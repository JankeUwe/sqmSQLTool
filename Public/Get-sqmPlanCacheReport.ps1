<#
.SYNOPSIS
    Lists the most expensive queries in the plan cache (top N by CPU, duration, reads and more),
    flags typical plan problems and optionally exports the execution plans as .sqlplan files.

.DESCRIPTION
    Reads sys.dm_exec_query_stats and ranks every cached statement once per requested metric
    (-SortBy). A statement that is in the top N of several metrics is returned only once, with
    all its ranks in the Ranks column. No stored procedure is installed on the instance.

    Per statement the following is returned:
      - Database, object (procedure/function) or ad hoc, statement text
      - Executions, total and average CPU, duration, logical reads, writes
      - Memory grant and tempdb spills (if the SQL Server version provides them)
      - Share of the instance-wide total CPU / duration / reads in percent
      - Plan creation time and last execution
      - Findings from the plan XML: ImplicitConversion, MissingIndex, Spill, KeyLookup,
        NoJoinPredicate, ParallelPlan
      - Only statements with a value above 0 are ranked for a metric, so -SortBy Spills
        returns nothing on an instance without spills.
      - Optional: path of the exported .sqlplan file (-ExportPlans). Those files can be fed
        straight into Get-sqmPlanInsights -Path for a detailed analysis.

    Metrics for -SortBy:
      CPU          total_worker_time
      Duration     total_elapsed_time
      Reads        total_logical_reads
      Writes       total_logical_writes
      Executions   execution_count
      MemoryGrant  total_grant_kb   (SQL Server 2016 SP2 / 2017 and later)
      Spills       total_spills     (SQL Server 2016 SP2 / 2017 and later)
      All          all of the above

    IMPORTANT: The plan cache only knows what is still cached. A restart, failover,
    memory pressure, DBCC FREEPROCCACHE or a RECOMPILE hint removes entries, and statements
    with OPTION (RECOMPILE) never show up. For history use Invoke-sqmQueryStore -Query.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Only statements of these databases (wildcards allowed). Determining the database needs
    sys.dm_exec_plan_attributes for every cached plan, which costs noticeably more CPU on
    instances with a large plan cache. Without -Database the database is only resolved for
    the top N rows.

.PARAMETER SortBy
    Metrics to rank by. Default: CPU, Duration, Reads. 'All' uses every metric.

.PARAMETER Top
    Number of statements per metric. Default: 10.

.PARAMETER MinutesBack
    Only statements executed within the last N minutes. Default: 0 (whole cache).

.PARAMETER ExportPlans
    Saves the statement plan of every returned row as .sqlplan file to <OutputPath>\Plans.
    Open them in SSMS or analyze them with Get-sqmPlanInsights -Path.

.PARAMETER OutputPath
    Directory for the CSV/HTML report. Default: <OutputPath config>\PlanCacheReport.

.PARAMETER NoReport
    Do not write CSV/HTML (objects are still returned). -ExportPlans still writes plans.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmPlanCacheReport -SqlInstance "SQL01"

.EXAMPLE
    # All metrics, top 5 each, plans as .sqlplan files
    Get-sqmPlanCacheReport -SqlInstance "SQL01" -SortBy All -Top 5 -ExportPlans

.EXAMPLE
    # What hurt in the last hour in the shop database
    Get-sqmPlanCacheReport -SqlInstance "SQL01" -Database "Shop*" -MinutesBack 60 -SortBy CPU,Reads

.EXAMPLE
    # Analyze the worst CPU statement in detail
    $r = Get-sqmPlanCacheReport -SqlInstance "SQL01" -SortBy CPU -Top 1 -ExportPlans -NoReport
    Get-sqmPlanInsights -Path $r[0].PlanFile

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE on the instance.
    Inspired by sp_BlitzCache (Brent Ozar, First Responder Kit) and PSBlitz, but built from
    the DMVs directly, nothing is installed on the target.
