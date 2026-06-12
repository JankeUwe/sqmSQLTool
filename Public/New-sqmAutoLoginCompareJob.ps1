<#
.SYNOPSIS
    Creates a SQL Agent job that periodically compares logins across AlwaysOn replicas.

.DESCRIPTION
    Sets up a recurring SQL Agent job that calls Compare-sqmAlwaysOnLogins on a schedule
    (default: weekly). The job step runs the comparison, writes a TXT/HTML report to the
    output path and exits with a non-zero code when any login drift is found
    (Status Warning or Critical). Combined with -NotificationOperator (OnFailure), the job
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

.PARAMETER NotificationOperator
    Name of an existing SQL Agent operator that receives the OnFailure notification.
    Because the step fails on detected drift, this effectively becomes a "logins out of
    sync" alert. The operator must exist on the instance (SQL Agent notifies operators,
    not raw email addresses). Default: none.

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
        -NotificationOperator "DBA-Team" -OnlyDifferences -Overwrite
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
		[string]$OutputPath = (Get-sqmDefaultOutputPath),

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[switch]$OnlyDifferences,

		[Parameter(Mandatory = $false)]
		[string]$NotificationOperator,

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

		# JobName aufloesen - in FI-TS-Umgebung muss er mit 'FITS' beginnen (wie Ola-Jobs).
		$isFitsEnv = ((Get-sqmConfig -Key 'CheckProfile') -eq 'FiTs')
		if ([string]::IsNullOrWhiteSpace($JobName))
		{
			$JobName = if ($isFitsEnv) { "FITS-LoginCompare_$AvailabilityGroupName" } else { "sqmLoginCompare_$AvailabilityGroupName" }
		}
		elseif ($isFitsEnv -and $JobName -notlike 'FITS*')
		{
			$enforced = "FITS-$JobName"
			Invoke-sqmLogging -Message "FI-TS-Umgebung: JobName muss mit 'FITS' beginnen. '$JobName' -> '$enforced'" -FunctionName $functionName -Level 'WARNING'
			$JobName = $enforced
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
					Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -Confirm:$false -ErrorAction Stop
					Invoke-sqmLogging -Message "Existierender Job '$JobName' geloescht" -FunctionName $functionName -Level 'INFO'
				}
			}

			# -------------------------------------------------------------------
			# 2. Schedule-Werte fuer native msdb-Prozeduren (sp_add_schedule).
			#    Bewusst NICHT ueber New-DbaAgentSchedule - dessen Parameter (-Force,
			#    -StartTime, -Schedule-Validierung) variieren je dbatools-Version.
			# -------------------------------------------------------------------
			$hour = [int]($TimeOfDay.Split(':')[0])
			$minute = [int]($TimeOfDay.Split(':')[1])
			$activeStartTime = [int]('{0:00}{1:00}00' -f $hour, $minute)

			$freqType = 4              # 4 = taeglich, 8 = woechentlich, 16 = monatlich
			$freqInterval = 1
			$freqRecurrence = 0
			$freqSubdayType = 1        # 1 = einmal zur angegebenen Zeit
			$freqSubdayInterval = 0

			$dayMap = @{
				'Monday' = 2; 'Tuesday' = 4; 'Wednesday' = 8; 'Thursday' = 16
				'Friday' = 32; 'Saturday' = 64; 'Sunday' = 1
			}

			if ($Schedule -eq 'Weekly')
			{
				$freqType = 8
				$freqInterval = $dayMap[$DayOfWeek]
				$freqRecurrence = 1
			}
			elseif ($Schedule -eq 'Custom')
			{
				switch ($CustomScheduleFrequency)
				{
					'Hourly'
					{
						$freqType = 4; $freqInterval = 1
						$freqSubdayType = 8          # 8 = Stunden
						$freqSubdayInterval = $CustomScheduleInterval
						$activeStartTime = 0
					}
					'Daily'   { $freqType = 4;  $freqInterval = $CustomScheduleInterval }
					'Weekly'  { $freqType = 8;  $freqInterval = 1; $freqRecurrence = $CustomScheduleInterval }
					'Monthly' { $freqType = 16; $freqInterval = 1; $freqRecurrence = $CustomScheduleInterval }
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
			# 3. Job anlegen
			# -------------------------------------------------------------------
			$job = New-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction Stop
			Invoke-sqmLogging -Message "Job '$JobName' erstellt" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 4. Output-Verzeichnis + Permissions
			# -------------------------------------------------------------------
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			@('NT SERVICE\MSSQLSERVER', 'NT SERVICE\SQLSERVERAGENT') | ForEach-Object {
				$null = icacls $OutputPath /grant "$_`:F" /T /C 2>&1
			}
			Invoke-sqmLogging -Message "Permissions für Output-Verzeichnis gesetzt: $OutputPath" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 5. Job-Step (CmdExec - einfaches Copy-Script)
			# -------------------------------------------------------------------
			$jobsDir = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs'
			if (-not (Test-Path $jobsDir)) { New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null }

			# Build wrapper script with all parameters
			$switchParams = @()
			if ($IncludeSystemLogins) { $switchParams += "-IncludeSystemLogins" }
			if ($OnlyDifferences) { $switchParams += "-OnlyDifferences" }
			$switchLine = if ($switchParams) { " " + ($switchParams -join " ") } else { "" }

			$wrapperScript = @"
`$ErrorActionPreference = 'Stop'
`$VerbosePreference = 'Continue'
Import-Module sqmSQLTool -Force
try {
    Write-Verbose "Starting Compare-sqmAlwaysOnLogins..."
    `$result = Compare-sqmAlwaysOnLogins -AvailabilityGroupName '$AvailabilityGroupName' -OutputPath '$OutputPath' -FailOnDrift -NoOpen -NoReport -Confirm:`$false -ErrorAction Stop$switchLine
    Write-Verbose "Compare completed successfully"
    Write-EventLog -LogName Application -Source 'sqmSQLTool' -EventId 5000 -EntryType Information `
        -Message "Job SUCCESS: Compare-sqmAlwaysOnLogins AG='$AvailabilityGroupName'" -ErrorAction SilentlyContinue
    exit 0
} catch {
    `$errMsg = `$_.ToString()
    `$errLine = `$_.InvocationInfo.ScriptLineNumber
    Write-Verbose "ERROR on line `${errLine}: `${errMsg}"
    Write-EventLog -LogName Application -Source 'sqmSQLTool' -EventId 5001 -EntryType Error `
        -Message "Job FEHLER: Compare-sqmAlwaysOnLogins Line:`${errLine} Msg:`${errMsg}" -ErrorAction SilentlyContinue
    exit 1
}
"@
			$wrapperPath = Join-Path $jobsDir "Compare-sqmAlwaysOnLogins-$JobName.ps1"
			[System.IO.File]::WriteAllText($wrapperPath, $wrapperScript, [System.Text.Encoding]::UTF8)

			# Create CmdExec job step
			$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
			$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`""

			$jobStep = New-DbaAgentJobStep -SqlInstance $SqlInstance -Job $JobName `
				-StepName "CompareLogins_Step1" -Subsystem 'CmdExec' -Command $command -ErrorAction Stop
			Invoke-sqmLogging -Message "Job-Schritt (CmdExec) hinzugefuegt: CompareLogins_Step1, Copy-Script: $wrapperPath" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 6. Zeitplan
			# -------------------------------------------------------------------
			$schedName = "sch_$JobName"
			$schedSql = @"
-- Alle (auch mehrfach vorhandenen) Schedules dieses Namens per ID entfernen,
-- damit sp_attach_schedule den Namen wieder eindeutig aufloesen kann.
DECLARE @sid INT;
WHILE EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'$schedName')
BEGIN
    SELECT TOP (1) @sid = schedule_id FROM msdb.dbo.sysschedules WHERE name = N'$schedName';
    EXEC msdb.dbo.sp_delete_schedule @schedule_id = @sid, @force_delete = 1;
END
EXEC msdb.dbo.sp_add_schedule
    @schedule_name          = N'$schedName',
    @enabled                = 1,
    @freq_type              = $freqType,
    @freq_interval          = $freqInterval,
    @freq_subday_type       = $freqSubdayType,
    @freq_subday_interval   = $freqSubdayInterval,
    @freq_recurrence_factor = $freqRecurrence,
    @active_start_time      = $activeStartTime;
EXEC msdb.dbo.sp_attach_schedule @job_name = N'$JobName', @schedule_name = N'$schedName';
"@
			$null = Invoke-DbaQuery -SqlInstance $SqlInstance -Database msdb -Query $schedSql -EnableException -ErrorAction Stop

			$schedDesc = if ($Schedule -eq 'Daily') { "Daily at $TimeOfDay" }
			elseif ($Schedule -eq 'Weekly') { "Weekly on $DayOfWeek at $TimeOfDay" }
			else { "$CustomScheduleFrequency every $CustomScheduleInterval" }

			Invoke-sqmLogging -Message "Zeitplan hinzugefuegt: $schedDesc" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 6. OnFailure-Benachrichtigung an Operator (= Alarm bei Drift)
			#    SQL Agent benachrichtigt einen Operator (mit hinterlegter Mailadresse),
			#    nicht eine rohe E-Mail. Operator muss auf der Instanz existieren.
			# -------------------------------------------------------------------
			if ($NotificationOperator)
			{
				$op = Get-DbaAgentOperator -SqlInstance $SqlInstance -Operator $NotificationOperator -ErrorAction SilentlyContinue
				if (-not $op)
				{
					Invoke-sqmLogging -Message "Operator '$NotificationOperator' existiert nicht auf $SqlInstance - Benachrichtigung wird NICHT gesetzt. Operator anlegen (New-DbaAgentOperator) oder Namen pruefen." -FunctionName $functionName -Level 'WARNING'
				}
				else
				{
					try
					{
						Set-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName `
							-EmailLevel OnFailure `
							-EmailOperator $NotificationOperator `
							-ErrorAction Stop
						Invoke-sqmLogging -Message "Benachrichtigung (OnFailure/Drift) an Operator '$NotificationOperator' gesetzt." -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						Invoke-sqmLogging -Message "Warnung: Benachrichtigung konnte nicht gesetzt werden: $($_.Exception.Message)" `
										  -FunctionName $functionName -Level 'WARNING'
					}
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
				LogPath           = (Get-sqmDefaultOutputPath)
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
