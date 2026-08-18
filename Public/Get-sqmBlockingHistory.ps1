<#
.SYNOPSIS
    Retrieves past blocking incidents (blocked_process_report events) from Extended Events
    ring buffers - both the dedicated sqm_BlockedProcessMonitor session this function
    ensures exists, and system_health if it happens to capture the event too.

.DESCRIPTION
    Unlike Get-sqmBlockingReport (which only shows blocking happening at the exact moment
    it is called), this function reads blocked_process_report events already captured in
    Extended Events ring buffers. Each event contains the blocking/blocked SPID, login,
    host, program, lock mode, wait resource, wait time and an input-buffer excerpt of the
    statement involved.

    The built-in system_health session does NOT reliably include blocked_process_report -
    verified live: on a default installation the event is simply absent from its
    definition, so the events fire but are captured nowhere. This function therefore calls
    Register-sqmBlockedProcessMonitor first to ensure a dedicated session
    (sqm_BlockedProcessMonitor) exists and is running, then reads from both that session
    and system_health (in case the latter happens to include the event too, no harm merging
    both - results are de-duplicated). Pass -SkipMonitorSetup to skip the ensure-step (e.g.
    for a read-only account without ALTER ANY EVENT SESSION).

    Two hard limitations of the underlying data source, both surfaced in the result:
      - blocked_process_report events are only generated when the server-level advanced
        setting 'blocked process threshold (s)' is greater than 0. It is 0 (disabled) by
        default and requires 'show advanced options' to be enabled to change via
        sp_configure. If it is 0, ThresholdConfigured is $false and no incidents can exist,
        regardless of how much blocking actually occurred, or how long the monitoring
        session has been running.
      - The ring buffer target is memory-limited and wraps around; on a busy instance it
        may only cover the last few hours, not days or weeks. Use -IncludeFileTarget on
        Register-sqmBlockedProcessMonitor once for longer retention via an event_file
        target. OldestEventInBuffer / MonitorSessionStartTime indicate how far back the
        available data actually reaches.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Since
    Only return incidents at or after this timestamp. Default: no lower bound (everything
    still in the ring buffer).

.PARAMETER MinWaitSeconds
    Only report incidents whose blocked-process wait time was at least this many seconds.
    Default: 0.

.PARAMETER SkipMonitorSetup
    Skip ensuring sqm_BlockedProcessMonitor exists/is running - only read whatever is
    already there (system_health and/or a previously created monitor session).

.PARAMETER OutputPath
    Directory for the CSV/HTML report. Default: <OutputPath config>\BlockingHistory.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.EXAMPLE
    Get-sqmBlockingHistory -SqlInstance "SQL01"

.EXAMPLE
    # Only incidents from the last 2 hours, at least 10 seconds blocked
    Get-sqmBlockingHistory -SqlInstance "SQL01" -Since (Get-Date).AddHours(-2) -MinWaitSeconds 10

.EXAMPLE
    $h = Get-sqmBlockingHistory -SqlInstance "SQL01"
    if (-not $h.ThresholdConfigured) { Write-Warning "blocked process threshold ist 0 - keine Historie moeglich." }

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Register-sqmBlockedProcessMonitor
    Needs VIEW SERVER STATE; ALTER ANY EVENT SESSION unless -SkipMonitorSetup is used.
    Data source: sys.dm_xe_session_targets, ring_buffer target, sessions
    'sqm_BlockedProcessMonitor' and 'system_health'. Does not change
    'blocked process threshold (s)' itself - only reports its current value.
