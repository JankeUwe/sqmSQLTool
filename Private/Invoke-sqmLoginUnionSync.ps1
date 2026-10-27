<#
.SYNOPSIS
    Union-Abgleich der Logins ueber alle Replikate einer AG (intern, fuer
    Sync-sqmLoginsToAlwaysOn -SyncMode Union).

.DESCRIPTION
    Logins gehoeren nicht zur AG. Die Primary-Rolle sagt nichts darueber, wo ein Login zuletzt
    angelegt wurde: wird ein Login auf A angelegt und schwenkt die AG vor dem naechsten Sync auf
    B, findet ein Primary->Secondary-Sync den Login nie. Deshalb hier:

    1. Fehlende Logins: jeder Login, der auf irgendeinem Replikat existiert, wird auf die
       Replikate kopiert, denen er fehlt (Copy-sqmLogins, nur anlegen, nie DROP).
    2. Tombstones: pro Replikat liegt in master.dbo.sqmLoginSyncState der zuletzt gesehene
       Login-Bestand. War ein Login dort schon einmal vorhanden und fehlt jetzt, wurde er auf
       diesem Replikat geloescht. Er wird dann NICHT wiederhergestellt, sondern gemeldet.
       Ist der Login auf allen Replikaten weg, wird der Eintrag entfernt.
    3. Erstlauf (Tabelle wird gerade angelegt): auf einem Secondary wird wie bisher kopiert. Auf
       dem Primary fehlende Logins werden nicht kopiert, sondern als Tombstone 'Baseline'
       vorgemerkt - frueher bewusst auf dem Primary geloeschte Logins kommen so nicht zurueck.
    4. Konflikte (gleicher Name, SID / Passwort-Hash / Standard-DB / Sprache / Deaktiviert
       unterschiedlich) werden nur gemeldet, nie geaendert. Widersprechen sich die Quellen bei
       SID oder Passwort, wird ein fehlender Login auch nicht kopiert.

    -ResetTombstone loescht die Eintraege der genannten Logins auf allen Replikaten vorab;
    danach gelten sie als nie gesehen und werden wieder kopiert.

.OUTPUTS
    Eine Zeile pro Aktion: Action (ReadReplica, Copy, Tombstone, Conflict, ResetTombstone,
    UpdateState), LoginName, SourceReplica, TargetReplica, Status (Success, Warning, Failed,
    Skipped, WhatIf), Message.
#>
function Invoke-sqmLoginUnionSync
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string[]]$Replica,

		[Parameter(Mandatory = $false)]
		[string]$PrimaryReplica,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$Login,

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[string[]]$ResetTombstone,

		[Parameter(Mandatory = $false)]
		[bool]$DisablePolicy = $true,

		[Parameter(Mandatory = $false)]
		[switch]$AdjustAuthMode,

		[Parameter(Mandatory = $false)]
		[switch]$RestartServiceIfRequired,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Install', 'Skip', 'Abort')]
		[string]$AdModuleAction
	)

	$functionName = 'Invoke-sqmLoginUnionSync'
	# Lokale Kopien: die Hilfsfunktionen unten lesen sie per dynamischem Scope.
	$agName = $AvailabilityGroupName
	$includePatterns = $Login
	$excludePatterns = $ExcludeLogin
	$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
	$stateTable = 'master.dbo.sqmLoginSyncState'

	function _Row
	{
		param ([string]$Action, [string]$LoginName, [string]$Source, [string]$Target, [string]$Status, [string]$Message)
		$rows.Add([PSCustomObject]@{
			AvailabilityGroup = $agName
			SyncMode          = 'Union'
			Action            = $Action
			LoginName         = $LoginName
			SourceReplica     = $Source
			TargetReplica     = $Target
			Status            = $Status
			Message           = $Message
			Timestamp         = Get-Date
		})
		$level = switch ($Status) { 'Failed' { 'ERROR' } 'Warning' { 'WARNING' } default { 'INFO' } }
		Invoke-sqmLogging -Message "[$Action] $LoginName $Source -> ${Target}: $Status - $Message" -FunctionName $functionName -Level $level
	}

	function _MatchesAny
	{
		param ([string]$Name, [string[]]$Patterns)
		foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
		return $false
	}

	function _SidHex
	{
		param ($Sid)
		if ($null -eq $Sid -or $Sid -is [System.DBNull]) { return '' }
		return '0x' + (($Sid | ForEach-Object { $_.ToString('X2') }) -join '')
	}

	$createSql = @"
