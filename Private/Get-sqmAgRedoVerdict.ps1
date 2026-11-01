<#
.SYNOPSIS
    Classifies the redo bottleneck of one availability database from sampled metrics.

.DESCRIPTION
    Pure decision logic for Get-sqmAgRedoDiagnosis (no database access), kept separate so the
    thresholds can be unit-tested. The rules are evaluated in order, the first match wins:

        NoBacklog              redo queue below MinRedoQueueMB
        Suspended              data movement is suspended, redo does not run
        NoRedoTask             no redo thread found (wrong replica, missing VIEW SERVER STATE)
        BlockedByQuery         redo threads blocked / waiting on locks (readable secondary)
        SingleThreadedRedo     no parallel redo helpers, dispatcher thread CPU-bound
        SchedulerPressure      redo threads runnable but not scheduled
        PageReadIO             redo threads waiting on data page reads
        LogReadIO              redo threads waiting on reading the log from disk
        TransactionDependency  helpers wait on commit ordering / drain / flow control
        DispatchBound          dispatcher at 100% of one core, helpers idle
        WorkerSkew             one helper saturated, the others mostly idle
        ApplyCpuBound          all redo threads busy on CPU
        RedoIdle               redo threads idle although a backlog exists
        Inconclusive           none of the above

    The result is a heuristic from point samples and CPU deltas, not proof. Evidence lists the
    numbers behind the verdict.

.PARAMETER Metrics
    PSCustomObject with the fields listed in the code below (shares are 0..1, CPU is percent of
    one core).

.NOTES
    Private helper - not exported.
#>
function Get-sqmAgRedoVerdict
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$Metrics,
		[Parameter(Mandatory = $false)]
		[int]$MinRedoQueueMB = 100
	)

	$m = $Metrics
	$evidence = "RedoQueue={0} MB, Trend={1} MB/min, DispatcherCPU={2}%, Helpers={3} (avg CPU {4}%, max {5}%), " -f `
		$m.RedoQueueMB, $m.TrendMBPerMin, $m.DispatcherCpuPct, $m.HelperCount, $m.AvgHelperCpuPct, $m.MaxHelperCpuPct
	$evidence += "Runnable={0:P0}, Locks={1:P0}, PageIO={2:P0}, LogRead={3:P0}, Dependency={4:P0}, Idle={5:P0}, AvgRunnablePerScheduler={6}" -f `
		$m.RunnableShare, $m.BlockedShare, $m.PageIoWaitShare, $m.LogReadWaitShare, $m.DependencyWaitShare, $m.IdleShare, $m.AvgRunnableTasks

	$verdict = $null
	$hint = $null

	if ([double]$m.RedoQueueMB -lt $MinRedoQueueMB)
	{
		$verdict = 'NoBacklog'
		$hint = 'Redo queue is below the threshold, nothing to diagnose.'
	}
	elseif ($m.IsSuspended)
	{
		$verdict = 'Suspended'
		$hint = "Data movement is suspended ($($m.SuspendReason)). Resume it first: ALTER DATABASE [db] SET HADR RESUME."
	}
	elseif (-not $m.DispatcherFound)
	{
		$verdict = 'NoRedoTask'
		$hint = 'No DB STARTUP redo thread found. Run on the secondary replica with VIEW SERVER STATE.'
	}
	elseif ($m.BlockedShare -ge 0.2)
	{
		$verdict = 'BlockedByQuery'
		$hint = 'Redo is blocked by locks, typically long queries on the readable secondary. Find the blocker (Get-sqmBlockingReport on the secondary), stop or reroute the query.'
	}
	elseif ($m.HelperCount -eq 0 -and $m.DispatcherCpuPct -ge 70)
	{
		$verdict = 'SingleThreadedRedo'
		$hint = 'Parallel redo is not active and the single redo thread is CPU-bound. Check core count, trace flag 3459, the parallel redo worker limit and edition/version.'
	}
	elseif ($m.RunnableShare -ge 0.25 -or $m.AvgRunnableTasks -ge 2)
	{
		$verdict = 'SchedulerPressure'
		$hint = 'Redo threads are ready to run but wait for CPU. Check CPU contention on the VM (steal time), affinity mask, resource governor, THREADPOOL waits and competing workload on the secondary.'
	}
	elseif ($m.PageIoWaitShare -ge 0.3)
	{
		$verdict = 'PageReadIO'
		$hint = 'Redo waits for data page reads (cold buffer pool). Average latency can look fine while IOPS or queue depth is capped: check IOPS/throughput limits and Get-sqmFileLatencyReport -SampleSeconds 60 on the data files.'
	}
	elseif ($m.LogReadWaitShare -ge 0.3)
	{
		$verdict = 'LogReadIO'
		$hint = 'Redo reads the log from disk instead of the log cache (large backlog). Check sequential read throughput of the secondary log file.'
	}
	elseif ($m.DependencyWaitShare -ge 0.3)
	{
		$verdict = 'TransactionDependency'
		$hint = 'Parallel redo workers wait on commit ordering or drain each other. Look for what generated the log on the primary: very large transactions, index rebuilds, DDL, allocation-heavy operations.'
	}
	elseif ($m.DispatcherCpuPct -ge 70 -and $m.AvgHelperCpuPct -lt 30)
	{
		$verdict = 'DispatchBound'
		$hint = 'The thread that parses log blocks and hands records to the workers is the limit while the workers are idle. Check log block size (many small commits on the primary) and per-core CPU speed of the secondary.'
	}
	elseif ($m.HelperCount -gt 0 -and $m.MaxHelperCpuPct -ge 80 -and $m.AvgHelperCpuPct -le 40)
	{
		$verdict = 'WorkerSkew'
		$hint = 'One redo worker is saturated while the others idle: the log is concentrated on few pages/objects. Identify the hot object on the primary (large single-table load or index operation).'
	}
	elseif ($m.AvgHelperCpuPct -ge 70 -or $m.DispatcherCpuPct -ge 70)
	{
		$verdict = 'ApplyCpuBound'
		$hint = 'All redo threads are busy on CPU: apply throughput is limited by the secondary CPU. Compare with the primary log generation rate; more or faster cores, less workload on the secondary.'
	}
	elseif ($m.IdleShare -ge 0.6 -and $m.DispatcherCpuPct -lt 20)
	{
		$verdict = 'RedoIdle'
		$hint = 'Redo threads are mostly idle although a backlog exists. Look upstream: log read throughput, flow control, and whether log blocks are hardened but not handed to redo.'
	}
	else
	{
		$verdict = 'Inconclusive'
		$hint = 'No single cause stands out. Repeat with a longer -SampleSeconds, or sample while the redo rate is low.'
	}

	[PSCustomObject]@{
		Verdict        = $verdict
		Evidence       = $evidence
		Recommendation = $hint
	}
}
