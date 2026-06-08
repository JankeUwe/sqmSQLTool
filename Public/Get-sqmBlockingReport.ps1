<#
.SYNOPSIS
    Retrieves current blocking chains on a SQL Server instance.

.DESCRIPTION
    Reads sys.dm_exec_requests, sys.dm_exec_sessions and sys.dm_exec_sql_text
    and builds complete blocking chains. For each blocked session the following is returned:
      - Blocking SPID and its SQL text
      - Blocked SPID(s) with wait time, wait type and lock resource
      - Database, login, hostname, program
      - Complete chain (head blocker to all blocked sessions)

    An optional snapshot mode can be enabled: the function then periodically writes
    snapshots as CSV files - useful for Agent jobs for historical analysis.

    Returns an object that can be used directly for further processing:
      .BlockingChains  - List of all chains with head blocker and blocked sessions
      .HeadBlockers    - Only the blocking sessions
      .BlockedSessions - Only the blocked sessions
      .HasBlocking     - $true if blocking was found

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER MinWaitSeconds
    Only report blocking that has been waiting longer than this value (in seconds). Default: 0.

.PARAMETER OutputPath
    If specified, a CSV snapshot is written to this directory.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.EXAMPLE
    Get-sqmBlockingReport

.EXAMPLE
    Get-sqmBlockingReport -SqlInstance "SQL01" -MinWaitSeconds 30

.EXAMPLE
    # Check whether blocking is currently occurring
    if ((Get-sqmBlockingReport -SqlInstance "SQL01").HasBlocking) { Write-Warning "Blocking detected!" }

.EXAMPLE
    # Regular snapshot via Agent job
    Get-sqmBlockingReport -SqlInstance "SQL01" -OutputPath "$env:ProgramData\sqmSQLTool\Logs\Blocking"

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE on the instance.
    SQL text is resolved via sys.dm_exec_sql_text (statement level via statement_start/end_offset).
#>
function Get-sqmBlockingReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$MinWaitSeconds = 0,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
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
			# -----------------------------------------------------------------------
			# Blockierungsabfrage: Head Blocker + blockierte Sessions in einem Schritt
			# statement_start/end_offset liefert den exakten Statement-Ausschnitt
			# -----------------------------------------------------------------------
			$blockingQuery = @"
SELECT
    r.session_id                                                AS BlockedSpid,
    r.blocking_session_id                                       AS BlockingSpid,
    r.wait_type                                                 AS WaitType,
    r.wait_time / 1000.0                                        AS WaitSeconds,
    r.wait_resource                                             AS WaitResource,
    r.status                                                    AS BlockedStatus,
    DB_NAME(r.database_id)                                      AS DatabaseName,
    -- Blockierter SQL-Text (aktuelles Statement)
    SUBSTRING(
        st_blocked.text,
        (r.statement_start_offset / 2) + 1,
        CASE r.statement_end_offset
            WHEN -1 THEN DATALENGTH(st_blocked.text)
            ELSE r.statement_end_offset
        END / 2 - r.statement_start_offset / 2 + 1
    )                                                           AS BlockedStatement,
    st_blocked.text                                             AS BlockedFullBatch,
    -- Blockierende Session
    s_blocked.login_name                                        AS BlockedLogin,
    s_blocked.host_name                                         AS BlockedHost,
    s_blocked.program_name                                      AS BlockedProgram,
    s_blocked.cpu_time                                          AS BlockedCpuMs,
    s_blocked.logical_reads                                     AS BlockedLogicalReads,
    -- Blockierende Session (Head Blocker)
    s_blocker.login_name                                        AS BlockingLogin,
    s_blocker.host_name                                         AS BlockingHost,
    s_blocker.program_name                                      AS BlockingProgram,
    s_blocker.status                                            AS BlockingSessionStatus,
    s_blocker.cpu_time                                          AS BlockingCpuMs,
    s_blocker.logical_reads                                     AS BlockingLogicalReads,
    s_blocker.last_request_start_time                           AS BlockingStartTime,
    -- SQL-Text des Blockierenden (aus offenen Requests oder letztem Batch)
    COALESCE(
        SUBSTRING(
            st_blocker.text,
            (r_blocker.statement_start_offset / 2) + 1,
            CASE r_blocker.statement_end_offset
                WHEN -1 THEN DATALENGTH(st_blocker.text)
                ELSE r_blocker.statement_end_offset
            END / 2 - r_blocker.statement_start_offset / 2 + 1
        ),
        st_blocker_conn.text
    )                                                           AS BlockingStatement,
    COALESCE(st_blocker.text, st_blocker_conn.text)             AS BlockingFullBatch
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s_blocked
    ON r.session_id = s_blocked.session_id
INNER JOIN sys.dm_exec_sessions s_blocker
    ON r.blocking_session_id = s_blocker.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st_blocked
-- Blocker: aktiver Request
LEFT JOIN sys.dm_exec_requests r_blocker
    ON r.blocking_session_id = r_blocker.session_id
OUTER APPLY sys.dm_exec_sql_text(r_blocker.sql_handle) st_blocker
-- Blocker: letzter Batch (falls kein aktiver Request)
OUTER APPLY sys.dm_exec_sql_text(s_blocker.most_recent_sql_handle) st_blocker_conn
WHERE r.blocking_session_id > 0
  AND r.wait_time / 1000.0 >= $MinWaitSeconds
