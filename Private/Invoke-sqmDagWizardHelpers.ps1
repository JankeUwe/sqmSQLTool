# Hilfsfunktionen für den Distributed-AG-Migrationsassistenten (Show-sqmDistributedAgGui).
# Bewusst ohne GUI-Abhaengigkeit, damit alles per Pester testbar ist.

function Resolve-sqmDagError
{
	<#
	.SYNOPSIS
	    Uebersetzt eine technische Fehlermeldung in Ursache, Lösungsvorschlag und Wiederholbarkeit.
	.DESCRIPTION
	    Liefert immer ein Objekt (nie $null). Unbekannte Fehler landen in der Kategorie 'Unknown'
	    mit dem Originaltext, damit nie Information verloren geht.
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
	)

	$rules = @(
		@{ Pattern = 'Login failed|18456|Anmeldung f.r den Benutzer|Anmeldung fehlgeschlagen'; Category = 'Auth'; Retry = $false
			De = 'Die Anmeldung am SQL Server wurde abgelehnt.'; DeFix = 'Benutzername und Kennwort prüfen, bei Windows-Anmeldung das Konto des Aufrufers prüfen.'
			En = 'The SQL Server login was rejected.'; EnFix = 'Check user name and password; for Windows authentication check the calling account.' }
		@{ Pattern = 'network-related|instance-specific|server was not found|Could not open a connection|nicht gefunden oder nicht erreichbar|Named Pipes Provider|TCP Provider'; Category = 'Unreachable'; Retry = $true
			De = 'Der SQL Server ist nicht erreichbar.'; DeFix = 'Servername, Port, Firewall und SQL Browser prüfen und danach wiederholen.'
			En = 'The SQL Server cannot be reached.'; EnFix = 'Check server name, port, firewall and SQL Browser, then retry.' }
		@{ Pattern = 'timeout|timed out|Zeitlimit|Timeout expired'; Category = 'Timeout'; Retry = $true
			De = 'Die Aktion hat das Zeitlimit überschritten.'; DeFix = 'Last auf dem Server prüfen. Der Schritt kann gefahrlos wiederholt werden.'
			En = 'The operation timed out.'; EnFix = 'Check server load. The step can safely be retried.' }
		@{ Pattern = 'permission was denied|\b229\b|\b297\b|\b15247\b|CONTROL SERVER|Berechtigung'; Category = 'Permission'; Retry = $false
			De = 'Dem Konto fehlen Berechtigungen.'; DeFix = 'Für die Migration wird sysadmin auf beiden Seiten benötigt.'
			En = 'The account lacks permissions.'; EnFix = 'The migration needs sysadmin on both sides.' }
		@{ Pattern = '\b35250\b|\b35206\b|\b35201\b|connection to the primary replica is not active'; Category = 'EndpointConnection'; Retry = $true
			De = 'Die Endpoint-Verbindung zwischen den Clustern steht nicht.'; DeFix = 'Endpoint-Port, Firewall, CONNECT-Recht des Dienstkontos und FQDN prüfen.'
			En = 'The endpoint connection between the clusters is not established.'; EnFix = 'Check endpoint port, firewall, CONNECT permission of the service account and FQDN.' }
		@{ Pattern = '\b19471\b|WSFC cluster could not be contacted|cluster could not be contacted'; Category = 'Cluster'; Retry = $true
			De = 'Der Windows-Cluster (WSFC) ist nicht erreichbar.'; DeFix = 'Clusterdienst und Quorum auf dem betroffenen Knoten prüfen.'
			En = 'The Windows cluster (WSFC) cannot be contacted.'; EnFix = 'Check the cluster service and quorum on the affected node.' }
		@{ Pattern = 'HADR is not enabled|\b35220\b|Always On.*not enabled|nicht aktiviert'; Category = 'HadrDisabled'; Retry = $false
			De = 'Always On ist auf dem Server nicht aktiviert.'; DeFix = 'HADR im SQL Server Configuration Manager aktivieren und den Dienst neu starten.'
			En = 'Always On is not enabled on the server.'; EnFix = 'Enable HADR in SQL Server Configuration Manager and restart the service.' }
		@{ Pattern = 'Cannot open backup device|operating system error 5|Access is denied|Zugriff verweigert|\b3201\b'; Category = 'BackupPath'; Retry = $false
			De = 'Der Backup-Pfad ist für ein SQL-Dienstkonto nicht erreichbar oder nicht beschreibbar.'; DeFix = 'UNC-Pfad verwenden und beiden SQL-Dienstkonten Schreib- und Leserechte geben.'
			En = 'The backup path is not reachable or writable for a SQL service account.'; EnFix = 'Use a UNC path and grant both SQL service accounts read and write access.' }
		@{ Pattern = 'There is insufficient disk space|not enough space|\b112\b|Datenträger.*voll|disk space'; Category = 'DiskSpace'; Retry = $false
			De = 'Auf dem Zielvolume ist nicht genug Platz.'; DeFix = 'Speicher schaffen oder anderes Volume verwenden und den Schritt wiederholen.'
			En = 'There is not enough space on the target volume.'; EnFix = 'Free up space or use another volume, then retry the step.' }
		@{ Pattern = 'already exists|\b1801\b|bereits vorhanden|already a member|database .* already'; Category = 'AlreadyExists'; Retry = $false
			De = 'Das Objekt existiert bereits (Wiederaufnahme oder Namenskonflikt).'; DeFix = 'Zustand prüfen. Hat ein frueherer Lauf das Objekt angelegt, kann der Schritt übersprungen werden.'
			En = 'The object already exists (resume or name conflict).'; EnFix = 'Check the state. If an earlier run created it, the step can be skipped.' }
		@{ Pattern = 'transaction log.*full|\b9002\b'; Category = 'LogFull'; Retry = $false
			De = 'Das Transaktionsprotokoll ist voll.'; DeFix = 'Log-Backup ausführen oder Log vergrößern, dann wiederholen.'
			En = 'The transaction log is full.'; EnFix = 'Take a log backup or grow the log, then retry.' }
	)

	foreach ($r in $rules)
	{
		if ($Message -match $r.Pattern)
		{
			return [PSCustomObject]@{
				Category = $r.Category
				CauseDe  = $r.De; FixDe = $r.DeFix
				CauseEn  = $r.En; FixEn = $r.EnFix
				Retryable = [bool]$r.Retry
				Raw      = $Message
			}
		}
	}
	return [PSCustomObject]@{
		Category = 'Unknown'
		CauseDe  = 'Unerwarteter Fehler.'; FixDe = 'Meldung und Log an den Support weitergeben. Der Zustand der Server bleibt unveraendert, sofern der Schritt nicht begonnen hat.'
		CauseEn  = 'Unexpected error.'; FixEn = 'Pass the message and the log to support. Server state is unchanged unless the step had started.'
		Retryable = $false
		Raw      = $Message
	}
}