IF OBJECT_ID(N'$stateTable', N'U') IS NULL
BEGIN
    CREATE TABLE $stateTable (
        login_name sysname        NOT NULL PRIMARY KEY,
        sid        varbinary(85)  NULL,
        first_seen datetime2(0)   NOT NULL,
        last_seen  datetime2(0)   NOT NULL,
        dropped_at datetime2(0)   NULL,
        note       nvarchar(200)  NULL
    );
    SELECT CAST(1 AS int) AS Created;
END
ELSE
    SELECT CAST(0 AS int) AS Created;
"@
	$existsSql = "SELECT CASE WHEN OBJECT_ID(N'$stateTable', N'U') IS NULL THEN 1 ELSE 0 END AS Created"
	$stateSql = "SELECT login_name, sid, dropped_at, note FROM $stateTable"

	# sa (SID 0x01) und ##MS_* nie: sa hat auf jeder Instanz ein eigenes Passwort, ##MS_* sind
	# Zertifikats-Logins der Instanz.
	$loginSql = @"
SELECT sp.name,
       sp.sid,
       sp.type,
       sp.is_disabled,
       sp.default_database_name,
       sp.default_language_name,
       CONVERT(varchar(514), sl.password_hash, 1) AS pwd_hash,
       CAST(LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS datetime) AS pwd_set,
       IS_SRVROLEMEMBER('sysadmin', sp.name) AS is_sysadmin,
       CAST(SERVERPROPERTY('MachineName') AS sysname) AS machine
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S', 'U', 'G')
  AND sp.sid <> 0x01
  AND sp.name NOT LIKE '##%'
