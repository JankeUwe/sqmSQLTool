<#
.SYNOPSIS
    Finds databases where non-dbo principals are members of db_owner and reports the
    associated privilege-escalation risk as a pass/fail (green/red) HTML report.

.DESCRIPTION
    db_owner is functionally equivalent to CONTROL on the database: members can create
    triggers and procedures with EXECUTE AS OWNER, which run in the security context of
    the database owner (dbo), not the caller. If the database has TRUSTWORTHY set to ON
    and the database owner maps to a login that holds sysadmin at the server level (very
    common, since databases are usually created by an admin/setup account), any db_owner
    member can escalate to full instance control via a single CREATE PROCEDURE ... WITH
    EXECUTE AS OWNER statement. See the accompanying blog post for the full background:
    https://www.powershelldba.de/blog/articles/db-owner-privilege-escalation-risks.html

    This function, per database:
      1. Reads the db_owner role members (sys.database_role_members), excluding the
         implicit 'dbo' principal and anything matched by -ExcludeLogin.
      2. Reads the database's TRUSTWORTHY setting and whether the database owner login
         is a sysadmin (sys.databases / IS_SRVROLEMEMBER).
      3. Classifies the database:
           OK       - no unexpected db_owner members -> green
           Warning  - unexpected db_owner member(s), but no TRUSTWORTHY+sysadmin-owner
                      escalation path open -> red
           Critical - unexpected db_owner member(s) AND TRUSTWORTHY=ON AND the owner is
                      sysadmin -> the full escalation path described above is open -> red

    Output as PowerShell objects (one row per database), plus TXT/CSV/HTML report files
    in the configured OutputPath. The HTML report colors each row green (OK) or red
    (Warning/Critical).

    This function only reports. Use Repair-sqmDbOwnerRisk to fix what it finds (removes
    db_owner membership, grants db_datareader/db_datawriter, creates/grants a custom
    db_execute role).

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential.

.PARAMETER Database
    Database name(s) to check. Wildcards allowed. Default: all user databases.

.PARAMETER ExcludeDatabase
    Databases to exclude. Wildcards allowed.

.PARAMETER ExcludeLogin
    Principal names to exclude from being reported as a db_owner risk (wildcards
    allowed), in addition to the always-excluded 'dbo'. Use this for accounts that are
    deliberately provisioned with db_owner (e.g. a documented deployment account).

.PARAMETER IncludeSystemDatabases
    Also check master/model/msdb. Default: $false. tempdb is never checked.

.PARAMETER OutputPath
    Output directory for the report (HTML/TXT/CSV). Default: <module OutputPath>\DbOwnerRisk.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately instead of just logging them.

.PARAMETER NoOpen
    Do not automatically open the report after creating it.

.PARAMETER Confirm
    Ask before writing the report files.

.PARAMETER WhatIf
    Show which report files would be created without writing them.

.EXAMPLE
    Get-sqmDbOwnerRisk

    Checks all user databases on the local instance.

.EXAMPLE
    Get-sqmDbOwnerRisk -SqlInstance 'SQL01','SQL02' -ExcludeLogin 'svc_deploy'

.EXAMPLE
    Get-sqmDbOwnerRisk -SqlInstance 'SQL01' | Where-Object Status -eq 'Risk'

.EXAMPLE
    Get-sqmDbOwnerRisk -SqlInstance 'SQL01' | Where-Object Status -eq 'Risk' | Repair-sqmDbOwnerRisk -WhatIf

    Feeds the findings straight into the repair function (dry run first).

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    See also: Repair-sqmDbOwnerRisk, Set-sqmDatabaseOwner
#>
function Get-sqmDbOwnerRisk
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin = @(),

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'DbOwnerRisk'),

		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException,

		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		# Instanz-weite Metadaten: TRUSTWORTHY + ob der Datenbankbesitzer sysadmin ist.
		# ISNULL(), weil IS_SRVROLEMEMBER() NULL liefert wenn der Owner-Login nicht
		# aufloesbar ist (z.B. verwaister Owner nach Migration) - das darf nicht als
		# "privilegiert" durchgehen.
		$metaQuery = @"
SELECT
    d.name AS DatabaseName,
    d.is_trustworthy_on AS IsTrustworthyOn,
    SUSER_SNAME(d.owner_sid) AS DbOwnerLogin,
    ISNULL(IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME(d.owner_sid)), 0) AS OwnerIsSysAdmin
FROM sys.databases d
"@

		$memberQuery = @"
