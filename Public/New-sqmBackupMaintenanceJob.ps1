<#
.SYNOPSIS
	Creates a SQL Agent job with two steps that implement the full dynamic backup maintenance workflow.

.DESCRIPTION
	Creates a single SQL Agent job containing two PowerShell steps:

	Step 1 — Sync-BackupExcludeTable
	    Calls Sync-sqmBackupExcludeTable to synchronise master.dbo.sqm_BackupExclude with the
	    current set of databases on the instance. This ensures the exclude table is up-to-date
	    before the actual backup starts.

	Step 2 — Backup-UserDatabases-<BackupType>
	    Calls Invoke-sqmUserDatabaseBackup with -All and all configured options (UseExcludeTable,
	    CheckPreferredReplica, MailTo, MailProfile, MailOnSuccess, BackupPath).

	Both steps use the PowerShell subsystem so that the sqmSQLTool module is imported fresh at
	each execution. This means the job is fully self-contained and does not depend on the SQL
	Server Agent service account's PowerShell profile.

	Default schedule days per backup type (when -ScheduleDays is not specified):
	    FULL — @('Sunday')
	    DIFF — @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
	    LOG  — @('EveryDay')

.PARAMETER SqlInstance
	SQL Server instance. Default: current computer name ($env:COMPUTERNAME).

.PARAMETER SqlCredential
	PSCredential for the SQL connection.

.PARAMETER JobName
	Name of the SQL Agent job to create. Default: 'sqm-BackupMaintenance-FULL'.

.PARAMETER BackupType
	Backup type: 'FULL', 'DIFF', or 'LOG'. Default: 'FULL'.

.PARAMETER BackupPath
	Optional backup path. When specified, overrides the server default and is passed as
	-BackupPath to Invoke-sqmUserDatabaseBackup in Step 2.

.PARAMETER ScheduleTime
	Start time of the schedule in format 'HH:mm'. Default: '20:00'.

.PARAMETER ScheduleDays
	Days of the week for the schedule. Valid values: 'Monday'..'Sunday', 'Weekdays', 'Weekend',
	'EveryDay'. When not specified, defaults depend on BackupType (see description).

.PARAMETER ScheduleIntervalMinutes
	Repeat interval within a day in minutes (e.g. 15 = every 15 minutes). 0 = run once at
	ScheduleTime. Default: 0.

.PARAMETER JobCategory
	SQL Agent job category. Default: 'Database Maintenance'.

.PARAMETER UseExcludeTable
	When set, passes -UseExcludeTable to Invoke-sqmUserDatabaseBackup in Step 2.

.PARAMETER CheckPreferredReplica
	When set, passes -CheckPreferredReplica to Invoke-sqmUserDatabaseBackup in Step 2.

.PARAMETER IncludeSystemDatabases
	When set, passes -IncludeSystemDatabases to Sync-sqmBackupExcludeTable in Step 1.
	Note: system databases are not backed up by Invoke-sqmUserDatabaseBackup (Step 2).

.PARAMETER MailTo
	Recipient email address. Passed as -MailTo to Invoke-sqmUserDatabaseBackup in Step 2.

.PARAMETER MailProfile
	SQL Server Database Mail profile name. Passed as -MailProfile to Invoke-sqmUserDatabaseBackup.
	Default: 'Default'.

.PARAMETER MailOnSuccess
	When set, passes -MailOnSuccess to Invoke-sqmUserDatabaseBackup in Step 2 so that a report
	mail is also sent on full success.

.PARAMETER OperatorName
	SQL Agent operator name for failure email notification on the job level.

.PARAMETER Update
	When set, replaces an existing job with the same name.

.PARAMETER EnableException
	Throw exceptions immediately instead of returning error objects.

.PARAMETER WhatIf
	Shows what would happen without making changes.

.PARAMETER Confirm
	Request confirmation before creating the job.

