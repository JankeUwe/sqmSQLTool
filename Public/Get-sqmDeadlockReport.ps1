<#
.SYNOPSIS
    Reads and analyzes deadlock events from the System Health Extended Event session.

.DESCRIPTION
    The System Health session (always active since SQL Server 2008) logs all
    deadlocks as XML, both in its ring buffer (in memory, a few MB, often only
    hours or days) and in its event_file target (system_health*.xel in the LOG
    folder, usually weeks). This function reads both by default, removes the
    duplicates, parses the deadlock graphs and returns for each deadlock:

      - Timestamp of the deadlock
      - Victim session with login, host, program, statement
      - All involved processes with their statements and held/requested locks
      - Involved resources (tables, indexes, objects)
      - Deadlock graph as XML (for SSMS import or storage as .xdl)

    Optionally, deadlock graphs can be saved as .xdl files
    (openable directly in SSMS by double-click).

    Timestamps: XEvents store UTC. -StartTime/-EndTime are local times and are converted;
    Timestamp in the result is local time, TimestampUtc the original value.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER StartTime
    Return only deadlocks from this point in time. Default: last 24 hours.

.PARAMETER EndTime
    Return only deadlocks up to this point in time. Default: now.

.PARAMETER Source
    Where to read from: Both (default), RingBuffer, EventFile. EventFile needs
    SQL Server 2012 or later; if it cannot be read, Both falls back to the ring buffer
    with a warning.

.PARAMETER MaxDeadlocks
    Maximum number of deadlocks returned (newest first). Default: 100.

.PARAMETER OutputPath
    Directory for the XDL graphs and the HTML summary report
    (format: Deadlock_<Instance>_<Timestamp>.xdl). Default: <OutputPath config>\DeadlockReport.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.PARAMETER NoOpen
    Do not automatically open the HTML summary report after creation (only relevant with -OutputPath).

.EXAMPLE
    Get-sqmDeadlockReport

.EXAMPLE
    Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-7)