SELECT dp.name AS MemberName, dp.type_desc AS MemberType
FROM sys.database_role_members rm
JOIN sys.database_principals dp ON dp.principal_id = rm.member_principal_id
JOIN sys.database_principals rp ON rp.principal_id = rm.role_principal_id
WHERE rp.name = N'db_owner'
ORDER BY dp.name
"@

		Invoke-sqmLogging -Message "Starte $functionName" -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			try
			{
				$connParams = @{ SqlInstance = $instance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				$metaRows = Invoke-DbaQuery @connParams -Database 'master' -Query $metaQuery -ErrorAction Stop
				$metaByDb = @{}
				foreach ($m in $metaRows) { $metaByDb[$m.DatabaseName] = $m }

				$isoByDb = Get-sqmDatabaseTrustIsolationMap -SqlInstance $instance -SqlCredential $SqlCredential

				$dbList = Get-DbaDatabase @connParams -ErrorAction Stop | Where-Object { $_.Name -ne 'tempdb' }
				if (-not $IncludeSystemDatabases) { $dbList = $dbList | Where-Object { -not $_.IsSystemObject } }

				if ($Database.Count -gt 0)
				{
					$dbList = $dbList | Where-Object {
						$dbName = $_.Name
						$match = $false
						foreach ($pattern in $Database) { if ($dbName -like $pattern) { $match = $true } }
						$match
					}
				}
				if ($ExcludeDatabase.Count -gt 0)
				{
					$dbList = $dbList | Where-Object {
						$dbName = $_.Name
						$exclude = $false
						foreach ($pattern in $ExcludeDatabase) { if ($dbName -like $pattern) { $exclude = $true } }
						-not $exclude
					}
				}

				$dbList = @($dbList)
				Invoke-sqmLogging -Message "[$instance] $($dbList.Count) Datenbank(en) zu pruefen." -FunctionName $functionName -Level 'INFO'

				foreach ($db in $dbList)
				{
					$dbName = $db.Name
					$rows = Invoke-DbaQuery @connParams -Database $dbName -Query $memberQuery -ErrorAction Stop

					$members = @($rows | Where-Object {
						$n = $_.MemberName
						if ($n -eq 'dbo') { return $false }
						$excluded = $false
						foreach ($pattern in $ExcludeLogin) { if ($n -like $pattern) { $excluded = $true } }
						-not $excluded
					} | Select-Object -ExpandProperty MemberName)

					$meta = $metaByDb[$dbName]
					$isTrustworthy = if ($meta) { [bool]$meta.IsTrustworthyOn } else { $false }
					$ownerIsSysAdmin = if ($meta) { [bool]$meta.OwnerIsSysAdmin } else { $false }
					$dbOwnerLogin = if ($meta) { $meta.DbOwnerLogin } else { $null }
					$isolationLevel = if ($isoByDb.ContainsKey($dbName)) { $isoByDb[$dbName].IsolationLevel } else { $null }

					$escalationPossible = ($members.Count -gt 0) -and $isTrustworthy -and $ownerIsSysAdmin

					if ($members.Count -eq 0)
					{
						$status = 'OK'; $severity = 'OK'; $icon = '🟢'
						$message = "Keine unerwarteten db_owner-Mitglieder."
					}
					elseif ($escalationPossible)
					{
						$status = 'Risk'; $severity = 'Critical'; $icon = '🔴'
						$message = "Eskalationspfad offen: TRUSTWORTHY=ON und Datenbankbesitzer '$dbOwnerLogin' ist sysadmin - " +
							"$($members -join ', ') koennte(n) per CREATE PROCEDURE/TRIGGER ... WITH EXECUTE AS OWNER auf sysadmin eskalieren."
					}
					else
					{
						$status = 'Risk'; $severity = 'Warning'; $icon = '🔴'
						$message = "Unerwartete(r) db_owner-Mitglied(er): $($members -join ', ')."
					}

					$allResults.Add([PSCustomObject]@{
						SqlInstance         = $instance
						DatabaseName        = $dbName
						Status              = $status
						Severity            = $severity
						RiskIcon            = $icon
						DbOwnerMembers      = $members
						MemberCount         = $members.Count
						DbOwnerLogin        = $dbOwnerLogin
						IsTrustworthyOn     = $isTrustworthy
						IsolationLevel      = $isolationLevel
						OwnerIsSysAdmin     = $ownerIsSysAdmin
						EscalationPossible  = $escalationPossible
						Message             = $message
					})
				}

				Invoke-sqmLogging -Message "[$instance] $($dbList.Count) Datenbank(en) geprueft." -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				$errMsg = "[$instance] Fehler: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		if ($allResults.Count -gt 0)
		{
			$cntCritical = @($allResults | Where-Object Severity -eq 'Critical').Count
			$cntWarning  = @($allResults | Where-Object Severity -eq 'Warning').Count
			$cntOk       = @($allResults | Where-Object Severity -eq 'OK').Count
			$instanceList = ($SqlInstance -join ', ')

			if ($PSCmdlet.ShouldProcess($instanceList, "Erstelle db_owner-Risiko-Bericht in $OutputPath"))
			{
				try
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level 'INFO'
					}

					$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
					$datestamp = Get-Date -Format 'yyyy-MM-dd'
					$safeInst  = ($SqlInstance -join '_') -replace '[\\/:*?"<>|]', '_'
					if ($safeInst.Length -gt 60) { $safeInst = $safeInst.Substring(0, 60) }
					$txtFile  = Join-Path $OutputPath "DbOwnerRisk_${safeInst}_${datestamp}.txt"
					$csvFile  = Join-Path $OutputPath "DbOwnerRisk_${safeInst}_${datestamp}.csv"
					$htmlFile = Join-Path $OutputPath "DbOwnerRisk_${safeInst}_${datestamp}.html"

					$sevRank = @{ Critical = 0; Warning = 1; OK = 2 }
					$sorted = $allResults | Sort-Object @{ Expression = { $sevRank[$_.Severity] } }, SqlInstance, DatabaseName

					# -- TXT --
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - db_owner Risiko-Bericht")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz(en): $instanceList")
					$lines.Add("# Erstellt   : $timestamp")
					$lines.Add("# Gesamt     : $($allResults.Count) Datenbank(en)")
					$lines.Add("# Critical   : $cntCritical  (db_owner-Mitglied + TRUSTWORTHY=ON + Owner ist sysadmin)")
					$lines.Add("# Warning    : $cntWarning  (unerwartete(s) db_owner-Mitglied(er))")
					$lines.Add("# OK         : $cntOk")
					$lines.Add("# ================================================================")

					foreach ($grp in @('Critical', 'Warning'))
					{
						$entries = $allResults | Where-Object Severity -eq $grp
						$lines.Add("")
						$lines.Add("# ----------------------------------------------------------------")
						$lines.Add("# $($grp.ToUpper()) ($($entries.Count))")
						$lines.Add("# ----------------------------------------------------------------")
						if ($entries)
						{
							foreach ($e in ($entries | Sort-Object SqlInstance, DatabaseName))
							{
								$lines.Add(("  {0,-20} {1,-25} Members: {2}" -f $e.SqlInstance, $e.DatabaseName, ($e.DbOwnerMembers -join ', ')))
								$lines.Add(("    Owner: {0,-25} Trustworthy: {1,-6} OwnerIsSysAdmin: {2,-6} IsolationLevel: {3}" -f $e.DbOwnerLogin, $e.IsTrustworthyOn, $e.OwnerIsSysAdmin, $e.IsolationLevel))
							}
						}
						else { $lines.Add("  (keine)") }
					}

					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$allResults | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# -- HTML: gruen (OK) / rot (Warning+Critical) --
					$rowsHtml = foreach ($e in $sorted)
					{
						$cssClass = if ($e.Status -eq 'OK') { 'ok' } else { 'crit' }
						"<tr><td class='$cssClass'>$($e.RiskIcon) $($e.Severity)</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.SqlInstance))</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.DatabaseName))</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode(($e.DbOwnerMembers -join ', ')))</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.DbOwnerLogin))</td>" +
							"<td>$($e.IsTrustworthyOn)</td><td>$([System.Net.WebUtility]::HtmlEncode($e.IsolationLevel))</td><td>$($e.OwnerIsSysAdmin)</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.Message))</td></tr>"
					}
					$bodyHtml = "<p>Gesamt: $($allResults.Count) | Critical: $cntCritical | Warning: $cntWarning | OK: $cntOk</p>" +
						"<table><tr><th>Status</th><th>Instanz</th><th>Datenbank</th><th>db_owner-Mitglieder</th>" +
						"<th>DB-Owner-Login</th><th>Trustworthy</th><th>IsolationLevel</th><th>OwnerIsSysAdmin</th><th>Meldung</th></tr>" +
						($rowsHtml -join '') + "</table>"
					$html = ConvertTo-sqmHtmlReport -Title "db_owner Risiko-Bericht" -Subtitle "Instanz(en): $instanceList | Erstellt: $timestamp" -BodyHtml $bodyHtml
					$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
					Invoke-sqmLogging -Message "Bericht erstellt: $htmlFile" -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					Invoke-sqmLogging -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}

			if ($cntCritical -gt 0)
			{
				Invoke-sqmLogging -Message "$cntCritical Datenbank(en) mit offenem Eskalationspfad (Critical) gefunden." -FunctionName $functionName -Level 'WARNING'
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Datenbank(en) gesamt." -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
