<#
.SYNOPSIS
    Shows currently active/blocked SQL Server sessions, similar to Adam Machanic's
    sp_whoisactive - optionally repeated every X seconds like a live monitor.

.DESCRIPTION
    Reads sys.dm_exec_sessions, sys.dm_exec_requests, sys.dm_exec_sql_text and
    sys.dm_db_session_space_usage and returns one row per relevant session: SPID,
    login/host/program, database, status, blocking SPID, wait info, elapsed time,
    CPU/reads/writes, tempdb allocation and the running (or last) SQL statement.

    Unlike sp_whoisactive this does not require installing a stored procedure on the
    target instance - everything is built from DMVs available on every SQL Server
    2012+ instance.

    With -RepeatIntervalSeconds the query re-runs on an interval (like sp_whoisactive's
    @sleep_time, but driven from the client side) until -RepeatCount iterations or
    -DurationMinutes elapse, or the user cancels with Ctrl+C. Each iteration is printed
    to the console as a live-refreshing table unless -NoConsoleOutput is used. All
    iterations are collected and written out as one CSV (full detail) and one HTML
    report (last snapshot) at the end - including when the loop is cancelled early.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER ShowSleepingSpids
    Mirrors sp_whoisactive's @show_sleeping_spids:
      0 = only sessions with an active request
      1 = active requests plus idle sessions with an open transaction (default)
      2 = all user sessions, including fully idle ones

.PARAMETER MinElapsedSeconds
    Only report sessions whose current request (or last batch) has been running/idle
    for at least this many seconds. Default: 0 (no filter).

.PARAMETER RepeatIntervalSeconds
    Seconds to wait between snapshots. Default: 0 (run once, no repeat).

.PARAMETER RepeatCount
    Number of snapshots to take when repeating. Default: 0 = repeat indefinitely
    (until -DurationMinutes elapses or the user presses Ctrl+C). Ignored when
    -RepeatIntervalSeconds is 0.

.PARAMETER DurationMinutes
    Stop repeating after this many minutes have elapsed. Default: 0 = unlimited.

.PARAMETER OutputPath
    Directory for the CSV/HTML report. Default: <OutputPath config>\WhoIsActive.

.PARAMETER NoConsoleOutput
    Suppress the live table printed to the console after every snapshot. Useful for
    unattended/Agent job runs where only the CSV/HTML report matters.

.PARAMETER NoOpen
    Suppress automatic opening of the HTML report.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.EXAMPLE
    Get-sqmWhoIsActive -SqlInstance "SQL01"
    # Single snapshot, like running sp_whoisactive once.

.EXAMPLE
    Get-sqmWhoIsActive -SqlInstance "SQL01" -RepeatIntervalSeconds 5
    # Refreshes every 5 seconds until Ctrl+C - a live "who is active" monitor.

.EXAMPLE
    Get-sqmWhoIsActive -SqlInstance "SQL01" -RepeatIntervalSeconds 10 -RepeatCount 30 -MinElapsedSeconds 5
    # 30 snapshots (5 minutes), only sessions running/idle-in-tran for 5+ seconds.

.EXAMPLE
    Get-sqmWhoIsActive -SqlInstance "SQL01" -RepeatIntervalSeconds 30 -DurationMinutes 60 -NoConsoleOutput
    # Unattended capture for an Agent job: 30-second snapshots for one hour, no console output.

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE on the instance.
    SQL text is resolved via sys.dm_exec_sql_text (statement level via
    statement_start/end_offset for active requests, last batch otherwise).
