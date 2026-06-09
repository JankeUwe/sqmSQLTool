<#
.SYNOPSIS
    Creates a SQL Agent job that periodically compares logins across AlwaysOn replicas.

.DESCRIPTION
    Sets up a recurring SQL Agent job that calls Compare-sqmAlwaysOnLogins on a schedule
    (default: weekly). The job step runs the comparison, writes a TXT/HTML report to the
    output path and exits with a non-zero code when any login drift is found
    (Status Warning or Critical). Combined with -NotificationEmail (OnFailure), the job
    automatically alerts when logins are no longer consistent across the replicas.

    This is the monitoring counterpart to New-sqmAutoLoginSyncJob: the sync job keeps
    logins aligned, this job verifies it and raises an alert on drift.

    Job components:
    1. Job definition (name, category)
    2. Job step (PowerShell calling Compare-sqmAlwaysOnLogins)
    3. Schedule (daily, weekly, custom)
    4. Notification on failure (= on detected drift) when an email is provided

    The job runs under the SQL Agent service account. Reports are written to
    C:\System\WinSrvLog\MSSQL\AlwaysOnLoginCompare_<AG>_<Date>.html|txt and a run log to
    C:\System\WinSrvLog\MSSQL\LoginCompare_<AG>_<Date>.log

    Prerequisites:
    - sqmSQLTool module available on the SQL Server (or in shared module path)
    - PowerShell step subsystem

.PARAMETER SqlInstance
    The SQL Server instance (entry replica of the AG). Default: $env:COMPUTERNAME

.PARAMETER AvailabilityGroupName
    Name of the Availability Group. If not specified, the first AG found is used
    (warning on multiple). Specify explicitly to avoid ambiguity.

.PARAMETER JobName
    Name for the SQL Agent job. Default: "sqmLoginCompare_<AGName>"

.PARAMETER Schedule
    Schedule type: 'Daily', 'Weekly', 'Custom'. Default: 'Weekly'

.PARAMETER CustomScheduleFrequency
    For -Schedule Custom: 'Hourly', 'Daily', 'Weekly', 'Monthly'

.PARAMETER CustomScheduleInterval
    Interval number for Custom schedule. Default: 1