#>
function Get-sqmPlanCacheReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[ValidateSet('CPU', 'Duration', 'Reads', 'Writes', 'Executions', 'MemoryGrant', 'Spills', 'All')]
		[string[]]$SortBy = @('CPU', 'Duration', 'Reads'),
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 500)]
		[int]$Top = 10,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 525600)]
		[int]$MinutesBack = 0,
		[Parameter(Mandatory = $false)]
		[switch]$ExportPlans,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'PlanCacheReport'),
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
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
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		# Metrik -> Spalte in sys.dm_exec_query_stats
		$metricColumn = [ordered]@{
			CPU         = 'total_worker_time'
			Duration    = 'total_elapsed_time'
			Reads       = 'total_logical_reads'
			Writes      = 'total_logical_writes'
			Executions  = 'execution_count'
			MemoryGrant = 'total_grant_kb'
			Spills      = 'total_spills'
		}

		Invoke-sqmLogging -Message ("Starte " + $functionName + " auf " + $SqlInstance) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database      = 'master'
			}

			# -------------------------------------------------------------------
			# 1. Welche Spalten kennt sys.dm_exec_query_stats auf dieser Version?
			#    total_grant_kb / total_spills gibt es erst ab 2016 SP2 / 2017.
			# -------------------------------------------------------------------
			$colRows = Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.all_columns WHERE object_id = OBJECT_ID('sys.dm_exec_query_stats')" -EnableException
			$availableCols = @($colRows | ForEach-Object { $_.name })
			$hasGrant = $availableCols -contains 'total_grant_kb'
			$hasSpills = $availableCols -contains 'total_spills'

			$metrics = if ($SortBy -contains 'All') { @($metricColumn.Keys) } else { @($SortBy | Select-Object -Unique) }
			$skipped = @()
			if (-not $hasGrant -and $metrics -contains 'MemoryGrant') { $skipped += 'MemoryGrant' }
			if (-not $hasSpills -and $metrics -contains 'Spills') { $skipped += 'Spills' }
			if ($skipped.Count -gt 0)
			{
				$metrics = @($metrics | Where-Object { $_ -notin $skipped })
				$msg = "Metrik(en) $($skipped -join ', ') auf dieser SQL-Server-Version nicht verfuegbar (sys.dm_exec_query_stats) - uebersprungen."
				Write-Warning $msg
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
			}
			if ($metrics.Count -eq 0)
			{
				throw "Keine auswertbare Metrik uebrig."
			}

			# -------------------------------------------------------------------
			# 2. Abfrage zusammenbauen. Rangbildung je Metrik ueber den ganzen Cache
			#    (billig, nur Zahlen), Text/Plan/DB erst fuer die Kandidaten in #c.
			# -------------------------------------------------------------------
			$grantCol = if ($hasGrant) { 'qs.total_grant_kb' } else { 'CAST(NULL AS bigint)' }
			$maxGrantCol = if ($hasGrant) { 'qs.max_grant_kb' } else { 'CAST(NULL AS bigint)' }
			$spillCol = if ($hasSpills) { 'qs.total_spills' } else { 'CAST(NULL AS bigint)' }

			$rankCols = ($metrics | ForEach-Object {
				# Nur Werte > 0 bekommen einen Rang - sonst stuenden bei Spills/Grant/Writes
				# beliebige Nullzeilen in der Liste.
				"        CASE WHEN b.$($metricColumn[$_]) > 0 THEN ROW_NUMBER() OVER (ORDER BY b.$($metricColumn[$_]) DESC) END AS rn_$_"
			}) -join ",`r`n"
			$rankFilter = ($metrics | ForEach-Object { "rn_$_ <= $Top" }) -join ' OR '

			$timeFilter = if ($MinutesBack -gt 0) { "WHERE qs.last_execution_time >= DATEADD(MINUTE, -$MinutesBack, GETDATE())" } else { '' }

			# Mit -Database muss die DB vor der Rangbildung bekannt sein (plan_attributes fuer
			# den ganzen Cache), ohne -Database nur fuer die Kandidaten.
			$dbFilterNames = @()
			if ($Database.Count -gt 0)
			{
				$allDbs = Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.databases" -EnableException
				foreach ($d in $allDbs)
				{
					foreach ($pattern in $Database) { if ($d.name -like $pattern) { $dbFilterNames += $d.name; break } }
				}
				if ($dbFilterNames.Count -eq 0)
				{
					throw "Keine Datenbank passt zu -Database '$($Database -join "', '")'."
				}
			}

			if ($dbFilterNames.Count -gt 0)
			{
				$inList = ($dbFilterNames | ForEach-Object { "N'" + ($_ -replace "'", "''") + "'" }) -join ', '
				$baseFrom = @"
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY (SELECT CONVERT(int, pa.value) AS dbid FROM sys.dm_exec_plan_attributes(qs.plan_handle) pa WHERE pa.attribute = N'dbid') pdb
    $timeFilter
"@
				$baseWhereDb = "WHERE DB_NAME(b.dbid) IN ($inList)"
				$baseDbCol = 'pdb.dbid'
			}
			else
			{
				$baseFrom = @"
    FROM sys.dm_exec_query_stats qs
    $timeFilter
"@
				$baseWhereDb = ''
				$baseDbCol = 'CAST(NULL AS int)'
			}

			$query = @"
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

