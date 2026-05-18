<#
.SYNOPSIS
    Sammelbericht zum Gesundheitszustand aller Datenbanken auf einer Instanz.

.DESCRIPTION
    Prueft pro Datenbank:
    - Recovery-Modell
    - Letzte DBCC CHECKDB-Ausfuehrung und ob fehlerfrei
    - Letzte Backup-Zeiten (Full / Diff / Log)
    - AutoGrowth-Ereignisse der letzten -HistoryDays Tage (via Default Trace)
    - VLF-Anzahl (uebermaessig fragmentierte Transaction-Log-Dateien)
    - Datenbankgroesse (Data + Log)
    - Datenbankstatus (Online, Suspect, Restoring, ...)

    Die Ergebnisse werden als TXT-Bericht und CSV-Datei im angegebenen Verzeichnis gespeichert.
    Zusaetzlich gibt die Funktion ein Objekt mit den Detaildaten und den Dateipfaden zurueck.

.PARAMETER SqlInstance
    SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    Optionales PSCredential fuer die Verbindung.

.PARAMETER MaxCheckDbAgeDays
    Maximales Alter der letzten fehlerfreien DBCC CHECKDB in Tagen. Standard: 14.

.PARAMETER MaxVlfCount
    Warnschwelle fuer VLF-Anzahl pro Datenbank. Standard: 200.

.PARAMETER HistoryDays
    Zeitraum fuer AutoGrowth-Auswertung in Tagen. Standard: 30.

.PARAMETER ExcludeDatabase
    Datenbanken ausschliessen. Wildcards erlaubt.

.PARAMETER IncludeSystemDatabases
    System-Datenbanken (ausser tempdb) einbeziehen. Standard: $false.

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
    Get-sqmDatabaseHealth

.EXAMPLE
    Get-sqmDatabaseHealth -SqlInstance "SQL01" -IncludeSystemDatabases -OutputPath "D:\Reports"

.NOTES
    Autor:   MSSQLTools
    Voraussetzungen: dbatools, Invoke-sqmLogging
    Standard-Ausgabepfad: $env:ProgramData\sqmSQLTool\Logs
    VLF-Abfrage benoetigt SQL Server 2016+ (sys.dm_db_log_info). Bei aelteren Versionen wird VLF-Status als 'Unknown' angezeigt.
#>
function Get-sqmDatabaseHealth
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$MaxCheckDbAgeDays = 14,
		[Parameter(Mandatory = $false)]
		[int]$MaxVlfCount = 200,
		[Parameter(Mandatory = $false)]
		[int]$HistoryDays = 30,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
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
		
		# Hilfsfunktion fuer Ausschlusspruefung
		function _IsExcluded
		{
			param ([string]$Name,
				[string[]]$Patterns)
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade Datenbank-Health-Daten ..." -FunctionName $functionName -Level "INFO"
				
				# 1. Datenbanken abrufen (exkl. tempdb, Filter nach System/Exclude)
				$dbParams = @{ SqlInstance = $instance; SqlCredential = $SqlCredential; ErrorAction = 'Stop' }
				if ($EnableException) { $dbParams.EnableException = $true }
				$allDbs = Get-DbaDatabase @dbParams
				$databases = $allDbs | Where-Object {
					$_.Name -ne 'tempdb' -and
					($IncludeSystemDatabases -or -not $_.IsSystemObject) -and
					-not (_IsExcluded $_.Name $ExcludeDatabase)
				}
				
				if (-not $databases)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Datenbanken gefunden (nach Filterung)." -FunctionName $functionName -Level "WARNING"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Warning'
							Message	    = 'Keine Datenbanken nach Filterung'
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
						})
					continue
				}
				
				# 2. Letzte CHECKDB-Daten aus DBCC DBINFO (via DATABASEPROPERTYEX)
				$checkDbQuery = @"
SELECT
    db.name                                              AS DatabaseName,
    DATABASEPROPERTYEX(db.name, 'LastGoodCheckDbTime')  AS LastGoodCheckDb