"@

	# ------------------------------------------------------------------
	# 1. Alle Replikate lesen: Logins, Snapshot, ggf. Tombstones zuruecksetzen
	# ------------------------------------------------------------------
	$info = [ordered]@{}
	foreach ($r in $Replica)
	{
		$conn = @{ SqlInstance = $r }
		if ($SqlCredential) { $conn['SqlCredential'] = $SqlCredential }
		try
		{
			$baseline = $false
			if ($WhatIfPreference)
			{
				$baseline = [bool]((Invoke-DbaQuery @conn -Query $existsSql -EnableException).Created)
			}
			else
			{
				$baseline = [bool]((Invoke-DbaQuery @conn -Query $createSql -EnableException).Created)
				if ($baseline)
				{
					Invoke-sqmLogging -Message "[$r] $stateTable angelegt (Erstlauf)." -FunctionName $functionName -Level 'INFO'
				}
			}

			if ($ResetTombstone -and -not $baseline)
			{
				foreach ($t in $ResetTombstone)
				{
					if ($PSCmdlet.ShouldProcess("$r / $t", 'Tombstone zuruecksetzen'))
					{
						Invoke-DbaQuery @conn -Query "DELETE FROM $stateTable WHERE login_name = @n" -SqlParameter @{ n = $t } -EnableException
						_Row 'ResetTombstone' $t '' $r 'Success' 'Snapshot-Eintrag entfernt, Login gilt als nie gesehen.'
					}
				}
			}

			$state = @{}
			if (-not ($WhatIfPreference -and $baseline))
			{
				foreach ($s in @(Invoke-DbaQuery @conn -Query $stateSql -EnableException))
				{
					$state[[string]$s.login_name] = $s
				}
			}

			$logins = @{}
			$machine = $null
			foreach ($l in @(Invoke-DbaQuery @conn -Query $loginSql -EnableException))
			{
				$logins[[string]$l.name] = $l
				$machine = [string]$l.machine
			}

			$info[$r] = [PSCustomObject]@{
				Name     = $r
				Conn     = $conn
				Baseline = $baseline
				State    = $state
				Logins   = $logins
				Machine  = $machine
			}
		}
		catch
		{
			_Row 'ReadReplica' '(alle)' '' $r 'Failed' "Replikat nicht lesbar, wird in diesem Lauf ausgelassen: $($_.Exception.Message)"
		}
	}

	if ($info.Count -lt 2)
	{
		_Row 'ReadReplica' '(alle)' '' '(alle)' 'Failed' "Nur $($info.Count) von $($Replica.Count) Replikat(en) lesbar - kein Abgleich moeglich."
		return $rows
	}
	$allReachable = ($info.Count -eq $Replica.Count)

	# Lokale Windows-Konten (MACHINE\user) gibt es nur auf ihrem Host - nie kopieren.
	$machinePatterns = @($info.Values | Where-Object { $_.Machine } | ForEach-Object { "$($_.Machine)\*" })
	$systemPatterns = @('NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*')

	function _InScope
	{
		param ($Row)
		$n = [string]$Row.name
		if (_MatchesAny $n $machinePatterns) { return $false }
		if (-not $IncludeSystemLogins)
		{
			if (_MatchesAny $n $systemPatterns) { return $false }
			if ($Row.is_sysadmin -eq 1) { return $false }
		}
		if ($includePatterns -and -not (_MatchesAny $n $includePatterns)) { return $false }
		if ($excludePatterns -and (_MatchesAny $n $excludePatterns)) { return $false }
		return $true
	}

	# ------------------------------------------------------------------
	# 2. Tombstones pro Replikat: im Snapshot bekannt, jetzt nicht mehr vorhanden
	# ------------------------------------------------------------------
	$tombstones = @{}
	foreach ($ri in $info.Values)
	{
		$t = @{}
		foreach ($name in $ri.State.Keys)
		{
			if ($ri.Logins.ContainsKey($name)) { continue }
			$s = $ri.State[$name]
			$since = if ($s.dropped_at -is [datetime]) { $s.dropped_at.ToString('yyyy-MM-dd HH:mm') } else { 'jetzt' }
			$t[$name] = if ($s.note -eq 'Baseline') { "beim Erstlauf ($since) auf dem Primary fehlend vorgefunden" } else { "geloescht (erkannt $since)" }
		}
		$tombstones[$ri.Name] = $t
	}

	# ------------------------------------------------------------------
	# 3. Pro Login: Konflikte melden, fehlende Logins einplanen
	# ------------------------------------------------------------------
	$names = @{}
	foreach ($ri in $info.Values)
	{
		foreach ($l in $ri.Logins.Values) { if (_InScope $l) { $names[[string]$l.name] = $true } }
	}

	$plan = [ordered]@{}
	$newBaselineTombstones = @{}
	foreach ($name in ($names.Keys | Sort-Object))
	{
		$holders = @($info.Values | Where-Object { $_.Logins.ContainsKey($name) })
		$missing = @($info.Values | Where-Object { -not $_.Logins.ContainsKey($name) })

		$sidDiff = $false
		$pwdDiff = $false
		if ($holders.Count -gt 1)
		{
			$diffs = [System.Collections.Generic.List[string]]::new()
			$first = $holders[0].Logins[$name]
			$sidDiff = @($holders | ForEach-Object { _SidHex $_.Logins[$name].sid } | Sort-Object -Unique).Count -gt 1
			if ($sidDiff)
			{
				$diffs.Add('SID (' + (($holders | ForEach-Object { "$($_.Name)=$(_SidHex $_.Logins[$name].sid)" }) -join ', ') + ')')
			}
			if ([string]$first.type -eq 'S')
			{
				$pwdDiff = @($holders | ForEach-Object { [string]$_.Logins[$name].pwd_hash } | Sort-Object -Unique).Count -gt 1
				if ($pwdDiff)
				{
					$diffs.Add('Passwort-Hash (zuletzt gesetzt: ' + (($holders | ForEach-Object {
						$ps = $_.Logins[$name].pwd_set
						"$($_.Name)=$(if ($ps -is [datetime]) { $ps.ToString('yyyy-MM-dd HH:mm') } else { '?' })"
					}) -join ', ') + ')')
				}
			}
			foreach ($prop in 'default_database_name', 'default_language_name', 'is_disabled')
			{
				if (@($holders | ForEach-Object { [string]$_.Logins[$name].$prop } | Sort-Object -Unique).Count -gt 1)
				{
					$diffs.Add("$prop (" + (($holders | ForEach-Object { "$($_.Name)=$($_.Logins[$name].$prop)" }) -join ', ') + ')')
				}
			}
			if ($diffs.Count -gt 0)
			{
				_Row 'Conflict' $name '' '(alle)' 'Warning' ("Abweichung, wird nicht geaendert: " + ($diffs -join '; '))
			}
		}

		foreach ($target in $missing)
		{
			$holderNames = ($holders | ForEach-Object { $_.Name }) -join ', '
			if ($tombstones[$target.Name].ContainsKey($name))
			{
				_Row 'Tombstone' $name $holderNames $target.Name 'Warning' ("Nicht wiederhergestellt: auf $($target.Name) $($tombstones[$target.Name][$name]), existiert noch auf $holderNames. " +
					"Entweder dort ebenfalls loeschen oder mit -ResetTombstone '$name' wieder verteilen.")
				continue
			}
			if ($target.Baseline -and $PrimaryReplica -and $target.Name -eq $PrimaryReplica)
			{
				$newBaselineTombstones[$name] = $true
				_Row 'Tombstone' $name $holderNames $target.Name 'Warning' ("Erstlauf: fehlt auf dem Primary, existiert auf $holderNames. Nicht kopiert, weil unklar ist, ob er auf dem Primary bewusst geloescht wurde. " +
					"Zum Verteilen: -ResetTombstone '$name'.")
				continue
			}
			if ($sidDiff -or $pwdDiff)
			{
				_Row 'Conflict' $name $holderNames $target.Name 'Warning' 'Nicht kopiert: die Quellen haben unterschiedliche SID oder Passwort.'
				continue
			}
			$src = if ($PrimaryReplica -and ($holders | Where-Object { $_.Name -eq $PrimaryReplica })) { $PrimaryReplica } else { $holders[0].Name }
			$key = "$src|$($target.Name)"
			if (-not $plan.Contains($key)) { $plan[$key] = [System.Collections.Generic.List[string]]::new() }
			$plan[$key].Add($name)
		}
	}

	# ------------------------------------------------------------------
	# 4. Kopieren (nur anlegen - Copy-sqmLogins ohne -Force)
	# ------------------------------------------------------------------
	foreach ($key in $plan.Keys)
	{
		$src, $dst = $key -split '\|', 2
		$list = @($plan[$key])
		if (-not $PSCmdlet.ShouldProcess($dst, "$($list.Count) fehlende(n) Login(s) von $src anlegen: $($list -join ', ')"))
		{
			foreach ($n in $list) { _Row 'Copy' $n $src $dst 'WhatIf' 'Wuerde angelegt.' }
			continue
		}

		$copyParams = @{
			Source                   = $src
			Destination              = $dst
			Login                    = @($list | ForEach-Object { [System.Management.Automation.WildcardPattern]::Escape($_) })
			IncludeSystemLogins      = $IncludeSystemLogins
			DisablePolicy            = $DisablePolicy
			AdjustAuthMode           = $AdjustAuthMode
			RestartServiceIfRequired = $RestartServiceIfRequired
			ContinueOnError          = $true
			Confirm                  = $false
		}
		if ($SqlCredential) { $copyParams['SqlCredential'] = $SqlCredential }
		if ($AdModuleAction) { $copyParams['AdModuleAction'] = $AdModuleAction }

		try
		{
			$copyResult = @(Copy-sqmLogins @copyParams)
			$reported = @{}
			foreach ($c in $copyResult)
			{
				if ($c.Action -in @('CopyLogin', 'AdCheck') -and $list -contains $c.LoginName)
				{
					$st = if ($c.Status -eq 'Success') { 'Success' } elseif ($c.Status -in @('AdOrphan', 'AdQueryFailed')) { 'Warning' } else { [string]$c.Status }
					_Row 'Copy' $c.LoginName $src $dst $st ([string]$c.Message)
					$reported[$c.LoginName] = $true
				}
				elseif ($c.Status -eq 'Failed')
				{
					_Row 'Copy' ([string]$c.LoginName) $src $dst 'Failed' "$($c.Action): $($c.Message)"
				}
			}
			foreach ($n in $list)
			{
				if (-not $reported.ContainsKey($n) -and -not ($copyResult | Where-Object { $_.Status -eq 'Failed' }))
				{
					_Row 'Copy' $n $src $dst 'Skipped' 'Von Copy-sqmLogins nicht verarbeitet (Filter der Quelle).'
				}
			}
		}
		catch
		{
			foreach ($n in $list) { _Row 'Copy' $n $src $dst 'Failed' $_.Exception.Message }
		}
	}

	# ------------------------------------------------------------------
	# 5. Snapshot pro Replikat fortschreiben (nach dem Kopieren neu gelesen)
	# ------------------------------------------------------------------
	if ($WhatIfPreference) { return $rows }

	# Ueberall weg (und alle Replikate gelesen): Tombstone hat sich erledigt.
	$purge = @{}
	if ($allReachable)
	{
		foreach ($ri in $info.Values)
		{
			foreach ($name in $ri.State.Keys)
			{
				if (-not ($info.Values | Where-Object { $_.Logins.ContainsKey($name) })) { $purge[$name] = $true }
			}
		}
	}

	$updateSql = @"
