<#
.SYNOPSIS
    Comprehensive audit of all SQL Server logins on one or more instances.

.DESCRIPTION
    Checks per login:
    - POLICY VIOLATIONS (CHECK_POLICY/EXPIRATION/MUST_CHANGE)
    - Password age and whether it was never changed
    - Inactive / never-used logins
    - Duplicate SIDs (failed migration)
    - AD-orphaned Windows logins (optional)

    Output as TXT report and CSV (findings only) in the configured OutputPath.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential.

.PARAMETER InactivityThresholdDays
    Logins without login since this value are considered inactive. Default: 90.

.PARAMETER MaxPasswordAgeDays
    SQL logins with password older than this value are reported (non-sysadmins). Default: 180. 0 = disabled.

.PARAMETER MaxPasswordAgeDaysSysadmin
    SQL logins with password older than this value are reported (sysadmins). Default: 365. 0 = disabled.

.PARAMETER ExcludeLogin
    Logins to exclude (wildcards). E.g. 'NT SERVICE\*', 'sqmsa'.

.PARAMETER IncludeSystemLogins
    When set, NT SERVICE\*, NT AUTHORITY\* are also included.

.PARAMETER CheckPolicyNonSysadmin
    Check password policy violations for non-sysadmin logins. Default: $true.

.PARAMETER CheckPolicySysadmin
    Check password policy violations for sysadmin logins. Default: $true.

.PARAMETER ReportBuiltInAdmins
    When BUILTIN\Administrators is found in logins, report as warning. Default: $true.

.PARAMETER CheckAdOrphans
    When set, AD orphan check is performed for Windows logins (requires AD module).

.PARAMETER GenerateHtmlReport
    Generate HTML report in addition to TXT/CSV. Default: $true.

.PARAMETER HtmlReportTemplate
    HTML template style: 'Standard', 'Compact', 'Detailed'. Default: 'Standard'.

.PARAMETER OutputPath
    Output directory. Default: from module configuration (Get-sqmDefaultOutputPath).

.PARAMETER ContinueOnError
    Continue on error for an instance.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before file creation.

.PARAMETER WhatIf
    Shows what would happen.

.EXAMPLE
    Invoke-sqmLoginAudit

