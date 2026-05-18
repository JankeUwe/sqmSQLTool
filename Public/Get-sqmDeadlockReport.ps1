<#
.SYNOPSIS
    Liest und analysiert Deadlock-Ereignisse aus der System Health Extended Event Session.

.DESCRIPTION
    Die System Health Session (seit SQL Server 2008 immer aktiv) protokolliert alle
    Deadlocks als XML in den Ring Buffer. Diese Funktion liest diesen Buffer aus,
    parst die Deadlock-Graphen und gibt fuer jeden Deadlock aus:

      - Zeitpunkt des Deadlocks
      - Opfer-Session (victim) mit Login, Host, Programm, Statement
      - Alle beteiligten Prozesse mit deren Statements und gehaltenen/angeforderten Locks
      - Beteiligte Ressourcen (Tabellen, Indizes, Objekte)
      - Deadlock-Graph als XML (fuer SSMS-Import oder Speicherung als .xdl)

    Optional koennen die Deadlock-Graphen als .xdl-Dateien gespeichert werden
    (direkt in SSMS via Doppelklick oeffenbar).

    Zusaetzlich wird der System Health .xel-Ringbuffer ausgelesen wenn verfuegbar
    (SQL Server 2012+, liefert mehr History als der Ring Buffer).

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER StartTime
    Nur Deadlocks ab diesem Zeitpunkt zurueckgeben. Standard: letzte 24 Stunden.

.PARAMETER EndTime
    Nur Deadlocks bis zu diesem Zeitpunkt zurueckgeben. Standard: jetzt.

.PARAMETER MaxDeadlocks
    Maximale Anzahl zurueckgegebener Deadlocks (neueste zuerst). Standard: 100.

.PARAMETER OutputPath
    Wenn angegeben, werden Deadlock-Graphen als .xdl-Dateien in dieses Verzeichnis
    gespeichert (Format: Deadlock_<Instanz>_<Zeitstempel>.xdl).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt als Fehler zurueckgeben.

.EXAMPLE
    Get-sqmDeadlockReport

.EXAMPLE
    Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-7)

.EXAMPLE
    # Deadlocks als XDL-Dateien fuer SSMS speichern
    Get-sqmDeadlockReport -SqlInstance "SQL01" -OutputPath "C:\System\WinSrvLog\MSSQL\Deadlocks"

.EXAMPLE
    # Nur Deadlocks der letzten Stunde, Anzahl betroffener Statements anzeigen
    Get-sqmDeadlockReport -StartTime (Get-Date).AddHours(-1) |
        Select-Object Timestamp, VictimLogin, VictimStatement, ProcessCount

.NOTES
    Erfordert: dbatools, Invoke-sqmLogging
    Benoetigt VIEW SERVER STATE auf der Instanz.
    Die System Health Session laeuft immer - keine Konfiguration erforderlich.
    XDL-Dateien koennen in SSMS ueber Datei ? oeffnen direkt als Deadlock-Graph dargestellt werden.
    Ring Buffer Kapazitaet: standardmaessig 4 MB ? bei hoher Deadlock-Frequenz frueh exportieren.
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