#>
function Get-sqmWhoIsActive
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateSet(0, 1, 2)]
		[int]$ShowSleepingSpids = 1,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 86400)]
		[int]$MinElapsedSeconds = 0,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 3600)]
		[int]$RepeatIntervalSeconds = 0,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 100000)]
		[int]$RepeatCount = 0,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$DurationMinutes = 0,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'WhoIsActive'),
		[Parameter(Mandatory = $false)]
		[switch]$NoConsoleOutput,
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
			$msg = "dbatools module not found. Install it first: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		Invoke-sqmLogging -Message "Starting $functionName on $SqlInstance (ShowSleepingSpids=$ShowSleepingSpids, RepeatIntervalSeconds=$RepeatIntervalSeconds, RepeatCount=$RepeatCount)" `
			-FunctionName $functionName -Level "INFO"
	}

	process
	{
		$allSnapshots = [System.Collections.Generic.List[PSCustomObject]]::new()
		$lastSnapshotRows = @()
		$iteration = 0
		$loopStart = Get-Date
		$csvFile = $null
		$htmlFile = $null

		try
		{
			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database	  = 'master'
				ErrorAction   = 'Stop'
			}

			# -----------------------------------------------------------------------
			# Sleeping-Filter analog sp_whoisactive @show_sleeping_spids.
			# Aliase (z.B. ElapsedSeconds) sind in WHERE nicht verfuegbar, daher wird
			# der DATEDIFF-Ausdruck fuer den MinElapsedSeconds-Filter wiederholt.
			# -----------------------------------------------------------------------
			$sleepingFilter = switch ($ShowSleepingSpids)
			{
				0 { "AND r.session_id IS NOT NULL" }
				1 { "AND (r.session_id IS NOT NULL OR s.open_transaction_count > 0)" }
				2 { "" }
			}
			$elapsedFilter = if ($MinElapsedSeconds -gt 0)
			{
				"AND DATEDIFF(SECOND, COALESCE(r.start_time, s.last_request_start_time), SYSDATETIME()) >= $MinElapsedSeconds"
			}
			else { "" }

			$whoIsActiveQuery = @"
SELECT
    s.session_id                                                     AS SessionId,
    r.request_id                                                     AS RequestId,
    s.login_name                                                     AS LoginName,
    s.host_name                                                      AS HostName,
    s.program_name                                                   AS ProgramName,
    DB_NAME(COALESCE(r.database_id, s.database_id))                  AS DatabaseName,
    COALESCE(r.status, s.status)                                     AS Status,
    r.command                                                        AS Command,
    r.blocking_session_id                                            AS BlockingSessionId,
    r.wait_type                                                      AS WaitType,
    r.wait_time                                                      AS WaitTimeMs,
    r.wait_resource                                                  AS WaitResource,
    CASE WHEN r.wait_type IS NOT NULL THEN
        r.wait_type + ' (' + CAST(r.wait_time AS VARCHAR(20)) + ' ms)' +
        CASE WHEN r.blocking_session_id > 0
             THEN ' blocked by ' + CAST(r.blocking_session_id AS VARCHAR(10))
             ELSE ''
        END
    ELSE NULL END                                                    AS WaitInfo,
    COALESCE(r.open_transaction_count, s.open_transaction_count, 0)  AS OpenTranCount,
    r.percent_complete                                               AS PercentComplete,
    r.start_time                                                     AS RequestStartTime,
    s.login_time                                                     AS LoginTime,
    s.last_request_start_time                                        AS LastRequestStartTime,
    s.last_request_end_time                                          AS LastRequestEndTime,
    DATEDIFF(SECOND, COALESCE(r.start_time, s.last_request_start_time), SYSDATETIME()) AS ElapsedSeconds,
    ISNULL(r.cpu_time, s.cpu_time)                                   AS CpuTimeMs,
    ISNULL(r.reads, s.reads)                                         AS Reads,
    ISNULL(r.writes, s.writes)                                       AS Writes,
    ISNULL(r.logical_reads, s.logical_reads)                         AS LogicalReads,
    CASE WHEN r.granted_query_memory IS NOT NULL
         THEN CAST(r.granted_query_memory * 8.0 / 1024 AS DECIMAL(18,2))
         ELSE NULL END                                               AS GrantedMemoryMB,
    CAST((ISNULL(tdb.user_objects_alloc_page_count, 0)
        + ISNULL(tdb.internal_objects_alloc_page_count, 0)) * 8.0 / 1024 AS DECIMAL(18,2)) AS TempdbAllocMB,
    -- Laufendes Statement (aktiver Request) oder letzter Batch (idle) als Fallback
    COALESCE(
        SUBSTRING(
            st_req.text,
            (r.statement_start_offset / 2) + 1,
            CASE r.statement_end_offset
                WHEN -1 THEN DATALENGTH(st_req.text)
                ELSE r.statement_end_offset
            END / 2 - r.statement_start_offset / 2 + 1
        ),
        st_last.text
    )                                                                 AS SqlText,
    COALESCE(st_req.text, st_last.text)                               AS SqlFullBatch
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r
    ON r.session_id = s.session_id
LEFT JOIN sys.dm_db_session_space_usage tdb
    ON tdb.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st_req
-- Idle-Sessions haben keinen aktiven Request: letzter Batch ueber die Connection
OUTER APPLY (
    SELECT TOP 1 c.most_recent_sql_handle
    FROM sys.dm_exec_connections c
    WHERE c.session_id = s.session_id
    ORDER BY c.connect_time DESC
) c_last
OUTER APPLY sys.dm_exec_sql_text(c_last.most_recent_sql_handle) st_last
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
  $sleepingFilter
  $elapsedFilter
ORDER BY ElapsedSeconds DESC, CpuTimeMs DESC
"@

			do
			{
				$iteration++
				$captureTime = Get-Date

				$rawData = @(Invoke-DbaQuery @connParams -Query $whoIsActiveQuery)

				$rowsThisIteration = foreach ($row in $rawData)
				{
					[PSCustomObject]@{
						Iteration		  = $iteration
						CaptureTime	      = $captureTime
						SessionId		  = $row.SessionId
						RequestId		  = $row.RequestId
						LoginName		  = $row.LoginName
						HostName		  = $row.HostName
						ProgramName	      = $row.ProgramName
						DatabaseName	  = $row.DatabaseName
						Status		      = $row.Status
						Command		      = $row.Command
						# NULL (kein aktiver Blocker) kommt aus SQL als DBNull zurueck - [DBNull]::Value ist in
						# PowerShell wahr (kein $null, kein leerer String), also schlaegt ein einfaches
						# if($row.BlockingSessionId) fehl. '-as [int]' wirft nicht, liefert bei DBNull $null.
						BlockingSessionId = $(
							$bId = $row.BlockingSessionId -as [int]
							if ($null -eq $bId) { 0 } else { $bId }
						)
						WaitInfo		  = $row.WaitInfo
						WaitType		  = $row.WaitType
						WaitTimeMs	      = $row.WaitTimeMs
						OpenTranCount	  = $row.OpenTranCount
						PercentComplete   = $row.PercentComplete
						ElapsedSeconds    = $row.ElapsedSeconds
						CpuTimeMs		  = $row.CpuTimeMs
						Reads			  = $row.Reads
						Writes		      = $row.Writes
						LogicalReads	  = $row.LogicalReads
						GrantedMemoryMB   = $row.GrantedMemoryMB
						TempdbAllocMB	  = $row.TempdbAllocMB
						SqlText		      = if ($row.SqlText) { ($row.SqlText -replace '\s+', ' ').Trim() } else { $null }
						SqlFullBatch	  = $row.SqlFullBatch
					}
				}

				foreach ($r in $rowsThisIteration) { $allSnapshots.Add($r) }
				$lastSnapshotRows = $rowsThisIteration

				if (-not $NoConsoleOutput)
				{
					$header = "=== $functionName - $SqlInstance - Iteration $iteration - $($captureTime.ToString('yyyy-MM-dd HH:mm:ss')) - $($rowsThisIteration.Count) session(s) ==="
					Write-Host $header -ForegroundColor Cyan

					if ($rowsThisIteration.Count -gt 0)
					{
						$rowsThisIteration |
						Select-Object SessionId,
									  @{ N = 'Elapsed'; E = { Format-sqmTimeSpan -Seconds ([math]::Max(0, [int]$_.ElapsedSeconds)) } },
									  Status, BlockingSessionId, WaitInfo, DatabaseName, LoginName, HostName,
									  CpuTimeMs, Reads, Writes, TempdbAllocMB,
									  @{ N = 'SqlText'; E = { if ($_.SqlText -and $_.SqlText.Length -gt 60) { $_.SqlText.Substring(0, 60) + '...' } else { $_.SqlText } } } |
						Format-Table -AutoSize | Out-String | Write-Host
					}
				}

				$continueLoop = $true
				if ($RepeatIntervalSeconds -le 0) { $continueLoop = $false }
				elseif ($RepeatCount -gt 0 -and $iteration -ge $RepeatCount) { $continueLoop = $false }
				elseif ($DurationMinutes -gt 0 -and ((Get-Date) - $loopStart).TotalMinutes -ge $DurationMinutes) { $continueLoop = $false }

				if ($continueLoop) { Start-Sleep -Seconds $RepeatIntervalSeconds }
			}
			while ($continueLoop)

			$msg = "$($functionName): $iteration Snapshot(s) erfasst, zuletzt $($lastSnapshotRows.Count) relevante Session(s)."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$errMsg = "Fehler beim Abrufen der Active-Sessions-Daten: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
		finally
		{
			# Wird auch bei Ctrl+C (PipelineStoppedException) durchlaufen, damit ein
			# abgebrochener Dauerlauf trotzdem einen Report der bisherigen Snapshots liefert.
			if ($OutputPath -and $allSnapshots.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath))
				{
					New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
				}
				$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
				$safeInst = $SqlInstance -replace '\\', '_'

				$csvFile = Join-Path $OutputPath "WhoIsActive_${safeInst}_${stamp}.csv"
				$allSnapshots | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "WhoIsActive-CSV gespeichert ($($allSnapshots.Count) Zeile(n)): $csvFile" -FunctionName $functionName -Level "INFO"

				$htmlFile = Join-Path $OutputPath "WhoIsActive_${safeInst}_${stamp}.html"
				$rowsHtml = foreach ($s in $lastSnapshotRows)
				{
					$elapsedTxt = Format-sqmTimeSpan -Seconds ([math]::Max(0, [int]$s.ElapsedSeconds))
					$sevClass = if ($s.BlockingSessionId -gt 0) { 'crit' } elseif ($s.ElapsedSeconds -ge 30) { 'warn' } else { 'ok' }
					"<tr><td class='$sevClass'>$($s.SessionId)</td><td>$elapsedTxt</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.Status))</td><td>$($s.BlockingSessionId)</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.WaitInfo))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.DatabaseName))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.LoginName))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.HostName))</td><td>$($s.CpuTimeMs)</td><td>$($s.Reads)</td><td>$($s.TempdbAllocMB)</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.SqlText))</td></tr>"
				}
				$bodyHtml = "<p>$iteration Snapshot(s) erfasst zwischen $($loopStart.ToString('yyyy-MM-dd HH:mm:ss')) und $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')). Letzter Snapshot: $($lastSnapshotRows.Count) Session(s).</p>" +
					"<table><tr><th>SPID</th><th>Elapsed</th><th>Status</th><th>Blocked by</th><th>Wait Info</th><th>Datenbank</th><th>Login</th><th>Host</th><th>CPU ms</th><th>Reads</th><th>Tempdb MB</th><th>SQL Text</th></tr>" +
					($rowsHtml -join '') + "</table>"
				$html = ConvertTo-sqmHtmlReport -Title "Who Is Active - $SqlInstance" -Subtitle "Letzter Snapshot: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ($iteration Snapshot(s) gesamt)" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
				Invoke-sqmLogging -Message "WhoIsActive-HTML-Bericht gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
			}
		}

		return [PSCustomObject]@{
			SqlInstance	  = $SqlInstance
			StartTime	  = $loopStart
			EndTime		  = Get-Date
			Iterations	  = $iteration
			SnapshotCount = $allSnapshots.Count
			LastSnapshot  = $lastSnapshotRows
			AllSnapshots  = $allSnapshots
			CsvFile	      = $csvFile
			HtmlFile	  = $htmlFile
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}
