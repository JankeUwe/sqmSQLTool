@{
    # ── Common ─────────────────────────────────────────────────────────────────
    'Error_dbatoolsNotFound'        = 'dbatools module not found.'
    'Error_Generic'                 = 'Error in {0}: {1}'

    # ── Get-sqmWaitStatistics ──────────────────────────────────────────────────
    'WaitStats_Starting'            = 'Starting {0} on {1} (TopN={2}, IncludeIdle={3})'
    'WaitStats_NoData'              = 'No wait statistics returned.'
    'WaitStats_SnapshotCreated'     = 'Snapshot created: {0} wait types.'
    'WaitStats_Saved'               = 'Wait statistics saved: {0}'
    'WaitStats_Completed'           = '{0} completed: {1} wait types, total {2} sec.'

    'WaitRec_PAGEIOLATCH_SH'        = 'Disk I/O bottleneck - check storage performance and missing indexes.'
    'WaitRec_PAGEIOLATCH_EX'        = 'Disk I/O bottleneck on writes - check storage performance and index fragmentation.'
    'WaitRec_PAGEIOLATCH_UP'        = 'Disk I/O on updates - check storage performance.'
    'WaitRec_WRITELOG'              = 'Log I/O bottleneck - use faster storage for log files, avoid RAID5.'
    'WaitRec_IO_COMPLETION'         = 'General I/O delays - check storage performance.'
    'WaitRec_ASYNC_IO_COMPLETION'   = 'Async I/O delay - Backup/Restore/DBCC running on slow storage.'
    'WaitRec_LCK_M_X'              = 'Exclusive lock waits - review transaction design, index coverage and isolation level.'
    'WaitRec_LCK_M_S'              = 'Shared lock waits - consider enabling Read Committed Snapshot Isolation (RCSI).'
    'WaitRec_LCK_M_U'              = 'Update lock waits - optimize queries and improve index coverage.'
    'WaitRec_LCK_M_IX'             = 'Intent exclusive lock waits - analyze blocking chains and optimize indexes.'
    'WaitRec_LCK_M_IS'             = 'Intent shared lock waits - reduce transaction duration.'
    'WaitRec_CXPACKET'             = 'Parallelism waits - tune MAXDOP and Cost Threshold for Parallelism.'
    'WaitRec_CXCONSUMER'           = 'Parallel consumer waits - review MAXDOP setting.'
    'WaitRec_RESOURCE_SEMAPHORE'   = 'Memory grant waits - queries with excessive memory grants or index fragmentation.'
    'WaitRec_RES_SEM_COMPILE'      = 'Compilation memory shortage - too many concurrent compilations.'
    'WaitRec_CMEMTHREAD'           = 'Memory contention - possible NUMA imbalance or max server memory too low.'
    'WaitRec_SOS_SCHEDULER_YIELD'  = 'CPU pressure - optimize long-running queries or increase CPU resources.'
    'WaitRec_THREADPOOL'           = 'Worker thread shortage - check max worker threads or hardware capacity.'
    'WaitRec_PAGELATCH_EX'         = 'Page latch contention - often a tempdb bottleneck or hot pages (GUID-based indexes).'
    'WaitRec_PAGELATCH_SH'         = 'Shared page latch contention - increase tempdb files (8 recommended).'
    'WaitRec_PAGELATCH_UP'         = 'Update page latch - last page insert contention, avoid sequential keys.'
    'WaitRec_LATCH_EX'             = 'Internal latch contention - use Get-DbaLatch for detailed analysis.'
    'WaitRec_LATCH_SH'             = 'Internal shared latch - statistics and plan cache may be affected.'
    'WaitRec_DBMIRROR_EVENTS_QUEUE'= 'Database mirroring queue - check network latency between partners.'
    'WaitRec_DBMIRRORING_CMD'      = 'Mirroring synchronization - check network throughput.'
    'WaitRec_ASYNC_NETWORK_IO'     = 'Client processing data too slowly - reduce result set size, consider pagination.'

    # ── Get-sqmPerfCounters ────────────────────────────────────────────────────
    'PerfCounters_Starting'         = 'Starting {0} on {1}'
    'PerfCounters_Completed'        = '{0}: {1} counters read, {2} warnings.'
    'PerfCounters_Saved'            = 'Counter report saved: {0}'
    'PerfInterp_PLE_Critical'       = 'CRITICAL: PLE < 300 sec - memory shortage or cache churn'
    'PerfInterp_PLE_Warning'        = 'WARNING: PLE < 600 sec - monitor memory pressure'
    'PerfInterp_MemGrants'          = 'WARNING: Queries waiting for memory grants - index/query optimization required'
    'PerfInterp_Blocking_Critical'  = 'CRITICAL: Blocking active'
    'PerfInterp_Blocking_Warning'   = 'WARNING: Blocking active'
    'PerfInterp_Deadlocks'          = 'WARNING: Deadlocks detected - review Extended Events deadlock trace'
    'PerfInterp_LazyWrites'         = 'WARNING: High lazy write rate - check memory configuration'
    'PerfInterp_ReCompilations'     = 'WARNING: High re-compilation rate - check SET options and schema changes'

    # ── Invoke-sqmPatchAnalysis ────────────────────────────────────────────────
    'PatchAnalysis_Starting'        = 'Starting {0} for {1} instance(s)'
    'PatchAnalysis_InstanceResult'  = '[{0}] {1} {2} - {3} ({4} builds behind)'
    'PatchAnalysis_Saved'           = 'Patch analysis saved: {0}'
    'PatchAnalysis_Completed'       = '{0} completed: {1} instance(s), {2} critical, {3} to update.'
    'PatchAnalysis_InstanceError'   = '[{0}] Error: {1}'
    'PatchRec_UpToDate'             = 'Up to date - no patch required.'
    'PatchRec_Outdated'             = "{0} build(s) behind current release. Next update: {1}. Recommendation: upgrade to {2} ({3})."
    'PatchRec_UnknownVersion'       = 'No reference data available for major version {0}.'

    # ── Invoke-sqmFailover ─────────────────────────────────────────────────────
    'Failover_Starting'             = "Starting {0}: AG='{1}', Primary='{2}', Target='{3}'"
    'Failover_AgNotFound'           = "AG '{0}' not found or instance '{1}' is not a member."
    'Failover_NotPrimary'           = "Instance '{0}' is not Primary (current role: {1}). Failover must be initiated from the Primary."
    'Failover_NoSecondaries'        = "No secondary replicas found for AG '{0}'."
    'Failover_TargetNotFound'       = "Target replica '{0}' not found or not secondary."
    'Failover_NoSuitableTarget'     = 'No suitable target replica found (SYNCHRONIZED required).'
    'Failover_RedoQueueLimit'       = "Redo queue on '{0}' is {1} MB (limit: {2} MB). Failover aborted."
    'Failover_PreCheckPassed'       = "Pre-checks passed. Target: '{0}', SyncState: {1}, Redo-Queue: {2} MB"
    'Failover_WhatIf'               = "WhatIf: Failover would be executed to '{0}'."
    'Failover_Executing'            = "Executing failover to '{0}'..."
    'Failover_Waiting'              = 'Failover command executed. Waiting {0} sec...'
    'Failover_Success'              = "Failover successful. '{0}' is now Primary. SyncHealth: {1}"
    'Failover_PostCheckFailed'      = 'Failover executed, but post-check could not confirm the new Primary role. Please verify manually.'
    'Failover_PostCheckError'       = 'Failover executed, post-check failed: {0}'
    'Failover_Completed'            = '{0} completed in {1} sec.'

    # ── Get-sqmConnectionStats ────────────────────────────────────────────────
    'ConnStats_Starting'            = 'Starting {0} on {1} (GroupBy={2})'
    'ConnStats_Summary'             = '{0}: {1} connections ({2}% of max {3}), {4} active, {5} blocked.'
    'ConnStats_Saved'               = 'Connection report saved: {0}'

    # ── Get-sqmOrphanedFiles ──────────────────────────────────────────────────
    'Orphaned_RemoteWarning'        = 'Remote instance detected. Filesystem access is performed from this computer. Specify SearchPath as UNC path if paths are not directly accessible.'
    'Orphaned_Starting'             = 'Starting {0} on {1}'
    'Orphaned_DirectoriesCount'     = '{0} director(y/ies) to be scanned.'
    'Orphaned_DirNotReachable'      = 'Directory not reachable: {0}'
    'Orphaned_Completed'            = '{0}: {1} files scanned, {2} orphaned files found.'
    'Orphaned_NoneFound'            = 'No orphaned database files found.'

    # ── Invoke-sqmPerfBaseline ────────────────────────────────────────────────
    'Baseline_Starting'             = 'Starting {0} on {1}, Action={2}'
    'Baseline_NoFiles'              = 'No baseline files found in: {0}'
    'Baseline_Saved'                = 'Baseline saved: {0} ({1} waits, {2} counters)'
    'Baseline_NotEnoughFiles'       = 'Not enough baseline files for comparison. At least 2 baselines required.'
    'Baseline_Comparing'            = "Comparing: '{0}' vs '{1}'"

    # ── Invoke-sqmRestoreTest (evidence report) ───────────────────────────────
    'RestoreTest_Title'             = 'Restore Test Evidence'
    'RestoreTest_ReportHeadline'    = 'sqmSQLTool - Restore Test Evidence'
    'RestoreTest_Instance'          = 'Instance'
    'RestoreTest_Created'           = 'Created'

    'RestoreTest_SectionResult'     = 'Result'
    'RestoreTest_Status'            = 'Status'
    'RestoreTest_Successful'        = 'SUCCESSFUL'
    'RestoreTest_Failed'            = 'FAILED'
    'RestoreTest_SourceDatabase'    = 'Source database'
    'RestoreTest_TestDatabase'      = 'Test database'

    'RestoreTest_SectionMetrics'    = 'Metrics'
    'RestoreTest_DataVolume'        = 'Data volume (backup)'
    'RestoreTest_PhysicallyRead'    = 'of which physically read'
    'RestoreTest_Duration'          = 'Duration'
    'RestoreTest_Throughput'        = 'Throughput'
    'RestoreTest_Compressed'        = 'compressed'
    'RestoreTest_Uncompressed'      = 'uncompressed'
    'RestoreTest_SizeUnknown'       = 'unknown'
    'RestoreTest_NotDeterminable'   = 'not determinable'

    'RestoreTest_SectionDetails'    = 'Details'
    'RestoreTest_Start'             = 'Start'
    'RestoreTest_End'               = 'End'
    'RestoreTest_BackupFiles'       = 'Backup files'
    'RestoreTest_RestoredFiles'     = 'Restored files'
    'RestoreTest_CleanedUp'         = 'Cleaned up'
    'RestoreTest_CleanedUpYes'      = 'Yes - test database removed'
    'RestoreTest_CleanedUpNo'       = 'No - test database kept'
    'RestoreTest_Retention'         = 'Evidence retention'
    'RestoreTest_RetentionMonths'   = '{0} months'
    'RestoreTest_RetentionForever'  = 'unlimited'
    'RestoreTest_ResolvedVia'       = 'Backup resolved via'
    'RestoreTest_SourceHistory'     = 'msdb backup history'
    'RestoreTest_SourceScan'        = 'directory scan'
    'RestoreTest_SourceParameter'   = 'explicitly specified'
    'RestoreTest_BackupSource'      = 'Backup source'
    'RestoreTest_ThroughputNote'    = 'Throughput refers to the logical data volume (BackupSize) and is measured as wall-clock time across the entire restore.'
}
