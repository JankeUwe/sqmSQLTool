<#
.SYNOPSIS
    Manages Extended Events sessions for performance analysis on SQL Server.

.DESCRIPTION
    Creates, starts, stops, reads and evaluates Extended Events sessions.

    Operating modes (switches, combinable):
      -Create    Creates a new XEvent session based on a template.
      -Start     Starts an existing (or newly created) session.
      -Stop      Stops a running session.
      -Read      Reads events from the XEL ring buffer or a file.
      -Diagnose  Aggregates events and detects patterns (top waits, blocking chains,
                 slow queries, deadlocks).
      -Drop      Removes a session completely (including XEL files).

    If no switch is specified, -Read and -Diagnose are executed.

    Available session templates:
      SlowQueries   sql_statement_completed > threshold (default: 1000 ms)
      Blocking      blocked_process_report
      Waits         wait_info with configurable wait list
      Deadlocks     xml_deadlock_report
      AllInOne      Combines all four templates in one session

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER SessionName
    Name of the XEvent session. Default: 'sqmPerformance'.

.PARAMETER Template
    Session template when creating. Values: SlowQueries, Blocking, Waits, Deadlocks, AllInOne.
    Default: AllInOne.

.PARAMETER SlowQueryThresholdMs
    Minimum execution duration in milliseconds for SlowQueries capture. Default: 1000.

.PARAMETER WaitTypes
    Comma-separated list of wait types for the Waits template.
    Default: LCK_M_X,LCK_M_S,LCK_M_U,PAGEIOLATCH_SH,PAGEIOLATCH_EX,CXPACKET,SOS_SCHEDULER_YIELD

.PARAMETER TargetType
    Target type for event storage: RingBuffer or File. Default: RingBuffer.

.PARAMETER TargetFilePath
    Directory for XEL files (only for TargetType = File).
    Default: from module configuration OutputPath + \XEvents.

.PARAMETER MaxFileSizeMB
    Maximum size of an XEL file (MB). Default: 100.

.PARAMETER MaxRolloverFiles
    Number of XEL rollover files. Default: 5.

.PARAMETER RingBufferMaxMB
    Maximum size of the ring buffer (MB). Default: 50.

.PARAMETER MaxEventsRead
    Maximum number of events when reading. Default: 10000.

.PARAMETER LookbackMinutes
    Time window for diagnostic aggregation in minutes. Default: 60.

.PARAMETER TopN
    Number of top entries in diagnostic tables. Default: 25.

.PARAMETER OutputPath
    Directory for saved reports (CSV + TXT + HTML). Default: from module configuration + \XEvents.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER Create
    Create session.

.PARAMETER Start
    Start session.

.PARAMETER Stop
    Stop session.

.PARAMETER Read
    Read events.

.PARAMETER Diagnose
    Aggregate events and detect issues.

.PARAMETER Drop
    Remove session.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Create AllInOne session and start immediately
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Create -Start

.EXAMPLE
    # Record Slow Queries > 2 seconds, save to file
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Template SlowQueries -SlowQueryThresholdMs 2000 -TargetType File -Create -Start

.EXAMPLE
    # Read running session and create report
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Read -Diagnose

.EXAMPLE
    # Stop session and remove it
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Stop -Drop

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath
    Needs VIEW SERVER STATE on the instance.
    Reading XEL files requires direct access to the SQL Server path.
