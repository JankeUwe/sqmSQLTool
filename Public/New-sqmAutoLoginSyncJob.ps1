<#
.SYNOPSIS
    Creates a SQL Agent job to automatically synchronize logins in an AlwaysOn Availability Group.

.DESCRIPTION
    Sets up a recurring SQL Agent job that calls Sync-sqmLoginsToAlwaysOn on a schedule.

    Job components:
    1. Job definition (name, owner, category)
    2. Job step (PowerShell script calling Sync-sqmLoginsToAlwaysOn)
    3. Schedule (daily, weekly, custom)
    4. Notifications (job failure handling)

    The job runs under the SQL Agent service account context. It outputs results to a log file
    at C:\System\WinSrvLog\MSSQL\LoginSync_<AG>_<Date>.log

    Prerequisites:
    - sqmSQLTool module available on the SQL Server (or in shared UNC path)
    - PowerShell step type requires agent proxy with PowerShell enabled
    - Alternatively: T-SQL step calling PowerShell via xp_cmdshell

.PARAMETER SqlInstance
    The SQL Server instance (Primary replica). Default: $env:COMPUTERNAME

.PARAMETER AvailabilityGroupName
    Name of the Availability Group. If not specified, the first AG found on the instance is used.
    If multiple AGs exist: Warning is displayed, first AG is used. Specify explicitly to avoid ambiguity.

.PARAMETER JobName
    Name for the SQL Agent job. Default: "sqmLoginSync_<AGName>"

.PARAMETER Schedule
    Schedule type: 'Daily' (2:00 AM), 'Weekly' (Sunday 2:00 AM), 'Custom'
    Default: 'Daily'

.PARAMETER CustomScheduleFrequency
    For -Schedule Custom: 'Hourly', 'Daily', 'Weekly', 'Monthly'

.PARAMETER CustomScheduleInterval
    Interval number (e.g. every 4 hours, every 2 weeks)
    Default: 1

.PARAMETER TimeOfDay
    Time for daily/weekly runs. Format: 'HH:mm' (24-hour).
    Default: '02:00' (2:00 AM)

.PARAMETER DayOfWeek
    For weekly schedule: 'Monday', 'Tuesday', ..., 'Sunday'
    Default: 'Sunday'

.PARAMETER IncludeSystemLogins
    Include system logins in the sync. Default: $false

.PARAMETER AdjustAuthMode
    Allow automatic auth mode adjustment on secondaries. Default: $false

.PARAMETER SkipSecondaryServers
    Comma-separated list of replica names to skip (maintenance). Default: none

.PARAMETER Force
    When set, the job will update existing logins (password changes).
    Default: $false (only new logins are synced).
    When enabled, SafeForceMode automatically excludes system/agent accounts.

.PARAMETER ForceIncludeOnly
    When Force is set, only these logins are updated (whitelist).
    Example: 'AppUser_*', 'ServiceAccount'
    System logins still excluded per SafeForceMode.

.PARAMETER BackupLogins
    When set with -Force, creates login backups on each secondary before updating.
    Backups stored in: C:\System\WinSrvLog\MSSQL\LoginBackup_<Secondary>_<Timestamp>.sql
    Allows rollback if needed.

.PARAMETER NotificationEmail
    Email address for job failure notifications. Default: none

.PARAMETER Overwrite
    If the job already exists, drop and recreate it. Default: $false

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    New-sqmAutoLoginSyncJob -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -Schedule Daily -TimeOfDay "02:00"
    Creates a daily login sync job at 2:00 AM.

.EXAMPLE
    New-sqmAutoLoginSyncJob -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -Schedule Weekly -DayOfWeek Sunday -TimeOfDay "03:00" -IncludeSystemLogins
    Creates a weekly job (Sunday 3:00 AM) including system logins.