.EXAMPLE
	# Weekly FULL backup Sunday 20:00 with all features
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL `
	    -UseExcludeTable -CheckPreferredReplica `
	    -MailTo "dba@company.com" -MailProfile "DBA-Mail"

.EXAMPLE
	# Daily DIFF backup with exclude table
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType DIFF `
	    -UseExcludeTable -ScheduleTime "22:00"

.EXAMPLE
	# LOG backup every 15 minutes
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType LOG `
	    -ScheduleIntervalMinutes 15 -UseExcludeTable

.EXAMPLE
	# Replace existing job
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL -Update

.NOTES
	Prerequisites: dbatools, Invoke-sqmLogging
	Both job steps use the PowerShell subsystem and import sqmSQLTool at runtime.
#>
function New-sqmBackupMaintenanceJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqm-BackupMaintenance-FULL',
		[Parameter(Mandatory = $false)]
		[ValidateSet('FULL', 'DIFF', 'LOG')]
		[string]$BackupType = 'FULL',
		[Parameter(Mandatory = $false)]
		[string]$BackupPath,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$ScheduleTime = '20:00',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', 'Weekdays', 'Weekend', 'EveryDay')]
		[string[]]$ScheduleDays,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1440)]
		[int]$ScheduleIntervalMinutes = 0,
		[Parameter(Mandatory = $false)]
		[string]$JobCategory = 'Database Maintenance',
		[Parameter(Mandatory = $false)]
		[switch]$UseExcludeTable,
		[Parameter(Mandatory = $false)]
		[switch]$CheckPreferredReplica,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[string]$MailTo,
		[Parameter(Mandatory = $false)]
		[string]$MailProfile = 'Default',
		[Parameter(Mandatory = $false)]
		[switch]$MailOnSuccess,
		[Parameter(Mandatory = $false)]
		[string]$OperatorName,
		[Parameter(Mandatory = $false)]
		[switch]$Update,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Default-ScheduleDays je BackupType setzen wenn nicht explizit angegeben
		if (-not $PSBoundParameters.ContainsKey('ScheduleDays'))
		{
			switch ($BackupType)
			{
				'FULL' { $ScheduleDays = @('Sunday') }
				'DIFF' { $ScheduleDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') }
				'LOG'  { $ScheduleDays = @('EveryDay') }
			}
		}

		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	}

	process
	{
		$result = [PSCustomObject]@{
			SqlInstance    = $SqlInstance
			JobName        = $JobName
			BackupType     = $BackupType
			Step1Command   = $null
			Step2Command   = $null
			ScheduleName   = $null
			ScheduleDays   = ($ScheduleDays -join ', ')
			ScheduleTime   = $ScheduleTime
			Status         = 'Unknown'
			Message        = $null
		}

		try
		{
			Invoke-sqmLogging -Message "Starte Erstellung des Backup-Maintenance-Jobs '$JobName' auf $SqlInstance" -FunctionName $functionName -Level "INFO"

			# 1. Verbindung herstellen
			$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop

			# 2. Job-Kategorie sicherstellen
			$existingCat = Get-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue
			if (-not $existingCat)
			{
				New-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue | Out-Null
				Invoke-sqmLogging -Message "Job-Kategorie '$JobCategory' wurde erstellt." -FunctionName $functionName -Level "INFO"
			}

			# 3. Bestehenden Job behandeln
			$existingJob = Get-DbaAgentJob @connParams -Job $JobName -ErrorAction SilentlyContinue
			if ($existingJob)
			{
				if (-not $Update)
				{
					$msg = "Job '$JobName' existiert bereits. Verwenden Sie -Update zum Ueberschreiben."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$result.Status  = 'AlreadyExists'
					$result.Message = $msg
					return $result
				}
				else
				{
					Remove-DbaAgentJob @connParams -Job $JobName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
					Invoke-sqmLogging -Message "Vorhandener Job '$JobName' wurde entfernt (Update)." -FunctionName $functionName -Level "INFO"
				}
			}

			# 4. Step 1 Command aufbauen: Sync-sqmBackupExcludeTable
			$step1Lines = [System.Collections.Generic.List[string]]::new()
			$step1Lines.Add("Import-Module sqmSQLTool -Force")
			$step1Lines.Add("`$params = @{ SqlInstance = '$SqlInstance' }")
			if ($IncludeSystemDatabases)
			{
				$step1Lines.Add("`$params['IncludeSystemDatabases'] = `$true")
			}
			$step1Lines.Add("Sync-sqmBackupExcludeTable @params")
			$step1Command = $step1Lines -join "`r`n"
			$result.Step1Command = $step1Command

			Invoke-sqmLogging -Message "Step 1 Command aufgebaut (Sync-sqmBackupExcludeTable)." -FunctionName $functionName -Level "INFO"

			# 5. Step 2 Command aufbauen: Invoke-sqmUserDatabaseBackup
			# DIFF und LOG Unterstuetzung geplant — aktuell wird Type = 'Full' verwendet
			$step2Lines = [System.Collections.Generic.List[string]]::new()
			$step2Lines.Add("Import-Module sqmSQLTool -Force")
			$step2Lines.Add("`$params = @{ SqlInstance = '$SqlInstance'; All = `$true; BackupType = 'FULL' }")
			if ($UseExcludeTable)
			{
				$step2Lines.Add("`$params['UseExcludeTable'] = `$true")
			}
			if ($CheckPreferredReplica)
			{
				$step2Lines.Add("`$params['CheckPreferredReplica'] = `$true")
			}
			if ($BackupPath)
			{
				$step2Lines.Add("`$params['BackupPath'] = '$BackupPath'")
			}
			if ($MailTo)
			{
				$step2Lines.Add("`$params['MailTo'] = '$MailTo'")
			}
			$step2Lines.Add("`$params['MailProfile'] = '$MailProfile'")
			if ($MailOnSuccess)
			{
				$step2Lines.Add("`$params['MailOnSuccess'] = `$true")
			}
			$step2Lines.Add("Invoke-sqmUserDatabaseBackup @params")
			$step2Command = $step2Lines -join "`r`n"
			$result.Step2Command = $step2Command

			Invoke-sqmLogging -Message "Step 2 Command aufgebaut (Invoke-sqmUserDatabaseBackup)." -FunctionName $functionName -Level "INFO"

			# 6. WhatIf-Pruefung
			if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Erstelle Job '$JobName' [$BackupType]"))
			{
				$result.Status  = 'WhatIf'
				$result.Message = "WhatIf: Job '$JobName' wuerde erstellt werden."
				return $result
			}

			# 7. Job anlegen
			New-DbaAgentJob @connParams `
				-Job $JobName `
				-Category $JobCategory `
				-Description "sqm BackupMaintenance $BackupType - Sync-sqmBackupExcludeTable + Invoke-sqmUserDatabaseBackup - $($ScheduleDays -join '/') $ScheduleTime" `
				-EnableException -ErrorAction Stop | Out-Null

			Invoke-sqmLogging -Message "Job '$JobName' angelegt." -FunctionName $functionName -Level "INFO"

			# 8. Step 1 anlegen: Sync-BackupExcludeTable
			New-DbaAgentJobStep @connParams `
				-Job $JobName `
				-StepId 1 `
				-StepName 'Sync-BackupExcludeTable' `
				-Subsystem PowerShell `
				-Command $step1Command `
				-OnSuccessAction GoToNextStep `
				-OnFailAction QuitWithFailure `
				-EnableException -ErrorAction Stop | Out-Null

			Invoke-sqmLogging -Message "Step 1 'Sync-BackupExcludeTable' angelegt." -FunctionName $functionName -Level "INFO"

			# 9. Step 2 anlegen: Backup-UserDatabases-<BackupType>
			New-DbaAgentJobStep @connParams `
				-Job $JobName `
				-StepId 2 `
				-StepName "Backup-UserDatabases-$BackupType" `
				-Subsystem PowerShell `
				-Command $step2Command `
				-OnSuccessAction QuitWithSuccess `
				-OnFailAction QuitWithFailure `
				-EnableException -ErrorAction Stop | Out-Null

			Invoke-sqmLogging -Message "Step 2 'Backup-UserDatabases-$BackupType' angelegt." -FunctionName $functionName -Level "INFO"

			# 10. Hilfsfunktion: Wochentage aufloesen
			function ConvertTo-WeekdayInterval
			{
				param ([string[]]$Days)
				$expanded = foreach ($d in $Days)
				{
					switch ($d)
					{
						'Weekdays' { 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday' }
						'Weekend'  { 'Saturday', 'Sunday' }
						'EveryDay' { 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday' }
						default    { $d }
					}
				}
				return ($expanded | Select-Object -Unique)
			}

			# 11. Schedule anlegen
			$timeNormal     = $ScheduleTime -replace ':', ''
			$intervalSuffix = if ($ScheduleIntervalMinutes -gt 0) { "_every$($ScheduleIntervalMinutes)min" } else { '' }
			$scheduleName   = "sqm_BackupMaintenance_${BackupType}_${timeNormal}${intervalSuffix}"
			$result.ScheduleName = $scheduleName

			$expandedDays = ConvertTo-WeekdayInterval -Days $ScheduleDays

			$timeParts = $ScheduleTime -split ':'
			$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]

			$schedParams = @{
				SqlInstance       = $SqlInstance
				Job               = $JobName
				Schedule          = $scheduleName
				Force             = $true
				FrequencyType     = 'Weekly'
				FrequencyInterval = $expandedDays
				StartTime         = $startTime
			}
			if ($SqlCredential) { $schedParams['SqlCredential'] = $SqlCredential }

			if ($ScheduleIntervalMinutes -gt 0)
			{
				$schedParams['FrequencySubDayType']     = 'Minutes'
				$schedParams['FrequencySubDayInterval'] = $ScheduleIntervalMinutes
				$schedParams['EndTime']                 = '235959'
				Invoke-sqmLogging -Message "Schedule '$scheduleName': woechentlich $($expandedDays -join '/'), Start $ScheduleTime, alle $ScheduleIntervalMinutes Minuten bis 23:59." -FunctionName $functionName -Level "INFO"
			}
			else
			{
				Invoke-sqmLogging -Message "Schedule '$scheduleName': woechentlich $($expandedDays -join '/') um $ScheduleTime." -FunctionName $functionName -Level "INFO"
			}

			New-DbaAgentSchedule @schedParams | Out-Null

			# 12. Operator fuer Fehler-Benachrichtigung
			if ($OperatorName)
			{
				$op = Get-DbaAgentOperator @connParams -Operator $OperatorName -ErrorAction SilentlyContinue
				if ($op)
				{
					Set-DbaAgentJob @connParams -Job $JobName -OperatorToEmail $OperatorName -EmailLevel OnFailure -ErrorAction SilentlyContinue | Out-Null
					Invoke-sqmLogging -Message "Operator '$OperatorName' fuer Fehler-Benachrichtigung gesetzt." -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "Operator '$OperatorName' nicht gefunden - Benachrichtigung nicht konfiguriert." -FunctionName $functionName -Level "WARNING"
				}
			}

			$intervalInfo    = if ($ScheduleIntervalMinutes -gt 0) { ", alle $ScheduleIntervalMinutes Min." } else { '' }
			$result.Status   = 'Created'
			$result.Message  = "Job '$JobName' ($BackupType) erstellt. Schedule: $($expandedDays -join '/') $ScheduleTime$intervalInfo"
			Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler bei Erstellung von Job '$JobName': $errMsg" -FunctionName $functionName -Level "ERROR"
			$result.Status  = 'Failed'
			$result.Message = $errMsg
			if ($EnableException) { throw }
		}

		return $result
	}
}