function Test-sqmDagInputValue
{
	<#
	.SYNOPSIS
	    Prüft einzelne Eingabewerte des Assistenten. Liefert $null bei Erfolg, sonst den Fehlertext (de/en).
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][ValidateSet('Instance', 'AgName', 'DagName', 'Fqdn', 'Port', 'Path', 'ServiceAccount')][string]$Kind,
		[AllowEmptyString()][string]$Value,
		[ValidateSet('de', 'en')][string]$Lang = 'de'
	)
	$v = if ($null -eq $Value) { '' } else { $Value.Trim() }
	$isDe = ($Lang -eq 'de')
	$msg = {
		param ($de, $en)
		if ($isDe) { $de } else { $en }
	}
	if (-not $v) { return (& $msg 'Pflichtfeld.' 'Required.') }
	switch ($Kind)
	{
		'Instance'
		{
			if ($v -notmatch '^[A-Za-z0-9_\-\.]+(\\[A-Za-z0-9_\-\$#@]+)?(,\d{1,5})?$')
			{ return (& $msg 'Ungültiger Instanzname. Erlaubt: SERVER, SERVER\INSTANZ oder SERVER,Port.' 'Invalid instance name. Allowed: SERVER, SERVER\INSTANCE or SERVER,port.') }
			if ($v -match ',(\d+)$' -and ([int]$Matches[1] -lt 1 -or [int]$Matches[1] -gt 65535))
			{ return (& $msg 'Port außerhalb 1 bis 65535.' 'Port outside 1 to 65535.') }
		}
		{ $_ -in 'AgName', 'DagName' }
		{
			if ($v.Length -gt 128) { return (& $msg 'Maximal 128 Zeichen.' 'At most 128 characters.') }
			if ($v -match '[\[\]''";\r\n\\/]') { return (& $msg 'Unzulaessige Zeichen ([ ] '' " ; \ /).' 'Illegal characters ([ ] '' " ; \ /).') }
		}
		'Fqdn'
		{
			if ($v -notmatch '^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$|^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9\-]+$')
			{ return (& $msg 'Kein gültiger FQDN (z. B. sql01.firma.local).' 'Not a valid FQDN (e.g. sql01.corp.local).') }
		}
		'Port'
		{
			$p = 0
			if (-not [int]::TryParse($v, [ref]$p) -or $p -lt 1024 -or $p -gt 65535)
			{ return (& $msg 'Port muss eine Zahl von 1024 bis 65535 sein.' 'Port must be a number from 1024 to 65535.') }
		}
		'Path'
		{
			if ($v -notmatch '^(\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*|[A-Za-z]:\\([^\\/:*?"<>|]+\\?)*)$')
			{ return (& $msg 'Ungültiger Pfad. Erlaubt: UNC (\\server\freigabe) oder Laufwerkspfad.' 'Invalid path. Allowed: UNC (\\server\share) or drive path.') }
		}
		'ServiceAccount'
		{
			if ($v -notmatch '^[^\\@\s]+\\[^\\@\s]+\$?$|^[^@\s]+@[^@\s]+$|^NT SERVICE\\.+$')
			{ return (& $msg 'Format DOMAENE\Konto oder konto@domaene erwartet.' 'Expected DOMAIN\account or account@domain.') }
		}
	}
	return $null
}

