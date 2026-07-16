<#
.SYNOPSIS
    Configures the Query Store, reads from it, detects issues and saves reports.

.DESCRIPTION
    Comprehensive Query Store management for one, multiple or all user databases.

    Operating modes (switches, combinable):
      -Configure  Enables and configures the Query Store (ALTER DATABASE SET QUERY_STORE).
      -Query      Reads the top-N queries from the Query Store (by duration, CPU, reads, etc.).
      -Diagnose   Detects issues: READ_ONLY status, memory pressure, plan regression,
                  forced plan failures, unstable execution plans.

    If none of the three switches are specified, -Query and -Diagnose are executed
    (report mode).

    Results are returned as PSCustomObject and optionally saved as CSV/TXT.

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    One or more databases. Ignored when -All is set.

.PARAMETER All
    Process all accessible user databases.

.PARAMETER Configure
    Configure Query Store (enable/set parameters).

.PARAMETER Query
    Read top-N queries from the Query Store.

.PARAMETER Diagnose
    Detect issues in the Query Store and return them as issues.

.PARAMETER OperationMode
    Query Store operation mode. Values: READ_WRITE, READ_ONLY, OFF. Default: READ_WRITE.

.PARAMETER FlushIntervalSeconds
    Frequency of writing to the Query Store (seconds). Default: 900.

.PARAMETER IntervalLengthMinutes
    Length of a statistics interval (minutes). Default: 60.

.PARAMETER MaxStorageSizeMB
    Maximum size of the Query Store (MB). Default: 1000.

.PARAMETER QueryCaptureMode
    Capture mode. Values: ALL, AUTO, NONE. Default: AUTO.

.PARAMETER SizeBasedCleanupMode
    Automatic cleanup under memory pressure. Values: OFF, AUTO. Default: AUTO.

.PARAMETER MaxPlansPerQuery
    Maximum number of execution plans per query. Default: 200.

.PARAMETER TopN
    Number of top queries to return. Default: 25.

.PARAMETER OrderBy
    Sort column for top queries. Values: Duration, CPU, LogicalReads, ExecutionCount, Memory.
    Default: Duration.

.PARAMETER LookbackHours
    Lookback period in hours (from now backwards). Default: 24.

.PARAMETER MinExecutionCount
    Minimum number of executions required to be included in top queries. Default: 5.

.PARAMETER StorageWarningPct
    Fill level (%) at which a storage warning is issued. Default: 80.

.PARAMETER MaxPlansWarning
    Number of plans per query at which a plan instability warning is issued. Default: 5.

.PARAMETER OutputPath
    Directory for reports (CSV + TXT + HTML). Default: from module configuration + \QueryStore.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Report for all databases (Query + Diagnose)
    Invoke-sqmQueryStore -All

.EXAMPLE
    # Configure Query Store and query immediately
    Invoke-sqmQueryStore -Database "SalesDB","CRM" -Configure -Query -Diagnose

.EXAMPLE
    # Top 50 queries by CPU consumption, last 48 hours
    Invoke-sqmQueryStore -Database "SalesDB" -Query -TopN 50 -OrderBy CPU -LookbackHours 48

.EXAMPLE
    # Diagnostics with storage warning from 70% and save report
    Invoke-sqmQueryStore -All -Diagnose -StorageWarningPct 70 -OutputPath "D:\Reports\QS"

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmConfig, Get-sqmDefaultOutputPath
    Needs VIEW DATABASE STATE on the target databases.
    Query Store is available from SQL Server 2016 (compatibility level >= 130).