DECLARE @x xml = CAST(@list AS xml);
DECLARE @now datetime2(0) = SYSDATETIME();
DECLARE @cur TABLE (login_name sysname PRIMARY KEY, sid varbinary(85) NULL);
DECLARE @base TABLE (login_name sysname PRIMARY KEY);
DECLARE @purge TABLE (login_name sysname PRIMARY KEY);
INSERT @cur (login_name, sid)
SELECT n.value('@n', 'nvarchar(128)'), CONVERT(varbinary(85), NULLIF(n.value('@s', 'varchar(200)'), ''), 1)
FROM @x.nodes('/r/l') t(n);
INSERT @base (login_name) SELECT n.value('@n', 'nvarchar(128)') FROM @x.nodes('/r/b') t(n);
INSERT @purge (login_name) SELECT n.value('@n', 'nvarchar(128)') FROM @x.nodes('/r/p') t(n);

UPDATE s SET last_seen = @now, dropped_at = NULL, note = NULL, sid = c.sid
FROM $stateTable s JOIN @cur c ON c.login_name = s.login_name;

INSERT $stateTable (login_name, sid, first_seen, last_seen)
SELECT c.login_name, c.sid, @now, @now FROM @cur c
WHERE NOT EXISTS (SELECT 1 FROM $stateTable s WHERE s.login_name = c.login_name);

