function Test-sqmDistributedAgMigrationPrerequisite
{
<#
.SYNOPSIS
    Prüft alle Voraussetzungen für die Migration eines AlwaysOn-AG per Distributed AG auf einen neuen Cluster.

.DESCRIPTION
    Liest nur, aendert nichts. Prüft getrennt für Quelle und Ziel:
    Erreichbarkeit und sysadmin, SQL-Version und Edition (Distributed AG ab 2016 SP1, Enterprise/Developer),
    Ziel-Version nicht älter als Quelle, HADR aktiv, AG vorhanden und auf dem angegebenen Knoten PRIMARY,
    AG gesund, bereits Teil einer Distributed AG, Namenskonflikte, Datenbankzustand (synchron, nicht suspendiert),
    Datenbanknamen auf dem Ziel, Dateipfade und freier Platz auf dem Ziel (Autoseed), Endpoint (vorhanden, gestartet,
    Port, Rolle), CONNECT-Recht des Dienstkontos der Gegenseite, DNS und TCP-Erreichbarkeit der FQDNs sowie der
    Backup-Pfad bei manuellem Seeding.

    Jede Prüfung liefert Severity (Blocker oder Warning) und Status (Pass, Fail, Warn, Skip) mit Meldung und
    Lösungsvorschlag in Deutsch und Englisch. CanProceed ist nur dann $true, wenn kein Blocker fehlschlaegt.

.PARAMETER SourceInstance
    SQL-Instanz (Knoten oder Listener) der Quelle. Sie muss den PRIMARY der Quell-AG hosten.

.PARAMETER SourceAgName
    Name der Quell-AG.

.PARAMETER TargetInstance
    SQL-Instanz des Ziel-Clusters. Sie muss den PRIMARY der Ziel-AG hosten.

.PARAMETER TargetAgName
    Name der Ziel-AG (muss bereits existieren).

.PARAMETER SqlCredential
    Optionales Credential für beide Seiten.

.PARAMETER DistributedAgName
    Geplanter Name der Distributed AG. Standard: <Quell-AG>_<Ziel-AG>.

.PARAMETER SourceFqdn
    FQDN der Quelle für die LISTENER_URL (optional, aktiviert DNS- und Port-Test).

.PARAMETER TargetFqdn
    FQDN des Ziels für die LISTENER_URL (optional, aktiviert DNS- und Port-Test).

.PARAMETER EndpointPort
    Erwarteter Endpoint-Port. Standard 5022.

.PARAMETER SeedingMode
    Automatic oder Manual. Bei Manual wird der Backup-Pfad geprüft.

.PARAMETER BackupPath
    Backup-Pfad für manuelles Seeding (UNC empfohlen).

.EXAMPLE
    Test-sqmDistributedAgMigrationPrerequisite -SourceInstance SQL01 -SourceAgName ProdAG -TargetInstance NEW01 -TargetAgName NewAG

.OUTPUTS
    PSCustomObject mit Checks, Blockers, Warnings, Passed, CanProceed, SourceDatabases.

.NOTES
    DNS- und Port-Test laufen von dem Rechner aus, auf dem dieser Befehl läuft. Maßgeblich ist die Verbindung
    von Server zu Server, daher sind diese beiden Prüfungen nur Warnungen.
#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)][string]$SourceInstance,
		[Parameter(Mandatory = $true)][string]$SourceAgName,
		[Parameter(Mandatory = $true)][string]$TargetInstance,
		[Parameter(Mandatory = $true)][string]$TargetAgName,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[string]$DistributedAgName,
		[string]$SourceFqdn,
		[string]$TargetFqdn,
		[ValidateRange(1024, 65535)][int]$EndpointPort = 5022,
		[ValidateSet('Automatic', 'Manual')][string]$SeedingMode = 'Automatic',
		[string]$BackupPath
	)

	$cred = $SqlCredential
	$checks = [System.Collections.Generic.List[PSCustomObject]]::new()
	$dagName = if ($DistributedAgName) { $DistributedAgName } else { "$($SourceAgName)_$($TargetAgName)" }

	$add = {
		# Zwei Aufrufformen: 4 Texte (Meldung de/en, Lösung de/en) oder 6 Texte
		# (Meldung bei Erfolg de/en, Meldung bei Fehler de/en, Lösung de/en).
		param ($Id, $Category, $Name, $Severity, [bool]$Pass, $T1, $T2, $T3, $T4, $T5, $T6)
		$status = if ($Pass) { 'Pass' } elseif ($Severity -eq 'Blocker') { 'Fail' } else { 'Warn' }
		if ($null -ne $T6 -or $null -ne $T5)
		{
			$msgDe = if ($Pass) { $T1 } else { $T3 }
			$msgEn = if ($Pass) { $T2 } else { $T4 }
			$fixDe = $T5; $fixEn = $T6
		}
		else
		{
			$msgDe = $T1; $msgEn = $T2; $fixDe = $T3; $fixEn = $T4
		}
		$c = [PSCustomObject]@{
			Id = $Id; Category = $Category; Name = $Name; Severity = $Severity; Status = $status
			MessageDe = $msgDe; MessageEn = $msgEn
			RemedyDe = $(if ($Pass) { '' } else { $fixDe }); RemedyEn = $(if ($Pass) { '' } else { $fixEn })
		}
		$checks.Add($c)
		Write-Information -MessageData ([PSCustomObject]@{ Step = $Name; Status = $status }) -Tags 'sqmStep'
	}

	$q = {
		param ($Instance, $Query, $Params)
		$p = @{ SqlInstance = $Instance; Query = $Query; EnableException = $true }
		if ($cred) { $p['SqlCredential'] = $cred }
		if ($Params) { $p['SqlParameters'] = $Params }
		Invoke-DbaQuery @p
	}

	# ---- lokal: dbatools ----
	$hasDbatools = [bool](Get-Module -Name dbatools -ListAvailable -ErrorAction SilentlyContinue)
	& $add 'local.dbatools' 'Lokal' 'dbatools' 'Blocker' $hasDbatools 'dbatools ist installiert.' 'dbatools is installed.' `
		'dbatools fehlt.' 'dbatools is missing.' 'Install-Module dbatools oder das Offline-Paket installieren.' 'Install-Module dbatools or install the offline package.'

	$sides = @(
		@{ Key = 'src'; Label = 'Quelle'; LabelEn = 'Source'; Instance = $SourceInstance; Ag = $SourceAgName; Other = $TargetInstance }
		@{ Key = 'tgt'; Label = 'Ziel'; LabelEn = 'Target'; Instance = $TargetInstance; Ag = $TargetAgName; Other = $SourceInstance }
	)
	$info = @{}
	$srcDatabases = @()
	$srcFiles = @()

	foreach ($s in $sides)
	{
		$k = $s.Key; $lbl = "$($s.Label)"
		$inst = $s.Instance
		$cat = "$lbl ($inst)"

		# ---- Verbindung und Basisdaten ----
		$row = $null
		try
		{
			$row = & $q $inst @"
SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(32)) AS ProductVersion,
       CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
       CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled,
       CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS Collation,
       IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin
"@ $null | Select-Object -First 1
		}
		catch
		{
			$err = Resolve-sqmDagError -Message $_.Exception.Message
			& $add "$k.connect" $cat 'Verbindung' 'Blocker' $false "Verbindung zu [$inst] fehlgeschlagen: $($err.CauseDe)" "Connection to [$inst] failed: $($err.CauseEn)" $err.FixDe $err.FixEn
			$info[$k] = $null
			continue
		}
		if (-not $row)
		{
			& $add "$k.connect" $cat 'Verbindung' 'Blocker' $false "Keine Antwort von [$inst]." "No answer from [$inst]." 'Servernamen prüfen.' 'Check the server name.'
			$info[$k] = $null
			continue
		}
		$info[$k] = $row
		& $add "$k.connect" $cat 'Verbindung' 'Blocker' $true "Verbunden mit [$inst]." "Connected to [$inst]." '' ''

		$isSys = ($row.IsSysadmin -eq 1)
		& $add "$k.sysadmin" $cat 'sysadmin-Rechte' 'Blocker' $isSys 'Das Konto ist sysadmin.' 'The account is sysadmin.' `
			'Das Konto ist kein sysadmin.' 'The account is not sysadmin.' 'Mit einem sysadmin-Konto anmelden.' 'Sign in with a sysadmin account.'

		$ver = $null
		try { $ver = [version]$row.ProductVersion } catch { $ver = $null }
		$verOk = ($ver -and $ver -ge [version]'13.0.4001')
		& $add "$k.version" $cat 'SQL-Version' 'Blocker' ([bool]$verOk) "SQL Server $($row.ProductVersion)." "SQL Server $($row.ProductVersion)." `
			'Distributed AG benötigt SQL Server 2016 SP1 oder neuer.' 'Distributed AG needs SQL Server 2016 SP1 or later.' 'Instanz aktualisieren.' 'Update the instance.'

		$edOk = ($row.Edition -match 'Enterprise|Developer|Evaluation')
		& $add "$k.edition" $cat 'Edition' 'Blocker' ([bool]$edOk) "Edition: $($row.Edition)." "Edition: $($row.Edition)." `
			'Distributed AG wird von dieser Edition nicht unterstützt.' 'Distributed AG is not supported on this edition.' 'Enterprise oder Developer verwenden.' 'Use Enterprise or Developer.'

		& $add "$k.hadr" $cat 'Always On aktiviert' 'Blocker' ($row.IsHadrEnabled -eq 1) 'Always On ist aktiviert.' 'Always On is enabled.' `
			'Always On ist nicht aktiviert.' 'Always On is not enabled.' 'HADR im SQL Server Configuration Manager aktivieren und Dienst neu starten.' 'Enable HADR in SQL Server Configuration Manager and restart the service.'

		# ---- AG vorhanden / PRIMARY / gesund ----
		$ag = $null
		try
		{
			$ag = & $q $inst @"
SELECT ag.name, ag.is_distributed, ags.primary_replica, ars.role_desc, ars.synchronization_health_desc
FROM sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_group_states ags ON ags.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id = ag.group_id AND ars.is_local = 1
WHERE ag.name = @n
"@ @{ n = $s.Ag } | Select-Object -First 1
		}
		catch
		{
			$err = Resolve-sqmDagError -Message $_.Exception.Message
			& $add "$k.ag" $cat "AG [$($s.Ag)]" 'Blocker' $false "AG-Abfrage fehlgeschlagen: $($err.CauseDe)" "AG query failed: $($err.CauseEn)" $err.FixDe $err.FixEn
			continue
		}
		& $add "$k.ag" $cat "AG [$($s.Ag)] vorhanden" 'Blocker' ([bool]$ag) "AG [$($s.Ag)] gefunden." "AG [$($s.Ag)] found." `
			"AG [$($s.Ag)] existiert auf [$inst] nicht." "AG [$($s.Ag)] does not exist on [$inst]." 'AG-Namen und Instanz prüfen.' 'Check AG name and instance.'
		if (-not $ag) { continue }

		& $add "$k.notdag" $cat 'Normale AG' 'Blocker' ($ag.is_distributed -ne $true -and $ag.is_distributed -ne 1) 'Es ist eine normale AG.' 'This is a regular AG.' `
			'Die angegebene AG ist selbst eine Distributed AG.' 'The specified AG is itself a Distributed AG.' 'Die zugrunde liegende normale AG angeben.' 'Specify the underlying regular AG.'

		& $add "$k.primary" $cat 'Knoten ist PRIMARY' 'Blocker' ($ag.role_desc -eq 'PRIMARY') "[$inst] ist PRIMARY der AG." "[$inst] is the PRIMARY of the AG." `
			"[$inst] ist nicht PRIMARY (aktuell: $($ag.role_desc); Primary: $($ag.primary_replica))." "[$inst] is not PRIMARY (currently: $($ag.role_desc); primary: $($ag.primary_replica))." `
			'Mit dem Primary-Knoten oder dem Listener der AG verbinden.' 'Connect to the primary node or the AG listener.'

		& $add "$k.health" $cat 'AG gesund' 'Blocker' ($ag.synchronization_health_desc -eq 'HEALTHY') 'AG ist HEALTHY.' 'AG is HEALTHY.' `
			"AG ist nicht gesund: $($ag.synchronization_health_desc)." "AG is not healthy: $($ag.synchronization_health_desc)." 'Erst die AG reparieren (Get-sqmAlwaysOnHealthReport).' 'Repair the AG first (Get-sqmAlwaysOnHealthReport).'

		# ---- Distributed-AG-Konflikte ----
		try
		{
			$inDag = @(& $q $inst @"
SELECT DISTINCT ag.name FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
WHERE ag.is_distributed = 1 AND ar.replica_server_name IN (@a, @b)
"@ @{ a = $SourceAgName; b = $TargetAgName })
			$sameName = @(& $q $inst 'SELECT name FROM sys.availability_groups WHERE name = @n' @{ n = $dagName })
			$sameCollides = ($sameName.Count -gt 0)
			if ($inDag.Count -gt 0 -and -not ($inDag.Count -eq 1 -and $inDag[0].name -eq $dagName))
			{
				$names = ($inDag | ForEach-Object { $_.name }) -join ', '
				& $add "$k.indag" $cat 'Nicht bereits in anderer Distributed AG' 'Blocker' $false "Mitglied von: $names" "Member of: $names" `
					"Eine der AGs ist schon Teil der Distributed AG $names." "One of the AGs is already part of Distributed AG $names." 'Bestehende Distributed AG prüfen oder fortsetzen.' 'Check or resume the existing Distributed AG.'
			}
			elseif ($sameCollides -and $inDag.Count -eq 0)
			{
				& $add "$k.dagname" $cat "Name [$dagName] frei" 'Blocker' $false '' '' `
					"Der Name [$dagName] ist auf [$inst] schon durch eine andere AG belegt." "The name [$dagName] is already used by another AG on [$inst]." 'Anderen Namen für die Distributed AG wählen.' 'Choose another name for the Distributed AG.'
			}
			elseif ($sameCollides)
			{
				& $add "$k.dagname" $cat "Distributed AG [$dagName]" 'Warning' $false '' '' `
					"Die Distributed AG [$dagName] existiert bereits. Der Assistent setzt dann mit den fehlenden Schritten fort." "Distributed AG [$dagName] already exists. The wizard will resume with the missing steps." 'Nur fortfahren, wenn dies eine abgebrochene Migration ist.' 'Only continue if this is an interrupted migration.'
			}
			else
			{
				& $add "$k.indag" $cat 'Distributed AG frei' 'Blocker' $true 'Keine Distributed AG-Konflikte.' 'No Distributed AG conflicts.' '' ''
			}
		}
		catch { Write-Verbose $_.Exception.Message }

		# ---- Endpoint ----
		try
		{
			$ep = & $q $inst @"
SELECT e.name, e.state_desc, te.port, dme.role_desc, dme.encryption_algorithm_desc
FROM sys.database_mirroring_endpoints dme
JOIN sys.endpoints e ON e.endpoint_id = dme.endpoint_id
JOIN sys.tcp_endpoints te ON te.endpoint_id = dme.endpoint_id
"@ $null | Select-Object -First 1
			& $add "$k.endpoint" $cat 'Endpoint vorhanden und gestartet' 'Blocker' ([bool]($ep -and $ep.state_desc -eq 'STARTED')) "Endpoint [$($ep.name)] läuft auf Port $($ep.port)." "Endpoint [$($ep.name)] is running on port $($ep.port)." `
				'Kein gestarteter Database-Mirroring-Endpoint gefunden.' 'No started database mirroring endpoint found.' 'Endpoint anlegen und starten (AlwaysOnSetup Schritt 3).' 'Create and start the endpoint (AlwaysOnSetup step 3).'
			if ($ep)
			{
				& $add "$k.endpointport" $cat "Endpoint-Port $EndpointPort" 'Warning' ([int]$ep.port -eq $EndpointPort) "Port stimmt ($EndpointPort)." "Port matches ($EndpointPort)." `
					"Endpoint lauscht auf $($ep.port), geplant ist $EndpointPort." "Endpoint listens on $($ep.port), planned is $EndpointPort." 'Port im Assistenten auf den tatsaechlichen Wert setzen.' 'Set the port in the wizard to the actual value.'
				& $add "$k.endpointrole" $cat 'Endpoint-Rolle' 'Warning' ($ep.role_desc -in 'ALL', 'PARTNER') "Rolle: $($ep.role_desc)." "Role: $($ep.role_desc)." `
					"Rolle $($ep.role_desc) ist für AG-Betrieb ungeeignet." "Role $($ep.role_desc) is unsuitable for AG operation." 'Rolle ALL verwenden.' 'Use role ALL.'
			}
		}
		catch { Write-Verbose $_.Exception.Message }

		# ---- Datenbanken (nur Quelle) ----
		if ($k -eq 'src')
		{
			try
			{
				$srcDatabases = @(& $q $inst @"
SELECT DB_NAME(drs.database_id) AS DatabaseName, drs.synchronization_state_desc, drs.synchronization_health_desc, drs.is_suspended
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = @n AND drs.is_local = 1
"@ @{ n = $s.Ag })
				& $add 'src.dbcount' $cat 'Datenbanken in der AG' 'Blocker' ($srcDatabases.Count -gt 0) "$($srcDatabases.Count) Datenbank(en) in der AG." "$($srcDatabases.Count) database(s) in the AG." `
					'Die Quell-AG enthält keine Datenbanken.' 'The source AG contains no databases.' 'Datenbanken zur AG hinzufügen.' 'Add databases to the AG.'
				$bad = @($srcDatabases | Where-Object { $_.is_suspended -eq $true -or $_.is_suspended -eq 1 -or $_.synchronization_state_desc -notin 'SYNCHRONIZED', 'SYNCHRONIZING' })
				$badNames = ($bad | ForEach-Object { $_.DatabaseName }) -join ', '
				& $add 'src.dbsync' $cat 'Datenbanken synchron' 'Blocker' ($bad.Count -eq 0) 'Alle Datenbanken laufen synchron.' 'All databases are synchronizing.' `
					"Nicht synchron oder suspendiert: $badNames" "Not synchronizing or suspended: $badNames" 'Datenbewegung fortsetzen und Synchronisation abwarten.' 'Resume data movement and wait for synchronization.'

				$srcFiles = @(& $q $inst @"
SELECT DB_NAME(mf.database_id) AS DatabaseName, mf.physical_name, CAST(mf.size AS bigint) * 8 / 1024 AS SizeMB
FROM sys.master_files mf
JOIN sys.availability_databases_cluster adc ON adc.database_name = DB_NAME(mf.database_id)
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
WHERE ag.name = @n
"@ @{ n = $s.Ag })
			}
			catch
			{
				$err = Resolve-sqmDagError -Message $_.Exception.Message
				& $add 'src.db' $cat 'Datenbankabfrage' 'Blocker' $false "Abfrage fehlgeschlagen: $($err.CauseDe)" "Query failed: $($err.CauseEn)" $err.FixDe $err.FixEn
			}
		}
	}

	# ---- Gegenseite: Version, Kollation, Dienstkonto ----
	if ($info['src'] -and $info['tgt'])
	{
		$sv = $null; $tv = $null
		try { $sv = [version]$info['src'].ProductVersion; $tv = [version]$info['tgt'].ProductVersion } catch { Write-Verbose $_.Exception.Message }
		if ($sv -and $tv)
		{
			& $add 'x.version' 'Quelle gegen Ziel' 'Versionen kompatibel' 'Blocker' ($tv.Major -ge $sv.Major) "Ziel $($tv.Major).x ist nicht älter als Quelle $($sv.Major).x." "Target $($tv.Major).x is not older than source $($sv.Major).x." `
				"Ziel ($($info['tgt'].ProductVersion)) ist älter als Quelle ($($info['src'].ProductVersion)). Datenbanken lassen sich nicht auf eine ältere Version übertragen." "Target ($($info['tgt'].ProductVersion)) is older than source ($($info['src'].ProductVersion)). Databases cannot be moved to an older version." 'Ziel mit gleicher oder neuerer Version aufbauen.' 'Build the target with the same or a newer version.'
		}
		$colSame = ($info['src'].Collation -eq $info['tgt'].Collation)
		& $add 'x.collation' 'Quelle gegen Ziel' 'Serverkollation' 'Warning' $colSame 'Kollationen sind gleich.' 'Collations match.' `
			"Kollation unterscheidet sich ($($info['src'].Collation) / $($info['tgt'].Collation))." "Collation differs ($($info['src'].Collation) / $($info['tgt'].Collation))." 'Datenbanken behalten ihre Kollation, tempdb-Verhalten und Joins mit Systemobjekten prüfen.' 'Databases keep their collation; check tempdb behavior and joins with system objects.'

		# Dienstkonto der Gegenseite benötigt CONNECT auf dem lokalen Endpoint
		foreach ($pair in @(@('src', 'tgt', $SourceInstance), @('tgt', 'src', $TargetInstance)))
		{
			try
			{
				$otherAcct = (& $q $pair[2] @"
SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'
"@ $null | Select-Object -First 1).service_account
				$otherInst = if ($pair[0] -eq 'src') { $TargetInstance } else { $SourceInstance }
				$thisAcct = (& $q $otherInst @"
SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'
"@ $null | Select-Object -First 1).service_account
				# otherAcct = Konto des Servers $pair[2]; es braucht CONNECT auf dem Endpoint der Gegenseite ($otherInst)
				$grantees = @(& $q $otherInst @"
SELECT sp.name AS Grantee FROM sys.server_permissions p
JOIN sys.server_principals sp ON sp.principal_id = p.grantee_principal_id
JOIN sys.endpoints e ON e.endpoint_id = p.major_id
WHERE p.class = 105 AND e.type = 4 AND p.permission_name = 'CONNECT' AND p.state IN ('G', 'W')
"@ $null | ForEach-Object { $_.Grantee })
				$ok = ($otherAcct -and ($grantees -contains $otherAcct -or $otherAcct -eq $thisAcct))
				& $add "x.connect.$($pair[0])" 'Endpoint-Berechtigung' "CONNECT für $otherAcct auf [$otherInst]" 'Warning' ([bool]$ok) "Dienstkonto [$otherAcct] darf sich mit [$otherInst] verbinden." "Service account [$otherAcct] may connect to [$otherInst]." `
					"Dienstkonto [$otherAcct] hat kein CONNECT auf dem Endpoint von [$otherInst]." "Service account [$otherAcct] has no CONNECT on the endpoint of [$otherInst]." 'Im Assistenten das Dienstkonto angeben, dann wird Login und GRANT CONNECT angelegt.' 'Enter the service account in the wizard; login and GRANT CONNECT are then created.'
			}
			catch { Write-Verbose $_.Exception.Message }
		}

		# ---- Zieldatenbanken, Pfade, Platz ----
		try
		{
			$tgtDbs = @(& $q $TargetInstance 'SELECT name FROM sys.databases' $null | ForEach-Object { $_.name })
			$tgtAgDbs = @(& $q $TargetInstance @"
SELECT adc.database_name AS name FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id WHERE ag.name = @n
"@ @{ n = $TargetAgName } | ForEach-Object { $_.name })
			$clash = @($srcDatabases | Where-Object { $tgtDbs -contains $_.DatabaseName -and $tgtAgDbs -notcontains $_.DatabaseName } | ForEach-Object { $_.DatabaseName })
			& $add 'tgt.dbclash' 'Ziel' 'Datenbanknamen auf dem Ziel frei' 'Blocker' ($clash.Count -eq 0) 'Keine Namenskonflikte auf dem Ziel.' 'No name conflicts on the target.' `
				"Diese Datenbanken existieren auf dem Ziel schon: $($clash -join ', ')" "These databases already exist on the target: $($clash -join ', ')" 'Datenbanken auf dem Ziel entfernen oder umbenennen (Seeding braucht ein leeres Ziel).' 'Drop or rename the databases on the target (seeding needs an empty target).'

			if ($srcFiles.Count -gt 0)
			{
				$dirs = @($srcFiles | ForEach-Object { [System.IO.Path]::GetDirectoryName($_.physical_name) } | Sort-Object -Unique)
				$missing = @()
				foreach ($d in $dirs)
				{
					$r = & $q $TargetInstance 'DECLARE @t TABLE (FileExists int, IsDir int, ParentExists int); INSERT @t EXEC master.dbo.xp_fileexist @d; SELECT IsDir FROM @t' @{ d = $d } | Select-Object -First 1
					if (-not $r -or $r.IsDir -ne 1) { $missing += $d }
				}
				& $add 'tgt.paths' 'Ziel' 'Dateipfade auf dem Ziel vorhanden' 'Warning' ($missing.Count -eq 0) 'Alle Quellpfade existieren auf dem Ziel.' 'All source paths exist on the target.' `
					"Auf dem Ziel fehlen: $($missing -join '; ')" "Missing on the target: $($missing -join '; ')" 'Pfade anlegen. Ab SQL 2017 nutzt Autoseed sonst die Standardpfade des Ziels.' 'Create the paths. From SQL 2017 autoseed otherwise uses the default paths of the target.'

				$vols = @(& $q $TargetInstance @"
SELECT DISTINCT vs.volume_mount_point, vs.available_bytes / 1048576 AS AvailableMB
FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
"@ $null)
				$short = @()
				foreach ($v in $vols)
				{
					$need = ($srcFiles | Where-Object { $_.physical_name -like "$($v.volume_mount_point)*" } | Measure-Object -Property SizeMB -Sum).Sum
					if ($need -and ($need * 1.1) -gt [double]$v.AvailableMB) { $short += "$($v.volume_mount_point) (benötigt ca. $([math]::Round($need)) MB, frei $($v.AvailableMB) MB)" }
				}
				& $add 'tgt.space' 'Ziel' 'Freier Platz auf dem Ziel' 'Warning' ($short.Count -eq 0) 'Genug freier Platz auf den Zielvolumes.' 'Enough free space on the target volumes.' `
					"Zu wenig Platz: $($short -join '; ')" "Not enough space: $($short -join '; ')" 'Platz schaffen oder Volume vergrößern.' 'Free up space or grow the volume.'
			}
		}
		catch
		{
			$err = Resolve-sqmDagError -Message $_.Exception.Message
			& $add 'tgt.dbcheck' 'Ziel' 'Zielprüfungen' 'Warning' $false "Prüfung unvollständig: $($err.CauseDe)" "Check incomplete: $($err.CauseEn)" $err.FixDe $err.FixEn
		}
	}

	# ---- Netz: DNS und Port (vom ausführenden Rechner) ----
	foreach ($f in @(@('src', $SourceFqdn), @('tgt', $TargetFqdn)))
	{
		if (-not $f[1]) { continue }
		$fq = $f[1]
		$resolved = $false
		try { $resolved = [bool]([System.Net.Dns]::GetHostAddresses($fq) | Select-Object -First 1) } catch { $resolved = $false }
		& $add "net.dns.$($f[0])" 'Netzwerk' "DNS [$fq]" 'Warning' $resolved "[$fq] wird aufgelöst." "[$fq] resolves." `
			"[$fq] ist von diesem Rechner nicht auflösbar." "[$fq] cannot be resolved from this machine." 'FQDN prüfen. Entscheidend ist die Auflösung durch den jeweils anderen SQL Server.' 'Check the FQDN. What matters is resolution from the other SQL Server.'
		if ($resolved)
		{
			$open = $false
			$tcp = New-Object System.Net.Sockets.TcpClient
			try
			{
				$iar = $tcp.BeginConnect($fq, $EndpointPort, $null, $null)
				$open = ($iar.AsyncWaitHandle.WaitOne(3000, $false) -and $tcp.Connected)
			}
			catch { $open = $false }
			finally { $tcp.Close() }
			& $add "net.port.$($f[0])" 'Netzwerk' "Port $EndpointPort auf [$fq]" 'Warning' $open "Port $EndpointPort ist erreichbar." "Port $EndpointPort is reachable." `
				"Port $EndpointPort auf [$fq] antwortet nicht von diesem Rechner." "Port $EndpointPort on [$fq] does not answer from this machine." 'Firewall zwischen den Clustern prüfen (Server zu Server).' 'Check the firewall between the clusters (server to server).'
		}
	}

	# ---- Backup-Pfad bei manuellem Seeding ----
	if ($SeedingMode -eq 'Manual')
	{
		$hasPath = [bool]$BackupPath
		& $add 'seed.path' 'Seeding' 'Backup-Pfad angegeben' 'Blocker' $hasPath "Backup-Pfad: $BackupPath" "Backup path: $BackupPath" `
			'Bei manuellem Seeding wird ein Backup-Pfad benötigt.' 'Manual seeding needs a backup path.' 'Pfad angeben (UNC empfohlen).' 'Enter a path (UNC recommended).'
		if ($hasPath)
		{
			$isUnc = ($BackupPath -like '\\*')
			& $add 'seed.unc' 'Seeding' 'Backup-Pfad ist UNC' 'Warning' $isUnc 'Der Pfad ist ein UNC-Pfad.' 'The path is a UNC path.' `
				'Ein Laufwerkspfad existiert auf Quelle und Ziel meist nicht identisch.' 'A drive path rarely exists identically on source and target.' 'UNC-Freigabe verwenden, auf die beide SQL-Dienstkonten zugreifen.' 'Use a UNC share that both SQL service accounts can access.'
			if ($isUnc)
			{
				$reach = $false
				try { $reach = [bool](Test-Path -LiteralPath $BackupPath -ErrorAction Stop) } catch { $reach = $false }
				& $add 'seed.reach' 'Seeding' 'Backup-Pfad erreichbar' 'Warning' $reach 'Der Pfad ist erreichbar.' 'The path is reachable.' `
					'Der Pfad ist von diesem Rechner nicht erreichbar.' 'The path is not reachable from this machine.' 'Freigabe und Berechtigungen prüfen (die SQL-Dienstkonten müssen schreiben und lesen).' 'Check share and permissions (the SQL service accounts must write and read).'
			}
		}
	}

	$blockers = @($checks | Where-Object { $_.Status -eq 'Fail' })
	$warnings = @($checks | Where-Object { $_.Status -eq 'Warn' })
	return [PSCustomObject]@{
		SourceInstance   = $SourceInstance
		SourceAgName     = $SourceAgName
		TargetInstance   = $TargetInstance
		TargetAgName     = $TargetAgName
		DistributedAgName = $dagName
		Checks           = $checks.ToArray()
		Blockers         = $blockers
		Warnings         = $warnings
		Passed           = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
		CanProceed       = ($blockers.Count -eq 0 -and $checks.Count -gt 0)
		SourceDatabases  = @($srcDatabases | ForEach-Object { $_.DatabaseName })
		Timestamp        = Get-Date
	}
}