.EXAMPLE
    New-sqmAutoLoginSyncJob -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -Schedule Custom -CustomScheduleFrequency Hourly -CustomScheduleInterval 4
    Creates a job that runs every 4 hours.

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs: sysadmin on the SQL Server instance
    The job step uses PowerShell to call Sync-sqmLoginsToAlwaysOn
    Results logged to: C:\System\WinSrvLog\MSSQL\LoginSync_<AGName>_<Date>.log
#>
function New-sqmAutoLoginSyncJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[string]$JobName,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Daily', 'Weekly', 'Custom')]
		[string]$Schedule = 'Daily',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Hourly', 'Daily', 'Weekly', 'Monthly')]
		[string]$CustomScheduleFrequency = 'Daily',

		[Parameter(Mandatory = $false)]
		[int]$CustomScheduleInterval = 1,

		[Parameter(Mandatory = $false)]
		[string]$TimeOfDay = '02:00',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
		[string]$DayOfWeek = 'Sunday',

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[switch]$AdjustAuthMode,

		[Parameter(Mandatory = $false)]
		[string[]]$SkipSecondaryServers,

		[Parameter(Mandatory = $false)]
		[switch]$Force,

		[Parameter(Mandatory = $false)]
		[string[]]$ForceIncludeOnly,

		[Parameter(Mandatory = $false)]
		[switch]$BackupLogins,

		[Parameter(Mandatory = $false)]
		[string]$NotificationEmail,

		[Parameter(Mandatory = $false)]
		[switch]$Overwrite,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# -------------------------------------------------------------------
		# Resolve AvailabilityGroupName (if empty, use first AG)
		# -------------------------------------------------------------------
		$agQuery = @"
