<#
.SYNOPSIS
    Creates SQL Agent jobs for FULL, DIFF, and/or LOG backups of user databases
    via Ola Hallengren's DatabaseBackup.

.DESCRIPTION
    Creates a separate SQL Agent job for each selected backup type (-Full, -Diff, -Log).
    Each job gets its own schedule with configurable days and start time.

    Backups are stored in <BackupDirectory>\Usr-db.
    Job names are read from the module configuration:
        OlaJobNameFull  (Default: 'OlaHH-UserDatabases-FULL')
        OlaJobNameDiff  (Default: 'OlaHH-UserDatabases-DIFF')
        OlaJobNameLog   (Default: 'OlaHH-UserDatabases-LOG')

    When -UseExcludeTable is set, the function reads master.dbo.sqm_BackupExclude
    (created by Sync-sqmBackupExcludeTable) for entries where IsActive=1 AND IsOrphaned=0.
    If entries are found, they are passed to Ola's @ExcludeDatabases parameter in the
    generated job step command. If the table does not exist or contains no matching rows,
    the -Databases parameter is used unchanged.

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the SQL connection.

.PARAMETER BackupDirectory
    Backup base directory. User databases are backed up to <BackupDirectory>\Usr-db.
    Default: automatically determined from SQL Server.

.PARAMETER Databases
    Database filter for Ola. E.g. 'USER_DATABASES', 'ALL_DATABASES', or
    comma-separated DB names like 'DB1,DB2'. Default: 'USER_DATABASES'.

.PARAMETER Full
    Creates a FULL backup job.

.PARAMETER FullJobName
    Overrides the job name for FULL read from the configuration.

.PARAMETER FullScheduleTime
    Start time of the FULL job in format 'HH:mm'. Default: '20:00'.

.PARAMETER FullScheduleDays
    Days of the week for the FULL job as an array. Valid values: 'Monday'..'Sunday', 'Weekdays', 'Weekend', 'EveryDay'.
    Multiple days: @('Monday','Wednesday','Friday'). Default: @('Sunday').

.PARAMETER FullScheduleIntervalMinutes
    Repeat interval for the FULL job in minutes (e.g. 60 = hourly).
    0 = no interval, job runs once at FullScheduleTime. Default: 0.

.PARAMETER Diff
    Creates a DIFF backup job.

.PARAMETER DiffJobName
    Overrides the job name for DIFF read from the configuration.

.PARAMETER DiffScheduleTime
    Start time of the DIFF job in format 'HH:mm'. Default: '20:00'.

.PARAMETER DiffScheduleDays
    Days of the week for the DIFF job. Default: @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday').

.PARAMETER DiffScheduleIntervalMinutes
    Repeat interval for the DIFF job in minutes. 0 = once. Default: 0.

.PARAMETER Log
    Creates a LOG backup job.

.PARAMETER LogJobName
    Overrides the job name for LOG read from the configuration.

.PARAMETER LogScheduleTime
    Start time of the LOG job in format 'HH:mm'. Default: '00:00'.

.PARAMETER LogScheduleDays
    Days of the week for the LOG job. Default: @('EveryDay').

.PARAMETER LogScheduleIntervalMinutes
    Repeat interval for the LOG job in minutes (e.g. 15 = every 15 minutes).
    0 = once at LogScheduleTime. Default: 0.

.PARAMETER JobCategory
    Category for all created jobs. Default: 'Database Maintenance'.

.PARAMETER CleanupTime
    Age in hours after which backup files are deleted. Default: 48. 0 = no cleanup.

.PARAMETER Compress
    Backup compression. Default: 'Y'.

.PARAMETER Verify
    Backup verification. Default: 'Y'.

.PARAMETER CheckSum
    Checksum calculation. Default: 'Y'.

.PARAMETER LogToTable
    Ola internal logging to CommandLog table. Default: 'Y'.

.PARAMETER OperatorName
    SQL Agent operator for email notification on failure.

.PARAMETER Update
    Replace existing jobs with the same name.

.PARAMETER ContinueOnError
    Continue with remaining jobs if one job fails.

.PARAMETER UseExcludeTable
    When set, reads master.dbo.sqm_BackupExclude for active, non-orphaned entries and
    adds them as @ExcludeDatabases to the Ola DatabaseBackup command in the job step.
    If the table does not exist or is empty, the Databases parameter is used unchanged.

