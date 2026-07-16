<#
.SYNOPSIS
    Reads and analyzes SQL Server wait statistics from sys.dm_os_wait_stats.

.DESCRIPTION
    Reads the cumulative wait statistics of the instance, filters out known idle waits
    and returns the top-N waits with category and recommended action.
    Optional: snapshot comparison (before/after) via -SnapshotBefore/-SaveSnapshot.

    The idle/background filter follows the established SQLskills ignore list
    (Paul Randal), including the types introduced with SQL Server 2016/2017/2019
    (SOS_WORK_DISPATCHER, QDS_*, PREEMPTIVE_XE_DISPATCHER, PARALLEL_REDO_*).

    Recommendations are threshold based: a wait is only reported when its average
    wait time (or its share of the relevant wait time) actually indicates a problem.
    A large cumulative sum alone means nothing - it only reflects uptime.

.PARAMETER SqlInstance
    SQL Server instance. Default: local computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER TopN
    Number of top wait types to return. Default: 25.

.PARAMETER IncludeIdle
    Include idle waits (SLEEP_*, WAITFOR, etc.). Default: off.

.PARAMETER SnapshotBefore
    PSCustomObject array of an earlier snapshot (output of -SaveSnapshot).
    If specified, only the delta is calculated.

.PARAMETER SaveSnapshot
    Returns a snapshot array that can later be used as SnapshotBefore.

.PARAMETER OutputPath
    If specified, a CSV report is saved.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmWaitStatistics -SqlInstance "SQL01" -TopN 20

