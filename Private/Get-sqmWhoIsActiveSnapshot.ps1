<#
.SYNOPSIS
    Fuehrt einen einzelnen WhoIsActive-Snapshot aus (eine DMV-Abfrage, keine Wiederholung).

.DESCRIPTION
    Kapselt die eigentliche sys.dm_exec_sessions/dm_exec_requests-Abfrage, die urspruenglich
    inline in Get-sqmWhoIsActive stand. Ausgelagert, damit sowohl die wiederholende
    Konsolen-/Report-Funktion (Get-sqmWhoIsActive) als auch die WinForms-Live-Ansicht
    (Show-sqmWhoIsActiveMonitor) exakt dieselbe Abfrage- und Zeilenlogik verwenden -
    eine Aenderung an Spalten/Filtern muss dadurch nur an einer Stelle gepflegt werden.

.PARAMETER Iteration
    Fortlaufende Snapshot-Nummer, wird nur in die Ergebniszeilen geschrieben
    (Anzeige-/Diagnosezweck), hat keinen Einfluss auf die Abfrage selbst.

.PARAMETER CaptureTime
    Zeitstempel, der als CaptureTime in jede Ergebniszeile geschrieben wird.
    Default: Get-Date zum Zeitpunkt des Aufrufs.

.NOTES
    Privat - wird ausschliesslich von Get-sqmWhoIsActive und Show-sqmWhoIsActiveMonitor
    aufgerufen. Wirft Abfragefehler unveraendert weiter (kein eigenes try/catch) -
    Fehlerbehandlung ist Sache des jeweiligen Aufrufers.
#>
function Get-sqmWhoIsActiveSnapshot
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
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
		[int]$Iteration = 1,
		[Parameter(Mandatory = $false)]
		[datetime]$CaptureTime = (Get-Date)
	)

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

	$rawData = @(Invoke-DbaQuery @connParams -Query $whoIsActiveQuery)

	foreach ($row in $rawData)
	{
		[PSCustomObject]@{
			Iteration		  = $Iteration
			CaptureTime	      = $CaptureTime
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
}
