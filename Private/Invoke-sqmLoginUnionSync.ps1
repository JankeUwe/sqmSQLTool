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
       diesem Replikat geloescht. Er wird dann NICHT wiederhergestellt, sondern gemeldet. Das gilt
       nur bei gleicher SID: ein ueberall geloeschter und neu angelegter SQL-Login (neue SID) wird
       normal verteilt.
       Ist der Login auf allen Replikaten weg, wird der Eintrag entfernt.
    3. Erstlauf (Tabelle wird gerade angelegt): auf einem Secondary wird wie bisher kopiert. Auf
       dem Primary fehlende Logins werden nicht kopiert, sondern als Tombstone 'Baseline'
       vorgemerkt - frueher bewusst auf dem Primary geloeschte Logins kommen so nicht zurueck.
    4. Passwortaenderungen (-HashChange Newest, Standard): gleicher SQL-Login mit gleicher
       SID, aber unterschiedlichem Passwort-Hash. Eine Aenderung wird NICHT am Hash erkannt,
       sondern daran, dass LOGINPROPERTY PasswordLastSetTime (in UTC) auf einem Replikat seit dem
       letzten Lauf gestiegen ist (Spalte pwd_set_utc im Snapshot). Grund: SQL Server 2025
       schreibt einen aelteren Hash (0x0200) bei der naechsten Anmeldung ins neue Format (0x0300)
       um, ohne PasswordLastSetTime zu aendern; gleiche Passwoerter haben dann verschiedene Hashes.
       Ohne erkannte Aenderung (z. B. erster Lauf) wird nur bei gleichem Hash-Format verglichen,
       dann gewinnt das zuletzt gesetzte Passwort. Uebernahme per ALTER LOGIN ... WITH PASSWORD =
       <hash> HASHED, ohne DROP. HASHED ist mit CHECK_POLICY = ON nicht erlaubt: CHECK_POLICY/
       CHECK_EXPIRATION werden fuer die Aenderung abgeschaltet und danach auf den vorherigen Stand
       gesetzt. Liegen zwei konkurrierende Aenderungen weniger als 60 Sekunden auseinander, ist
       der Gewinner unklar: dann nur Meldung. Ein 0x0300-Hash wird nie auf ein Replikat unter SQL
       Server 2025 geschrieben (Meldung, Passwort dort von Hand setzen). Vorher wird pro Ziel ein
       Rollback-Skript mit den alten Hashes geschrieben (LoginBackup_PasswordRollback_*.sql).
       -HashChange Report: nur melden.
    5. Sonstige Konflikte (SID / Standard-DB / Sprache / Deaktiviert unterschiedlich) werden nur
       gemeldet, nie geaendert. Bei unterschiedlicher SID wird ein fehlender Login nicht kopiert.

    -ResetTombstone loescht die Eintraege der genannten Logins auf allen Replikaten vorab;
    danach gelten sie als nie gesehen und werden wieder kopiert.