#>
function Invoke-sqmQueryStore
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database,
		[Parameter(Mandatory = $false)]
		[switch]$All,

		# --- Betriebsarten ---
		[Parameter(Mandatory = $false)]
		[switch]$Configure,
		[Parameter(Mandatory = $false)]
		[switch]$Query,
		[Parameter(Mandatory = $false)]
		[switch]$Diagnose,

		# --- Konfigurationsparameter ---
		[Parameter(Mandatory = $false)]
		[ValidateSet('READ_WRITE', 'READ_ONLY', 'OFF')]
		[string]$OperationMode = 'READ_WRITE',
		[Parameter(Mandatory = $false)]
		[ValidateRange(60, 86400)]
		[int]$FlushIntervalSeconds = 900,
		[Parameter(Mandatory = $false)]
		[ValidateSet(1, 5, 10, 15, 30, 60, 120)]
		[int]$IntervalLengthMinutes = 60,
		[Parameter(Mandatory = $false)]
		[ValidateRange(10, 10240)]
		[int]$MaxStorageSizeMB = 1000,
		[Parameter(Mandatory = $false)]
		[ValidateSet('ALL', 'AUTO', 'NONE')]
		[string]$QueryCaptureMode = 'AUTO',
		[Parameter(Mandatory = $false)]
		[ValidateSet('OFF', 'AUTO')]
		[string]$SizeBasedCleanupMode = 'AUTO',
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 10000)]
		[int]$MaxPlansPerQuery = 200,

		# --- Abfrageparameter ---
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 1000)]
		[int]$TopN = 25,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Duration', 'CPU', 'LogicalReads', 'ExecutionCount', 'Memory')]
		[string]$OrderBy = 'Duration',
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 8760)]
		[int]$LookbackHours = 24,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1000000)]
		[int]$MinExecutionCount = 5,

		# --- Diagnoseschwellwerte ---
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$StorageWarningPct = 80,
		[Parameter(Mandatory = $false)]
		[ValidateRange(2, 1000)]
		[int]$MaxPlansWarning = 5,

		# --- Ausgabe ---
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Wenn kein Aktions-Switch gesetzt: Report-Modus (Query + Diagnose)
		$runQuery    = $Query    -or (-not $Configure -and -not $Query -and -not $Diagnose)
		$runDiagnose = $Diagnose -or (-not $Configure -and -not $Query -and -not $Diagnose)
		$runConfigure = $Configure.IsPresent

		# OutputPath aufloesen
		if (-not $OutputPath) { $OutputPath = Join-Path (Get-sqmDefaultOutputPath) 'QueryStore' }

		# Sortierklausel
		$orderByClause = switch ($OrderBy)
		{
			'Duration'       { 'avg_duration_ms DESC' }
			'CPU'            { 'avg_cpu_ms DESC' }
			'LogicalReads'   { 'avg_logical_reads DESC' }
			'ExecutionCount' { 'total_executions DESC' }
			'Memory'         { 'avg_memory_mb DESC' }
			default          { 'avg_duration_ms DESC' }
		}

		$systemDatabases = @('master', 'tempdb', 'model', 'msdb', 'distribution')
		$allDbResults    = [System.Collections.Generic.List[PSCustomObject]]::new()

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Configure=$runConfigure Query=$runQuery Diagnose=$runDiagnose)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# -----------------------------------------------------------------------
			# Datenbankliste ermitteln
			# -----------------------------------------------------------------------
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$allDatabases = Get-DbaDatabase @connParams -ExcludeSystem -ErrorAction Stop |
				Where-Object { $_.IsAccessible -and $_.Status -eq 'Normal' }

			$targetDatabases = if ($All -or (-not $Database -or $Database.Count -eq 0))
			{
				$allDatabases
			}
			else
			{
				$allDatabases | Where-Object { $_.Name -in $Database }
			}

			if (-not $targetDatabases)
			{
				Invoke-sqmLogging -Message "Keine zugaenglichen Benutzerdatenbanken gefunden." -FunctionName $functionName -Level "WARNING"
				return
			}

			Invoke-sqmLogging -Message "$(@($targetDatabases).Count) Datenbank(en) werden verarbeitet." -FunctionName $functionName -Level "INFO"

			foreach ($db in $targetDatabases)
			{
				$dbName = $db.Name
				Invoke-sqmLogging -Message "Verarbeite Datenbank '$dbName'..." -FunctionName $functionName -Level "INFO"

				$dbResult = [PSCustomObject]@{
					SqlInstance     = $SqlInstance
					DatabaseName    = $dbName
					QSOptions       = $null
					ConfigureStatus = $null
					TopQueries      = @()
					Issues          = @()
					IssueCount      = 0
					ReportFile      = $null
					HtmlFile        = $null
				}

				$dbConnParams = @{
					SqlInstance   = $SqlInstance
					Database      = $dbName
				}
				if ($SqlCredential) { $dbConnParams['SqlCredential'] = $SqlCredential }

				# -------------------------------------------------------------------
				# QS-Status immer lesen (benoetigt fuer Diagnose und als Info)
				# -------------------------------------------------------------------
				try
				{
					$qsStatusSql = @"
SELECT
    actual_state_desc                                               AS ActualState,
    readonly_reason                                                 AS ReadOnlyReason,
    current_storage_size_mb                                         AS CurrentStorageMB,
    max_storage_size_mb                                             AS MaxStorageMB,
    CAST(current_storage_size_mb * 100.0
         / NULLIF(max_storage_size_mb, 0) AS DECIMAL(5,1))         AS StoragePct,
    flush_interval_seconds                                          AS FlushIntervalSeconds,
    interval_length_minutes                                         AS IntervalLengthMinutes,
    max_plans_per_query                                             AS MaxPlansPerQuery,
    query_capture_mode_desc                                         AS QueryCaptureMode,
    size_based_cleanup_mode_desc                                    AS SizeBasedCleanupMode
FROM sys.database_query_store_options
"@
					$qsOptions = Invoke-DbaQuery @dbConnParams -Query $qsStatusSql -ErrorAction Stop
					$dbResult.QSOptions = $qsOptions
				}
				catch
				{
					Invoke-sqmLogging -Message "[$dbName] QS-Status konnte nicht gelesen werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}

				# -------------------------------------------------------------------
				# CONFIGURE
				# -------------------------------------------------------------------
				if ($runConfigure -and $PSCmdlet.ShouldProcess($dbName, "Query Store konfigurieren ($OperationMode)"))
				{
					try
					{
						Invoke-sqmLogging -Message "[$dbName] Konfiguriere Query Store ($OperationMode)..." -FunctionName $functionName -Level "INFO"

						$configureSql = @"
ALTER DATABASE [$dbName] SET QUERY_STORE = ON (
    OPERATION_MODE             = $OperationMode,
    DATA_FLUSH_INTERVAL_SECONDS = $FlushIntervalSeconds,
    INTERVAL_LENGTH_MINUTES    = $IntervalLengthMinutes,
    MAX_STORAGE_SIZE_MB        = $MaxStorageSizeMB,
    QUERY_CAPTURE_MODE         = $QueryCaptureMode,
    SIZE_BASED_CLEANUP_MODE    = $SizeBasedCleanupMode,
    MAX_PLANS_PER_QUERY        = $MaxPlansPerQuery
);
"@
						# Muss gegen master ausgefuehrt werden (ALTER DATABASE)
						$masterParams = @{ SqlInstance = $SqlInstance; Database = 'master' }
						if ($SqlCredential) { $masterParams['SqlCredential'] = $SqlCredential }
						Invoke-DbaQuery @masterParams -Query $configureSql -ErrorAction Stop

						# Aktualisierten Status lesen
						$qsOptionsNew = Invoke-DbaQuery @dbConnParams -Query $qsStatusSql -ErrorAction SilentlyContinue
						if ($qsOptionsNew) { $dbResult.QSOptions = $qsOptionsNew }

						$dbResult.ConfigureStatus = 'Success'
						Invoke-sqmLogging -Message "[$dbName] Query Store konfiguriert: $OperationMode, ${MaxStorageSizeMB}MB, Capture=$QueryCaptureMode" -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						$errMsg = "[$dbName] Konfiguration fehlgeschlagen: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						$dbResult.ConfigureStatus = "Failed: $($_.Exception.Message)"
						if ($EnableException) { throw }
					}
				}

				# Query Store muss aktiv sein fuer Query und Diagnose
				$qsActive = $dbResult.QSOptions -and $dbResult.QSOptions.ActualState -in @('READ_WRITE', 'READ_ONLY')
				if (-not $qsActive -and ($runQuery -or $runDiagnose))
				{
					Invoke-sqmLogging -Message "[$dbName] Query Store ist nicht aktiv (Status: $($dbResult.QSOptions.ActualState)). Verwende -Configure zum Aktivieren." -FunctionName $functionName -Level "WARNING"
					$dbResult.Issues += [PSCustomObject]@{
						Severity    = 'Critical'
						Category    = 'QSDisabled'
						Description = "Query Store ist deaktiviert (Status: $($dbResult.QSOptions.ActualState)). Verwende: Invoke-sqmQueryStore -Configure"
						Detail      = $null
					}
					$dbResult.IssueCount = $dbResult.Issues.Count
					$allDbResults.Add($dbResult)
					continue
				}

				# -------------------------------------------------------------------
				# QUERY  - Top-N-Queries
				# -------------------------------------------------------------------
				if ($runQuery)
				{
					try
					{
						Invoke-sqmLogging -Message "[$dbName] Lese Top $TopN Queries (OrderBy: $OrderBy, Lookback: ${LookbackHours}h)..." -FunctionName $functionName -Level "INFO"

						$topQuerySql = @"
SELECT TOP ($TopN)
    q.query_id                                                              AS QueryId,
    SUBSTRING(qt.query_sql_text, 1, 2000)                                  AS QueryText,
    COUNT(DISTINCT p.plan_id)                                               AS PlanCount,
    SUM(rs.count_executions)                                                AS TotalExecutions,
    CAST(AVG(rs.avg_duration)       / 1000.0  AS DECIMAL(18,2))            AS avg_duration_ms,
    CAST(MAX(rs.max_duration)       / 1000.0  AS DECIMAL(18,2))            AS max_duration_ms,
    CAST(MIN(rs.min_duration)       / 1000.0  AS DECIMAL(18,2))            AS min_duration_ms,
    CAST(AVG(rs.avg_cpu_time)       / 1000.0  AS DECIMAL(18,2))            AS avg_cpu_ms,
    CAST(AVG(rs.avg_logical_io_reads)          AS DECIMAL(18,2))            AS avg_logical_reads,
    CAST(AVG(rs.avg_physical_io_reads)         AS DECIMAL(18,2))            AS avg_physical_reads,
    CAST(AVG(rs.avg_query_max_used_memory) * 8.0 / 1024.0 AS DECIMAL(18,2)) AS avg_memory_mb,
    CAST(AVG(rs.avg_rowcount)                  AS DECIMAL(18,2))            AS avg_rowcount,
    MAX(rs.last_execution_time)                                             AS last_execution_utc,
    MAX(CAST(p.is_forced_plan AS INT))                                      AS has_forced_plan
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs
    ON p.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -$LookbackHours, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY q.query_id, qt.query_sql_text
HAVING SUM(rs.count_executions) >= $MinExecutionCount
ORDER BY $orderByClause
"@
						$topQueries = Invoke-DbaQuery @dbConnParams -Query $topQuerySql -ErrorAction Stop
						$dbResult.TopQueries = @($topQueries)
						Invoke-sqmLogging -Message "[$dbName] $(@($topQueries).Count) Queries gelesen." -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						Invoke-sqmLogging -Message "[$dbName] Fehler beim Lesen der Top-Queries: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
					}
				}

				# -------------------------------------------------------------------
				# DIAGNOSE  - Probleme erkennen
				# -------------------------------------------------------------------
				if ($runDiagnose)
				{
					$issues = [System.Collections.Generic.List[PSCustomObject]]::new()

					# D1: Query Store im READ_ONLY-Modus (Speicherdruck)
					if ($dbResult.QSOptions.ActualState -eq 'READ_ONLY')
					{
						$reason = switch ($dbResult.QSOptions.ReadOnlyReason)
						{
							1  { 'Speicherlimit erreicht (SIZE_BASED_CLEANUP)' }
							2  { 'Datenbankkompatibilitaet < 130' }
							4  { 'Datenbankwiederherstellung' }
							8  { 'ALTER DATABASE in Bearbeitung' }
							65 { 'Speicherlimit UND Kompatibilitaet' }
							default { "Code $($dbResult.QSOptions.ReadOnlyReason)" }
						}
						$issues.Add([PSCustomObject]@{
							Severity    = 'Critical'
							Category    = 'ReadOnly'
							Description = "Query Store ist READ_ONLY: $reason"
							Detail      = "Speicher: $($dbResult.QSOptions.CurrentStorageMB) MB / $($dbResult.QSOptions.MaxStorageMB) MB. Erhoehe MaxStorageSizeMB oder fuehre EXEC sys.sp_query_store_flush_db aus."
						})
					}

					# D2: Speicherfuellung kritisch
					if ($dbResult.QSOptions.StoragePct -ge $StorageWarningPct)
					{
						$severity = if ($dbResult.QSOptions.StoragePct -ge 95) { 'Critical' } else { 'Warning' }
						$issues.Add([PSCustomObject]@{
							Severity    = $severity
							Category    = 'StoragePressure'
							Description = "Query Store Speicher $($dbResult.QSOptions.StoragePct)% belegt ($($dbResult.QSOptions.CurrentStorageMB)/$($dbResult.QSOptions.MaxStorageMB) MB)"
							Detail      = "Empfehlung: MaxStorageSizeMB erhoehen oder EXEC sys.sp_query_store_remove_query fuer alte Daten."
						})
					}

					# D3: Plan-Instabilitaet  - Queries mit vielen Plaenen
					try
					{
						$planInstabilitySql = @"
SELECT TOP 20
    q.query_id                                                      AS QueryId,
    SUBSTRING(qt.query_sql_text, 1, 500)                           AS QueryText,
    COUNT(DISTINCT p.plan_id)                                       AS PlanCount,
    CAST(MIN(agg.avg_dur) / 1000.0 AS DECIMAL(18,2))               AS best_avg_ms,
    CAST(MAX(agg.avg_dur) / 1000.0 AS DECIMAL(18,2))               AS worst_avg_ms,
    CASE WHEN MIN(agg.avg_dur) > 0
         THEN CAST((MAX(agg.avg_dur) - MIN(agg.avg_dur)) * 100.0
                  / MIN(agg.avg_dur) AS DECIMAL(8,1))
         ELSE 0
    END                                                             AS regression_pct
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
JOIN (
    SELECT rs.plan_id, AVG(rs.avg_duration) AS avg_dur
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(HOUR, -$LookbackHours, GETUTCDATE())
    GROUP BY rs.plan_id
) agg ON p.plan_id = agg.plan_id
GROUP BY q.query_id, qt.query_sql_text
HAVING COUNT(DISTINCT p.plan_id) >= $MaxPlansWarning
ORDER BY regression_pct DESC
"@
						$unstableQueries = Invoke-DbaQuery @dbConnParams -Query $planInstabilitySql -ErrorAction Stop
						foreach ($uq in $unstableQueries)
						{
							$issues.Add([PSCustomObject]@{
								Severity    = if ($uq.regression_pct -gt 200) { 'Critical' } else { 'Warning' }
								Category    = 'PlanInstability'
								Description = "QueryId $($uq.QueryId): $($uq.PlanCount) Plaene, Regression +$($uq.regression_pct)% (best: $($uq.best_avg_ms) ms, worst: $($uq.worst_avg_ms) ms)"
								Detail      = ($uq.QueryText -replace '\s+', ' ').Trim()
							})
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$dbName] Plan-Instabilitaets-Diagnose fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}

					# D4: Forced Plans mit Fehlschlaegen
					try
					{
						$forcedPlanSql = @"
SELECT
    q.query_id                                                      AS QueryId,
    SUBSTRING(qt.query_sql_text, 1, 500)                           AS QueryText,
    p.plan_id                                                       AS PlanId,
    p.force_failure_count                                           AS ForceFailureCount,
    p.last_force_failure_reason_desc                                AS LastFailureReason
FROM sys.query_store_plan p
JOIN sys.query_store_query q
    ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
WHERE p.is_forced_plan = 1
  AND p.force_failure_count > 0
ORDER BY p.force_failure_count DESC
"@
						$failedForcedPlans = Invoke-DbaQuery @dbConnParams -Query $forcedPlanSql -ErrorAction Stop
						foreach ($ffp in $failedForcedPlans)
						{
							$issues.Add([PSCustomObject]@{
								Severity    = 'Critical'
								Category    = 'ForcedPlanFailure'
								Description = "QueryId $($ffp.QueryId), PlanId $($ffp.PlanId): Forced Plan $($ffp.ForceFailureCount)x fehlgeschlagen ($($ffp.LastFailureReason))"
								Detail      = ($ffp.QueryText -replace '\s+', ' ').Trim()
							})
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$dbName] Forced-Plan-Diagnose fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}

					# D5: Hohe Ausfuehrungsvarianz (instabile Laufzeiten)
					try
					{
						$varianceSql = @"
SELECT TOP 15
    q.query_id                                                      AS QueryId,
    SUBSTRING(qt.query_sql_text, 1, 500)                           AS QueryText,
    SUM(rs.count_executions)                                        AS TotalExecutions,
    CAST(AVG(rs.avg_duration)  / 1000.0 AS DECIMAL(18,2))          AS avg_duration_ms,
    CAST(MAX(rs.max_duration)  / 1000.0 AS DECIMAL(18,2))          AS max_duration_ms,
    CAST(MIN(rs.min_duration)  / 1000.0 AS DECIMAL(18,2))          AS min_duration_ms,
    CASE WHEN AVG(rs.avg_duration) > 0
         THEN CAST((MAX(rs.max_duration) - MIN(rs.min_duration)) * 100.0
                  / AVG(rs.avg_duration) AS DECIMAL(8,1))
         ELSE 0
    END                                                             AS variation_pct
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs
    ON p.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -$LookbackHours, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY q.query_id, qt.query_sql_text
HAVING SUM(rs.count_executions) >= $MinExecutionCount
   AND CASE WHEN AVG(rs.avg_duration) > 0
            THEN (MAX(rs.max_duration) - MIN(rs.min_duration)) * 100.0 / AVG(rs.avg_duration)
            ELSE 0 END > 300
ORDER BY variation_pct DESC
"@
						$highVariance = Invoke-DbaQuery @dbConnParams -Query $varianceSql -ErrorAction Stop
						foreach ($hv in $highVariance)
						{
							$issues.Add([PSCustomObject]@{
								Severity    = 'Warning'
								Category    = 'HighVariance'
								Description = "QueryId $($hv.QueryId): Laufzeitvarianz $($hv.variation_pct)% (min $($hv.min_duration_ms) ms / avg $($hv.avg_duration_ms) ms / max $($hv.max_duration_ms) ms)"
								Detail      = ($hv.QueryText -replace '\s+', ' ').Trim()
							})
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$dbName] Varianz-Diagnose fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}

					$dbResult.Issues    = $issues.ToArray()
					$dbResult.IssueCount = $issues.Count

					$critCount = @($issues | Where-Object { $_.Severity -eq 'Critical' }).Count
					$warnCount = @($issues | Where-Object { $_.Severity -eq 'Warning' }).Count
					Invoke-sqmLogging -Message "[$dbName] Diagnose abgeschlossen: $critCount Critical, $warnCount Warning." -FunctionName $functionName -Level "INFO"
				}

				# -------------------------------------------------------------------
				# BERICHT SPEICHERN
				# -------------------------------------------------------------------
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

				$safeInst  = $SqlInstance -replace '[\\/:<>|]', '_'
				$safeDb    = $dbName -replace '[\\/:<>|]', '_'
				$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
				$baseFile  = Join-Path $OutputPath "QS_${safeInst}_${safeDb}_${timestamp}"

				# Top-Queries als CSV
				if ($dbResult.TopQueries.Count -gt 0)
				{
					$csvFile = "${baseFile}_TopQueries.csv"
					$dbResult.TopQueries | Select-Object QueryId, TotalExecutions,
						avg_duration_ms, max_duration_ms, avg_cpu_ms,
						avg_logical_reads, avg_memory_mb, has_forced_plan, PlanCount,
						last_execution_utc, QueryText |
						Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
					Invoke-sqmLogging -Message "[$dbName] Top-Queries gespeichert: $csvFile" -FunctionName $functionName -Level "INFO"
				}

				# Issues als TXT-Bericht
				if ($dbResult.Issues.Count -gt 0)
				{
					$reportLines = [System.Collections.Generic.List[string]]::new()
					$reportLines.Add("=" * 70)
					$reportLines.Add("  QUERY STORE DIAGNOSE  - $SqlInstance \ $dbName")
					$reportLines.Add("  Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
					$reportLines.Add("  Zeitraum: letzte ${LookbackHours}h")
					if ($dbResult.QSOptions)
					{
						$reportLines.Add("  QS-Status: $($dbResult.QSOptions.ActualState)  |  Speicher: $($dbResult.QSOptions.CurrentStorageMB)/$($dbResult.QSOptions.MaxStorageMB) MB ($($dbResult.QSOptions.StoragePct)%)")
					}
					$reportLines.Add("=" * 70)
					$reportLines.Add("")

					$grouped = $dbResult.Issues | Group-Object Severity | Sort-Object { if ($_.Name -eq 'Critical') { 0 } else { 1 } }
					foreach ($grp in $grouped)
					{
						$reportLines.Add("[$($grp.Name.ToUpper())]  - $($grp.Count) Eintrag/Eintraege")
						$reportLines.Add("-" * 50)
						foreach ($issue in $grp.Group)
						{
							$reportLines.Add("  Kategorie : $($issue.Category)")
							$reportLines.Add("  Problem   : $($issue.Description)")
							if ($issue.Detail) { $reportLines.Add("  Detail    : $($issue.Detail.Substring(0, [Math]::Min(200, $issue.Detail.Length)))") }
							$reportLines.Add("")
						}
					}

					$txtFile = "${baseFile}_Issues.txt"
					$reportLines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$dbResult.ReportFile = $txtFile
					Invoke-sqmLogging -Message "[$dbName] Issues-Bericht gespeichert: $txtFile" -FunctionName $functionName -Level "INFO"
				}

				# -------------------------------------------------------------------
				# HTML-BERICHT  - Status + Issues + Top-Queries in einem Dokument
				# -------------------------------------------------------------------
				if ($dbResult.TopQueries.Count -gt 0 -or $dbResult.Issues.Count -gt 0)
				{
					$enc = { param ($t) if ($null -eq $t) { '' } else { [string]$t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' } }
					$body = [System.Text.StringBuilder]::new()

					if ($dbResult.QSOptions)
					{
						[void]$body.AppendLine('<h2>Query Store Status</h2>')
						[void]$body.AppendLine(($dbResult.QSOptions |
								Select-Object ActualState, CurrentStorageMB, MaxStorageMB, StoragePct,
											  QueryCaptureMode, SizeBasedCleanupMode, MaxPlansPerQuery |
								ConvertTo-Html -Fragment -As List | Out-String))
					}

					if ($dbResult.Issues.Count -gt 0)
					{
						[void]$body.AppendLine("<h2>Erkannte Probleme ($($dbResult.IssueCount))</h2>")
						[void]$body.AppendLine('<table><tr><th>Severity</th><th>Kategorie</th><th>Problem</th><th>Detail</th></tr>')
						$sorted = $dbResult.Issues | Sort-Object { if ($_.Severity -eq 'Critical') { 0 } else { 1 } }
						foreach ($issue in $sorted)
						{
							$cls = if ($issue.Severity -eq 'Critical') { 'crit' } else { 'warn' }
							[void]$body.AppendLine(("<tr><td class='{0}'>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>" -f
									$cls, (& $enc $issue.Severity), (& $enc $issue.Category),
									(& $enc $issue.Description), (& $enc $issue.Detail)))
						}
						[void]$body.AppendLine('</table>')
					}

					if ($dbResult.TopQueries.Count -gt 0)
					{
						[void]$body.AppendLine("<h2>Top $TopN Queries (sortiert nach $OrderBy)</h2>")
						[void]$body.AppendLine(($dbResult.TopQueries |
								Select-Object QueryId, TotalExecutions, avg_duration_ms, max_duration_ms,
											  avg_cpu_ms, avg_logical_reads, avg_memory_mb, PlanCount,
											  has_forced_plan, QueryText |
								ConvertTo-Html -Fragment -As Table | Out-String))
					}

					$htmlFile = "${baseFile}.html"
					$subtitle = "Instanz: $SqlInstance  |  Datenbank: $dbName  |  Zeitraum: letzte ${LookbackHours}h"
					ConvertTo-sqmHtmlReport -Title "Query Store Report - $dbName" -Subtitle $subtitle -BodyHtml $body.ToString() |
					Out-File -FilePath $htmlFile -Encoding UTF8 -Force
					$dbResult.HtmlFile = $htmlFile
					Invoke-sqmLogging -Message "[$dbName] HTML-Report gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
					Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
				}

				$allDbResults.Add($dbResult)
			}
		}
		catch
		{
			$errMsg = "Schwerwiegender Fehler in $functionName : $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
	}

	end
	{
		$totalIssues = ($allDbResults | Measure-Object -Property IssueCount -Sum).Sum
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allDbResults.Count) DB(s), $totalIssues Issue(s) gesamt." -FunctionName $functionName -Level "INFO"
		return $allDbResults.ToArray()
	}
}
