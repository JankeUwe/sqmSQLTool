<#
.SYNOPSIS
    Checks the TDP (IBM Spectrum Protect for SQL) backup solution end to end and reports
    every problem it can find, with a hint how to fix it.

.DESCRIPTION
    The TDP backup solution consists of the SQL Agent job TDP_Backup_Daily, the CMD wrapper
    Backup_TdpFull.cmd, the PowerShell orchestration (Backup-TdpFull.ps1), BackupPlan.json,
    the tracking tables in master (TDP_BackupPlan, BackupStatus, BackupLog) and the TDP/TSM
    client files (tdpsqlc.exe, dsm.opt, tdpsql.cfg). A backup can fail at any of these places
    and some failures leave no trace in the usual places (the job reports success although
    nothing was backed up). This function therefore does not trust a single source but
    cross-checks them:

      Agent        SQL Server Agent service running; job exists, is enabled, has an enabled
                   schedule, a CmdExec step, a usable proxy; last run succeeded and is not
                   overdue; no run that hangs; failed runs in the history.
      Tracking     master tables/procedures exist; BackupLog is written by every job run
                   (a job that "succeeds" without logging means the script did nothing).
      Plan         TDP_BackupPlan filled; every plan database has a BackupStatus row (the
                   orchestration joins on it, a missing row means the database is never
                   backed up); plan databases that no longer exist; user databases that are
                   not in the plan; BackupPlan.json against the tracking table.
      Backups      Per database the age of the newest TDP backup, taken from msdb (virtual
                   device backups, device_type 7) and therefore independent of the tracking
                   tables. Limits are derived from the schedule in BackupPlan.json.
                   Also: consecutive failures and last error from the tracking, "success"
                   logged without a matching backup in msdb, non-TDP full backups taken after
                   the last TDP full (they become the base of the differentials and break the
                   restore chain from TSM), differentials without a TDP full, databases in
                   FULL recovery without any log backup (the TDP job runs Full/Diff only).
      Files        tdpsqlc.exe, dsm.opt, tdpsql.cfg, BackupPlan.json (valid, no placeholders,
                   valid day names, no duplicates), TdpBackup.config, the CMD wrapper (passes
                   the exit code on), log directory.
      Logs         Newest wrapper logs (FAILED / unfinished), newest per-database TDP logs and
                   tdpsql.log: ANSxxxxE/S, ACNxxxxE/S, ACOxxxxE/S messages from the last
                   days, with a hint for the common ones.
      TSM server   With -TestTsmServer: TCP connect to TCPServeraddress/TCPPort from dsm.opt
                   (local computer only).

    Every finding has a severity: Critical (backup is not working / not protected), Warning
    (needs attention) or Info (good to know, does not change the overall status). Files are
    read locally or, for a remote instance, through the administrative share of the host that
    runs the instance. Results are saved as TXT, CSV and HTML.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the SQL connection.

.PARAMETER TdpDir
    TDP installation directory on the instance's host.
    Default: C:\Program Files\Tivoli\TSM\TDPSql

.PARAMETER JobName
    Name of the SQL Agent job. Default: TDP_Backup_Daily

.PARAMETER ConfigPath
    Path of BackupPlan.json on the instance's host. Default: <TdpDir>\BackupPlan.json

.PARAMETER MaxFullAgeDays
    Maximum age of the newest TDP full backup in days. 0 (default) = derive from the schedule
    in BackupPlan.json (longest gap between two full days plus -MarginHours); without a
    readable plan 8 days.

.PARAMETER MaxAnyAgeHours
    Maximum age of the newest TDP full or differential backup in hours. 0 (default) = derive
    from the schedule (longest gap between two backup days plus -MarginHours); without a
    readable plan 26 hours.

.PARAMETER MarginHours
    Tolerance added to the schedule-derived limits (the backup finishes hours after the job
    start). Default: 12.

.PARAMETER HistoryDays
    How far back job history and msdb backup history are read. Default: 35.

.PARAMETER LogFilesToScan
    Number of newest wrapper logs / per-database logs that are scanned. Default: 5.

.PARAMETER TestTsmServer
    Test the TCP connection to the TSM server named in dsm.opt (local computer only).

.PARAMETER ExcludeDatabase
    Databases not to check. Wildcards allowed.

.PARAMETER OutputPath
    Output directory for the report files. Default: 'TdpBackup' subfolder of the configured
    output path.

.PARAMETER NoOpen
    Do not open the HTML report.

.PARAMETER NoReport
    Do not write report files, only return the result object.

.PARAMETER NoFileFallback
    By default, an instance that cannot be reached over SQL is not an error: the function falls
    back to the file-only check (Test-sqmTdpConfiguration) on the instance's host, adds a Critical
    finding "SQL Server not reachable" and sets SqlReachable = $false. The host is taken from the
    instance name (a listener name may not be the machine that runs TDP). With -NoFileFallback
    the connection error is thrown instead.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Test-sqmTdpBackup -SqlInstance "SQL01"

.EXAMPLE
    # Only what needs attention, no report files
    (Test-sqmTdpBackup -SqlInstance "SQL01" -NoReport).Findings | Where-Object Severity -ne 'Info'

.EXAMPLE
    # Also test the TSM server connection, non-default TDP directory
    Test-sqmTdpBackup -SqlInstance "SQL01" -TdpDir 'D:\Tivoli\TDPSql' -TestTsmServer

.NOTES
    Author:        MSSQLTools
    Prerequisites: dbatools; read access to msdb, master and sys.databases, VIEW SERVER STATE
                   (Agent service status, AG role). Read access to the TDP directory (local or
                   administrative share).
    TDP backups are recognised by device_type 7 (virtual device). Another VDI-based backup
    product on the same instance would be counted as TDP.
#>
function Test-sqmTdpBackup
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$TdpDir = 'C:\Program Files\Tivoli\TSM\TDPSql',
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'TDP_Backup_Daily',
		[Parameter(Mandatory = $false)]
		[string]$ConfigPath,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 365)]
		[int]$MaxFullAgeDays = 0,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 8760)]
		[int]$MaxAnyAgeHours = 0,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 168)]
		[int]$MarginHours = 12,
		[Parameter(Mandatory = $false)]
		[ValidateRange(8, 365)]
		[int]$HistoryDays = 35,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 50)]
		[int]$LogFilesToScan = 5,
		[Parameter(Mandatory = $false)]
		[switch]$TestTsmServer,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'TdpBackup'),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
		[Parameter(Mandatory = $false)]
		[switch]$NoFileFallback,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		Invoke-sqmLogging -Message "Starte $functionName (Job $JobName, TdpDir $TdpDir)" -FunctionName $functionName -Level "INFO"
		if (-not $ConfigPath) { $ConfigPath = Join-Path $TdpDir 'BackupPlan.json' }

		# Jede Abfrage traegt eine Markierung (TDPCHK:name) - Unit-Tests steuern damit die Antworten.
		$q = @{ }
		$q.env = @'