function Get-sqmDagStateDirectory
{
	[CmdletBinding()]
	[OutputType([string])]
	param ([string]$BasePath)
	if (-not $BasePath) { $BasePath = Join-Path (Get-sqmDefaultOutputPath) 'DistributedAgMigration' }
	if (-not (Test-Path -LiteralPath $BasePath)) { New-Item -ItemType Directory -Path $BasePath -Force | Out-Null }
	return $BasePath
}

function Get-sqmDagStateFile
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)][string]$SourceAgName,
		[Parameter(Mandatory = $true)][string]$TargetAgName,
		[string]$BasePath
	)
	$dir = Get-sqmDagStateDirectory -BasePath $BasePath
	$safe = ("$SourceAgName`__$TargetAgName") -replace '[^A-Za-z0-9_\-\.]', '_'
	return (Join-Path $dir "$safe.json")
}

function Save-sqmDagMigrationState
{
	<#
	.SYNOPSIS
	    Schreibt den Migrationszustand atomar als JSON. Geheimnisse (Kennwort, Credential) werden nie gespeichert.
	#>
	[CmdletBinding(SupportsShouldProcess = $true)]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)][hashtable]$State,
		[string]$BasePath
	)
	$clean = @{}
	foreach ($k in $State.Keys)
	{
		if ($k -match 'pass|secret|credential|token|pwd') { continue }
		$clean[$k] = $State[$k]
	}
	$clean['SavedAt'] = (Get-Date).ToString('s')
	$file = Get-sqmDagStateFile -SourceAgName ([string]$State.SourceAgName) -TargetAgName ([string]$State.TargetAgName) -BasePath $BasePath
	if ($PSCmdlet.ShouldProcess($file, 'Zustand speichern'))
	{
		$tmp = "$file.tmp"
		$json = $clean | ConvertTo-Json -Depth 8
		[System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
		Move-Item -LiteralPath $tmp -Destination $file -Force
	}
	return $file
}

