<#
.SYNOPSIS
    Creates three SQL Agent jobs for Ola Hallengren's Maintenance Solution:
    IndexOptimize (user DBs) and IntegrityCheck (user and system DBs).

.DESCRIPTION
    Creates three fully configured SQL Agent jobs on the specified SQL Server instance
    that call Ola Hallengren's IndexOptimize and DatabaseIntegrityCheck procedures.

    Prerequisite: Ola Hallengren's Maintenance Solution must be installed.
    (https://ola.hallengren.com)

    Job names are read from the module configuration (see defaults in NOTES).
    IndexOptimize uses optimized default parameters (see NOTES).

    Logging and OutputPath are controlled via the module configuration.

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the SQL connection.

.PARAMETER JobCategory
    Category for all three jobs. Default: 'Database Maintenance'.

.PARAMETER JobNameIndexOpt
    Name of the IndexOptimize job (overrides module configuration).

.PARAMETER JobNameIntUserDb
    Name of the IntegrityCheck job for user DBs (overrides module configuration).

.PARAMETER JobNameIntSysDb
    Name of the IntegrityCheck job for system DBs (overrides module configuration).

.PARAMETER ScheduleTime
    Start time for all jobs (format 'HH:mm'). Default: '23:00'.

.PARAMETER ScheduleDay
    Day of week as SQL Agent Frequency Interval (bitmask). Default: 1 (Sunday).

.PARAMETER Databases
    Database filter for IndexOptimize and IntegrityCheck user. Default: 'USER_DATABASES'.

.PARAMETER FragmentationLevel1
    Lower fragmentation threshold in percent (medium). Default: 5.

.PARAMETER FragmentationLevel2
    Upper fragmentation threshold in percent (high). Default: 30.

.PARAMETER MinNumberOfPages
    Minimum page count of an index to be considered. Default: 1000.

.PARAMETER FillFactor
    Fill factor for index rebuilds in percent. Default: 90.

.PARAMETER MaxDOP
    MAXDOP for IndexOptimize. Default: 0 (SQL Server decides).

.PARAMETER SortInTempdb
    Execute sort operations in TempDB. Default: 'Y'.

.PARAMETER UpdateStatistics
    Update statistics: 'ALL', 'COLUMNS', 'INDEX', 'NONE'. Default: 'ALL'.

.PARAMETER OnlyModifiedStatistics
    Only update modified statistics. Default: 'Y'.

.PARAMETER StatisticsSample
    Sample size for statistics update in percent. Default: 0 (SQL Server default).

.PARAMETER LogToTable
    Ola internal logging to CommandLog table. Default: 'Y'.

.PARAMETER CheckCommands
    DBCC command for IntegrityCheck. Default: 'CHECKDB'.

.PARAMETER PhysicalOnly
    Check physical consistency only (faster). Default: 'N'.

.PARAMETER NoIndex
    Skip non-clustered indexes in IntegrityCheck. Default: 'N'.

.PARAMETER OperatorName
    SQL Agent operator for email notification on failure.

.PARAMETER Update
    Replace existing jobs with the same name.

.PARAMETER ContinueOnError
    Continue with the next job on error (rarely used).

.PARAMETER EnableException
    Throw exceptions immediately.

.PARAMETER Confirm
    Request confirmation before creation.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    New-sqmOlaMaintenanceJobs -SqlInstance "SQL01"

.EXAMPLE
    New-sqmOlaMaintenanceJobs -SqlInstance "SQL01" -ScheduleTime "22:00" -ScheduleDay 64 -OperatorName "DBAs"

.NOTES
    Module configuration keys:
        OlaJobNameIndexOpt   (Default: 'OlaHH IndexOptimize - USER_DATABASES')
        OlaJobNameIntUserDb  (Default: 'OlaHH IntegrityCheck - USER_DATABASES')
        OlaJobNameIntSysDb   (Default: 'OlaHH IntegrityCheck - SYSTEM_DATABASES')
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmConfig, Test-sqmOlaInstallation, Get-sqmSaLogin
#>
function New-sqmOlaMaintenanceJobs
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$JobCategory = 'Database Maintenance',
		[Parameter(Mandatory = $false)]
		[string]$JobNameIndexOpt,
		[Parameter(Mandatory = $false)]
		[string]$JobNameIntUserDb,
		[Parameter(Mandatory = $false)]
		[string]$JobNameIntSysDb,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$ScheduleTime = '23:00',
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 127)]
		[int]$ScheduleDay = 1,
		# Sonntag

		[Parameter(Mandatory = $false)]
		[string]$Databases = 'USER_DATABASES',
		# IndexOptimize

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$FragmentationLevel1 = 5,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$FragmentationLevel2 = 30,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 2147483647)]
		[int]$MinNumberOfPages = 1000,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 100)]
		[int]$FillFactor = 90,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 64)]
		[int]$MaxDOP = 0,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$SortInTempdb = 'Y',
		[Parameter(Mandatory = $false)]
		[ValidateSet('ALL', 'COLUMNS', 'INDEX', 'NONE')]
		[string]$UpdateStatistics = 'ALL',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$OnlyModifiedStatistics = 'Y',
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 100)]
		[int]$StatisticsSample = 0,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$LogToTable = 'Y',
		# IntegrityCheck

		[Parameter(Mandatory = $false)]
		[ValidateSet('CHECKDB', 'CHECKFILEGROUP', 'CHECKTABLE')]
		[string]$CheckCommands = 'CHECKDB',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$PhysicalOnly = 'N',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Y', 'N')]
		[string]$NoIndex = 'N',
		# Allgemein

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
		
		$cfg = Get-sqmConfig
		$effJobIndexOpt = if ($JobNameIndexOpt) { $JobNameIndexOpt }
		else { $cfg['OlaJobNameIndexOpt'] }
		$effJobIntUser = if ($JobNameIntUserDb) { $JobNameIntUserDb }
		else { $cfg['OlaJobNameIntUserDb'] }
		$effJobIntSys = if ($JobNameIntSysDb) { $JobNameIntSysDb }
		else { $cfg['OlaJobNameIntSysDb'] }
		
		$result = [PSCustomObject]@{
			SqlInstance	     = $SqlInstance
			JobNameIndexOpt  = $effJobIndexOpt
			JobNameIntUserDb = $effJobIntUser
			JobNameIntSysDb  = $effJobIntSys
			IndexOptStatus   = 'Unknown'
			IntUserDbStatus  = 'Unknown'
			IntSysDbStatus   = 'Unknown'
			OverallStatus    = 'Unknown'
			Message		     = $null
		}
		
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
		
		$logDir = $cfg['LogPath']
		if (-not $logDir) { $logDir = '$env:ProgramData\sqmSQLTool\Logs' }
		$maintenanceLogDir = Join-Path $logDir 'MaintenanceLog'
		$centralLogDir = $cfg['CentralPath']
		
		$dayNames = @{ 1 = 'Sonntag'; 2 = 'Montag'; 4 = 'Dienstag'; 8 = 'Mittwoch'; 16 = 'Donnerstag'; 32 = 'Freitag'; 64 = 'Samstag' }
		$schedDayName = if ($dayNames.ContainsKey($ScheduleDay)) { $dayNames[$ScheduleDay] }
		else { "Tag $ScheduleDay" }
		$timeParts = $ScheduleTime -split ':'
		$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]
	}
	
	process
	{
		try
		{
			Invoke-sqmLogging -Message "Starte Erstellung der Ola Maintenance-Jobs auf $SqlInstance" -FunctionName $functionName -Level "INFO"
			
			# 1. Verbindung und Ola-Pruefung
			$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop
			$olaCheck = Test-sqmOlaInstallation -SqlInstance $SqlInstance -SqlCredential $SqlCredential -RequiredSet Index
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
			
			# 2. SA-Login + Job-Kategorie
			$saLogin = Get-sqmSaLogin -SqlInstance $SqlInstance -SqlCredential $SqlCredential
			if (-not $saLogin) { $saLogin = 'sa' }
			
			$existingCat = Get-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue
			if (-not $existingCat)
			{
				New-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue | Out-Null
			}
			
			# 3. Hilfsfunktion fuer Job-Erstellung
			function _CreateJob
			{
				param ($Name,
					$StepCommand,
					$StepName,
					$OutputFile,
					$Description)
				$existing = Get-DbaAgentJob @connParams -Job $Name -ErrorAction SilentlyContinue
				if ($existing)
				{
					if (-not $Update)
					{
						Invoke-sqmLogging -Message "Job '$Name' existiert bereits. Verwenden Sie -Update zum ueberschreiben." -FunctionName $functionName -Level "WARNING"
						return 'AlreadyExists'
					}
					Remove-DbaAgentJob @connParams -Job $Name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
					Invoke-sqmLogging -Message "Job '$Name' wurde entfernt (Update)." -FunctionName $functionName -Level "VERBOSE"
				}
				if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Erstelle Job '$Name'")) { return 'WhatIf' }
				New-DbaAgentJob @connParams -Job $Name -Category $JobCategory -OwnerLogin $saLogin -Description $Description -EnableException -ErrorAction Stop | Out-Null
				New-DbaAgentJobStep @connParams -Job $Name -StepName $StepName -StepId 1 -Subsystem TransactSql -Command $StepCommand -OnSuccessAction QuitWithSuccess -OnFailAction QuitWithFailure -EnableException -ErrorAction Stop | Out-Null
				# OutputFileName setzen
				try
				{
					$srv = Connect-DbaInstance @connParams -ErrorAction Stop
					$agJob = $srv.JobServer.Jobs[$Name]
					$step = $agJob.JobSteps | Where-Object { $_.ID -eq 1 }
					if ($step)
					{
						$step.OutputFileName = $OutputFile
						$step.AppendToLog = $true
						$step.Alter()
					}
				}
				catch { Invoke-sqmLogging -Message "OutputFileName konnte nicht gesetzt werden: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE" }
				if ($OperatorName)
				{
					$op = Get-DbaAgentOperator @connParams -Operator $OperatorName -ErrorAction SilentlyContinue
					if ($op)
					{
						Set-DbaAgentJob @connParams -Job $Name -OperatorToEmail $OperatorName -EmailLevel OnFailure -ErrorAction SilentlyContinue | Out-Null
					}
					else
					{
						Invoke-sqmLogging -Message "Operator '$OperatorName' nicht gefunden." -FunctionName $functionName -Level "WARNING"
					}
				}
				# Zeitplan (woechentlich)
				$schedParams = @{
					SqlInstance = $SqlInstance
					Job		    = $Name
					Schedule    = "MSSQLTools_$($Name)_Schedule"
					Force	    = $true
					StartTime   = $startTime
					FrequencyType = 'Weekly'
					FrequencyInterval = $ScheduleDay
				}
				if ($SqlCredential) { $schedParams.SqlCredential = $SqlCredential }
				New-DbaAgentSchedule @schedParams | Out-Null
				return 'Created'
			}
			
			# 4. T-SQL-Aufrufe vorbereiten
			$fillFactorParam = if ($FillFactor -gt 0) { "@FillFactor = $FillFactor," }
			else { '' }
			$maxDopParam = if ($MaxDOP -ge 0) { "@MaxDOP = $MaxDOP," }
			else { '' }
			$statSampleParam = if ($StatisticsSample -gt 0) { "@StatisticsSample = $StatisticsSample," }
			else { '' }
			
			$indexOptCall = @"
EXECUTE master.dbo.IndexOptimize
    @Databases              = '$Databases',
    @FragmentationLow       = NULL,
    @FragmentationMedium    = 'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationHigh      = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationLevel1    = $FragmentationLevel1,
    @FragmentationLevel2    = $FragmentationLevel2,
    @MinNumberOfPages       = $MinNumberOfPages,
    @SortInTempdb           = '$SortInTempdb',
    $maxDopParam
    $fillFactorParam
    @UpdateStatistics       = '$UpdateStatistics',
    @OnlyModifiedStatistics = '$OnlyModifiedStatistics',
    $statSampleParam
    @LogToTable             = '$LogToTable';
"@
			$indexOptCall = ($indexOptCall -split "`n" | Where-Object { $_.Trim() -ne '' }) -join "`n"
			
			$intUserCall = @"
EXECUTE master.dbo.DatabaseIntegrityCheck
    @Databases             = '$Databases',
    @CheckCommands         = '$CheckCommands',
    @PhysicalOnly          = '$PhysicalOnly',
    @NoIndex               = '$NoIndex',
    @LogToTable            = '$LogToTable';
"@
			$intSysCall = @"
EXECUTE master.dbo.DatabaseIntegrityCheck
    @Databases             = 'SYSTEM_DATABASES',
    @CheckCommands         = '$CheckCommands',
    @PhysicalOnly          = '$PhysicalOnly',
    @NoIndex               = '$NoIndex',
    @LogToTable            = '$LogToTable';
"@
			$outputTemplate = '$(ESCAPE_SQUOTE(SQLLOGDIR))\MaintenanceLog\{0}_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt'
			
			# 5. Jobs erstellen
			$errors = $false
			$jobResults = @{ }
			
			$jobResults['IndexOpt'] = _CreateJob $effJobIndexOpt $indexOptCall 'IndexOptimize' ($outputTemplate -f 'IndexOptimize') "Ola IndexOptimize - $Databases - $schedDayName $ScheduleTime"
			$result.IndexOptStatus = $jobResults['IndexOpt']
			if ($jobResults['IndexOpt'] -eq 'Created') { Invoke-sqmLogging -Message "IndexOptimize-Job '$effJobIndexOpt' erstellt ($schedDayName $ScheduleTime)" -FunctionName $functionName -Level "INFO" }
			
			$jobResults['IntUser'] = _CreateJob $effJobIntUser $intUserCall 'DatabaseIntegrityCheck User' ($outputTemplate -f 'IntegrityCheck_USER') "Ola DatabaseIntegrityCheck - $Databases - $schedDayName $ScheduleTime"
			$result.IntUserDbStatus = $jobResults['IntUser']
			if ($jobResults['IntUser'] -eq 'Created') { Invoke-sqmLogging -Message "IntegrityCheck User-Job '$effJobIntUser' erstellt ($schedDayName $ScheduleTime)" -FunctionName $functionName -Level "INFO" }
			
			$jobResults['IntSys'] = _CreateJob $effJobIntSys $intSysCall 'DatabaseIntegrityCheck System' ($outputTemplate -f 'IntegrityCheck_SYSTEM') "Ola DatabaseIntegrityCheck - SYSTEM_DATABASES - $schedDayName $ScheduleTime"
			$result.IntSysDbStatus = $jobResults['IntSys']
			if ($jobResults['IntSys'] -eq 'Created') { Invoke-sqmLogging -Message "IntegrityCheck System-Job '$effJobIntSys' erstellt ($schedDayName $ScheduleTime)" -FunctionName $functionName -Level "INFO" }
			
			$errors = ($jobResults.Values -contains 'Failed')
			
			# 6. Logdatei schreiben
			if (-not (Test-Path $maintenanceLogDir)) { New-Item -ItemType Directory -Path $maintenanceLogDir -Force | Out-Null }
			$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
			$datestamp = Get-Date -Format 'yyyy-MM-dd'
			$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
			$logFile = Join-Path $maintenanceLogDir "OlaMaintenance_${safeInst}_${datestamp}.txt"
			$logContent = @"
# ================================================================
# MSSQLTools - Ola Maintenance Jobs Konfigurationsbericht
# Instanz          : $SqlInstance
# Erstellt         : $timestamp
# Zeitplan         : $schedDayName $ScheduleTime
# Datenbanken      : $Databases
# ================================================================

IndexOptimize Parameter:
  FragmentationLevel1    : $FragmentationLevel1 %
  FragmentationLevel2    : $FragmentationLevel2 %
  MinNumberOfPages       : $MinNumberOfPages  (~$([math]::Round($MinNumberOfPages * 8/1024, 2)) MB)
  FillFactor             : $FillFactor %
  MaxDOP                 : $MaxDOP
  SortInTempdb           : $SortInTempdb
  UpdateStatistics       : $UpdateStatistics
  OnlyModifiedStatistics : $OnlyModifiedStatistics
  StatisticsSample       : $(if ($StatisticsSample -eq 0) { 'Default/Fullscan' }
				else { "$StatisticsSample %" })

IntegrityCheck Parameter:
  CheckCommands          : $CheckCommands
  PhysicalOnly           : $PhysicalOnly
  NoIndex                : $NoIndex

Jobs:
  IndexOptimize  : $effJobIndexOpt  ? $($result.IndexOptStatus)
  Integrity User : $effJobIntUser   ? $($result.IntUserDbStatus)
  Integrity Sys  : $effJobIntSys    ? $($result.IntSysDbStatus)
"@
			$logContent | Out-File -FilePath $logFile -Encoding UTF8 -Force
			if ($centralLogDir)
			{
				$centralSub = Join-Path $centralLogDir 'MaintenanceLog'
				if (-not (Test-Path $centralSub)) { New-Item -ItemType Directory -Path $centralSub -Force | Out-Null }
				Copy-Item $logFile (Join-Path $centralSub (Split-Path $logFile -Leaf)) -Force -ErrorAction SilentlyContinue
			}
			
			$result.OverallStatus = if ($errors) { 'PartialSuccess' }
			elseif ('WhatIf' -in $jobResults.Values) { 'WhatIf' }
			else { 'Success' }
			$result.Message = "IndexOpt: $($result.IndexOptStatus) | IntUser: $($result.IntUserDbStatus) | IntSys: $($result.IntSysDbStatus)"
			Invoke-sqmLogging -Message "Ola Maintenance-Jobs auf $SqlInstance abgeschlossen: $($result.OverallStatus)" -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Schwerer Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$result.OverallStatus = 'Failed'
			$result.Message = $errMsg
		}
		return $result
	}
}