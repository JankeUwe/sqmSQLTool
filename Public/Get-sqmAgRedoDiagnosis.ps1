<#
.SYNOPSIS
    Finds out why an Always On secondary does not catch up: samples the redo threads for a
    minute and names the likely bottleneck per database.

.DESCRIPTION
    Use it on a secondary replica with a large redo queue while the send queue is small (log
    arrives, but is applied too slowly). The function samples for -SampleSeconds:
      - redo queue, redo rate and send queue per database (sys.dm_hadr_database_replica_states)
      - every redo thread (sys.dm_exec_requests: DB STARTUP and PARALLEL REDO tasks): status,
        wait type, blocker, CPU time
      - runnable tasks per scheduler (sys.dm_os_schedulers)
      - instance wide wait statistics of the interval (redo, I/O and scheduler waits)
    and condenses them into one verdict per database:

      BlockedByQuery         redo blocked by locks (queries on the readable secondary)
      SingleThreadedRedo     parallel redo not active, the one redo thread is CPU-bound
      SchedulerPressure      redo threads runnable but not getting CPU
      PageReadIO             redo waits for data page reads
      LogReadIO              redo waits for reading the log from disk
      TransactionDependency  workers wait for commit ordering (huge transactions, DDL, rebuilds)
      DispatchBound          the log-parsing thread is the limit, workers idle
      WorkerSkew             one redo worker saturated, the others idle
      ApplyCpuBound          all redo threads busy on CPU
      RedoIdle               redo idle despite a backlog, look upstream
      Suspended / NoRedoTask / NoBacklog / Inconclusive

    The verdict is a heuristic from point samples and CPU deltas. The Evidence column shows the
    numbers; use them to confirm it. One collection run answers the question, so it suits
    customer systems where every round trip is expensive.

.PARAMETER SqlInstance
    The secondary replica (default: current computer name). Run it per replica, not against the
    listener.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER Database
    Only these databases (wildcards allowed). Default: all availability databases on the replica.

.PARAMETER SampleSeconds
    Length of the measurement. Default 60, range 10-3600. Use longer for fluctuating redo rates.

.PARAMETER IntervalSeconds
    Time between two samples. Default 2, range 1-60.

.PARAMETER MinRedoQueueMB
    Databases with a smaller redo queue get the verdict NoBacklog. Default: 100.

.PARAMETER Quiet
    No progress bar.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmAgRedoDiagnosis -SqlInstance "SQL02"

.EXAMPLE
    # Longer sample, only the worst database, with the numbers behind the verdict
    Get-sqmAgRedoDiagnosis -SqlInstance "SQL02" -SampleSeconds 300 |
        Select-Object -First 1 | Format-List DatabaseName, RedoQueueMB, TrendMBPerMin, Verdict, Evidence, Recommendation

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE on the secondary replica.
    Combine with Get-sqmAlwaysOnQueueStatus (queues), Get-sqmFileLatencyReport -SampleSeconds
    (storage) and Get-sqmBlockingReport (blocking on a readable secondary).
    Get-sqmWaitStatistics hides the PARALLEL_REDO waits as benign, this function reads them.
#>
function Get-sqmAgRedoDiagnosis
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
		[ValidateRange(10, 3600)]
		[int]$SampleSeconds = 60,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 60)]
		[int]$IntervalSeconds = 2,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 100000000)]
		[int]$MinRedoQueueMB = 100,
		[Parameter(Mandatory = $false)]
		[switch]$Quiet,
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

		$replicaQuery = @"
SET NOCOUNT ON;
SELECT
    DB_NAME(drs.database_id)                 AS DatabaseName,
    CAST(drs.database_id AS int)             AS DatabaseId,
    ag.name                                  AS AgName,
    ars.role_desc                            AS Role,
    CAST(ISNULL(drs.redo_queue_size, 0) AS bigint)     AS RedoQueueKB,
    CAST(ISNULL(drs.redo_rate, 0) AS bigint)           AS RedoRateKBs,
    CAST(ISNULL(drs.log_send_queue_size, 0) AS bigint) AS SendQueueKB,
    CAST(ISNULL(drs.is_suspended, 0) AS int)           AS IsSuspended,
    ISNULL(drs.suspend_reason_desc, N'')               AS SuspendReason
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = drs.replica_id AND ars.group_id = drs.group_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE drs.is_local = 1;
"@

		$taskQuery = @"
