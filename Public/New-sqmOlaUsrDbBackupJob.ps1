<#
.SYNOPSIS
    Erstellt SQL Agent Jobs fuer FULL-, DIFF- und/oder LOG-Backup der
    User-Datenbanken via Ola Hallengrens DatabaseBackup.

.DESCRIPTION
    Legt je nach gewaehltem Backup-Typ (-Full, -Diff, -Log) einen separaten
    SQL Agent Job an. Jeder Job erhaelt seinen eigenen Zeitplan mit
    konfigurierbaren Tagen und Startzeit.

    Backups werden in <BackupDirectory>\Usr-db abgelegt.
    Job-Namen werden aus der Modulkonfiguration gelesen:
        OlaJobNameFull  (Default: 'FITS-UserDatabases-FULL')
        OlaJobNameDiff  (Default: 'FITS-UserDatabases-DIFF')
        OlaJobNameLog   (Default: 'FITS-UserDatabases-LOG')

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: aktueller Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung.

.PARAMETER BackupDirectory
    Backup-Basis-Verzeichnis. User-Datenbanken werden in <BackupDirectory>\Usr-db gesichert.
    Standard: automatisch aus SQL Server ermittelt.

.PARAMETER Databases
    Datenbank-Filter fuer Ola. Z.B. 'USER_DATABASES', 'ALL_DATABASES' oder
    kommagetrennte DB-Namen wie 'DB1,DB2'. Standard: 'USER_DATABASES'.

.PARAMETER Full
    Erstellt einen FULL-Backup-Job.

.PARAMETER FullJobName
    ueberschreibt den aus der Konfiguration gelesenen Job-Namen fuer FULL.

.PARAMETER FullScheduleTime
    Startzeit des FULL-Jobs im Format 'HH:mm'. Standard: '20:00'.

.PARAMETER FullScheduleDays
    Wochentage fuer den FULL-Job als Array. Gueltige Werte: 'Monday'..'Sunday', 'Weekdays', 'Weekend', 'EveryDay'.
    Mehrere Tage: @('Monday','Wednesday','Friday'). Standard: @('Sunday').

.PARAMETER FullScheduleIntervalMinutes
    Wiederholungsintervall fuer den FULL-Job in Minuten (z.B. 60 = stuendlich).
    0 = kein Intervall, Job laeuft einmalig zur FullScheduleTime. Standard: 0.

.PARAMETER Diff
    Erstellt einen DIFF-Backup-Job.

.PARAMETER DiffJobName
    ueberschreibt den aus der Konfiguration gelesenen Job-Namen fuer DIFF.

.PARAMETER DiffScheduleTime
    Startzeit des DIFF-Jobs im Format 'HH:mm'. Standard: '20:00'.

.PARAMETER DiffScheduleDays
    Wochentage fuer den DIFF-Job. Standard: @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday').

.PARAMETER DiffScheduleIntervalMinutes
    Wiederholungsintervall fuer den DIFF-Job in Minuten. 0 = einmalig. Standard: 0.

.PARAMETER Log
    Erstellt einen LOG-Backup-Job.

.PARAMETER LogJobName
    ueberschreibt den aus der Konfiguration gelesenen Job-Namen fuer LOG.

.PARAMETER LogScheduleTime
    Startzeit des LOG-Jobs im Format 'HH:mm'. Standard: '00:00'.

.PARAMETER LogScheduleDays
    Wochentage fuer den LOG-Job. Standard: @('EveryDay').

.PARAMETER LogScheduleIntervalMinutes
    Wiederholungsintervall fuer den LOG-Job in Minuten (z.B. 15 = alle 15 Minuten).
    0 = einmalig zur LogScheduleTime. Standard: 0.

.PARAMETER JobCategory
    Kategorie aller erzeugten Jobs. Standard: 'Database Maintenance'.

.PARAMETER CleanupTime
    Alter in Stunden, nach dem Backup-Dateien geloescht werden. Standard: 48. 0 = kein Cleanup.

.PARAMETER Compress
    Backup-Komprimierung. Standard: 'Y'.

.PARAMETER Verify
    Backup-Verifikation. Standard: 'Y'.

.PARAMETER CheckSum
    Checksum-Berechnung. Standard: 'Y'.

.PARAMETER LogToTable
    Ola-interne Protokollierung in CommandLog-Tabelle. Standard: 'Y'.

.PARAMETER OperatorName
    SQL Agent Operator fuer E-Mail-Benachrichtigung bei Fehlschlag.

.PARAMETER Update
    Vorhandene Jobs gleichen Namens ersetzen.

.PARAMETER ContinueOnError
    Bei Fehler eines Jobs fortfahren und verbleibende Jobs weiter erstellen.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.PARAMETER Confirm
    Bestaetigung vor der Erstellung anfordern.

.PARAMETER WhatIf
    Zeigt, was passieren wuerde.

.EXAMPLE
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full

.EXAMPLE
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log

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
    # LOG-Backup alle 15 Minuten, taeglich
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Log `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -LogScheduleIntervalMinutes 15 -Update

.EXAMPLE
    # FULL an mehreren Tagen, DIFF taeglich, LOG alle 30 Minuten
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log `
        -FullScheduleDays @('Monday','Wednesday','Friday') -FullScheduleTime "22:00" `
        -DiffScheduleDays @('EveryDay') -DiffScheduleTime "22:00" `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -LogScheduleIntervalMinutes 30 -Update

.NOTES
    Voraussetzungen: dbatools, Invoke-sqmLogging, Get-sqmConfig, Test-sqmOlaInstallation, Get-sqmSaLogin
    Konfigurationsschluessel:
        OlaJobNameFull  (Default: 'FITS-UserDatabases-FULL')
        OlaJobNameDiff  (Default: 'FITS-UserDatabases-DIFF')
        OlaJobNameLog   (Default: 'FITS-UserDatabases-LOG')
    Backup-Unterverzeichnis: <BackupDirectory>\Usr-db
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
		$effFullJobName = if ($FullJobName) { $FullJobName } elseif ($cfg['OlaJobNameFull']) { $cfg['OlaJobNameFull'] } else { 'FITS-UserDatabases-FULL' }
		$effDiffJobName = if ($DiffJobName) { $DiffJobName } elseif ($cfg['OlaJobNameDiff']) { $cfg['OlaJobNameDiff'] } else { 'FITS-UserDatabases-DIFF' }
		$effLogJobName  = if ($LogJobName)  { $LogJobName }  elseif ($cfg['OlaJobNameLog'])  { $cfg['OlaJobNameLog'] }  else { 'FITS-UserDatabases-LOG' }
		
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
		
		$logDir = $cfg['LogPath']
		if (-not $logDir) { $logDir = 'C:\system\WinSrvLog\MSSQL' }
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
					
					$result.JobStatus    = 'Created'
					$result.OverallStatus = 'Success'
					$intervalInfo = if ($jobDef.IntervalMinutes -gt 0) { ", alle $($jobDef.IntervalMinutes) Min." } else { '' }
					$result.Message      = "Job '$($jobDef.JobName)' erstellt. $($expandedDays -join '/') $($jobDef.ScheduleTime)$intervalInfo -> $usrBackupDir"
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
		
		return $results.ToArray()
	}
}