.PARAMETER EnableException
    Throw exceptions immediately.

.PARAMETER Confirm
    Request confirmation before creation.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full

.EXAMPLE
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log

.EXAMPLE
    # Create FULL job that automatically excludes databases from sqm_BackupExclude
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -UseExcludeTable

.EXAMPLE
    # All three job types with exclude table integration
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log -UseExcludeTable -Update

.EXAMPLE
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full `
        -FullScheduleTime "22:00" -FullScheduleDays @('Sunday') `
        -OperatorName "DBAs"

.EXAMPLE
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Log `
        -LogScheduleTime "00:30" -LogScheduleDays @('EveryDay') `
        -Databases "USER_DATABASES"

.EXAMPLE
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log `
        -FullScheduleDays @('Sunday') -FullScheduleTime "21:00" `
        -DiffScheduleDays @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') `
        -DiffScheduleTime "21:00" `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -Update

.EXAMPLE
    # LOG backup every 15 minutes, daily
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Log `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -LogScheduleIntervalMinutes 15 -Update

.EXAMPLE
    # FULL on multiple days, DIFF daily, LOG every 30 minutes
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log `
        -FullScheduleDays @('Monday','Wednesday','Friday') -FullScheduleTime "22:00" `
        -DiffScheduleDays @('EveryDay') -DiffScheduleTime "22:00" `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -LogScheduleIntervalMinutes 30 -Update

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmConfig, Test-sqmOlaInstallation, Get-sqmSaLogin
    Configuration keys:
        OlaJobNameFull  (Default: 'OlaHH-UserDatabases-FULL')
        OlaJobNameDiff  (Default: 'OlaHH-UserDatabases-DIFF')
        OlaJobNameLog   (Default: 'OlaHH-UserDatabases-LOG')
    Backup subdirectory: <BackupDirectory>\Usr-db
#>
function New-sqmOlaUsrDbBackupJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject[]])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$BackupDirectory,
		[Parameter(Mandatory = $false)]
		[string]$Databases = 'USER_DATABASES',
		
		# --- FULL ---
		[Parameter(Mandatory = $false)]
		[switch]$Full,
		[Parameter(Mandatory = $false)]
		[string]$FullJobName,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$FullScheduleTime = '20:00',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', 'Weekdays', 'Weekend', 'EveryDay')]
		[string[]]$FullScheduleDays = @('Sunday'),
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1440)]
		[int]$FullScheduleIntervalMinutes = 0,

		# --- DIFF ---
		[Parameter(Mandatory = $false)]
		[switch]$Diff,
		[Parameter(Mandatory = $false)]
		[string]$DiffJobName,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$DiffScheduleTime = '20:00',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', 'Weekdays', 'Weekend', 'EveryDay')]
		[string[]]$DiffScheduleDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'),
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1440)]
		[int]$DiffScheduleIntervalMinutes = 0,

		# --- LOG ---
		[Parameter(Mandatory = $false)]
		[switch]$Log,
		[Parameter(Mandatory = $false)]
		[string]$LogJobName,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$LogScheduleTime = '00:00',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', 'Weekdays', 'Weekend', 'EveryDay')]
		[string[]]$LogScheduleDays = @('EveryDay'),
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1440)]
		[int]$LogScheduleIntervalMinutes = 0,

		# --- Allgemein ---
		[Parameter(Mandatory = $false)]
		[string]$JobCategory = 'Database Maintenance',
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 8760)]
		[int]$CleanupTime = 48,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$Compress = 'Y',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$Verify = 'Y',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$CheckSum = 'Y',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$LogToTable = 'Y',
		[Parameter(Mandatory = $false)]
		[string]$OperatorName,
		[Parameter(Mandatory = $false)]
		[switch]$Update,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$UseExcludeTable,
		[Parameter(Mandatory = $false)]
		[switch]$SkipAlwaysOnPropagation,
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
		
		if (-not $Full -and -not $Diff -and -not $Log)
		{
			$errMsg = "Mindestens einer der Parameter -Full, -Diff oder -Log muss angegeben werden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		$cfg = Get-sqmConfig
		
		# Job-Namen aus Konfiguration oder Default
		$effFullJobName = if ($FullJobName) { $FullJobName } elseif ($cfg['OlaJobNameFull']) { $cfg['OlaJobNameFull'] } else { 'OlaHH-UserDatabases-FULL' }
		$effDiffJobName = if ($DiffJobName) { $DiffJobName } elseif ($cfg['OlaJobNameDiff']) { $cfg['OlaJobNameDiff'] } else { 'OlaHH-UserDatabases-DIFF' }
		$effLogJobName  = if ($LogJobName)  { $LogJobName }  elseif ($cfg['OlaJobNameLog'])  { $cfg['OlaJobNameLog'] }  else { 'OlaHH-UserDatabases-LOG' }
		
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		# Auto-Erkennung bestehender Job-Einstellungen bei -UseExcludeTable
		$script:autoDisableDiff = $false
		if ($UseExcludeTable)
		{
			$existingFullJob = Get-DbaAgentJob @connParams -Job $effFullJobName -ErrorAction SilentlyContinue
			if ($existingFullJob)
			{
				Invoke-sqmLogging -Message "UseExcludeTable: Bestehender FULL-Job '$effFullJobName' gefunden — uebernehme Einstellungen." -FunctionName $functionName -Level "INFO"

				# Schedule-Zeit aus bestehendem Job lesen (nur wenn nicht explizit angegeben)
				if (-not $PSBoundParameters.ContainsKey('FullScheduleTime'))
				{
					$existSched = $existingFullJob.JobSchedules | Select-Object -First 1
					if ($existSched)
					{
						$t = $existSched.ActiveStartTimeOfDay
						$FullScheduleTime = '{0:D2}:{1:D2}' -f $t.Hours, $t.Minutes
						Invoke-sqmLogging -Message "FullScheduleTime aus vorhandenem Job: $FullScheduleTime" -FunctionName $functionName -Level "INFO"
					}
				}

				# Backup-Verzeichnis aus Step-Command parsen (nur wenn nicht explizit angegeben)
				if (-not $PSBoundParameters.ContainsKey('BackupDirectory'))
				{
					$existStep = $existingFullJob.JobSteps | Select-Object -First 1
					if ($existStep -and $existStep.Command -match "@Directory\s*=\s*N?'([^']+)'")
					{
						$BackupDirectory = $Matches[1] -replace '\\Usr-db$', ''
						Invoke-sqmLogging -Message "BackupDirectory aus vorhandenem Job: $BackupDirectory" -FunctionName $functionName -Level "INFO"
					}
				}

				# LOG-Schedule aus bestehendem LOG-Job lesen
				if ($Log)
				{
					$existingLogJob = Get-DbaAgentJob @connParams -Job $effLogJobName -ErrorAction SilentlyContinue
					if ($existingLogJob)
					{
						$existLogSched = $existingLogJob.JobSchedules | Select-Object -First 1
						if ($existLogSched)
						{
							if (-not $PSBoundParameters.ContainsKey('LogScheduleTime'))
							{
								$t = $existLogSched.ActiveStartTimeOfDay
								$LogScheduleTime = '{0:D2}:{1:D2}' -f $t.Hours, $t.Minutes
							}
							if (-not $PSBoundParameters.ContainsKey('LogScheduleIntervalMinutes') -and $existLogSched.FrequencySubDayInterval -gt 0)
							{
								$LogScheduleIntervalMinutes = $existLogSched.FrequencySubDayInterval
							}
						}
					}
				}
			}
			else
			{
				# Kein bestehender Job — FITS-Standardwerte: FULL taeglich 21:15, LOG alle 15 Min, DIFF deaktiviert
				Invoke-sqmLogging -Message "UseExcludeTable: Kein bestehender Job '$effFullJobName' gefunden — verwende Standardwerte (FULL 21:15 taeglich, LOG alle 15 Min, DIFF deaktiviert)." -FunctionName $functionName -Level "INFO"
				if (-not $PSBoundParameters.ContainsKey('FullScheduleTime'))         { $FullScheduleTime         = '21:15' }
				if (-not $PSBoundParameters.ContainsKey('FullScheduleDays'))         { $FullScheduleDays         = @('EveryDay') }
				if (-not $PSBoundParameters.ContainsKey('LogScheduleTime'))          { $LogScheduleTime          = '00:00' }
				if (-not $PSBoundParameters.ContainsKey('LogScheduleIntervalMinutes')) { $LogScheduleIntervalMinutes = 15 }
				$script:autoDisableDiff = $true
			}
		}

		$logDir = $cfg['LogPath']
		if (-not $logDir) { $logDir = '$env:ProgramData\sqmSQLTool\Logs' }
		$maintenanceLogDir = Join-Path $logDir 'MaintenanceLog'
		$centralLogDir = $cfg['CentralPath']
		
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
	}
	
	process
	{
		try
		{
			Invoke-sqmLogging -Message "Starte Erstellung der User-DB-Backup-Jobs auf $SqlInstance" -FunctionName $functionName -Level "INFO"
			
			# 1. Verbindung und Ola-Pruefung
			$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop
			$olaCheck = Test-sqmOlaInstallation -SqlInstance $SqlInstance -SqlCredential $SqlCredential -RequiredSet Backup

			# 1a. Bei -UseExcludeTable: Tabelle synchronisieren und DDL-Trigger sicherstellen
			if ($UseExcludeTable)
			{
				Invoke-sqmLogging -Message "UseExcludeTable: Stelle sicher dass sqm_BackupExclude und DDL-Trigger vorhanden sind." -FunctionName $functionName -Level "INFO"
				$syncParams = @{ SqlInstance = $SqlInstance; SkipAlwaysOnPropagation = $true }
				if ($SqlCredential) { $syncParams['SqlCredential'] = $SqlCredential }
				Sync-sqmBackupExcludeTable @syncParams -ErrorAction SilentlyContinue | Out-Null

				$triggerParams = @{ SqlInstance = $SqlInstance; SkipAlwaysOnPropagation = $true }
				if ($SqlCredential) { $triggerParams['SqlCredential'] = $SqlCredential }
				Register-sqmBackupExcludeTrigger @triggerParams -ErrorAction SilentlyContinue | Out-Null
			}
			foreach ($w in $olaCheck.Warnings)
			{
				Invoke-sqmLogging -Message $w -FunctionName $functionName -Level "WARNING"
			}
			if (-not $olaCheck.IsInstalled)
			{
				throw $olaCheck.Message
			}
			if (-not $olaCheck.AgentRunning)
			{
				Invoke-sqmLogging -Message "SQL Agent ist nicht gestartet - Jobs koennen nicht ausgefuehrt werden." -FunctionName $functionName -Level "WARNING"
			}
			
			# 2. Backup-Verzeichnis ermitteln
			$effBackupDir = $BackupDirectory
			if (-not $effBackupDir)
			{
				try
				{
					$regQuery = "DECLARE @BackupDirectory NVARCHAR(4000); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @BackupDirectory OUTPUT; SELECT @BackupDirectory AS BackupDirectory;"
					$regResult = Invoke-DbaQuery @connParams -Query $regQuery -ErrorAction Stop
					$effBackupDir = $regResult.BackupDirectory
				}
				catch { }
				if (-not $effBackupDir) { $effBackupDir = $sqlSrv.BackupDirectory }
			}
			if (-not $effBackupDir) { $effBackupDir = 'C:\Program Files\Microsoft SQL Server\MSSQL\Backup' }
			$usrBackupDir = "$effBackupDir\Usr-db"
			Invoke-sqmLogging -Message "Backup-Verzeichnis fuer User-Datenbanken: $usrBackupDir" -FunctionName $functionName -Level "INFO"
			
			# 3. SA-Login und Job-Kategorie
			$saLogin = Get-sqmSaLogin -SqlInstance $SqlInstance -SqlCredential $SqlCredential
			if (-not $saLogin) { $saLogin = 'sa' }
			
			$existingCat = Get-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue
			if (-not $existingCat)
			{
				New-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue | Out-Null
			}
			
			# 4. Jobs definieren
			$jobDefinitions = @()
			if ($Full)
			{
				$jobDefinitions += [PSCustomObject]@{
					BackupType      = 'FULL'
					JobName         = $effFullJobName
					ScheduleTime    = $FullScheduleTime
					ScheduleDays    = $FullScheduleDays
					IntervalMinutes = $FullScheduleIntervalMinutes
					StepSuffix      = 'FULL'
				}
			}
			if ($Diff)
			{
				$jobDefinitions += [PSCustomObject]@{
					BackupType      = 'DIFF'
					JobName         = $effDiffJobName
					ScheduleTime    = $DiffScheduleTime
					ScheduleDays    = $DiffScheduleDays
					IntervalMinutes = $DiffScheduleIntervalMinutes
					StepSuffix      = 'DIFF'
				}
			}
			if ($Log)
			{
				$jobDefinitions += [PSCustomObject]@{
					BackupType      = 'LOG'
					JobName         = $effLogJobName
					ScheduleTime    = $LogScheduleTime
					ScheduleDays    = $LogScheduleDays
					IntervalMinutes = $LogScheduleIntervalMinutes
					StepSuffix      = 'LOG'
				}
			}
			
			# 5. Hilfsfunktion: Wochentage in dbatools FrequencyInterval umrechnen
			# New-DbaAgentSchedule erwartet bei Weekly einen kombinierten Wochentag-String
			# oder die FrequencyInterval-Flags (Bitfeld: So=1, Mo=2, Di=4, Mi=8, Do=16, Fr=32, Sa=64)
			function ConvertTo-WeekdayInterval
			{
				param ([string[]]$Days)
				
				# Kurzformen aufloesen
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
			
			if ($UseExcludeTable)
			{
				Invoke-sqmLogging -Message "-UseExcludeTable gesetzt: Job-Step liest sqm_BackupExclude zur Laufzeit dynamisch." -FunctionName $functionName -Level "INFO"
			}

			# 6. Jeden Job anlegen
			$cleanupParam = if ($CleanupTime -gt 0) { "@CleanupTime = $CleanupTime," } else { '' }
			
			foreach ($jobDef in $jobDefinitions)
			{
				$result = [PSCustomObject]@{
					SqlInstance    = $SqlInstance
					BackupType     = $jobDef.BackupType
					JobName        = $jobDef.JobName
					BackupDirectory = $usrBackupDir
					Databases      = $Databases
					ScheduleTime   = $jobDef.ScheduleTime
					ScheduleDays   = ($jobDef.ScheduleDays -join ', ')
					JobStatus      = 'Unknown'
					OverallStatus  = 'Unknown'
					Message        = $null
				}
				
				try
				{
					# Vorhandenen Job behandeln
					$existingJob = Get-DbaAgentJob @connParams -Job $jobDef.JobName -ErrorAction SilentlyContinue
					if ($existingJob)
					{
						if (-not $Update)
						{
							$msg = "Job '$($jobDef.JobName)' existiert bereits. Verwenden Sie -Update zum ueberschreiben."
							Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
							$result.JobStatus    = 'AlreadyExists'
							$result.OverallStatus = 'AlreadyExists'
							$result.Message      = $msg
							$results.Add($result)
							if (-not $ContinueOnError) { continue }
							else { continue }
						}
						else
						{
							Remove-DbaAgentJob @connParams -Job $jobDef.JobName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
							Invoke-sqmLogging -Message "Vorhandener Job '$($jobDef.JobName)' wurde entfernt (Update)." -FunctionName $functionName -Level "INFO"
						}
					}
					
					# Ola-Kommando aufbauen
					if ($UseExcludeTable)
					{
						# Exclude-Liste wird bei jedem Job-Lauf frisch aus sqm_BackupExclude gelesen —
						# aenderungen in der Tabelle wirken sofort, ohne den Job neu anlegen zu muessen.
						$olaCommand = @"
DECLARE @ExcludeList NVARCHAR(MAX) = NULL;

IF OBJECT_ID(N'master.dbo.sqm_BackupExclude', N'U') IS NOT NULL
BEGIN
    SELECT @ExcludeList = STUFF((
        SELECT ',' + DatabaseName
        FROM   master.dbo.sqm_BackupExclude
        WHERE  IsActive   = 1
          AND  IsOrphaned = 0
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 1, '');
END

DECLARE @cmd NVARCHAR(MAX);
SET @cmd = N'EXECUTE master.dbo.DatabaseBackup
    @Databases  = ''$Databases'',
    @Directory  = N''$usrBackupDir'',
    @BackupType = ''$($jobDef.BackupType)'',
    @Verify     = ''$Verify'',
    $cleanupParam
    @Compress   = ''$Compress'',
    @CheckSum   = ''$CheckSum'',
    @LogToTable = ''$LogToTable'''
    + CASE
        WHEN @ExcludeList IS NOT NULL AND @ExcludeList <> ''
        THEN N',
    @ExcludeDatabases = ''' + @ExcludeList + N''''
        ELSE N''
      END
    + N';';

EXEC sp_executesql @cmd;
"@
					}
					else
					{
						$olaCommand = @"
EXECUTE master.dbo.DatabaseBackup
    @Databases  = '$Databases',
    @Directory  = N'$usrBackupDir',
    @BackupType = '$($jobDef.BackupType)',
    @Verify     = '$Verify',
    $cleanupParam
    @Compress   = '$Compress',
    @CheckSum   = '$CheckSum',
    @LogToTable = '$LogToTable';
"@
					}
					$olaCommand = ($olaCommand -split "`n" | Where-Object { $_.Trim() -ne '' }) -join "`n"
					
					$timeParts = $jobDef.ScheduleTime -split ':'
					$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]
					$outFile   = "$("`$")(ESCAPE_SQUOTE(SQLLOGDIR))\MaintenanceLog\DatabaseBackup_USR_$($jobDef.StepSuffix)_$("`$")(ESCAPE_SQUOTE(STRTDT))_$("`$")(ESCAPE_SQUOTE(STRTTM)).txt"
					
					# WhatIf-Pruefung
					if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Erstelle Job '$($jobDef.JobName)' [$($jobDef.BackupType)]"))
					{
						$result.JobStatus    = 'WhatIf'
						$result.OverallStatus = 'WhatIf'
						$result.Message      = "WhatIf: Job '$($jobDef.JobName)' wuerde erstellt werden."
						$results.Add($result)
						continue
					}
					
					# Job und Step anlegen
					New-DbaAgentJob @connParams `
						-Job $jobDef.JobName `
						-Category $JobCategory `
						-OwnerLogin $saLogin `
						-Description "Ola DatabaseBackup - $Databases - $($jobDef.BackupType) - $($jobDef.ScheduleDays -join '/') $($jobDef.ScheduleTime) - Ziel: $usrBackupDir" `
						-EnableException -ErrorAction Stop | Out-Null
					
					New-DbaAgentJobStep @connParams `
						-Job $jobDef.JobName `
						-StepName "DatabaseBackup $($jobDef.StepSuffix)" `
						-StepId 1 `
						-Subsystem TransactSql `
						-Command $olaCommand `
						-OnSuccessAction QuitWithSuccess `
						-OnFailAction QuitWithFailure `
						-EnableException -ErrorAction Stop | Out-Null
					
					# OutputFileName setzen
					try
					{
						$srv2 = Connect-DbaInstance @connParams -ErrorAction Stop
						$agJob = $srv2.JobServer.Jobs[$jobDef.JobName]
						$step  = $agJob.JobSteps | Where-Object { $_.ID -eq 1 }
						if ($step)
						{
							$step.OutputFileName = $outFile
							$step.AppendToLog    = $true
							$step.Alter()
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "OutputFileName fuer Job '$($jobDef.JobName)' konnte nicht gesetzt werden: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE"
					}
					
					# Zeitplan anlegen
					$expandedDays = ConvertTo-WeekdayInterval -Days $jobDef.ScheduleDays
					$intervalSuffix = if ($jobDef.IntervalMinutes -gt 0) { "_every$($jobDef.IntervalMinutes)min" } else { '' }
					$scheduleName   = "MSSQLTools_UsrDbBackup_$($jobDef.StepSuffix)_$($jobDef.ScheduleTime -replace ':', '')$intervalSuffix"

					$schedParams = @{
						SqlInstance       = $SqlInstance
						Job               = $jobDef.JobName
						Schedule          = $scheduleName
						Force             = $true
						FrequencyType     = 'Weekly'
						FrequencyInterval = $expandedDays
						StartTime         = $startTime
					}
					if ($SqlCredential) { $schedParams.SqlCredential = $SqlCredential }

					if ($jobDef.IntervalMinutes -gt 0)
					{
						# Wiederholt sich innerhalb des Tages alle N Minuten bis Mitternacht
						$schedParams['FrequencySubDayType']     = 'Minutes'
						$schedParams['FrequencySubDayInterval'] = $jobDef.IntervalMinutes
						$schedParams['EndTime']                 = '235959'
						Invoke-sqmLogging -Message "Schedule '$scheduleName': woechentlich $($expandedDays -join '/'), Start $($jobDef.ScheduleTime), alle $($jobDef.IntervalMinutes) Minuten bis 23:59." -FunctionName $functionName -Level "INFO"
					}
					else
					{
						Invoke-sqmLogging -Message "Schedule '$scheduleName': woechentlich $($expandedDays -join '/') um $($jobDef.ScheduleTime)." -FunctionName $functionName -Level "INFO"
					}

					New-DbaAgentSchedule @schedParams | Out-Null
					
					# Operator
					if ($OperatorName)
					{
						$op = Get-DbaAgentOperator @connParams -Operator $OperatorName -ErrorAction SilentlyContinue
						if ($op)
						{
							Set-DbaAgentJob @connParams -Job $jobDef.JobName -OperatorToEmail $OperatorName -EmailLevel OnFailure -ErrorAction SilentlyContinue | Out-Null
						}
						else
						{
							Invoke-sqmLogging -Message "Operator '$OperatorName' nicht gefunden." -FunctionName $functionName -Level "WARNING"
						}
					}
					
					# DIFF-Job im Auto-Modus (kein bestehender Job gefunden) deaktivieren
					if ($jobDef.BackupType -eq 'DIFF' -and $script:autoDisableDiff)
					{
						Set-DbaAgentJob @connParams -Job $jobDef.JobName -Disabled -ErrorAction SilentlyContinue | Out-Null
						Invoke-sqmLogging -Message "DIFF-Job '$($jobDef.JobName)' wurde automatisch deaktiviert (kein bestehender Job als Vorlage gefunden)." -FunctionName $functionName -Level "INFO"
					}

					$result.JobStatus    = 'Created'
					$result.OverallStatus = 'Success'
					$intervalInfo = if ($jobDef.IntervalMinutes -gt 0) { ", alle $($jobDef.IntervalMinutes) Min." } else { '' }
					$diffDisabledNote = if ($jobDef.BackupType -eq 'DIFF' -and $script:autoDisableDiff) { ' (deaktiviert)' } else { '' }
					$result.Message      = "Job '$($jobDef.JobName)' erstellt$diffDisabledNote. $($expandedDays -join '/') $($jobDef.ScheduleTime)$intervalInfo -> $usrBackupDir"
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = $_.Exception.Message
					Invoke-sqmLogging -Message "Fehler bei Job '$($jobDef.JobName)': $errMsg" -FunctionName $functionName -Level "ERROR"
					$result.JobStatus    = 'Failed'
					$result.OverallStatus = 'Failed'
					$result.Message      = $errMsg
					if ($EnableException) { throw }
					if (-not $ContinueOnError) { $results.Add($result); throw }
				}
				
				$results.Add($result)
			}
			
			# 7. Konfigurationsbericht schreiben
			if (-not (Test-Path $maintenanceLogDir)) { New-Item -ItemType Directory -Path $maintenanceLogDir -Force | Out-Null }
			$safeInst  = $SqlInstance -replace '[\\/:*?"<>|]', '_'
			$datestamp = Get-Date -Format 'yyyy-MM-dd'
			$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
			$logFile   = Join-Path $maintenanceLogDir "OlaUsrBackup_${safeInst}_${datestamp}.txt"
			
			$reportLines = @(
				"# ================================================================"
				"# MSSQLTools - Ola User-DB Backup Jobs Konfigurationsbericht"
				"# Instanz        : $SqlInstance"
				"# Erstellt       : $timestamp"
				"# Backup-Verz.   : $usrBackupDir"
				"# Datenbanken    : $Databases"
				"# Cleanup (h)    : $CleanupTime"
				"# Compress       : $Compress | Verify: $Verify | CheckSum: $CheckSum"
				"# ----------------------------------------------------------------"
			)
			foreach ($r in $results)
			{
				$reportLines += "# [$($r.BackupType)] $($r.JobName) | $($r.ScheduleDays) $($r.ScheduleTime) | Status: $($r.JobStatus)"
			}
			$reportLines += "# ================================================================"
			$reportLines | Out-File -FilePath $logFile -Encoding UTF8 -Force
			
			if ($centralLogDir)
			{
				$centralSub = Join-Path $centralLogDir 'MaintenanceLog'
				if (-not (Test-Path $centralSub)) { New-Item -ItemType Directory -Path $centralSub -Force | Out-Null }
				Copy-Item $logFile (Join-Path $centralSub (Split-Path $logFile -Leaf)) -Force -ErrorAction SilentlyContinue
			}
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Schwerwiegender Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			if (-not $ContinueOnError) { throw }
		}

		# AlwaysOn-Propagierung: erfolgreich erstellte Jobs auch auf Secondary-Repliken anlegen
		if (-not $SkipAlwaysOnPropagation -and $jobDefinitions -and ($results | Where-Object { $_.JobStatus -eq 'Created' }))
		{
			try
			{
				$replicaQuery = "SELECT r.replica_server_name FROM sys.availability_replicas r WHERE r.replica_server_name <> @@SERVERNAME"
				$secondaries = Invoke-DbaQuery @connParams -Database master -Query $replicaQuery -ErrorAction SilentlyContinue

				foreach ($sec in $secondaries)
				{
					$secName = $sec.replica_server_name
					Invoke-sqmLogging -Message "AlwaysOn: Propagiere Jobs auf Secondary '$secName'." -FunctionName $functionName -Level "INFO"
					try
					{
						# Parameter aus effektiven Werten (nach auto-detect) aufbauen
						$secParams = @{
							SqlInstance             = $secName
							SkipAlwaysOnPropagation = $true
							Update                  = $true
							Databases               = $Databases
							JobCategory             = $JobCategory
							CleanupTime             = $CleanupTime
							Compress                = $Compress
							Verify                  = $Verify
							CheckSum                = $CheckSum
							LogToTable              = $LogToTable
						}
						if ($SqlCredential)   { $secParams['SqlCredential']   = $SqlCredential }
						if ($UseExcludeTable) { $secParams['UseExcludeTable'] = $true }
						if ($OperatorName)    { $secParams['OperatorName']    = $OperatorName }
						if ($BackupDirectory) { $secParams['BackupDirectory'] = $BackupDirectory }

						# Job-Typ-Switches und effektive Schedule-Werte aus den erstellten Job-Definitionen
						foreach ($jd in $jobDefinitions)
						{
							switch ($jd.BackupType)
							{
								'FULL' {
									$secParams['Full']                        = $true
									$secParams['FullJobName']                 = $jd.JobName
									$secParams['FullScheduleTime']            = $jd.ScheduleTime
									$secParams['FullScheduleDays']            = $jd.ScheduleDays
									$secParams['FullScheduleIntervalMinutes'] = $jd.IntervalMinutes
								}
								'DIFF' {
									$secParams['Diff']                        = $true
									$secParams['DiffJobName']                 = $jd.JobName
									$secParams['DiffScheduleTime']            = $jd.ScheduleTime
									$secParams['DiffScheduleDays']            = $jd.ScheduleDays
									$secParams['DiffScheduleIntervalMinutes'] = $jd.IntervalMinutes
								}
								'LOG' {
									$secParams['Log']                         = $true
									$secParams['LogJobName']                  = $jd.JobName
									$secParams['LogScheduleTime']             = $jd.ScheduleTime
									$secParams['LogScheduleDays']             = $jd.ScheduleDays
									$secParams['LogScheduleIntervalMinutes']  = $jd.IntervalMinutes
								}
							}
						}

						$secResults = New-sqmOlaUsrDbBackupJob @secParams
						foreach ($sr in $secResults)
						{
							Invoke-sqmLogging -Message "AlwaysOn '$secName': [$($sr.BackupType)] $($sr.JobStatus) — $($sr.Message)" -FunctionName $functionName -Level "INFO"
							$results.Add([PSCustomObject]@{
								SqlInstance     = $secName
								BackupType      = $sr.BackupType
								JobName         = $sr.JobName
								BackupDirectory = $sr.BackupDirectory
								Databases       = $sr.Databases
								ScheduleTime    = $sr.ScheduleTime
								ScheduleDays    = $sr.ScheduleDays
								JobStatus       = "Secondary_$($sr.JobStatus)"
								OverallStatus   = $sr.OverallStatus
								Message         = "[AlwaysOn Secondary '$secName'] $($sr.Message)"
							})
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "AlwaysOn: Fehler bei Propagierung auf '$secName': $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "AlwaysOn-Erkennung nicht verfuegbar oder kein AG konfiguriert." -FunctionName $functionName -Level "VERBOSE"
			}
		}

		return $results.ToArray()
	}
}
