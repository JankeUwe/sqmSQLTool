<#
.SYNOPSIS
    Erstellt, vergleicht oder listet Performance-Baselines (Wait Stats + Perf Counters).

.DESCRIPTION
    Capture: Speichert aktuellen Snapshot von sys.dm_os_wait_stats und
    sys.dm_os_performance_counters als JSON-Datei.
    Compare: Berechnet das Delta zwischen zwei Baselines.
    List:    Listet alle gespeicherten Baseline-Dateien auf.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER Action
    Capture | Compare | List. Standard: Capture.

.PARAMETER BaselineName
    Bezeichnung fuer den Snapshot (wird im Dateinamen verwendet).
    Standard: Timestamp.

.PARAMETER BaselineA
    Pfad oder Dateiname (ohne Pfad) der ersten Baseline fuer den Vergleich.
    Standard: die vorletzte Datei im OutputPath.

.PARAMETER BaselineB
    Pfad oder Dateiname der zweiten (neueren) Baseline.
    Standard: die neueste Datei im OutputPath.

.PARAMETER OutputPath
    Verzeichnis fuer Baseline-JSON-Dateien.
    Standard: aus Modulkonfiguration + \PerfBaseline.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    # Baseline aufnehmen
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -BaselineName "vor_patch"

.EXAMPLE
    # Baseline nach Aenderung aufnehmen und vergleichen
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -BaselineName "nach_patch"
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -Action Compare

.EXAMPLE
    # Alle Baselines auflisten
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -Action List

.NOTES
    Erfordert: Invoke-sqmLogging, Get-sqmDefaultOutputPath
    Benoetigt VIEW SERVER STATE.