FROM sys.databases db
WHERE db.name != 'tempdb';
"@
				$checkDbRows = Invoke-DbaQuery @connParams -Query $checkDbQuery -EnableException:$EnableException
				$checkDbLookup = @{ }
				foreach ($r in $checkDbRows) { $checkDbLookup[$r.DatabaseName] = $r.LastGoodCheckDb }
				
				# 3. Letzte Backups (Full, Diff, Log)
				$backupQuery = @"
SELECT database_name, type, MAX(backup_finish_date) AS LastBackup
FROM msdb.dbo.backupset
WHERE type IN ('D','I','L') AND is_copy_only = 0
GROUP BY database_name, type;
"@
				$backupRows = Invoke-DbaQuery @connParams -Query $backupQuery -EnableException:$EnableException
				$backupLookup = @{ }
				foreach ($r in $backupRows) { $backupLookup["$($r.database_name)|$($r.type)"] = $r.LastBackup }
				
				# 4. VLF-Anzahl pro DB (sys.dm_db_log_info ab SQL 2016)
				$vlfLookup = @{ }
				try
				{
					$vlfQuery = @"
SELECT DB_NAME(s.database_id) AS DatabaseName, COUNT(*) AS VlfCount
FROM sys.databases d
CROSS APPLY sys.dm_db_log_info(d.database_id) s
GROUP BY s.database_id;
"@
					$vlfRows = Invoke-DbaQuery @connParams -Query $vlfQuery -EnableException:$false -ErrorAction SilentlyContinue
					foreach ($r in $vlfRows) { $vlfLookup[$r.DatabaseName] = $r.VlfCount }
				}
				catch
				{
					Invoke-sqmLogging -Message "[$instance] VLF-Abfrage nicht unterstuetzt (SQL Server < 2016?)." -FunctionName $functionName -Level "VERBOSE"
				}
				
				# 5. AutoGrowth-Ereignisse aus Default Trace (letzte HistoryDays Tage)
				$agLookup = @{ }
				try
				{
					$autoGrowthQuery = @"
DECLARE @tracefile NVARCHAR(500);
SELECT @tracefile = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX('\', REVERSE(path)), 500)) + N'log.trc'
FROM sys.traces WHERE is_default = 1;

IF @tracefile IS NOT NULL
BEGIN
    SELECT
        DatabaseName,
        COUNT(*)            AS GrowthCount,
        SUM(IntegerData*8)  AS TotalGrowthKB
    FROM sys.fn_trace_gettable(@tracefile, DEFAULT)
    WHERE EventClass IN (92, 93)   -- DataFileAutoGrow, LogFileAutoGrow
      AND StartTime >= DATEADD(DAY, -$HistoryDays, GETDATE())
    GROUP BY DatabaseName;
END
"@
					$agRows = Invoke-DbaQuery @connParams -Query $autoGrowthQuery -EnableException:$false -ErrorAction SilentlyContinue
					foreach ($r in $agRows) { $agLookup[$r.DatabaseName] = $r }
				}
				catch
				{
					Invoke-sqmLogging -Message "[$instance] AutoGrowth-Abfrage fehlgeschlagen (Trace evtl. deaktiviert)." -FunctionName $functionName -Level "VERBOSE"
				}
				
				$now = Get-Date
				
				# 6. Detailzeilen fuer jede Datenbank
				foreach ($db in $databases)
				{
					$dbName = $db.Name
					
					# CHECKDB
					$lastCheckDb = $checkDbLookup[$dbName]
					$checkDbAgeD = if ($lastCheckDb) { ($now - $lastCheckDb).TotalDays }
					else { $null }
					$checkDbStatus = if (-not $lastCheckDb) { 'Unknown' }
					elseif ($checkDbAgeD -gt $MaxCheckDbAgeDays) { 'Warning' }
					else { 'OK' }
					
					# Backups
					$lastFull = $backupLookup["$dbName|D"]
					$lastLog = $backupLookup["$dbName|L"]
					
					# VLF
					$vlfCount = $vlfLookup[$dbName]
					$vlfStatus = if (-not $vlfCount) { 'Unknown' }
					elseif ($vlfCount -gt $MaxVlfCount) { 'Warning' }
					else { 'OK' }
					
					# AutoGrowth
					$agData = $agLookup[$dbName]
					$agCount = if ($agData) { $agData.GrowthCount }
					else { 0 }
					$agTotalKB = if ($agData) { $agData.TotalGrowthKB }
					else { 0 }
					
					# Gesamtstatus
					$overallStatus = if ($db.Status -ne 'Normal') { 'Critical' }
					elseif ($checkDbStatus -eq 'Warning' -or
						$vlfStatus -eq 'Warning') { 'Warning' }
					else { 'OK' }
					
					$detailRows.Add([PSCustomObject]@{
							SqlInstance    = $instance
							Database	   = $dbName
							DatabaseStatus = $db.Status
							RecoveryModel  = $db.RecoveryModel
							SizeMB		   = [math]::Round($db.Size, 1)
							LastCheckDb    = if ($lastCheckDb) { $lastCheckDb.ToString('yyyy-MM-dd') } else { '(unbekannt)' }
							CheckDbAgeDays = if ($checkDbAgeD) { [math]::Round($checkDbAgeD, 0) } else { $null }
							CheckDbStatus  = $checkDbStatus
							LastFullBackup = if ($lastFull) { $lastFull.ToString('yyyy-MM-dd HH:mm') } else { '(keins)' }
							LastLogBackup  = if ($lastLog) { $lastLog.ToString('yyyy-MM-dd HH:mm') } else { 'n/a' }
							VlfCount	   = $vlfCount
							VlfStatus	   = $vlfStatus
							AutoGrowthEvents = $agCount
							AutoGrowthTotalMB = [math]::Round($agTotalKB / 1024, 1)
							OverallStatus  = $overallStatus
						})
				}
				
				# 7. Berichtsdateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "DatabaseHealth_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "DatabaseHealth_${safeInst}_${datestamp}.csv"
				
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Database-Health-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					# TXT-Bericht
					$cntCrit = ($detailRows | Where-Object OverallStatus -eq 'Critical').Count
					$cntWarn = ($detailRows | Where-Object OverallStatus -eq 'Warning').Count
					$cntOk = ($detailRows | Where-Object OverallStatus -eq 'OK').Count
					
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# MSSQLTools - Datenbank Health Report")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# CheckDB max: ${MaxCheckDbAgeDays} Tage | VLF max: $MaxVlfCount | AutoGrowth: letzte $HistoryDays Tage")
					$lines.Add("# OK: $cntOk | Warning: $cntWarn | Critical: $cntCrit")
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-35} {1,-10} {2,-12} {3,-6} {4,-7} {5,-8} {6,-8} {7}" -f
							'Datenbank', 'Status', 'Recovery', 'SizeMB', 'CheckDB', 'VLF', 'AGEvts', 'Letztes Full'))
					$lines.Add(("-" * 110))
					
					foreach ($e in ($detailRows | Sort-Object OverallStatus, Database))
					{
						$dbNameShort = if ($e.Database.Length -gt 35) { $e.Database.Substring(0, 32) + '...' }
						else { $e.Database }
						$lines.Add(("{0,-35} {1,-10} {2,-12} {3,-6} {4,-7} {5,-8} {6,-8} {7}" -f
								$dbNameShort, $e.OverallStatus, $e.RecoveryModel, $e.SizeMB,
								$e.CheckDbAgeDays, $e.VlfCount, $e.AutoGrowthEvents, $e.LastFullBackup))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					
					# CSV-Datei
					$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
					
					Invoke-sqmLogging -Message "[$instance] Database-Health-Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
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
					DetailRows					     = $detailRows
					TxtFile						     = $txtFile
					CsvFile						     = $csvFile
					Status						     = if ($cntCrit -gt 0) { 'Critical' } elseif ($cntWarn -gt 0) { 'Warning' } else { 'OK' }
				}
				$allInstanceResults.Add($result)
				
				if ($cntCrit -gt 0)
				{
					Invoke-sqmLogging -Message "[$instance] $cntCrit Critical, $cntWarn Warning - Bericht: $txtFile" -FunctionName $functionName -Level "WARNING"
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
						DetailRows  = $null
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