function Get-sqmDagMigrationState
{
	<#
	.SYNOPSIS
	    Liest gespeicherte Migrationszustaende. Mit Quell-/Ziel-AG wird genau einer geliefert, sonst alle.
	    Eine beschaedigte Datei wird nicht geworfen, sondern als Objekt mit Corrupt = $true gemeldet.
	#>
	[CmdletBinding()]
	param (
		[string]$SourceAgName,
		[string]$TargetAgName,
		[string]$BasePath
	)
	$dir = Get-sqmDagStateDirectory -BasePath $BasePath
	if ($SourceAgName -and $TargetAgName)
	{
		$files = @(Get-Item -LiteralPath (Get-sqmDagStateFile -SourceAgName $SourceAgName -TargetAgName $TargetAgName -BasePath $BasePath) -ErrorAction SilentlyContinue)
	}
	else
	{
		$files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)
	}
	foreach ($f in $files)
	{
		try
		{
			$o = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
			$o | Add-Member -NotePropertyName StateFile -NotePropertyValue $f.FullName -Force
			$o | Add-Member -NotePropertyName Corrupt -NotePropertyValue $false -Force
			$o
		}
		catch
		{
			[PSCustomObject]@{ StateFile = $f.FullName; Corrupt = $true; Error = $_.Exception.Message }
		}
	}
}

function Enter-sqmDagMigrationLock
{
	<#
	.SYNOPSIS
	    Verhindert, dass zwei Assistenten dieselbe Migration gleichzeitig bearbeiten.
	.DESCRIPTION
	    Liefert Acquired = $true oder false mit Owner-Angaben. Eine Sperre desselben Rechners, deren
	    Prozess nicht mehr läuft, gilt als verwaist und wird übernommen (StaleTakeover).
	#>
	[CmdletBinding(SupportsShouldProcess = $true)]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)][string]$SourceAgName,
		[Parameter(Mandatory = $true)][string]$TargetAgName,
		[string]$BasePath
	)
	$stateFile = Get-sqmDagStateFile -SourceAgName $SourceAgName -TargetAgName $TargetAgName -BasePath $BasePath
	$lockFile = [System.IO.Path]::ChangeExtension($stateFile, '.lock')
	$stale = $false
	if (Test-Path -LiteralPath $lockFile)
	{
		$owner = $null
		try { $owner = Get-Content -LiteralPath $lockFile -Raw | ConvertFrom-Json } catch { $owner = $null }
		if ($owner)
		{
			$alive = $true
			if ($owner.Host -eq $env:COMPUTERNAME)
			{
				$alive = [bool](Get-Process -Id ([int]$owner.Pid) -ErrorAction SilentlyContinue)
			}
			if ($alive)
			{
				return [PSCustomObject]@{ Acquired = $false; LockFile = $lockFile; OwnerHost = $owner.Host; OwnerUser = $owner.User; OwnerPid = $owner.Pid; Since = $owner.Started; StaleTakeover = $false }
			}
		}
		$stale = $true
	}
	if ($PSCmdlet.ShouldProcess($lockFile, 'Sperre setzen'))
	{
		$info = @{ Pid = $PID; Host = $env:COMPUTERNAME; User = "$env:USERDOMAIN\$env:USERNAME"; Started = (Get-Date).ToString('s') }
		[System.IO.File]::WriteAllText($lockFile, ($info | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
	}
	return [PSCustomObject]@{ Acquired = $true; LockFile = $lockFile; StaleTakeover = $stale }
}

function Exit-sqmDagMigrationLock
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param ([Parameter(Mandatory = $true)][string]$LockFile)
	if ((Test-Path -LiteralPath $LockFile) -and $PSCmdlet.ShouldProcess($LockFile, 'Sperre aufheben'))
	{
		Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
	}
}

