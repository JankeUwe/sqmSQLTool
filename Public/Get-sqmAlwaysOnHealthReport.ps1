<#
.SYNOPSIS
    Creates a detailed health report for all Always On availability groups on an instance.

.DESCRIPTION
    Retrieves for each AG on the specified instance:
    - Synchronization status of all replicas
    - LSN lag between primary and secondaries (redo queue, send queue)
    - Database status per replica (Synchronized, Synchronizing, NotSynchronizing, ...)
    - Connection status of replicas
    - Listener configuration
    - Running AutoSeed operations

    Results are saved as a TXT report, CSV file, and HTML report in the specified directory.
    The function also returns an object with the detail data and file paths.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER MaxRedoQueueMB
    Warning threshold for the redo queue in MB. Default: 100.

.PARAMETER MaxSendQueueMB
    Warning threshold for the send queue in MB. Default: 50.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER OutputHtml
    Generate HTML report (in addition to TXT and CSV). Default: $true

.PARAMETER ContinueOnError
    Continue on error for an instance (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before writing files.

.PARAMETER WhatIf
    Shows which files would be created without actually writing them.

.EXAMPLE
    Get-sqmAgHealthReport

.EXAMPLE
    Get-sqmAgHealthReport -SqlInstance "SQL01" -MaxRedoQueueMB 200 -OutputPath "D:\Reports"

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools, Invoke-sqmLogging
    Default output path: C:\System\WinSrvLog\MSSQL
#>
function Get-sqmAlwaysOnHealthReport
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
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$OutputHtml = $true,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
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
				
				# SQL Server-Version ermitteln (2016=13, 2019=15, 2022=16, 2025=17)
				$sqlMajorVersion = 0
				try
				{
					$verRow = Invoke-DbaQuery @connParams -Query "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) AS V" -EnableException:$true -ErrorAction Stop
					$sqlMajorVersion = [int]$verRow.V
				}
				catch { $sqlMajorVersion = 0 }
				
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
    DB_NAME(adbrs.database_id)         AS DatabaseName,
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
ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name, DB_NAME(adbrs.database_id);
"@
				$dmvRows = Invoke-DbaQuery @connParams -Query $dmvQuery -EnableException:$EnableException
				
				# Laufende AutoSeed-Vorgaenge (ab SQL Server 2016) - versionsspezifisch
				# SQL 2019+ (v15): group_database_id, transferred/total_size_bytes, estimate_time_complete
				# SQL 2016/2017 (v13/v14): nur Basis-Spalten, kein group_database_id
				# SQL 2012/2014 (v<13): DMV existiert nicht - uebersprungen
				$seedQuery = $null
				if ($sqlMajorVersion -ge 15)
				{
					$seedQuery = @"
SELECT
    ag.name                        AS AgName,
    DB_NAME(adbrs.database_id)     AS DatabaseName,
    has.current_state              AS SeedState,
    has.performed_seeding_name     AS SeedingType,
    has.start_time,
    has.transferred_size_bytes,
    has.total_size_bytes,
    has.estimate_time_complete
FROM sys.dm_hadr_automatic_seeding  has
JOIN sys.availability_replicas       ar  ON ar.replica_id = has.local_physical_seeding_id
JOIN sys.availability_groups         ag  ON ag.group_id   = ar.group_id
JOIN sys.dm_hadr_database_replica_states adbrs
    ON adbrs.group_database_id = has.group_database_id
   AND adbrs.is_local = 1
WHERE has.completion_time IS NULL
ORDER BY has.start_time;
"@
				}
				elseif ($sqlMajorVersion -ge 13)
				{
					# SQL 2016 / 2017: keine group_database_id und keine neueren Groessen-Spalten
					$seedQuery = @"
SELECT
    ag.name                        AS AgName,
    DB_NAME(has.local_database_id) AS DatabaseName,
    has.current_state              AS SeedState,
    has.performed_seeding_name     AS SeedingType,
    has.start_time,
    CAST(NULL AS BIGINT)           AS transferred_size_bytes,
    CAST(NULL AS BIGINT)           AS total_size_bytes,
    CAST(NULL AS DATETIME2)        AS estimate_time_complete
FROM sys.dm_hadr_automatic_seeding  has
JOIN sys.availability_replicas       ar  ON ar.replica_id = has.local_physical_seeding_id
JOIN sys.availability_groups         ag  ON ag.group_id   = ar.group_id
WHERE has.completion_time IS NULL
ORDER BY has.start_time;
"@
				}
				$seedRows = $null
				if ($seedQuery)
				{
				try
				{
					# EnableException:$true erzwingt echte Exception statt dbatools-Warning
					# (sonst greift catch nie, Warning laeuft durch)
					$seedRows = Invoke-DbaQuery @connParams -Query $seedQuery -EnableException:$true
				}
				catch
				{
					if ($_.Exception.Message -match 'Invalid object name|Invalid column name')
					{
						Invoke-sqmLogging -Message "[$instance] sys.dm_hadr_automatic_seeding nicht verfuegbar oder Spalten inkompatibel (SQL Server < 2016 oder aelteres CU-Build). AutoSeed-ueberwachung uebersprungen." -FunctionName $functionName -Level "VERBOSE"
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
				}  # end if ($seedQuery)
				
				# Ergebniszeilen sammeln (pro Datenbank/Replikat)
				$healthRows = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($row in $dmvRows)
				{
					if (-not $row.DatabaseName) { continue } # Replikat ohne Datenbankzeile ueberspringen
					
					# NULL-sicher: bei disconnected Secondary liefert SQL NULL fuer Queue-Groessen
					$redoMB = [math]::Round([double]($row.RedoQueueKB -as [long]) / 1024, 1)
					$sendMB = [math]::Round([double]($row.SendQueueKB -as [long]) / 1024, 1)
					
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
				$htmlFile = Join-Path $OutputPath "AgHealthReport_${safeInst}_${datestamp}.html"
				
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
					$lines.Add("# sqmSQLTool - Always On Health Report")
					$lines.Add("# $(Get-sqmReportReference)")
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

					# HTML-Bericht erstellen (falls gewuenscht)
					if ($OutputHtml)
					{
						$htmlContent = _GenerateAlwaysOnHealthHtml -HealthRows $healthRows -Instance $instance -Timestamp $timestamp -MaxRedoQueueMB $MaxRedoQueueMB -MaxSendQueueMB $MaxSendQueueMB
						$htmlContent | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
						Invoke-sqmLogging -Message "[$instance] HTML-Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
					}
					else
					{
						$htmlFile = $null
					}

					Invoke-sqmOpenReport -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$instance] Health-Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
					$htmlFile = $null
				}
				
				# Ergebnisobjekt fuer diese Instanz
				$result = [PSCustomObject]@{
					SqlInstance					     = $instance
					Timestamp					     = $timestamp
					HealthRows					     = $healthRows
					TxtFile						     = $txtFile
					CsvFile						     = $csvFile
					HtmlFile					     = $htmlFile
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
						HtmlFile    = $null
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

# ============ Helper Functions ============

function _GenerateAlwaysOnHealthHtml
{
	param(
		[PSCustomObject[]]$HealthRows,
		[string]$Instance,
		[string]$Timestamp,
		[int]$MaxRedoQueueMB,
		[int]$MaxSendQueueMB
	)

	$reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
	$cntCritical = ($HealthRows | Where-Object OverallStatus -eq 'Critical').Count
	$cntWarning = ($HealthRows | Where-Object OverallStatus -eq 'Warning').Count
	$cntOk = ($HealthRows | Where-Object OverallStatus -eq 'OK').Count
	$totalAgs = ($HealthRows | Select-Object -ExpandProperty AgName -Unique).Count

	$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<title>Always On Health Report</title>
	<style>
		* { margin: 0; padding: 0; box-sizing: border-box; }
		body {
			font-family: 'Segoe UI', Arial, sans-serif;
			background: #0f172a;
			color: #e2e8f0;
			padding: 20px;
		}
		.container { max-width: 1800px; margin: 0 auto; }

		.header {
			background: linear-gradient(160deg, #1e3a8a 0%, #2e5090 100%);
			padding: 30px;
			border-radius: 12px;
			margin-bottom: 30px;
			border-left: 4px solid #3b82f6;
		}

		.header h1 {
			color: #60a5fa;
			font-size: 2em;
			margin-bottom: 10px;
		}

		.header p {
			color: #94a3b8;
			font-size: 0.95em;
		}

		.stats {
			display: grid;
			grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
			gap: 15px;
			margin-bottom: 30px;
		}

		.stat-card {
			background: #0b1e3d;
			border: 1px solid #3b82f6;
			padding: 20px;
			border-radius: 8px;
			text-align: center;
		}

		.stat-value {
			font-size: 2.2em;
			font-weight: bold;
			margin-bottom: 5px;
		}

		.stat-label {
			color: #94a3b8;
			font-size: 0.9em;
		}

		.stat-card:nth-child(1) .stat-value { color: #60a5fa; }
		.stat-card:nth-child(2) .stat-value { color: #34d399; }
		.stat-card:nth-child(3) .stat-value { color: #f59e0b; }
		.stat-card:nth-child(4) .stat-value { color: #ef4444; }

		.controls {
			display: flex;
			gap: 10px;
			margin-bottom: 20px;
			flex-wrap: wrap;
		}

		.controls input {
			background: #0b1e3d;
			border: 1px solid #3b82f6;
			color: #e2e8f0;
			padding: 10px;
			border-radius: 6px;
			flex: 1;
			min-width: 200px;
		}

		.controls button {
			background: #1e3a8a;
			border: 1px solid #3b82f6;
			color: #60a5fa;
			padding: 10px 20px;
			border-radius: 6px;
			cursor: pointer;
			font-weight: bold;
		}

		.controls button:hover { background: #2e5090; }

		.section-title {
			color: #5dade2;
			font-size: 1.3em;
			margin-top: 30px;
			margin-bottom: 15px;
			font-weight: 600;
			border-bottom: 2px solid #3b82f6;
			padding-bottom: 10px;
		}

		table {
			width: 100%;
			border-collapse: collapse;
			background: #0b1e3d;
			border-radius: 8px;
			overflow: hidden;
			margin-bottom: 30px;
		}

		th {
			background: #1e3a8a;
			color: #60a5fa;
			padding: 15px;
			text-align: left;
			font-weight: 600;
			border-bottom: 2px solid #3b82f6;
		}

		td {
			padding: 12px 15px;
			border-bottom: 1px solid #2d5a8c;
		}

		tr:hover { background: #1a2f4d; }

		.ag-name {
			color: #60a5fa;
			font-weight: 600;
		}

		.replica-name {
			font-family: monospace;
			color: #e2e8f0;
		}

		.status-critical {
			color: #ef4444;
			font-weight: bold;
		}

		.status-warning {
			color: #f59e0b;
			font-weight: bold;
		}

		.status-ok {
			color: #34d399;
			font-weight: bold;
		}

		.role-primary {
			background: rgba(59, 130, 246, 0.1);
			color: #60a5fa;
			padding: 2px 8px;
			border-radius: 4px;
			font-weight: 600;
		}

		.role-secondary {
			background: rgba(148, 163, 184, 0.1);
			color: #cbd5e1;
			padding: 2px 8px;
			border-radius: 4px;
		}

		.sync-synchronized {
			color: #34d399;
		}

		.sync-synchronizing {
			color: #f59e0b;
		}

		.sync-not-synchronized {
			color: #ef4444;
		}

		.queue-normal {
			color: #34d399;
		}

		.queue-warning {
			color: #f59e0b;
		}

		.queue-critical {
			color: #ef4444;
		}

		.footer {
			color: #94a3b8;
			font-size: 0.85em;
			text-align: center;
			margin-top: 50px;
			padding-top: 20px;
			border-top: 1px solid #3b82f6;
		}

		.hidden { display: none; }
	</style>
</head>
<body>
	<div class="container">
		<div class="header">
			<h1>📊 Always On Health Report</h1>
			<p>Instance: <strong>$Instance</strong> | Generated: $reportDate</p>
		</div>

		<div class="stats">
			<div class="stat-card">
				<div class="stat-value">$totalAgs</div>
				<div class="stat-label">Total AGs</div>
			</div>
			<div class="stat-card">
				<div class="stat-value">$cntOk</div>
				<div class="stat-label">OK Status</div>
			</div>
			<div class="stat-card">
				<div class="stat-value">$cntWarning</div>
				<div class="stat-label">Warning Issues</div>
			</div>
			<div class="stat-card">
				<div class="stat-value">$cntCritical</div>
				<div class="stat-label">Critical Issues</div>
			</div>
		</div>

		<div class="controls">
			<input type="text" id="searchBox" placeholder="Search AG name, replica, or database..." onkeyup="filterTable()">
			<button onclick="sortTable('AgName')">Sort by AG</button>
			<button onclick="sortTable('Status')">Sort by Status</button>
		</div>

		<div class="section-title">Replica & Database Status</div>

		<table id="healthTable">
			<thead>
				<tr>
					<th style="width: 15%;">AG Name</th>
					<th style="width: 15%;">Replica Name</th>
					<th style="width: 8%;">Role</th>
					<th style="width: 15%;">Database</th>
					<th style="width: 12%;">Sync State</th>
					<th style="width: 10%;">Connection</th>
					<th style="width: 10%;">Redo Queue (MB)</th>
					<th style="width: 10%;">Send Queue (MB)</th>
					<th style="width: 8%;">Status</th>
				</tr>
			</thead>
			<tbody>
"@

	# Add table rows
	foreach ($row in $HealthRows) {
		$statusClass = switch ($row.OverallStatus) {
			'Critical' { 'status-critical' }
			'Warning' { 'status-warning' }
			default { 'status-ok' }
		}

		$syncClass = switch ($row.DbSyncState) {
			'SYNCHRONIZED' { 'sync-synchronized' }
			'SYNCHRONIZING' { 'sync-synchronizing' }
			default { 'sync-not-synchronized' }
		}

		$roleClass = if ($row.Role -eq 'PRIMARY') { 'role-primary' } else { 'role-secondary' }

		# Queue styling
		$redoClass = if ($row.Role -eq 'PRIMARY') { 'queue-normal' }
		elseif ($row.RedoQueueMB -gt $MaxRedoQueueMB) { 'queue-critical' }
		else { 'queue-normal' }

		$sendClass = if ($row.SendQueueMB -gt $MaxSendQueueMB) { 'queue-warning' }
		else { 'queue-normal' }

		$connectionState = if ($row.ConnectionState -eq 'CONNECTED') { '<span style="color: #34d399;">Connected</span>' }
		else { '<span style="color: #ef4444;">Disconnected</span>' }

		$html += @"
				<tr>
					<td class="ag-name">$($row.AgName)</td>
					<td class="replica-name">$($row.ReplicaName)</td>
					<td><span class="$roleClass">$($row.Role)</span></td>
					<td>$($row.DatabaseName)</td>
					<td class="$syncClass">$($row.DbSyncState)</td>
					<td>$connectionState</td>
					<td class="$redoClass">$($row.RedoQueueMB)</td>
					<td class="$sendClass">$($row.SendQueueMB)</td>
					<td class="$statusClass">$($row.OverallStatus)</td>
				</tr>
"@
	}

	$html += @"
			</tbody>
		</table>

		<div class="footer">
			<p>Generated by sqmSQLTool | Get-sqmAlwaysOnHealthReport</p>
			<p>Configuration: RedoQueue Threshold=$MaxRedoQueueMB MB | SendQueue Threshold=$MaxSendQueueMB MB</p>
			<p>Report ID: $Timestamp</p>
		</div>
	</div>

	<script>
		function filterTable() {
			const input = document.getElementById('searchBox');
			const filter = input.value.toLowerCase();
			const table = document.getElementById('healthTable');
			const rows = table.getElementsByTagName('tr');

			for (let i = 1; i < rows.length; i++) {
				const agName = rows[i].cells[0].textContent.toLowerCase();
				const replicaName = rows[i].cells[1].textContent.toLowerCase();
				const dbName = rows[i].cells[3].textContent.toLowerCase();
				const match = agName.includes(filter) || replicaName.includes(filter) || dbName.includes(filter);
				rows[i].style.display = match ? '' : 'none';
			}
		}

		function sortTable(column) {
			const table = document.getElementById('healthTable');
			const tbody = table.querySelector('tbody');
			const rows = Array.from(tbody.querySelectorAll('tr'));

			const columnIndex = {
				'AgName': 0,
				'Status': 8
			}[column] || 0;

			rows.sort((a, b) => {
				const aText = a.cells[columnIndex].textContent.trim();
				const bText = b.cells[columnIndex].textContent.trim();
				return aText.localeCompare(bText);
			});

			rows.forEach(row => tbody.appendChild(row));
		}
	</script>
</body>
</html>
"@

	return $html
}