SET NOCOUNT ON;
SELECT
    CAST(r.session_id AS int)                AS SessionId,
    CAST(r.database_id AS int)               AS DatabaseId,
    r.command                                AS Command,
    r.status                                 AS Status,
    ISNULL(r.wait_type, N'')                 AS WaitType,
    CAST(ISNULL(r.blocking_session_id, 0) AS int) AS BlockingSessionId,
    CAST(r.cpu_time AS bigint)               AS CpuMs
FROM sys.dm_exec_requests r
WHERE r.command = N'DB STARTUP' OR r.command LIKE N'PARALLEL REDO%';
"@

		$schedQuery = @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(AVG(CAST(runnable_tasks_count AS float)), 0) AS float) AS AvgRunnable
FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';
"@

		$waitQuery = @"
SET NOCOUNT ON;
SELECT wait_type AS WaitType, CAST(wait_time_ms AS bigint) AS WaitTimeMs
FROM sys.dm_os_wait_stats
WHERE wait_type LIKE N'PARALLEL_REDO%' OR wait_type LIKE N'PAGEIOLATCH%'
   OR wait_type IN (N'REDO_THREAD_PENDING_WORK', N'SOS_SCHEDULER_YIELD', N'HADR_RECOVERY_WAIT_FOR_UNDO', N'IO_COMPLETION');
