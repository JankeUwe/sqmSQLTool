<#
.SYNOPSIS
    Creates a SQL Agent job for the daily full backup of SQL Server system databases
    via Ola Hallengren's DatabaseBackup.

.DESCRIPTION
    Creates a SQL Agent job that daily backs up master, model, and msdb completely.
    Backups are stored in a dedicated subdirectory \Sys-db: <BackupDirectory>\Sys-db.

    Job name is read from the module configuration (OlaJobNameSysDbBackup).
    Default: 'OlaHH-SystemDatabases-FULL'.

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the SQL connection.

.PARAMETER BackupDirectory
    Backup base directory. System databases are backed up to <BackupDirectory>\Sys-db.
    Default: automatically determined from SQL Server.

.PARAMETER JobName
    Name of the SQL Agent job (overrides module configuration).

.PARAMETER JobCategory
    Job category. Default: 'Database Maintenance'.

.PARAMETER ScheduleTime
    Start time in format 'HH:mm'. Default: '21:15'.

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
    Replace an existing job with the same name.

.PARAMETER ContinueOnError
    Continue on error (rarely used here, but included for consistency).

.PARAMETER EnableException
    Throw exceptions immediately.

.PARAMETER Confirm
    Request confirmation before creation.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    New-sqmOlaSysDbBackupJob -SqlInstance "SQL01"

.EXAMPLE
    New-sqmOlaSysDbBackupJob -SqlInstance "SQL01" -ScheduleTime "20:00" -OperatorName "DBAs"

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmConfig, Test-sqmOlaInstallation, Get-sqmSaLogin
    Configuration key: OlaJobNameSysDbBackup (Default: 'OlaHH-SystemDatabases-FULL')