SELECT name FROM sys.availability_groups
ORDER BY creation_date DESC
"@

		try
		{
			$allAgs = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $agQuery -ErrorAction Stop
		}
		catch
		{
			throw "Fehler beim Abfragen von Availability Groups auf $SqlInstance : $($_.Exception.Message)"
		}

		if (-not $allAgs)
		{
			throw "Keine Availability Groups auf $SqlInstance gefunden."
		}

		# Determine which AG to use
		if ([string]::IsNullOrWhiteSpace($AvailabilityGroupName))
		{
			$AvailabilityGroupName = if ($allAgs -is [System.Collections.Generic.List[PSCustomObject]]) { $allAgs[0].name } else { $allAgs.name }

			# Warn if multiple AGs exist
			if (@($allAgs).Count -gt 1)
			{
				$agList = ($allAgs | ForEach-Object { $_.name }) -join ', '
				Invoke-sqmLogging -Message "⚠️ WARNUNG: Mehrere Availability Groups gefunden [$agList]. Verwende erste: '$AvailabilityGroupName'. Tipp: Verwende -AvailabilityGroupName um AG explizit zu wählen." `
								  -FunctionName $functionName -Level 'WARNING'
			}
		}
		else
		{
			# Verify that specified AG exists
			$agExists = $allAgs | Where-Object { $_.name -eq $AvailabilityGroupName }
			if (-not $agExists)
			{
				throw "Availability Group '$AvailabilityGroupName' nicht gefunden auf $SqlInstance. Verfügbar: $(($allAgs | ForEach-Object { $_.name }) -join ', ')"
			}
		}

		# Set JobName if not provided
		if ([string]::IsNullOrWhiteSpace($JobName))
		{
			$JobName = "sqmLoginSync_$AvailabilityGroupName"
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance für AG '$AvailabilityGroupName' (Job: '$JobName')" `
						  -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		try
		{
			# -------------------------------------------------------------------
			# 1. Check if job exists
			# -------------------------------------------------------------------
			$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction SilentlyContinue

			if ($existingJob -and -not $Overwrite)
			{
				throw "Job '$JobName' existiert bereits. Verwende -Overwrite zum Ersetzen."
			}

			if ($existingJob -and $Overwrite)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Lösche existierenden Job"))
				{
					Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -Force -ErrorAction Stop
					Invoke-sqmLogging -Message "Existierender Job '$JobName' gelöscht" -FunctionName $functionName -Level 'INFO'
				}
			}

			# -------------------------------------------------------------------
			# 2. Build PowerShell script for job step
			# -------------------------------------------------------------------
			$skipServersArg = if ($SkipSecondaryServers) { "-SkipSecondaryServers $(($SkipSecondaryServers | ForEach-Object { "'$_'" }) -join ',')" } else { "" }
			$includeSystemArg = if ($IncludeSystemLogins) { "-IncludeSystemLogins" } else { "" }
			$adjustAuthArg = if ($AdjustAuthMode) { "-AdjustAuthMode -RestartServiceIfRequired" } else { "" }
			$forceArg = if ($Force) { "-Force" } else { "" }
			$forceIncludeArg = if ($ForceIncludeOnly) { "-ForceIncludeOnly $(($ForceIncludeOnly | ForEach-Object { "'$_'" }) -join ',')" } else { "" }
			$backupArg = if ($BackupLogins) { "-BackupLogins -BackupPath 'C:\System\WinSrvLog\MSSQL'" } else { "" }

			$scriptContent = @"
`$logPath = "C:\System\WinSrvLog\MSSQL"
`$logFile = Join-Path `$logPath ("LoginSync_$AvailabilityGroupName_`$(Get-Date -Format 'yyyyMMdd_HHmmss').log")
if (-not (Test-Path `$logPath)) { New-Item -ItemType Directory -Path `$logPath -Force | Out-Null }

Import-Module sqmSQLTool -Force -ErrorAction Stop

`$params = @{
    SqlInstance = "$SqlInstance"
    AvailabilityGroupName = "$AvailabilityGroupName"
    $includeSystemArg
    $adjustAuthArg
    $skipServersArg
    $forceArg
    $forceIncludeArg
    $backupArg
}

`$result = Sync-sqmLoginsToAlwaysOn @params | ConvertTo-Json

"`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Login Sync Result:`n`$result" | Out-File -FilePath `$logFile -Append -Encoding UTF8

# Log backup files if Force was used
`$backups = `$result | Where-Object { `$_.BackupFile }
if (`$backups) {
    "Backup files created: `$(`$backups | ForEach-Object { `$_.BackupFile } | Join-String -Separator ', ')" | Out-File -FilePath `$logFile -Append -Encoding UTF8
}

# Return status (0=success, 1=failure)
`$failures = @(`$result | Where-Object Status -eq 'Failed')
exit ([int](`$failures.Count -gt 0))
"@

			# -------------------------------------------------------------------
			# 3. Parse schedule settings
			# -------------------------------------------------------------------
			$scheduleParams = @{
				SqlInstance = $SqlInstance
				Force       = $true
			}

			if ($Schedule -eq 'Daily')
			{
				$hour = [int]($TimeOfDay.Split(':')[0])
				$minute = [int]($TimeOfDay.Split(':')[1])
				$scheduleParams += @{
					FrequencyType = 'Daily'
					FrequencyInterval = 1
					ActiveStartTimeOfDay = ($hour * 10000) + ($minute * 100)
				}
			}
			elseif ($Schedule -eq 'Weekly')
			{
				$dayMap = @{
					'Monday' = 2; 'Tuesday' = 4; 'Wednesday' = 8; 'Thursday' = 16
					'Friday' = 32; 'Saturday' = 64; 'Sunday' = 1
				}
				$hour = [int]($TimeOfDay.Split(':')[0])
				$minute = [int]($TimeOfDay.Split(':')[1])
				$scheduleParams += @{
					FrequencyType = 'Weekly'
					FrequencyInterval = $dayMap[$DayOfWeek]
					ActiveStartTimeOfDay = ($hour * 10000) + ($minute * 100)
				}
			}
			else # Custom
			{
				$freqMap = @{
					'Hourly' = 4; 'Daily' = 1; 'Weekly' = 2; 'Monthly' = 3
				}
				$scheduleParams += @{
					FrequencyType = $freqMap[$CustomScheduleFrequency]
					FrequencyInterval = $CustomScheduleInterval
				}
			}

			if (-not $PSCmdlet.ShouldProcess($JobName, "Erstelle neuen SQL Agent Job"))
			{
				Invoke-sqmLogging -Message "WhatIf: Job '$JobName' würde erstellt" -FunctionName $functionName -Level 'VERBOSE'
				return [PSCustomObject]@{
					SqlInstance = $SqlInstance
					AvailabilityGroup = $AvailabilityGroupName
					JobName = $JobName
					Status = 'WhatIf'
					Message = 'Job would be created'
					Timestamp = Get-Date
				}
			}

			# -------------------------------------------------------------------
			# 4. Create job
			# -------------------------------------------------------------------
			$job = New-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction Stop
			Invoke-sqmLogging -Message "Job '$JobName' erstellt" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 5. Add job step
			# -------------------------------------------------------------------
			$stepParams = @{
				SqlInstance = $SqlInstance
				Job = $JobName
				StepName = "SyncLogins_Step1"
				Subsystem = 'PowerShell'
				Command = $scriptContent
				ErrorAction = 'Stop'
			}

			$jobStep = New-DbaAgentJobStep @stepParams
			Invoke-sqmLogging -Message "Job-Schritt hinzugefügt: SyncLogins_Step1" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 6. Add schedule
			# -------------------------------------------------------------------
			$schedName = "sch_$JobName"
			$schedule = New-DbaAgentSchedule -SqlInstance $SqlInstance -Schedule $schedName @scheduleParams -ErrorAction Stop
			$jobSchedule = Add-DbaAgentJobSchedule -SqlInstance $SqlInstance -Job $JobName -Schedule $schedName -ErrorAction Stop

			$schedDesc = if ($Schedule -eq 'Daily') { "Daily at $TimeOfDay" } `
						 elseif ($Schedule -eq 'Weekly') { "Weekly on $DayOfWeek at $TimeOfDay" } `
						 else { "$CustomScheduleFrequency every $CustomScheduleInterval" }

			Invoke-sqmLogging -Message "Zeitplan hinzugefügt: $schedDesc" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 7. Add notification if email provided
			# -------------------------------------------------------------------
			if ($NotificationEmail)
			{
				try
				{
					Set-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName `
						-NotificationLevel OnFailure `
						-NotificationEmail $NotificationEmail `
						-ErrorAction Stop

					Invoke-sqmLogging -Message "Benachrichtigung hinzugefügt: $NotificationEmail" -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					Invoke-sqmLogging -Message "Warnung: Benachrichtigung konnte nicht hinzugefügt werden: $($_.Exception.Message)" `
									  -FunctionName $functionName -Level 'WARNING'
				}
			}

			# -------------------------------------------------------------------
			# 8. Return result
			# -------------------------------------------------------------------
			Invoke-sqmLogging -Message "Job '$JobName' erfolgreich erstellt" -FunctionName $functionName -Level 'INFO'

			return [PSCustomObject]@{
				SqlInstance = $SqlInstance
				AvailabilityGroup = $AvailabilityGroupName
				JobName = $JobName
				Schedule = $schedDesc
				Status = 'Success'
				Message = "Job created and scheduled: $schedDesc"
				LogPath = 'C:\System\WinSrvLog\MSSQL\LoginSync_*.log'
				Timestamp = Get-Date
			}
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler in $functionName: $errMsg" -FunctionName $functionName -Level 'ERROR'

			if ($EnableException) { throw }

			return [PSCustomObject]@{
				SqlInstance = $SqlInstance
				AvailabilityGroup = $AvailabilityGroupName
				JobName = $JobName
				Schedule = $null
				Status = 'Failed'
				Message = $errMsg
				LogPath = $null
				Timestamp = Get-Date
			}
		}
	}
}
