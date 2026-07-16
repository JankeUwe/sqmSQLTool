<#
.SYNOPSIS
    Reads and analyzes SQL Server wait statistics from sys.dm_os_wait_stats.

.DESCRIPTION
    Reads the cumulative wait statistics of the instance, filters out known idle waits
    and returns the top-N waits with category and recommended action.
    Optional: snapshot comparison (before/after) via -SnapshotBefore/-SaveSnapshot.

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

		$idleWaits = @(
			'SLEEP_TASK','SLEEP_SYSTEMTASK','SLEEP_DBSTARTUP','SLEEP_DBTASK',
			'SLEEP_TEMPDBSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
			'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_TEMPDBSTARTUP',
			'SLEEP_WORKER_THREAD','WAITFOR','WAITFOR_TASKSHUTDOWN',
			'BROKER_TO_FLUSH','BROKER_SLEEP','BROKER_EVENTHANDLER',
			'SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
			'CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE',
			'DISPATCHER_QUEUE_SEMAPHORE','XE_DISPATCHER_WAIT','XE_TIMER_EVENT',
			'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','HADR_WORK_QUEUE','HADR_SLEEP_TASK',
			'HADR_FILESTREAM_IOMGR_IOCOMPLETION','LAZYWRITER_SLEEP',
			'LOGMGR_QUEUE','CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH',
			'RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_DBSTARTUP',
			'SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP','ONDEMAND_TASK_QUEUE',
			'WAIT_XTP_HOST_WAIT','WAIT_XTP_ONLINE_INDEX_BUILD',
			'FT_IFTS_SCHEDULER_IDLE_WAIT','FT_IFTSHC_MUTEX','DIRTY_PAGE_POLL'
		)

		# Kategorien und Empfehlungen aus Sprachdatei laden
		$waitCategories = @{
			'PAGEIOLATCH_SH'     = @{ Category = 'I/O';         Recommendation = (_s 'WaitRec_PAGEIOLATCH_SH') }
			'PAGEIOLATCH_EX'     = @{ Category = 'I/O';         Recommendation = (_s 'WaitRec_PAGEIOLATCH_EX') }
			'PAGEIOLATCH_UP'     = @{ Category = 'I/O';         Recommendation = (_s 'WaitRec_PAGEIOLATCH_UP') }
			'WRITELOG'           = @{ Category = 'I/O';         Recommendation = (_s 'WaitRec_WRITELOG') }
			'IO_COMPLETION'      = @{ Category = 'I/O';         Recommendation = (_s 'WaitRec_IO_COMPLETION') }
			'ASYNC_IO_COMPLETION'= @{ Category = 'I/O';         Recommendation = (_s 'WaitRec_ASYNC_IO_COMPLETION') }
			'LCK_M_X'            = @{ Category = 'Locking';     Recommendation = (_s 'WaitRec_LCK_M_X') }
			'LCK_M_S'            = @{ Category = 'Locking';     Recommendation = (_s 'WaitRec_LCK_M_S') }
			'LCK_M_U'            = @{ Category = 'Locking';     Recommendation = (_s 'WaitRec_LCK_M_U') }
			'LCK_M_IX'           = @{ Category = 'Locking';     Recommendation = (_s 'WaitRec_LCK_M_IX') }
			'LCK_M_IS'           = @{ Category = 'Locking';     Recommendation = (_s 'WaitRec_LCK_M_IS') }
			'CXPACKET'           = @{ Category = 'Parallelism'; Recommendation = (_s 'WaitRec_CXPACKET') }
			'CXCONSUMER'         = @{ Category = 'Parallelism'; Recommendation = (_s 'WaitRec_CXCONSUMER') }
			'RESOURCE_SEMAPHORE' = @{ Category = 'Memory';      Recommendation = (_s 'WaitRec_RESOURCE_SEMAPHORE') }
			'RESOURCE_SEMAPHORE_QUERY_COMPILE' = @{ Category = 'Memory'; Recommendation = (_s 'WaitRec_RES_SEM_COMPILE') }
			'CMEMTHREAD'         = @{ Category = 'Memory';      Recommendation = (_s 'WaitRec_CMEMTHREAD') }
			'SOS_SCHEDULER_YIELD'= @{ Category = 'CPU';         Recommendation = (_s 'WaitRec_SOS_SCHEDULER_YIELD') }
			'THREADPOOL'         = @{ Category = 'CPU';         Recommendation = (_s 'WaitRec_THREADPOOL') }
			'PAGELATCH_EX'       = @{ Category = 'Latch';       Recommendation = (_s 'WaitRec_PAGELATCH_EX') }
			'PAGELATCH_SH'       = @{ Category = 'Latch';       Recommendation = (_s 'WaitRec_PAGELATCH_SH') }
			'PAGELATCH_UP'       = @{ Category = 'Latch';       Recommendation = (_s 'WaitRec_PAGELATCH_UP') }
			'LATCH_EX'           = @{ Category = 'Latch';       Recommendation = (_s 'WaitRec_LATCH_EX') }
			'LATCH_SH'           = @{ Category = 'Latch';       Recommendation = (_s 'WaitRec_LATCH_SH') }
			'DBMIRROR_EVENTS_QUEUE' = @{ Category = 'Network';  Recommendation = (_s 'WaitRec_DBMIRROR_EVENTS_QUEUE') }
			'DBMIRRORING_CMD'    = @{ Category = 'Network';     Recommendation = (_s 'WaitRec_DBMIRRORING_CMD') }
			'ASYNC_NETWORK_IO'   = @{ Category = 'Network';     Recommendation = (_s 'WaitRec_ASYNC_NETWORK_IO') }
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
			if ($totalWaitMs -eq 0) { $totalWaitMs = 1 }

			$results = $filtered |
				Sort-Object wait_time_ms -Descending |
				Select-Object -First $TopN |
				ForEach-Object {
					$cat = if ($waitCategories.ContainsKey($_.wait_type)) { $waitCategories[$_.wait_type].Category } else { 'Other' }
					$rec = if ($waitCategories.ContainsKey($_.wait_type)) { $waitCategories[$_.wait_type].Recommendation } else { '' }
					$pct = [math]::Round($_.wait_time_ms * 100.0 / $totalWaitMs, 1)
					[PSCustomObject]@{
						WaitType             = $_.wait_type
						Category             = $cat
						WaitTimeSec          = [math]::Round($_.wait_time_ms / 1000.0, 1)
						WaitTimePct          = $pct
						WaitingTasksCount    = $_.waiting_tasks_count
						AvgWaitMs            = $_.avg_wait_ms
						MaxWaitMs            = $_.max_wait_time_ms
						SignalWaitMs         = $_.signal_wait_time_ms
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