-- TDPCHK:env
SET NOCOUNT ON;
DECLARE @agent nvarchar(60) = NULL;
BEGIN TRY
    EXEC sp_executesql N'SELECT TOP (1) @a = status_desc FROM sys.dm_server_services WHERE servicename LIKE N''SQL Server Agent%''', N'@a nvarchar(60) OUTPUT', @a = @agent OUTPUT;
END TRY
BEGIN CATCH
    SET @agent = NULL;
END CATCH
SELECT CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(128)) AS HostName,
       GETDATE() AS ServerNow, @agent AS AgentStatus;
'@
		$q.objects = @'
-- TDPCHK:objects
SELECT o.name AS ObjectName FROM master.sys.objects o
WHERE o.schema_id = SCHEMA_ID(N'dbo')
  AND o.name IN (N'TDP_BackupPlan', N'BackupStatus', N'BackupLog', N'BackupLog_Errors',
                 N'sp_UpdateBackupStatus', N'sp_LogBackupResult', N'v_DatabasesWithoutFullBackup');
'@
		$q.job = @'
-- TDPCHK:job
SELECT j.job_id AS JobId, j.enabled AS Enabled, SUSER_SNAME(j.owner_sid) AS OwnerName
FROM msdb.dbo.sysjobs j WHERE j.name = @JobName;
'@
		$q.steps = @'
-- TDPCHK:steps
SELECT s.step_id AS StepId, s.step_name AS StepName, s.subsystem AS Subsystem, s.command AS Command,
       s.proxy_id AS ProxyId, p.name AS ProxyName, p.enabled AS ProxyEnabled
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
LEFT JOIN msdb.dbo.sysproxies p ON p.proxy_id = s.proxy_id
WHERE j.name = @JobName ORDER BY s.step_id;
'@
		$q.sched = @'
-- TDPCHK:sched
SELECT sc.name AS ScheduleName, sc.enabled AS Enabled, sc.freq_type AS FreqType,
       sc.freq_interval AS FreqInterval, sc.active_start_time AS StartTime
FROM msdb.dbo.sysjobschedules js
JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name = @JobName;
'@
		$q.hist = @'
-- TDPCHK:hist
SELECT h.step_id AS StepId, h.step_name AS StepName, h.run_status AS RunStatus,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS RunTime, h.message AS Message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = @JobName
  AND h.run_date >= CONVERT(int, CONVERT(char(8), DATEADD(DAY, -@Days, GETDATE()), 112))
ORDER BY h.instance_id DESC;
'@
		$q.act = @'
-- TDPCHK:act
SELECT a.start_execution_date AS StartDate
FROM msdb.dbo.sysjobactivity a
JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id
WHERE j.name = @JobName
  AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL;
'@
		$q.plan = @'
-- TDPCHK:plan
SELECT DatabaseName, Enabled, IncludeInDifferential, BackupType FROM master.dbo.TDP_BackupPlan;
'@
		$q.status = @'
-- TDPCHK:status
SELECT DatabaseName, FullBackupExists, LastFullBackupDate, LastFullBackupStatus, LastDifferentialDate,
       ConsecutiveFailures, LastErrorMessage, CreatedDate
FROM master.dbo.BackupStatus;
'@
		$q.log = @'
-- TDPCHK:log
SELECT l.DatabaseName, l.BackupType,
       MAX(CASE WHEN l.Status = 'SUCCESS' THEN l.ExecutionDate END) AS LastSuccess,
       MAX(CASE WHEN l.Status <> 'SUCCESS' THEN l.ExecutionDate END) AS LastFailed,
       SUM(CASE WHEN l.Status <> 'SUCCESS' AND l.ExecutionDate >= DATEADD(DAY, -7, GETDATE()) THEN 1 ELSE 0 END) AS FailedLast7d,
       MAX(l.ExecutionDate) AS LastEntry
FROM master.dbo.BackupLog l
WHERE l.ExecutionDate >= DATEADD(DAY, -@Days, GETDATE())
GROUP BY l.DatabaseName, l.BackupType;
'@
		$q.logmax = @'
-- TDPCHK:logmax
SELECT MAX(ExecutionDate) AS LastEntry, COUNT_BIG(*) AS Cnt FROM master.dbo.BackupLog;
'@
		$q.logerr = @'
-- TDPCHK:logerr
SELECT x.DatabaseName, x.BackupType, x.ExecutionDate, x.ErrorCode, x.ErrorMessage
FROM (SELECT l.DatabaseName, l.BackupType, l.ExecutionDate, l.ErrorCode, l.ErrorMessage,
             ROW_NUMBER() OVER (PARTITION BY l.DatabaseName ORDER BY l.ExecutionDate DESC, l.LogId DESC) AS rn
      FROM master.dbo.BackupLog l
      WHERE l.Status <> 'SUCCESS' AND l.ExecutionDate >= DATEADD(DAY, -7, GETDATE())) x
WHERE x.rn = 1;
'@
		$q.dbs = @'
-- TDPCHK:dbs
SELECT d.name AS DatabaseName, d.database_id AS DatabaseId, d.create_date AS CreateDate,
       d.state_desc AS State, d.recovery_model_desc AS RecoveryModel, d.log_reuse_wait_desc AS LogReuseWait,
       CAST(CASE WHEN d.replica_id IS NOT NULL AND ISNULL(ars.role_desc, '') <> 'PRIMARY' THEN 1 ELSE 0 END AS int) AS IsAgSecondary
FROM sys.databases d
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = d.replica_id AND ars.is_local = 1
WHERE d.database_id > 4 AND d.source_database_id IS NULL;
'@
		$q.msdb = @'
-- TDPCHK:msdb
SELECT b.database_name AS DatabaseName,
       MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 0 AND m.device_type = 7 THEN b.backup_finish_date END) AS LastVdiFull,
       MAX(CASE WHEN b.type = 'I' AND m.device_type = 7 THEN b.backup_finish_date END) AS LastVdiDiff,
       MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 0 AND m.device_type <> 7 THEN b.backup_finish_date END) AS LastOtherFull,
       MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS LastLog
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
JOIN sys.databases d ON d.name COLLATE DATABASE_DEFAULT = b.database_name COLLATE DATABASE_DEFAULT
WHERE b.backup_finish_date >= DATEADD(DAY, -@Days, GETDATE())
  AND b.backup_finish_date >= d.create_date