.EXAMPLE
    # Last 15 days from the .xel files only
    Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-15) -Source EventFile

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
    Ring buffer capacity: 4 MB by default. The event_file keeps more history (SQL Server 2019+:
    4 files x 100 MB by default, older versions 4 x 5 MB); export early at high deadlock frequency.
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
		[ValidateSet('Both', 'RingBuffer', 'EventFile')]
		[string]$Source = 'Both',
		[Parameter(Mandatory = $false)]
		[int]$MaxDeadlocks = 100,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'DeadlockReport'),
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
		
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance ($($StartTime.ToString('yyyy-MM-dd HH:mm')) bis $($EndTime.ToString('yyyy-MM-dd HH:mm')))" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			# XEvent-Zeitstempel sind UTC - Filtergrenzen umrechnen
			$fromUtc = $StartTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
			$toUtc = $EndTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
			$collected = [System.Collections.Generic.List[object]]::new()

			# -----------------------------------------------------------------------
			# a) Ring Buffer (alle Versionen ab SQL Server 2008)
			# -----------------------------------------------------------------------
			if ($Source -in 'Both', 'RingBuffer')
			{
				$ringBufferQuery = @"
SELECT
    xdr.value('@timestamp', 'datetime2')             AS EventTime,
    xdr.query('(data/value/deadlock)[1]')            AS DeadlockGraph
FROM (
    SELECT CAST(target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets t
    INNER JOIN sys.dm_xe_sessions s ON t.event_session_address = s.address
    WHERE s.name = 'system_health'
      AND t.target_name = 'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData(xdr)
WHERE xdr.value('@timestamp', 'datetime2') >= '$fromUtc'
  AND xdr.value('@timestamp', 'datetime2') <= '$toUtc'
"@
				$rb = @(Invoke-DbaQuery @connParams -Database master -Query $ringBufferQuery -EnableException)
				foreach ($r in $rb) { $collected.Add($r) }
				Invoke-sqmLogging -Message "$($rb.Count) Deadlock-Ereignis(se) im Ring Buffer gefunden." -FunctionName $functionName -Level "INFO"
			}

			# -----------------------------------------------------------------------
			# b) event_file (system_health*.xel, SQL Server 2012+). Pfad aus dem Target,
			#    damit auch ein verlegter LOG-Ordner und Linux-Pfade funktionieren.
			# -----------------------------------------------------------------------
			if ($Source -in 'Both', 'EventFile')
			{
				try
				{
					$fileName = (Invoke-DbaQuery @connParams -Database master -EnableException -Query @"
SELECT CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(4000)') AS FileName
FROM sys.dm_xe_session_targets t
INNER JOIN sys.dm_xe_sessions s ON t.event_session_address = s.address
WHERE s.name = 'system_health' AND t.target_name = 'event_file'
"@).FileName
					if ($null -eq $fileName -or $fileName -is [DBNull] -or [string]::IsNullOrWhiteSpace([string]$fileName))
					{
						throw "system_health hat kein aktives event_file-Target."
					}
					$pattern = ([regex]::Match([string]$fileName, '^.*[\\/]').Value) + 'system_health*.xel'
					$patternSql = $pattern -replace "'", "''"
					$fileQuery = @"
SELECT x.EventTime, x.ev.query('(event/data/value/deadlock)[1]') AS DeadlockGraph
FROM sys.fn_xe_file_target_read_file(N'$patternSql', NULL, NULL, NULL) f
CROSS APPLY (SELECT CAST(f.event_data AS xml) AS ev) e
CROSS APPLY (SELECT e.ev, e.ev.value('(event/@timestamp)[1]', 'datetime2') AS EventTime) x
WHERE f.object_name = N'xml_deadlock_report'
  AND x.EventTime >= '$fromUtc'
  AND x.EventTime <= '$toUtc'
"@
					$ef = @(Invoke-DbaQuery @connParams -Database master -Query $fileQuery -QueryTimeout 600 -EnableException)
					foreach ($r in $ef) { $collected.Add($r) }
					Invoke-sqmLogging -Message "$($ef.Count) Deadlock-Ereignis(se) in $pattern gefunden." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$msg = "system_health event_file nicht lesbar: $($_.Exception.Message)"
					if ($Source -eq 'EventFile') { throw $msg }
					Write-Warning "$msg - nur Ring Buffer ausgewertet."
					Invoke-sqmLogging -Message "$msg - nur Ring Buffer ausgewertet." -FunctionName $functionName -Level "WARNING"
				}
			}

			# Gleicher Deadlock steht in beiden Quellen: ueber Zeitstempel + Graph entdoppeln
			$seen = New-Object 'System.Collections.Generic.HashSet[string]'
			$rawDeadlocks = @($collected | Sort-Object -Property EventTime -Descending | Where-Object {
				$seen.Add(([datetime]$_.EventTime).Ticks.ToString() + '|' + $_.DeadlockGraph.ToString())
			})

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			$index = 0
			
			foreach ($dl in $rawDeadlocks)
			{
				if ($index -ge $MaxDeadlocks) { break }
				$index++
				
				try
				{
					# Deadlock-Graph XML parsen. Die SQL-Query liefert bereits den <deadlock>-Knoten
					# direkt (xdr.query('(data/value/deadlock)[1]'), wie im bewaehrten DeadlockCollector-
					# Projekt - NICHT den ganzen <event>-Knoten. Ein frueherer Versuch, stattdessen den
					# ganzen <event>-Knoten zu holen (xdr.query('.')) und in PowerShell ueber
					# $dlXml.event.'data'.value.'deadlock' zum <deadlock>-Knoten zu navigieren, scheiterte
					# lautlos (0 Treffer statt Fehler), sobald <event> mehr als ein <data>-Kind hat -
					# $dlXml.event.'data' wird dann ein Array statt eines einzelnen Elements.
					[xml]$dlXml = $dl.DeadlockGraph.ToString()
					$deadlockNode = $dlXml.deadlock

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
					
					$eventUtc = [datetime]::SpecifyKind([datetime]$dl.EventTime, [System.DateTimeKind]::Utc)
					$result = [PSCustomObject]@{
						Timestamp = $eventUtc.ToLocalTime()
						TimestampUtc = $eventUtc
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
						$timestamp = $eventUtc.ToLocalTime().ToString('yyyyMMdd_HHmmss')
						$xdlFile = Join-Path $OutputPath "Deadlock_$(($SqlInstance -replace '[\\/:*?"<>|,]', '_'))_${timestamp}_${index}.xdl"
						# XDL braucht den reinen deadlock-Knoten ohne Event-Wrapper
						$graphXml | Set-Content -Path $xdlFile -Encoding UTF8 -Force
						$result | Add-Member -NotePropertyName XdlFile -NotePropertyValue $xdlFile -Force
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Fehler beim Parsen von Deadlock #${index}: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}
			
			# XDL-Pfad loggen + HTML-Summary-Bericht schreiben
			if ($OutputPath -and $results.Count -gt 0)
			{
				Invoke-sqmLogging -Message "$($results.Count) XDL-Datei(en) gespeichert in: $OutputPath" -FunctionName $functionName -Level "INFO"

				$rowsHtml = foreach ($r in $results)
				{
					$xdlLink = if ($r.XdlFile) { "<a href='$([System.IO.Path]::GetFileName($r.XdlFile))'>XDL</a>" } else { '' }
					"<tr><td class='crit'>$($r.Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$([System.Net.WebUtility]::HtmlEncode($r.VictimLogin))</td><td>$([System.Net.WebUtility]::HtmlEncode($r.VictimHost))</td><td>$([System.Net.WebUtility]::HtmlEncode($r.VictimProgram))</td><td>$($r.ProcessCount)</td><td>$([System.Net.WebUtility]::HtmlEncode($r.VictimStatement))</td><td>$xdlLink</td></tr>"
				}
				$bodyHtml = "<p>$($results.Count) Deadlock(s) im Zeitraum $($StartTime.ToString('yyyy-MM-dd HH:mm')) bis $($EndTime.ToString('yyyy-MM-dd HH:mm')).</p>" +
					"<table><tr><th>Zeitpunkt</th><th>Victim Login</th><th>Victim Host</th><th>Victim Program</th><th>Prozesse</th><th>Victim Statement</th><th>Graph</th></tr>" +
					($rowsHtml -join '') + "</table>"
				$html = ConvertTo-sqmHtmlReport -Title "Deadlock Report - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml

				$safeInst = $SqlInstance -replace '[\\/:*?"<>|,]', '_'
				$htmlFile = Join-Path $OutputPath "DeadlockReport_${safeInst}_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "HTML-Bericht gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"

				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
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