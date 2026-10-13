<#
.SYNOPSIS
    Runs all sqmSQLTool health and performance checks against one instance and writes one
    consolidated HTML report with a prioritized findings list, plus every detail report.

.DESCRIPTION
    One call, one folder: HealthReport_<Instance>_<Timestamp>\index.html is the overview, the
    detail reports of the individual functions land in its Details subfolder and are linked
    from the overview. The idea follows PSBlitz (Brent Ozar's First Responder Kit as one
    report), built from sqmSQLTool's own functions; nothing is installed on the instance.

    Sections (-Section, default all):
      Instance          Version, edition, uptime, CPU, memory + best-practice checks
                        (Get-sqmSQLInstanceCheck)
      Waits             Top waits (Get-sqmWaitStatistics), cumulative or during -SampleSeconds
      Activity          Running sessions, blocking (Get-sqmWhoIsActive, one snapshot)
      OpenTransactions  Transactions open longer than -OpenTranMinutes, with log usage
      TempDb            Configuration (Get-sqmTempDbRecommendation) + top tempdb consumers
      Databases         CHECKDB, backups, VLFs, auto growth (Get-sqmDatabaseHealth)
      Backups           Backup control against thresholds, honours sqm_BackupExclude, flags
                        databases created after the last backup run (Test-sqmBackupStatus)
      PlanCache         Most expensive statements (Get-sqmPlanCacheReport)
      Indexes           Unused/duplicate/overlapping indexes, heaps (Get-sqmIndexUsageReport)
                        + missing indexes (Get-sqmMissingIndexes)
      FileLatency       Latency per database file (Get-sqmFileLatencyReport)
      Deadlocks         Deadlocks of the last -DeadlockDays days (Get-sqmDeadlockReport)
      Security          Sysadmin accounts (Get-sqmSysadminAccounts)
      Disk              Free space and growth forecast (Get-sqmDiskSpaceReport)

    Every section runs on its own: if one fails (missing permission, old version), the
    report says so in that section and the others still run.

    Findings are rated Critical, Warning or Info and listed at the top of the report,
    most severe first. The ratings come from the individual functions; this function only
    collects them.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for all connections.

.PARAMETER Section
    Sections to run. Default: all. -SkipSection removes single ones.

.PARAMETER SkipSection
    Sections to leave out, e.g. Indexes on an instance with thousands of databases.

.PARAMETER Database
    Restricts PlanCache and Indexes to these databases (wildcards allowed).

.PARAMETER SampleSeconds
    0 (default): waits and file latency cumulative since start. 1-600: both are measured
    live in the same time window (waits snapshot before/after, latency difference).

.PARAMETER InDepth
    PlanCache with all seven metrics instead of CPU/Duration/Reads, and -SampleSeconds 30
    if no -SampleSeconds is given.

.PARAMETER ExportPlans
    Saves the plan cache statement plans as .sqlplan to Details\Plans.

.PARAMETER DeadlockDays
    Days of deadlock history. Default: 15.

.PARAMETER OpenTranMinutes
    Transactions open at least this long are listed. Default: 1. Older than 10 minutes is a Warning.

.PARAMETER Top
    Rows per section table in the overview and statements per plan cache metric. Default: 10.

.PARAMETER OutputPath
    Parent directory. Default: <OutputPath config>\HealthReport.

.PARAMETER Zip
    Additionally packs the report folder into a .zip next to it.

.PARAMETER NoOpen
    Do not open the report after creation.

.PARAMETER EnableException
    Throw if the instance cannot be reached at all. Section errors never throw, they are
    reported in the result and the report.

.EXAMPLE
    Invoke-sqmHealthReport -SqlInstance "SQL01"

.EXAMPLE
    # In-depth, with a 30 s live window, plans exported, zipped for the ticket
    Invoke-sqmHealthReport -SqlInstance "SQL01" -InDepth -ExportPlans -Zip

.EXAMPLE
    # Quick look without the expensive parts
    Invoke-sqmHealthReport -SqlInstance "SQL01" -SkipSection Indexes, Deadlocks, PlanCache

.EXAMPLE
    # Only what matters for one application database
    Invoke-sqmHealthReport -SqlInstance "SQL01" -Database "Shop" -Section Instance, Waits, PlanCache, Indexes

.NOTES
    Requires: dbatools and the sqmSQLTool functions listed above.
    Needs VIEW SERVER STATE; Databases/Security/Disk need the rights of the respective functions
    (sysadmin covers everything).
    Runtime: a few seconds to minutes, mostly Indexes on instances with many databases and
    Deadlocks with large system_health files, plus -SampleSeconds.
