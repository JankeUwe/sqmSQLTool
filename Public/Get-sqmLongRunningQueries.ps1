<#
.SYNOPSIS
    Ermittelt lang laufende Queries auf einer SQL Server-Instanz.

.DESCRIPTION
    Liest sys.dm_exec_requests, sys.dm_exec_sessions, sys.dm_exec_sql_text und
    sys.dm_exec_query_plan aus und gibt alle aktiven Requests zurueck, die die
    konfigurierten Schwellwerte ueberschreiten.

    Pro Query werden ausgegeben:
      - Session-ID, Datenbank, Login, Host, Programm
      - Laufzeit in Sekunden, CPU-Zeit, logische/physische Reads, Writes
      - Aktueller Wartetyp und Warteressource
      - Aktuelles Statement (nicht nur der Batch) mit Start/End-Offset-Aufloesung
      - Query Plan Hash und Query Hash (fuer Plan Cache Abgleich)
      - Geschaetzte Fertigstellung (falls percent_complete > 0)
      - Transaktionsisolationsstufe

    Systemsessions (session_id <= 50) und der eigene Request werden automatisch
    ausgeschlossen.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER MinDurationSeconds
    Nur Queries ausgeben, die laenger als dieser Wert laufen (Sekunden). Standard: 30.

.PARAMETER MinCpuMs
    Nur Queries ausgeben, deren CPU-Zeit diesen Wert ueberschreitet (Millisekunden). Standard: 0.

.PARAMETER ExcludeWaitType
    Wartetypen ausschliessen (z.B. 'SLEEP_TASK','WAITFOR'). Standard: uebliche Leerlauf-Waits.

.PARAMETER IncludeSystemSessions
    Auch System-Sessions (SPID <= 50) einbeziehen. Standard: $false.

.PARAMETER IncludeQueryPlan
    XML-Ausfuehrungsplan mit abrufen (kostenintensiv - nur bei Bedarf). Standard: $false.

.PARAMETER OutputPath
    Wenn angegeben, wird ein CSV-Snapshot in dieses Verzeichnis geschrieben.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt als Fehler zurueckgeben.

.EXAMPLE
    Get-sqmLongRunningQueries

.EXAMPLE
    Get-sqmLongRunningQueries -SqlInstance "SQL01" -MinDurationSeconds 60

.EXAMPLE
    # Top 10 nach Laufzeit
    Get-sqmLongRunningQueries -MinDurationSeconds 10 | Sort-Object DurationSeconds -Descending | Select-Object -First 10

.EXAMPLE
    # Regelmaessiger Snapshot via Agent-Job
    Get-sqmLongRunningQueries -MinDurationSeconds 120 -OutputPath "C:\System\WinSrvLog\MSSQL\LongRunning"

.NOTES
    Erfordert: dbatools, Invoke-sqmLogging
    Benoetigt VIEW SERVER STATE auf der Instanz.
    IncludeQueryPlan erzeugt zusaetzliche Last - nur interaktiv verwenden, nicht in Agent-Jobs.
#>
function Get-sqmLongRunningQueries
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$MinDurationSeconds = 30,
		[Parameter(Mandatory = $false)]
		[int]$MinCpuMs = 0,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeWaitType = @(
			'SLEEP_TASK', 'WAITFOR', 'BROKER_TO_FLUSH', 'BROKER_TASK_STOP',
			'CLR_AUTO_EVENT', 'DISPATCHER_QUEUE_SEMAPHORE', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
			'HADR_WORK_QUEUE', 'LAZYWRITER_SLEEP', 'LOGMGR_QUEUE', 'ONDEMAND_TASK_QUEUE',
			'REQUEST_FOR_DEADLOCK_SEARCH', 'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK',
			'SLEEP_DBSTARTUP', 'SLEEP_DBTASK', 'SLEEP_MASTERDBREADY', 'SLEEP_MASTERMDREADY',
			'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK',
			'SLEEP_TEMPDBSTARTUP', 'SNI_HTTP_ACCEPT', 'SP_SERVER_DIAGNOSTICS_SLEEP',
			'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
			'XE_DISPATCHER_WAIT', 'XE_TIMER_EVENT'
		),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemSessions,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeQueryPlan,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
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
		
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (MinDuration=${MinDurationSeconds}s)" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			$systemFilter = if ($IncludeSystemSessions) { '' }
			else { 'AND r.session_id > 50' }
			$minCpuFilter = if ($MinCpuMs -gt 0) { "AND r.cpu_time >= $MinCpuMs" }
			else { '' }
			
			# Isolation Level als lesbare Bezeichnung
			$isoLevelCase = @"
CASE s.transaction_isolation_level
    WHEN 0 THEN 'Unspecified'
    WHEN 1 THEN 'ReadUncommitted'
    WHEN 2 THEN 'ReadCommitted'
    WHEN 3 THEN 'RepeatableRead'
    WHEN 4 THEN 'Serializable'
    WHEN 5 THEN 'Snapshot'
    ELSE 'Unknown'
END
"@
			
			$query = @"
