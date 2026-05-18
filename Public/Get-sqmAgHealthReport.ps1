<#
.SYNOPSIS
    Erstellt einen detaillierten Zustandsbericht aller Always On-Verfuegbarkeitsgruppen auf einer Instanz.

.DESCRIPTION
    Ermittelt fuer jede AG auf der angegebenen Instanz:
    - Synchronisierungsstatus aller Replikate
    - LSN-Lag zwischen Primary und Secondaries (Redo-Queue, Send-Queue)
    - Datenbankstatus pro Replikat (Synchronized, Synchronizing, NotSynchronizing, ...)
    - Verbindungsstatus der Replikate
    - Listener-Konfiguration
    - Laufende AutoSeed-Vorgaenge

    Die Ergebnisse werden als TXT-Bericht und CSV-Datei im angegebenen Verzeichnis gespeichert.
    Zusaetzlich gibt die Funktion ein Objekt mit den Detaildaten und den Dateipfaden zurueck.

.PARAMETER SqlInstance
    SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    Optionales PSCredential fuer die Verbindung.

.PARAMETER MaxRedoQueueMB
    Warnschwelle fuer die Redo-Queue in MB. Standard: 100.

.PARAMETER MaxSendQueueMB
    Warnschwelle fuer die Send-Queue in MB. Standard: 50.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer die Berichtsdateien. Standard: $env:ProgramData\sqmSQLTool\Logs

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz fortfahren (ansonsten wird der Fehler ausgeloest).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (ueberschreibt ContinueOnError).

.PARAMETER Confirm
    Fordert vor dem Schreiben der Dateien eine Bestaetigung an.

.PARAMETER WhatIf
    Zeigt, welche Dateien erstellt wuerden, ohne sie tatsaechlich zu schreiben.

.EXAMPLE
    Get-sqmAgHealthReport

.EXAMPLE
    Get-sqmAgHealthReport -SqlInstance "SQL01" -MaxRedoQueueMB 200 -OutputPath "D:\Reports"

.NOTES
    Autor:   MSSQLTools
    Voraussetzungen: dbatools, Invoke-sqmLogging
    Standard-Ausgabepfad: $env:ProgramData\sqmSQLTool\Logs
#>
function Get-sqmAgHealthReport
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$MaxRedoQueueMB = 100,
		[Parameter(Mandatory = $false)]
		[int]$MaxSendQueueMB = 50,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = '$env:ProgramData\sqmSQLTool\Logs',
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade Always On-Informationen ..." -FunctionName $functionName -Level "INFO"
				
				# Verfuegbarkeitsgruppen abrufen
				$ags = Get-DbaAvailabilityGroup @connParams -ErrorAction Stop
				if (-not $ags)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Verfuegbarkeitsgruppen vorhanden." -FunctionName $functionName -Level "INFO"
					continue
				}
				
				# DMV-Abfrage: Replikat- und Datenbankstatus mit Queues
				$dmvQuery = @"
SELECT
    ag.name                           AS AgName,
    ar.replica_server_name            AS ReplicaName,
    ar.availability_mode_desc         AS AvailabilityMode,
    ar.failover_mode_desc             AS FailoverMode,
    ars.role_desc                     AS Role,
    ars.connected_state_desc          AS ConnectionState,
    ars.synchronization_health_desc   AS SyncHealth,
    adbrs.database_name               AS DatabaseName,
    adbrs.synchronization_state_desc  AS DbSyncState,
    adbrs.synchronization_health_desc AS DbSyncHealth,
    adbrs.redo_queue_size             AS RedoQueueKB,
    adbrs.log_send_queue_size         AS SendQueueKB,
    adbrs.redo_rate                   AS RedoRateKBs,
    adbrs.log_send_rate               AS SendRateKBs,
    adbrs.is_suspended                AS IsSuspended
