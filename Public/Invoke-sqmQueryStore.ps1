<#
.SYNOPSIS
    Richtet den Query Store ein, liest ihn aus, erkennt Probleme und speichert Berichte.

.DESCRIPTION
    Umfassende Query-Store-Verwaltung fuer eine, mehrere oder alle Benutzerdatenbanken.

    Betriebsarten (Switches, kombinierbar):
      -Configure  Aktiviert und konfiguriert den Query Store (ALTER DATABASE SET QUERY_STORE).
      -Query      Liest die Top-N-Queries aus dem Query Store (nach Dauer, CPU, Reads etc.).
      -Diagnose   Erkennt Probleme: READ_ONLY-Status, Speicherdruck, Plan-Regression,
                  Forced-Plan-Fehler, instabile Ausfuehrungsplaene.

    Wenn keiner der drei Switches angegeben wird, werden -Query und -Diagnose ausgefuehrt
    (Report-Modus).

    Ergebnisse werden als PSCustomObject zurueckgegeben und optional als CSV/TXT gespeichert.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: aktueller Computername.

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER Database
    Eine oder mehrere Datenbanken. Wird ignoriert wenn -All gesetzt ist.

.PARAMETER All
    Alle zugaenglichen Benutzerdatenbanken verarbeiten.

.PARAMETER Configure
    Query Store konfigurieren (aktivieren/Parameter setzen).

.PARAMETER Query
    Top-N-Queries aus dem Query Store lesen.

.PARAMETER Diagnose
    Probleme im Query Store erkennen und als Issues zurueckgeben.

.PARAMETER OperationMode
    Query Store Betriebsmodus. Werte: READ_WRITE, READ_ONLY, OFF. Standard: READ_WRITE.

.PARAMETER FlushIntervalSeconds
    Haeufigkeit des Schreibens in den Query Store (Sekunden). Standard: 900.

.PARAMETER IntervalLengthMinutes
    Laenge eines Statistik-Intervalls (Minuten). Standard: 60.

.PARAMETER MaxStorageSizeMB
    Maximale Groesse des Query Store (MB). Standard: 1000.

.PARAMETER QueryCaptureMode
    Erfassungsmodus. Werte: ALL, AUTO, NONE. Standard: AUTO.

.PARAMETER SizeBasedCleanupMode
    Automatische Bereinigung bei Speicherdruck. Werte: OFF, AUTO. Standard: AUTO.

.PARAMETER MaxPlansPerQuery
    Maximale Anzahl Ausfuehrungsplaene je Query. Standard: 200.

.PARAMETER TopN
    Anzahl der zurueckzugebenden Top-Queries. Standard: 25.

.PARAMETER OrderBy
    Sortierspalte fuer Top-Queries. Werte: Duration, CPU, LogicalReads, ExecutionCount, Memory.
    Standard: Duration.

.PARAMETER LookbackHours
    Betrachtungszeitraum in Stunden (rueckwirkend ab jetzt). Standard: 24.

.PARAMETER MinExecutionCount
    Mindestanzahl Ausfuehrungen fuer Aufnahme in Top-Queries. Standard: 5.

.PARAMETER StorageWarningPct
    Ab welchem Fuellgrad (%) eine Speicher-Warnung ausgegeben wird. Standard: 80.

.PARAMETER MaxPlansWarning
    Ab wie vielen Plaenen pro Query eine Plan-Instabilitaets-Warnung ausgegeben wird. Standard: 5.

.PARAMETER OutputPath
    Verzeichnis fuer Berichte (CSV + TXT). Standard: aus Modulkonfiguration + \QueryStore.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    # Report fuer alle Datenbanken (Query + Diagnose)
    Invoke-sqmQueryStore -All

.EXAMPLE
    # Query Store konfigurieren und sofort abfragen
    Invoke-sqmQueryStore -Database "SalesDB","CRM" -Configure -Query -Diagnose

.EXAMPLE
    # Top 50 Queries nach CPU-Verbrauch, letzten 48 Stunden
    Invoke-sqmQueryStore -Database "SalesDB" -Query -TopN 50 -OrderBy CPU -LookbackHours 48

.EXAMPLE
    # Diagnose mit Speicherwarnung ab 70% und Bericht speichern
    Invoke-sqmQueryStore -All -Diagnose -StorageWarningPct 70 -OutputPath "D:\Reports\QS"

.NOTES
    Erfordert: dbatools, Invoke-sqmLogging, Get-sqmConfig, Get-sqmDefaultOutputPath
    Benoetigt VIEW DATABASE STATE auf den Zieldatenbanken.
    Query Store ist verfuegbar ab SQL Server 2016 (Kompatibilitaetslevel >= 130).
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
				$timestamp = Get-Date -Format 'yyyyMMdd_HHmsqm'
				$baseFile  = Join-Path $OutputPath "QS_${safeInst}_${safeDb}_${timestamp}"

				# Top-Queries als CSV
				if ($dbResult.TopQueries.Count -gt 0)
				{
					$csvFile = "$baseFile_TopQueries.csv"
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

					$txtFile = "$baseFile_Issues.txt"
					$reportLines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$dbResult.ReportFile = $txtFile
					Invoke-sqmLogging -Message "[$dbName] Issues-Bericht gespeichert: $txtFile" -FunctionName $functionName -Level "INFO"
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