IF OBJECT_ID('tempdb..#q') IS NOT NULL DROP TABLE #q;
IF OBJECT_ID('tempdb..#c') IS NOT NULL DROP TABLE #c;

SELECT
    qs.sql_handle, qs.plan_handle, qs.statement_start_offset, qs.statement_end_offset,
    qs.query_hash, qs.creation_time, qs.last_execution_time, qs.execution_count,
    qs.total_worker_time, qs.total_elapsed_time, qs.total_logical_reads, qs.total_logical_writes,
    $grantCol AS total_grant_kb, $maxGrantCol AS max_grant_kb, $spillCol AS total_spills,
    $baseDbCol AS dbid
INTO #q
$baseFrom;

SELECT b.*,
$rankCols,
        SUM(CAST(b.total_worker_time AS float))   OVER () AS sum_cpu,
        SUM(CAST(b.total_elapsed_time AS float))  OVER () AS sum_dur,
        SUM(CAST(b.total_logical_reads AS float)) OVER () AS sum_reads
INTO #c
FROM #q b
$baseWhereDb;

SELECT
    c.*,
    COALESCE(DB_NAME(c.dbid), DB_NAME(pdb.dbid), DB_NAME(st.dbid)) AS DatabaseName,
    OBJECT_SCHEMA_NAME(st.objectid, st.dbid) AS SchemaName,
    OBJECT_NAME(st.objectid, st.dbid)        AS ObjectName,
    SUBSTRING(st.text, (c.statement_start_offset / 2) + 1,
        ((CASE c.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE c.statement_end_offset END
          - c.statement_start_offset) / 2) + 1) AS StatementText,
    tqp.query_plan AS PlanText
FROM #c c
CROSS APPLY sys.dm_exec_sql_text(c.sql_handle) st
OUTER APPLY (SELECT CONVERT(int, pa.value) AS dbid FROM sys.dm_exec_plan_attributes(c.plan_handle) pa WHERE pa.attribute = N'dbid') pdb
OUTER APPLY sys.dm_exec_text_query_plan(c.plan_handle, c.statement_start_offset, c.statement_end_offset) tqp
WHERE $rankFilter;