.OUTPUTS
    Eine Zeile pro Aktion: Action (ReadReplica, Copy, PasswordSync, Tombstone, Conflict,
    ResetTombstone, UpdateState), LoginName, SourceReplica, TargetReplica, Status (Success, Warning, Failed,
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
		[string]$AdModuleAction,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Newest', 'Report')]
		[string]$HashChange = 'Newest',

		[Parameter(Mandatory = $false)]
		[string]$BackupPath,

		[Parameter(Mandatory = $false)]
		[switch]$NoReport
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
DECLARE @created int = 0;
IF OBJECT_ID(N'$stateTable', N'U') IS NULL
BEGIN
    CREATE TABLE $stateTable (
        login_name  sysname        NOT NULL PRIMARY KEY,
        sid         varbinary(85)  NULL,
        first_seen  datetime2(0)   NOT NULL,
        last_seen   datetime2(0)   NOT NULL,
        dropped_at  datetime2(0)   NULL,
        note        nvarchar(200)  NULL,
        pwd_set_utc datetime2(3)   NULL
    );
    SET @created = 1;
END
-- Tabellen aus v1.9.191.0 haben die Spalte noch nicht.
IF COL_LENGTH(N'$stateTable', 'pwd_set_utc') IS NULL
    ALTER TABLE $stateTable ADD pwd_set_utc datetime2(3) NULL;
SELECT @created AS Created;
"@
	$existsSql = "SELECT CASE WHEN OBJECT_ID(N'$stateTable', N'U') IS NULL THEN 1 ELSE 0 END AS Created"
	# Dynamisch, weil die Spalte unter -WhatIf (keine Aenderung an der Tabelle) noch fehlen kann.
	$stateSql = "IF COL_LENGTH(N'$stateTable', 'pwd_set_utc') IS NULL EXEC(N'SELECT login_name, sid, dropped_at, note, CAST(NULL AS datetime2(3)) AS pwd_set_utc FROM $stateTable') " +
		"ELSE EXEC(N'SELECT login_name, sid, dropped_at, note, pwd_set_utc FROM $stateTable')"

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
       DATEADD(minute, -DATEDIFF(minute, GETUTCDATE(), GETDATE()), CAST(LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS datetime)) AS pwd_set_utc,
       CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS major_version,
       sl.is_policy_checked,
       sl.is_expiration_checked,
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
			$major = 0
			foreach ($l in @(Invoke-DbaQuery @conn -Query $loginSql -EnableException))
			{
				$logins[[string]$l.name] = $l
				$machine = [string]$l.machine
				$major = [int]$l.major_version
			}

			$info[$r] = [PSCustomObject]@{
				Name     = $r
				Conn     = $conn
				Baseline = $baseline
				State    = $state
				Logins   = $logins
				Machine  = $machine
				Major    = $major
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
			$text = if ($s.note -eq 'Baseline') { "beim Erstlauf ($since) auf dem Primary fehlend vorgefunden" } else { "geloescht (erkannt $since)" }
			$t[$name] = [PSCustomObject]@{ Text = $text; Sid = (_SidHex $s.sid) }
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
	$pwPlan = [System.Collections.Generic.List[PSCustomObject]]::new()
	$newBaselineTombstones = @{}
	foreach ($name in ($names.Keys | Sort-Object))
	{
		$holders = @($info.Values | Where-Object { $_.Logins.ContainsKey($name) })
		$missing = @($info.Values | Where-Object { -not $_.Logins.ContainsKey($name) })

		$sidDiff = $false
		$pwdDiff = $false
		$pwWinner = $null
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
					# Pro Replikat: PasswordLastSetTime in UTC und ob er seit dem letzten Lauf gestiegen ist.
					$times = @($holders | ForEach-Object {
						$l = $_.Logins[$name]
						$st = $_.State[$name]
						$utc = if ($l.pwd_set_utc -is [datetime]) { [datetime]$l.pwd_set_utc } else { $null }
						$last = if ($st -and $st.pwd_set_utc -is [datetime]) { [datetime]$st.pwd_set_utc } else { $null }
						$hash = [string]$l.pwd_hash
						[PSCustomObject]@{
							Replica = $_
							Utc     = $utc
							Changed = ($utc -and $last -and ($utc - $last).TotalSeconds -ge 1)
							Hash    = $hash
							Format  = if ($hash.Length -ge 4) { $hash.Substring(0, 4).ToUpper() } else { '' }
						}
					} | Sort-Object -Property @{ Expression = { if ($_.Utc) { $_.Utc } else { [datetime]::MinValue } } } -Descending)
					$timeText = ($times | ForEach-Object { "$($_.Replica.Name)=$(if ($_.Utc) { $_.Utc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' } else { '?' })$(if ($_.Changed) { ' (geaendert)' })" }) -join ', '

					# Kandidaten: Replikate mit erkannter Aenderung. Ohne Aenderung nur bei gleichem
					# Hash-Format vergleichen - 0x0200 und 0x0300 koennen dasselbe Passwort sein.
					$changed = @($times | Where-Object { $_.Changed })
					$sameFormat = @($times | ForEach-Object { $_.Format } | Sort-Object -Unique).Count -eq 1
					$candidates = if ($changed.Count -gt 0) { $changed } elseif ($sameFormat) { $times } else { @() }

					if ($candidates.Count -eq 0)
					{
						# Nur unterschiedliches Hash-Format (Umschreibung durch SQL Server 2025), keine
						# neue Aenderung: nichts zu tun, auch kein Konflikt fuer fehlende Logins.
						$pwdDiff = $false
					}
					else
					{
						$top = $candidates[0]
						$rivals = @($candidates | Where-Object { $_.Hash -ne $top.Hash })
						$clear = $top.Utc -and ($rivals.Count -eq 0 -or -not $rivals[0].Utc -or ($top.Utc - $rivals[0].Utc).TotalSeconds -ge 60)

						if ($HashChange -eq 'Newest' -and -not $sidDiff -and $clear -and $top.Hash -match '^0x[0-9A-Fa-f]+$')
						{
							$pwWinner = $top.Replica
							foreach ($t in $times)
							{
								if ($t.Hash -eq $top.Hash) { continue }
								$l = $t.Replica.Logins[$name]
								# 0x0300 (PBKDF2) kennt erst SQL Server 2025 (Hauptversion 17).
								if ($top.Format -eq '0X03' -and $t.Replica.Major -lt 17)
								{
									_Row 'PasswordSync' $name $pwWinner.Name $t.Replica.Name 'Warning' ("Nicht uebernommen: das neue Passwort liegt auf $($pwWinner.Name) nur im Hash-Format 0x0300 (SQL Server 2025) vor, " +
										"$($t.Replica.Name) (Version $($t.Replica.Major)) kann es nicht lesen. Passwort dort von Hand setzen ($timeText).")
									continue
								}
								$pwPlan.Add([PSCustomObject]@{
									Name       = $name
									Source     = $pwWinner.Name
									Target     = $t.Replica
									NewHash    = $top.Hash
									OldHash    = $t.Hash
									Policy     = ($l.is_policy_checked -eq $true)
									Expiration = ($l.is_expiration_checked -eq $true)
									Times      = $timeText
								})
							}
						}
						else
						{
							$why = if ($HashChange -eq 'Report') { 'nur gemeldet (-HashChange Report)' }
							elseif ($sidDiff) { 'nicht uebernommen, SID unterschiedlich' }
							else { 'nicht uebernommen, juengste Aenderung nicht eindeutig (unter 60 s Abstand oder Zeitpunkt fehlt)' }
							$diffs.Add("Passwort-Hash $why (zuletzt gesetzt: $timeText)")
						}
					}
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
			# Tombstone nur bei gleicher SID: ein ueberall geloeschter und auf einem Replikat neu
			# angelegter SQL-Login hat eine neue SID und ist ein anderer Login.
			$tomb = $tombstones[$target.Name][$name]
			if ($tomb -and (-not $tomb.Sid -or (@($holders | ForEach-Object { _SidHex $_.Logins[$name].sid }) -contains $tomb.Sid)))
			{
				_Row 'Tombstone' $name $holderNames $target.Name 'Warning' ("Nicht wiederhergestellt: auf $($target.Name) $($tomb.Text), existiert noch auf $holderNames. " +
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
			if ($sidDiff -or ($pwdDiff -and -not $pwWinner))
			{
				_Row 'Conflict' $name $holderNames $target.Name 'Warning' 'Nicht kopiert: die Quellen haben unterschiedliche SID oder Passwort.'
				continue
			}
			$src = if ($pwWinner) { $pwWinner.Name }
			elseif ($PrimaryReplica -and ($holders | Where-Object { $_.Name -eq $PrimaryReplica })) { $PrimaryReplica }
			else { $holders[0].Name }
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
	# 5. Passwortaenderungen uebernehmen (ALTER LOGIN ... HASHED, kein DROP)
	# ------------------------------------------------------------------
	foreach ($grp in ($pwPlan | Group-Object -Property { $_.Target.Name }))
	{
		$tgt = $grp.Group[0].Target
		$items = @($grp.Group)
		if (-not $PSCmdlet.ShouldProcess($tgt.Name, "Passwort von $($items.Count) Login(s) auf den zuletzt gesetzten Stand bringen: $(($items | ForEach-Object { $_.Name }) -join ', ')"))
		{
			foreach ($it in $items) { _Row 'PasswordSync' $it.Name $it.Source $tgt.Name 'WhatIf' "Wuerde uebernommen ($($it.Times))." }
			continue
		}

		# Rollback-Skript mit den bisherigen Hashes, bevor etwas geaendert wird.
		if ($BackupPath -and -not $NoReport)
		{
			try
			{
				if (-not (Test-Path $BackupPath)) { New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null }
				$rbFile = Join-Path $BackupPath ("LoginBackup_PasswordRollback_{0}_{1}.sql" -f ($tgt.Name -replace '[\\/:*?"<>|,]', '_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
				$rb = [System.Text.StringBuilder]::new()
				[void]$rb.AppendLine("-- Rollback Passwortuebernahme auf $($tgt.Name), $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
				foreach ($it in $items)
				{
					$q = '[' + ($it.Name -replace '\]', ']]') + ']'
					[void]$rb.AppendLine("ALTER LOGIN $q WITH CHECK_POLICY = OFF;")
					[void]$rb.AppendLine("ALTER LOGIN $q WITH PASSWORD = $($it.OldHash) HASHED;")
					[void]$rb.AppendLine("ALTER LOGIN $q WITH CHECK_POLICY = $(if ($it.Policy) { 'ON' } else { 'OFF' }), CHECK_EXPIRATION = $(if ($it.Expiration) { 'ON' } else { 'OFF' });")
				}
				[System.IO.File]::WriteAllText($rbFile, $rb.ToString(), [System.Text.Encoding]::UTF8)
				Invoke-sqmLogging -Message "[$($tgt.Name)] Rollback-Skript fuer Passwortuebernahme: $rbFile" -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				foreach ($it in $items) { _Row 'PasswordSync' $it.Name $it.Source $tgt.Name 'Failed' "Nicht uebernommen: Rollback-Skript konnte nicht geschrieben werden: $($_.Exception.Message)" }
				continue
			}
		}

		# Eine konfigurierte PBM-Policy (On Change: Prevent) wuerde ALTER LOGIN blockieren -
		# wie in Copy-sqmLogins kurz deaktivieren, im finally wieder aktivieren.
		$policyOff = $false
		$conn = $tgt.Conn
		try
		{
			$defaultPolicy = Get-sqmConfig -Key 'DefaultPolicy' 3>$null
			if ($DisablePolicy -and -not [string]::IsNullOrWhiteSpace($defaultPolicy))
			{
				$polParams = @{ SqlInstance = $tgt.Name; State = 'Disable' }
				if ($SqlCredential) { $polParams['SqlCredential'] = $SqlCredential }
				$policyOff = (@(Set-sqmSqlPolicyState @polParams)[0].Status -eq 'Success')
			}

			foreach ($it in $items)
			{
				$q = '[' + ($it.Name -replace '\]', ']]') + ']'
				$restore = "CHECK_POLICY = $(if ($it.Policy) { 'ON' } else { 'OFF' }), CHECK_EXPIRATION = $(if ($it.Expiration) { 'ON' } else { 'OFF' })"
				$alterSql = "BEGIN TRY ALTER LOGIN $q WITH CHECK_POLICY = OFF; ALTER LOGIN $q WITH PASSWORD = $($it.NewHash) HASHED; ALTER LOGIN $q WITH $restore; END TRY " +
					"BEGIN CATCH ALTER LOGIN $q WITH $restore; THROW; END CATCH"
				try
				{
					Invoke-DbaQuery @conn -Query $alterSql -EnableException
					_Row 'PasswordSync' $it.Name $it.Source $tgt.Name 'Success' "Passwort vom zuletzt geaenderten Replikat uebernommen ($($it.Times))."
				}
				catch
				{
					_Row 'PasswordSync' $it.Name $it.Source $tgt.Name 'Failed' "ALTER LOGIN fehlgeschlagen: $($_.Exception.Message)"
				}
			}
		}
		finally
		{
			if ($policyOff)
			{
				$polParams['State'] = 'Enable'
				try { Set-sqmSqlPolicyState @polParams | Out-Null }
				catch
				{
					_Row 'PasswordSync' '(Policy)' '' $tgt.Name 'Failed' "KRITISCH: Policy konnte nicht wieder aktiviert werden: $($_.Exception.Message)"
				}
			}
		}
	}

	# ------------------------------------------------------------------
	# 6. Snapshot pro Replikat fortschreiben (nach dem Kopieren neu gelesen)
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
DECLARE @cur TABLE (login_name sysname PRIMARY KEY, sid varbinary(85) NULL, pwd_set_utc datetime2(3) NULL);
DECLARE @base TABLE (login_name sysname PRIMARY KEY);
DECLARE @purge TABLE (login_name sysname PRIMARY KEY);
INSERT @cur (login_name, sid, pwd_set_utc)
SELECT n.value('@n', 'nvarchar(128)'), CONVERT(varbinary(85), NULLIF(n.value('@s', 'varchar(200)'), ''), 1),
       CONVERT(datetime2(3), NULLIF(n.value('@t', 'varchar(30)'), ''), 126)
FROM @x.nodes('/r/l') t(n);
INSERT @base (login_name) SELECT n.value('@n', 'nvarchar(128)') FROM @x.nodes('/r/b') t(n);
INSERT @purge (login_name) SELECT n.value('@n', 'nvarchar(128)') FROM @x.nodes('/r/p') t(n);

UPDATE s SET last_seen = @now, dropped_at = NULL, note = NULL, sid = c.sid, pwd_set_utc = c.pwd_set_utc
FROM $stateTable s JOIN @cur c ON c.login_name = s.login_name;

INSERT $stateTable (login_name, sid, first_seen, last_seen, pwd_set_utc)
SELECT c.login_name, c.sid, @now, @now, c.pwd_set_utc FROM @cur c
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
				$t = if ($l.pwd_set_utc -is [datetime]) { ([datetime]$l.pwd_set_utc).ToString('yyyy-MM-ddTHH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
				[void]$sb.Append("<l n=""$([System.Security.SecurityElement]::Escape([string]$l.name))"" s=""$(_SidHex $l.sid)"" t=""$t""/>")
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
