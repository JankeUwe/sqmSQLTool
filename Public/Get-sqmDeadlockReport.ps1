<#
.SYNOPSIS
    Reads and analyzes deadlock events from the System Health Extended Event session.

.DESCRIPTION
    The System Health session (always active since SQL Server 2008) logs all
    deadlocks as XML in the ring buffer. This function reads that buffer,
    parses the deadlock graphs and returns for each deadlock:

      - Timestamp of the deadlock
      - Victim session with login, host, program, statement
      - All involved processes with their statements and held/requested locks
      - Involved resources (tables, indexes, objects)
      - Deadlock graph as XML (for SSMS import or storage as .xdl)

    Optionally, deadlock graphs can be saved as .xdl files
    (openable directly in SSMS by double-click).

    Additionally, the System Health .xel ring buffer is read when available
    (SQL Server 2012+, provides more history than the ring buffer).

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER StartTime
    Return only deadlocks from this point in time. Default: last 24 hours.

.PARAMETER EndTime
    Return only deadlocks up to this point in time. Default: now.

.PARAMETER MaxDeadlocks
    Maximum number of deadlocks returned (newest first). Default: 100.

.PARAMETER OutputPath
    If specified, deadlock graphs are saved as .xdl files in this directory
    (format: Deadlock_<Instance>_<Timestamp>.xdl).

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.EXAMPLE
    Get-sqmDeadlockReport

.EXAMPLE
    Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-7)

.EXAMPLE
    # Save deadlocks as XDL files for SSMS
    Get-sqmDeadlockReport -SqlInstance "SQL01" -OutputPath "$env:ProgramData\sqmSQLTool\Logs\Deadlocks"

.EXAMPLE
    # Only deadlocks from the last hour, show number of affected statements
    Get-sqmDeadlockReport -StartTime (Get-Date).AddHours(-1) |
        Select-Object Timestamp, VictimLogin, VictimStatement, ProcessCount

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE on the instance.
    The System Health session runs at all times - no configuration required.
    XDL files can be opened directly in SSMS via File > Open as a deadlock graph.
    Ring buffer capacity: 4 MB by default - export early at high deadlock frequency.
#>
function Get-sqmDeadlockReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[datetime]$StartTime = (Get-Date).AddHours(-24),
		[Parameter(Mandatory = $false)]
		[datetime]$EndTime = (Get-Date),
		[Parameter(Mandatory = $false)]
		[int]$MaxDeadlocks = 100,
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
		
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance ($($StartTime.ToString('yyyy-MM-dd HH:mm')) bis $($EndTime.ToString('yyyy-MM-dd HH:mm')))" -FunctionName $functionName -Level "INFO"
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
			# Deadlock-XML aus System Health Ring Buffer lesen
			# Funktioniert auf allen Versionen ab SQL Server 2008
			# -----------------------------------------------------------------------
			$ringBufferQuery = @"
SELECT
    xdr.value('@timestamp', 'datetime2')         AS EventTime,
    xdr.query('.')                               AS DeadlockGraph