#>
function Invoke-sqmHealthReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Instance', 'Waits', 'Activity', 'OpenTransactions', 'TempDb', 'Databases', 'Backups', 'PlanCache', 'Indexes', 'FileLatency', 'Deadlocks', 'Security', 'Disk')]
		[string[]]$Section = @('Instance', 'Waits', 'Activity', 'OpenTransactions', 'TempDb', 'Databases', 'Backups', 'PlanCache', 'Indexes', 'FileLatency', 'Deadlocks', 'Security', 'Disk'),
		[Parameter(Mandatory = $false)]
		[ValidateSet('Instance', 'Waits', 'Activity', 'OpenTransactions', 'TempDb', 'Databases', 'Backups', 'PlanCache', 'Indexes', 'FileLatency', 'Deadlocks', 'Security', 'Disk')]
		[string[]]$SkipSection = @(),
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 600)]
		[int]$SampleSeconds = 0,
		[Parameter(Mandatory = $false)]
		[switch]$InDepth,
		[Parameter(Mandatory = $false)]
		[switch]$ExportPlans,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 365)]
		[int]$DeadlockDays = 15,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$OpenTranMinutes = 1,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$Top = 10,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'HealthReport'),
		[Parameter(Mandatory = $false)]
		[switch]$Zip,
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

		if ($InDepth -and -not $PSBoundParameters.ContainsKey('SampleSeconds')) { $SampleSeconds = 30 }

		Invoke-sqmLogging -Message ("Starte " + $functionName + " auf " + $SqlInstance) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		$runStart = Get-Date
		$order = @('Instance', 'Waits', 'Activity', 'OpenTransactions', 'TempDb', 'Databases', 'Backups', 'PlanCache', 'Indexes', 'FileLatency', 'Deadlocks', 'Security', 'Disk')
		$todo = @($order | Where-Object { $_ -in $Section -and $_ -notin $SkipSection })

		$conn = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $conn['SqlCredential'] = $SqlCredential }

		# -------------------------------------------------------------------
		# 0. Erreichbarkeit + Eckdaten. Scheitert das, ist der ganze Lauf sinnlos.
		# -------------------------------------------------------------------
		try
		{
			$info = Invoke-DbaQuery @conn -Database master -EnableException -Query @"
SELECT
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(256))     AS ServerName,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))  AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64))    AS ProductLevel,
    CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)) AS ProductUpdateLevel,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(256))        AS Edition,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int)            AS IsHadrEnabled,
    CAST(SERVERPROPERTY('IsClustered') AS int)              AS IsClustered,
    si.sqlserver_start_time                                 AS StartTime,
    si.cpu_count                                            AS CpuCount,
    CAST(si.physical_memory_kb / 1024 AS bigint)            AS PhysicalMemoryMB,
    CAST(si.committed_kb / 1024 AS bigint)                  AS CommittedMB,
    CAST(si.committed_target_kb / 1024 AS bigint)           AS TargetMB,
    (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4) AS UserDatabases
