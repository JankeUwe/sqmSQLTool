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

    The job runs under the SQL Agent service account context. The step is intentionally thin:
    it imports the module and calls Sync-sqmLoginsToAlwaysOn directly. Logging, retention and the
    optional AD-orphan audit live inside that function; paths come from the module settings
    (Get-sqmDefaultOutputPath, default C:\System\WinSrvLog\MSSQL). On failure the step throws, so
    SQL Agent marks the job failed and notifies the configured operator.

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
    Controls whether the job updates EXISTING logins (password / language / default-db changes),
    not only adds new ones. Default: $true - a recurring sync job should keep the secondaries
    fully in sync; without it, a password change on the primary would silently drift and break
    application logins after a failover.
    SafeForceMode (in Sync-sqmLoginsToAlwaysOn) automatically excludes all sysadmin logins, the
    SQL Agent service account and every system account, so the job cannot lock itself or any
    admin out.
    Opt out with -Force:$false (then only new logins are created, password drift is NOT corrected).

.PARAMETER ForceIncludeOnly
    When Force is set, only these logins are updated (whitelist).
    Example: 'AppUser_*', 'ServiceAccount'
    System logins still excluded per SafeForceMode.

.PARAMETER BackupLogins
    Creates a login backup on each secondary BEFORE -Force updates them (rollback safety).
    Default: $true (paired with the Force default).
    Backups stored in: C:\System\WinSrvLog\MSSQL\LoginBackup_<Secondary>_<Timestamp>.sql
    Opt out with -BackupLogins:$false.

.PARAMETER BackupRetentionDays
    Retention in days for login backups (LoginBackup_*.sql) in the configured output path
    (Get-sqmDefaultOutputPath, default C:\System\WinSrvLog\MSSQL). On each run
    Sync-sqmLoginsToAlwaysOn deletes matching files older than this value, so the share does
    not grow unbounded. When -AuditAdOrphans is active, the LoginAudit_<instance>_* reports are
    cleaned up by the same retention. Passed through to Sync-sqmLoginsToAlwaysOn.
    Default: 7. Set to 0 to disable cleanup (keep all files).

.PARAMETER AuditAdOrphans
    When set, the job runs an AD-orphan check (Invoke-sqmLoginAudit -CheckAdOrphans) on the
    primary AFTER the sync and reports Windows logins whose AD account no longer exists.
    Findings are written to the sync log and raised as a Windows Event Log warning
    (Source 'sqmSQLTool', EventId 9003) for Splunk.
    DETECTION ONLY - logins are NEVER deleted automatically. A missing AD account can be a
    transient DC/trust issue, so removal stays a deliberate manual action.
    Requires the RSAT ActiveDirectory module and AD read rights for the SQL Agent service
    account. Default: $false.

.PARAMETER NotificationOperator
    Name of an existing SQL Agent operator for OnFailure notifications. The operator must
    exist on the instance (SQL Agent notifies operators, not raw email addresses). Default: none

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
    Creates a job that runs every 4 hours (Force and BackupLogins are on by default).

.EXAMPLE
    New-sqmAutoLoginSyncJob -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -Force:$false
    Creates a job that only adds NEW logins - password/language drift is NOT corrected (legacy behaviour).

.EXAMPLE
    New-sqmAutoLoginSyncJob -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -AuditAdOrphans
    Daily sync that additionally reports AD-orphaned Windows logins after each run (no auto-delete).

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs: sysadmin on the SQL Server instance
    The job step uses PowerShell to call Sync-sqmLoginsToAlwaysOn directly.
    Results are written to the sqmSQLTool central log; backups and audit reports go to the
    configured output path (Get-sqmDefaultOutputPath, default C:\System\WinSrvLog\MSSQL).
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
		[switch]$Force = $true,

		[Parameter(Mandatory = $false)]
		[string[]]$ForceIncludeOnly,

		[Parameter(Mandatory = $false)]
		[switch]$BackupLogins = $true,

		[Parameter(Mandatory = $false)]
		[int]$BackupRetentionDays = 7,

		[Parameter(Mandatory = $false)]
		[switch]$AuditAdOrphans,

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
		# Resolve AvailabilityGroupName (if empty, use first AG)
		# -------------------------------------------------------------------
		$agQuery = @"
