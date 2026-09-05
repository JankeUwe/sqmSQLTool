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
			do
			{
				$iteration++
				$captureTime = Get-Date

				$rowsThisIteration = @(Get-sqmWhoIsActiveSnapshot -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
						-ShowSleepingSpids $ShowSleepingSpids -MinElapsedSeconds $MinElapsedSeconds `
						-Iteration $iteration -CaptureTime $captureTime)

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
				$report = Export-sqmWhoIsActiveReport -AllSnapshots $allSnapshots -LastSnapshotRows $lastSnapshotRows `
					-SqlInstance $SqlInstance -OutputPath $OutputPath -IterationCount $iteration -LoopStart $loopStart -NoOpen:$NoOpen
				$csvFile = $report.CsvFile
				$htmlFile = $report.HtmlFile

				Invoke-sqmLogging -Message "WhoIsActive-CSV gespeichert ($($allSnapshots.Count) Zeile(n)): $csvFile" -FunctionName $functionName -Level "INFO"
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
