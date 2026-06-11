<#
.SYNOPSIS
    Vergleicht die Logins aller Replicas einer AlwaysOn Availability Group.

.DESCRIPTION
    Ermittelt alle Replicas einer Availability Group und vergleicht pro Login:
    - Vorhanden        : existiert der Login auf jeder Replica?
    - Standard-DB      : default_database_name auf allen gleich?
    - Sprache          : default_language_name (Text) auf allen gleich?
    - Passwort-Hash    : password_hash gleich (nur SQL-Logins; Windows = N/A)
    - SID              : sid gleich? (Mismatch = verwaiste User nach Failover)

    Statusbewertung pro Login:
    - Critical : fehlt auf mindestens einer Replica, ODER SID-Mismatch,
                 ODER Passwort-Hash-Mismatch (Authentifizierung bricht nach Failover)
    - Warning  : Standard-DB oder Sprache weicht ab
    - OK       : alles konsistent

    Ausgabe als Tabelle (Rueckgabeobjekt) sowie TXT- und HTML-Report. Der HTML-Report
    wird nach dem Erstellen automatisch geoeffnet (ausser -NoOpen).

    Voraussetzung fuer den Passwort-Hash-Vergleich: Leserecht auf sys.sql_logins
    (sysadmin oder CONTROL SERVER). Fehlt das Recht, wird der Hash als N/A behandelt.

.PARAMETER SqlInstance
    Einstiegs-Instanz der AG (Primary oder eine Secondary). Standard: aktueller Computer.

.PARAMETER AvailabilityGroupName
    Name der Availability Group. Ohne Angabe wird die erste gefundene AG verwendet
    (bei mehreren: Warnung, erste wird genommen).

.PARAMETER SqlCredential
    Optionales PSCredential fuer alle Replicas.

.PARAMETER IncludeSystemLogins
    Wenn gesetzt, werden auch Systemlogins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*,
    BUILTIN\*) verglichen. Standard: ausgeblendet.

    Hinweis: Das 'sa'-Konto (SID 0x01, auch umbenannt) wird standardmaessig ausgeschlossen,
    weil jede Instanz ein eigenes Zufallspasswort verwendet (vom Sync bewusst nicht
    synchronisiert). Sein Passwort-Hash weicht daher erwartungsgemaess ab und wuerde
    sonst -FailOnDrift im Job ausloesen. Benannte sysadmin-Logins bleiben im Vergleich.
    Mit -IncludeSystemLogins wird 'sa' dennoch angezeigt (gilt dann wieder als Drift).

.PARAMETER Login
    Nur diese Logins vergleichen (Wildcards erlaubt).

.PARAMETER ExcludeLogin
    Diese Logins ausschliessen (Wildcards erlaubt).

.PARAMETER OnlyDifferences
    Nur Logins mit Abweichung (Status Warning/Critical) ausgeben.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer TXT/HTML. Standard: aus Modulkonfiguration.

.PARAMETER NoOpen
    Unterdrueckt das automatische Oeffnen des Reports.

.PARAMETER FailOnDrift
    Wenn gesetzt: bei Login-Drift (Status Warning oder Critical) wird ein Windows Event
    (Source 'sqmSQLTool', EventId 9001) geschrieben und anschliessend eine Ausnahme geworfen.
    Damit schlaegt ein SQL-Agent-Job-Step, der nur 'Compare-sqmAlwaysOnLogins -FailOnDrift'
    aufruft, bei Drift fehl (-> OnFailure-Operator-Alarm). Impliziert -NoOpen. Der Report wird
    vorher trotzdem geschrieben.

.PARAMETER ContinueOnError
    Bei Fehler fortfahren.

.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Compare-sqmAlwaysOnLogins -SqlInstance "SQL01"

.EXAMPLE
    Compare-sqmAlwaysOnLogins -SqlInstance "SQL01" -AvailabilityGroupName "AG_Prod" -OnlyDifferences

.EXAMPLE
    Compare-sqmAlwaysOnLogins -SqlInstance "SQL01" | Format-Table

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging.
    Diagnostisches Gegenstueck zu Sync-sqmLoginsToAlwaysOn.