#>
function Get-sqmBlockingHistory
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[Nullable[datetime]]$Since,
		[Parameter(Mandatory = $false)]
		[int]$MinWaitSeconds = 0,
		[Parameter(Mandatory = $false)]
		[switch]$SkipMonitorSetup,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'BlockingHistory'),
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
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (MinWaitSeconds=$MinWaitSeconds)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database	  = 'master'
				ErrorAction   = 'Stop'
			}

			# -----------------------------------------------------------------------
			# 1. 'blocked process threshold (s)' pruefen - ohne diese Servereinstellung
			# (Default 0 = deaktiviert) entstehen nie blocked_process_report-Events,
			# egal wie viel Blocking tatsaechlich stattfand. sys.configurations liest
			# den Wert unabhaengig von 'show advanced options'.
			# -----------------------------------------------------------------------
			$thresholdRow = Invoke-DbaQuery @connParams -Query "SELECT CAST(value_in_use AS INT) AS ThresholdSeconds FROM sys.configurations WHERE name = 'blocked process threshold (s)'"
			$thresholdSeconds = if ($thresholdRow) { [int]$thresholdRow.ThresholdSeconds } else { 0 }
			$thresholdConfigured = $thresholdSeconds -gt 0

			if (-not $thresholdConfigured)
			{
				Invoke-sqmLogging -Message "[$SqlInstance] 'blocked process threshold (s)' ist 0 (deaktiviert) - es koennen keine blocked_process_report-Events existieren. Aktivieren (Advanced Option, daher zwei Schritte) z.B. mit: sp_configure 'show advanced options', 1; RECONFIGURE; sp_configure 'blocked process threshold (s)', 20; RECONFIGURE;" -FunctionName $functionName -Level "WARNING"
			}

			# -----------------------------------------------------------------------
			# 2. Eigene Monitor-Session sicherstellen - system_health enthaelt
			# blocked_process_report auf einer Standardinstallation NICHT (live
			# verifiziert). Ohne ein lauschendes Ziel verpuffen die Events komplett,
			# selbst bei aktiviertem Threshold.
			# -----------------------------------------------------------------------
			$monitorSessionName = 'sqm_BlockedProcessMonitor'
			if (-not $SkipMonitorSetup)
			{
				try
				{
					$regResult = Register-sqmBlockedProcessMonitor -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
					if ($regResult) { Invoke-sqmLogging -Message "[$SqlInstance] $($regResult.Action): $($regResult.Message)" -FunctionName $functionName -Level "INFO" }
				}
				catch
				{
					Invoke-sqmLogging -Message "[$SqlInstance] Register-sqmBlockedProcessMonitor fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}

			$sessionInfoRows = Invoke-DbaQuery @connParams -Query "SELECT name, create_time FROM sys.dm_xe_sessions WHERE name IN (N'$monitorSessionName', N'system_health')"
			$monitorStartTime = ($sessionInfoRows | Where-Object { $_.name -eq $monitorSessionName } | Select-Object -First 1).create_time
			$systemHealthStartTime = ($sessionInfoRows | Where-Object { $_.name -eq 'system_health' } | Select-Object -First 1).create_time

			# -----------------------------------------------------------------------
			# 3. Ring-Buffer beider Sessions auslesen und blocked_process_report-Events
			# shredden - DISTINCT, falls system_health das Event auf dieser Instanz
			# zufaellig ebenfalls enthaelt (dann taucht derselbe Vorfall doppelt auf).
			# -----------------------------------------------------------------------
			# WICHTIG: .value() muss den vollen XPath direkt gegen XEventData ausfuehren.
			# Verkettet ueber ein per .query() vorher materialisiertes XML-Zwischenergebnis
			# (fruehere Fassung: CTE mit "Report"-Spalte) liefert .value() zuverlaessig NULL
			# fuer jede Spalte - live mit einem echten Blocking-Vorfall auf DEV01 verifiziert
			# (BlockedSpid/BlockedWaitMs/BlockingSpid kamen als DBNull zurueck, obwohl die
			# rohe XML nachweislich vollstaendig befuellt war).
			$xeQuery = @"
SELECT DISTINCT
    XEventData.value('(@timestamp)[1]', 'datetime2') AS EventTime,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@spid)[1]', 'int') AS BlockingSpid,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@loginname)[1]', 'nvarchar(128)') AS BlockingLogin,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@hostname)[1]', 'nvarchar(128)') AS BlockingHost,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@clientapp)[1]', 'nvarchar(256)') AS BlockingProgram,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@lockMode)[1]', 'nvarchar(10)') AS BlockingLockMode,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)') AS BlockingStatement,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@spid)[1]', 'int') AS BlockedSpid,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint') AS BlockedWaitMs,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@lockMode)[1]', 'nvarchar(10)') AS BlockedLockMode,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@waitresource)[1]', 'nvarchar(256)') AS WaitResource,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@loginname)[1]', 'nvarchar(128)') AS BlockedLogin,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@hostname)[1]', 'nvarchar(128)') AS BlockedHost,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@clientapp)[1]', 'nvarchar(256)') AS BlockedProgram,
    DB_NAME(XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@currentdb)[1]', 'int')) AS DatabaseName,
    XEventData.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)') AS BlockedStatement
