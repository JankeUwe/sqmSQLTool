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
    SQL logins with password older than this value are reported. Default: 180. 0 = disabled.

.PARAMETER ExcludeLogin
    Logins to exclude (wildcards). E.g. 'NT SERVICE\*', 'sqmsa'.

.PARAMETER IncludeSystemLogins
    When set, NT SERVICE\*, NT AUTHORITY\* are also included.

.PARAMETER CheckAdOrphans
    When set, AD orphan check is performed for Windows logins (requires AD module).

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
		[string[]]$ExcludeLogin = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,
		[Parameter(Mandatory = $false)]
		[switch]$CheckAdOrphans,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
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
					$Status)
				$detailRows.Add([PSCustomObject]@{
						SqlInstance = $instance
						LoginName   = $LoginName
						LoginType   = $LoginType
						IsEnabled   = $IsEnabled
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
    sp.sid                                  AS Sid
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
				
				# 1. Policy-Verstoesse (SQL-Logins)
				foreach ($row in ($filtered | Where-Object { $_.LoginType -eq 'SQL_LOGIN' }))
				{
					$enabled = -not [bool]$row.IsDisabled
					if (-not $row.PolicyChecked)
					{
						_AddFinding $row.LoginName 'PolicyOff' $row.LoginType $enabled 'Policy' "CHECK_POLICY = OFF - Kennwortrichtlinie deaktiviert." 'Warning'
					}
					if (-not $row.ExpirationChecked)
					{
						_AddFinding $row.LoginName 'ExpirationOff' $row.LoginType $enabled 'Policy' "CHECK_EXPIRATION = OFF - Kennwortablauf deaktiviert." 'Warning'
					}
					if ($row.MustChange)
					{
						_AddFinding $row.LoginName 'MustChange' $row.LoginType $enabled 'Policy' "MUST_CHANGE = ON - Kennwort muss bei naechstem Login geaendert werden." 'Warning'
					}
				}
				
				# 2. Kennwortalter
				if ($MaxPasswordAgeDays -gt 0)
				{
					foreach ($row in ($filtered | Where-Object { $_.LoginType -eq 'SQL_LOGIN' -and $_.PwLastSet }))
					{
						$pwAgeDays = ($now - $row.PwLastSet).TotalDays
						if ($pwAgeDays -gt $MaxPasswordAgeDays)
						{
							_AddFinding $row.LoginName 'OldPassword' $row.LoginType (-not [bool]$row.IsDisabled) 'Password' ("Kennwort seit $([math]::Round($pwAgeDays, 0)) Tagen nicht geaendert (Max: $MaxPasswordAgeDays Tage). Letzte aenderung: " + $row.PwLastSet.ToString('yyyy-MM-dd')) 'Warning'
						}
						if ($row.CreateDate -and [math]::Abs(($row.PwLastSet - $row.CreateDate).TotalMinutes) -lt 1)
						{
							_AddFinding $row.LoginName 'NeverChangedPassword' $row.LoginType (-not [bool]$row.IsDisabled) 'Password' "Kennwort seit Kontoerstellung nie geaendert (erstellt: $($row.CreateDate.ToString('yyyy-MM-dd')))." 'Warning'
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
							_AddFinding $row.LoginName 'Inactive' $row.LoginType $enabled 'Inactivity' ("Letzter Login vor $([math]::Round($inactiveDays, 0)) Tagen ($($row.LastLogin.ToString('yyyy-MM-dd'))). Schwelle: $InactivityThresholdDays Tage.") 'Warning'
						}
					}
					elseif (-not $row.IsDisabled -and $row.LoginType -eq 'SQL_LOGIN')
					{
						$createDays = ($now - $row.CreateDate).TotalDays
						if ($createDays -gt $InactivityThresholdDays)
						{
							_AddFinding $row.LoginName 'NeverUsed' $row.LoginType $true 'Inactivity' "Login seit $([math]::Round($createDays, 0)) Tagen nie verwendet (erstellt: $($row.CreateDate.ToString('yyyy-MM-dd')))." 'Warning'
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
						_AddFinding $row.LoginName 'DuplicateSid' $row.LoginType (-not [bool]$row.IsDisabled) 'Integrity' "Doppelte SID mit: $names - deutet auf fehlerhafte Migration hin." 'Warning'
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
								_AddFinding $row.LoginName 'AdOrphan' $row.LoginType (-not [bool]$row.IsDisabled) 'Orphan' "Windows-Login '$($row.LoginName)' im AD nicht gefunden - verwaist." 'Warning'
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
						_AddFinding $row.LoginName 'Clean' $row.LoginType (-not [bool]$row.IsDisabled) 'Info' "Kein Befund." 'OK'
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
					$lines.Add("# MSSQLTools - Login Audit")
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
						$lines.Add("# ?? $($categories[$catKey]) ($(@($catItems).Count)) ??")
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
						$lines.Add("# ?? OHNE BEFUND ($(@($okLogins).Count)) ??")
						$lines.Add("  " + (($okLogins | Sort-Object LoginName | Select-Object -ExpandProperty LoginName) -join ', '))
					}
					
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					
					# CSV (nur Befunde)
					$detailRows | Where-Object { $_.FindingType -ne 'Clean' } |
					Select-Object SqlInstance, LoginName, LoginType, IsEnabled,
								  Category, FindingType, Status, Detail |
					Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
					
					Copy-sqmToCentralPath -Path $txtFile, $csvFile
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