GROUP BY b.database_name;
'@


		function _N
		{
			param ($Value)
			if ($Value -is [DBNull]) { return $null }
			return $Value
		}
		function _ToDate
		{
			param ($Value)
			if ($null -eq $Value -or $Value -is [DBNull]) { return $null }
			return [datetime]$Value
		}
		function _Fmt
		{
			param ($Value)
			if ($null -eq $Value) { return '' }
			return $Value.ToString('yyyy-MM-dd HH:mm')
		}
		function _MatchAny
		{
			param ([string]$Name, [string[]]$Patterns)
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}
		function _Short
		{
			param ($Text, [int]$Max = 300)
			$t = ([string]$Text -replace '\s+', ' ').Trim()
			if ($t.Length -gt $Max) { return $t.Substring(0, $Max - 3) + '...' }
			return $t
		}
		# Laengste Luecke (in Tagen) zwischen zwei Backup-Tagen der Woche, zyklisch gerechnet
		function _MaxGapDays
		{
			param ([string[]]$Days)
			$idx = @($Days | Where-Object { $_ } | ForEach-Object { try { [int][System.Enum]::Parse([DayOfWeek], [string]$_, $true) } catch { $null } } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
			if ($idx.Count -eq 0) { return $null }
			if ($idx.Count -eq 1) { return 7 }
			$max = 0
			for ($i = 0; $i -lt $idx.Count; $i++)
			{
				$next = $idx[($i + 1) % $idx.Count]
				$gap = ($next - $idx[$i] + 7) % 7
				if ($gap -gt $max) { $max = $gap }
			}
			return $max
		}
	}
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

			function _Add
			{
				param ([string]$Severity, [string]$Category, [string]$Message, [string]$Hint = '', [string]$Database = '')
				$findings.Add([PSCustomObject]@{
						SqlInstance = $instance
						Severity    = $Severity
						Category    = $Category
						Database    = $Database
						Message     = $Message
						Hint        = $Hint
					})
			}
			function _Q
			{
				param ([string]$Name, [hashtable]$Params = @{ })
				$p = $connParams.Clone()
				$p['Database'] = 'master'
				$p['Query'] = $q[$Name]
				$p['EnableException'] = $true
				if ($Params.Count -gt 0) { $p['SqlParameter'] = $Params }
				return @(Invoke-DbaQuery @p)
			}

			try
			{
				Invoke-sqmLogging -Message "[$instance] Pruefe TDP-Backup ..." -FunctionName $functionName -Level "INFO"

				# ------------------------------------------------------------------ Umgebung
				try { $env1 = @(_Q 'env') }
				catch
				{
					if ($NoFileFallback) { throw }
					$sqlError = $_.Exception.Message
					Invoke-sqmLogging -Message "[$instance] SQL nicht erreichbar, pruefe nur Dateien und Logs: $sqlError" -FunctionName $functionName -Level "WARNING"
					$fbHost = (($instance -split '\\')[0] -split ',')[0]
					$sqlFinding = [PSCustomObject]@{
						SqlInstance = $instance
						Severity    = 'Critical'
						Category    = 'SQL'
						Database    = ''
						Message     = "SQL Server nicht erreichbar, nur Datei- und Log-Pruefung moeglich: $(_Short $sqlError 250)"
						Hint        = 'Instanzname, Port, Credential und Dienst pruefen. Agent-Job, Tracking-Tabellen und Backup-Alter in msdb sind in diesem Lauf NICHT geprueft.'
					}
					$cfgR = Test-sqmTdpConfiguration -ComputerName $fbHost -TdpDir $TdpDir -ConfigPath $ConfigPath -LogFilesToScan $LogFilesToScan -TestTsmServer:$TestTsmServer -AdditionalFinding $sqlFinding -OutputPath $OutputPath -NoOpen:$NoOpen -NoReport:$NoReport
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance     = $instance
							HostName        = $fbHost
							Timestamp       = $cfgR.Timestamp
							Status          = $cfgR.Status
							SqlReachable    = $false
							CriticalCount   = $cfgR.CriticalCount
							WarningCount    = $cfgR.WarningCount
							InfoCount       = $cfgR.InfoCount
							LimitSource     = 'nicht ermittelt (kein SQL)'
							MaxFullAgeHours = $null
							MaxAnyAgeHours  = $null
							Findings        = $cfgR.Findings
							DatabaseRows    = @()
							TxtFile         = $cfgR.TxtFile
							CsvFile         = $cfgR.CsvFile
							HtmlFile        = $cfgR.HtmlFile
						})
					continue
				}
				$now = if ($env1.Count -gt 0 -and -not ($env1[0].ServerNow -is [DBNull])) { [datetime]$env1[0].ServerNow } else { Get-Date }
				$hostName = if ($env1.Count -gt 0 -and -not ($env1[0].HostName -is [DBNull]) -and $env1[0].HostName) { [string]$env1[0].HostName } else { (($instance -split '\\')[0] -split ',')[0] }
				$isLocal = ($hostName -ieq $env:COMPUTERNAME) -or ($hostName -in @('.', 'localhost', '(local)'))
				$agentStatus = if ($env1.Count -gt 0) { [string](_N $env1[0].AgentStatus) } else { '' }
				function _P
				{
					param ([string]$LocalPath)
					if ($isLocal) { return $LocalPath }
					return (_ToUncPath -ComputerName $hostName -LocalPath $LocalPath)
				}

				# ------------------------------------------------------------------ Dateien, BackupPlan.json, Logs (ohne SQL)
				$fc = Invoke-sqmTdpFileCheck -Instance $instance -TdpDir $TdpDir -ConfigPath $ConfigPath -HostName $hostName -IsLocal $isLocal -Now $now -LogFilesToScan $LogFilesToScan -TestTsmServer:$TestTsmServer
				foreach ($f in $fc.Findings) { $findings.Add($f) }
				$planOk = $fc.PlanOk
				$fullDays = $fc.FullDays; $diffDays = $fc.DiffDays; $jsonDbs = $fc.JsonDatabases; $jsonExcluded = $fc.JsonExcluded

				# Grenzen aus dem Zeitplan ableiten (oder Parameter / Standard)
				$fullGap = _MaxGapDays $fullDays
				$anyGap = _MaxGapDays (@($fullDays) + @($diffDays))
				$maxFullAgeH = if ($MaxFullAgeDays -gt 0) { $MaxFullAgeDays * 24 } elseif ($fullGap) { $fullGap * 24 + $MarginHours } else { 8 * 24 }
				$maxAnyAgeH = if ($MaxAnyAgeHours -gt 0) { $MaxAnyAgeHours } elseif ($anyGap) { $anyGap * 24 + $MarginHours } else { 26 }
				$limitSource = if ($MaxFullAgeDays -gt 0 -or $MaxAnyAgeHours -gt 0) { 'Parameter' } elseif ($planOk -and $fullGap) { 'Zeitplan' } else { 'Standard' }

				# ------------------------------------------------------------------ SQL Agent
				if ($agentStatus -and $agentStatus -ne 'Running')
				{
					_Add 'Critical' 'Agent' "SQL Server Agent Dienst ist nicht gestartet (Status: $agentStatus)" 'Dienst starten und Starttyp Automatisch pruefen; ohne Agent laeuft kein Backup-Job.'
				}
				$jobRows = @(_Q 'job' @{ JobName = $JobName })
				$jobFound = $jobRows.Count -gt 0
				$lastJobRun = $null
				$jobLastOk = $null
				if (-not $jobFound)
				{
					_Add 'Critical' 'Agent' "Agent-Job '$JobName' existiert nicht" '02_Create_Agent_Job.sql ausfuehren (oder -JobName anpassen, falls der Job anders heisst).'
				}
				else
				{
					if ([int]$jobRows[0].Enabled -ne 1)
					{
						_Add 'Critical' 'Agent' "Agent-Job '$JobName' ist deaktiviert" "Job aktivieren: EXEC msdb.dbo.sp_update_job @job_name = N'$JobName', @enabled = 1"
					}
					$steps = @(_Q 'steps' @{ JobName = $JobName })
					if ($steps.Count -eq 0)
					{
						_Add 'Critical' 'Agent' 'Der Job hat keinen Job-Step' '02_Create_Agent_Job.sql erneut ausfuehren.'
					}
					foreach ($st in $steps)
					{
						$cmd = [string](_N $st.Command)
						if ([string]$st.Subsystem -ne 'CmdExec')
						{
							_Add 'Warning' 'Agent' "Step '$($st.StepName)' laeuft als $($st.Subsystem), erwartet CmdExec" 'PowerShell-Steps haengen im Agent erfahrungsgemaess; CmdExec mit Backup_TdpFull.cmd verwenden.'
						}
						if ($cmd -notmatch 'Backup_TdpFull')
						{
							_Add 'Warning' 'Agent' "Step '$($st.StepName)' ruft nicht Backup_TdpFull.cmd auf: $(_Short $cmd 150)" 'Befehl des Steps pruefen (Soll: <TdpDir>\01_Backup_CMD\Backup_TdpFull.cmd).'
						}
						elseif ($cmd -match '([A-Za-z]:\\[^"]*?Backup_TdpFull\.cmd)')
						{
							$cmdFile = _P $Matches[1]
							if (-not (Test-Path -LiteralPath $cmdFile))
							{
								_Add 'Critical' 'Agent' "Die vom Job-Step aufgerufene Datei existiert nicht: $($Matches[1])" 'Pfad im Step korrigieren oder die Datei wiederherstellen; der Step scheitert sofort.'
							}
						}
						if (-not ($st.ProxyId -is [DBNull]) -and $st.ProxyId -and [int]$st.ProxyId -ne 0)
						{
							if ([int](_N $st.ProxyEnabled) -ne 1)
							{
								_Add 'Critical' 'Agent' "Proxy '$($st.ProxyName)' des Steps '$($st.StepName)' ist deaktiviert" "Proxy aktivieren: EXEC msdb.dbo.sp_update_proxy @proxy_name = N'$($st.ProxyName)', @enabled = 1"
							}
						}
						elseif ($st.Subsystem -eq 'CmdExec')
						{
							_Add 'Info' 'Agent' "Step '$($st.StepName)' laeuft ohne Proxy unter dem SQL-Agent-Dienstkonto" 'Empfohlen: New-TdpAgentProxy.ps1 ausfuehren und 02_Create_Agent_Job.sql erneut starten.'
						}
					}

					$sched = @(_Q 'sched' @{ JobName = $JobName })
					$activeSched = @($sched | Where-Object { [int]$_.Enabled -eq 1 })
					if ($sched.Count -eq 0)
					{
						_Add 'Critical' 'Agent' 'Dem Job ist kein Zeitplan zugeordnet' 'Zeitplan anlegen und anhaengen (02_Create_Agent_Job.sql); der Job startet sonst nie.'
					}
					elseif ($activeSched.Count -eq 0)
					{
						_Add 'Critical' 'Agent' 'Alle Zeitplaene des Jobs sind deaktiviert' 'Zeitplan aktivieren (sp_update_schedule @enabled = 1).'
					}
					$dailySched = @($activeSched | Where-Object { [int]$_.FreqType -eq 4 -and [int]$_.FreqInterval -eq 1 }).Count -gt 0

					$hist = @(_Q 'hist' @{ JobName = $JobName; Days = $HistoryDays })
					$runs = @($hist | Where-Object { [int]$_.StepId -eq 0 })
					if ($runs.Count -gt 0)
					{
						$lastRun = $runs[0]
						$lastJobRun = _ToDate $lastRun.RunTime
						$okRuns = @($runs | Where-Object { [int]$_.RunStatus -eq 1 })
						if ($okRuns.Count -gt 0) { $jobLastOk = _ToDate $okRuns[0].RunTime }
						if ([int]$lastRun.RunStatus -eq 0)
						{
							$failStep = @($hist | Where-Object { [int]$_.StepId -gt 0 -and [int]$_.RunStatus -eq 0 } | Select-Object -First 1)
							$why = if ($failStep.Count -gt 0) { _Short $failStep[0].Message 400 } else { _Short $lastRun.Message 400 }
							_Add 'Critical' 'Agent' "Letzter Job-Lauf ($(_Fmt $lastJobRun)) ist fehlgeschlagen: $why" 'Details: Jobverlauf in SSMS; Wrapper-Log in <TdpDir>\03_Log (Backup_TdpFull_*.log) und die Befunde der Kategorie Log.'
						}
						elseif ([int]$lastRun.RunStatus -eq 2)
						{
							_Add 'Warning' 'Agent' "Letzter Job-Lauf ($(_Fmt $lastJobRun)) wurde wiederholt (Retry)" 'Step hat mindestens einmal versagt und lief erst im Retry; Ursache im Jobverlauf suchen.'
						}
						elseif ([int]$lastRun.RunStatus -eq 3)
						{
							_Add 'Warning' 'Agent' "Letzter Job-Lauf ($(_Fmt $lastJobRun)) wurde abgebrochen" 'Jobverlauf pruefen (manueller Stopp oder Agent-Neustart waehrend des Laufs).'
						}
						$failed7 = @($runs | Where-Object { [int]$_.RunStatus -eq 0 -and (_ToDate $_.RunTime) -ge $now.AddDays(-7) }).Count
						if ($failed7 -gt 0 -and [int]$lastRun.RunStatus -ne 0)
						{
							_Add 'Warning' 'Agent' "$failed7 fehlgeschlagene Job-Laeufe in den letzten 7 Tagen (zuletzt ok)" 'Wiederkehrendes Problem - Jobverlauf der fehlgeschlagenen Laeufe ansehen.'
						}
						if ($dailySched -and $lastJobRun -and ($now - $lastJobRun).TotalHours -gt 26)
						{
							_Add 'Critical' 'Agent' "Der Job ist seit $([math]::Round(($now - $lastJobRun).TotalHours, 0)) h nicht gelaufen (letzter Lauf $(_Fmt $lastJobRun), Zeitplan taeglich)" 'Agent-Dienst, Zeitplan und Job-Status pruefen.'
						}
					}
					else
					{
						_Add 'Critical' 'Agent' "Keine Job-Historie der letzten $HistoryDays Tage - der Job lief nicht (oder die Historie wurde bereinigt)" 'Job einmal manuell starten und Zeitplan pruefen.'
					}

					$act = @(_Q 'act' @{ JobName = $JobName })
					if ($act.Count -gt 0)
					{
						$started = _ToDate $act[0].StartDate
						$runH = if ($started) { ($now - $started).TotalHours } else { 0 }
						if ($runH -gt 12)
						{
							_Add 'Warning' 'Agent' "Der Job laeuft seit $([math]::Round($runH, 1)) h (Start $(_Fmt $started))" 'Haengt tdpsqlc.exe (TSM-Verbindung)? Prozess und Wrapper-Log pruefen; kein zweiter Lauf startet, solange der Job aktiv ist.'
						}
					}
				}

				# ------------------------------------------------------------------ Tracking-Objekte
				$haveObj = @(_Q 'objects' | ForEach-Object { [string]$_.ObjectName })
				$needObj = 'TDP_BackupPlan', 'BackupStatus', 'BackupLog', 'sp_UpdateBackupStatus', 'sp_LogBackupResult', 'v_DatabasesWithoutFullBackup'
				$missingObj = @($needObj | Where-Object { $_ -notin $haveObj })
				if ($missingObj.Count -gt 0)
				{
					_Add 'Critical' 'Tracking' "In master fehlen: $($missingObj -join ', ')" '01_TDP_BackupTracking_Setup.sql ausfuehren (Achtung: das Skript legt die Tabellen neu an).'
				}
				$tablesOk = ('TDP_BackupPlan' -in $haveObj) -and ('BackupStatus' -in $haveObj) -and ('BackupLog' -in $haveObj)

				$planRows = @(); $statusRows = @(); $logRows = @(); $logErrRows = @(); $logMax = $null
				if ('TDP_BackupPlan' -in $haveObj) { $planRows = @(_Q 'plan') }
				if ('BackupStatus' -in $haveObj) { $statusRows = @(_Q 'status') }
				if ('BackupLog' -in $haveObj)
				{
					$logRows = @(_Q 'log' @{ Days = $HistoryDays })
					$logErrRows = @(_Q 'logerr')
					$logMax = @(_Q 'logmax')
				}

				# ------------------------------------------------------------------ Datenbanken und msdb
				$dbRows = @(_Q 'dbs')
				$msdbRows = @(_Q 'msdb' @{ Days = $HistoryDays })
				$dbInfo = @{ }
				foreach ($r in $dbRows) { $dbInfo[[string]$r.DatabaseName] = $r }
				$vdi = @{ }
				foreach ($r in $msdbRows) { $vdi[[string]$r.DatabaseName] = $r }
				$statusMap = @{ }
				foreach ($r in $statusRows) { $statusMap[[string]$r.DatabaseName] = $r }
				$logMap = @{ }
				foreach ($r in $logRows) { $logMap["$($r.DatabaseName)|$($r.BackupType)"] = $r }
				$errMap = @{ }
				foreach ($r in $logErrRows) { $errMap[[string]$r.DatabaseName] = $r }

				# ------------------------------------------------------------------ BackupLog wird vom Job beschrieben?
				if ('BackupLog' -in $haveObj)
				{
					$lastEntry = if ($logMax.Count -gt 0) { _ToDate $logMax[0].LastEntry } else { $null }
					if ($null -eq $lastEntry)
					{
						if ($jobFound -and $jobLastOk)
						{
							_Add 'Critical' 'Tracking' 'BackupLog ist leer, obwohl der Job erfolgreich gelaufen ist - das Skript hat nichts gesichert/protokolliert' 'Wrapper-Log in <TdpDir>\03_Log pruefen; haeufig: Backup-TdpFull.ps1 am erwarteten Ort fehlt oder die Ausfuehrung endet vor Step 5.'
						}
						else
						{
							_Add 'Warning' 'Tracking' 'BackupLog ist leer - noch kein Backup protokolliert' 'Job einmal manuell ausfuehren.'
						}
					}
					elseif ($jobLastOk -and $lastEntry -lt $jobLastOk.AddHours(-2) -and ($now - $jobLastOk).TotalHours -le 48)
					{
						_Add 'Critical' 'Tracking' "Der Job lief erfolgreich ($(_Fmt $jobLastOk)), BackupLog hat aber nichts Neueres als $(_Fmt $lastEntry)" 'Der Job meldet Erfolg ohne zu sichern. Wrapper-Log (Backup_TdpFull_*.log) pruefen: Pfad zu Backup-TdpFull.ps1, Konfigurationsdatei, Ausfuehrungsrichtlinie.'
					}
				}

				# ------------------------------------------------------------------ Plan gegen Tabelle und Datenbanken
				$planNames = @($planRows | ForEach-Object { [string]$_.DatabaseName })
				if ($tablesOk)
				{
					if ($planRows.Count -eq 0)
					{
						_Add 'Critical' 'Plan' 'TDP_BackupPlan ist leer - es wird keine Datenbank gesichert' 'Der Sync aus BackupPlan.json laeuft zu Beginn von Backup-TdpFull.ps1; JSON und Job-Lauf pruefen.'
					}
					foreach ($pr in $planRows)
					{
						$n = [string]$pr.DatabaseName
						if (_MatchAny $n $ExcludeDatabase) { continue }
						if ([int]$pr.Enabled -eq 1 -and -not $statusMap.ContainsKey($n))
						{
							_Add 'Critical' 'Plan' 'Im Plan, aber ohne Zeile in BackupStatus - die Orchestrierung verbindet per INNER JOIN und sichert sie nie' "Zeile in BackupStatus anlegen bzw. Sync pruefen (Sync-JsonToDatabase / sp_UpdateBackupStatus)." $n
						}
						if (-not $dbInfo.ContainsKey($n))
						{
							_Add 'Warning' 'Plan' 'Im Plan, aber die Datenbank existiert nicht (mehr) auf der Instanz' 'Aus BackupPlan.json entfernen oder die Datenbank wiederherstellen.' $n
						}
						elseif ([int]$pr.Enabled -eq 0)
						{
							_Add 'Info' 'Plan' 'Im Plan deaktiviert (Enabled = 0) - wird nicht gesichert' '' $n
						}
					}
					foreach ($r in $dbRows)
					{
						$n = [string]$r.DatabaseName
						if (_MatchAny $n $ExcludeDatabase) { continue }
						if ([int]$r.IsAgSecondary -eq 1 -or [string]$r.State -ne 'ONLINE') { continue }
						if ($n -notin $planNames -and $n -notin $jsonExcluded)
						{
							$other = $vdi.ContainsKey($n) -and ($vdi[$n].LastOtherFull -isnot [DBNull])
							$sev = if ($other) { 'Info' } else { 'Warning' }
							$extra = if ($other) { ' (wird aber anderweitig gesichert)' } else { '' }
							_Add $sev 'Plan' "Benutzerdatenbank ist nicht im TDP-Backup-Plan$extra" 'Mit Configure-BackupPlan.ps1 aufnehmen oder in ExcludedDatabases eintragen.' $n
						}
					}
				}
				if ($planOk -and $tablesOk)
				{
					$jsonEnabled = @($jsonDbs | Where-Object { $_.PSObject.Properties['Enabled'] -and [bool]$_.Enabled } | ForEach-Object { [string]$_.Name })
					$tblEnabled = @($planRows | Where-Object { [int]$_.Enabled -eq 1 } | ForEach-Object { [string]$_.DatabaseName })
					$onlyJson = @($jsonEnabled | Where-Object { $_ -notin $tblEnabled -and -not (_MatchAny $_ $ExcludeDatabase) })
					$onlyTbl = @($tblEnabled | Where-Object { $_ -notin $jsonEnabled -and -not (_MatchAny $_ $ExcludeDatabase) })
					if ($onlyJson.Count -gt 0 -or $onlyTbl.Count -gt 0)
					{
						$parts = @()
						if ($onlyJson.Count -gt 0) { $parts += "nur im JSON: $($onlyJson -join ', ')" }
						if ($onlyTbl.Count -gt 0) { $parts += "nur in der Tabelle: $($onlyTbl -join ', ')" }
						_Add 'Warning' 'Plan' "BackupPlan.json und TDP_BackupPlan weichen ab ($($parts -join '; '))" 'Der Sync laeuft erst beim naechsten Job-Lauf; weicht es danach noch ab, schlaegt Sync-JsonToDatabase fehl (Wrapper-Log).'
					}
				}

				# ------------------------------------------------------------------ Backups je Datenbank
				$checkNames = @(@($planNames) + @($dbRows | Where-Object { [int]$_.IsAgSecondary -eq 0 } | ForEach-Object { [string]$_.DatabaseName }) | Sort-Object -Unique |
					Where-Object { $_ -and -not (_MatchAny $_ $ExcludeDatabase) })
				$dbReport = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($n in $checkNames)
				{
					$pr = @($planRows | Where-Object { [string]$_.DatabaseName -eq $n }) | Select-Object -First 1
					$inPlan = [bool]$pr
					$planEnabled = $inPlan -and [int]$pr.Enabled -eq 1
					$info = $dbInfo[$n]
					$v = $vdi[$n]
					$vFull = if ($v) { _ToDate $v.LastVdiFull } else { $null }
					$vDiff = if ($v) { _ToDate $v.LastVdiDiff } else { $null }
					$oFull = if ($v) { _ToDate $v.LastOtherFull } else { $null }
					$anyBk = if ($vFull -and $vDiff) { if ($vFull -gt $vDiff) { $vFull } else { $vDiff } } elseif ($vFull) { $vFull } else { $vDiff }
					$fullAgeH = if ($vFull) { [math]::Round(($now - $vFull).TotalHours, 1) } else { $null }
					$anyAgeH = if ($anyBk) { [math]::Round(($now - $anyBk).TotalHours, 1) } else { $null }
					$stRow = $statusMap[$n]
					$consec = if ($stRow -and -not ($stRow.ConsecutiveFailures -is [DBNull])) { [int]$stRow.ConsecutiveFailures } else { 0 }

					# nur online-Datenbanken, die TDP sichern soll
					$checkable = $planEnabled -and $info -and [string]$info.State -eq 'ONLINE' -and [int]$info.IsAgSecondary -eq 0
					if ($planEnabled -and $info -and [string]$info.State -ne 'ONLINE')
					{
						_Add 'Info' 'Backup' "Datenbank ist $($info.State) - nicht pruefbar" '' $n
					}
					if ($planEnabled -and $info -and [int]$info.IsAgSecondary -eq 1)
					{
						_Add 'Info' 'Backup' 'AG-Secondary - Backups dort nicht geprueft (TDP sichert auf dem Primary)' '' $n
					}
					if ($checkable)
					{
						$created = _ToDate $info.CreateDate
						$ageSinceCreateH = if ($created) { ($now - $created).TotalHours } else { [double]::MaxValue }
						$inDiff = [int]$pr.IncludeInDifferential -eq 1

						# Alter der letzten TDP-Sicherung (aus msdb, unabhaengig von den Tracking-Tabellen)
						if ($null -eq $vFull)
						{
							$sev = if ($ageSinceCreateH -gt $maxFullAgeH) { 'Critical' } else { 'Warning' }
							$what = if ($ageSinceCreateH -gt $maxFullAgeH) { "Kein TDP-Full-Backup in msdb (Historie $HistoryDays Tage, Datenbank angelegt $(_Fmt $created))" } else { "Noch kein TDP-Full-Backup (Datenbank erst $([math]::Round($ageSinceCreateH, 0)) h alt)" }
							_Add $sev 'Backup' $what 'Wrapper-Log und tdpsql.log pruefen; Sonderbehandlung (AllowSpecialHandling) sichert Datenbanken ohne Full beim naechsten Lauf.' $n
						}
						else
						{
							if ($fullAgeH -gt $maxFullAgeH)
							{
								_Add 'Critical' 'Backup' "Letztes TDP-Full vor $([math]::Round($fullAgeH / 24, 1)) Tagen ($(_Fmt $vFull)), Grenze $([math]::Round($maxFullAgeH / 24, 1)) Tage ($limitSource)" 'Faellt das Full aus, sind auch die Differentials nutzlos. Befunde zu Job, Log und TSM-Verbindung beachten.' $n
							}
							if ($inDiff -and $anyAgeH -gt $maxAnyAgeH)
							{
								_Add 'Critical' 'Backup' "Letztes TDP-Full/Diff vor $([math]::Round($anyAgeH, 1)) h ($(_Fmt $anyBk)), Grenze $maxAnyAgeH h ($limitSource)" 'Naechster geplanter Lauf zu spaet oder Backups scheitern - Job-/Log-Befunde pruefen.' $n
							}
						}

						# Fehler laut Tracking
						if ($consec -ge 1)
						{
							$sev = if ($consec -ge 3) { 'Critical' } else { 'Warning' }
							$msg = if ($stRow -and -not ($stRow.LastErrorMessage -is [DBNull])) { _Short $stRow.LastErrorMessage 300 } else { '(keine Fehlermeldung hinterlegt)' }
							_Add $sev 'Backup' "$consec Fehlversuch(e) in Folge laut BackupStatus: $msg" 'Meldungscode in der Tabelle der bekannten Codes (Kategorie Log) nachschlagen; ANS-Codes siehe TSM-Dokumentation.' $n
						}
						elseif ($errMap.ContainsKey($n) -and $errMap[$n].ExecutionDate -ge $now.AddDays(-7))
						{
							$e = $errMap[$n]
							_Add 'Warning' 'Backup' "Fehlgeschlagenes $($e.BackupType)-Backup am $(_Fmt (_ToDate $e.ExecutionDate)) (danach erfolgreich): $(_Short $e.ErrorMessage 250)" 'Einmaliger Fehler - nur beachten, wenn er sich wiederholt.' $n
						}

						# Erfolg gemeldet, aber nichts in msdb?
						foreach ($bt in 'FULL', 'DIFF')
						{
							$lg = $logMap["$n|$bt"]
							if (-not $lg) { continue }
							$succ = _ToDate $lg.LastSuccess
							if (-not $succ) { continue }
							$vref = if ($bt -eq 'FULL') { $vFull } else { $vDiff }
							if ($null -eq $vref)
							{
								_Add 'Critical' 'Backup' "BackupLog meldet SUCCESS fuer $bt ($(_Fmt $succ)), in msdb gibt es aber kein TDP-Backup dieses Typs" 'Erfolg ohne Backup: tdpsqlc.exe liefert Exit 0 ohne zu sichern, oder msdb-Historie wurde bereinigt. Wrapper-Log und tdpsql.log pruefen.' $n
							}
							elseif ($succ -gt $vref.AddHours(2))
							{
								_Add 'Warning' 'Backup' "BackupLog meldet SUCCESS fuer $bt um $(_Fmt $succ), das neueste TDP-$bt in msdb ist aber von $(_Fmt $vref)" 'Abweichung zwischen Protokoll und msdb - Wrapper-Log und tdpsql.log fuer diesen Zeitpunkt pruefen.' $n
							}
						}

						# Fremde Fulls nach dem letzten TDP-Full
						if ($oFull -and $vFull -and $oFull -gt $vFull)
						{
							_Add 'Warning' 'Backup' "Nicht-TDP-Full ($(_Fmt $oFull)) neuer als das letzte TDP-Full ($(_Fmt $vFull)) - Differentials haengen am fremden Full" 'Wiederherstellung aus TSM braucht das Full als Basis: Fremd-Full als COPY_ONLY ausfuehren oder TDP-Full neu starten.' $n
						}
						elseif ($oFull -and -not $vFull)
						{
							_Add 'Info' 'Backup' "Es gibt Nicht-TDP-Fulls ($(_Fmt $oFull)), aber kein TDP-Full" '' $n
						}

						# Differential ohne Full
						if ($inDiff -and $vDiff -and -not $vFull)
						{
							_Add 'Warning' 'Backup' 'TDP-Differential vorhanden, aber kein TDP-Full - Restore aus TSM nicht moeglich' 'TDP-Full anstossen (Sonderbehandlung oder manuell).' $n
						}

						# Logbackups (TDP-Job sichert nur Full/Diff)
						if ([string]$info.RecoveryModel -in 'FULL', 'BULK_LOGGED' -and $vFull)
						{
							$lastLog = if ($v) { _ToDate $v.LastLog } else { $null }
							if ($null -eq $lastLog -and ($now - $vFull).TotalHours -gt 24)
							{
								$wait = [string](_N $info.LogReuseWait)
								$extra = if ($wait -eq 'LOG_BACKUP') { ' - Transaktionslog kann nicht wiederverwendet werden und waechst' } else { '' }
								_Add 'Warning' 'Backup' "Recovery $($info.RecoveryModel) ohne Log-Backup in den letzten $HistoryDays Tagen$extra" 'Das TDP-Skript sichert nur Full/Diff. Log-Backups separat einrichten (TDP log-Backup oder Ola) oder auf SIMPLE umstellen, wenn Point-in-Time nicht noetig ist.' $n
							}
						}
					}

					$mine = @($findings | Where-Object { $_.Database -eq $n })
					$dbStatus = if (-not $planEnabled -and -not ($mine | Where-Object { $_.Severity -ne 'Info' })) { if ($inPlan) { 'Disabled' } else { 'NotInPlan' } }
					elseif ($mine | Where-Object { $_.Severity -eq 'Critical' }) { 'Critical' }
					elseif ($mine | Where-Object { $_.Severity -eq 'Warning' }) { 'Warning' }
					else { 'OK' }
					$dbReport.Add([PSCustomObject]@{
							SqlInstance          = $instance
							Database             = $n
							Status               = $dbStatus
							InPlan               = $inPlan
							LastTdpFull          = _Fmt $vFull
							LastTdpDiff          = _Fmt $vDiff
							LastOtherFull        = _Fmt $oFull
							FullAgeHours         = $fullAgeH
							AnyAgeHours          = $anyAgeH
							ConsecutiveFailures  = $consec
							Notes                = (@($mine | ForEach-Object { $_.Message }) -join '; ')
						})
				}


				# ------------------------------------------------------------------ Ergebnis
				$cnt = @{ }
				foreach ($s in 'Critical', 'Warning', 'Info') { $cnt[$s] = @($findings | Where-Object Severity -eq $s).Count }
				$overall = if ($cnt.Critical -gt 0) { 'Critical' } elseif ($cnt.Warning -gt 0) { 'Warning' } else { 'OK' }
				$sevOrder = @{ Critical = 0; Warning = 1; Info = 2 }
				$sortedF = @($findings | Sort-Object @{ e = { $sevOrder[$_.Severity] } }, Category, Database)
				$sortedD = @($dbReport | Sort-Object @{ e = { switch ($_.Status) { 'Critical' { 0 } 'Warning' { 1 } 'OK' { 2 } default { 3 } } } }, Database)

				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$fileStamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
				$txtFile = $null; $csvFile = $null; $htmlFile = $null
				$limitTxt = "Full max $([math]::Round($maxFullAgeH / 24, 1)) Tage | Full/Diff max $maxAnyAgeH h ($limitSource)"

				if (-not $NoReport -and $PSCmdlet.ShouldProcess($instance, "Erstelle TDP-Backup-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null }
					$txtFile = Join-Path $OutputPath "TdpBackup_${safeInst}_$fileStamp.txt"
					$csvFile = Join-Path $OutputPath "TdpBackup_${safeInst}_$fileStamp.csv"
					$htmlFile = Join-Path $OutputPath "TdpBackup_${safeInst}_$fileStamp.html"

					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - TDP-Backup-Pruefung")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz  : $instance (Host $hostName)")
					$lines.Add("# Erstellt : $timestamp")
					$lines.Add("# Job      : $JobName | TdpDir: $TdpDir")
					$lines.Add("# Grenzen  : $limitTxt")
					$lines.Add("# Gesamt   : $overall | Critical: $($cnt.Critical) | Warning: $($cnt.Warning) | Info: $($cnt.Info)")
					$lines.Add("# ================================================================")
					$lines.Add("")
					foreach ($f in $sortedF)
					{
						$dbTxt = if ($f.Database) { " [$($f.Database)]" } else { '' }
						$lines.Add("[$($f.Severity.ToUpper())] $($f.Category)$dbTxt - $($f.Message)")
						if ($f.Hint) { $lines.Add("        -> $($f.Hint)") }
					}
					if ($sortedF.Count -eq 0) { $lines.Add('Keine Befunde.') }
					$lines.Add("")
					$lines.Add(("{0,-35} {1,-10} {2,-16} {3,-16} {4}" -f 'Datenbank', 'Status', 'Letztes Full', 'Letztes Diff', 'Hinweise'))
					$lines.Add(("-" * 140))
					foreach ($d in $sortedD)
					{
						$dn = if ($d.Database.Length -gt 35) { $d.Database.Substring(0, 32) + '...' } else { $d.Database }
						$lines.Add(("{0,-35} {1,-10} {2,-16} {3,-16} {4}" -f $dn, $d.Status, $d.LastTdpFull, $d.LastTdpDiff, $d.Notes))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					$sortedF | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Delimiter ';' -Force

					$enc = { param ($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
					$fRows = foreach ($f in $sortedF)
					{
						$cls = switch ($f.Severity) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { '' } }
						"<tr><td class='$cls'>$($f.Severity)</td><td>$(& $enc $f.Category)</td><td>$(& $enc $f.Database)</td><td>$(& $enc $f.Message)</td><td>$(& $enc $f.Hint)</td></tr>"
					}
					$dRows = foreach ($d in $sortedD)
					{
						$cls = switch ($d.Status) { 'Critical' { 'crit' } 'Warning' { 'warn' } 'OK' { 'ok' } default { '' } }
						"<tr><td class='$cls'>$($d.Status)</td><td>$(& $enc $d.Database)</td><td>$($d.LastTdpFull)</td><td>$($d.LastTdpDiff)</td><td>$($d.ConsecutiveFailures)</td><td>$(& $enc $d.Notes)</td></tr>"
					}
					$body = "<p>Job: $(& $enc $JobName) | TdpDir: $(& $enc $TdpDir) | Grenzen: $(& $enc $limitTxt)<br>Gesamt: <b>$overall</b> | Critical: $($cnt.Critical) | Warning: $($cnt.Warning) | Info: $($cnt.Info)</p>"
					$body += "<h2>Befunde</h2>"
					$body += if ($sortedF.Count -gt 0) { "<table><tr><th>Schwere</th><th>Bereich</th><th>Datenbank</th><th>Befund</th><th>Hinweis</th></tr>" + ($fRows -join '') + "</table>" } else { "<p class='ok'>Keine Befunde.</p>" }
					$body += "<h2>Datenbanken</h2><table><tr><th>Status</th><th>Datenbank</th><th>Letztes TDP-Full</th><th>Letztes TDP-Diff</th><th>Fehlversuche</th><th>Hinweise</th></tr>" + ($dRows -join '') + "</table>"
					ConvertTo-sqmHtmlReport -Title "TDP-Backup-Pruefung - $instance" -Subtitle "Erstellt: $timestamp" -BodyHtml $body | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
				}

				$lvl = if ($overall -eq 'OK') { 'INFO' } else { 'WARNING' }
				Invoke-sqmLogging -Message "[$instance] TDP-Backup-Pruefung: $overall (Critical $($cnt.Critical), Warning $($cnt.Warning), Info $($cnt.Info))" -FunctionName $functionName -Level $lvl

				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance   = $instance
						HostName      = $hostName
						Timestamp     = $timestamp
						Status        = $overall
						SqlReachable  = $true
						CriticalCount = $cnt.Critical
						WarningCount  = $cnt.Warning
						InfoCount     = $cnt.Info
						LimitSource   = $limitSource
						MaxFullAgeHours = $maxFullAgeH
						MaxAnyAgeHours  = $maxAnyAgeH
						Findings      = $sortedF
						DatabaseRows  = $sortedD
						TxtFile       = $txtFile
						CsvFile       = $csvFile
						HtmlFile      = $htmlFile
					})
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status      = 'Error'
						Message     = $errMsg
						Findings    = $null
						DatabaseRows = $null
						TxtFile     = $null
						CsvFile     = $null
						HtmlFile    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanz(en) verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}