.EXAMPLE
    $before = Get-sqmWaitStatistics -SqlInstance "SQL01" -SaveSnapshot
    Get-sqmWaitStatistics -SqlInstance "SQL01" -SnapshotBefore $before

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE.
#>
function Get-sqmWaitStatistics
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 500)]
		[int]$TopN = 25,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeIdle,
		[Parameter(Mandatory = $false)]
		[object[]]$SnapshotBefore,
		[Parameter(Mandatory = $false)]
		[switch]$SaveSnapshot,
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
			$errMsg = _s 'Error_dbatoolsNotFound'
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Idle-/Background-Waits nach der SQLskills-Ignore-Liste (Paul Randal).
		# Diese Typen laufen dauerhaft im Leerlauf mit und haben nichts mit Last zu
		# tun. Bleiben sie drin, frisst allein SOS_WORK_DISPATCHER auf einer 2022er
		# Instanz ueber 80 % der ausgewiesenen Wartezeit und WaitTimePct wird wertlos.
		$idleWaits = @(
			# Service Broker
			'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP',
			'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER', 'BROKER_SLEEP',
			# Checkpoint / Lazywriter / Log
			'CHECKPOINT_QUEUE', 'CHKPT', 'DIRTY_PAGE_POLL', 'LAZYWRITER_SLEEP',
			'LOGMGR_QUEUE', 'SLEEP_BPOOL_FLUSH', 'SLEEP_BUFFERPOOL_HELPLW',
			# CLR
			'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'CLR_SEMAPHORE',
			# Mirroring / AlwaysOn
			'DBMIRROR_DBM_EVENT', 'DBMIRROR_EVENTS_QUEUE', 'DBMIRROR_WORKER_QUEUE',
			'DBMIRRORING_CMD', 'HADR_CLUSAPI_CALL',
			'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'HADR_LOGCAPTURE_WAIT',
			'HADR_NOTIFICATION_DEQUEUE', 'HADR_TIMER_TASK', 'HADR_WORK_QUEUE',
			'HADR_SLEEP_TASK', 'PARALLEL_REDO_DRAIN_WORKER', 'PARALLEL_REDO_LOG_CACHE',
			'PARALLEL_REDO_TRAN_LIST', 'PARALLEL_REDO_WORKER_SYNC',
			'PARALLEL_REDO_WORKER_WAIT_WORK', 'REDO_THREAD_PENDING_WORK',
			# Full-Text
			'FT_IFTS_SCHEDULER_IDLE_WAIT', 'FT_IFTSHC_MUTEX', 'FSAGENT',
			# Query Store (SQL 2016+)
			'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
			'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_SHUTDOWN_QUEUE',
			# Scheduler / Worker Idle (SOS_WORK_DISPATCHER: SQL 2019+)
			'DISPATCHER_QUEUE_SEMAPHORE', 'EXECSYNC', 'KSOURCE_WAKEUP',
			'MEMORY_ALLOCATION_EXT', 'ONDEMAND_TASK_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH',
			'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK', 'SOS_WORK_DISPATCHER',
			'SP_SERVER_DIAGNOSTICS_SLEEP', 'STARTUP_DEPENDENCY_MANAGER',
			# Preemptive Background
			'PREEMPTIVE_OS_FLUSHFILEBUFFERS', 'PREEMPTIVE_XE_DISPATCHER',
			'PREEMPTIVE_XE_GETTARGETSTATE',
			# Accelerated Database Recovery / Extensibility (SQL 2019+)
			'PVS_PREALLOCATE', 'PWAIT_ALL_COMPONENTS_INITIALIZED',
			'PWAIT_DIRECTLOGCONSUMER_GETNEXT', 'PWAIT_EXTENSIBILITY_CLEANUP_TASK',
			# Sleep / Startup
			'SLEEP_DBSTARTUP', 'SLEEP_DBTASK', 'SLEEP_DCOMSTARTUP',
			'SLEEP_MASTERDBREADY', 'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED',
			'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK', 'SLEEP_TASK',
			'SLEEP_TEMPDBSTARTUP', 'SLEEP_WORKER_THREAD',
			# Trace / Extended Events
			'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
			'SQLTRACE_WAIT_ENTRIES', 'XE_BUFFERMGR_ALLPROCESSED_EVENT',
			'XE_DISPATCHER_JOIN', 'XE_DISPATCHER_WAIT', 'XE_LIVE_TARGET_TVF',
			'XE_TIMER_EVENT',
			# Sonstige
			'SNI_HTTP_ACCEPT', 'VDI_CLIENT_OTHER', 'WAIT_FOR_RESULTS',
			'WAITFOR', 'WAITFOR_TASKSHUTDOWN',
			# In-Memory OLTP
			'WAIT_XTP_CKPT_CLOSE', 'WAIT_XTP_HOST_WAIT',
			'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 'WAIT_XTP_ONLINE_INDEX_BUILD',
			'WAIT_XTP_RECOVERY'
		)

		# Kategorien, Empfehlungen und Schwellwerte.
		#
		# Ohne Schwellwert feuert jede Empfehlung auf die kumulierte Summe - und die
		# waechst allein mit der Uptime. PAGEIOLATCH_SH mit 2 ms Durchschnitt ist
		# gesundes Storage, auch wenn die Summe ueber Wochen auf 75.000 Sekunden
		# klettert. Darum entscheidet:
		#   MinAvgWaitMs     - Durchschnittsdauer je Wait (I/O, Locks, Latches, Netz)
		#   MinWaitPct       - Anteil an der relevanten Wartezeit (Parallelismus, Memory:
		#                      viele kurze Waits, die erst in der Masse weh tun)
		#   MinSignalWaitPct - instanzweiter Signal-Wait-Anteil (CPU-Druck)
		# Ohne Schwellwert-Key wird immer gemeldet (THREADPOOL ist nie harmlos).
		$waitCategories = @{
			'PAGEIOLATCH_SH'     = @{ Category = 'I/O';         MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_PAGEIOLATCH_SH') }
			'PAGEIOLATCH_EX'     = @{ Category = 'I/O';         MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_PAGEIOLATCH_EX') }
			'PAGEIOLATCH_UP'     = @{ Category = 'I/O';         MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_PAGEIOLATCH_UP') }
			'WRITELOG'           = @{ Category = 'I/O';         MinAvgWaitMs = 5;       Recommendation = (_s 'WaitRec_WRITELOG') }
			'IO_COMPLETION'      = @{ Category = 'I/O';         MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_IO_COMPLETION') }
			'ASYNC_IO_COMPLETION'= @{ Category = 'I/O';         MinAvgWaitMs = 1000;    Recommendation = (_s 'WaitRec_ASYNC_IO_COMPLETION') }
			'LCK_M_X'            = @{ Category = 'Locking';     MinAvgWaitMs = 500;     Recommendation = (_s 'WaitRec_LCK_M_X') }
			'LCK_M_S'            = @{ Category = 'Locking';     MinAvgWaitMs = 500;     Recommendation = (_s 'WaitRec_LCK_M_S') }
			'LCK_M_U'            = @{ Category = 'Locking';     MinAvgWaitMs = 500;     Recommendation = (_s 'WaitRec_LCK_M_U') }
			'LCK_M_IX'           = @{ Category = 'Locking';     MinAvgWaitMs = 500;     Recommendation = (_s 'WaitRec_LCK_M_IX') }
			'LCK_M_IS'           = @{ Category = 'Locking';     MinAvgWaitMs = 500;     Recommendation = (_s 'WaitRec_LCK_M_IS') }
			'CXPACKET'           = @{ Category = 'Parallelism'; MinWaitPct = 5;         Recommendation = (_s 'WaitRec_CXPACKET') }
			'CXCONSUMER'         = @{ Category = 'Parallelism'; MinWaitPct = 5;         Recommendation = (_s 'WaitRec_CXCONSUMER') }
			'CXSYNC_PORT'        = @{ Category = 'Parallelism'; MinWaitPct = 5;         Recommendation = (_s 'WaitRec_CXSYNC_PORT') }
			'RESOURCE_SEMAPHORE' = @{ Category = 'Memory';      MinWaitPct = 5;         Recommendation = (_s 'WaitRec_RESOURCE_SEMAPHORE') }
			'RESOURCE_SEMAPHORE_QUERY_COMPILE' = @{ Category = 'Memory'; MinWaitPct = 5; Recommendation = (_s 'WaitRec_RES_SEM_COMPILE') }
			'CMEMTHREAD'         = @{ Category = 'Memory';      MinWaitPct = 5;         Recommendation = (_s 'WaitRec_CMEMTHREAD') }
			'SOS_SCHEDULER_YIELD'= @{ Category = 'CPU';         MinSignalWaitPct = 25;  Recommendation = (_s 'WaitRec_SOS_SCHEDULER_YIELD') }
			'THREADPOOL'         = @{ Category = 'CPU';                                 Recommendation = (_s 'WaitRec_THREADPOOL') }
			'PAGELATCH_EX'       = @{ Category = 'Latch';       MinAvgWaitMs = 5;       Recommendation = (_s 'WaitRec_PAGELATCH_EX') }
			'PAGELATCH_SH'       = @{ Category = 'Latch';       MinAvgWaitMs = 5;       Recommendation = (_s 'WaitRec_PAGELATCH_SH') }
			'PAGELATCH_UP'       = @{ Category = 'Latch';       MinAvgWaitMs = 5;       Recommendation = (_s 'WaitRec_PAGELATCH_UP') }
			'LATCH_EX'           = @{ Category = 'Latch';       MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_LATCH_EX') }
			'LATCH_SH'           = @{ Category = 'Latch';       MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_LATCH_SH') }
			'DBMIRROR_EVENTS_QUEUE' = @{ Category = 'Network';  MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_DBMIRROR_EVENTS_QUEUE') }
			'DBMIRRORING_CMD'    = @{ Category = 'Network';     MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_DBMIRRORING_CMD') }
			'ASYNC_NETWORK_IO'   = @{ Category = 'Network';     MinAvgWaitMs = 10;      Recommendation = (_s 'WaitRec_ASYNC_NETWORK_IO') }
		}

		Invoke-sqmLogging -Message (_s 'WaitStats_Starting' $functionName, $SqlInstance, $TopN, $IncludeIdle) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$waitSql = @"
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms AS resource_wait_time_ms,
    CASE WHEN waiting_tasks_count > 0
         THEN CAST(wait_time_ms * 1.0 / waiting_tasks_count AS DECIMAL(18,2))
         ELSE 0 END AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE waiting_tasks_count > 0
ORDER BY wait_time_ms DESC
"@
			$rawWaits = Invoke-DbaQuery @connParams -Database master -Query $waitSql -ErrorAction Stop

			if (-not $rawWaits)
			{
				Invoke-sqmLogging -Message (_s 'WaitStats_NoData') -FunctionName $functionName -Level "WARNING"
				return
			}

			if ($SaveSnapshot)
			{
				Invoke-sqmLogging -Message (_s 'WaitStats_SnapshotCreated' $rawWaits.Count) -FunctionName $functionName -Level "INFO"
				return $rawWaits
			}

			$workingSet = if ($SnapshotBefore)
			{
				$beforeHash = @{}
				foreach ($row in $SnapshotBefore) { $beforeHash[$row.wait_type] = $row }
				$rawWaits | ForEach-Object {
					$prev = $beforeHash[$_.wait_type]
					[PSCustomObject]@{
						wait_type              = $_.wait_type
						waiting_tasks_count    = $_.waiting_tasks_count    - [long]($prev.waiting_tasks_count)
						wait_time_ms           = $_.wait_time_ms           - [long]($prev.wait_time_ms)
						max_wait_time_ms       = $_.max_wait_time_ms
						signal_wait_time_ms    = $_.signal_wait_time_ms    - [long]($prev.signal_wait_time_ms)
						resource_wait_time_ms  = ($_.wait_time_ms - $_.signal_wait_time_ms) - ([long]($prev.wait_time_ms) - [long]($prev.signal_wait_time_ms))
						avg_wait_ms            = if (($_.waiting_tasks_count - [long]($prev.waiting_tasks_count)) -gt 0) {
							[math]::Round(($_.wait_time_ms - [long]($prev.wait_time_ms)) * 1.0 / ($_.waiting_tasks_count - [long]($prev.waiting_tasks_count)), 2)
						} else { 0 }
						IsDelta                = $true
					}
				} | Where-Object { $_.wait_time_ms -gt 0 }
			}
			else { $rawWaits }

			$filtered = if ($IncludeIdle) { $workingSet }
			else { $workingSet | Where-Object { $_.wait_type -notin $idleWaits } }

			$totalWaitMs = ($filtered | Measure-Object wait_time_ms -Sum).Sum
			if (-not $totalWaitMs -or $totalWaitMs -eq 0) { $totalWaitMs = 1 }

			# Instanzweiter Signal-Wait-Anteil: Zeit, die runnable Tasks nach dem
			# Wait noch auf einen Scheduler warten. Das ist das etablierte Mass fuer
			# CPU-Druck - anders als die absolute SOS_SCHEDULER_YIELD-Summe, die auf
			# jeder Instanz mit genug Uptime gross aussieht.
			$totalSignalMs = ($filtered | Measure-Object signal_wait_time_ms -Sum).Sum
			$signalWaitPct = [math]::Round($totalSignalMs * 100.0 / $totalWaitMs, 1)

			$results = $filtered |
				Sort-Object wait_time_ms -Descending |
				Select-Object -First $TopN |
				ForEach-Object {
					$pct       = [math]::Round($_.wait_time_ms * 100.0 / $totalWaitMs, 1)
					$avgWaitMs = [double]$_.avg_wait_ms
					$rowSigPct = if ($_.wait_time_ms -gt 0) { [math]::Round($_.signal_wait_time_ms * 100.0 / $_.wait_time_ms, 1) } else { 0 }

					$cat = 'Other'
					$rec = ''
					if ($waitCategories.ContainsKey($_.wait_type))
					{
						$meta = $waitCategories[$_.wait_type]
						$cat  = $meta.Category

						# Erster verletzter Schwellwert gewinnt und erklaert, warum hier
						# nichts zu tun ist. Sonst raet der Leser, ob die leere Zelle
						# "unauffaellig" oder "nicht bewertet" heisst.
						$rec = if ($meta.ContainsKey('MinAvgWaitMs') -and $avgWaitMs -lt $meta.MinAvgWaitMs)
						{
							_s 'WaitRec_BelowAvgWaitMs' $avgWaitMs, $meta.MinAvgWaitMs
						}
						elseif ($meta.ContainsKey('MinWaitPct') -and $pct -lt $meta.MinWaitPct)
						{
							_s 'WaitRec_BelowWaitPct' $pct, $meta.MinWaitPct
						}
						elseif ($meta.ContainsKey('MinSignalWaitPct') -and $signalWaitPct -lt $meta.MinSignalWaitPct)
						{
							_s 'WaitRec_BelowSignalWaitPct' $signalWaitPct, $meta.MinSignalWaitPct
						}
						else { $meta.Recommendation }
					}

					[PSCustomObject]@{
						WaitType             = $_.wait_type
						Category             = $cat
						WaitTimeSec          = [math]::Round($_.wait_time_ms / 1000.0, 1)
						WaitTimePct          = $pct
						WaitingTasksCount    = $_.waiting_tasks_count
						AvgWaitMs            = $_.avg_wait_ms
						MaxWaitMs            = $_.max_wait_time_ms
						SignalWaitMs         = $_.signal_wait_time_ms
						SignalWaitPct        = $rowSigPct
						ResourceWaitMs       = $_.resource_wait_time_ms
						IsDelta              = [bool]$SnapshotBefore
						Recommendation       = $rec
					}
				}

			if ($OutputPath)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'
				$ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
				$csvFile  = Join-Path $OutputPath "WaitStats_${safeInst}_${ts}.csv"
				$results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message (_s 'WaitStats_Saved' $csvFile) -FunctionName $functionName -Level "INFO"

				$htmlFile = Join-Path $OutputPath "WaitStats_${safeInst}_${ts}.html"
				$bodyHtml = ($results | ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "Wait Statistics - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}

			Invoke-sqmLogging -Message (_s 'WaitStats_SignalWaitPct' $signalWaitPct) -FunctionName $functionName -Level "INFO"
			Invoke-sqmLogging -Message (_s 'WaitStats_Completed' $functionName, $results.Count, ([math]::Round($totalWaitMs/1000,1))) -FunctionName $functionName -Level "INFO"
			return $results
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