FROM sys.availability_groups              ag
JOIN sys.availability_replicas            ar    ON ar.group_id    = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states adbrs ON adbrs.replica_id = ar.replica_id
ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name, adbrs.database_name;
"@
				$dmvRows = Invoke-DbaQuery @connParams -Query $dmvQuery -EnableException:$EnableException
				
				# Laufende AutoSeed-Vorgaenge (ab SQL Server 2016)
				$seedQuery = @"
SELECT
    ag.name                       AS AgName,
    adbrs.database_name           AS DatabaseName,
    has.current_state             AS SeedState,
    has.performed_seeding_name    AS SeedingType,
    has.start_time,
    has.transferred_size_bytes,
    has.total_size_bytes,
    has.estimate_time_complete
FROM sys.dm_hadr_automatic_seeding  has
JOIN sys.availability_replicas       ar  ON ar.replica_id = has.local_physical_seeding_id
JOIN sys.availability_groups         ag  ON ag.group_id   = ar.group_id
JOIN sys.dm_hadr_database_replica_states adbrs
    ON adbrs.group_database_id = has.group_database_id
WHERE has.completion_time IS NULL
ORDER BY has.start_time;
"@
				$seedRows = $null
				try
				{
					$seedRows = Invoke-DbaQuery @connParams -Query $seedQuery -EnableException:$EnableException -ErrorAction Stop
				}
				catch
				{
					if ($_.Exception.Message -match 'Invalid object name')
					{
						Invoke-sqmLogging -Message "[$instance] sys.dm_hadr_automatic_seeding nicht verfuegbar (SQL Server < 2016). AutoSeed-ueberwachung uebersprungen." -FunctionName $functionName -Level "VERBOSE"
					}
					elseif (-not $EnableException)
					{
						Invoke-sqmLogging -Message "[$instance] Fehler beim Lesen der AutoSeed-Daten: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
					else
					{
						throw
					}
				}
				
				# Ergebniszeilen sammeln (pro Datenbank/Replikat)
				$healthRows = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($row in $dmvRows)
				{
					if (-not $row.DatabaseName) { continue } # Replikat ohne Datenbankzeile ueberspringen
					
					$redoMB = [math]::Round($row.RedoQueueKB / 1024, 1)
					$sendMB = [math]::Round($row.SendQueueKB / 1024, 1)
					
					$queueStatus = if ($row.Role -ne 'PRIMARY' -and $redoMB -gt $MaxRedoQueueMB) { 'Warning' }
					elseif ($sendMB -gt $MaxSendQueueMB) { 'Warning' }
					else { 'OK' }
					
					$syncOk = ($row.DbSyncState -in @('SYNCHRONIZED', 'SYNCHRONIZING')) -and
					$row.ConnectionState -eq 'CONNECTED' -and
					-not $row.IsSuspended
					
					$overallStatus = if (-not $syncOk) { 'Critical' }
					elseif ($queueStatus -eq 'Warning') { 'Warning' }
					else { 'OK' }
					
					$healthRows.Add([PSCustomObject]@{
							SqlInstance = $instance
							AgName	    = $row.AgName
							ReplicaName = $row.ReplicaName
							Role	    = $row.Role
							AvailabilityMode = $row.AvailabilityMode
							ConnectionState = $row.ConnectionState
							SyncHealth  = $row.SyncHealth
							DatabaseName = $row.DatabaseName
							DbSyncState = $row.DbSyncState
							IsSuspended = $row.IsSuspended
							RedoQueueMB = $redoMB
							SendQueueMB = $sendMB
							RedoRateKBs = $row.RedoRateKBs
							SendRateKBs = $row.SendRateKBs
							OverallStatus = $overallStatus
						})
				}
				
				# AutoSeed-Eintraege hinzufuegen (falls vorhanden)
				if ($seedRows)
				{
					foreach ($s in $seedRows)
					{
						$pctComplete = if ($s.total_size_bytes -gt 0)
						{
							[math]::Round($s.transferred_size_bytes / $s.total_size_bytes * 100, 1)
						}
						else { 0 }
						$dbSyncState = "AutoSeed: $($s.SeedState) - $pctComplete%"
						$healthRows.Add([PSCustomObject]@{
								SqlInstance = $instance
								AgName	    = $s.AgName
								ReplicaName = '(AutoSeed)'
								Role	    = 'SEEDING'
								AvailabilityMode = 'Automatic'
								ConnectionState = 'CONNECTED'
								SyncHealth  = 'SEEDING_IN_PROGRESS'
								DatabaseName = $s.DatabaseName
								DbSyncState = $dbSyncState
								IsSuspended = $false
								RedoQueueMB = 0
								SendQueueMB = 0
								RedoRateKBs = 0
								SendRateKBs = 0
								OverallStatus = 'Warning'
							})
					}
				}
				
				# Berichtsdateien schreiben (nur wenn -WhatIf nicht aktiv)
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "AgHealthReport_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "AgHealthReport_${safeInst}_${datestamp}.csv"
				
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Health-Bericht in $OutputPath"))
				{
					# Verzeichnis anlegen
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					# TXT-Bericht erstellen
					$cntCrit = ($healthRows | Where-Object OverallStatus -eq 'Critical').Count
					$cntWarn = ($healthRows | Where-Object OverallStatus -eq 'Warning').Count
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# MSSQLTools - Always On Health Report")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# RedoQueue max: ${MaxRedoQueueMB} MB | SendQueue max: ${MaxSendQueueMB} MB")
					$lines.Add("# Critical: $cntCrit | Warning: $cntWarn")
					$lines.Add("# ================================================================")
					
					foreach ($ag in ($healthRows | Group-Object AgName))
					{
						$lines.Add(""); $lines.Add("# AG: $($ag.Name)")
						$lines.Add(("{0,-30} {1,-10} {2,-8} {3,-25} {4,-12} {5,-8} {6}" -f
								'Replikat', 'Status', 'Role', 'DB-SyncState', 'Connection', 'RedoMB', 'SendMB'))
						$lines.Add(("-" * 115))
						foreach ($e in ($ag.Group | Sort-Object Role, ReplicaName, DatabaseName))
						{
							$repName = $e.ReplicaName
							if ($repName.Length -gt 30) { $repName = $repName.Substring(0, 27) + '...' }
							$dbSync = $e.DbSyncState
							if ($dbSync.Length -gt 25) { $dbSync = $dbSync.Substring(0, 22) + '...' }
							$lines.Add(("{0,-30} {1,-10} {2,-8} {3,-25} {4,-12} {5,-8} {6}" -f
									$repName, $e.OverallStatus, $e.Role, $dbSync,
									$e.ConnectionState, $e.RedoQueueMB, $e.SendQueueMB))
						}
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					
					# CSV-Datei erstellen
					$healthRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
					
					Invoke-sqmLogging -Message "[$instance] Health-Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
				}
				
				# Ergebnisobjekt fuer diese Instanz
				$result = [PSCustomObject]@{
					SqlInstance					     = $instance
					Timestamp					     = $timestamp
					HealthRows					     = $healthRows
					TxtFile						     = $txtFile
					CsvFile						     = $csvFile
					Status						     = if ($cntCrit -gt 0) { 'Critical' } elseif ($cntWarn -gt 0) { 'Warning' } else { 'OK' }
				}
				$allInstanceResults.Add($result)
				
				if ($cntCrit -gt 0)
				{
					Invoke-sqmLogging -Message "[$instance] $cntCrit Critical AG-Issue(s) - Bericht: $txtFile" -FunctionName $functionName -Level "WARNING"
				}
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status	    = 'Error'
						Message	    = $errMsg
						HealthRows  = $null
						TxtFile	    = $null
						CsvFile	    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanzen verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}