#>
function Invoke-sqmExtendedEvents
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$SessionName = 'sqmPerformance',
		[Parameter(Mandatory = $false)]
		[ValidateSet('SlowQueries', 'Blocking', 'Waits', 'Deadlocks', 'AllInOne')]
		[string]$Template = 'AllInOne',
		[Parameter(Mandatory = $false)]
		[ValidateRange(100, 3600000)]
		[int]$SlowQueryThresholdMs = 1000,
		[Parameter(Mandatory = $false)]
		[string]$WaitTypes = 'LCK_M_X,LCK_M_S,LCK_M_U,PAGEIOLATCH_SH,PAGEIOLATCH_EX,CXPACKET,SOS_SCHEDULER_YIELD',
		[Parameter(Mandatory = $false)]
		[ValidateSet('RingBuffer', 'File')]
		[string]$TargetType = 'RingBuffer',
		[Parameter(Mandatory = $false)]
		[string]$TargetFilePath,
		[Parameter(Mandatory = $false)]
		[ValidateRange(10, 2048)]
		[int]$MaxFileSizeMB = 100,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$MaxRolloverFiles = 5,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 500)]
		[int]$RingBufferMaxMB = 50,
		[Parameter(Mandatory = $false)]
		[ValidateRange(100, 1000000)]
		[int]$MaxEventsRead = 10000,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 525600)]
		[int]$LookbackMinutes = 60,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 500)]
		[int]$TopN = 25,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,

		# --- Aktions-Switches ---
		[Parameter(Mandatory = $false)]
		[switch]$Create,
		[Parameter(Mandatory = $false)]
		[switch]$Start,
		[Parameter(Mandatory = $false)]
		[switch]$Stop,
		[Parameter(Mandatory = $false)]
		[switch]$Read,
		[Parameter(Mandatory = $false)]
		[switch]$Diagnose,
		[Parameter(Mandatory = $false)]
		[switch]$Drop,

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
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Wenn kein Aktions-Switch gesetzt: Read + Diagnose
		$noActionSwitch = -not ($Create -or $Start -or $Stop -or $Read -or $Diagnose -or $Drop)
		$runRead    = $Read    -or $noActionSwitch
		$runDiagnose = $Diagnose -or $noActionSwitch

		# OutputPath / TargetFilePath aufloesen
		if (-not $OutputPath)    { $OutputPath     = Join-Path (Get-sqmDefaultOutputPath) 'XEvents' }
		if (-not $TargetFilePath){ $TargetFilePath  = Join-Path (Get-sqmDefaultOutputPath) 'XEvents' }

		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$result = [PSCustomObject]@{
			SqlInstance    = $SqlInstance
			SessionName    = $SessionName
			Template       = $Template
			SessionStatus  = $null
			CreateStatus   = $null
			StartStatus    = $null
			StopStatus     = $null
			DropStatus     = $null
			Events         = @()
			EventCount     = 0
			Diagnose       = $null
			ReportFile     = $null
			HtmlFile       = $null
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance  - Session '$SessionName' (Template=$Template, TargetType=$TargetType)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# =================================================================
			# Hilfsfunktion: Wait-Type-Filter-SQL bauen
			# =================================================================
			$waitFilter = ($WaitTypes -split ',' | ForEach-Object {
					"N'$($_.Trim())'"
				}) -join ','

			# =================================================================
			# CREATE
			# =================================================================
			if ($Create -and $PSCmdlet.ShouldProcess($SqlInstance, "XEvent-Session '$SessionName' erstellen (Template: $Template)"))
			{
				Invoke-sqmLogging -Message "Erstelle XEvent-Session '$SessionName' (Template=$Template, Target=$TargetType)..." -FunctionName $functionName -Level "INFO"

				# --- Event-Definitionen je Template ---
				$eventBlock = switch ($Template)
				{
					'SlowQueries' {
						$thresholdMicro = $SlowQueryThresholdMs * 1000
						@"
    ADD EVENT sqlserver.sql_statement_completed (
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.username,
                sqlserver.client_app_name, sqlserver.client_hostname,
                sqlserver.request_id, sqlserver.session_id, sqlserver.plan_handle)
        WHERE (duration >= $thresholdMicro
           AND sqlserver.is_system = 0)
    ),
    ADD EVENT sqlserver.rpc_completed (
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.username,
                sqlserver.client_app_name, sqlserver.client_hostname,
                sqlserver.session_id)
        WHERE (duration >= $thresholdMicro
           AND sqlserver.is_system = 0)
    )
"@
					}
					'Blocking'   {
						@"
    ADD EVENT sqlserver.blocked_process_report (
        ACTION (sqlserver.sql_text, sqlserver.database_name,
                sqlserver.session_id, sqlserver.username)
    )
"@
					}
					'Waits'      {
						@"
    ADD EVENT sqlos.wait_info (
        ACTION (sqlserver.sql_text, sqlserver.session_id,
                sqlserver.database_name, sqlserver.username)
        WHERE (wait_type IN ($waitFilter)
           AND duration   > 0
           AND opcode     = 1)
    )
"@
					}
					'Deadlocks'  {
						@"
    ADD EVENT sqlserver.xml_deadlock_report (
        ACTION (sqlserver.database_name)
    )
"@
					}
					'AllInOne'   {
						$thresholdMicro = $SlowQueryThresholdMs * 1000
						@"
    ADD EVENT sqlserver.sql_statement_completed (
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.username,
                sqlserver.client_app_name, sqlserver.client_hostname,
                sqlserver.session_id, sqlserver.plan_handle)
        WHERE (duration >= $thresholdMicro
           AND sqlserver.is_system = 0)
    ),
    ADD EVENT sqlserver.rpc_completed (
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.username,
                sqlserver.client_app_name, sqlserver.session_id)
        WHERE (duration >= $thresholdMicro
           AND sqlserver.is_system = 0)
    ),
    ADD EVENT sqlserver.blocked_process_report (
        ACTION (sqlserver.sql_text, sqlserver.database_name,
                sqlserver.session_id, sqlserver.username)
    ),
    ADD EVENT sqlos.wait_info (
        ACTION (sqlserver.sql_text, sqlserver.session_id, sqlserver.database_name)
        WHERE (wait_type IN ($waitFilter)
           AND duration   > 0
           AND opcode     = 1)
    ),
    ADD EVENT sqlserver.xml_deadlock_report (
        ACTION (sqlserver.database_name)
    )