function Start-sqmDagBackgroundJob
{
	<#
	.SYNOPSIS
	    Fuehrt Code in einem eigenen Runspace aus, damit die GUI bedienbar bleibt.
	.DESCRIPTION
	    Das Modul wird im Runspace neu importiert. Credentials werden als Objekt übergeben und
	    verlassen den Prozess nicht. Fortschritt kommt über den Information-Stream (Tag sqmStep).
	#>
	[CmdletBinding(SupportsShouldProcess = $true)]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)][string]$Code,
		[object[]]$ArgumentList = @(),
		[string]$ModulePath
	)
	if (-not $ModulePath)
	{
		$m = Get-Module -Name sqmSQLTool
		$ModulePath = if ($m) { Join-Path $m.ModuleBase 'sqmSQLTool.psd1' } else { 'sqmSQLTool' }
	}
	if (-not $PSCmdlet.ShouldProcess('Hintergrundjob', 'Starten')) { return $null }
	$rs = [runspacefactory]::CreateRunspace()
	$rs.ApartmentState = 'MTA'
	$rs.Open()
	$ps = [powershell]::Create()
	$ps.Runspace = $rs
	[void]$ps.AddScript({
			param ($ModPath, $Src, $Arguments)
			$ErrorActionPreference = 'Stop'
			$env:MSSQLTOOLS_SKIP_AUTO_UPDATE = '1'
			Import-Module $ModPath -Force -DisableNameChecking
			$mod = Get-Module -Name sqmSQLTool
			$sb = [scriptblock]::Create($Src)
			# Im Modulbereich ausführen, damit auch die privaten Hilfsfunktionen sichtbar sind.
			& $mod $sb @Arguments
		}).AddArgument($ModulePath).AddArgument($Code).AddArgument($ArgumentList)
	$handle = $ps.BeginInvoke()
	return [PSCustomObject]@{ PowerShell = $ps; Runspace = $rs; Handle = $handle; InfoRead = 0; ErrRead = 0; Started = Get-Date }
}

function Receive-sqmDagBackgroundJob
{
	<#
	.SYNOPSIS
	    Holt neue Schrittmeldungen und Fehler eines Hintergrundjobs und meldet, ob er fertig ist.
	.OUTPUTS
	    Steps (neue sqmStep-Meldungen), Errors (neue Fehler), Done, Output (nur wenn Done), Failed.
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param ([Parameter(Mandatory = $true)]$Job)
	$ps = $Job.PowerShell
	$steps = @()
	$info = $ps.Streams.Information
	while ($Job.InfoRead -lt $info.Count)
	{
		$rec = $info[$Job.InfoRead]
		$Job.InfoRead++
		if ($rec.Tags -contains 'sqmStep') { $steps += $rec.MessageData }
	}
	$errs = @()
	$er = $ps.Streams.Error
	while ($Job.ErrRead -lt $er.Count)
	{
		$errs += $er[$Job.ErrRead]
		$Job.ErrRead++
	}
	$done = $Job.Handle.IsCompleted
	$out = $null
	$failed = $false
	if ($done)
	{
		try { $out = @($ps.EndInvoke($Job.Handle)) }
		catch { $failed = $true; $errs += $_ }
		if ($ps.HadErrors -and -not $out) { $failed = $true }
	}
	return [PSCustomObject]@{ Steps = $steps; Errors = $errs; Done = $done; Output = $out; Failed = $failed }
}

function Stop-sqmDagBackgroundJob
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param ([Parameter(Mandatory = $true)]$Job)
	if (-not $PSCmdlet.ShouldProcess('Hintergrundjob', 'Beenden')) { return }
	try { if (-not $Job.Handle.IsCompleted) { [void]$Job.PowerShell.BeginStop($null, $null) } } catch { Write-Verbose $_.Exception.Message }
}