.PARAMETER TimeOfDay
    Time for daily/weekly runs. Format 'HH:mm'. Default: '03:00'
    (offset from the sync job's default 02:00 to avoid overlap).

.PARAMETER DayOfWeek
    For weekly schedule. Default: 'Sunday'

.PARAMETER OutputPath
    Output directory for the comparison reports. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER IncludeSystemLogins
    Include system logins in the comparison. Default: $false.

.PARAMETER OnlyDifferences
    Only report logins with drift (Warning/Critical) in the output files. Default: $false.
    The alert (exit code) is always based on drift, regardless of this switch.

.PARAMETER NotificationEmail
    Email address for the OnFailure notification. Because the step fails on detected
    drift, this effectively becomes a "logins out of sync" alert. Default: none.

.PARAMETER Overwrite
    If the job already exists, drop and recreate it. Default: $false.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    New-sqmAutoLoginCompareJob -SqlInstance "PRIMARY01" -AvailabilityGroupName "AG_Prod"
    Creates a weekly comparison job (Sunday 03:00).

.EXAMPLE
    New-sqmAutoLoginCompareJob -SqlInstance "PRIMARY01" -AvailabilityGroupName "AG_Prod" `
        -Schedule Weekly -DayOfWeek Sunday -TimeOfDay "03:00" `
        -NotificationEmail "dba@kunde.de" -OnlyDifferences -Overwrite
    Weekly check with email alert on drift, report contains only differing logins.

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Compare-sqmAlwaysOnLogins
    Needs: sysadmin on the SQL Server instance
    Reports: C:\System\WinSrvLog\MSSQL\AlwaysOnLoginCompare_<AG>_<Date>.html|txt
#>
function New-sqmAutoLoginCompareJob
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
		[string]$Schedule = 'Weekly',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Hourly', 'Daily', 'Weekly', 'Monthly')]
		[string]$CustomScheduleFrequency = 'Weekly',

		[Parameter(Mandatory = $false)]
		[int]$CustomScheduleInterval = 1,

		[Parameter(Mandatory = $false)]
		[string]$TimeOfDay = '03:00',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
		[string]$DayOfWeek = 'Sunday',

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = 'C:\System\WinSrvLog\MSSQL',

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[switch]$OnlyDifferences,

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
		# AvailabilityGroupName aufloesen (erste AG wenn leer)
		# -------------------------------------------------------------------
		try
		{
			$allAgs = Invoke-DbaQuery -SqlInstance $SqlInstance `
				-Query "SELECT name FROM sys.availability_groups ORDER BY name ASC" -ErrorAction Stop
		}
		catch
		{
			throw "Fehler beim Abfragen von Availability Groups auf $SqlInstance : $($_.Exception.Message)"
		}

		if (-not $allAgs)
		{
			throw "Keine Availability Groups auf $SqlInstance gefunden."
		}

		if ([string]::IsNullOrWhiteSpace($AvailabilityGroupName))
		{
			$AvailabilityGroupName = if ($allAgs -is [System.Collections.Generic.List[PSCustomObject]]) { $allAgs[0].name } else { $allAgs.name }
			if (@($allAgs).Count -gt 1)
			{
				$agList = ($allAgs | ForEach-Object { $_.name }) -join ', '
				Invoke-sqmLogging -Message "Mehrere Availability Groups gefunden [$agList]. Verwende erste: '$AvailabilityGroupName'. Mit -AvailabilityGroupName explizit waehlen." `
								  -FunctionName $functionName -Level 'WARNING'
			}
		}
		else
		{
			if (-not ($allAgs | Where-Object { $_.name -eq $AvailabilityGroupName }))
			{
				throw "Availability Group '$AvailabilityGroupName' nicht gefunden auf $SqlInstance. Verfuegbar: $(($allAgs | ForEach-Object { $_.name }) -join ', ')"
			}
		}

		if ([string]::IsNullOrWhiteSpace($JobName))
		{
			$JobName = "sqmLoginCompare_$AvailabilityGroupName"
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance fuer AG '$AvailabilityGroupName' (Job: '$JobName')" `
						  -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		try
		{
			# -------------------------------------------------------------------
			# 1. Job vorhanden?
			# -------------------------------------------------------------------
			$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction SilentlyContinue

			if ($existingJob -and -not $Overwrite)
			{
				throw "Job '$JobName' existiert bereits. Verwende -Overwrite zum Ersetzen."
			}
			if ($existingJob -and $Overwrite)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Loesche existierenden Job"))
				{
					Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -Force -ErrorAction Stop
					Invoke-sqmLogging -Message "Existierender Job '$JobName' geloescht" -FunctionName $functionName -Level 'INFO'
				}
			}

			# -------------------------------------------------------------------
			# 2. PowerShell-Script fuer den Job-Step bauen
			# -------------------------------------------------------------------
			# Schalter werden per Indexer NACH dem Hashtable gesetzt - ein bloszes
			# "-Switch" innerhalb von @{} waere ungueltiges PowerShell.
			$includeSystemLine = if ($IncludeSystemLogins) { "`$params['IncludeSystemLogins'] = `$true" } else { "" }
			$onlyDiffLine      = if ($OnlyDifferences)      { "`$params['OnlyDifferences'] = `$true" }      else { "" }

			$scriptContent = @"
`$logPath = "C:\System\WinSrvLog\MSSQL"
if (-not (Test-Path `$logPath)) { New-Item -ItemType Directory -Path `$logPath -Force | Out-Null }
`$logFile = Join-Path `$logPath ("LoginCompare_$AvailabilityGroupName" + "_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".log")

Import-Module sqmSQLTool -Force -ErrorAction Stop

`$params = @{
    SqlInstance           = "$SqlInstance"
    AvailabilityGroupName = "$AvailabilityGroupName"
    OutputPath            = "$OutputPath"
    NoOpen                = `$true
}
$includeSystemLine
$onlyDiffLine

`$result   = Compare-sqmAlwaysOnLogins @params
`$crit     = @(`$result | Where-Object { `$_.OverallStatus -eq 'Critical' })
`$warn     = @(`$result | Where-Object { `$_.OverallStatus -eq 'Warning' })
`$ok       = @(`$result | Where-Object { `$_.OverallStatus -eq 'OK' })
`$drift    = `$crit.Count + `$warn.Count

`$summary = "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Compare AG '$AvailabilityGroupName': OK=`$(`$ok.Count) Warning=`$(`$warn.Count) Critical=`$(`$crit.Count)"
`$summary | Out-File -FilePath `$logFile -Append -Encoding UTF8
if (`$drift -gt 0) {
    "Drift erkannt - betroffene Logins:" | Out-File -FilePath `$logFile -Append -Encoding UTF8
    `$result | Where-Object { `$_.OverallStatus -ne 'OK' } |
        ForEach-Object { "  [`$(`$_.OverallStatus)] `$(`$_.LoginName)  Present=`$(`$_.Present)  MissingOn=`$(`$_.MissingOn)" } |
        Out-File -FilePath `$logFile -Append -Encoding UTF8
}

# Exit 1 bei Drift -> loest OnFailure-Benachrichtigung aus
exit ([int](`$drift -gt 0))
"@

			# -------------------------------------------------------------------
			# 3. Schedule-Parameter
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
					FrequencyType        = 'Daily'
					FrequencyInterval    = 1
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
					FrequencyType        = 'Weekly'
					FrequencyInterval    = $dayMap[$DayOfWeek]
					ActiveStartTimeOfDay = ($hour * 10000) + ($minute * 100)
				}
			}
			else # Custom
			{
				$freqMap = @{ 'Hourly' = 4; 'Daily' = 1; 'Weekly' = 2; 'Monthly' = 3 }
				$scheduleParams += @{
					FrequencyType     = $freqMap[$CustomScheduleFrequency]
					FrequencyInterval = $CustomScheduleInterval
				}
			}

			if (-not $PSCmdlet.ShouldProcess($JobName, "Erstelle neuen SQL Agent Job"))
			{
				Invoke-sqmLogging -Message "WhatIf: Job '$JobName' wuerde erstellt" -FunctionName $functionName -Level 'VERBOSE'
				return [PSCustomObject]@{
					SqlInstance       = $SqlInstance
					AvailabilityGroup = $AvailabilityGroupName
					JobName           = $JobName
					Status            = 'WhatIf'
					Message           = 'Job would be created'
					Timestamp         = Get-Date
				}
			}

			# -------------------------------------------------------------------
			# 4. Job anlegen
			# -------------------------------------------------------------------
			$job = New-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction Stop
			Invoke-sqmLogging -Message "Job '$JobName' erstellt" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 5. Job-Step
			# -------------------------------------------------------------------
			$stepParams = @{
				SqlInstance = $SqlInstance
				Job         = $JobName
				StepName    = "CompareLogins_Step1"
				Subsystem   = 'PowerShell'
				Command     = $scriptContent
				ErrorAction = 'Stop'
			}
			$jobStep = New-DbaAgentJobStep @stepParams
			Invoke-sqmLogging -Message "Job-Schritt hinzugefuegt: CompareLogins_Step1" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 6. Zeitplan
			# -------------------------------------------------------------------
			$schedName = "sch_$JobName"
			$schedule = New-DbaAgentSchedule -SqlInstance $SqlInstance -Schedule $schedName @scheduleParams -ErrorAction Stop
			$jobSchedule = Add-DbaAgentJobSchedule -SqlInstance $SqlInstance -Job $JobName -Schedule $schedName -ErrorAction Stop

			$schedDesc = if ($Schedule -eq 'Daily') { "Daily at $TimeOfDay" }
			elseif ($Schedule -eq 'Weekly') { "Weekly on $DayOfWeek at $TimeOfDay" }
			else { "$CustomScheduleFrequency every $CustomScheduleInterval" }

			Invoke-sqmLogging -Message "Zeitplan hinzugefuegt: $schedDesc" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 7. OnFailure-Benachrichtigung (= Alarm bei Drift)
			# -------------------------------------------------------------------
			if ($NotificationEmail)
			{
				try
				{
					Set-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName `
						-NotificationLevel OnFailure `
						-NotificationEmail $NotificationEmail `
						-ErrorAction Stop
					Invoke-sqmLogging -Message "Benachrichtigung (OnFailure/Drift) hinzugefuegt: $NotificationEmail" -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					Invoke-sqmLogging -Message "Warnung: Benachrichtigung konnte nicht hinzugefuegt werden: $($_.Exception.Message)" `
									  -FunctionName $functionName -Level 'WARNING'
				}
			}

			# -------------------------------------------------------------------
			# 8. Ergebnis
			# -------------------------------------------------------------------
			Invoke-sqmLogging -Message "Job '$JobName' erfolgreich erstellt" -FunctionName $functionName -Level 'INFO'

			return [PSCustomObject]@{
				SqlInstance       = $SqlInstance
				AvailabilityGroup = $AvailabilityGroupName
				JobName           = $JobName
				Schedule          = $schedDesc
				Status            = 'Success'
				Message           = "Job created and scheduled: $schedDesc"
				LogPath           = 'C:\System\WinSrvLog\MSSQL\LoginCompare_*.log'
				ReportPath        = "$OutputPath\AlwaysOnLoginCompare_*.html"
				Timestamp         = Get-Date
			}
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler in ${functionName}: $errMsg" -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			return [PSCustomObject]@{
				SqlInstance       = $SqlInstance
				AvailabilityGroup = $AvailabilityGroupName
				JobName           = $JobName
				Schedule          = $null
				Status            = 'Failed'
				Message           = $errMsg
				Timestamp         = Get-Date
			}
		}
	}
}