FROM sys.dm_os_sys_info si
"@
		}
		catch
		{
			$errMsg = "Instanz '$SqlInstance' nicht erreichbar: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw $errMsg }
			Write-Error $errMsg
			return
		}

		$safeInst = $SqlInstance -replace '[\\/:*?"<>|,]', '_'
		$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
		$folder = Join-Path $OutputPath "HealthReport_${safeInst}_$stamp"
		$details = Join-Path $folder 'Details'
		New-Item -ItemType Directory -Path $details -Force | Out-Null

		$uptimeDays = [math]::Round(((Get-Date) - [datetime]$info.StartTime).TotalDays, 1)
		$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
		$sections = [System.Collections.Generic.List[PSCustomObject]]::new()
		$sectionHtml = @{}

		$enc = { param ($s) ([string]$s) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
		$addFinding = {
			param ([string]$Severity, [string]$Sec, [string]$Text, [string]$Detail)
			$findings.Add([PSCustomObject]@{ Severity = $Severity; Section = $Sec; Finding = $Text; Detail = $Detail })
		}
		# Kompakte Tabelle: ausgewaehlte Spalten, hoechstens $Top Zeilen
		$table = {
			param ($Rows, [string[]]$Columns, [int]$Max)
			$r = @($Rows)
			if ($r.Count -eq 0) { return "<p class='ok'>Keine Eintraege.</p>" }
			$sb = New-Object System.Text.StringBuilder
			[void]$sb.Append('<table><tr>')
			foreach ($c in $Columns) { [void]$sb.Append("<th>$(& $enc $c)</th>") }
			[void]$sb.Append('</tr>')
			foreach ($row in ($r | Select-Object -First $Max))
			{
				[void]$sb.Append('<tr>')
				foreach ($c in $Columns)
				{
					$v = $row.$c
					if ($v -is [DBNull]) { $v = '' }
					if ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd HH:mm') }
					$s = [string]$v
					if ($s.Length -gt 300) { $s = $s.Substring(0, 300) + ' ...' }
					$cls = switch -Regex ($s) { '^(Critical|Failed|CRITICAL)$' { " class='crit'" } '^(Warning|WARNING)$' { " class='warn'" } '^(OK|Passed)$' { " class='ok'" } default { '' } }
					[void]$sb.Append("<td$cls>$(& $enc $s)</td>")
				}
				[void]$sb.Append('</tr>')
			}
			[void]$sb.Append('</table>')
			if ($r.Count -gt $Max) { [void]$sb.Append("<p>... $($r.Count - $Max) weitere Zeile(n) im Detailbericht.</p>") }
			return $sb.ToString()
		}
		$mapSeverity = {
			param ([string]$s)
			switch -Regex ($s) { '^(Critical|Failed|Error)$' { 'Critical' } '^Warning$' { 'Warning' } default { $null } }
		}

		# Wait-Snapshot vor dem Messfenster (wird von FileLatency mit -SampleSeconds aufgespannt)
		$waitBefore = $null
		if ($SampleSeconds -gt 0 -and $todo -contains 'Waits')
		{
			try { $waitBefore = Get-sqmWaitStatistics @conn -SaveSnapshot -NoOpen -EnableException 3>$null 6>$null } catch { $waitBefore = $null }
		}

		# Mit Messfenster: FileLatency (schlaeft -SampleSeconds) direkt vor Waits ausfuehren, damit
		# beide dasselbe Zeitfenster messen. Die Anzeige folgt trotzdem $order.
		$runOrder = $todo
		if ($SampleSeconds -gt 0 -and $todo -contains 'FileLatency' -and $todo -contains 'Waits')
		{
			$rest = @($todo | Where-Object { $_ -notin 'Instance', 'FileLatency', 'Waits' })
			$runOrder = @($todo | Where-Object { $_ -eq 'Instance' }) + @('FileLatency', 'Waits') + $rest
		}

		foreach ($sec in $runOrder)
		{
			$sw = [Diagnostics.Stopwatch]::StartNew()
			$filesBefore = @(Get-ChildItem -Path $details -Recurse -File -Filter '*.html' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
			$status = 'OK'
			$err = $null
			$html = ''
			$countBefore = $findings.Count
			try
			{
				switch ($sec)
				{
					'Instance'
					{
						$ver = "$($info.ProductVersion) $($info.ProductLevel) $(if ($info.ProductUpdateLevel -isnot [DBNull]) { $info.ProductUpdateLevel })".Trim()
						$facts = [PSCustomObject]@{
							Server = $info.ServerName; Version = $ver; Edition = $info.Edition; Uptime = "$uptimeDays Tage (seit $(([datetime]$info.StartTime).ToString('yyyy-MM-dd HH:mm')))"
							CPUs = $info.CpuCount; 'RAM MB' = $info.PhysicalMemoryMB; 'SQL committed MB' = $info.CommittedMB; 'Target MB' = $info.TargetMB
							AlwaysOn = [bool]$info.IsHadrEnabled; Cluster = [bool]$info.IsClustered; 'User DBs' = $info.UserDatabases
						}
						$html = & $table @($facts) @('Server', 'Version', 'Edition', 'Uptime', 'CPUs', 'RAM MB', 'SQL committed MB', 'AlwaysOn', 'Cluster', 'User DBs') 1
						$checks = @(Get-sqmSQLInstanceCheck @conn -EnableException 3>$null 6>$null)
						foreach ($c in $checks)
						{
							$sv = & $mapSeverity $c.Status
							if ($sv) { & $addFinding $sv 'Instance' "$($c.Check): $($c.CurrentValue)" "$($c.Message) Empfohlen: $($c.Recommended)" }
						}
						$html += & $table $checks @('Check', 'CurrentValue', 'Recommended', 'Status', 'Message') 50
						if ($uptimeDays -lt 7) { & $addFinding 'Info' 'Instance' "Laufzeit nur $uptimeDays Tage" 'Kumulierte DMV-Werte (Waits, Index-Nutzung, Plan-Cache) decken nur diese Zeit ab.' }
					}
					'Waits'
					{
						$wp = @{ TopN = $Top; OutputPath = $details; NoOpen = $true }
						if ($waitBefore)
						{
							# Ohne FileLatency spannt niemand das Fenster auf: selbst warten
							if ($todo -notcontains 'FileLatency') { Start-Sleep -Seconds $SampleSeconds }
							$wp['SnapshotBefore'] = $waitBefore
						}
						$waits = @(Get-sqmWaitStatistics @conn @wp -EnableException 3>$null 6>$null)
						$scope = if ($waitBefore) { "Messfenster $SampleSeconds s" } else { 'kumuliert seit Start' }
						$html = "<p>Top $Top Waits, $scope.</p>" + (& $table $waits @('WaitType', 'Category', 'WaitTimePct', 'AvgWaitMs', 'SignalWaitPct', 'Recommendation') $Top)
						foreach ($w in ($waits | Where-Object { [double]$_.WaitTimePct -ge 25 -and $_.Recommendation }))
						{
							& $addFinding 'Warning' 'Waits' "$($w.WaitType): $($w.WaitTimePct) % der Wartezeit ($($w.Category))" $w.Recommendation
						}
					}
					'Activity'
					{
						$who = Get-sqmWhoIsActive @conn -OutputPath $details -NoOpen -NoConsoleOutput -EnableException 3>$null 6>$null
						$rows = @($who.LastSnapshot | Where-Object { $_ })
						$html = & $table ($rows | Sort-Object ElapsedSeconds -Descending) @('SessionId', 'BlockingSessionId', 'LoginName', 'DatabaseName', 'Status', 'WaitType', 'ElapsedSeconds', 'CpuTimeMs', 'TempdbAllocMB', 'SqlText') $Top
						$blocked = @($rows | Where-Object { $_.BlockingSessionId -and [int]$_.BlockingSessionId -gt 0 })
						if ($blocked.Count -gt 0)
						{
							$heads = ($blocked | ForEach-Object { $_.BlockingSessionId } | Sort-Object -Unique) -join ', '
							& $addFinding 'Warning' 'Activity' "$($blocked.Count) blockierte Session(s)" "Blockierende SPID(s): $heads. Details: Get-sqmBlockingReport."
						}
						$long = @($rows | Where-Object { [double]$_.ElapsedSeconds -ge 600 })
						if ($long.Count -gt 0) { & $addFinding 'Info' 'Activity' "$($long.Count) Request(s) laufen laenger als 10 Minuten" (($long | ForEach-Object { "SPID $($_.SessionId) ($([int]$_.ElapsedSeconds) s)" }) -join ', ') }
					}
					'OpenTransactions'
					{
						$tran = @(Invoke-DbaQuery @conn -Database master -EnableException -Query @"
SET NOCOUNT ON;
SELECT
    st.session_id                                            AS SessionId,
    s.login_name                                             AS LoginName,
    s.host_name                                              AS HostName,
    s.program_name                                           AS ProgramName,
    DB_NAME(dt.DbId)                                         AS DatabaseName,
    at.transaction_begin_time                                AS BeginTime,
    DATEDIFF(SECOND, at.transaction_begin_time, GETDATE())   AS OpenSeconds,
    s.status                                                 AS SessionStatus,
    CAST(dt.LogUsedMB AS decimal(18,2))                      AS LogUsedMB,
    LEFT(ISNULL(t.text, N''), 1000)                          AS LastSqlText
FROM sys.dm_tran_session_transactions st
JOIN sys.dm_tran_active_transactions at ON at.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
OUTER APPLY (
    SELECT MIN(d.database_id) AS DbId, SUM(d.database_transaction_log_bytes_used) / 1048576.0 AS LogUsedMB
    FROM sys.dm_tran_database_transactions d
    WHERE d.transaction_id = st.transaction_id AND d.database_id <> 32767
) dt
LEFT JOIN sys.dm_exec_connections c ON c.session_id = st.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
WHERE st.is_user_transaction = 1
  AND DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) >= $($OpenTranMinutes * 60)
ORDER BY at.transaction_begin_time;
"@)
						$html = "<p>Benutzertransaktionen, die seit mindestens $OpenTranMinutes Minute(n) offen sind. 'sleeping' mit offener Transaktion heisst meist: die Anwendung hat COMMIT vergessen.</p>" +
							(& $table $tran @('SessionId', 'LoginName', 'HostName', 'ProgramName', 'DatabaseName', 'BeginTime', 'OpenSeconds', 'SessionStatus', 'LogUsedMB', 'LastSqlText') $Top)
						if ($tran.Count -gt 0) { $tran | Export-Csv -Path (Join-Path $details "OpenTransactions_${safeInst}_$stamp.csv") -NoTypeInformation -Encoding UTF8 }
						foreach ($t in ($tran | Where-Object { [int]$_.OpenSeconds -ge 600 }))
						{
							$sv = if ($t.SessionStatus -eq 'sleeping') { 'Critical' } else { 'Warning' }
							& $addFinding $sv 'OpenTransactions' "SPID $($t.SessionId) haelt seit $([math]::Round([int]$t.OpenSeconds / 60)) Minuten eine Transaktion offen ($($t.SessionStatus))" "$($t.LoginName) / $($t.ProgramName) / $($t.DatabaseName), Log $($t.LogUsedMB) MB"
						}
					}
					'TempDb'
					{
						$rec = @(Get-sqmTempDbRecommendation @conn -OutputPath $details -NoOpen -EnableException 3>$null 6>$null)
						$cfg = $rec | Select-Object Status, FileCount, RecommendedCount, @{ n = 'FileSizesMB'; e = { ($_.FileSizesMB -join ', ') } }, @{ n = 'GrowthMB'; e = { ($_.GrowthMB -join ', ') } }, @{ n = 'Recommendations'; e = { ($_.Recommendations -join ' ') } }
						$html = & $table $cfg @('Status', 'FileCount', 'RecommendedCount', 'FileSizesMB', 'GrowthMB', 'Recommendations') 1
						foreach ($r in $rec) { $sv = & $mapSeverity $r.Status; if ($sv) { & $addFinding $sv 'TempDb' "TempDB-Konfiguration: $($r.Status)" ($r.Recommendations -join ' ') } }
						$use = @(Invoke-DbaQuery @conn -Database master -EnableException -Query @"
SET NOCOUNT ON;
SELECT TOP ($Top)
    su.session_id AS SessionId, s.login_name AS LoginName, s.program_name AS ProgramName,
    CAST((su.user_objects_alloc_page_count - su.user_objects_dealloc_page_count
        + ISNULL(tu.UserPages, 0)) * 8 / 1024.0 AS decimal(18,2))     AS UserObjectsMB,
    CAST((su.internal_objects_alloc_page_count - su.internal_objects_dealloc_page_count
        + ISNULL(tu.InternalPages, 0)) * 8 / 1024.0 AS decimal(18,2)) AS InternalObjectsMB
FROM sys.dm_db_session_space_usage su
JOIN sys.dm_exec_sessions s ON s.session_id = su.session_id
OUTER APPLY (
    SELECT SUM(t.user_objects_alloc_page_count - t.user_objects_dealloc_page_count) AS UserPages,
           SUM(t.internal_objects_alloc_page_count - t.internal_objects_dealloc_page_count) AS InternalPages
    FROM sys.dm_db_task_space_usage t WHERE t.session_id = su.session_id
) tu
WHERE su.session_id <> @@SPID
ORDER BY (su.user_objects_alloc_page_count + su.internal_objects_alloc_page_count) DESC;
"@ | Where-Object { [double]$_.UserObjectsMB + [double]$_.InternalObjectsMB -gt 0 })
						$html += '<h3>Groesste TempDB-Verbraucher (aktuelle Sessions)</h3>' + (& $table $use @('SessionId', 'LoginName', 'ProgramName', 'UserObjectsMB', 'InternalObjectsMB') $Top)
					}
					'Databases'
					{
						$dh = Get-sqmDatabaseHealth @conn -OutputPath $details -NoOpen -EnableException 3>$null 6>$null
						$rows = @($dh.DetailRows)
						$html = & $table ($rows | Sort-Object @{ e = { switch ($_.OverallStatus) { 'Critical' { 0 } 'Warning' { 1 } default { 2 } } } }, Database) @('Database', 'OverallStatus', 'RecoveryModel', 'SizeMB', 'LastCheckDb', 'CheckDbStatus', 'LastFullBackup', 'LastLogBackup', 'VlfCount', 'VlfStatus') ([math]::Max($Top, 25))
						foreach ($d in ($rows | Where-Object { $_.OverallStatus -in 'Warning', 'Critical' }))
						{
							$why = @($d.PSObject.Properties | Where-Object { $_.Name -like '*Status' -and $_.Name -notin 'OverallStatus', 'DatabaseStatus' -and [string]$_.Value -in 'Warning', 'Critical' } | ForEach-Object { $_.Name -replace 'Status$', '' })
							if ([string]$d.LastFullBackup -eq '(keins)') { $why += 'kein Full-Backup' }
							& $addFinding $d.OverallStatus 'Databases' "Datenbank $($d.Database): $($why -join ', ')" "Letztes CHECKDB: $($d.LastCheckDb), letztes Full-Backup: $($d.LastFullBackup)"
						}
					}
					'Backups'
					{
						$bs = Test-sqmBackupStatus @conn -OutputPath $details -NoOpen -EnableException 3>$null 6>$null
						$rows = @($bs.DetailRows)
						$html = "<p>Letzter Backup-Lauf: $(if ($bs.LastBackupRun) { ([datetime]$bs.LastBackupRun).ToString('yyyy-MM-dd HH:mm') } else { '(keiner gefunden)' }) | Ausgeschlossen (sqm_BackupExclude): $($bs.ExcludedCount)</p>"
						$html += & $table ($rows | Where-Object Status -ne 'OK' | Sort-Object @{ e = { switch ($_.Status) { 'Critical' { 0 } 'Warning' { 1 } 'Skipped' { 2 } default { 3 } } } }, Database) @('Database', 'Status', 'RecoveryModel', 'CreateDate', 'LastFullBackup', 'LastLogBackup', 'Notes') ([math]::Max($Top, 25))
						foreach ($d in ($rows | Where-Object { $_.Status -in 'Warning', 'Critical' }))
						{
							& $addFinding $d.Status 'Backups' "Backup $($d.Database)" $d.Notes
						}
						if (@($bs.NewSinceLastBackup).Count -gt 0)
						{
							& $addFinding 'Info' 'Backups' "Nach dem letzten Backup-Lauf angelegt: $(@($bs.NewSinceLastBackup) -join ', ')" 'Werden vom naechsten Lauf erfasst, sofern nicht in sqm_BackupExclude ausgeschlossen.'
						}
					}
					'PlanCache'
					{
						$pp = @{ Top = $Top; OutputPath = $details; NoOpen = $true }
						if ($InDepth) { $pp['SortBy'] = 'All' }
						if ($ExportPlans) { $pp['ExportPlans'] = $true }
						if ($Database.Count -gt 0) { $pp['Database'] = $Database }
						$pc = @(Get-sqmPlanCacheReport @conn @pp -EnableException 3>$null 6>$null)
						$html = & $table $pc @('Ranks', 'DatabaseName', 'ObjectName', 'Executions', 'TotalCpuMs', 'CpuPercent', 'AvgDurationMs', 'AvgReads', 'Findings', 'StatementText') ([math]::Max($Top, 15))
						foreach ($kind in 'ImplicitConversion', 'Spill', 'MissingIndex', 'NoJoinPredicate')
						{
							$hit = @($pc | Where-Object { $_.Findings -match "\b$kind\b" })
							if ($hit.Count -eq 0) { continue }
							$sv = if ($kind -in 'ImplicitConversion', 'NoJoinPredicate', 'Spill') { 'Warning' } else { 'Info' }
							& $addFinding $sv 'PlanCache' "$kind in $($hit.Count) der teuersten Statements" (($hit | Select-Object -First 5 | ForEach-Object { "$($_.DatabaseName) $($_.ObjectName) [$($_.Ranks)]" }) -join '; ')
						}
						$hog = $pc | Where-Object { [double]$_.CpuPercent -ge 25 } | Select-Object -First 1
						if ($hog) { & $addFinding 'Info' 'PlanCache' "Ein Statement verursacht $($hog.CpuPercent) % der CPU im Cache" "$($hog.DatabaseName) $($hog.ObjectName): $([string]$hog.StatementText | ForEach-Object { if ($_.Length -gt 120) { $_.Substring(0, 120) + ' ...' } else { $_ } })" }
					}
					'Indexes'
					{
						$ip = @{ OutputPath = $details; NoOpen = $true }
						if ($Database.Count -gt 0) { $ip['Database'] = $Database }
						$iu = @(Get-sqmIndexUsageReport @conn @ip -EnableException 3>$null 6>$null)
						$sum = @($iu | Group-Object Finding | ForEach-Object { [PSCustomObject]@{ Finding = $_.Name; Count = $_.Count; SizeMB = [math]::Round(($_.Group | Measure-Object SizeMB -Sum).Sum, 1) } })
						$html = & $table $sum @('Finding', 'Count', 'SizeMB') 10
						$html += '<h3>Groesste Befunde</h3>' + (& $table ($iu | Sort-Object SizeMB -Descending) @('Finding', 'DatabaseName', 'TableName', 'IndexName', 'SizeMB', 'Reads', 'Writes', 'Detail') $Top)
						foreach ($g in $sum)
						{
							$sv = if ($g.Finding -in 'Duplicate', 'Unused' -and $g.SizeMB -ge 1024) { 'Warning' } else { 'Info' }
							& $addFinding $sv 'Indexes' "$($g.Count) Index-Befund(e) '$($g.Finding)' ($($g.SizeMB) MB)" 'Details und auskommentiertes DROP-Skript im Detailbericht.'
						}
						$mp = @{ OutputPath = $details; NoOpen = $true; Top = $Top }
						if ($Database.Count -gt 0) { $mp['Database'] = $Database }
						$mi = @(Get-sqmMissingIndexes @conn @mp -EnableException 3>$null 6>$null)
						$html += '<h3>Fehlende Indizes (DMV-Empfehlungen)</h3>' + (& $table $mi @('DatabaseName', 'TableName', 'ImpactScore', 'UserSeeks', 'EqualityColumns', 'InequalityColumns', 'IncludedColumns') $Top)
						$big = @($mi | Where-Object { [double]$_.ImpactScore -ge 1000 })
						if ($big.Count -gt 0) { & $addFinding 'Warning' 'Indexes' "$($big.Count) fehlende(r) Index(e) mit Impact-Score >= 1000" (($big | Select-Object -First 5 | ForEach-Object { "$($_.DatabaseName).$($_.TableName) ($($_.ImpactScore))" }) -join '; ') }
					}
					'FileLatency'
					{
						$lp = @{ OutputPath = $details; NoOpen = $true }
						if ($SampleSeconds -gt 0) { $lp['SampleSeconds'] = $SampleSeconds }
						$lat = @(Get-sqmFileLatencyReport @conn @lp -EnableException 3>$null 6>$null)
						$html = & $table $lat @('DatabaseName', 'LogicalName', 'FileType', 'Drive', 'Reads', 'AvgReadMs', 'Writes', 'AvgWriteMs', 'Rating') $Top
						foreach ($f in ($lat | Where-Object { $_.Rating -in 'Critical', 'Warning' }))
						{
							& $addFinding $f.Rating 'FileLatency' "$($f.DatabaseName) $($f.LogicalName) ($($f.FileType)): Read $($f.AvgReadMs) ms, Write $($f.AvgWriteMs) ms" "Laufwerk $($f.Drive), $($f.Mode)"
						}
					}
					'Deadlocks'
					{
						$dl = @(Get-sqmDeadlockReport @conn -StartTime (Get-Date).AddDays(-$DeadlockDays) -OutputPath (Join-Path $details 'Deadlocks') -NoOpen -EnableException 3>$null 6>$null)
						$html = "<p>Deadlocks der letzten $DeadlockDays Tage (system_health, Ring Buffer + .xel). Die Graphen liegen als .xdl in Details\Deadlocks.</p>" +
							(& $table $dl @('Timestamp', 'VictimLogin', 'VictimHost', 'VictimProgram', 'ProcessCount', 'VictimStatement') $Top)
						if ($dl.Count -gt 0)
						{
							$sv = if ($dl.Count -ge 10) { 'Warning' } else { 'Info' }
							$apps = ($dl | Group-Object VictimProgram | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', '
							& $addFinding $sv 'Deadlocks' "$($dl.Count) Deadlock(s) in $DeadlockDays Tagen" "Haeufigste Opfer-Programme: $apps"
						}
					}
					'Security'
					{
						$sa = Get-sqmSysadminAccounts @conn -OutputPath $details -NoOpen -EnableException 3>$null 6>$null
						$rows = @($sa.DetailRows)
						$html = & $table $rows @('LoginName', 'LoginType', 'IsEnabled', 'IsSa', 'LastLogin', 'Status', 'Message') ([math]::Max($Top, 25))
						foreach ($r in $rows) { $sv = & $mapSeverity $r.Status; if ($sv) { & $addFinding $sv 'Security' "Sysadmin $($r.LoginName)" $r.Message } }
						& $addFinding 'Info' 'Security' "$($rows.Count) Konto/Konten mit sysadmin" 'Vollstaendiges Login-Audit: Invoke-sqmLoginAudit.'
					}
					'Disk'
					{
						# Historie am Standardort fortschreiben, sonst startet jede Prognose bei null
						$diskHistory = Join-Path (Join-Path (Get-sqmDefaultOutputPath) 'DiskSpaceReports') 'History'
						$dk = Get-sqmDiskSpaceReport @conn -OutputPath $details -HistoryPath $diskHistory -NoOpen -EnableException 3>$null 6>$null
						$rows = @($dk.DetailRows)
						$html = & $table $rows @('MountPoint', 'VolumeName', 'TotalGB', 'FreeGB', 'FreePct', 'DaysUntilFull', 'Status', 'Message') $Top
						foreach ($r in $rows) { $sv = & $mapSeverity $r.Status; if ($sv) { & $addFinding $sv 'Disk' "Laufwerk $($r.MountPoint): $($r.FreePct) % frei" $r.Message } }
					}
				}
			}
			catch
			{
				$status = 'Failed'
				$err = $_.Exception.Message
				$html = "<p class='crit'>Abschnitt fehlgeschlagen: $(& $enc $err)</p>"
				& $addFinding 'Warning' $sec "Abschnitt '$sec' konnte nicht ausgewertet werden" $err
				Invoke-sqmLogging -Message "[$sec] fehlgeschlagen: $err" -FunctionName $functionName -Level "WARNING"
			}
			$sw.Stop()

			$newHtml = @(Get-ChildItem -Path $details -Recurse -File -Filter '*.html' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notin $filesBefore } | ForEach-Object { $_.FullName })
			$secFindings = @($findings | Select-Object -Skip $countBefore)
			if ($status -eq 'OK')
			{
				if ($secFindings | Where-Object Severity -eq 'Critical') { $status = 'Critical' }
				elseif ($secFindings | Where-Object Severity -eq 'Warning') { $status = 'Warning' }
			}
			$sections.Add([PSCustomObject]@{
				Section     = $sec
				Status      = $status
				Findings    = $secFindings.Count
				DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
				DetailFiles = $newHtml
				Error       = $err
			})
			$sectionHtml[$sec] = $html
			Invoke-sqmLogging -Message "[$sec] $status in $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s, $($secFindings.Count) Befund(e)." -FunctionName $functionName -Level "INFO"
		}

		# -------------------------------------------------------------------
		# Gesamtbericht
		# -------------------------------------------------------------------
		$sevRank = @{ 'Critical' = 0; 'Warning' = 1; 'Info' = 2 }
		$sorted = @($findings | Sort-Object @{ e = { $sevRank[$_.Severity] } }, Section)
		$nCrit = @($sorted | Where-Object Severity -eq 'Critical').Count
		$nWarn = @($sorted | Where-Object Severity -eq 'Warning').Count
		$nInfo = @($sorted | Where-Object Severity -eq 'Info').Count
		$overall = if ($nCrit -gt 0) { 'Critical' } elseif ($nWarn -gt 0) { 'Warning' } else { 'OK' }
		$totalSec = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 0)

		$sb = New-Object System.Text.StringBuilder
		[void]$sb.Append(@"
<style>
.cards{display:flex;gap:14px;flex-wrap:wrap;margin:6px 0 22px}
.cardx{background:#0d1f38;border:1px solid #1e3a5f;border-radius:8px;padding:12px 18px;min-width:130px}
.cardx b{display:block;font-size:24px}
.cardx span{color:#94a8c0;font-size:11px;text-transform:uppercase}
a{color:#5dade2}
.toc a{color:#5dade2;margin-right:14px;text-decoration:none;white-space:nowrap}
.sec{margin-top:28px}
.sec h2 small{color:#94a8c0;font-weight:400;font-size:12px;margin-left:10px}
.sec a{color:#5dade2}
h3{color:#94a8c0;font-size:14px;margin:16px 0 6px}
</style>
"@)
		$ovCls = switch ($overall) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
		$mode = if ($SampleSeconds -gt 0) { "Messfenster $SampleSeconds s" } else { 'kumulierte Werte' }
		[void]$sb.Append("<div class='cards'><div class='cardx'><span>Gesamt</span><b class='$ovCls'>$overall</b></div><div class='cardx'><span>Critical</span><b class='crit'>$nCrit</b></div><div class='cardx'><span>Warning</span><b class='warn'>$nWarn</b></div><div class='cardx'><span>Info</span><b>$nInfo</b></div><div class='cardx'><span>Laufzeit</span><b>$totalSec s</b></div><div class='cardx'><span>Uptime</span><b>$uptimeDays d</b></div></div>")
		[void]$sb.Append("<p>$(& $enc $info.ServerName) &middot; $(& $enc $info.Edition) &middot; $(& $enc $info.ProductVersion) &middot; $mode$(if ($InDepth) { ' &middot; InDepth' })</p>")
		[void]$sb.Append("<p class='toc'>" + (($sections | ForEach-Object { $c = switch ($_.Status) { 'Critical' { 'crit' } 'Failed' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }; "<a href='#s-$($_.Section)'><span class='$c'>&#9679;</span> $($_.Section)</a>" }) -join '') + '</p>')

		[void]$sb.Append('<h2>Befunde</h2>')
		if ($sorted.Count -eq 0) { [void]$sb.Append("<p class='ok'>Keine Befunde.</p>") }
		else
		{
			[void]$sb.Append('<table><tr><th>Schwere</th><th>Bereich</th><th>Befund</th><th>Detail</th></tr>')
			foreach ($f in $sorted)
			{
				$c = switch ($f.Severity) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { '' } }
				[void]$sb.Append("<tr><td class='$c'>$($f.Severity)</td><td><a href='#s-$($f.Section)'>$($f.Section)</a></td><td>$(& $enc $f.Finding)</td><td>$(& $enc $f.Detail)</td></tr>")
			}
			[void]$sb.Append('</table>')
		}

		foreach ($s in ($sections | Sort-Object { [array]::IndexOf($order, $_.Section) }))
		{
			$links = @($s.DetailFiles | ForEach-Object {
				$rel = $_.Substring($folder.Length + 1) -replace '\\', '/'
				"<a href='$(& $enc $rel)'>$(& $enc ([System.IO.Path]::GetFileName($_)))</a>"
			}) -join ' &middot; '
			$c = switch ($s.Status) { 'Critical' { 'crit' } 'Failed' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
			[void]$sb.Append("<div class='sec' id='s-$($s.Section)'><h2>$($s.Section) <small><span class='$c'>$($s.Status)</span> &middot; $($s.DurationSec) s$(if ($links) { " &middot; Detail: $links" })</small></h2>")
			[void]$sb.Append($sectionHtml[$s.Section])
			[void]$sb.Append('</div>')
		}

		$htmlFile = Join-Path $folder 'index.html'
		$doc = ConvertTo-sqmHtmlReport -Title "Health Report - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $sb.ToString()
		$doc | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
		$sorted | Export-Csv -Path (Join-Path $folder 'Findings.csv') -NoTypeInformation -Encoding UTF8 -Force

		$zipFile = $null
		if ($Zip)
		{
			$zipFile = "$folder.zip"
			Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zipFile -Force
		}

		Copy-sqmToCentralPath -Path @($htmlFile)
		Invoke-sqmLogging -Message "Health Report $overall (Critical=$nCrit, Warning=$nWarn, Info=$nInfo) in $totalSec s: $htmlFile" -FunctionName $functionName -Level "INFO"
		Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

		[PSCustomObject]@{
			SqlInstance = $SqlInstance
			Status      = $overall
			Critical    = $nCrit
			Warning     = $nWarn
			Info        = $nInfo
			Findings    = $sorted
			Sections    = $sections
			DurationSec = $totalSec
			Folder      = $folder
			HtmlFile    = $htmlFile
			ZipFile     = $zipFile
		}
	}

	end
	{
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen.") -FunctionName $functionName -Level "INFO"
	}
}