function Remove-sqmDagBackgroundJob
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param ([Parameter(Mandatory = $true)]$Job)
	if (-not $PSCmdlet.ShouldProcess('Hintergrundjob', 'Entfernen')) { return }
	try { $Job.PowerShell.Dispose() } catch { Write-Verbose $_.Exception.Message }
	try { $Job.Runspace.Dispose() } catch { Write-Verbose $_.Exception.Message }
}

function Get-sqmDagSyncSnapshot
{
	<#
	.SYNOPSIS
	    Liest den Datenbank-Replikationszustand einer Distributed AG von der globalen Primary.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$SqlInstance,
		[Parameter(Mandatory = $true)][string]$DagName,
		[System.Management.Automation.PSCredential]$SqlCredential
	)
	$p = @{ SqlInstance = $SqlInstance; EnableException = $true; SqlParameters = @{ dag = $DagName }; Query = @"
SELECT DB_NAME(drs.database_id) AS DatabaseName, ar.replica_server_name AS ReplicaName, drs.is_local AS IsLocal,
       drs.synchronization_state_desc AS SyncState, drs.synchronization_health_desc AS Health, drs.is_suspended AS Suspended,
       ISNULL(drs.log_send_queue_size, 0) AS SendQueueKB, ISNULL(drs.redo_queue_size, 0) AS RedoQueueKB, drs.last_commit_time AS LastCommit
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id AND ar.group_id = drs.group_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = @dag
ORDER BY DB_NAME(drs.database_id), drs.is_local DESC
"@ }
	if ($SqlCredential) { $p['SqlCredential'] = $SqlCredential }
	return @(Invoke-DbaQuery @p)
}

function Get-sqmDagSeedingSnapshot
{
	<#
	.SYNOPSIS
	    Liest den automatischen Seeding-Zustand einer Instanz (dm_hadr_automatic_seeding).
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential
	)
	$p = @{ SqlInstance = $SqlInstance; EnableException = $true; Query = @"
SELECT adc.database_name AS DatabaseName, ar.replica_server_name AS Replica, s.current_state AS State,
       s.failure_state_desc AS FailureState, s.error_code AS ErrorCode, s.start_time AS StartTime, s.completion_time AS CompletionTime
FROM sys.dm_hadr_automatic_seeding s
LEFT JOIN sys.availability_databases_cluster adc ON adc.group_database_id = s.ag_db_id
LEFT JOIN sys.availability_replicas ar ON ar.replica_id = s.ag_remote_replica_id
ORDER BY s.start_time DESC
"@ }
	if ($SqlCredential) { $p['SqlCredential'] = $SqlCredential }
	return @(Invoke-DbaQuery @p)
}

function Test-sqmDagFailoverReady
{
	<#
	.SYNOPSIS
	    Bewertet einen Sync-Snapshot: darf ein Failover starten? Liefert Ready und die Gruende.
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[AllowEmptyCollection()][object[]]$Snapshot = @(),
		[int]$MaxQueueKB = 1024
	)
	$reasons = [System.Collections.Generic.List[string]]::new()
	$remote = @($Snapshot | Where-Object { -not ($_.IsLocal -eq $true -or $_.IsLocal -eq 1) })
	if ($remote.Count -eq 0) { $reasons.Add('Keine Replikationsdaten der Gegenseite gefunden.') }
	foreach ($r in $remote)
	{
		if ($r.Suspended -eq $true -or $r.Suspended -eq 1) { $reasons.Add("[$($r.DatabaseName)] ist suspendiert.") }
		elseif ($r.SyncState -notin 'SYNCHRONIZED', 'SYNCHRONIZING') { $reasons.Add("[$($r.DatabaseName)] Zustand $($r.SyncState).") }
		elseif ([int64]$r.SendQueueKB -gt $MaxQueueKB -or [int64]$r.RedoQueueKB -gt $MaxQueueKB)
		{ $reasons.Add("[$($r.DatabaseName)] Send-Queue $($r.SendQueueKB) KB, Redo-Queue $($r.RedoQueueKB) KB.") }
	}
	return [PSCustomObject]@{ Ready = ($reasons.Count -eq 0); Reasons = $reasons.ToArray(); DatabaseCount = $remote.Count }
}