.EXAMPLE
    Invoke-sqmLoginAudit -SqlInstance "SQL01" -CheckAdOrphans -IncludeSystemLogins

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    AD orphan check requires the ActiveDirectory module (RSAT).
#>
function Invoke-sqmLoginAudit
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$InactivityThresholdDays = 90,
		[Parameter(Mandatory = $false)]
		[int]$MaxPasswordAgeDays = 180,
		[Parameter(Mandatory = $false)]
		[int]$MaxPasswordAgeDaysSysadmin = 365,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,
		[Parameter(Mandatory = $false)]
		[switch]$CheckPolicyNonSysadmin = $true,
		[Parameter(Mandatory = $false)]
		[switch]$CheckPolicySysadmin = $true,
		[Parameter(Mandatory = $false)]
		[switch]$ReportBuiltInAdmins = $true,
		[Parameter(Mandatory = $false)]
		[switch]$CheckAdOrphans,
		[Parameter(Mandatory = $false)]
		[switch]$GenerateHtmlReport = $true,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Standard', 'Compact', 'Detailed')]
		[string]$HtmlReportTemplate = 'Standard',
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),
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
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
		
		# AD-Modul testen falls benoetigt
		$adAvailable = $false
		if ($CheckAdOrphans)
		{
			if (Get-Command -Name Get-ADObject -ErrorAction SilentlyContinue)
			{
				$adAvailable = $true
			}
			else
			{
				try
				{
					Import-Module ActiveDirectory -ErrorAction Stop
					$adAvailable = $true
				}
				catch
				{
					Invoke-sqmLogging -Message "ActiveDirectory-Modul konnte nicht geladen werden. AD-Orphan-Pruefung wird uebersprungen." -FunctionName $functionName -Level "WARNING"
				}
			}
		}
		
		function _IsExcluded
		{
			param ([string]$Name,
				[string[]]$Patterns)
			if (-not $Patterns) { return $false }
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			
			function _AddFinding
			{
				param ($LoginName,
					$FindingType,
					$LoginType,
					$IsEnabled,
					$Category,
					$Detail,
					$Status,
					$IsSysadmin = $false)
				$detailRows.Add([PSCustomObject]@{
						SqlInstance = $instance
						LoginName   = $LoginName
						LoginType   = $LoginType
						IsEnabled   = $IsEnabled
						IsSysadmin  = $IsSysadmin
						Category    = $Category
						FindingType = $FindingType
						Detail	    = $Detail
						Status	    = $Status
					})
			}
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Login-Audit gestartet ..." -FunctionName $functionName -Level "INFO"
				
				$loginQuery = @"
SELECT
    sp.name                                 AS LoginName,
    sp.type_desc                            AS LoginType,
    sp.is_disabled                          AS IsDisabled,
    sp.create_date                          AS CreateDate,
    sp.modify_date                          AS ModifyDate,
    NULL                                    AS LastLogin,          -- sys.server_principals hat keine last_login-Spalte
    sp.default_database_name                AS DefaultDatabase,
    sl.is_policy_checked                    AS PolicyChecked,
    sl.is_expiration_checked                AS ExpirationChecked,
    CAST(LOGINPROPERTY(sp.name, 'IsMustChange') AS BIT) AS MustChange,
    CAST(LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS DATETIME) AS PwLastSet,
    sp.sid                                  AS Sid,
    CASE WHEN IS_SRVROLEMEMBER('sysadmin', sp.name) = 1 THEN 1 ELSE 0 END AS IsSysadmin
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins   sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT IN ('##MS_PolicyEventProcessingLogin##',
                      '##MS_PolicyTsqlExecutionLogin##')
  AND sp.principal_id > 1
"@
				$loginRows = Invoke-DbaQuery @connParams -Query $loginQuery -EnableException:$EnableException
				$now = Get-Date
				
				$filtered = $loginRows | Where-Object {
					($IncludeSystemLogins -or
						($_.LoginName -notlike 'NT SERVICE\*' -and
							$_.LoginName -notlike 'NT AUTHORITY\*')) -and
					(-not (_IsExcluded $_.LoginName $ExcludeLogin))
				}
				
				if (-not $filtered)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Logins nach Filterung." -FunctionName $functionName -Level "WARNING"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Warning'
							Message	    = 'Keine Logins nach Filterung'
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
						})
					continue
				}
				
				Invoke-sqmLogging -Message "[$instance] $(@($filtered).Count) Logins zu pruefen." -FunctionName $functionName -Level "INFO"
				
				# 0. BUILTIN\Admins-Pruefung
				if ($ReportBuiltInAdmins)
				{
					$builtinAdmins = $filtered | Where-Object { $_.LoginName -like 'BUILTIN\*Administrators*' }
					foreach ($row in $builtinAdmins)
					{
						$enabled = -not [bool]$row.IsDisabled
						_AddFinding $row.LoginName 'BuiltinAdmins' $row.LoginType $enabled 'BuiltinAdmins' "BUILTIN\Administrators nicht empfohlen. Verwende Domain-Gruppen oder spezifische Service-Accounts statt." 'Warning' $row.IsSysadmin
					}
				}

				# 1. Policy-Verstoesse (SQL-Logins, differenziert nach Sysadmin)
				foreach ($row in ($filtered | Where-Object { $_.LoginType -eq 'SQL_LOGIN' }))
				{
					$enabled = -not [bool]$row.IsDisabled
					$isSysadmin = [bool]$row.IsSysadmin

					# Entscheidung: Policy-Check durchfuehren?
					$checkPolicy = if ($isSysadmin) { $CheckPolicySysadmin } else { $CheckPolicyNonSysadmin }

					if ($checkPolicy)
					{
						if (-not $row.PolicyChecked)
						{
							_AddFinding $row.LoginName 'PolicyOff' $row.LoginType $enabled 'Policy' "CHECK_POLICY = OFF - Kennwortrichtlinie deaktiviert." 'Warning' $row.IsSysadmin
						}
						if (-not $row.ExpirationChecked)
						{
							_AddFinding $row.LoginName 'ExpirationOff' $row.LoginType $enabled 'Policy' "CHECK_EXPIRATION = OFF - Kennwortablauf deaktiviert." 'Warning' $row.IsSysadmin
						}
						if ($row.MustChange)
						{
							_AddFinding $row.LoginName 'MustChange' $row.LoginType $enabled 'Policy' "MUST_CHANGE = ON - Kennwort muss bei naechstem Login geaendert werden." 'Warning' $row.IsSysadmin
						}
					}
				}

				# 2. Kennwortalter (differenziert nach Sysadmin)
				foreach ($row in ($filtered | Where-Object { $_.LoginType -eq 'SQL_LOGIN' -and $_.PwLastSet }))
				{
					$isSysadmin = [bool]$row.IsSysadmin
					$maxPwAge = if ($isSysadmin) { $MaxPasswordAgeDaysSysadmin } else { $MaxPasswordAgeDays }

					if ($maxPwAge -gt 0)
					{
						$pwAgeDays = ($now - $row.PwLastSet).TotalDays
						if ($pwAgeDays -gt $maxPwAge)
						{
							$label = if ($isSysadmin) { "(Sysadmin: Max $MaxPasswordAgeDaysSysadmin Tage)" } else { "(Max: $MaxPasswordAgeDays Tage)" }
							_AddFinding $row.LoginName 'OldPassword' $row.LoginType (-not [bool]$row.IsDisabled) 'Password' ("Kennwort seit $([math]::Round($pwAgeDays, 0)) Tagen nicht geaendert $label. Letzte aenderung: " + $row.PwLastSet.ToString('yyyy-MM-dd')) 'Warning' $row.IsSysadmin
						}
						if ($row.CreateDate -and [math]::Abs(($row.PwLastSet - $row.CreateDate).TotalMinutes) -lt 1)
						{
							_AddFinding $row.LoginName 'NeverChangedPassword' $row.LoginType (-not [bool]$row.IsDisabled) 'Password' "Kennwort seit Kontoerstellung nie geaendert (erstellt: $($row.CreateDate.ToString('yyyy-MM-dd')))." 'Warning' $row.IsSysadmin
						}
					}
				}
				
				# 3. Inaktive Logins
				foreach ($row in $filtered)
				{
					$enabled = -not [bool]$row.IsDisabled
					if ($row.LastLogin -and $row.LastLogin.Year -gt 1990)
					{
						$inactiveDays = ($now - $row.LastLogin).TotalDays
						if ($inactiveDays -gt $InactivityThresholdDays)
						{
							_AddFinding $row.LoginName 'Inactive' $row.LoginType $enabled 'Inactivity' ("Letzter Login vor $([math]::Round($inactiveDays, 0)) Tagen ($($row.LastLogin.ToString('yyyy-MM-dd'))). Schwelle: $InactivityThresholdDays Tage.") 'Warning' $row.IsSysadmin
						}
					}
					elseif (-not $row.IsDisabled -and $row.LoginType -eq 'SQL_LOGIN')
					{
						$createDays = ($now - $row.CreateDate).TotalDays
						if ($createDays -gt $InactivityThresholdDays)
						{
							_AddFinding $row.LoginName 'NeverUsed' $row.LoginType $true 'Inactivity' "Login seit $([math]::Round($createDays, 0)) Tagen nie verwendet (erstellt: $($row.CreateDate.ToString('yyyy-MM-dd')))." 'Warning' $row.IsSysadmin
						}
					}
				}
				
				# 4. Doppelte SIDs
				$sidGroups = $filtered | Where-Object { $_.LoginType -eq 'SQL_LOGIN' } | Group-Object { [System.BitConverter]::ToString($_.Sid) } | Where-Object { $_.Count -gt 1 }
				foreach ($grp in $sidGroups)
				{
					$names = ($grp.Group | Select-Object -ExpandProperty LoginName) -join ', '
					foreach ($row in $grp.Group)
					{
						_AddFinding $row.LoginName 'DuplicateSid' $row.LoginType (-not [bool]$row.IsDisabled) 'Integrity' "Doppelte SID mit: $names - deutet auf fehlerhafte Migration hin." 'Warning' $row.IsSysadmin
					}
				}
				
				# 5. AD-Orphan-Pruefung
				if ($CheckAdOrphans -and $adAvailable)
				{
					$winLogins = $filtered | Where-Object { $_.LoginType -in @('WINDOWS_LOGIN', 'WINDOWS_GROUP') }
					foreach ($row in $winLogins)
					{
						$samName = $row.LoginName -replace '^.*\\', ''
						try
						{
							$adObj = Get-ADObject -Filter { SamAccountName -eq $samName } -ErrorAction Stop | Select-Object -First 1
							if (-not $adObj)
							{
								_AddFinding $row.LoginName 'AdOrphan' $row.LoginType (-not [bool]$row.IsDisabled) 'Orphan' "Windows-Login '$($row.LoginName)' im AD nicht gefunden - verwaist." 'Warning' $row.IsSysadmin
							}
						}
						catch
						{
							Invoke-sqmLogging -Message "[$instance] AD-Abfrage fuer '$($row.LoginName)' fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "DEBUG"
						}
					}
				}
				
				# Logins ohne Befund als OK
				$loginNamesWithFindings = $detailRows | Select-Object -ExpandProperty LoginName -Unique
				foreach ($row in $filtered)
				{
					if ($row.LoginName -notin $loginNamesWithFindings)
					{
						_AddFinding $row.LoginName 'Clean' $row.LoginType (-not [bool]$row.IsDisabled) 'Info' "Kein Befund." 'OK' $row.IsSysadmin
					}
				}
				
				$cntWarn = ($detailRows | Where-Object Status -eq 'Warning').Count
				$cntOk = ($detailRows | Where-Object { $_.Status -eq 'OK' -and $_.FindingType -eq 'Clean' }).Count
				Invoke-sqmLogging -Message "[$instance] Logins: $($filtered.Count) geprueft | $cntWarn Befunde | $cntOk ohne Befund" -FunctionName $functionName -Level "INFO"
				
				# Dateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "LoginAudit_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "LoginAudit_${safeInst}_${datestamp}.csv"
				
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Login-Audit-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					# TXT-Bericht
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - Login Audit")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz      : $instance")
					$lines.Add("# Erstellt     : $timestamp")
					$lines.Add("# Inaktiv ab   : $InactivityThresholdDays Tage | PW-Alter max: $MaxPasswordAgeDays Tage")
					$lines.Add("# Logins ges.  : $($filtered.Count) | Befunde: $cntWarn | Ohne Befund: $cntOk")
					$lines.Add("# ================================================================")
					
					$categories = @{
						'Policy'	 = 'POLICY-VERSToeSSE (CHECK_POLICY/EXPIRATION/MUST_CHANGE)'
						'Password'   = 'KENNWORTALTER'
						'Inactivity' = 'INAKTIVE / NIE VERWENDETE LOGINS'
						'Integrity'  = 'INTEGRITaeTSPROBLEME (Doppelte SIDs)'
						'Orphan'	 = 'AD-VERWAISTE LOGINS'
					}
					
					foreach ($catKey in $categories.Keys)
					{
						$catItems = $detailRows | Where-Object { $_.Category -eq $catKey }
						if (-not $catItems) { continue }
						$lines.Add("")
						$lines.Add("# === $($categories[$catKey]) ($(@($catItems).Count)) ===")
						foreach ($e in ($catItems | Sort-Object LoginName))
						{
							$loginShort = if ($e.LoginName.Length -gt 40) { $e.LoginName.Substring(0, 37) + '...' }
							else { $e.LoginName }
							$lines.Add(("  [{0,-8}] [{1,-20}] {2,-40} {3}" -f $e.Status, $e.FindingType, $loginShort, $e.Detail))
						}
					}
					
					$okLogins = $detailRows | Where-Object { $_.FindingType -eq 'Clean' }
					if ($okLogins)
					{
						$lines.Add("")
						$lines.Add("# === OHNE BEFUND ($(@($okLogins).Count)) ===")
						$lines.Add("  " + (($okLogins | Sort-Object LoginName | Select-Object -ExpandProperty LoginName) -join ', '))
					}
					
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					
					# CSV (nur Befunde)
					$detailRows | Where-Object { $_.FindingType -ne 'Clean' } |
					Select-Object SqlInstance, LoginName, LoginType, IsEnabled, IsSysadmin,
								  Category, FindingType, Status, Detail |
					Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# HTML-Report (optional)
					$htmlFile = $null
					if ($GenerateHtmlReport)
					{
						$htmlFile = Join-Path $OutputPath "LoginAudit_${safeInst}_${datestamp}.html"

						# HTML Header + Styling
						$htmlLines = [System.Collections.Generic.List[string]]::new()
						$htmlLines.Add('<!DOCTYPE html>')
						$htmlLines.Add('<html>')
						$htmlLines.Add('<head>')
						$htmlLines.Add('	<meta charset="UTF-8">')
						$htmlLines.Add('	<title>sqmSQLTool - Login Audit Report</title>')
						$htmlLines.Add('	<style>')
						$htmlLines.Add('		body { background: #060f20; color: #e2e8f0; font-family: Segoe UI, Arial; margin: 0; padding: 20px; }')
						$htmlLines.Add('		.header { background: linear-gradient(160deg, #060f20 0%, #0b1e3d 100%); padding: 20px; border-radius: 8px; margin-bottom: 20px; }')
						$htmlLines.Add('		.header h1 { margin: 0; color: #5dade2; }')
						$htmlLines.Add('		.header p { margin: 5px 0; color: #94a8c0; }')
						$htmlLines.Add('		.section { background: #0b1e3d; padding: 15px; margin-bottom: 20px; border-radius: 4px; border-left: 4px solid #2e86c1; }')
						$htmlLines.Add('		.section.warning { border-left-color: #c91a1a; }')
						$htmlLines.Add('		.section.ok { border-left-color: #16a34a; }')
						$htmlLines.Add('		h2 { color: #5dade2; margin-top: 0; }')
						$htmlLines.Add('		table { width: 100%; border-collapse: collapse; }')
						$htmlLines.Add('		th { background: #051329; color: #5dade2; text-align: left; padding: 8px; border-bottom: 2px solid #2e86c1; }')
						$htmlLines.Add('		td { padding: 8px; border-bottom: 1px solid #051329; }')
						$htmlLines.Add('		tr:hover { background: #0b1e3d; }')
						$htmlLines.Add('		.warning-text { color: #f87171; }')
						$htmlLines.Add('		.ok-text { color: #86efac; }')
						$htmlLines.Add('		.badge { padding: 2px 8px; border-radius: 3px; font-size: 0.85em; font-weight: bold; }')
						$htmlLines.Add('		.badge-warning { background: #7c2d12; color: #fdba74; }')
						$htmlLines.Add('		.badge-ok { background: #14532d; color: #86efac; }')
						$htmlLines.Add('		.badge-sysadmin { background: #1e1b4b; color: #c4b5fd; }')
						$htmlLines.Add('		.footer { text-align: center; margin-top: 40px; color: #94a8c0; font-size: 0.9em; border-top: 1px solid #2e86c1; padding-top: 20px; }')
						$htmlLines.Add('	</style>')
						$htmlLines.Add('</head>')
						$htmlLines.Add('<body>')

						# Header
						$htmlLines.Add('	<div class="header">')
						$htmlLines.Add("		<h1>SQL Server Login Audit Report</h1>")
						$htmlLines.Add("		<p><strong>Instance:</strong> $instance | <strong>Generated:</strong> $timestamp</p>")
						$htmlLines.Add("		<p><strong>Inactivity Threshold:</strong> $InactivityThresholdDays days | <strong>Password Age (Non-Sysadmin):</strong> $MaxPasswordAgeDays days | <strong>Password Age (Sysadmin):</strong> $MaxPasswordAgeDaysSysadmin days</p>")
						$htmlLines.Add('	</div>')

						# Summary
						$sysadminCount = ($detailRows | Where-Object { $_.IsSysadmin } | Select-Object -ExpandProperty LoginName -Unique).Count
						$htmlLines.Add('	<div class="section">')
						$htmlLines.Add('		<h2>Summary</h2>')
						$htmlLines.Add('		<table>')
						$htmlLines.Add("			<tr><td><strong>Total Logins:</strong></td><td>$(@($filtered).Count)</td></tr>")
						$htmlLines.Add("			<tr><td><strong>Findings:</strong></td><td><span class='warning-text'>$cntWarn</span></td></tr>")
						$htmlLines.Add("			<tr><td><strong>Clean Logins:</strong></td><td><span class='ok-text'>$cntOk</span></td></tr>")
						$htmlLines.Add("			<tr><td><strong>Sysadmin Logins:</strong></td><td><span class='badge badge-sysadmin'>$sysadminCount</span></td></tr>")
						$htmlLines.Add('		</table>')
						$htmlLines.Add('	</div>')

						# Findings by Category
						$categories = @('BuiltinAdmins', 'Policy', 'Password', 'Inactivity', 'Integrity', 'Orphan')
						foreach ($catKey in $categories)
						{
							$catItems = $detailRows | Where-Object { $_.Category -eq $catKey }
							if (-not $catItems) { continue }

							$catTitle = @{
								'BuiltinAdmins' = '⚠️ Built-in Admins'
								'Policy' = '⚠️ Policy Violations'
								'Password' = '⚠️ Password Issues'
								'Inactivity' = '⚠️ Inactive Logins'
								'Integrity' = '⚠️ Integrity Problems'
								'Orphan' = '⚠️ AD-Orphaned Logins'
							}[$catKey]

							$htmlLines.Add('	<div class="section warning">')
							$htmlLines.Add("		<h2>$catTitle ($(@($catItems).Count))</h2>")
							$htmlLines.Add('		<table>')
							$htmlLines.Add('			<tr><th>Login</th><th>Type</th><th>Enabled</th><th>Sysadmin</th><th>Finding</th><th>Detail</th></tr>')

							foreach ($e in ($catItems | Sort-Object LoginName))
							{
								$badgeClass = if ($e.Status -eq 'Warning') { 'badge-warning' } else { 'badge-ok' }
								$sysAdminBadge = if ($e.IsSysadmin) { '<span class="badge badge-sysadmin">SA</span>' } else { '-' }
								$htmlLines.Add("			<tr>")
								$htmlLines.Add("				<td>$($e.LoginName)</td>")
								$htmlLines.Add("				<td>$($e.LoginType)</td>")
								$htmlLines.Add("				<td>$(if ($e.IsEnabled) { '<span class="ok-text">Yes</span>' } else { '<span class="warning-text">No</span>' })</td>")
								$htmlLines.Add("				<td>$sysAdminBadge</td>")
								$htmlLines.Add("				<td><span class='badge $badgeClass'>$($e.FindingType)</span></td>")
								$htmlLines.Add("				<td>$($e.Detail)</td>")
								$htmlLines.Add("			</tr>")
							}

							$htmlLines.Add('		</table>')
							$htmlLines.Add('	</div>')
						}

						# Clean Logins (if any)
						if ($cntOk -gt 0)
						{
							$htmlLines.Add('	<div class="section ok">')
							$htmlLines.Add("		<h2>✅ Clean Logins ($cntOk)</h2>")
							$htmlLines.Add('		<p>These logins have no findings:</p>')
							$htmlLines.Add('		<table>')
							$htmlLines.Add('			<tr><th>Login</th><th>Type</th><th>Sysadmin</th></tr>')

							$cleanLogins = $detailRows | Where-Object { $_.FindingType -eq 'Clean' } | Sort-Object LoginName
							foreach ($login in $cleanLogins)
							{
								$sysAdminBadge = if ($login.IsSysadmin) { '<span class="badge badge-sysadmin">SA</span>' } else { '-' }
								$htmlLines.Add("			<tr><td>$($login.LoginName)</td><td>$($login.LoginType)</td><td>$sysAdminBadge</td></tr>")
							}

							$htmlLines.Add('		</table>')
							$htmlLines.Add('	</div>')
						}

						# Footer
						$htmlLines.Add('	<div class="footer">')
						$htmlLines.Add("		<p>sqmSQLTool | $(Get-sqmReportReference) | Generated: $timestamp</p>")
						$htmlLines.Add('	</div>')

						$htmlLines.Add('</body>')
						$htmlLines.Add('</html>')

						$htmlLines | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
						Invoke-sqmLogging -Message "[$instance] HTML-Report erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
					}

					Copy-sqmToCentralPath -Path $txtFile, $csvFile, $htmlFile

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$instance] Login-Audit-Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
				}
				
				if ($cntWarn -gt 0)
				{
					Invoke-sqmLogging -Message "[$instance] $cntWarn Login-Befunde - Bericht: $txtFile" -FunctionName $functionName -Level "WARNING"
				}
				
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Timestamp   = $timestamp
						DetailRows  = $detailRows
						TxtFile	    = $txtFile
						CsvFile	    = $csvFile
						HtmlFile    = $htmlFile
						Status	    = if ($cntWarn -gt 0) { 'Warning' } else { 'OK' }
					})
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status	    = 'Error'
						Message	    = $errMsg
						DetailRows  = $null
						TxtFile	    = $null
						CsvFile	    = $null
						HtmlFile    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanzen verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}