DROP TABLE #c;
DROP TABLE #q;
"@
			$rawData = @(Invoke-DbaQuery @connParams -Query $query -QueryTimeout 600 -EnableException)

			# -------------------------------------------------------------------
			# 3. Ergebnisobjekte + Befunde aus dem Plan-XML
			# -------------------------------------------------------------------
			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			$safeInst = $SqlInstance -replace '[\\/:*?"<>|,]', '_'
			$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
			$planDir = Join-Path $OutputPath 'Plans'
			# Nach CPU sortiert; $resultAt[k] gehoert zu $rawData[k] (Index statt Objektvergleich,
			# PowerShell wrappt DataRows je nach Pipeline unterschiedlich).
			$rawData = @($rawData | Sort-Object -Property total_worker_time -Descending)
			$resultAt = @{}
			$isRanked = { param ($v) ($null -ne $v) -and ($v -isnot [DBNull]) -and ([long]$v -le $Top) }

			$i = 0
			for ($k = 0; $k -lt $rawData.Count; $k++)
			{
				$row = $rawData[$k]
				$i++
				$ranks = @($metrics | Where-Object { & $isRanked $row."rn_$_" } | ForEach-Object { "$_#$($row."rn_$_")" })

				$planText = if ($row.PlanText -is [DBNull]) { $null } else { [string]$row.PlanText }
				$findings = @()
				if ($planText)
				{
					if ($planText -match 'CONVERT_IMPLICIT') { $findings += 'ImplicitConversion' }
					if ($planText -match '<MissingIndexes>') { $findings += 'MissingIndex' }
					if ($planText -match '<SpillToTempDb') { $findings += 'Spill' }
					if ($planText -match 'Lookup="(1|true)"') { $findings += 'KeyLookup' }
					if ($planText -match '<NoJoinPredicate') { $findings += 'NoJoinPredicate' }
					if ($planText -match '<RelOp [^>]*Parallel="(1|true)"') { $findings += 'ParallelPlan' }
				}
				if ($row.total_spills -isnot [DBNull] -and [long]$row.total_spills -gt 0 -and $findings -notcontains 'Spill') { $findings += 'Spill' }

				$exec = [math]::Max([long]$row.execution_count, 1)
				$pct = {
					param ($v, $sum)
					if ($sum -is [DBNull] -or [double]$sum -le 0) { return 0 }
					[math]::Round(100.0 * [double]$v / [double]$sum, 2)
				}
				$objectName = if ($row.ObjectName -is [DBNull] -or -not $row.ObjectName) { '(ad hoc)' } else { "$($row.SchemaName).$($row.ObjectName)" }

				$planFile = $null
				if ($ExportPlans -and $planText)
				{
					if (-not (Test-Path $planDir)) { New-Item -ItemType Directory -Path $planDir -Force | Out-Null }
					$planFile = Join-Path $planDir ("PlanCache_" + $safeInst + "_" + $stamp + "_" + $i.ToString('000') + ".sqlplan")
					[System.IO.File]::WriteAllText($planFile, $planText, (New-Object System.Text.UTF8Encoding($false)))
				}

				$obj = [PSCustomObject]@{
					SqlInstance        = $SqlInstance
					Ranks              = ($ranks -join ', ')
					DatabaseName       = if ($row.DatabaseName -is [DBNull]) { $null } else { $row.DatabaseName }
					ObjectName         = $objectName
					StatementText      = if ($row.StatementText -is [DBNull]) { $null } else { ([string]$row.StatementText).Trim() }
					Executions         = [long]$row.execution_count
					TotalCpuMs         = [math]::Round([double]$row.total_worker_time / 1000, 0)
					AvgCpuMs           = [math]::Round([double]$row.total_worker_time / 1000 / $exec, 2)
					CpuPercent         = & $pct $row.total_worker_time $row.sum_cpu
					TotalDurationMs    = [math]::Round([double]$row.total_elapsed_time / 1000, 0)
					AvgDurationMs      = [math]::Round([double]$row.total_elapsed_time / 1000 / $exec, 2)
					DurationPercent    = & $pct $row.total_elapsed_time $row.sum_dur
					TotalReads         = [long]$row.total_logical_reads
					AvgReads           = [math]::Round([double]$row.total_logical_reads / $exec, 0)
					ReadsPercent       = & $pct $row.total_logical_reads $row.sum_reads
					TotalWrites        = [long]$row.total_logical_writes
					TotalGrantKB       = if ($row.total_grant_kb -is [DBNull]) { $null } else { [long]$row.total_grant_kb }
					MaxGrantKB         = if ($row.max_grant_kb -is [DBNull]) { $null } else { [long]$row.max_grant_kb }
					TotalSpills        = if ($row.total_spills -is [DBNull]) { $null } else { [long]$row.total_spills }
					Findings           = ($findings -join ', ')
					PlanCreated        = $row.creation_time
					LastExecution      = $row.last_execution_time
					QueryHash          = if ($row.query_hash -is [byte[]]) { '0x' + (($row.query_hash | ForEach-Object { $_.ToString('X2') }) -join '') } else { $null }
					PlanFile           = $planFile
				}
				$results.Add($obj)
				$resultAt[$k] = $obj
			}

			if ($ExportPlans)
			{
				$planCount = @($results | Where-Object { $_.PlanFile }).Count
				Invoke-sqmLogging -Message "$planCount Plan-Datei(en) gespeichert in $planDir" -FunctionName $functionName -Level "INFO"
			}

			# -------------------------------------------------------------------
			# 4. CSV + HTML (ein Abschnitt je Metrik)
			# -------------------------------------------------------------------
			if (-not $NoReport -and $results.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

				$csvFile = Join-Path $OutputPath ("PlanCacheReport_" + $safeInst + "_" + $stamp + ".csv")
				$results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

				$enc = { param ($s) ([string]$s) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
				$sb = New-Object System.Text.StringBuilder
				$scope = if ($MinutesBack -gt 0) { "letzte $MinutesBack Minuten" } else { 'gesamter Plan-Cache' }
				if ($dbFilterNames.Count -gt 0) { $scope += ", Datenbank(en): $($dbFilterNames -join ', ')" }
				[void]$sb.Append("<p>Top $Top je Metrik, $scope. Prozentwerte beziehen sich auf die Summe aller betrachteten Cache-Eintraege.</p>")

				foreach ($m in $metrics)
				{
					$idxForMetric = @(0..($rawData.Count - 1) | Where-Object { & $isRanked $rawData[$_]."rn_$m" } | Sort-Object { [long]$rawData[$_]."rn_$m" })
					[void]$sb.Append("<h2>Top $Top nach $m</h2><table><tr><th class='num'>#</th><th>Datenbank</th><th>Objekt</th><th class='num'>Ausf.</th><th class='num'>CPU ms</th><th class='num'>CPU %</th><th class='num'>Dauer ms avg</th><th class='num'>Reads avg</th><th class='num'>Grant KB max</th><th class='num'>Spills</th><th>Befunde</th><th>Statement</th></tr>")
					foreach ($k in $idxForMetric)
					{
						$r = $rawData[$k]
						$o = $resultAt[$k]
						$stmt = $o.StatementText
						if ($stmt -and $stmt.Length -gt 400) { $stmt = $stmt.Substring(0, 400) + ' ...' }
						$findCls = if ($o.Findings) { " class='warn'" } else { '' }
						[void]$sb.Append("<tr><td class='num'>$($r."rn_$m")</td><td>$(& $enc $o.DatabaseName)</td><td>$(& $enc $o.ObjectName)</td><td class='num'>$($o.Executions)</td><td class='num'>$($o.TotalCpuMs)</td><td class='num'>$($o.CpuPercent)</td><td class='num'>$($o.AvgDurationMs)</td><td class='num'>$($o.AvgReads)</td><td class='num'>$($o.MaxGrantKB)</td><td class='num'>$($o.TotalSpills)</td><td$findCls>$(& $enc $o.Findings)</td><td><code>$(& $enc $stmt)</code></td></tr>")
					}
					[void]$sb.Append('</table>')
				}

				$htmlFile = Join-Path $OutputPath ("PlanCacheReport_" + $safeInst + "_" + $stamp + ".html")
				$html = ConvertTo-sqmHtmlReport -Title "Plan Cache - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $sb.ToString()
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

				Copy-sqmToCentralPath -Path @($csvFile, $htmlFile)
				Invoke-sqmLogging -Message ("Report gespeichert: " + $htmlFile) -FunctionName $functionName -Level "INFO"
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}

			Invoke-sqmLogging -Message "$($results.Count) Statement(s) aus dem Plan-Cache ausgewertet (Metriken: $($metrics -join ', '), Top $Top)." -FunctionName $functionName -Level "INFO"
			return $results
		}
		catch
		{
			$errMsg = "Fehler beim Auswerten des Plan-Caches: " + $_.Exception.Message
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}

	end
	{
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen.") -FunctionName $functionName -Level "INFO"
	}
}