function Invoke-sqmDagMigrationUnit
{
	<#
	.SYNOPSIS
	    Fuehrt genau einen Migrationsschritt aus und liefert ein einheitliches Ergebnis (nie eine Ausnahme).
	.DESCRIPTION
	    Units: CreateDag, AddDatabase, ListenerPrep, ListenerComplete, Failover, Rollback.
	    Das Ergebnis enthält Ok, Unit, Result (Rueckgabe der Funktion) und bei Fehlern Error
	    (Resolve-sqmDagError). Mit -DryRun wird -WhatIf durchgereicht (ListenerPrep/Complete/Failover/
	    CreateDag/AddDatabase unterstuetzen es).
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)][ValidateSet('CreateDag', 'AddDatabase', 'ListenerPrep', 'ListenerComplete', 'Failover', 'Rollback')][string]$Unit,
		[Parameter(Mandatory = $true)][hashtable]$Config,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[string]$DatabaseName,
		[switch]$DryRun
	)
	$c = $Config
	$cred = @{}
	if ($SqlCredential) { $cred['SqlCredential'] = $SqlCredential }
	$wi = @{}
	if ($DryRun) { $wi['WhatIf'] = $true } else { $wi['Confirm'] = $false }
	try
	{
		switch ($Unit)
		{
			'CreateDag'
			{
				$p = @{
					PrimaryInstance = $c.SourceInstance; PrimaryAgName = $c.SourceAgName
					SecondaryInstance = $c.TargetInstance; SecondaryAgName = $c.TargetAgName
					PrimaryFqdn = $c.SourceFqdn; SecondaryFqdn = $c.TargetFqdn
					DistributedAgName = $c.DistributedAgName; EndpointPort = [int]$c.EndpointPort
					SeedingMode = $c.SeedingMode; EnableException = $true
				}
				if ($c.ServiceAccount) { $p['ServiceAccount'] = $c.ServiceAccount }
				if ($c.EndpointName) { $p['EndpointName'] = $c.EndpointName }
				if ($c.OutputPath) { $p['OutputPath'] = $c.OutputPath }
				$r = New-sqmDistributedAvailabilityGroup @p @cred @wi
			}
			'AddDatabase'
			{
				$p = @{
					SqlInstance = $c.SourceInstance; AvailabilityGroupName = $c.DistributedAgName; DatabaseName = $DatabaseName
					SecondaryInstance = $c.TargetInstance; SourceAvailabilityGroupName = $c.SourceAgName
					TargetAvailabilityGroupName = $c.TargetAgName; SeedingMode = $c.SeedingMode; EnableException = $true
				}
				if ($c.BackupPath) { $p['BackupPath'] = $c.BackupPath }
				$r = Add-sqmDatabaseToDistributedAg @p @cred @wi
			}
			'ListenerPrep'
			{
				$p = @{ SqlInstance = $c.SourceInstance; AvailabilityGroupName = $c.SourceAgName; EnableException = $true }
				if ($c.ListenerName) { $p['ListenerName'] = $c.ListenerName }
				if ($c.ListenerOutputPath) { $p['OutputPath'] = $c.ListenerOutputPath }
				$r = Invoke-sqmListenerMigrationPrep @p @cred @wi
			}
			'ListenerComplete'
			{
				$p = @{ SqlInstance = $c.TargetInstance; AvailabilityGroupName = $c.TargetAgName; ListenerName = $c.ListenerName; EnableException = $true }
				if ($c.ListenerPort) { $p['ListenerPort'] = [int]$c.ListenerPort }
				if ($c.ListenerOutputPath) { $p['OutputPath'] = $c.ListenerOutputPath }
				$r = Complete-sqmListenerMigration @p @cred @wi
			}
			{ $_ -in 'Failover', 'Rollback' }
			{
				$fwd = ($Unit -eq 'Failover')
				$p = @{
					SqlInstance = $(if ($fwd) { $c.SourceInstance } else { $c.TargetInstance })
					TargetInstance = $(if ($fwd) { $c.TargetInstance } else { $c.SourceInstance })
					AvailabilityGroupName = $c.DistributedAgName; Force = $true; EnableException = $true
				}
				if ($Unit -eq 'Rollback') { $p['Rollback'] = $true }
				if ($c.FailoverOutputPath) { $p['OutputPath'] = $c.FailoverOutputPath }
				$r = Invoke-sqmDistributedFailover @p @cred @wi
			}
		}
		$st = if ($r -and $r.PSObject.Properties['Status']) { [string]$r.Status } else { 'SUCCESS' }
		if ($st -eq 'FAILED')
		{
			$msg = if ($r.PSObject.Properties['Error']) { [string]$r.Error } else { 'Schritt fehlgeschlagen.' }
			return [PSCustomObject]@{ Ok = $false; Unit = $Unit; Status = $st; Result = $r; Error = (Resolve-sqmDagError -Message $msg) }
		}
		return [PSCustomObject]@{ Ok = $true; Unit = $Unit; Status = $st; Result = $r; Error = $null }
	}
	catch
	{
		return [PSCustomObject]@{ Ok = $false; Unit = $Unit; Status = 'FAILED'; Result = $null; Error = (Resolve-sqmDagError -Message $_.Exception.Message) }
	}
}

