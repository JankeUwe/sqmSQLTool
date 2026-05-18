<#
.SYNOPSIS
    Erstellt drei SQL Agent Jobs fuer Ola Hallengrens Wartungsloesung:
    IndexOptimize (User-DBs) und IntegrityCheck (User- und System-DBs).

.DESCRIPTION
    Legt auf der angegebenen SQL Server-Instanz drei vollstaendig konfigurierte
    SQL Agent Jobs an, die Ola Hallengrens IndexOptimize- und
    DatabaseIntegrityCheck-Prozeduren aufrufen.

    Voraussetzung: Ola Hallengrens Maintenance Solution muss installiert sein.
    (https://ola.hallengren.com)

    Job-Namen werden aus der Modulkonfiguration gelesen (Standard siehe NOTES).
    IndexOptimize verwendet optimierte Standardparameter (siehe NOTES).

    Logging und OutputPath werden ueber die Modulkonfiguration gesteuert.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: aktueller Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung.

.PARAMETER JobCategory
    Kategorie fuer alle drei Jobs. Standard: 'Database Maintenance'.

.PARAMETER JobNameIndexOpt
    Name des IndexOptimize-Jobs (ueberschreibt Modulkonfiguration).

.PARAMETER JobNameIntUserDb
    Name des IntegrityCheck-Jobs fuer User-DBs (ueberschreibt Modulkonfiguration).

.PARAMETER JobNameIntSysDb
    Name des IntegrityCheck-Jobs fuer System-DBs (ueberschreibt Modulkonfiguration).

.PARAMETER ScheduleTime
    Startzeit fuer alle Jobs (Format 'HH:mm'). Standard: '23:00'.

.PARAMETER ScheduleDay
    Wochentag als SQL Agent Frequency Interval (Bitmaske). Standard: 1 (Sonntag).

.PARAMETER Databases
    Datenbank-Filter fuer IndexOptimize und IntegrityCheck User. Standard: 'USER_DATABASES'.

.PARAMETER FragmentationLevel1
    Untere Fragmentierungsschwelle in Prozent (Medium). Standard: 5.

.PARAMETER FragmentationLevel2
    Obere Fragmentierungsschwelle in Prozent (High). Standard: 30.

.PARAMETER MinNumberOfPages
    Minimale Seitenanzahl eines Index fuer Beruecksichtigung. Standard: 1000.

.PARAMETER FillFactor
    Fuellgrad fuer Index-Rebuilds in Prozent. Standard: 90.

.PARAMETER MaxDOP
    MAXDOP fuer IndexOptimize. Standard: 0 (SQL Server entscheidet).

.PARAMETER SortInTempdb
    Sort-Operationen in TempDB ausfuehren. Standard: 'Y'.

.PARAMETER UpdateStatistics
    Statistiken aktualisieren: 'ALL', 'COLUMNS', 'INDEX', 'NONE'. Standard: 'ALL'.

.PARAMETER OnlyModifiedStatistics
    Nur geaenderte Statistiken aktualisieren. Standard: 'Y'.

.PARAMETER StatisticsSample
    Stichprobengroesse fuer Statistik-Update in Prozent. Standard: 0 (SQL Server-Default).

.PARAMETER LogToTable
    Ola-interne Protokollierung in CommandLog-Tabelle. Standard: 'Y'.

.PARAMETER CheckCommands
    DBCC-Befehl fuer IntegrityCheck. Standard: 'CHECKDB'.

.PARAMETER PhysicalOnly
    Nur physische Konsistenz pruefen (schneller). Standard: 'N'.

.PARAMETER NoIndex
    Non-Clustered Indexes bei IntegrityCheck ueberspringen. Standard: 'N'.

.PARAMETER OperatorName
    SQL Agent Operator fuer E-Mail-Benachrichtigung bei Fehlschlag.

.PARAMETER Update
    Vorhandene Jobs gleichen Namens ersetzen.

.PARAMETER ContinueOnError
    Bei Fehler mit naechstem Job fortfahren (selten verwendet).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.PARAMETER Confirm
    Bestaetigung vor der Erstellung anfordern.

.PARAMETER WhatIf
    Zeigt, was passieren wuerde.

.EXAMPLE
    New-sqmOlaMaintenanceJobs -SqlInstance "SQL01"

.EXAMPLE
    New-sqmOlaMaintenanceJobs -SqlInstance "SQL01" -ScheduleTime "22:00" -ScheduleDay 64 -OperatorName "DBAs"

.NOTES
    Modulkonfigurationsschluessel:
        OlaJobNameIndexOpt   (Default: 'OlaHH IndexOptimize - USER_DATABASES')
        OlaJobNameIntUserDb  (Default: 'OlaHH IntegrityCheck - USER_DATABASES')
        OlaJobNameIntSysDb   (Default: 'OlaHH IntegrityCheck - SYSTEM_DATABASES')
    Voraussetzung: dbatools, Invoke-sqmLogging, Get-sqmConfig, Test-sqmOlaInstallation, Get-sqmSaLogin
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