"@

		$idleWaits = @('PARALLEL_REDO_WORKER_WAIT_WORK', 'REDO_THREAD_PENDING_WORK')
		$dependencyWaits = @('PARALLEL_REDO_TRAN_TURN', 'PARALLEL_REDO_DRAIN_WORKER', 'PARALLEL_REDO_TRAN_LIST',
			'PARALLEL_REDO_WORKER_SYNC', 'PARALLEL_REDO_FLOW_CONTROL')

		Invoke-sqmLogging -Message ("Starte " + $functionName + " auf " + $SqlInstance) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance; SqlCredential = $SqlCredential; Database = 'master' }

			$samples = [System.Collections.Generic.List[PSCustomObject]]::new()
			$sw = [System.Diagnostics.Stopwatch]::StartNew()
			$waitFirst = @(Invoke-DbaQuery @connParams -Query $waitQuery -EnableException)

			while ($true)
			{
				$samples.Add([PSCustomObject]@{
					T       = $sw.ElapsedMilliseconds
					Replica = @(Invoke-DbaQuery @connParams -Query $replicaQuery -EnableException)
					Tasks   = @(Invoke-DbaQuery @connParams -Query $taskQuery -EnableException)
					Sched   = [double](@(Invoke-DbaQuery @connParams -Query $schedQuery -EnableException)[0].AvgRunnable)
				})

				if ($sw.ElapsedMilliseconds -ge ($SampleSeconds * 1000)) { break }
				if (-not $Quiet)
				{
					Write-Progress -Activity "Redo-Analyse $SqlInstance" -Status "Probe $($samples.Count)" `
						-PercentComplete ([math]::Min(99, [int](100 * $sw.ElapsedMilliseconds / ($SampleSeconds * 1000))))
				}
				Start-Sleep -Seconds $IntervalSeconds
			}
			if (-not $Quiet) { Write-Progress -Activity "Redo-Analyse $SqlInstance" -Completed }

			$waitLast = @(Invoke-DbaQuery @connParams -Query $waitQuery -EnableException)
			$firstWait = @{}
			foreach ($w in $waitFirst) { $firstWait[[string]$w.WaitType] = [long]$w.WaitTimeMs }
			$waitDelta = foreach ($w in $waitLast)
			{
				$prev = 0
				if ($firstWait.ContainsKey([string]$w.WaitType)) { $prev = $firstWait[[string]$w.WaitType] }
				[PSCustomObject]@{ WaitType = [string]$w.WaitType; DeltaMs = [long]$w.WaitTimeMs - $prev }
			}
			$topWaits = (@($waitDelta | Where-Object { $_.DeltaMs -gt 0 } | Sort-Object DeltaMs -Descending | Select-Object -First 5 |
					ForEach-Object { "$($_.WaitType)=$($_.DeltaMs)ms" }) -join '; ')

			# CPU in percent of one core for one redo session between its first and last sample
			$cpuPct = {
				param ($rows)
				$ordered = @($rows | Sort-Object T)
				if ($ordered.Count -lt 2) { return $null }
				$spanMs = $ordered[-1].T - $ordered[0].T
				$delta = [long]$ordered[-1].CpuMs - [long]$ordered[0].CpuMs
				if ($spanMs -le 0 -or $delta -lt 0) { return $null }
				[math]::Round(100.0 * $delta / $spanMs, 1)
			}

			$lastReplica = @($samples[$samples.Count - 1].Replica | Where-Object { $_.Role -eq 'SECONDARY' })
			if ($Database.Count -gt 0)
			{
				$lastReplica = @($lastReplica | Where-Object { $name = $_.DatabaseName; @($Database | Where-Object { $name -like $_ }).Count -gt 0 })
			}
			if ($lastReplica.Count -eq 0)
			{
				Write-Warning "[$SqlInstance] Keine Datenbank als Secondary gefunden. Die Funktion muss auf dem sekundaeren Replikat laufen."
				return
			}

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			foreach ($db in $lastReplica)
			{
				$dbId = [int]$db.DatabaseId

				$qSeries = foreach ($s in $samples)
				{
					$row = @($s.Replica | Where-Object { [int]$_.DatabaseId -eq $dbId })[0]
					if ($row) { [PSCustomObject]@{ T = $s.T; QueueMB = [double]$row.RedoQueueKB / 1024; RateKBs = [double]$row.RedoRateKBs } }
				}
				$qSeries = @($qSeries)
				$qFirst = $qSeries[0]
				$qLast = $qSeries[$qSeries.Count - 1]
				$minutes = ($qLast.T - $qFirst.T) / 60000.0
				$trend = 0.0
				if ($minutes -gt 0) { $trend = [math]::Round(($qLast.QueueMB - $qFirst.QueueMB) / $minutes, 1) }
				$eta = $null
				if ($trend -lt 0) { $eta = [math]::Round($qLast.QueueMB / (-$trend), 0) }
				$rates = @($qSeries | ForEach-Object { $_.RateKBs })

				$taskRows = foreach ($s in $samples)
				{
					foreach ($t in @($s.Tasks | Where-Object { [int]$_.DatabaseId -eq $dbId }))
					{
						[PSCustomObject]@{
							T = $s.T; SessionId = [int]$t.SessionId; Command = [string]$t.Command; Status = [string]$t.Status
							WaitType = [string]$t.WaitType; Blocking = [int]$t.BlockingSessionId; CpuMs = [long]$t.CpuMs
						}
					}
				}
				$taskRows = @($taskRows)

				$dispatcherRows = @($taskRows | Where-Object { $_.Command -eq 'DB STARTUP' })
				$helperRows = @($taskRows | Where-Object { $_.Command -like 'PARALLEL REDO*' })

				$dispatcherPct = 0.0
				foreach ($g in ($dispatcherRows | Group-Object SessionId))
				{
					$p = & $cpuPct $g.Group
					if ($null -ne $p -and $p -gt $dispatcherPct) { $dispatcherPct = $p }
				}
				$helperGroups = @($helperRows | Group-Object SessionId)
				$helperPcts = @(foreach ($g in $helperGroups) { $p = & $cpuPct $g.Group; if ($null -ne $p) { $p } })
				$avgHelper = 0.0
				$maxHelper = 0.0
				if ($helperPcts.Count -gt 0)
				{
					$avgHelper = [math]::Round(($helperPcts | Measure-Object -Average).Average, 1)
					$maxHelper = [math]::Round(($helperPcts | Measure-Object -Maximum).Maximum, 1)
				}

				$total = $taskRows.Count
				$idle = @($taskRows | Where-Object { $_.WaitType -in $idleWaits }).Count
				$busy = @($taskRows | Where-Object { $_.WaitType -notin $idleWaits })
				$share = {
					param ($rows)
					if ($busy.Count -eq 0) { return 0.0 }
					[math]::Round(@($rows).Count / $busy.Count, 3)
				}
				$idleShare = 0.0
				if ($total -gt 0) { $idleShare = [math]::Round($idle / $total, 3) }

				$metrics = [PSCustomObject]@{
					RedoQueueMB         = [math]::Round($qLast.QueueMB, 1)
					TrendMBPerMin       = $trend
					IsSuspended         = ([int]$db.IsSuspended -eq 1)
					SuspendReason       = [string]$db.SuspendReason
					DispatcherFound     = ($dispatcherRows.Count -gt 0)
					DispatcherCpuPct    = $dispatcherPct
					HelperCount         = $helperGroups.Count
					AvgHelperCpuPct     = $avgHelper
					MaxHelperCpuPct     = $maxHelper
					RunnableShare       = (& $share -rows @($busy | Where-Object { $_.Status -eq 'runnable' }))
					BlockedShare        = (& $share -rows @($busy | Where-Object { $_.Blocking -gt 0 -or $_.WaitType -like 'LCK_M_*' }))
					PageIoWaitShare     = (& $share -rows @($busy | Where-Object { $_.WaitType -like 'PAGEIOLATCH*' -or $_.WaitType -in @('IO_COMPLETION', 'ASYNC_IO_COMPLETION') }))
					LogReadWaitShare    = (& $share -rows @($busy | Where-Object { $_.WaitType -eq 'PARALLEL_REDO_LOG_CACHE' }))
					DependencyWaitShare = (& $share -rows @($busy | Where-Object { $_.WaitType -in $dependencyWaits }))
					IdleShare           = $idleShare
					AvgRunnableTasks    = [math]::Round((($samples | Measure-Object Sched -Average).Average), 2)
				}
				$verdict = Get-sqmAgRedoVerdict -Metrics $metrics -MinRedoQueueMB $MinRedoQueueMB

				$results.Add([PSCustomObject]@{
					SqlInstance         = $SqlInstance
					AgName              = [string]$db.AgName
					DatabaseName        = [string]$db.DatabaseName
					RedoQueueMB         = $metrics.RedoQueueMB
					RedoQueueStartMB    = [math]::Round($qFirst.QueueMB, 1)
					TrendMBPerMin       = $trend
					DrainEtaMinutes     = $eta
					SendQueueMB         = [math]::Round([double]$db.SendQueueKB / 1024, 1)
					AvgRedoRateKBs      = [math]::Round(($rates | Measure-Object -Average).Average, 0)
					MinRedoRateKBs      = ($rates | Measure-Object -Minimum).Minimum
					MaxRedoRateKBs      = ($rates | Measure-Object -Maximum).Maximum
					DispatcherCpuPct    = $dispatcherPct
					HelperCount         = $metrics.HelperCount
					AvgHelperCpuPct     = $avgHelper
					MaxHelperCpuPct     = $maxHelper
					Verdict             = $verdict.Verdict
					Evidence            = $verdict.Evidence
					Recommendation      = $verdict.Recommendation
					InstanceTopWaits    = $topWaits
					Samples             = $samples.Count
					SampleSeconds       = [int][math]::Round($sw.ElapsedMilliseconds / 1000.0)
				})
			}

			$results | Sort-Object RedoQueueMB -Descending
		}
		catch
		{
			if (-not $Quiet) { Write-Progress -Activity "Redo-Analyse $SqlInstance" -Completed }
			$errMsg = "[$SqlInstance] Fehler bei der Redo-Analyse: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
	}
}
