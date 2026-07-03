<#
.SYNOPSIS
    Vergleicht die Server-Rollen-Mitgliedschaft aller Replicas einer AlwaysOn Availability Group.

.DESCRIPTION
    Ermittelt alle Replicas einer Availability Group und vergleicht pro Login, welchen
    Server-Rollen er auf jeder Replica angehoert (fixe Rollen wie sysadmin, dbcreator,
    securityadmin, ... sowie ab SQL Server 2022 benutzerdefinierte Server-Rollen).

    Hintergrund: AlwaysOn repliziert nur die Datenbanken selbst - master und damit
    Server-Principals (Logins) UND deren Server-Rollen-Mitgliedschaft werden NICHT
    automatisch synchronisiert. Nach einem Failover kann ein Login auf dem neuen
    Primary z. B. kein sysadmin mehr sein (oder umgekehrt zu viele Rechte haben),
    ohne dass das auffaellt. Diagnostisches Geschwister von Compare-sqmAlwaysOnLogins
    (das Login-Existenz/-Attribute wie Default-DB, Sprache, Passwort-Hash, SID prueft,
    aber keine Rollen-Mitgliedschaft).

    Datenbank-Rollen (db_owner, db_datareader, ...) sind bewusst NICHT Teil dieses
    Vergleichs - sie liegen innerhalb der replizierten Datenbank und sind damit
    strukturell kaum divergent (Ausnahme: verwaiste SIDs, dafuer siehe
    Repair-sqmAlwaysOnDatabases).

    Statusbewertung pro Login:
    - Critical : fehlt auf mindestens einer Replica, ODER sysadmin-Mitgliedschaft
                 weicht zwischen Replicas ab (hoechstprivilegierte Rolle)
    - Warning  : eine andere Rolle weicht ab (Login auf allen Replicas vorhanden)
    - OK       : Rollen-Set auf allen erreichbaren Replicas identisch

    Ausgabe als Tabelle (Rueckgabeobjekt) sowie TXT- und HTML-Report. Der HTML-Report
    wird nach dem Erstellen automatisch geoeffnet (ausser -NoOpen).

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
    analog zu Compare-sqmAlwaysOnLogins. Mit -IncludeSystemLogins wird es dennoch angezeigt.

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
    Wenn gesetzt: bei Rollen-Drift (Status Warning oder Critical) wird ein Windows Event
    (Source 'sqmSQLTool', EventId 9010) geschrieben und anschliessend eine Ausnahme geworfen.
    Damit schlaegt ein SQL-Agent-Job-Step, der nur 'Compare-sqmAlwaysOnRoles -FailOnDrift'
    aufruft, bei Drift fehl (-> OnFailure-Operator-Alarm). Impliziert -NoOpen. Der Report wird
    vorher trotzdem geschrieben.

.PARAMETER ContinueOnError
    Bei Fehler fortfahren.

.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Compare-sqmAlwaysOnRoles -SqlInstance "SQL01"

.EXAMPLE
    Compare-sqmAlwaysOnRoles -SqlInstance "SQL01" -AvailabilityGroupName "AG_Prod" -OnlyDifferences

.EXAMPLE
    Compare-sqmAlwaysOnRoles -SqlInstance "SQL01" | Format-Table

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging.
    Diagnostisches Geschwister von Compare-sqmAlwaysOnLogins (dort: Login-Attribute,
    hier: Server-Rollen-Mitgliedschaft).