#>
function Compare-sqmAlwaysOnLogins
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[string[]]$Login = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin = @(),

		[Parameter(Mandatory = $false)]
		[switch]$OnlyDifferences,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),

		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,

		[Parameter(Mandatory = $false)]
		[switch]$FailOnDrift,

		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$results      = [System.Collections.Generic.List[PSCustomObject]]::new()

		# -FailOnDrift ist fuer den unbeaufsichtigten Job-Betrieb: Report nicht oeffnen.
		if ($FailOnDrift) { $NoOpen = $true }

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$sysPatterns = @('sa', '##MS_*', 'NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*')

		function _IsSystemLogin
		{
			param ([string]$Name)
			foreach ($p in $sysPatterns) { if ($Name -like $p) { return $true } }
			return $false
		}

		function _MatchesAny
		{
			param ([string]$Name, [string[]]$Patterns)
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}

		# Prueft ob alle (nicht-null) Werte gleich sind
		function _AllSame
		{
			param ([object[]]$Values)
			$distinct = $Values | Where-Object { $null -ne $_ } | Select-Object -Unique
			return (@($distinct).Count -le 1)
		}

		function _h { param($x) [string]$x -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

		# 'sa'-Konto ermitteln (well-known SID 0x01, namensunabhaengig - kann umbenannt sein).
		# Jede Installation hat ein eigenes Zufallspasswort fuer 'sa'. Der Sync synchronisiert
		# es bewusst NICHT - daher hier ebenfalls standardmaessig ausblenden, damit der Report
		# und -FailOnDrift im Job nicht wegen der erwarteten Passwort-Hash-Differenz fehlschlagen.
		# Mit -IncludeSystemLogins wird es wieder gezeigt. Benannte sysadmins bleiben im Vergleich.
		$saLogins = @()
		try
		{
			$saName = (Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query "SELECT SUSER_SNAME(0x01) AS n" -ErrorAction Stop).n
			if (-not [string]::IsNullOrWhiteSpace($saName))
			{
				$saLogins = @($saName)
				Invoke-sqmLogging -Message "'sa'-Konto (SID 0x01) heisst '$saName' und wird ausgeschlossen (eigenes Zufallspasswort je Instanz)." -FunctionName $functionName -Level "INFO"
			}
		}
		catch
		{
			Invoke-sqmLogging -Message "'sa'-Konto konnte nicht ermittelt werden, Fallback 'sa': $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
			$saLogins = @('sa')
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# -------------------------------------------------------------------
			# 1. AG-Namen aufloesen
			# -------------------------------------------------------------------
			$agRows = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
				-Query "SELECT name FROM sys.availability_groups ORDER BY name ASC" -ErrorAction Stop

			if (-not $agRows)
			{
				$msg = "Keine Availability Groups auf '$SqlInstance' gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				if ($EnableException) { throw $msg }
				return
			}

			if ([string]::IsNullOrWhiteSpace($AvailabilityGroupName))
			{
				$AvailabilityGroupName = @($agRows)[0].name
				if (@($agRows).Count -gt 1)
				{
					$agList = ($agRows | ForEach-Object { $_.name }) -join ', '
					Invoke-sqmLogging -Message "Mehrere AGs gefunden [$agList]. Verwende erste: '$AvailabilityGroupName'. Mit -AvailabilityGroupName explizit waehlen." -FunctionName $functionName -Level "WARNING"
				}
			}
			else
			{
				if (-not ($agRows | Where-Object { $_.name -eq $AvailabilityGroupName }))
				{
					$msg = "Availability Group '$AvailabilityGroupName' nicht gefunden auf '$SqlInstance'."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					return
				}
			}

			# -------------------------------------------------------------------
			# 2. Replicas ermitteln
			# -------------------------------------------------------------------
			$replicaQuery = @"
SELECT
    ar.replica_server_name AS ReplicaName,
    drs.role_desc          AS Role
FROM sys.availability_replicas ar
INNER JOIN sys.dm_hadr_availability_replica_states drs
    ON ar.replica_id = drs.replica_id
WHERE ar.group_id IN (
    SELECT group_id FROM sys.availability_groups WHERE name = N'$AvailabilityGroupName'
)
ORDER BY drs.role ASC, ar.replica_server_name
"@
			$replicaRows = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $replicaQuery -ErrorAction Stop
			$replicaNames = @($replicaRows | ForEach-Object { $_.ReplicaName })

			if ($replicaNames.Count -lt 2)
			{
				Invoke-sqmLogging -Message "AG '$AvailabilityGroupName' hat nur $($replicaNames.Count) Replica(s) - Vergleich wenig sinnvoll." -FunctionName $functionName -Level "WARNING"
			}

			Invoke-sqmLogging -Message "AG '$AvailabilityGroupName': $($replicaNames.Count) Replica(s): $($replicaNames -join ', ')" -FunctionName $functionName -Level "INFO"

			# -------------------------------------------------------------------
			# 3. Logins pro Replica lesen
			# -------------------------------------------------------------------
			$loginQuery = @"
SELECT
    sp.name                                    AS LoginName,
    sp.type_desc                               AS LoginType,
    sp.type                                    AS LoginTypeCode,
    sp.default_database_name                   AS DefaultDatabase,
    sp.default_language_name                   AS DefaultLanguage,
    sp.is_disabled                             AS IsDisabled,
    CONVERT(varchar(85),  sp.sid, 1)           AS SidHex,
    CONVERT(varchar(256), sl.password_hash, 1) AS PwdHash
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT LIKE '##%##'
"@
			# replicaData[replicaName] = @{ loginNameLower = row }  ; unreachable -> $null
			$replicaData = [ordered]@{}
			$reachable   = [System.Collections.Generic.List[string]]::new()

			foreach ($rep in $replicaNames)
			{
				try
				{
					$rows = Invoke-DbaQuery -SqlInstance $rep -SqlCredential $SqlCredential -Query $loginQuery -ErrorAction Stop
					$map = @{}
					foreach ($r in $rows) { $map[$r.LoginName.ToLowerInvariant()] = $r }
					$replicaData[$rep] = $map
					$reachable.Add($rep)
					Invoke-sqmLogging -Message "[$rep] $($map.Count) Login(s) gelesen." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$replicaData[$rep] = $null
					Invoke-sqmLogging -Message "[$rep] nicht erreichbar oder Abfrage fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}

			if ($reachable.Count -eq 0)
			{
				$msg = "Keine Replica erreichbar - Vergleich nicht moeglich."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				return
			}

			# -------------------------------------------------------------------
			# 4. Login-Union bilden (nur erreichbare Replicas)
			# -------------------------------------------------------------------
			$allLogins = @{}   # lowerName -> displayName
			foreach ($rep in $reachable)
			{
				foreach ($r in $replicaData[$rep].Values)
				{
					$key = $r.LoginName.ToLowerInvariant()
					if (-not $allLogins.ContainsKey($key)) { $allLogins[$key] = $r.LoginName }
				}
			}

			# -------------------------------------------------------------------
			# 5. Vergleich pro Login
			# -------------------------------------------------------------------
			foreach ($key in ($allLogins.Keys | Sort-Object))
			{
				$display = $allLogins[$key]

				# Filter
				if (-not $IncludeSystemLogins -and ((_IsSystemLogin $display) -or ($saLogins -contains $display))) { continue }
				if ($Login.Count -gt 0 -and -not (_MatchesAny $display $Login)) { continue }
				if ($ExcludeLogin.Count -gt 0 -and (_MatchesAny $display $ExcludeLogin)) { continue }

				$presentOn = [System.Collections.Generic.List[string]]::new()
				$missingOn = [System.Collections.Generic.List[string]]::new()
				$dbVals    = [System.Collections.Generic.List[object]]::new()
				$langVals  = [System.Collections.Generic.List[object]]::new()
				$hashVals  = [System.Collections.Generic.List[object]]::new()
				$sidVals   = [System.Collections.Generic.List[object]]::new()
				$details   = [ordered]@{}
				$loginType = $null
				$isSqlLogin = $false

				foreach ($rep in $reachable)
				{
					$row = $replicaData[$rep][$key]
					if ($row)
					{
						$presentOn.Add($rep)
						if (-not $loginType) { $loginType = $row.LoginType }
						if ($row.LoginTypeCode -eq 'S') { $isSqlLogin = $true }

						$lang = if ([string]::IsNullOrEmpty([string]$row.DefaultLanguage)) { '(default)' } else { [string]$row.DefaultLanguage }
						$dbVals.Add([string]$row.DefaultDatabase)
						$langVals.Add($lang)
						$sidVals.Add([string]$row.SidHex)
						if ($row.LoginTypeCode -eq 'S') { $hashVals.Add([string]$row.PwdHash) }

						$details[$rep] = [PSCustomObject]@{
							Replica         = $rep
							DefaultDatabase = [string]$row.DefaultDatabase
							DefaultLanguage = $lang
							IsDisabled      = [bool]$row.IsDisabled
							SidHex          = [string]$row.SidHex
							PwdHash         = [string]$row.PwdHash
						}
					}
					else
					{
						$missingOn.Add($rep)
						$details[$rep] = $null
					}
				}

				$dbConsistent   = _AllSame $dbVals.ToArray()
				$langConsistent = _AllSame $langVals.ToArray()
				$sidConsistent  = _AllSame $sidVals.ToArray()

				# Hash nur fuer SQL-Logins; wenn alle NULL (kein Leserecht/kein Hash) -> N/A
				$hashConsistent = $null
				$nonNullHashes = $hashVals | Where-Object { $_ -and $_ -ne '' }
				if ($isSqlLogin -and @($nonNullHashes).Count -gt 0)
				{
					$hashConsistent = _AllSame $hashVals.ToArray()
				}

				# Status
				$status = 'OK'
				if ($missingOn.Count -gt 0 -or $sidConsistent -eq $false -or $hashConsistent -eq $false)
				{
					$status = 'Critical'
				}
				elseif ($dbConsistent -eq $false -or $langConsistent -eq $false)
				{
					$status = 'Warning'
				}

				if ($OnlyDifferences -and $status -eq 'OK') { continue }

				# Sprach-Werte als lesbarer Text (bei Abweichung Replica=Wert)
				$langDisplay = if ($langConsistent) { @($langVals)[0] }
				else { (($presentOn | ForEach-Object { "$_=$($details[$_].DefaultLanguage)" }) -join '; ') }

				$dbDisplay = if ($dbConsistent) { @($dbVals)[0] }
				else { (($presentOn | ForEach-Object { "$_=$($details[$_].DefaultDatabase)" }) -join '; ') }

				$results.Add([PSCustomObject]@{
					LoginName              = $display
					LoginType              = $loginType
					OverallStatus          = $status
					Present                = "$($presentOn.Count)/$($reachable.Count)"
					MissingOn              = ($missingOn -join ', ')
					DefaultDatabase        = $dbDisplay
					DefaultDbConsistent    = $dbConsistent
					DefaultLanguage        = $langDisplay
					LanguageConsistent     = $langConsistent
					PasswordHashConsistent = $hashConsistent
					SidConsistent          = $sidConsistent
					Details                = $details
				})
			}

			# -------------------------------------------------------------------
			# 6. Reports schreiben
			# -------------------------------------------------------------------
			$cntCrit = ($results | Where-Object OverallStatus -eq 'Critical').Count
			$cntWarn = ($results | Where-Object OverallStatus -eq 'Warning').Count
			$cntOk   = ($results | Where-Object OverallStatus -eq 'OK').Count

			Invoke-sqmLogging -Message "Vergleich abgeschlossen. OK: $cntOk | Warning: $cntWarn | Critical: $cntCrit" -FunctionName $functionName -Level "INFO"

			if ($PSCmdlet.ShouldProcess($AvailabilityGroupName, "Login-Vergleichsbericht erstellen"))
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeAg    = $AvailabilityGroupName -replace '[\\/:*?"<>|]', '_'
				$txtFile   = Join-Path $OutputPath "AlwaysOnLoginCompare_${safeAg}_${datestamp}.txt"
				$htmlFile  = Join-Path $OutputPath "AlwaysOnLoginCompare_${safeAg}_${datestamp}.html"

				# TXT
				$lines = [System.Collections.Generic.List[string]]::new()
				$lines.Add("# ================================================================")
				$lines.Add("# sqmSQLTool - AlwaysOn Login-Vergleich")
				$lines.Add("# $(Get-sqmReportReference)")
				$lines.Add("# AvailabilityGroup : $AvailabilityGroupName")
				$lines.Add("# Replicas          : $($reachable -join ', ')")
				$unreach = $replicaNames | Where-Object { $_ -notin $reachable }
				if ($unreach) { $lines.Add("# Nicht erreichbar  : $($unreach -join ', ')") }
				$lines.Add("# Erstellt          : $timestamp")
				$lines.Add("# OK: $cntOk | Warning: $cntWarn | Critical: $cntCrit")
				$lines.Add("# ================================================================")
				$lines.Add("")
				$lines.Add(("{0,-10} {1,-35} {2,-14} {3,-9} {4}" -f 'Status', 'Login', 'Typ', 'Vorhanden', 'Befund'))
				$lines.Add(('-' * 110))
				foreach ($e in ($results | Sort-Object OverallStatus, LoginName))
				{
					$befund = @()
					if ($e.MissingOn)                       { $befund += "fehlt auf: $($e.MissingOn)" }
					if ($e.SidConsistent -eq $false)        { $befund += "SID abweichend" }
					if ($e.PasswordHashConsistent -eq $false) { $befund += "Passwort-Hash abweichend" }
					if ($e.DefaultDbConsistent -eq $false)  { $befund += "Std-DB: $($e.DefaultDatabase)" }
					if ($e.LanguageConsistent -eq $false)   { $befund += "Sprache: $($e.DefaultLanguage)" }
					if (-not $befund) { $befund = @('konsistent') }
					$loginShort = if ($e.LoginName.Length -gt 35) { $e.LoginName.Substring(0, 32) + '...' } else { $e.LoginName }
					$lines.Add(("{0,-10} {1,-35} {2,-14} {3,-9} {4}" -f $e.OverallStatus, $loginShort, $e.LoginType, $e.Present, ($befund -join '; ')))
				}
				[System.IO.File]::WriteAllText($txtFile, ($lines -join "`n"), [System.Text.Encoding]::UTF8)

				# HTML
				$rowsHtml = ''
				foreach ($e in ($results | Sort-Object OverallStatus, LoginName))
				{
					$cls = switch ($e.OverallStatus) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
					$missClass = if ($e.MissingOn) { 'crit' } else { '' }
					$sidClass  = if ($e.SidConsistent -eq $false) { 'crit' } else { '' }
					$hashTxt   = switch ($e.PasswordHashConsistent) { $true { 'OK' } $false { 'abweichend' } default { 'N/A' } }
					$hashClass = if ($e.PasswordHashConsistent -eq $false) { 'crit' } else { '' }
					$dbClass   = if ($e.DefaultDbConsistent -eq $false) { 'warn' } else { '' }
					$langClass = if ($e.LanguageConsistent -eq $false) { 'warn' } else { '' }
					$rowsHtml += "<tr>" +
						"<td class='$cls'>$($e.OverallStatus)</td>" +
						"<td>$(_h $e.LoginName)</td>" +
						"<td>$(_h $e.LoginType)</td>" +
						"<td>$($e.Present)</td>" +
						"<td class='$missClass'>$(_h $e.MissingOn)</td>" +
						"<td class='$dbClass'>$(_h $e.DefaultDatabase)</td>" +
						"<td class='$langClass'>$(_h $e.DefaultLanguage)</td>" +
						"<td class='$hashClass'>$hashTxt</td>" +
						"<td class='$sidClass'>$(if ($e.SidConsistent) { 'OK' } else { 'abweichend' })</td>" +
						"</tr>`n"
				}
				$bodyHtml = @"
<table>
<thead><tr><th>Status</th><th>Login</th><th>Typ</th><th>Vorhanden</th><th>Fehlt auf</th><th>Standard-DB</th><th>Sprache</th><th>Passwort-Hash</th><th>SID</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<p style="color:#94a8c0;font-size:12px;">Replicas: $($reachable -join ', ')$(if ($unreach) { " &nbsp;|&nbsp; Nicht erreichbar: $($unreach -join ', ')" }) &nbsp;|&nbsp; OK: $cntOk, Warning: $cntWarn, Critical: $cntCrit</p>
"@
				$html = ConvertTo-sqmHtmlReport -Title "AlwaysOn Login-Vergleich - $AvailabilityGroupName" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
				[System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)

				Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
				Invoke-sqmLogging -Message "Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
			}
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			if (-not $ContinueOnError) { throw $_ }
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Login(s) verglichen." -FunctionName $functionName -Level "INFO"

		# -------------------------------------------------------------------
		# -FailOnDrift: bei Warning/Critical Event 9001 (Splunk) + Ausnahme,
		# damit ein SQL-Agent-Job rot wird (Drift-Alarm). Report ist bereits geschrieben.
		# -------------------------------------------------------------------
		if ($FailOnDrift)
		{
			$crit = @($results | Where-Object OverallStatus -eq 'Critical').Count
			$warn = @($results | Where-Object OverallStatus -eq 'Warning').Count
			if (($crit + $warn) -gt 0)
			{
				try
				{
					$evtSrc = 'sqmSQLTool'
					if (-not [System.Diagnostics.EventLog]::SourceExists($evtSrc)) { New-EventLog -LogName Application -Source $evtSrc -ErrorAction Stop }
					$evtType = if ($crit -gt 0) { 'Error' } else { 'Warning' }
					Write-EventLog -LogName Application -Source $evtSrc -EntryType $evtType -EventId 9001 `
						-Message "sqmSQLTool: AlwaysOn Login-Drift AG '$AvailabilityGroupName' - Warning=$warn Critical=$crit"
				}
				catch { }
				throw "AlwaysOn Login-Drift in AG '$AvailabilityGroupName': Warning=$warn Critical=$crit. Details im Report/Log."
			}
		}

		return $results
	}
}