#>
function Invoke-sqmPerfBaseline
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Capture', 'Compare', 'List')]
		[string]$Action = 'Capture',
		[Parameter(Mandatory = $false)]
		[string]$BaselineName,
		[Parameter(Mandatory = $false)]
		[string]$BaselineA,
		[Parameter(Mandatory = $false)]
		[string]$BaselineB,
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
			$errMsg = _s 'Error_dbatoolsNotFound'
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		if (-not $OutputPath) { $OutputPath = Join-Path (Get-sqmDefaultOutputPath) 'PerfBaseline' }
		if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

		$idleWaits = @(
			'SLEEP_TASK','SLEEP_SYSTEMTASK','SLEEP_DBSTARTUP','SLEEP_DBTASK',
			'SLEEP_TEMPDBSTARTUP','WAITFOR','BROKER_TO_FLUSH','BROKER_SLEEP',
			'SQLTRACE_BUFFER_FLUSH','CLR_AUTO_EVENT','CLR_MANUAL_EVENT',
			'DISPATCHER_QUEUE_SEMAPHORE','XE_DISPATCHER_WAIT','XE_TIMER_EVENT',
			'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','HADR_WORK_QUEUE','HADR_SLEEP_TASK',
			'LAZYWRITER_SLEEP','LOGMGR_QUEUE','CHECKPOINT_QUEUE',
			'REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE','SERVER_IDLE_CHECK',
			'SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP','ONDEMAND_TASK_QUEUE',
			'DIRTY_PAGE_POLL','FT_IFTS_SCHEDULER_IDLE_WAIT'
		)

		Invoke-sqmLogging -Message (_s 'Baseline_Starting' $functionName, $SqlInstance, $Action) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'

			# ============================================================
			# LIST
			# ============================================================
			if ($Action -eq 'List')
			{
				$files = Get-ChildItem -Path $OutputPath -Filter "PerfBaseline_${safeInst}_*.json" -ErrorAction SilentlyContinue |
					Sort-Object LastWriteTime -Descending
				if (-not $files)
				{
					Write-Host (_s 'Baseline_NoFiles' $OutputPath) -ForegroundColor Yellow
					return @()
				}
				return $files | ForEach-Object {
					[PSCustomObject]@{
						FileName     = $_.Name
						FullPath     = $_.FullName
						SizeKB       = [math]::Round($_.Length / 1024, 1)
						CreatedAt    = $_.LastWriteTime
					}
				}
			}

			# ============================================================
			# CAPTURE
			# ============================================================
			if ($Action -eq 'Capture')
			{
				$ts    = Get-Date -Format 'yyyyMMdd_HHmsqm'
				$label = if ($BaselineName) { $BaselineName -replace '[^\w\-]', '_' } else { $ts }

				# Wait Stats
				$waitSql = @"
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       max_wait_time_ms, signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE waiting_tasks_count > 0
ORDER BY wait_time_ms DESC
"@
				$waitRows = Invoke-DbaQuery @connParams -Database master -Query $waitSql -ErrorAction Stop |
					Where-Object { $_.wait_type -notin $idleWaits }

				# Perf Counters
				$counterSql = @"
SELECT
    RTRIM(object_name)   AS object_name,
    RTRIM(counter_name)  AS counter_name,
    RTRIM(instance_name) AS instance_name,
    cntr_value,
    cntr_type
FROM sys.dm_os_performance_counters
WHERE (
    (counter_name LIKE '%Buffer cache hit ratio%')
 OR (counter_name LIKE '%Page life expectancy%')
 OR (counter_name LIKE '%Batch Requests/sec%')
 OR (counter_name LIKE '%SQL Compilations/sec%')
 OR (counter_name LIKE '%SQL Re-Compilations/sec%')
 OR (counter_name LIKE '%Lock Waits/sec%'     AND instance_name = '_Total')
 OR (counter_name LIKE '%User Connections%')
 OR (counter_name LIKE '%Total Server Memory%')
 OR (counter_name LIKE '%Target Server Memory%')
 OR (counter_name LIKE '%Full Scans/sec%')
 OR (counter_name LIKE '%Index Searches/sec%')
 OR (counter_name LIKE '%Lazy Writes/sec%')
 OR (counter_name LIKE '%Checkpoint Pages/sec%')
 OR (counter_name LIKE '%Memory Grants Pending%')
 OR (counter_name LIKE '%Processes Blocked%')
)
"@
				$counterRows = Invoke-DbaQuery @connParams -Database master -Query $counterSql -ErrorAction Stop

				# Als JSON speichern
				$snapshot = [PSCustomObject]@{
					SqlInstance  = $SqlInstance
					BaselineName = $label
					CapturedAt   = (Get-Date -Format 'o')
					WaitStats    = @($waitRows | ForEach-Object {
						[PSCustomObject]@{
							wait_type           = $_.wait_type
							waiting_tasks_count = [long]$_.waiting_tasks_count
							wait_time_ms        = [long]$_.wait_time_ms
							max_wait_time_ms    = [long]$_.max_wait_time_ms
							signal_wait_time_ms = [long]$_.signal_wait_time_ms
						}
					})
					PerfCounters = @($counterRows | ForEach-Object {
						[PSCustomObject]@{
							object_name   = $_.object_name
							counter_name  = $_.counter_name
							instance_name = $_.instance_name
							cntr_value    = [long]$_.cntr_value
							cntr_type     = [long]$_.cntr_type
						}
					})
				}

				$outFile = Join-Path $OutputPath "PerfBaseline_${safeInst}_${ts}_${label}.json"
				$snapshot | ConvertTo-Json -Depth 5 | Out-File -FilePath $outFile -Encoding UTF8 -Force

				Invoke-sqmLogging -Message (_s 'Baseline_Saved' $outFile, $snapshot.WaitStats.Count, $snapshot.PerfCounters.Count) -FunctionName $functionName -Level "INFO"

				return [PSCustomObject]@{
					Action         = 'Capture'
					SqlInstance    = $SqlInstance
					BaselineName   = $label
					FileName       = $outFile
					WaitStatCount  = $snapshot.WaitStats.Count
					CounterCount   = $snapshot.PerfCounters.Count
					Timestamp      = $snapshot.CapturedAt
				}
			}

			# ============================================================
			# COMPARE
			# ============================================================
			if ($Action -eq 'Compare')
			{
				# Dateien aufloesen
				$allFiles = Get-ChildItem -Path $OutputPath -Filter "PerfBaseline_${safeInst}_*.json" |
					Sort-Object LastWriteTime

				function Resolve-BaselineFile($nameOrPath)
				{
					if ($nameOrPath -and (Test-Path $nameOrPath)) { return $nameOrPath }
					if ($nameOrPath)
					{
						$found = $allFiles | Where-Object { $_.Name -like "*$nameOrPath*" } | Select-Object -Last 1
						if ($found) { return $found.FullName }
					}
					return $null
				}

				$fileA = if ($BaselineA) { Resolve-BaselineFile $BaselineA } else { if ($allFiles.Count -ge 2) { $allFiles[-2].FullName } else { $null } }
				$fileB = if ($BaselineB) { Resolve-BaselineFile $BaselineB } else { if ($allFiles.Count -ge 1) { $allFiles[-1].FullName } else { $null } }

				if (-not $fileA -or -not $fileB)
				{
					$errMsg = _s 'Baseline_NotEnoughFiles'
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $errMsg }
					Write-Error $errMsg; return
				}

				$snapA = Get-Content $fileA -Raw -Encoding UTF8 | ConvertFrom-Json
				$snapB = Get-Content $fileB -Raw -Encoding UTF8 | ConvertFrom-Json

				Invoke-sqmLogging -Message (_s 'Baseline_Comparing' $snapA.BaselineName, $snapB.BaselineName) -FunctionName $functionName -Level "INFO"

				# Wait Stats Delta
				$waitHashA = @{}
				foreach ($w in $snapA.WaitStats) { $waitHashA[$w.wait_type] = $w }

				$waitDelta = $snapB.WaitStats | ForEach-Object {
					$a = $waitHashA[$_.wait_type]
					$deltaMs  = [long]$_.wait_time_ms - [long]($a.wait_time_ms)
					$deltaCnt = [long]$_.waiting_tasks_count - [long]($a.waiting_tasks_count)
					if ($deltaMs -gt 0)
					{
						[PSCustomObject]@{
							WaitType            = $_.wait_type
							DeltaWaitSec        = [math]::Round($deltaMs / 1000.0, 1)
							DeltaWaitingTasks   = $deltaCnt
							AvgWaitMsDelta      = if ($deltaCnt -gt 0) { [math]::Round($deltaMs * 1.0 / $deltaCnt, 2) } else { 0 }
							Type                = 'WaitStat'
						}
					}
				} | Sort-Object DeltaWaitSec -Descending

				# Perf Counter Delta
				$ctrHashA = @{}
				foreach ($c in $snapA.PerfCounters) { $ctrHashA["$($c.object_name)|$($c.counter_name)|$($c.instance_name)"] = $c }

				$ctrDelta = $snapB.PerfCounters | ForEach-Object {
					$key = "$($_.object_name)|$($_.counter_name)|$($_.instance_name)"
					$a   = $ctrHashA[$key]
					[PSCustomObject]@{
						Counter        = "$($_.counter_name) [$($_.instance_name)]"
						ValueA         = if ($a) { [long]$a.cntr_value } else { 0 }
						ValueB         = [long]$_.cntr_value
						Delta          = [long]$_.cntr_value - [long]($a.cntr_value)
						Type           = 'PerfCounter'
					}
				} | Sort-Object { [math]::Abs($_.Delta) } -Descending

				return [PSCustomObject]@{
					Action       = 'Compare'
					BaselineA    = $snapA.BaselineName
					BaselineB    = $snapB.BaselineName
					CapturedA    = $snapA.CapturedAt
					CapturedB    = $snapB.CapturedAt
					WaitDeltas   = @($waitDelta)
					CounterDeltas = @($ctrDelta)
				}
			}
		}
		catch
		{
			$errMsg = _s 'Error_Generic' $functionName, $_.Exception.Message
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
	}
}