SELECT name FROM sys.availability_groups
ORDER BY name ASC
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

		# JobName aufloesen - in FI-TS-Umgebung muss er mit 'FITS' beginnen (wie Ola-Jobs).
		$isFitsEnv = ((Get-sqmConfig -Key 'CheckProfile') -eq 'FiTs')
		if ([string]::IsNullOrWhiteSpace($JobName))
		{
			$JobName = if ($isFitsEnv) { "FITS-LoginSync_$AvailabilityGroupName" } else { "sqmLoginSync_$AvailabilityGroupName" }
		}
		elseif ($isFitsEnv -and $JobName -notlike 'FITS*')
		{
			$enforced = "FITS-$JobName"
			Invoke-sqmLogging -Message "FI-TS-Umgebung: JobName muss mit 'FITS' beginnen. '$JobName' -> '$enforced'" -FunctionName $functionName -Level 'WARNING'
			$JobName = $enforced
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance für AG '$AvailabilityGroupName' (Job: '$JobName')" `
						  -FunctionName $functionName -Level 'INFO'

		# Effektiver Job-Modus protokollieren. Force/BackupLogins sind standardmaessig an,
		# damit ein laufender Sync-Job auch Passwort-/Sprachaenderungen uebertraegt.
		# SafeForceMode in Sync-sqmLoginsToAlwaysOn schuetzt sysadmin/Agent/System-Konten.
		Invoke-sqmLogging -Message ("Job-Modus: Force={0}, BackupLogins={1} (SafeForceMode schuetzt sysadmin/Agent/System-Konten vor Self-Lockout)." -f [bool]$Force, [bool]$BackupLogins) `
						  -FunctionName $functionName -Level 'INFO'
		if (-not $Force)
		{
			Invoke-sqmLogging -Message "Hinweis: -Force:`$false - der Job legt nur NEUE Logins an. Passwort-/Sprach-Drift wird NICHT korrigiert." `
							  -FunctionName $functionName -Level 'WARNING'
		}
		if ($AuditAdOrphans)
		{
			Invoke-sqmLogging -Message "AD-Orphan-Audit aktiv: Job meldet verwaiste Windows-Logins nach jedem Lauf (nur Detection, KEIN Auto-Delete). Benoetigt RSAT-AD + AD-Leserechte des Agent-Kontos." `
							  -FunctionName $functionName -Level 'INFO'
		}
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
			# Schlanker Step: Modul laden, Sync-sqmLoginsToAlwaysOn direkt aufrufen, bei
			# Fehlern throw -> SQL Agent markiert den Step als fehlgeschlagen (-> Operator).
			# Retention, AD-Orphan-Audit und Logging liegen IN der Funktion. Pfade kommen
			# aus den Settings (Get-sqmDefaultOutputPath) - hier wird KEIN Pfad eingebacken.
			$extraLines = [System.Collections.Generic.List[string]]::new()
			if ($Force) { $extraLines.Add("    Force                 = `$true") }
			if ($BackupLogins) { $extraLines.Add("    BackupLogins          = `$true") }
			if ($BackupRetentionDays -gt 0) { $extraLines.Add("    BackupRetentionDays   = $BackupRetentionDays") }
			if ($AuditAdOrphans) { $extraLines.Add("    AuditAdOrphans        = `$true") }
			if ($IncludeSystemLogins) { $extraLines.Add("    IncludeSystemLogins   = `$true") }
			if ($AdjustAuthMode)
			{
				$extraLines.Add("    AdjustAuthMode           = `$true")
				$extraLines.Add("    RestartServiceIfRequired = `$true")
			}
			if ($SkipSecondaryServers)
			{
				$skipArr = ($SkipSecondaryServers | ForEach-Object { "'$_'" }) -join ','
				$extraLines.Add("    SkipSecondaryServers  = @($skipArr)")
			}
			if ($ForceIncludeOnly)
			{
				$fioArr = ($ForceIncludeOnly | ForEach-Object { "'$_'" }) -join ','
				$extraLines.Add("    ForceIncludeOnly      = @($fioArr)")
			}
			$extraParamLines = $extraLines -join "`r`n"

			$scriptContent = @"
Import-Module sqmSQLTool -Force -ErrorAction Stop

`$params = @{
    SqlInstance           = "$SqlInstance"
    AvailabilityGroupName = "$AvailabilityGroupName"
$extraParamLines
}

`$result = Sync-sqmLoginsToAlwaysOn @params

`$failures = @(`$result | Where-Object Status -eq 'Failed')
if (`$failures.Count -gt 0) {
    throw "Login-Sync fehlgeschlagen fuer AG '$AvailabilityGroupName': `$(`$failures.Count) Replica(s). Details im sqmSQLTool-Log."
}
"@

			# -------------------------------------------------------------------
			# 3. Parse schedule settings
			# -------------------------------------------------------------------
			# Schedule-Werte fuer die nativen msdb-Prozeduren (sp_add_schedule).
			# Bewusst NICHT ueber New-DbaAgentSchedule: dessen Parameter (-Force, -StartTime,
			# -Schedule-Validierung) unterscheiden sich je dbatools-Version und brachen die
			# Job-Erstellung. sp_add_schedule ist auf jeder SQL-Version identisch stabil.
			$hour = [int]($TimeOfDay.Split(':')[0])
			$minute = [int]($TimeOfDay.Split(':')[1])
			$activeStartTime = [int]('{0:00}{1:00}00' -f $hour, $minute)

			# Defaults: taeglich zur angegebenen Uhrzeit
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
			# 6. Add schedule (native msdb-Prozeduren - version-stabil)
			# -------------------------------------------------------------------
			$schedName = "sch_$JobName"
			$schedSql = @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'$schedName')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = N'$schedName', @force_delete = 1;
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

			$schedDesc = if ($Schedule -eq 'Daily') { "Daily at $TimeOfDay" } `
						 elseif ($Schedule -eq 'Weekly') { "Weekly on $DayOfWeek at $TimeOfDay" } `
						 else { "$CustomScheduleFrequency every $CustomScheduleInterval" }

			Invoke-sqmLogging -Message "Zeitplan hinzugefügt: $schedDesc" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 7. OnFailure-Benachrichtigung an Operator
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
						Invoke-sqmLogging -Message "Benachrichtigung (OnFailure) an Operator '$NotificationOperator' gesetzt." -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						Invoke-sqmLogging -Message "Warnung: Benachrichtigung konnte nicht gesetzt werden: $($_.Exception.Message)" `
										  -FunctionName $functionName -Level 'WARNING'
					}
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
				LogPath = (Get-sqmDefaultOutputPath)
				Timestamp = Get-Date
			}
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler in ${functionName}: $errMsg" -FunctionName $functionName -Level 'ERROR'

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
