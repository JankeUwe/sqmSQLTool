<#
.SYNOPSIS
    Collects SQL Server CPU and memory utilization trends over time.

.DESCRIPTION
    Captures multiple snapshots of SQL Server memory and CPU metrics from DMVs,
    calculates Min/Max/Avg trends, and generates reports (TXT, CSV, HTML).

.PARAMETER SqlInstance
    SQL Server instance. Default: local computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER SampleCount
    Number of snapshots to collect. Default: 6.

.PARAMETER SampleIntervalSeconds
    Interval between snapshots in seconds. Default: 10.
    (Total sampling time = SampleCount * SampleIntervalSeconds)

.PARAMETER OutputPath
    Directory for report output. Default: from module config.

.PARAMETER NoOpen
    Suppress automatic report opening.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmServerUtilization -SqlInstance "SQL01"
    # Collects 6 snapshots (60 seconds) and generates HTML report

.EXAMPLE
    Get-sqmServerUtilization -SqlInstance "SQL01" -SampleCount 12 -SampleIntervalSeconds 5
    # Collects 12 snapshots (60 seconds total)

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath
    Needs VIEW SERVER STATE and CONTROL SERVER permissions.
    Report includes: Memory, CPU, Worker Threads, Compilations.
#>
function Get-sqmServerUtilization
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$SampleCount = 6,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 60)]
		[int]$SampleIntervalSeconds = 10,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
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
			$errMsg = "dbatools module is not available. Install it first."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		if (-not $OutputPath)
		{
			$OutputPath = Get-sqmDefaultOutputPath
		}

		Invoke-sqmLogging -Message "Starting $functionName for $SqlInstance (Samples: $SampleCount, Interval: $SampleIntervalSeconds sec)" `
			-FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			# ===================================================================
			# SAMPLING LOOP
			# ===================================================================
			$samples = @()
			$startTime = Get-Date

			for ($i = 0; $i -lt $SampleCount; $i++)
			{
				$sampleTime = Get-Date

				# Query 1: Memory snapshot (single result set via CROSS JOIN)
				$memSql = @"
SELECT
    pm.SQLPhysicalMemoryBytes,
    sm.ServerTotalMemoryBytes,
    sm.AvailableMemoryBytes
FROM
    (SELECT CAST(physical_memory_in_use_kb AS BIGINT) * 1024 AS SQLPhysicalMemoryBytes
     FROM sys.dm_os_process_memory) AS pm
CROSS JOIN
    (SELECT CAST(total_physical_memory_kb AS BIGINT) * 1024 AS ServerTotalMemoryBytes,
            CAST(available_physical_memory_kb AS BIGINT) * 1024 AS AvailableMemoryBytes
     FROM sys.dm_os_sys_memory) AS sm;
"@

				$memResult = Invoke-DbaQuery @connParams -Database master -Query $memSql -ErrorAction Stop

				# Extract values (single row)
				$sqlMemoryBytes = [int64]($memResult.SQLPhysicalMemoryBytes)
				$serverTotalMemory = [int64]($memResult.ServerTotalMemoryBytes)
				$availableMemory = [int64]($memResult.AvailableMemoryBytes)

				# Query 2: Worker threads (T-SQL: CASE, not PostgreSQL FILTER)
				$threadSql = @"
SELECT
    ISNULL(SUM(CASE WHEN state = 'RUNNABLE' THEN 1 ELSE 0 END), 0) AS RunnableThreads,
    ISNULL(SUM(CASE WHEN state IN ('SUSPENDED', 'RUNNING') THEN 1 ELSE 0 END), 0) AS ActiveThreads
FROM sys.dm_os_workers;
"@

				$threadResult = Invoke-DbaQuery @connParams -Database master -Query $threadSql -ErrorAction Stop
				$threadRow = @($threadResult)[0]
				$runnableThreads = [int]($threadRow.RunnableThreads)
				$activeThreads = [int]($threadRow.ActiveThreads)

				# Query 3: CPU utilization from ring buffer (record column is XML, not JSON)
				$cpuSql = @"
SELECT TOP 1
    x.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS CPUUtilizationPercent
FROM
    (SELECT CONVERT(XML, record) AS record, [timestamp]
     FROM sys.dm_os_ring_buffers
     WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR') AS x
ORDER BY x.[timestamp] DESC;
"@

				$cpuResult = Invoke-DbaQuery @connParams -Database master -Query $cpuSql -ErrorAction Stop
				$cpuRaw = @($cpuResult)[0].CPUUtilizationPercent
				$cpuUtilPercent = if ($null -eq $cpuRaw -or $cpuRaw -is [System.DBNull]) { 0.0 } else { [double]$cpuRaw }

				# Query 4: Compilations
				$compSql = @"
SELECT
    COUNT(*) AS CachedPlans,
    ISNULL(SUM(CAST(plan_generation_num AS BIGINT)), 0) AS TotalCompilations,
    ISNULL(SUM(CAST(execution_count AS BIGINT)), 0) AS TotalExecutions
FROM sys.dm_exec_query_stats;
"@

				$compResult = Invoke-DbaQuery @connParams -Database master -Query $compSql -ErrorAction Stop
				$compRow = @($compResult)[0]
				$cachedPlans = [int64]($compRow.CachedPlans)
				$totalCompilations = [int64]($compRow.TotalCompilations)

				# Build sample object
				$sample = [PSCustomObject]@{
					Timestamp             = $sampleTime
					CPUUtilizationPercent = $cpuUtilPercent
					SQLMemoryMB           = [math]::Round($sqlMemoryBytes / 1MB, 2)
					AvailableMemoryMB     = [math]::Round($availableMemory / 1MB, 2)
					ServerTotalMemoryMB   = [math]::Round($serverTotalMemory / 1MB, 2)
					RunnableThreads       = $runnableThreads
					ActiveThreads         = $activeThreads
					CachedPlans           = $cachedPlans
					TotalCompilations     = $totalCompilations
				}

				$samples += $sample

				# Wait before next sample (except on last iteration)
				if ($i -lt ($SampleCount - 1))
				{
					Start-Sleep -Seconds $SampleIntervalSeconds
				}
			}

			$endTime = Get-Date

			# ===================================================================
			# AGGREGATION (Min, Max, Avg)
			# ===================================================================
			$aggregated = [PSCustomObject]@{
				StartTime                 = $startTime
				EndTime                   = $endTime
				SampleCount               = $SampleCount
				CPUUtilization_Current    = $samples[-1].CPUUtilizationPercent
				CPUUtilization_Min        = ($samples.CPUUtilizationPercent | Measure-Object -Minimum).Minimum
				CPUUtilization_Max        = ($samples.CPUUtilizationPercent | Measure-Object -Maximum).Maximum
				CPUUtilization_Avg        = [math]::Round(($samples.CPUUtilizationPercent | Measure-Object -Average).Average, 2)
				SQLMemory_Current         = $samples[-1].SQLMemoryMB
				SQLMemory_Min             = ($samples.SQLMemoryMB | Measure-Object -Minimum).Minimum
				SQLMemory_Max             = ($samples.SQLMemoryMB | Measure-Object -Maximum).Maximum
				SQLMemory_Avg             = [math]::Round(($samples.SQLMemoryMB | Measure-Object -Average).Average, 2)
				AvailableMemory_Current   = $samples[-1].AvailableMemoryMB
				AvailableMemory_Min       = ($samples.AvailableMemoryMB | Measure-Object -Minimum).Minimum
				AvailableMemory_Max       = ($samples.AvailableMemoryMB | Measure-Object -Maximum).Maximum
				AvailableMemory_Avg       = [math]::Round(($samples.AvailableMemoryMB | Measure-Object -Average).Average, 2)
				RunnableThreads_Current   = $samples[-1].RunnableThreads
				RunnableThreads_Min       = ($samples.RunnableThreads | Measure-Object -Minimum).Minimum
				RunnableThreads_Max       = ($samples.RunnableThreads | Measure-Object -Maximum).Maximum
				RunnableThreads_Avg       = [math]::Round(($samples.RunnableThreads | Measure-Object -Average).Average, 2)
				ActiveThreads_Current     = $samples[-1].ActiveThreads
				ActiveThreads_Min         = ($samples.ActiveThreads | Measure-Object -Minimum).Minimum
				ActiveThreads_Max         = ($samples.ActiveThreads | Measure-Object -Maximum).Maximum
				ActiveThreads_Avg         = [math]::Round(($samples.ActiveThreads | Measure-Object -Average).Average, 2)
				CachedPlans               = $samples[-1].CachedPlans
				TotalCompilations         = $samples[-1].TotalCompilations
			}

			# ===================================================================
			# GENERATE REPORTS
			# ===================================================================
			$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
			$reportBaseName = "ServerUtilization_${SqlInstance}_$timestamp"

			# TXT Report
			$txtReport = Generate-UtilizationTxtReport -Agg $aggregated -SqlInstance $SqlInstance -Samples $samples
			$txtPath = Join-Path $OutputPath "$reportBaseName.txt"
			$txtReport | Out-File -FilePath $txtPath -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "TXT report saved: $txtPath" -FunctionName $functionName -Level "INFO"

			# CSV Report (raw sample data)
			$samples | Export-Csv -Path (Join-Path $OutputPath "$reportBaseName.csv") -NoTypeInformation -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "CSV report saved: $(Join-Path $OutputPath "$reportBaseName.csv")" -FunctionName $functionName -Level "INFO"

			# HTML Report
			$htmlContent = Generate-UtilizationHtmlReport -Agg $aggregated -SqlInstance $SqlInstance -Samples $samples
			$htmlPath = Join-Path $OutputPath "$reportBaseName.html"
			$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "HTML report saved: $htmlPath" -FunctionName $functionName -Level "INFO"

			# Open report
			if (-not $NoOpen)
			{
				Invoke-sqmOpenReport -HtmlFile $htmlPath -NoOpen:$NoOpen
			}

			Write-Verbose "Utilization data collection complete. Reports saved to: $OutputPath"
			return $aggregated
		}
		catch
		{
			$errMsg = "Error during utilization collection: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw } else { Write-Error $errMsg }
		}
	}

	end
	{
		Invoke-sqmLogging -Message "Completed $functionName" -FunctionName $functionName -Level "INFO"
	}
}

# ===================================================================
# HELPER FUNCTIONS (Private)
# ===================================================================

function Generate-UtilizationTxtReport
{
	param(
		[PSCustomObject]$Agg,
		[string]$SqlInstance,
		[array]$Samples
	)

	$sb = New-Object System.Text.StringBuilder

	$sb.AppendLine("═══════════════════════════════════════════════════════════════") | Out-Null
	$sb.AppendLine("  SQL Server Utilization Report — $SqlInstance — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
	$sb.AppendLine("═══════════════════════════════════════════════════════════════") | Out-Null
	$sb.AppendLine() | Out-Null

	$sb.AppendLine("CPU UTILIZATION (%)") | Out-Null
	$sb.AppendLine("──────────────────") | Out-Null
	$sb.AppendLine(("{0,-30} {1,12} {2,12} {3,12} {4,12}" -f "Metric", "Current", "Min", "Max", "Avg")) | Out-Null
	$sb.AppendLine(("{0,-30} {1,12:F2} {2,12:F2} {3,12:F2} {4,12:F2}" -f "Processor Utilization %", $Agg.CPUUtilization_Current, $Agg.CPUUtilization_Min, $Agg.CPUUtilization_Max, $Agg.CPUUtilization_Avg)) | Out-Null
	$sb.AppendLine() | Out-Null

	$sb.AppendLine("MEMORY UTILIZATION (MB)") | Out-Null
	$sb.AppendLine("───────────────────────") | Out-Null
	$sb.AppendLine(("{0,-30} {1,12} {2,12} {3,12} {4,12}" -f "Metric", "Current", "Min", "Max", "Avg")) | Out-Null
	$sb.AppendLine(("{0,-30} {1,12:N0} {2,12:N0} {3,12:N0} {4,12:N0}" -f "SQL Memory (MB)", $Agg.SQLMemory_Current, $Agg.SQLMemory_Min, $Agg.SQLMemory_Max, $Agg.SQLMemory_Avg)) | Out-Null
	$sb.AppendLine(("{0,-30} {1,12:N0} {2,12:N0} {3,12:N0} {4,12:N0}" -f "Available Memory (MB)", $Agg.AvailableMemory_Current, $Agg.AvailableMemory_Min, $Agg.AvailableMemory_Max, $Agg.AvailableMemory_Avg)) | Out-Null
	$sb.AppendLine() | Out-Null

	$sb.AppendLine("WORKER THREADS") | Out-Null
	$sb.AppendLine("──────────────") | Out-Null
	$sb.AppendLine(("{0,-30} {1,12} {2,12} {3,12} {4,12}" -f "Metric", "Current", "Min", "Max", "Avg")) | Out-Null
	$sb.AppendLine(("{0,-30} {1,12:N0} {2,12:N0} {3,12:N0} {4,12:N0}" -f "Runnable Threads", $Agg.RunnableThreads_Current, $Agg.RunnableThreads_Min, $Agg.RunnableThreads_Max, $Agg.RunnableThreads_Avg)) | Out-Null
	$sb.AppendLine(("{0,-30} {1,12:N0} {2,12:N0} {3,12:N0} {4,12:N0}" -f "Active Threads", $Agg.ActiveThreads_Current, $Agg.ActiveThreads_Min, $Agg.ActiveThreads_Max, $Agg.ActiveThreads_Avg)) | Out-Null
	$sb.AppendLine() | Out-Null

	$sb.AppendLine("COMPILATION & EXECUTION") | Out-Null
	$sb.AppendLine("───────────────────────") | Out-Null
	$sb.AppendLine("Cached Query Plans: $($Agg.CachedPlans.ToString('N0'))") | Out-Null
	$sb.AppendLine("Total Compilations: $($Agg.TotalCompilations.ToString('N0'))") | Out-Null
	$sb.AppendLine() | Out-Null

	$sb.AppendLine("SAMPLING DETAILS") | Out-Null
	$sb.AppendLine("────────────────") | Out-Null
	$sb.AppendLine("Period: $($Agg.StartTime.ToString('yyyy-MM-dd HH:mm:ss')) — $($Agg.EndTime.ToString('HH:mm:ss'))") | Out-Null
	$sb.AppendLine("Duration: $((($Agg.EndTime - $Agg.StartTime).TotalSeconds).ToString('F1')) seconds") | Out-Null
	$sb.AppendLine("Samples: $($Agg.SampleCount)") | Out-Null
	$sb.AppendLine() | Out-Null

	$reference = Get-sqmReportReference
	$sb.AppendLine("$reference") | Out-Null

	return $sb.ToString()
}

function Generate-UtilizationHtmlReport
{
	param(
		[PSCustomObject]$Agg,
		[string]$SqlInstance,
		[array]$Samples
	)

	$htmlTable = $Samples | ConvertTo-Html -Fragment | Out-String

	# Pre-format all values (here-strings can't execute pipes)
	$cpuCurr = $Agg.CPUUtilization_Current.ToString("F2")
	$cpuMin = $Agg.CPUUtilization_Min.ToString("F2")
	$cpuMax = $Agg.CPUUtilization_Max.ToString("F2")
	$cpuAvg = $Agg.CPUUtilization_Avg.ToString("F2")
	$sqlMemCurr = $Agg.SQLMemory_Current.ToString("N0")
	$sqlMemAvg = $Agg.SQLMemory_Avg.ToString("N0")
	$availMemCurr = $Agg.AvailableMemory_Current.ToString("N0")
	$availMemAvg = $Agg.AvailableMemory_Avg.ToString("N0")
	$runnAvg = $Agg.RunnableThreads_Avg.ToString("F2")
	$activeAvg = $Agg.ActiveThreads_Avg.ToString("F2")
	$duration = (($Agg.EndTime - $Agg.StartTime).TotalSeconds).ToString("F1")
	$reference = Get-sqmReportReference

	$html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset='utf-8'>
    <title>SQL Server Utilization Report</title>
    <style>
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:'Segoe UI',Arial,sans-serif;background:#0f172a;color:#e2e8f0;font-size:13px}
        .page-header{background:linear-gradient(160deg,#1e3a8a 0%,#2e5090 100%);padding:28px 32px;border-left:4px solid #3b82f6;margin-bottom:24px}
        .page-header h1{font-size:1.4rem;font-weight:700;color:#60a5fa;margin:0 0 4px 0}
        .page-header .sub{font-size:.82rem;color:#94a3b8}
        .wrap{padding:0 24px 40px}
        h2{font-size:1rem;font-weight:600;color:#60a5fa;margin:28px 0 12px;border-bottom:1px solid #1e3a5f;padding-bottom:6px}
        table{width:100%;border-collapse:collapse;background:#0b1e3d;border-radius:6px;overflow:hidden;margin-bottom:20px}
        th{background:#1e3a8a;color:#60a5fa;padding:9px 12px;text-align:left;font-weight:600;font-size:.75rem;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #3b82f6}
        td{padding:8px 12px;border-bottom:1px solid #1e3a5f;color:#e2e8f0;vertical-align:top}
        tr:hover td{background:#0f2744}
        .summary-table td:first-child{color:#94a3b8;font-weight:600;width:28%}
        .footer{margin-top:32px;padding-top:16px;border-top:1px solid #1e3a5f;font-size:.75rem;color:#475569;text-align:center}
        .footer a{color:#5dade2;text-decoration:none}
    </style>
</head>
<body>
<div class='page-header'>
  <h1>SQL Server Utilization Report</h1>
  <div class='sub'>Instance: $SqlInstance &bull; Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</div>
<div class='wrap'>

    <h2>Summary Metrics</h2>
    <table class='summary-table'>
        <tr>
            <td>CPU Utilization (Current / Min / Max / Avg %)</td>
            <td>$cpuCurr / $cpuMin / $cpuMax / $cpuAvg</td>
        </tr>
        <tr>
            <td>SQL Memory (Current / Avg MB)</td>
            <td>$sqlMemCurr / $sqlMemAvg</td>
        </tr>
        <tr>
            <td>Available Memory (Current / Avg MB)</td>
            <td>$availMemCurr / $availMemAvg</td>
        </tr>
        <tr>
            <td>Runnable Threads (Current / Avg)</td>
            <td>$($Agg.RunnableThreads_Current) / $runnAvg</td>
        </tr>
        <tr>
            <td>Active Threads (Current / Avg)</td>
            <td>$($Agg.ActiveThreads_Current) / $activeAvg</td>
        </tr>
        <tr>
            <td>Cached Plans</td>
            <td>$($Agg.CachedPlans.ToString('N0'))</td>
        </tr>
        <tr>
            <td>Total Compilations</td>
            <td>$($Agg.TotalCompilations.ToString('N0'))</td>
        </tr>
    </table>

    <h2>Sample Timeline</h2>
    $htmlTable

    <div class='footer'>
        <p>$reference</p>
        <p>Sampling Period: $($Agg.StartTime.ToString('yyyy-MM-dd HH:mm:ss')) — $($Agg.EndTime.ToString('HH:mm:ss')) ($duration sec, $($Agg.SampleCount) samples)</p>
    </div>
</div>
</body>
</html>
"@

	return $html
}