SELECT
    r.session_id                                                    AS SessionId,
    r.blocking_session_id                                           AS BlockingSpid,
    DB_NAME(r.database_id)                                          AS DatabaseName,
    s.login_name                                                    AS LoginName,
    s.host_name                                                     AS HostName,
    s.program_name                                                  AS ProgramName,
    r.status                                                        AS RequestStatus,
    r.command                                                       AS Command,
    DATEDIFF(SECOND, r.start_time, GETDATE())                       AS DurationSeconds,
    r.start_time                                                    AS StartTime,
    r.cpu_time                                                      AS CpuMs,
    r.logical_reads                                                 AS LogicalReads,
    r.reads                                                         AS PhysicalReads,
    r.writes                                                        AS Writes,
    r.wait_type                                                     AS WaitType,
    r.wait_time / 1000.0                                            AS WaitSeconds,
    r.wait_resource                                                 AS WaitResource,
    r.percent_complete                                              AS PercentComplete,
    CASE
        WHEN r.percent_complete > 0
        THEN DATEADD(ms, r.estimated_completion_time, GETDATE())
        ELSE NULL
    END                                                             AS EstimatedCompletion,
    r.open_transaction_count                                        AS OpenTransactions,
    $isoLevelCase                                                   AS IsolationLevel,
    r.query_hash                                                    AS QueryHash,
    r.query_plan_hash                                               AS QueryPlanHash,
    r.sql_handle                                                    AS SqlHandle,
    r.plan_handle                                                   AS PlanHandle,
    r.statement_start_offset                                        AS StmtStartOffset,
    r.statement_end_offset                                          AS StmtEndOffset,
    -- Aktuelles Statement (Ausschnitt aus dem Batch)
    SUBSTRING(
        st.text,
        (r.statement_start_offset / 2) + 1,
        CASE r.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE r.statement_end_offset
        END / 2 - r.statement_start_offset / 2 + 1
    )                                                               AS CurrentStatement,
    st.text                                                         AS FullBatch,
    s.total_elapsed_time                                            AS SessionTotalElapsedMs,
    s.last_request_start_time                                       AS LastRequestStart
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s
    ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.session_id <> @@SPID
  AND DATEDIFF(SECOND, r.start_time, GETDATE()) >= $MinDurationSeconds
  $systemFilter
  $minCpuFilter
ORDER BY DurationSeconds DESC
"@
			
			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database	  = 'master'
				ErrorAction   = 'Stop'
			}
			
			$rawData = Invoke-DbaQuery @connParams -Query $query
			
			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			
			foreach ($row in $rawData)
			{
				# ExcludeWaitType-Filter (NULL-sicher)
				if ($row.WaitType -and $ExcludeWaitType -contains $row.WaitType) { continue }
				
				$entry = [PSCustomObject]@{
					SessionId = $row.SessionId
					BlockingSpid = if ($row.BlockingSpid -gt 0) { $row.BlockingSpid } else { $null }
					DatabaseName = $row.DatabaseName
					LoginName = $row.LoginName
					HostName  = $row.HostName
					ProgramName = $row.ProgramName
					RequestStatus = $row.RequestStatus
					Command   = $row.Command
					DurationSeconds = $row.DurationSeconds
					StartTime = $row.StartTime
					CpuMs	  = $row.CpuMs
					LogicalReads = $row.LogicalReads
					PhysicalReads = $row.PhysicalReads
					Writes    = $row.Writes
					WaitType  = $row.WaitType
					WaitSeconds = [math]::Round($row.WaitSeconds, 1)
					WaitResource = $row.WaitResource
					PercentComplete = [math]::Round($row.PercentComplete, 1)
					EstimatedCompletion = $row.EstimatedCompletion
					OpenTransactions = $row.OpenTransactions
					IsolationLevel = $row.IsolationLevel
					QueryHash = if ($row.QueryHash -is [byte[]]) { [System.BitConverter]::ToString($row.QueryHash) -replace '-', '' } else { $null }
					QueryPlanHash = if ($row.QueryPlanHash -is [byte[]]) { [System.BitConverter]::ToString($row.QueryPlanHash) -replace '-', '' } else { $null }
					CurrentStatement = ($row.CurrentStatement -replace '\s+', ' ').Trim()
					FullBatch = $row.FullBatch
					QueryPlanXml = $null # wird ggf. weiter unten befuellt
					IsBlocked = ($row.BlockingSpid -gt 0)
					CaptureTime = (Get-Date)
				}
				
				# Ausfuehrungsplan abrufen (optional, da kostenintensiv)
				if ($IncludeQueryPlan -and $row.PlanHandle -is [byte[]])
				{
					try
					{
						$planQuery = "SELECT query_plan FROM sys.dm_exec_query_plan($(
							'0x' + [System.BitConverter]::ToString($row.PlanHandle).Replace('-', '')
						))"
						$planResult = Invoke-DbaQuery @connParams -Query $planQuery -ErrorAction SilentlyContinue
						if ($planResult) { $entry.QueryPlanXml = $planResult.query_plan }
					}
					catch { <# Plan nicht verfuegbar - ignorieren #> }
				}
				
				$results.Add($entry)
			}
			
			# Optional: CSV-Snapshot schreiben
			if ($OutputPath -and $results.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath))
				{
					New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
				}
				$csvFile = Join-Path $OutputPath "LongRunning_$(($SqlInstance -replace '\\', '_'))_$(Get-Date -Format 'yyyyMMdd_HHmsqm').csv"
				# QueryPlanXml fuer CSV-Export ausschliessen (zu gross)
				$results | Select-Object * -ExcludeProperty QueryPlanXml, FullBatch |
				Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "LongRunning-Snapshot gespeichert: $csvFile" -FunctionName $functionName -Level "INFO"
			}
			
			$msg = "$($results.Count) lang laufende Query/Queries gefunden (>= ${MinDurationSeconds}s)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
			
			return $results
		}
		catch
		{
			$errMsg = "Fehler beim Abrufen der lang laufenden Queries: $($_.Exception.Message)"
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