ORDER BY r.wait_time DESC
"@
			
			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database	  = 'master'
				ErrorAction   = 'Stop'
			}
			
			$rawData = Invoke-DbaQuery @connParams -Query $blockingQuery
			
			# -----------------------------------------------------------------------
			# Ergebnis aufbereiten
			# -----------------------------------------------------------------------
			$blockedSessions = [System.Collections.Generic.List[PSCustomObject]]::new()
			$headBlockerSpids = [System.Collections.Generic.HashSet[int]]::new()
			
			foreach ($row in $rawData)
			{
				$null = $headBlockerSpids.Add([int]$row.BlockingSpid)
				
				$blockedSessions.Add([PSCustomObject]@{
						BlockedSpid = $row.BlockedSpid
						BlockingSpid = $row.BlockingSpid
						WaitType    = $row.WaitType
						WaitSeconds = [math]::Round($row.WaitSeconds, 1)
						WaitResource = $row.WaitResource
						BlockedStatus = $row.BlockedStatus
						DatabaseName = $row.DatabaseName
						BlockedLogin = $row.BlockedLogin
						BlockedHost = $row.BlockedHost
						BlockedProgram = $row.BlockedProgram
						BlockedStatement = ($row.BlockedStatement -replace '\s+', ' ').Trim()
						BlockedFullBatch = $row.BlockedFullBatch
						BlockedCpuMs = $row.BlockedCpuMs
						BlockedLogicalReads = $row.BlockedLogicalReads
						BlockingLogin = $row.BlockingLogin
						BlockingHost = $row.BlockingHost
						BlockingProgram = $row.BlockingProgram
						BlockingStatus = $row.BlockingSessionStatus
						BlockingStartTime = $row.BlockingStartTime
						BlockingStatement = ($row.BlockingStatement -replace '\s+', ' ').Trim()
						BlockingFullBatch = $row.BlockingFullBatch
						BlockingCpuMs = $row.BlockingCpuMs
						BlockingLogicalReads = $row.BlockingLogicalReads
						CaptureTime = (Get-Date)
					})
			}
			
			# Head Blocker: SPIDs die blockieren, aber selbst nicht blockiert sind
			$blockedSpids = $blockedSessions | Select-Object -ExpandProperty BlockedSpid
			$trueHeadBlockers = $headBlockerSpids | Where-Object { $_ -notin $blockedSpids }
			
			# Blockierungsketten aufbauen
			$chains = [System.Collections.Generic.List[PSCustomObject]]::new()
			foreach ($headSpid in ($trueHeadBlockers | Sort-Object))
			{
				$chain = Get-sqmBlockingChain -Sessions $blockedSessions -HeadSpid $headSpid
				$chains.Add([PSCustomObject]@{
						HeadBlockerSpid = $headSpid
						HeadLogin	    = ($blockedSessions | Where-Object { $_.BlockingSpid -eq $headSpid } | Select-Object -First 1).BlockingLogin
						HeadHost	    = ($blockedSessions | Where-Object { $_.BlockingSpid -eq $headSpid } | Select-Object -First 1).BlockingHost
						HeadStatement   = ($blockedSessions | Where-Object { $_.BlockingSpid -eq $headSpid } | Select-Object -First 1).BlockingStatement
						HeadStartTime   = ($blockedSessions | Where-Object { $_.BlockingSpid -eq $headSpid } | Select-Object -First 1).BlockingStartTime
						BlockedSpids    = $chain
						BlockedCount    = $chain.Count
						MaxWaitSeconds  = ($chain | Measure-Object -Property WaitSeconds -Maximum).Maximum
					})
			}
			
			$result = [PSCustomObject]@{
				SqlInstance = $SqlInstance
				CaptureTime = (Get-Date)
				HasBlocking = ($blockedSessions.Count -gt 0)
				BlockingChains = $chains
				HeadBlockers = $trueHeadBlockers
				BlockedSessions = $blockedSessions
				BlockedCount = $blockedSessions.Count
			}
			
			# Optional: CSV-Snapshot schreiben
			if ($OutputPath -and $blockedSessions.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath))
				{
					New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
				}
				$csvFile = Join-Path $OutputPath "Blocking_$(($SqlInstance -replace '\\', '_'))_$(Get-Date -Format 'yyyyMMdd_HHmsqm').csv"
				$blockedSessions | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

				# Oeffne CSV-Datei wenn nicht -NoOpen
				if (-not $NoOpen -and $csvFile)
				{
					Start-Process $csvFile
				}

				Invoke-sqmLogging -Message "Blocking-Snapshot gespeichert: $csvFile" -FunctionName $functionName -Level "INFO"
			}
			
			$msg = if ($result.HasBlocking)
			{
				"$($blockedSessions.Count) blockierte Session(s) in $($chains.Count) Kette(n) gefunden. Max. Wartezeit: $(($chains | Measure-Object -Property MaxWaitSeconds -Maximum).Maximum)s"
			}
			else
			{
				"Keine Blockierungen gefunden."
			}
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
			
			return $result
		}
		catch
		{
			$errMsg = "Fehler beim Abrufen der Blockierungsdaten: $($_.Exception.Message)"
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

# ---------------------------------------------------------------------------
# Private Hilfsfunktion: Blockierungskette rekursiv aufbauen
# ---------------------------------------------------------------------------
function Get-sqmBlockingChain
{
	param (
		[System.Collections.Generic.List[PSCustomObject]]$Sessions,
		[int]$HeadSpid,
		[int]$Depth = 0
	)
	$result = [System.Collections.Generic.List[PSCustomObject]]::new()
	$directlyBlocked = $Sessions | Where-Object { $_.BlockingSpid -eq $HeadSpid }
	foreach ($s in $directlyBlocked)
	{
		$s | Add-Member -NotePropertyName ChainDepth -NotePropertyValue $Depth -Force
		$result.Add($s)
		# Rekursiv: Ist diese Session selbst ein Blocker?
		$subChain = Get-sqmBlockingChain -Sessions $Sessions -HeadSpid $s.BlockedSpid -Depth ($Depth + 1)
		foreach ($sub in $subChain) { $result.Add($sub) }
	}
	return $result
}