#>
function Compare-sqmAlwaysOnRoles
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
		[switch]$EnableException,

		[Parameter(Mandatory = $false)]
		[switch]$NoReport  # Skip report generation (for job context)
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

		# Vergleicht zwei sortierte Rollenlisten (String-Arrays) auf Gleichheit
		function _SameRoleSet
		{
			param ([string[]]$A, [string[]]$B)
			$sa = @($A | Sort-Object -Unique)
			$sb = @($B | Sort-Object -Unique)
			if ($sa.Count -ne $sb.Count) { return $false }
			for ($i = 0; $i -lt $sa.Count; $i++) { if ($sa[$i] -ne $sb[$i]) { return $false } }
			return $true
		}

		function _h { param($x) [string]$x -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

		# 'sa'-Konto ermitteln (well-known SID 0x01, namensunabhaengig - kann umbenannt sein).
		# Analog zu Compare-sqmAlwaysOnLogins standardmaessig ausgeblendet.
		$saLogins = @()
		try
		{
			$saName = (Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query "SELECT SUSER_SNAME(0x01) AS n" -ErrorAction Stop).n
			if (-not [string]::IsNullOrWhiteSpace($saName))
			{
				$saLogins = @($saName)
				Invoke-sqmLogging -Message "'sa'-Konto (SID 0x01) heisst '$saName' und wird ausgeschlossen." -FunctionName $functionName -Level "INFO"
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
			# 3. Server-Rollen-Mitgliedschaft pro Replica lesen
			#    is_fixed_role existiert erst ab SQL Server 2022 (benutzerdefinierte
			#    Server-Rollen) - Fallback-Query ohne diese Spalte fuer aeltere Versionen.
			# -------------------------------------------------------------------
			$roleQueryModern = @"
SELECT
    sp.name         AS LoginName,
    sp.type_desc    AS LoginType,
    r.name          AS RoleName,
    r.is_fixed_role AS IsFixedRole
FROM sys.server_role_members srm
JOIN sys.server_principals sp ON sp.principal_id = srm.member_principal_id
JOIN sys.server_principals r  ON r.principal_id  = srm.role_principal_id
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT LIKE '##%##'
"@
			$roleQueryLegacy = @"
SELECT
    sp.name      AS LoginName,
    sp.type_desc AS LoginType,
    r.name       AS RoleName,
    CAST(1 AS bit) AS IsFixedRole
FROM sys.server_role_members srm
JOIN sys.server_principals sp ON sp.principal_id = srm.member_principal_id
JOIN sys.server_principals r  ON r.principal_id  = srm.role_principal_id
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT LIKE '##%##'
"@

			# replicaData[replicaName] = @{ loginNameLower = @{ LoginName=..; LoginType=..; Roles=@(...) } } ; unreachable -> $null
			$replicaData = [ordered]@{}
			$reachable   = [System.Collections.Generic.List[string]]::new()

			foreach ($rep in $replicaNames)
			{
				try
				{
					try
					{
						$rows = Invoke-DbaQuery -SqlInstance $rep -SqlCredential $SqlCredential -Query $roleQueryModern -ErrorAction Stop
					}
					catch
					{
						# is_fixed_role fehlt (SQL Server < 2022) - Fallback ohne diese Spalte
						$rows = Invoke-DbaQuery -SqlInstance $rep -SqlCredential $SqlCredential -Query $roleQueryLegacy -ErrorAction Stop
					}

					$map = @{}
					foreach ($r in $rows)
					{
						$key = $r.LoginName.ToLowerInvariant()
						if (-not $map.ContainsKey($key))
						{
							$map[$key] = [PSCustomObject]@{
								LoginName = $r.LoginName
								LoginType = $r.LoginType
								Roles     = [System.Collections.Generic.List[string]]::new()
							}
						}
						$map[$key].Roles.Add([string]$r.RoleName)
					}
					$replicaData[$rep] = $map
					$reachable.Add($rep)
					Invoke-sqmLogging -Message "[$rep] $($map.Count) Login(s) mit Rollen-Mitgliedschaft gelesen." -FunctionName $functionName -Level "INFO"
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
				$details   = [ordered]@{}
				$loginType = $null
				$roleSets  = [System.Collections.Generic.List[string[]]]::new()
				$sysadminOn = [System.Collections.Generic.List[bool]]::new()

				foreach ($rep in $reachable)
				{
					$row = $replicaData[$rep][$key]
					if ($row)
					{
						$presentOn.Add($rep)
						if (-not $loginType) { $loginType = $row.LoginType }

						$roles = @($row.Roles | Sort-Object -Unique)
						$roleSets.Add($roles)
						$sysadminOn.Add(($roles -contains 'sysadmin'))

						$details[$rep] = [PSCustomObject]@{
							Replica = $rep
							Roles   = ($roles -join ', ')
						}
					}
					else
					{
						$missingOn.Add($rep)
						$details[$rep] = $null
					}
				}

				# Rollen-Konsistenz: alle Rollen-Sets (auf Replicas, wo Login vorhanden ist) identisch?
				$rolesConsistent = $true
				if ($roleSets.Count -gt 1)
				{
					for ($i = 1; $i -lt $roleSets.Count; $i++)
					{
						if (-not (_SameRoleSet $roleSets[0] $roleSets[$i])) { $rolesConsistent = $false; break }
					}
				}

				# sysadmin-Drift getrennt betrachten (hoechstprivilegierte Rolle -> immer Critical)
				$sysadminDrift = $false
				if ($sysadminOn.Count -gt 1)
				{
					$distinctSysadmin = $sysadminOn | Select-Object -Unique
					if (@($distinctSysadmin).Count -gt 1) { $sysadminDrift = $true }
				}

				# Status
				$status = 'OK'
				if ($missingOn.Count -gt 0 -or $sysadminDrift)
				{
					$status = 'Critical'
				}
				elseif (-not $rolesConsistent)
				{
					$status = 'Warning'
				}

				if ($OnlyDifferences -and $status -eq 'OK') { continue }

				$rolesDisplay = if ($rolesConsistent -and $roleSets.Count -gt 0) { ($roleSets[0] -join ', ') }
				elseif ($roleSets.Count -eq 0) { '(keine)' }
				else { (($presentOn | ForEach-Object { "$_=$($details[$_].Roles)" }) -join '; ') }

				$results.Add([PSCustomObject]@{
					LoginName       = $display
					LoginType       = $loginType
					OverallStatus   = $status
					Present         = "$($presentOn.Count)/$($reachable.Count)"
					MissingOn       = ($missingOn -join ', ')
					RolesConsistent = $rolesConsistent
					Roles           = $rolesDisplay
					IsSysadminDrift = $sysadminDrift
					Details         = $details
				})
			}

			# -------------------------------------------------------------------
			# 6. Reports schreiben
			# -------------------------------------------------------------------
			$cntCrit = ($results | Where-Object OverallStatus -eq 'Critical').Count
			$cntWarn = ($results | Where-Object OverallStatus -eq 'Warning').Count
			$cntOk   = ($results | Where-Object OverallStatus -eq 'OK').Count

			Invoke-sqmLogging -Message "Vergleich abgeschlossen. OK: $cntOk | Warning: $cntWarn | Critical: $cntCrit" -FunctionName $functionName -Level "INFO"

			if ($PSCmdlet.ShouldProcess($AvailabilityGroupName, "Rollen-Vergleichsbericht erstellen") -and -not $NoReport)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeAg    = $AvailabilityGroupName -replace '[\\/:*?"<>|]', '_'
				$txtFile   = Join-Path $OutputPath "AlwaysOnRoleCompare_${safeAg}_${datestamp}.txt"
				$htmlFile  = Join-Path $OutputPath "AlwaysOnRoleCompare_${safeAg}_${datestamp}.html"

				# TXT
				$lines = [System.Collections.Generic.List[string]]::new()
				$lines.Add("# ================================================================")
				$lines.Add("# sqmSQLTool - AlwaysOn Rollen-Vergleich")
				$lines.Add("# $(Get-sqmReportReference)")
				$lines.Add("# AvailabilityGroup : $AvailabilityGroupName")
				$lines.Add("# Replicas          : $($reachable -join ', ')")
				$unreach = $replicaNames | Where-Object { $_ -notin $reachable }
				if ($unreach) { $lines.Add("# Nicht erreichbar  : $($unreach -join ', ')") }
				$lines.Add("# Erstellt          : $timestamp")
				$lines.Add("# OK: $cntOk | Warning: $cntWarn | Critical: $cntCrit")
				$lines.Add("# ================================================================")
				$lines.Add("")
				$lines.Add(("{0,-10} {1,-35} {2,-14} {3,-9} {4}" -f 'Status', 'Login', 'Typ', 'Vorhanden', 'Rollen/Befund'))
				$lines.Add(('-' * 110))
				foreach ($e in ($results | Sort-Object OverallStatus, LoginName))
				{
					$befund = @()
					if ($e.MissingOn)        { $befund += "fehlt auf: $($e.MissingOn)" }
					if ($e.IsSysadminDrift)  { $befund += "sysadmin abweichend" }
					if (-not $e.RolesConsistent) { $befund += "Rollen: $($e.Roles)" }
					else { $befund += $e.Roles }
					$loginShort = if ($e.LoginName.Length -gt 35) { $e.LoginName.Substring(0, 32) + '...' } else { $e.LoginName }
					$lines.Add(("{0,-10} {1,-35} {2,-14} {3,-9} {4}" -f $e.OverallStatus, $loginShort, $e.LoginType, $e.Present, ($befund -join '; ')))
				}

				# Write reports only if NOT suppressed by -NoReport
				if (-not $NoReport)
				{
					[System.IO.File]::WriteAllText($txtFile, ($lines -join "`n"), [System.Text.Encoding]::UTF8)

					# HTML
					$rowsHtml = ''
					foreach ($e in ($results | Sort-Object OverallStatus, LoginName))
					{
						$cls = switch ($e.OverallStatus) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
						$missClass  = if ($e.MissingOn) { 'crit' } else { '' }
						$sysClass   = if ($e.IsSysadminDrift) { 'crit' } else { '' }
						$rolesClass = if (-not $e.RolesConsistent) { 'warn' } else { '' }
						$rowsHtml += "<tr>" +
							"<td class='$cls'>$($e.OverallStatus)</td>" +
							"<td>$(_h $e.LoginName)</td>" +
							"<td>$(_h $e.LoginType)</td>" +
							"<td>$($e.Present)</td>" +
							"<td class='$missClass'>$(_h $e.MissingOn)</td>" +
							"<td class='$rolesClass'>$(_h $e.Roles)</td>" +
							"<td class='$sysClass'>$(if ($e.IsSysadminDrift) { 'abweichend' } else { 'OK' })</td>" +
							"</tr>`n"
					}
					$bodyHtml = @"
<table>
<thead><tr><th>Status</th><th>Login</th><th>Typ</th><th>Vorhanden</th><th>Fehlt auf</th><th>Rollen</th><th>sysadmin</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<p style="color:#94a8c0;font-size:12px;">Replicas: $($reachable -join ', ')$(if ($unreach) { " &nbsp;|&nbsp; Nicht erreichbar: $($unreach -join ', ')" }) &nbsp;|&nbsp; OK: $cntOk, Warning: $cntWarn, Critical: $cntCrit</p>
"@
					$html = ConvertTo-sqmHtmlReport -Title "AlwaysOn Rollen-Vergleich - $AvailabilityGroupName" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
					[System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
					Invoke-sqmLogging -Message "Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
				}
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
		# -FailOnDrift: bei Warning/Critical Event 9010 (Splunk) + Ausnahme,
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
					Write-EventLog -LogName Application -Source $evtSrc -EntryType $evtType -EventId 9010 `
						-Message "sqmSQLTool: AlwaysOn Rollen-Drift AG '$AvailabilityGroupName' - Warning=$warn Critical=$crit"
				}
				catch { }
				throw "AlwaysOn Rollen-Drift in AG '$AvailabilityGroupName': Warning=$warn Critical=$crit. Details im Report/Log."
			}
		}

		return $results
	}
}