function Get-sqmDagAgList
{
	<#
	.SYNOPSIS
	    Verbindungstest einer Instanz und Liste ihrer normalen AGs mit lokaler Rolle (für die Auswahllisten des Assistenten).
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)][string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential
	)
	$p = @{ SqlInstance = $SqlInstance; EnableException = $true; Query = @"
SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(32)) AS ProductVersion,
       CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled,
       IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin
"@ }
	if ($SqlCredential) { $p['SqlCredential'] = $SqlCredential }
	try
	{
		$base = Invoke-DbaQuery @p | Select-Object -First 1
		$p['Query'] = @"
SELECT ag.name AS AgName, ISNULL(ars.role_desc, 'UNKNOWN') AS Role
FROM sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id = ag.group_id AND ars.is_local = 1
WHERE ag.is_distributed = 0
ORDER BY ag.name
"@
		$ags = @()
		$dags = @()
		if ($base.IsHadrEnabled -eq 1)
		{
			$ags = @(Invoke-DbaQuery @p)
			$p['Query'] = 'SELECT ag.name AS DagName FROM sys.availability_groups ag WHERE ag.is_distributed = 1 ORDER BY ag.name'
			$dags = @(Invoke-DbaQuery @p | ForEach-Object { $_.DagName })
		}
		$fqdn = $null
		try
		{
			$h = ($SqlInstance -split '[\\,]')[0]
			if ($h -and $h -notin '.', '(local)', 'localhost') { $fqdn = [System.Net.Dns]::GetHostEntry($h).HostName }
			else { $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName }
		}
		catch { $fqdn = $null }
		return [PSCustomObject]@{
			Ok = $true; Instance = $SqlInstance; ProductVersion = $base.ProductVersion
			HadrEnabled = ($base.IsHadrEnabled -eq 1); IsSysadmin = ($base.IsSysadmin -eq 1)
			AvailabilityGroups = @($ags | ForEach-Object { [PSCustomObject]@{ Name = $_.AgName; Role = $_.Role } })
			DistributedAgs = $dags; Fqdn = $fqdn; Error = $null
		}
	}
	catch
	{
		return [PSCustomObject]@{ Ok = $false; Instance = $SqlInstance; ProductVersion = $null; HadrEnabled = $false; IsSysadmin = $false; AvailabilityGroups = @(); DistributedAgs = @(); Fqdn = $null; Error = (Resolve-sqmDagError -Message $_.Exception.Message) }
	}
}