"@
					}
				}

				# --- Target-Definition ---
				$targetBlock = if ($TargetType -eq 'File')
				{
					$xelPattern = "$($TargetFilePath.TrimEnd('\'))\$SessionName"
					@"
    ADD TARGET package0.event_file (
        SET filename        = N'$xelPattern.xel',
            max_file_size   = $MaxFileSizeMB,
            max_rollover_files = $MaxRolloverFiles
    )
"@
				}
				else
				{
					# max_memory des ring_buffer-Ziels wird in KB angegeben, nicht in Bytes.
					$maxMemoryKb = $RingBufferMaxMB * 1024
					@"
    ADD TARGET package0.ring_buffer (
        SET max_memory = $maxMemoryKb
    )
"@
				}

				$createSql = @"
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'$SessionName')
    DROP EVENT SESSION [$SessionName] ON SERVER;

CREATE EVENT SESSION [$SessionName] ON SERVER
$eventBlock
$targetBlock
WITH (
    MAX_MEMORY              = 4096 KB,
    EVENT_RETENTION_MODE    = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY    = 5 SECONDS,
    STARTUP_STATE           = OFF
);
"@

				try
				{
					Invoke-DbaQuery @connParams -Database master -Query $createSql -ErrorAction Stop
					$result.CreateStatus = 'Success'
					Invoke-sqmLogging -Message "Session '$SessionName' erfolgreich erstellt." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$result.CreateStatus = "Failed: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "Session '$SessionName' erstellen fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
				}
			}

			# =================================================================
			# START
			# =================================================================
			if ($Start -and $PSCmdlet.ShouldProcess($SqlInstance, "XEvent-Session '$SessionName' starten"))
			{
				try
				{
					$startSql = "ALTER EVENT SESSION [$SessionName] ON SERVER STATE = START;"
					Invoke-DbaQuery @connParams -Database master -Query $startSql -ErrorAction Stop
					$result.StartStatus = 'Running'
					Invoke-sqmLogging -Message "Session '$SessionName' gestartet." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$result.StartStatus = "Failed: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "Session '$SessionName' starten fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
				}
			}

			# =================================================================
			# STOP
			# =================================================================
			if ($Stop -and $PSCmdlet.ShouldProcess($SqlInstance, "XEvent-Session '$SessionName' stoppen"))
			{
				try
				{
					$stopSql = "ALTER EVENT SESSION [$SessionName] ON SERVER STATE = STOP;"
					Invoke-DbaQuery @connParams -Database master -Query $stopSql -ErrorAction Stop
					$result.StopStatus = 'Stopped'
					Invoke-sqmLogging -Message "Session '$SessionName' gestoppt." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$result.StopStatus = "Failed: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "Session '$SessionName' stoppen fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
				}
			}

			# =================================================================
			# SESSION-STATUS abfragen (immer)
			# =================================================================
			try
			{
				$statusSql = @"
SELECT
    s.name                                              AS SessionName,
    CASE WHEN ds.create_time IS NULL THEN 'Stopped' ELSE 'Running' END AS SessionState,
    ds.create_time                                      AS StartedAt,
    t.target_name                                       AS TargetType,
    CAST(t.target_data AS XML)                          AS TargetDataXml,
    (SELECT SUM(CAST(f.column_value AS BIGINT))
     FROM sys.dm_xe_session_object_columns f
     WHERE f.event_session_address = ds.address
       AND f.column_name = 'event_count')               AS ApproxEventCount
FROM sys.server_event_sessions s
LEFT JOIN sys.dm_xe_sessions ds
    ON s.name = ds.name
LEFT JOIN sys.dm_xe_session_targets t
    ON ds.address = t.event_session_address
WHERE s.name = N'$SessionName'
"@
				$statusRows = Invoke-DbaQuery @connParams -Database master -Query $statusSql -ErrorAction Stop
				if ($statusRows)
				{
					$result.SessionStatus = $statusRows | Select-Object -First 1 SessionName, SessionState, StartedAt, TargetType, ApproxEventCount
				}
				else
				{
					$result.SessionStatus = [PSCustomObject]@{ SessionName = $SessionName; SessionState = 'NotFound' }
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "Session-Status konnte nicht abgefragt werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
			}

			# =================================================================
			# READ  - Ereignisse aus RingBuffer oder XEL-Datei lesen
			# =================================================================
			if ($runRead)
			{
				Invoke-sqmLogging -Message "Lese Ereignisse aus Session '$SessionName' (max $MaxEventsRead)..." -FunctionName $functionName -Level "INFO"

				$sessionState = if ($result.SessionStatus) { $result.SessionStatus.SessionState } else { $null }
				if ($sessionState -notin @('Running', 'Stopped') -and $sessionState -ne $null)
				{
					Invoke-sqmLogging -Message "Session '$SessionName' nicht gefunden  - kein Read moeglich." -FunctionName $functionName -Level "WARNING"
				}
				else
				{
					try
					{
						# Ziel-Typ der laufenden Session ermitteln
						$targetTypeSql = @"
SELECT t.target_name, t.target_data
FROM sys.dm_xe_sessions s
JOIN sys.dm_xe_session_targets t ON s.address = t.event_session_address
WHERE s.name = N'$SessionName'
"@
						$targetInfo = Invoke-DbaQuery @connParams -Database master -Query $targetTypeSql -ErrorAction SilentlyContinue

						$parsedEvents = [System.Collections.Generic.List[PSCustomObject]]::new()

						if ($targetInfo -and $targetInfo.target_name -eq 'ring_buffer')
						{
							# RingBuffer-XML parsen
							$rbReadSql = @"
SELECT CAST(t.target_data AS XML) AS RingBufferXml
FROM sys.dm_xe_sessions s
JOIN sys.dm_xe_session_targets t ON s.address = t.event_session_address
WHERE s.name = N'$SessionName'
  AND t.target_name = 'ring_buffer'
"@
							$rbRow = Invoke-DbaQuery @connParams -Database master -Query $rbReadSql -ErrorAction Stop
							if ($rbRow -and $rbRow.RingBufferXml)
							{
								[xml]$rbXml = $rbRow.RingBufferXml
								$eventNodes = $rbXml.RingBufferTarget.event | Select-Object -First $MaxEventsRead
								foreach ($evNode in $eventNodes)
								{
									$ev = [PSCustomObject]@{
										EventName    = $evNode.name
										Timestamp    = $evNode.timestamp
										DatabaseName = ($evNode.action | Where-Object { $_.name -eq 'database_name' }).value
										Username     = ($evNode.action | Where-Object { $_.name -eq 'username' }).value
										SessionId    = ($evNode.action | Where-Object { $_.name -eq 'session_id' }).value
										ClientApp    = ($evNode.action | Where-Object { $_.name -eq 'client_app_name' }).value
										ClientHost   = ($evNode.action | Where-Object { $_.name -eq 'client_hostname' }).value
										DurationMs   = [math]::Round(
											[double](($evNode.data | Where-Object { $_.name -eq 'duration' }).value) / 1000.0, 2)
										WaitType     = ($evNode.data | Where-Object { $_.name -eq 'wait_type' }).text
										SqlText      = ($evNode.action | Where-Object { $_.name -eq 'sql_text' }).value
										DeadlockXml  = ($evNode.data | Where-Object { $_.name -eq 'xml_report' }).value
										RowsAffected = ($evNode.data | Where-Object { $_.name -eq 'row_count' }).value
										PhysicalReads = ($evNode.data | Where-Object { $_.name -eq 'physical_reads' }).value
										LogicalReads  = ($evNode.data | Where-Object { $_.name -eq 'logical_reads' }).value
										Writes        = ($evNode.data | Where-Object { $_.name -eq 'writes' }).value
										CpuTime       = ($evNode.data | Where-Object { $_.name -eq 'cpu_time' }).value
									}
									$parsedEvents.Add($ev)
								}
							}
						}
						elseif ($targetInfo -and $targetInfo.target_name -eq 'event_file')
						{
							# XEL-Datei-Pfad aus sys.server_event_sessions lesen
							$xelPathSql = @"
SELECT f.value AS XelPath
FROM sys.server_event_sessions s
JOIN sys.server_event_session_targets t ON s.event_session_id = t.event_session_id
CROSS APPLY (
    SELECT c.value
    FROM sys.server_event_session_fields c
    WHERE c.event_session_id = s.event_session_id
      AND c.object_id       = t.target_id
      AND c.name            = 'filename'
) f
WHERE s.name = N'$SessionName'
"@
							$xelPathRow = Invoke-DbaQuery @connParams -Database master -Query $xelPathSql -ErrorAction SilentlyContinue
							if ($xelPathRow -and $xelPathRow.XelPath)
							{
								$xelPattern = $xelPathRow.XelPath -replace '\.xel$', '*.xel'
								$readXelSql = @"
SELECT TOP ($MaxEventsRead)
    object_name                                     AS EventName,
    CAST(event_data AS XML)                         AS EventXml,
    file_name                                       AS SourceFile,
    file_offset                                     AS FileOffset
FROM sys.fn_xe_file_target_read_file(N'$xelPattern', NULL, NULL, NULL)
ORDER BY file_offset DESC
"@
								$xelRows = Invoke-DbaQuery @connParams -Database master -Query $readXelSql -ErrorAction Stop
								foreach ($xelRow in $xelRows)
								{
									try
									{
										[xml]$evXml = $xelRow.EventXml
										$evData = $evXml.event
										$getVal = { param($name)
											$node = $evData.data | Where-Object { $_.name -eq $name }
											if ($node) { $node.value } else { $null }
										}
										$getAct = { param($name)
											$node = $evData.action | Where-Object { $_.name -eq $name }
											if ($node) { $node.value } else { $null }
										}
										$dur = & $getVal 'duration'
										$parsedEvents.Add([PSCustomObject]@{
											EventName     = $xelRow.EventName
											Timestamp     = $evData.timestamp
											DatabaseName  = & $getAct 'database_name'
											Username      = & $getAct 'username'
											SessionId     = & $getAct 'session_id'
											ClientApp     = & $getAct 'client_app_name'
											ClientHost    = & $getAct 'client_hostname'
											DurationMs    = if ($dur) { [math]::Round([double]$dur / 1000.0, 2) } else { $null }
											WaitType      = ($evData.data | Where-Object { $_.name -eq 'wait_type' }).text
											SqlText       = & $getAct 'sql_text'
											DeadlockXml   = & $getVal 'xml_report'
											RowsAffected  = & $getVal 'row_count'
											PhysicalReads = & $getVal 'physical_reads'
											LogicalReads  = & $getVal 'logical_reads'
											Writes        = & $getVal 'writes'
											CpuTime       = & $getVal 'cpu_time'
											SourceFile    = $xelRow.SourceFile
										})
									}
									catch { }
								}
							}
						}

						$result.Events     = $parsedEvents.ToArray()
						$result.EventCount = $parsedEvents.Count
						Invoke-sqmLogging -Message "$($parsedEvents.Count) Ereignisse gelesen." -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						Invoke-sqmLogging -Message "Fehler beim Lesen der Ereignisse: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
					}
				}
			}

			# =================================================================
			# DIAGNOSE  - Ereignisse aggregieren und Muster erkennen
			# =================================================================
			if ($runDiagnose -and $result.Events.Count -gt 0)
			{
				Invoke-sqmLogging -Message "Starte Diagnose ($($result.Events.Count) Ereignisse, Fenster: ${LookbackMinutes} Min)..." -FunctionName $functionName -Level "INFO"

				$cutoff = (Get-Date).AddMinutes(-$LookbackMinutes)
				$window = $result.Events | Where-Object {
					# $ts muss typisiert sein, sonst bindet [ref] nicht an die TryParse-Ueberladung.
					$ts = [datetime]::MinValue
					if ($_.Timestamp -and [datetime]::TryParse($_.Timestamp, [ref]$ts)) { $ts -ge $cutoff } else { $true }
				}

				$diagnoseResult = [PSCustomObject]@{
					TopSlowQueries    = @()
					TopWaits          = @()
					BlockingEvents    = @()
					DeadlockEvents    = @()
					IssueCount        = 0
					Issues            = @()
				}

				$issues = [System.Collections.Generic.List[PSCustomObject]]::new()

				# D1: Top Slow Queries
				$slowEvts = $window | Where-Object { $_.EventName -in @('sql_statement_completed','rpc_completed') -and $_.DurationMs -gt 0 }
				if ($slowEvts)
				{
					$topSlow = $slowEvts |
						Group-Object SqlText |
						ForEach-Object {
							$durs = $_.Group | ForEach-Object { [double]$_.DurationMs }
							[PSCustomObject]@{
								SqlText       = ($_.Name -replace '\s+', ' ').Trim() | ForEach-Object { $_.Substring(0, [Math]::Min(300, $_.Length)) }
								ExecCount     = $_.Count
								AvgDurationMs = [math]::Round(($durs | Measure-Object -Average).Average, 2)
								MaxDurationMs = [math]::Round(($durs | Measure-Object -Maximum).Maximum, 2)
								TotalDurationMs = [math]::Round(($durs | Measure-Object -Sum).Sum, 2)
								DatabaseName  = ($_.Group | Select-Object -First 1).DatabaseName
							}
						} |
						Sort-Object AvgDurationMs -Descending |
						Select-Object -First $TopN
					$diagnoseResult.TopSlowQueries = @($topSlow)

					$verySlowCount = @($slowEvts | Where-Object { $_.DurationMs -ge ($SlowQueryThresholdMs * 10) }).Count
					if ($verySlowCount -gt 0)
					{
						$issues.Add([PSCustomObject]@{
							Severity    = 'Warning'
							Category    = 'VerySlowQueries'
							Description = "$verySlowCount Queries mit Dauer >= $($SlowQueryThresholdMs * 10) ms im Auswertungsfenster"
							Detail      = "Top: $($topSlow[0].SqlText.Substring(0, [Math]::Min(200, $topSlow[0].SqlText.Length))) [Avg: $($topSlow[0].AvgDurationMs) ms]"
						})
					}
				}

				# D2: Top Wait Types
				$waitEvts = $window | Where-Object { $_.EventName -eq 'wait_info' -and $_.WaitType }
				if ($waitEvts)
				{
					$topWaits = $waitEvts |
						Group-Object WaitType |
						ForEach-Object {
							$durs = $_.Group | ForEach-Object { [double]$_.DurationMs }
							[PSCustomObject]@{
								WaitType       = $_.Name
								WaitCount      = $_.Count
								TotalWaitMs    = [math]::Round(($durs | Measure-Object -Sum).Sum, 2)
								AvgWaitMs      = [math]::Round(($durs | Measure-Object -Average).Average, 2)
								MaxWaitMs      = [math]::Round(($durs | Measure-Object -Maximum).Maximum, 2)
							}
						} |
						Sort-Object TotalWaitMs -Descending |
						Select-Object -First $TopN
					$diagnoseResult.TopWaits = @($topWaits)

					# Lock-dominanz erkennen
					$lockWaits = $topWaits | Where-Object { $_.WaitType -like 'LCK_*' }
					if ($lockWaits)
					{
						$lockTotal = ($lockWaits | Measure-Object TotalWaitMs -Sum).Sum
						if ($lockTotal -gt 5000)
						{
							$issues.Add([PSCustomObject]@{
								Severity    = if ($lockTotal -gt 60000) { 'Critical' } else { 'Warning' }
								Category    = 'LockContention'
								Description = "Lock-Waits: $([math]::Round($lockTotal/1000,1)) Sek gesamt im Auswertungsfenster"
								Detail      = ($lockWaits | ForEach-Object { "$($_.WaitType): $($_.WaitCount)x / $($_.TotalWaitMs) ms" }) -join '; '
							})
						}
					}

					# CXPACKET / Parallelismus
					$cxp = $topWaits | Where-Object { $_.WaitType -eq 'CXPACKET' }
					if ($cxp -and $cxp.WaitCount -gt 100)
					{
						$issues.Add([PSCustomObject]@{
							Severity    = 'Warning'
							Category    = 'ParallelismPressure'
							Description = "CXPACKET: $($cxp.WaitCount) Waits / $([math]::Round($cxp.TotalWaitMs/1000,1)) Sek gesamt  - moeglicher uebermassiger Parallelismus"
							Detail      = "MAXDOP oder Cost Threshold for Parallelism pruefen."
						})
					}
				}

				# D3: Blocking-Ereignisse
				$blockEvts = $window | Where-Object { $_.EventName -eq 'blocked_process_report' }
				if ($blockEvts)
				{
					$diagnoseResult.BlockingEvents = @($blockEvts | Select-Object Timestamp, DatabaseName, DurationMs, SqlText, Username | Sort-Object DurationMs -Descending | Select-Object -First $TopN)
					$issues.Add([PSCustomObject]@{
						Severity    = if ($blockEvts.Count -gt 10) { 'Critical' } else { 'Warning' }
						Category    = 'Blocking'
						Description = "$($blockEvts.Count) Blocking-Ereignis(se) erfasst"
						Detail      = "Maximale Blockierungsdauer: $([math]::Round(($blockEvts | Measure-Object DurationMs -Maximum).Maximum, 2)) ms"
					})
				}

				# D4: Deadlocks
				$deadlockEvts = $window | Where-Object { $_.EventName -eq 'xml_deadlock_report' }
				if ($deadlockEvts)
				{
					$diagnoseResult.DeadlockEvents = @($deadlockEvts | Select-Object Timestamp, DatabaseName, DeadlockXml)
					$issues.Add([PSCustomObject]@{
						Severity    = 'Critical'
						Category    = 'Deadlock'
						Description = "$($deadlockEvts.Count) Deadlock(s) erfasst"
						Detail      = "Timestamps: $(($deadlockEvts | ForEach-Object { $_.Timestamp }) -join ', ')"
					})
				}

				$diagnoseResult.Issues     = $issues.ToArray()
				$diagnoseResult.IssueCount = $issues.Count
				$result.Diagnose = $diagnoseResult

				$critCount = @($issues | Where-Object { $_.Severity -eq 'Critical' }).Count
				$warnCount = @($issues | Where-Object { $_.Severity -eq 'Warning' }).Count
				Invoke-sqmLogging -Message "Diagnose abgeschlossen: $critCount Critical, $warnCount Warning." -FunctionName $functionName -Level "INFO"
			}

			# =================================================================
			# BERICHT SPEICHERN
			# =================================================================
			if ($result.EventCount -gt 0 -or ($result.Diagnose -and $result.Diagnose.IssueCount -gt 0))
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

				$safeInst  = $SqlInstance -replace '[\\/:<>|]', '_'
				$safeSess  = $SessionName -replace '[\\/:<>|]', '_'
				$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
				$baseFile  = Join-Path $OutputPath "XE_${safeInst}_${safeSess}_${timestamp}"

				# Rohdaten (Ereignisse) als CSV
				if ($result.EventCount -gt 0)
				{
					$csvFile = "${baseFile}_Events.csv"
					$result.Events | Select-Object EventName, Timestamp, DatabaseName, Username,
						SessionId, ClientApp, ClientHost, DurationMs, WaitType,
						LogicalReads, PhysicalReads, Writes, CpuTime, RowsAffected,
						@{ N = 'SqlText'; E = { if ($_.SqlText) { $_.SqlText.ToString().Substring(0, [Math]::Min(500, $_.SqlText.ToString().Length)) } } } |
						Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
					Invoke-sqmLogging -Message "Ereignisse gespeichert: $csvFile" -FunctionName $functionName -Level "INFO"
				}

				# Diagnose-Bericht als TXT
				if ($result.Diagnose)
				{
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("=" * 70)
					$lines.Add("  EXTENDED EVENTS DIAGNOSE  - $SqlInstance  |  Session: $SessionName")
					$lines.Add("  Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
					$lines.Add("  Erfasste Ereignisse: $($result.EventCount)  |  Auswertungsfenster: ${LookbackMinutes} Min")
					$lines.Add("=" * 70)
					$lines.Add("")

					if ($result.Diagnose.Issues.Count -gt 0)
					{
						$lines.Add("ERKANNTE PROBLEME ($($result.Diagnose.IssueCount)):")
						$lines.Add("-" * 50)
						$grouped = $result.Diagnose.Issues | Group-Object Severity | Sort-Object { if ($_.Name -eq 'Critical') { 0 } else { 1 } }
						foreach ($grp in $grouped)
						{
							foreach ($issue in $grp.Group)
							{
								$lines.Add("  [$($grp.Name.ToUpper())] $($issue.Category): $($issue.Description)")
								if ($issue.Detail) { $lines.Add("         $($issue.Detail.Substring(0, [Math]::Min(200, $issue.Detail.Length)))") }
							}
						}
						$lines.Add("")
					}

					if ($result.Diagnose.TopSlowQueries.Count -gt 0)
					{
						$lines.Add("TOP $TopN SLOW QUERIES (nach Avg-Dauer):")
						$lines.Add("-" * 50)
						$rank = 1
						foreach ($sq in $result.Diagnose.TopSlowQueries)
						{
							$txt = if ($sq.SqlText) { $sq.SqlText.Substring(0, [Math]::Min(120, $sq.SqlText.Length)) } else { '(n/a)' }
							$lines.Add("  $rank. Avg: $($sq.AvgDurationMs) ms | Max: $($sq.MaxDurationMs) ms | Count: $($sq.ExecCount) | DB: $($sq.DatabaseName)")
							$lines.Add("     $txt")
							$rank++
						}
						$lines.Add("")
					}

					if ($result.Diagnose.TopWaits.Count -gt 0)
					{
						$lines.Add("TOP $TopN WAIT TYPES (nach Total-Wartezeit):")
						$lines.Add("-" * 50)
						foreach ($wt in $result.Diagnose.TopWaits)
						{
							$lines.Add("  $($wt.WaitType.PadRight(30)) Count: $($wt.WaitCount.ToString().PadLeft(6))  Total: $([math]::Round($wt.TotalWaitMs/1000,2)) Sek  Avg: $($wt.AvgWaitMs) ms  Max: $($wt.MaxWaitMs) ms")
						}
						$lines.Add("")
					}

					if ($result.Diagnose.BlockingEvents.Count -gt 0)
					{
						$lines.Add("BLOCKING-EREIGNISSE ($($result.Diagnose.BlockingEvents.Count)):")
						$lines.Add("-" * 50)
						foreach ($bl in $result.Diagnose.BlockingEvents | Select-Object -First 10)
						{
							$lines.Add("  [$($bl.Timestamp)] $($bl.DatabaseName) | $($bl.DurationMs) ms | $($bl.Username)")
						}
						$lines.Add("")
					}

					if ($result.Diagnose.DeadlockEvents.Count -gt 0)
					{
						$lines.Add("DEADLOCK-EREIGNISSE ($($result.Diagnose.DeadlockEvents.Count)):")
						$lines.Add("-" * 50)
						foreach ($dl in $result.Diagnose.DeadlockEvents)
						{
							$lines.Add("  [$($dl.Timestamp)] $($dl.DatabaseName)")
							if ($dl.DeadlockXml)
							{
								$dlFile = "${baseFile}_Deadlock_$($dl.Timestamp -replace '[:\s]', '_').xml"
								$dl.DeadlockXml | Out-File -FilePath $dlFile -Encoding UTF8 -Force
								$lines.Add("  Deadlock-XML gespeichert: $dlFile")
							}
						}
						$lines.Add("")
					}

					$txtFile = "${baseFile}_Report.txt"
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$result.ReportFile = $txtFile
					Invoke-sqmLogging -Message "Diagnose-Bericht gespeichert: $txtFile" -FunctionName $functionName -Level "INFO"

					# Top-Slow-Queries als eigene CSV
					if ($result.Diagnose.TopSlowQueries.Count -gt 0)
					{
						$slowCsv = "${baseFile}_TopSlowQueries.csv"
						$result.Diagnose.TopSlowQueries | Export-Csv -Path $slowCsv -NoTypeInformation -Encoding UTF8 -Force
					}

					# Top-Waits als eigene CSV
					if ($result.Diagnose.TopWaits.Count -gt 0)
					{
						$waitCsv = "${baseFile}_TopWaits.csv"
						$result.Diagnose.TopWaits | Export-Csv -Path $waitCsv -NoTypeInformation -Encoding UTF8 -Force
					}
				}

				# -------------------------------------------------------------
				# HTML-BERICHT  - Issues + Top-Slow-Queries + Top-Waits
				# -------------------------------------------------------------
				$enc  = { param ($t) if ($null -eq $t) { '' } else { [string]$t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' } }
				$body = [System.Text.StringBuilder]::new()

				if ($result.Diagnose -and $result.Diagnose.Issues.Count -gt 0)
				{
					[void]$body.AppendLine("<h2>Erkannte Probleme ($($result.Diagnose.IssueCount))</h2>")
					[void]$body.AppendLine('<table><tr><th>Severity</th><th>Kategorie</th><th>Problem</th><th>Detail</th></tr>')
					$sorted = $result.Diagnose.Issues | Sort-Object { if ($_.Severity -eq 'Critical') { 0 } else { 1 } }
					foreach ($issue in $sorted)
					{
						$cls = if ($issue.Severity -eq 'Critical') { 'crit' } else { 'warn' }
						[void]$body.AppendLine(("<tr><td class='{0}'>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>" -f
								$cls, (& $enc $issue.Severity), (& $enc $issue.Category),
								(& $enc $issue.Description), (& $enc $issue.Detail)))
					}
					[void]$body.AppendLine('</table>')
				}

				if ($result.Diagnose -and $result.Diagnose.TopSlowQueries.Count -gt 0)
				{
					[void]$body.AppendLine("<h2>Top $TopN langsamste Queries</h2>")
					[void]$body.AppendLine(($result.Diagnose.TopSlowQueries |
							ConvertTo-Html -Fragment -As Table | Out-String))
				}

				if ($result.Diagnose -and $result.Diagnose.TopWaits.Count -gt 0)
				{
					[void]$body.AppendLine("<h2>Top $TopN Wait-Typen</h2>")
					[void]$body.AppendLine(($result.Diagnose.TopWaits |
							ConvertTo-Html -Fragment -As Table | Out-String))
				}

				if ($body.Length -gt 0)
				{
					$htmlFile = "${baseFile}_Report.html"
					$subtitle = "Instanz: $SqlInstance  |  Session: $SessionName  |  Template: $Template  |  $($result.EventCount) Ereignis(se), Fenster ${LookbackMinutes} Min"
					ConvertTo-sqmHtmlReport -Title "Extended Events Report - $SqlInstance" -Subtitle $subtitle -BodyHtml $body.ToString() |
					Out-File -FilePath $htmlFile -Encoding UTF8 -Force
					$result.HtmlFile = $htmlFile
					Invoke-sqmLogging -Message "HTML-Report gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
					Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
				}
			}

			# =================================================================
			# DROP
			# =================================================================
			if ($Drop -and $PSCmdlet.ShouldProcess($SqlInstance, "XEvent-Session '$SessionName' entfernen"))
			{
				try
				{
					$dropSql = @"
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'$SessionName')
BEGIN
    ALTER EVENT SESSION [$SessionName] ON SERVER STATE = STOP;
    DROP EVENT SESSION [$SessionName] ON SERVER;
END
"@
					Invoke-DbaQuery @connParams -Database master -Query $dropSql -ErrorAction Stop
					$result.DropStatus = 'Dropped'
					Invoke-sqmLogging -Message "Session '$SessionName' entfernt." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$result.DropStatus = "Failed: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "Session '$SessionName' entfernen fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
				}
			}
		}
		catch
		{
			$errMsg = "Schwerwiegender Fehler in $functionName : $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}

		return $result
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}