#>
function New-sqmOlaSysDbBackupJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$BackupDirectory,
		[Parameter(Mandatory = $false)]
		[string]$JobName,
		[Parameter(Mandatory = $false)]
		[string]$JobCategory = 'Database Maintenance',
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$ScheduleTime = '21:15',
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
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		. "C:\CMP\SQL-Tools\sqmSQLTool\jobs\SqlVersionDetection.ps1"
		$null = Initialize-SqlTrustServerCertificate -SqlInstance $SqlInstance

		$cfg = Get-sqmConfig
		$effJobName = if ($JobName) { $JobName }
		else { $cfg['OlaJobNameSysDbBackup'] }
		if (-not $effJobName) { $effJobName = 'OlaHH-SystemDatabases-FULL' }
		
		$result = [PSCustomObject]@{
			SqlInstance	    = $SqlInstance
			JobName		    = $effJobName
			BackupDirectory = $null
			ScheduleTime    = $ScheduleTime
			JobStatus	    = 'Unknown'
			OverallStatus   = 'Unknown'
			Message		    = $null
		}
		
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
		
		$logDir = $cfg['LogPath']
		if (-not $logDir) { $logDir = '$env:ProgramData\sqmSQLTool\Logs' }
		$maintenanceLogDir = Join-Path $logDir 'MaintenanceLog'
		$centralLogDir = $cfg['CentralPath']
	}
	
	process
	{
		try
		{
			Invoke-sqmLogging -Message "Starte Erstellung des System-Datenbank-Backup-Jobs auf $SqlInstance" -FunctionName $functionName -Level "INFO"
			
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
				Invoke-sqmLogging -Message "SQL Agent ist nicht gestartet - Job kann nicht ausgefuehrt werden." -FunctionName $functionName -Level "WARNING"
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
			$sysBackupDir = "$effBackupDir\Sys-db"
			$result.BackupDirectory = $sysBackupDir
			Invoke-sqmLogging -Message "Backup-Verzeichnis fuer System-Datenbanken: $sysBackupDir" -FunctionName $functionName -Level "INFO"
			
			# 3. SA-Login und Job-Kategorie
			$saLogin = Get-sqmSaLogin -SqlInstance $SqlInstance -SqlCredential $SqlCredential
			if (-not $saLogin) { $saLogin = 'sa' }
			
			$existingCat = Get-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue
			if (-not $existingCat)
			{
				New-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue | Out-Null
			}
			
			# 4. Vorhandenen Job behandeln
			$existingJob = Get-DbaAgentJob @connParams -Job $effJobName -ErrorAction SilentlyContinue
			if ($existingJob)
			{
				if (-not $Update)
				{
					$msg = "Job '$effJobName' existiert bereits. Verwenden Sie -Update zum ueberschreiben."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$result.JobStatus = 'AlreadyExists'
					$result.OverallStatus = 'AlreadyExists'
					$result.Message = $msg
					if (-not $ContinueOnError -and -not $EnableException) { return $result }
				}
				else
				{
					Remove-DbaAgentJob @connParams -Job $effJobName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
					Invoke-sqmLogging -Message "Vorhandener Job '$effJobName' wurde entfernt (Update)." -FunctionName $functionName -Level "INFO"
				}
			}
			
			# 5. Ola-Aufruf vorbereiten
			$cleanupParam = if ($CleanupTime -gt 0) { "@CleanupTime = $CleanupTime," }
			else { '' }
			$olaCommand = @"
EXECUTE master.dbo.DatabaseBackup
    @Databases      = 'SYSTEM_DATABASES',
    @Directory      = N'$sysBackupDir',
    @BackupType     = 'FULL',
    @Verify         = '$Verify',
    $cleanupParam
    @Compress       = '$Compress',
    @CheckSum       = '$CheckSum',
    @LogToTable     = '$LogToTable';
"@
			$olaCommand = ($olaCommand -split "`n" | Where-Object { $_.Trim() -ne '' }) -join "`n"
			
			$timeParts = $ScheduleTime -split ':'
			$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]
			$outFile = '$(ESCAPE_SQUOTE(SQLLOGDIR))\MaintenanceLog\DatabaseBackup_SYS_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt'
			
			# 6. Job erstellen (wenn nicht WhatIf)
			if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Erstelle Job '$effJobName' (taeglich $ScheduleTime)"))
			{
				$result.JobStatus = 'WhatIf'
				$result.OverallStatus = 'WhatIf'
				$result.Message = "WhatIf: Job '$effJobName' wuerde erstellt werden."
				return $result
			}
			
			New-DbaAgentJob @connParams -Job $effJobName -Category $JobCategory -OwnerLogin $saLogin -Description "Ola DatabaseBackup - SYSTEM_DATABASES - taeglich $ScheduleTime - Ziel: $sysBackupDir" -EnableException -ErrorAction Stop | Out-Null
			New-DbaAgentJobStep @connParams -Job $effJobName -StepName 'DatabaseBackup System' -StepId 1 -Subsystem TransactSql -Command $olaCommand -OnSuccessAction QuitWithSuccess -OnFailAction QuitWithFailure -EnableException -ErrorAction Stop | Out-Null
			
			# OutputFileName setzen
			try
			{
				$srv = Connect-DbaInstance @connParams -ErrorAction Stop
				$agJob = $srv.JobServer.Jobs[$effJobName]
				$step = $agJob.JobSteps | Where-Object { $_.ID -eq 1 }
				if ($step)
				{
					$step.OutputFileName = $outFile
					$step.AppendToLog = $true
					$step.Alter()
				}
			}
			catch { Invoke-sqmLogging -Message "OutputFileName konnte nicht gesetzt werden: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE" }
			
			# Zeitplan
			$schedParams = @{
				SqlInstance = $SqlInstance
				Job		    = $effJobName
				Schedule    = "MSSQLTools_SysDbBackup_Daily_$($ScheduleTime -replace ':', '')"
				Force	    = $true
				FrequencyType = 'Daily'
				FrequencyInterval = 1
				StartTime   = $startTime
			}
			if ($SqlCredential) { $schedParams.SqlCredential = $SqlCredential }
			New-DbaAgentSchedule @schedParams | Out-Null
			
			# Operator
			if ($OperatorName)
			{
				$op = Get-DbaAgentOperator @connParams -Operator $OperatorName -ErrorAction SilentlyContinue
				if ($op)
				{
					Set-DbaAgentJob @connParams -Job $effJobName -EmailOperator $OperatorName -EmailLevel OnFailure -ErrorAction SilentlyContinue | Out-Null
				}
				else
				{
					Invoke-sqmLogging -Message "Operator '$OperatorName' nicht gefunden." -FunctionName $functionName -Level "WARNING"
				}
			}
			
			$result.JobStatus = 'Created'
			$result.OverallStatus = 'Success'
			$result.Message = "Job '$effJobName' erstellt. Taeglich $ScheduleTime ? $sysBackupDir"
			Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
			
			# 7. Konfigurationsbericht schreiben
			if (-not (Test-Path $maintenanceLogDir)) { New-Item -ItemType Directory -Path $maintenanceLogDir -Force | Out-Null }
			$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
			$datestamp = Get-Date -Format 'yyyy-MM-dd'
			$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
			$logFile = Join-Path $maintenanceLogDir "OlaSysBackup_${safeInst}_${datestamp}.txt"
			$logContent = @"
# ================================================================
# MSSQLTools - Ola System-DB Backup Job Konfigurationsbericht
# Instanz        : $SqlInstance
# Erstellt       : $timestamp
# Job            : $effJobName
# Zeitplan       : Taeglich $ScheduleTime
# Backup-Verz.   : $sysBackupDir
# Cleanup (h)    : $CleanupTime
# Compress       : $Compress | Verify: $Verify | CheckSum: $CheckSum
# Status         : $($result.JobStatus)
# ================================================================
"@
			$logContent | Out-File -FilePath $logFile -Encoding UTF8 -Force
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
			Invoke-sqmLogging -Message "Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$result.OverallStatus = 'Failed'
			$result.Message = $errMsg
			if (-not $ContinueOnError) { throw }
		}
		return $result
	}
}