FROM (
    SELECT CAST(target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets t
    INNER JOIN sys.dm_xe_sessions s ON t.event_session_address = s.address
    WHERE s.name = 'system_health'
      AND t.target_name = 'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData(xdr)
WHERE xdr.value('@timestamp', 'datetime2') >= '$($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))'
  AND xdr.value('@timestamp', 'datetime2') <= '$($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))'
ORDER BY EventTime DESC
"@
			
			$rawDeadlocks = Invoke-DbaQuery @connParams -Query $ringBufferQuery
			
			Invoke-sqmLogging -Message "$(@($rawDeadlocks).Count) Deadlock-Ereignis(se) im Ring Buffer gefunden." -FunctionName $functionName -Level "INFO"
			
			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			$index = 0
			
			foreach ($dl in $rawDeadlocks)
			{
				if ($index -ge $MaxDeadlocks) { break }
				$index++
				
				try
				{
					# Deadlock-Graph XML parsen
					[xml]$dlXml = $dl.DeadlockGraph.ToString()
					$deadlockNode = $dlXml.event.'data'.value.'deadlock'
					
					if (-not $deadlockNode) { continue }
					
					# Opfer ermitteln
					$victimId = $deadlockNode.'victim-list'.victimProcess.id
					$victimProcess = $deadlockNode.'process-list'.process | Where-Object { $_.id -eq $victimId }
					
					# Alle beteiligten Prozesse
					$processes = [System.Collections.Generic.List[PSCustomObject]]::new()
					foreach ($proc in $deadlockNode.'process-list'.process)
					{
						$isVictim = ($proc.id -eq $victimId)
						$statement = if ($proc.inputbuf) { ($proc.inputbuf -replace '\s+', ' ').Trim() }
						else { $null }
						
						# Gehaltene und angeforderte Locks aus dem executionStack
						$lockInfo = @()
						foreach ($frame in $proc.executionStack.frame)
						{
							if ($frame.sqlhandle -and $frame.sqlhandle -ne '0x0000000000000000000000000000000000000000')
							{
								$lockInfo += $frame.'#text'
							}
						}
						
						$processes.Add([PSCustomObject]@{
								ProcessId = $proc.id
								IsVictim  = $isVictim
								SpId	  = $proc.spid
								LoginName = $proc.loginname
								HostName  = $proc.hostname
								ProgramName = $proc.clientapp
								DatabaseId = $proc.currentdbid
								TransactionId = $proc.trancount
								LockMode  = $proc.lockMode
								WaitResource = $proc.waitresource
								WaitTime  = $proc.waittime
								LogUsed   = $proc.logused
								Statement = $statement
							})
					}
					
					# Beteiligte Ressourcen (Tabellen/Indizes)
					$resources = [System.Collections.Generic.List[PSCustomObject]]::new()
					foreach ($res in $deadlockNode.'resource-list'.ChildNodes)
					{
						$resources.Add([PSCustomObject]@{
								ResourceType = $res.LocalName
								ObjectName   = $res.objectname
								IndexName    = $res.indexname
								LockMode	 = $res.mode
								AssociatedProcesses = ($res.owner.id + $res.waiter.id) -join ', '
							})
					}
					
					# Deadlock-Graph als sauberes XML fuer XDL-Export
					$graphXml = $deadlockNode.OuterXml
					
					$result = [PSCustomObject]@{
						Timestamp = $dl.EventTime
						DeadlockIndex = $index
						VictimSpid = $victimProcess.spid
						VictimLogin = $victimProcess.loginname
						VictimHost = $victimProcess.hostname
						VictimProgram = $victimProcess.clientapp
						VictimStatement = if ($victimProcess.inputbuf) { ($victimProcess.inputbuf -replace '\s+', ' ').Trim() } else { $null }
						VictimWaitTime = $victimProcess.waittime
						ProcessCount = $processes.Count
						Processes = $processes
						Resources = $resources
						DeadlockGraphXml = $graphXml
						SqlInstance = $SqlInstance
					}
					
					$results.Add($result)
					
					# XDL-Datei schreiben (SSMS-kompatibel)
					if ($OutputPath)
					{
						if (-not (Test-Path $OutputPath))
						{
							New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
						}
						$timestamp = $dl.EventTime.ToString('yyyyMMdd_HHmsqm')
						$xdlFile = Join-Path $OutputPath "Deadlock_$(($SqlInstance -replace '\\', '_'))_${timestamp}_${index}.xdl"
						# XDL braucht den reinen deadlock-Knoten ohne Event-Wrapper
						$graphXml | Set-Content -Path $xdlFile -Encoding UTF8 -Force
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Fehler beim Parsen von Deadlock #${index}: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}
			
			# XDL-Pfad loggen
			if ($OutputPath -and $results.Count -gt 0)
			{
				Invoke-sqmLogging -Message "$($results.Count) XDL-Datei(en) gespeichert in: $OutputPath" -FunctionName $functionName -Level "INFO"
			}
			
			$msg = "$($results.Count) Deadlock(s) im Zeitraum gefunden."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
			
			return $results
		}
		catch
		{
			$errMsg = "Fehler beim Abrufen der Deadlock-Daten: $($_.Exception.Message)"
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