FROM
(
    SELECT CAST(target_data AS XML) AS TargetData
    FROM sys.dm_xe_session_targets st
    JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address
    WHERE s.name IN (N'$monitorSessionName', N'system_health') AND st.target_name = N'ring_buffer'
) AS RingBuffer
CROSS APPLY TargetData.nodes('RingBufferTarget/event[@name="blocked_process_report"]') AS Node(XEventData)
ORDER BY EventTime DESC
"@
			$rawEvents = Invoke-DbaQuery @connParams -Query $xeQuery

			$incidents = [System.Collections.Generic.List[PSCustomObject]]::new()
			foreach ($row in $rawEvents)
			{
				# Invoke-DbaQuery liefert SQL NULL als [System.DBNull], nicht als PowerShell $null -
				# eine reine Truthy-Pruefung haelt DBNull faelschlich fuer "vorhanden" und die
				# nachfolgende Division wirft. Live beobachtet, daher explizite Typpruefung.
				$waitSec = if ($row.BlockedWaitMs -and $row.BlockedWaitMs -isnot [DBNull]) { [math]::Round($row.BlockedWaitMs / 1000.0, 1) } else { 0 }
				if ($waitSec -lt $MinWaitSeconds) { continue }
				if ($Since -and $row.EventTime -lt $Since) { continue }

				$incidents.Add([PSCustomObject]@{
						EventTime         = $row.EventTime
						WaitSeconds       = $waitSec
						DatabaseName      = $row.DatabaseName
						WaitResource      = $row.WaitResource
						BlockingSpid      = $row.BlockingSpid
						BlockingLogin     = $row.BlockingLogin
						BlockingHost      = $row.BlockingHost
						BlockingProgram   = $row.BlockingProgram
						BlockingLockMode  = $row.BlockingLockMode
						BlockingStatement = ($row.BlockingStatement -replace '\s+', ' ').Trim()
						BlockedSpid       = $row.BlockedSpid
						BlockedLogin      = $row.BlockedLogin
						BlockedHost       = $row.BlockedHost
						BlockedProgram    = $row.BlockedProgram
						BlockedLockMode   = $row.BlockedLockMode
						BlockedStatement  = ($row.BlockedStatement -replace '\s+', ' ').Trim()
					})
			}

			$oldestEventInBuffer = if ($rawEvents) { ($rawEvents | Measure-Object -Property EventTime -Minimum).Minimum } else { $null }

			# -----------------------------------------------------------------------
			# Optional: CSV- und HTML-Bericht schreiben
			# -----------------------------------------------------------------------
			$csvFile = $null
			$htmlFile = $null
			if ($OutputPath -and $incidents.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
				$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'

				$csvFile = Join-Path $OutputPath "BlockingHistory_${safeInst}_${stamp}.csv"
				$incidents | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "Blocking-History gespeichert: $csvFile" -FunctionName $functionName -Level "INFO"

				$htmlFile = Join-Path $OutputPath "BlockingHistory_${safeInst}_${stamp}.html"
				$rowsHtml = foreach ($i in $incidents)
				{
					$sevClass = if ($i.WaitSeconds -ge 60) { 'crit' } elseif ($i.WaitSeconds -ge 10) { 'warn' } else { 'ok' }
					"<tr><td>$($i.EventTime.ToString('yyyy-MM-dd HH:mm:ss'))</td><td class='$sevClass'>$($i.WaitSeconds)s</td><td>$($i.BlockedSpid)</td><td>$($i.BlockingSpid)</td><td>$([System.Net.WebUtility]::HtmlEncode($i.DatabaseName))</td><td>$([System.Net.WebUtility]::HtmlEncode($i.BlockedLogin))</td><td>$([System.Net.WebUtility]::HtmlEncode($i.BlockingLogin))</td><td>$([System.Net.WebUtility]::HtmlEncode($i.BlockedStatement))</td><td>$([System.Net.WebUtility]::HtmlEncode($i.BlockingStatement))</td></tr>"
				}
				$thresholdNote = "'blocked process threshold (s)' = ${thresholdSeconds}s"
				$bufferNote = if ($oldestEventInBuffer) { "Ring-Buffer deckt ab: $($oldestEventInBuffer.ToString('yyyy-MM-dd HH:mm:ss'))" } else { "Ring-Buffer enthaelt aktuell keine blocked_process_report-Events" }
				$bodyHtml = "<p>$($incidents.Count) Vorfall/Vorfaelle. $thresholdNote. $bufferNote.</p>" +
					"<table><tr><th>Zeitpunkt</th><th>Wartezeit</th><th>Blocked SPID</th><th>Blocking SPID</th><th>Datenbank</th><th>Blocked Login</th><th>Blocking Login</th><th>Blocked Statement</th><th>Blocking Statement</th></tr>" +
					($rowsHtml -join '') + "</table>"
				$html = ConvertTo-sqmHtmlReport -Title "Blocking History - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
				Invoke-sqmLogging -Message "Blocking-History-HTML-Bericht gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
			}

			$result = [PSCustomObject]@{
				SqlInstance            = $SqlInstance
				CaptureTime            = (Get-Date)
				ThresholdConfigured    = $thresholdConfigured
				ThresholdSeconds       = $thresholdSeconds
				MonitorSessionStartTime = $monitorStartTime
				SystemHealthStartTime  = $systemHealthStartTime
				OldestEventInBuffer    = $oldestEventInBuffer
				HasIncidents           = ($incidents.Count -gt 0)
				Incidents              = $incidents
				IncidentCount          = $incidents.Count
				CsvFile                = $csvFile
				HtmlFile               = $htmlFile
			}

			$msg = if (-not $thresholdConfigured)
			{
				"'blocked process threshold (s)' ist 0 - Historie generell nicht moeglich."
			}
			elseif ($result.HasIncidents)
			{
				"$($incidents.Count) vergangene(r) Blocking-Vorfall/Vorfaelle im Ring-Buffer gefunden (deckt ab seit $oldestEventInBuffer)."
			}
			else
			{
				"Keine Blocking-Vorfaelle im aktuellen Ring-Buffer gefunden (Threshold=${thresholdSeconds}s, Monitor-Session laeuft seit $monitorStartTime)."
			}
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"

			return $result
		}
		catch
		{
			$errMsg = "Fehler beim Abrufen der Blocking-History: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}