UPDATE s SET dropped_at = @now
FROM $stateTable s
WHERE s.dropped_at IS NULL AND NOT EXISTS (SELECT 1 FROM @cur c WHERE c.login_name = s.login_name);

INSERT $stateTable (login_name, sid, first_seen, last_seen, dropped_at, note)
SELECT b.login_name, NULL, @now, @now, @now, N'Baseline' FROM @base b
WHERE NOT EXISTS (SELECT 1 FROM $stateTable s WHERE s.login_name = b.login_name);

DELETE s FROM $stateTable s JOIN @purge p ON p.login_name = s.login_name
WHERE NOT EXISTS (SELECT 1 FROM @cur c WHERE c.login_name = s.login_name);
"@

	foreach ($ri in $info.Values)
	{
		$conn = $ri.Conn
		try
		{
			$now = @(Invoke-DbaQuery @conn -Query $loginSql -EnableException)
			$sb = [System.Text.StringBuilder]::new('<r>')
			foreach ($l in $now)
			{
				[void]$sb.Append("<l n=""$([System.Security.SecurityElement]::Escape([string]$l.name))"" s=""$(_SidHex $l.sid)""/>")
			}
			if ($ri.Baseline -and $PrimaryReplica -and $ri.Name -eq $PrimaryReplica)
			{
				foreach ($n in $newBaselineTombstones.Keys) { [void]$sb.Append("<b n=""$([System.Security.SecurityElement]::Escape($n))""/>") }
			}
			foreach ($n in $purge.Keys) { [void]$sb.Append("<p n=""$([System.Security.SecurityElement]::Escape($n))""/>") }
			[void]$sb.Append('</r>')

			Invoke-DbaQuery @conn -Query $updateSql -SqlParameter @{ list = $sb.ToString() } -EnableException
			Invoke-sqmLogging -Message "[$($ri.Name)] Snapshot fortgeschrieben ($($now.Count) Login(s), $($purge.Count) erledigte Tombstone(s) entfernt)." -FunctionName $functionName -Level 'VERBOSE'
		}
		catch
		{
			_Row 'UpdateState' '(alle)' '' $ri.Name 'Failed' "Snapshot nicht fortgeschrieben: $($_.Exception.Message)"
		}
	}

	return $rows
}
