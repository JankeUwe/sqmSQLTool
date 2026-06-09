<#
.SYNOPSIS
    Creates structured HTML and CSV documentation for all databases on a SQL Server instance.

.DESCRIPTION
    Documents per database:
    - General properties (status, recovery model, collation, owner, creation date, compatibility level)
    - Size (data, log, total in MB)
    - Filegroups and files (name, path, size, autogrow, growth type)
    - Last backup times (full, diff, log)
    - Last DBCC CHECKDB execution
    - VLF count (SQL Server 2016+)
    - Object summary (tables, views, procedures, functions, triggers)
    - Database users (name, login name, type)
    - Extended properties of the database

    Output is generated as:
    - HTML file with formatted report (self-contained, no external CSS)
    - CSV file for machine processing

    Default output path is read from the module configuration (OutputPath).
    If CentralPath is configured, files are additionally copied there.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the SQL connection.

.PARAMETER Database
    Document specific databases only. Wildcards allowed (e.g. 'Sales*').
    Default: all user databases.

.PARAMETER IncludeSystemDatabases
    Include system databases (master, model, msdb, tempdb). Default: $false.

.PARAMETER IncludeFileDetails
    Include filegroup and file details in the report. Default: $true.

.PARAMETER IncludeUsers
    Include database users in the report. Default: $true.

.PARAMETER IncludeObjectSummary
    Include object summary (tables, SPs, views, etc.) in the report. Default: $true.

.PARAMETER OutputPath
    Output directory. Default: value from module configuration (Get-sqmDefaultOutputPath).

.PARAMETER ContinueOnError
    Continue on error for an instance or database instead of aborting.

.PARAMETER EnableException
    Throw exceptions directly (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before writing output files.

.PARAMETER WhatIf
    Simulation: shows which files would be created without writing them.

.EXAMPLE
    Export-sqmDatabaseDocumentation

.EXAMPLE
    Export-sqmDatabaseDocumentation -SqlInstance "SQL01" -Database "SalesDB","HRApp" -OutputPath "D:\Reports"

.EXAMPLE
    Export-sqmDatabaseDocumentation -SqlInstance "SQL01" -IncludeSystemDatabases -ContinueOnError

.EXAMPLE
    # Multiple instances via pipeline
    "SQL01","SQL02","SQL03" | Export-sqmDatabaseDocumentation -ContinueOnError

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    VLF query requires SQL Server 2016+ (sys.dm_db_log_info).
#>
function Export-sqmDatabaseDocumentation
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeFileDetails = $true,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeUsers = $true,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeObjectSummary = $true,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),
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
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte 'Install-Module dbatools' ausfuehren."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName ? OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
		
		# Interne Hilfsfunktion: HtmlEncode (kein System.Web erforderlich — PS 5.1 kompatibel)
		function _HtmlEncode
		{
			param([string]$Text)
			$Text -replace '&','&amp;' `
			      -replace '<','&lt;'  `
			      -replace '>','&gt;'  `
			      -replace '"','&quot;' `
			      -replace "'",'&#39;'
		}

		# ?? Interne Hilfsfunktion: HTML-Tabelle aus PSObject-Array ??????????????
		function _HtmlTable
		{
			param (
				[object[]]$Rows,
				[string[]]$Properties
			)
			if (-not $Rows -or $Rows.Count -eq 0) { return '<p style="color:#888;font-style:italic">Keine Eintraege.</p>' }
			$sb = [System.Text.StringBuilder]::new()
			[void]$sb.Append('<table>')
			[void]$sb.Append('<thead><tr>')
			foreach ($p in $Properties) { [void]$sb.Append("<th>$p</th>") }
			[void]$sb.Append('</tr></thead><tbody>')
			foreach ($row in $Rows)
			{
				[void]$sb.Append('<tr>')
				foreach ($p in $Properties)
				{
					$val = $row.$p
					if ($null -eq $val) { $val = '' }
					[void]$sb.Append("<td>$(_HtmlEncode $val.ToString())</td>")
				}
				[void]$sb.Append('</tr>')
			}
			[void]$sb.Append('</tbody></table>')
			return $sb.ToString()
		}
		
		# ?? HTML-Vorlage (Kopf) ??????????????????????????????????????????????????
		function _HtmlHead
		{
			param ([string]$Title,
				[string]$Instance,
				[string]$Timestamp)
			return @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$Title</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#f0f4f8;color:#1e293b;font-size:13px}
.page-header{background:#1a3a5c;color:#fff;padding:24px 32px}
.page-header h1{font-size:1.5rem;font-weight:900;letter-spacing:-.03em}
.page-header .sub{font-size:.82rem;opacity:.7;margin-top:4px}
.toc{background:#fff;border-bottom:1px solid #dde4ee;padding:10px 32px;display:flex;gap:6px;flex-wrap:wrap}
.toc a{font-size:.75rem;color:#2563a8;text-decoration:none;background:#eff6ff;border-radius:12px;padding:2px 10px}
.toc a:hover{background:#dbeafe}
.main{max-width:1200px;margin:0 auto;padding:28px 24px}
.db-section{background:#fff;border:1px solid #dde4ee;border-radius:10px;margin-bottom:28px;overflow:hidden}
.db-header{background:#1a3a5c;color:#fff;padding:14px 20px;display:flex;align-items:center;justify-content:space-between}
.db-header h2{font-size:1rem;font-weight:800;letter-spacing:-.02em}
.db-header .db-status{font-size:.7rem;font-weight:700;padding:2px 8px;border-radius:10px;background:rgba(255,255,255,.15)}
.db-header .db-status.ok{background:#d1fae5;color:#064e3b}
.db-header .db-status.warn{background:#fef3c7;color:#92400e}
.db-header .db-status.crit{background:#fde8e8;color:#991b1b}
.db-body{padding:16px 20px}
.section-block{margin-bottom:18px}
.section-block h3{font-size:.78rem;font-weight:700;color:#2563a8;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;padding-bottom:5px;margin-bottom:10px}
.props-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:6px 16px}
.prop{display:flex;flex-direction:column}
.prop .lbl{font-size:.68rem;color:#64748b;font-weight:600;text-transform:uppercase;letter-spacing:.05em}
.prop .val{font-size:.82rem;color:#1e293b;font-weight:500;margin-top:1px}
.prop .val.warn{color:#92400e;font-weight:700}
.prop .val.ok{color:#064e3b}
table{width:100%;border-collapse:collapse;font-size:.78rem}
table th{background:#f0f4f8;color:#1e293b;padding:5px 10px;text-align:left;font-weight:700;font-size:.72rem;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #dde4ee}
table td{padding:5px 10px;border-bottom:1px solid #e8edf4;vertical-align:top}
table tr:hover td{background:#f8fafc}
.badge{display:inline-block;font-size:.65rem;font-weight:700;padding:1px 7px;border-radius:9px;text-transform:uppercase;letter-spacing:.04em}
.badge-full{background:#d1fae5;color:#064e3b}
.badge-simple{background:#f3e8ff;color:#6b21a8}
.badge-bulk{background:#fef3c7;color:#92400e}
.footer{text-align:center;font-size:.72rem;color:#94a3b8;padding:20px;border-top:1px solid #dde4ee}
</style>
</head>
<body>
<div class="page-header">
  <h1>&#128202; Datenbank-Dokumentation</h1>
  <div class="sub">Instanz: $Instance &nbsp;?&nbsp; Erstellt: $Timestamp</div>
</div>
"@
		}
		
		# ?? HTML-Vorlage (Fuss) ???????????????????????????????????????????????????
		function _HtmlFoot
		{
			param ([string]$Timestamp)
			return @"
<div class="footer">Erstellt durch sqmSQLTool - Export-sqmDatabaseDocumentation - $Timestamp<br>Quelle: <a href="https://www.powershelldba.de">www.powershelldba.de</a></div>
</body></html>
"@
		}
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			# ?? Verbindungsparameter (KEIN ErrorAction im Hashtable!) ????????????
			# Begruendung: dbatools-Cmdlets haben eigene -ErrorAction-Unterstuetzung.
			# Ein ErrorAction-Eintrag im Splatting-Hashtable fuehrt zu
			# "Parameter ErrorAction mehrfach angegeben", wenn das Cmdlet auch
			# intern -ErrorAction setzt oder Common Parameters bindet.
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Verbinde ..." -FunctionName $functionName -Level "INFO"
				
				# ?? Server-Verbindung ????????????????????????????????????????????
				$srv = Connect-DbaInstance @connParams -ErrorAction Stop
				
				# ?? Datenbanken laden ????????????????????????????????????????????
				# WICHTIG: -ErrorAction NICHT als Hashtable-Key, sondern direkt als
				# Named Parameter uebergeben ? kein Konflikt mit Common Parameters
				$allDbs = Get-DbaDatabase @connParams -ErrorAction Stop
				
				# Filter: Systemdatenbanken, tempdb, gewuenschte Namen
				$filteredDbs = $allDbs | Where-Object {
					$_.Name -ne 'tempdb' -and
					(-not $_.IsSystemObject -or $IncludeSystemDatabases)
				}
				if ($Database.Count -gt 0)
				{
					$filteredDbs = $filteredDbs | Where-Object {
						$dbName = $_.Name
						($Database | Where-Object { $dbName -like $_ }).Count -gt 0
					}
				}
				
				if (-not $filteredDbs)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Datenbanken nach Filterung gefunden." -FunctionName $functionName -Level "WARNING"
					$allResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Warning'
							Message	    = 'Keine Datenbanken nach Filterung gefunden.'
							HtmlFile    = $null
							CsvFile	    = $null
						})
					continue
				}
				
				# ?? Backup-Daten zentral laden (1? pro Instanz) ??????????????????
				$backupLookup = @{ }
				try
				{
					$backupQuery = @"
SELECT database_name, type, MAX(backup_finish_date) AS LastBackup
FROM   msdb.dbo.backupset
WHERE  type IN ('D','I','L')
  AND  is_copy_only = 0
GROUP BY database_name, type;
"@
					# Invoke-DbaQuery: -ErrorAction hier als direkter Parameter,
					# NICHT im $connParams-Hashtable ? kein Doppel-Konflikt
					$backupRows = Invoke-DbaQuery @connParams -Query $backupQuery -ErrorAction SilentlyContinue
					foreach ($r in $backupRows)
					{
						$backupLookup["$($r.database_name)|$($r.type)"] = $r.LastBackup
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "[$instance] Backup-Abfrage fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE"
				}
				
				# ?? CHECKDB-Daten zentral laden ??????????????????????????????????
				$checkDbLookup = @{ }
				try
				{
					$checkDbQuery = @"
SELECT name AS DatabaseName,
       DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime') AS LastGoodCheckDb
FROM   sys.databases
WHERE  name <> 'tempdb';
"@
					$checkRows = Invoke-DbaQuery @connParams -Query $checkDbQuery -ErrorAction SilentlyContinue
					foreach ($r in $checkRows)
					{
						if ($null -ne $r.LastGoodCheckDb)
						{
							$checkDbLookup[$r.DatabaseName] = $r.LastGoodCheckDb
						}
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "[$instance] CHECKDB-Abfrage fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE"
				}
				
				# ?? VLF-Daten zentral laden (SQL 2016+) ??????????????????????????
				$vlfLookup = @{ }
				try
				{
					$vlfQuery = @"
SELECT DB_NAME(s.database_id) AS DatabaseName,
       COUNT(*)               AS VlfCount
FROM   sys.databases          d
CROSS APPLY sys.dm_db_log_info(d.database_id) s
GROUP BY s.database_id;
"@
					$vlfRows = Invoke-DbaQuery @connParams -Query $vlfQuery -ErrorAction SilentlyContinue
					foreach ($r in $vlfRows)
					{
						if ($r.DatabaseName) { $vlfLookup[$r.DatabaseName] = $r.VlfCount }
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "[$instance] VLF-Abfrage nicht unterstuetzt (< SQL 2016?)." -FunctionName $functionName -Level "VERBOSE"
				}
				
				# ?? HTML-Aufbau ??????????????????????????????????????????????????
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyyMMdd_HHmm'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$htmlFile = Join-Path $OutputPath "DatabaseDoc_${safeInst}_${datestamp}.html"
				$csvFile = Join-Path $OutputPath "DatabaseDoc_${safeInst}_${datestamp}.csv"
				
				$htmlSb = [System.Text.StringBuilder]::new()
				[void]$htmlSb.Append((_HtmlHead -Title "DB-Doku $instance" -Instance $instance -Timestamp $timestamp))
				
				# Inhaltsverzeichnis
				[void]$htmlSb.Append('<div class="toc">')
				foreach ($db in ($filteredDbs | Sort-Object Name))
				{
					[void]$htmlSb.Append("<a href='#db_$($db.Name)'>$($db.Name)</a>")
				}
				[void]$htmlSb.Append('</div>')
				[void]$htmlSb.Append('<div class="main">')
				
				# CSV-Zeilen-Liste
				$csvRows = [System.Collections.Generic.List[PSCustomObject]]::new()
				
				# ?? Pro Datenbank ????????????????????????????????????????????????
				foreach ($db in ($filteredDbs | Sort-Object Name))
				{
					$dbName = $db.Name
					Invoke-sqmLogging -Message "[$instance] Dokumentiere Datenbank '$dbName' ..." -FunctionName $functionName -Level "INFO"
					
					try
					{
						# Backup-Zeiten
						$lastFull = $backupLookup["$dbName|D"]
						$lastDiff = $backupLookup["$dbName|I"]
						$lastLog = $backupLookup["$dbName|L"]
						
						# CHECKDB
						$lastCheckDb = $checkDbLookup[$dbName]
						$checkDbAge = if ($lastCheckDb) { [math]::Round(((Get-Date) - $lastCheckDb).TotalDays, 0) }
						else { $null }
						
						# VLF
						$vlfCount = $vlfLookup[$dbName]
						
						# Groessen
						$dataSizeMB = [math]::Round(($db.FileGroups | ForEach-Object { $_.Files } | Measure-Object -Property Size -Sum).Sum / 1024, 1)
						$logSizeMB = [math]::Round(($db.LogFiles | Measure-Object -Property Size -Sum).Sum / 1024, 1)
						$totalSizeMB = $dataSizeMB + $logSizeMB
						
						# Status-Klasse fuer Badge
						$statusClass = switch ($db.Status)
						{
							'Normal'    { 'ok' }
							default	    { 'crit' }
						}
						if ($checkDbAge -and $checkDbAge -gt 14) { $statusClass = 'warn' }
						if ($vlfCount -and $vlfCount -gt 500) { $statusClass = 'warn' }
						
						# Recovery-Badge
						$recoveryBadgeClass = switch ($db.RecoveryModel.ToString())
						{
							'Full'		{ 'badge-full' }
							'Simple'    { 'badge-simple' }
							'BulkLogged'{ 'badge-bulk' }
							default	    { '' }
						}
						
						# ?? DB-Abschnitt oeffnen ??????????????????????????????????
						[void]$htmlSb.Append("<div class='db-section' id='db_$dbName'>")
						[void]$htmlSb.Append("<div class='db-header'>")
						[void]$htmlSb.Append("<h2>&#128200; $dbName</h2>")
						[void]$htmlSb.Append("<span class='db-status $statusClass'>$($db.Status)</span>")
						[void]$htmlSb.Append("</div>")
						[void]$htmlSb.Append("<div class='db-body'>")
						
						# ?? Allgemeine Eigenschaften ?????????????????????????????
						[void]$htmlSb.Append("<div class='section-block'><h3>Allgemeine Eigenschaften</h3>")
						[void]$htmlSb.Append("<div class='props-grid'>")
						$props = [ordered]@{
							'Recovery-Modell' = "<span class='badge $recoveryBadgeClass'>$($db.RecoveryModel)</span>"
							'Kompatibilitaetslevel' = $db.CompatibilityLevel
							'Collation'	      = $db.Collation
							'Owner'		      = $db.Owner
							'Erstellt am'	  = if ($db.CreateDate) { $db.CreateDate.ToString('yyyy-MM-dd') } else { '-' }
							'Status'		  = $db.Status
							'Data-Groesse (MB)' = $dataSizeMB
							'Log-Groesse (MB)'  = $logSizeMB
							'Gesamt (MB)'	  = $totalSizeMB
							'VLF-Anzahl'	  = if ($vlfCount) { $vlfCount } else { 'n/a' }
							'ReadOnly'	      = $db.ReadOnly
							'AutoClose'	      = $db.AutoClose
							'AutoShrink'	  = $db.AutoShrink
						}
						foreach ($kv in $props.GetEnumerator())
						{
							[void]$htmlSb.Append("<div class='prop'><span class='lbl'>$($kv.Key)</span><span class='val'>$($kv.Value)</span></div>")
						}
						[void]$htmlSb.Append("</div></div>")
						
						# ?? Backup-Informationen ?????????????????????????????????
						[void]$htmlSb.Append("<div class='section-block'><h3>Letzte Backups</h3>")
						$backupData = @(
							[PSCustomObject]@{ Typ = 'Full (D)'; LetzteAusfuehrung = if ($lastFull) { $lastFull.ToString('yyyy-MM-dd HH:mm') } else { '(kein Backup gefunden)' }; AgeTage = if ($lastFull) { [math]::Round(((Get-Date) - $lastFull).TotalDays, 0) } else { '-' } }
							[PSCustomObject]@{ Typ = 'Diff (I)'; LetzteAusfuehrung = if ($lastDiff) { $lastDiff.ToString('yyyy-MM-dd HH:mm') } else { '-' }; AgeTage = if ($lastDiff) { [math]::Round(((Get-Date) - $lastDiff).TotalDays, 0) } else { '-' } }
							[PSCustomObject]@{ Typ = 'Log (L)'; LetzteAusfuehrung = if ($lastLog) { $lastLog.ToString('yyyy-MM-dd HH:mm') } else { if ($db.RecoveryModel.ToString() -eq 'Simple') { 'n/a (Simple Recovery)' }
									else { '(kein Log-Backup!)' } }; AgeTage = if ($lastLog) { [math]::Round(((Get-Date) - $lastLog).TotalHours, 1) } else { '-' } }
						)
						[void]$htmlSb.Append((_HtmlTable -Rows $backupData -Properties 'Typ', 'LetzteAusfuehrung', 'AgeTage'))
						$checkDbText = if ($lastCheckDb) { "$($lastCheckDb.ToString('yyyy-MM-dd HH:mm')) (vor $checkDbAge Tagen)" }
						else { '(unbekannt)' }
						[void]$htmlSb.Append("<p style='margin-top:8px;font-size:.78rem;'>&#10003; Letzte DBCC CHECKDB: <strong>$checkDbText</strong></p>")
						[void]$htmlSb.Append("</div>")
						
						# ?? Datei-Details ????????????????????????????????????????
						if ($IncludeFileDetails)
						{
							[void]$htmlSb.Append("<div class='section-block'><h3>Datenbankdateien</h3>")
							$fileRows = [System.Collections.Generic.List[PSCustomObject]]::new()
							foreach ($fg in $db.FileGroups)
							{
								foreach ($f in $fg.Files)
								{
									$growthInfo = if ($f.GrowthType -eq 'Percent') { "$($f.Growth) %" }
									else { "$([math]::Round($f.Growth / 1024, 0)) MB" }
									$fileRows.Add([PSCustomObject]@{
											Dateigruppe = $fg.Name
											Dateiname   = $f.Name
											Typ		    = 'Data'
											'Groesse (MB)' = [math]::Round($f.Size / 1024, 1)
											Autogrow    = $growthInfo
											Pfad	    = $f.FileName
										})
								}
							}
							foreach ($lf in $db.LogFiles)
							{
								$growthInfo = if ($lf.GrowthType -eq 'Percent') { "$($lf.Growth) %" }
								else { "$([math]::Round($lf.Growth / 1024, 0)) MB" }
								$fileRows.Add([PSCustomObject]@{
										Dateigruppe = 'LOG'
										Dateiname   = $lf.Name
										Typ		    = 'Log'
										'Groesse (MB)' = [math]::Round($lf.Size / 1024, 1)
										Autogrow    = $growthInfo
										Pfad	    = $lf.FileName
									})
							}
							[void]$htmlSb.Append((_HtmlTable -Rows $fileRows -Properties 'Dateigruppe', 'Dateiname', 'Typ', 'Groesse (MB)', 'Autogrow', 'Pfad'))
							[void]$htmlSb.Append("</div>")
						}
						
						# ?? Objekt-Zusammenfassung ???????????????????????????????
						if ($IncludeObjectSummary)
						{
							[void]$htmlSb.Append("<div class='section-block'><h3>Objekt-Zusammenfassung</h3>")
							try
							{
								$objQuery = @"
SELECT
    SUM(CASE WHEN type = 'U'  THEN 1 ELSE 0 END) AS Tabellen,
    SUM(CASE WHEN type = 'V'  THEN 1 ELSE 0 END) AS Views,
    SUM(CASE WHEN type = 'P'  THEN 1 ELSE 0 END) AS Prozeduren,
    SUM(CASE WHEN type IN ('FN','IF','TF') THEN 1 ELSE 0 END) AS Funktionen,
    SUM(CASE WHEN type = 'TR' THEN 1 ELSE 0 END) AS Trigger,
    SUM(CASE WHEN type = 'SN' THEN 1 ELSE 0 END) AS Synonyme
FROM [$dbName].sys.objects
WHERE is_ms_shipped = 0;
"@
								# Direkte Named Parameter - kein ErrorAction im Hashtable
								$objRow = Invoke-DbaQuery @connParams -Database $dbName -Query $objQuery -ErrorAction SilentlyContinue
								if ($objRow)
								{
									$objData = @(
										[PSCustomObject]@{ Objekttyp = 'Tabellen'; Anzahl = $objRow.Tabellen }
										[PSCustomObject]@{ Objekttyp = 'Sichten (Views)'; Anzahl = $objRow.Views }
										[PSCustomObject]@{ Objekttyp = 'Gespeicherte Prozeduren'; Anzahl = $objRow.Prozeduren }
										[PSCustomObject]@{ Objekttyp = 'Funktionen'; Anzahl = $objRow.Funktionen }
										[PSCustomObject]@{ Objekttyp = 'Trigger'; Anzahl = $objRow.Trigger }
										[PSCustomObject]@{ Objekttyp = 'Synonyme'; Anzahl = $objRow.Synonyme }
									)
									[void]$htmlSb.Append((_HtmlTable -Rows $objData -Properties 'Objekttyp', 'Anzahl'))
								}
							}
							catch
							{
								Invoke-sqmLogging -Message "[$instance][$dbName] Objekt-Abfrage fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE"
								[void]$htmlSb.Append('<p style="color:#888;font-style:italic">Objekte konnten nicht abgefragt werden.</p>')
							}
							[void]$htmlSb.Append("</div>")
						}
						
						# ?? Datenbank-User ???????????????????????????????????????
						if ($IncludeUsers)
						{
							[void]$htmlSb.Append("<div class='section-block'><h3>Datenbank-User</h3>")
							try
							{
								$userQuery = @"
SELECT
    dp.name          AS Benutzername,
    dp.type_desc     AS Typ,
    ISNULL(sp.name, '(kein Login)') AS LoginName,
    dp.create_date   AS ErstelltAm
FROM [$dbName].sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S','U','G')
  AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys','##MS_PolicyTsqlExecutionLogin##','##MS_AgentSigningCertificate##')
ORDER BY dp.name;
"@
								$userRows = Invoke-DbaQuery @connParams -Database $dbName -Query $userQuery -ErrorAction SilentlyContinue
								if ($userRows)
								{
									[void]$htmlSb.Append((_HtmlTable -Rows $userRows -Properties 'Benutzername', 'Typ', 'LoginName', 'ErstelltAm'))
								}
								else
								{
									[void]$htmlSb.Append('<p style="color:#888;font-style:italic">Keine Benutzer gefunden.</p>')
								}
							}
							catch
							{
								Invoke-sqmLogging -Message "[$instance][$dbName] User-Abfrage fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE"
							}
							[void]$htmlSb.Append("</div>")
						}
						
						[void]$htmlSb.Append("</div></div>")
						
						# ?? CSV-Zeile ????????????????????????????????????????????
						$csvRows.Add([PSCustomObject]@{
								SqlInstance = $instance
								Datenbank   = $dbName
								Status	    = $db.Status
								RecoveryModel = $db.RecoveryModel
								Kompatibilitaet = $db.CompatibilityLevel
								Collation   = $db.Collation
								Owner	    = $db.Owner
								ErstelltAm  = if ($db.CreateDate) { $db.CreateDate.ToString('yyyy-MM-dd') } else { '' }
								DataSizeMB  = $dataSizeMB
								LogSizeMB   = $logSizeMB
								TotalSizeMB = $totalSizeMB
								VlfCount    = if ($vlfCount) { $vlfCount } else { '' }
								LetzteCheckDb = if ($lastCheckDb) { $lastCheckDb.ToString('yyyy-MM-dd HH:mm') } else { '' }
								CheckDbAgeTage = if ($checkDbAge) { $checkDbAge } else { '' }
								LetztesFull = if ($lastFull) { $lastFull.ToString('yyyy-MM-dd HH:mm') } else { '' }
								LetzteDiff  = if ($lastDiff) { $lastDiff.ToString('yyyy-MM-dd HH:mm') } else { '' }
								LetztesLog  = if ($lastLog) { $lastLog.ToString('yyyy-MM-dd HH:mm') } else { '' }
							})
					}
					catch
					{
						$errMsg = "[$instance][$dbName] Fehler bei Datenbankdokumentation: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						[void]$htmlSb.Append("<div class='db-section'><div class='db-header'><h2>$dbName</h2><span class='db-status crit'>FEHLER</span></div><div class='db-body'><p style='color:#991b1b;'>$errMsg</p></div></div>")
						if ($EnableException) { throw }
						if (-not $ContinueOnError) { throw $_ }
					}
				}
				
				[void]$htmlSb.Append("</div>")
				[void]$htmlSb.Append((_HtmlFoot -Timestamp $timestamp))
				
				# ?? Dateien schreiben ????????????????????????????????????????????
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Datenbankdokumentation in '$OutputPath'"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis '$OutputPath' erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					$htmlSb.ToString() | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
					$csvRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					Copy-sqmToCentralPath -Path $htmlFile, $csvFile

					Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$instance] Dokumentation erstellt: $htmlFile | $csvFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Dateien wuerden erstellt: $htmlFile | $csvFile" -FunctionName $functionName -Level "VERBOSE"
					$htmlFile = $null
					$csvFile = $null
				}
				
				$allResults.Add([PSCustomObject]@{
						SqlInstance   = $instance
						DatabaseCount = $csvRows.Count
						HtmlFile	  = $htmlFile
						CsvFile	      = $csvFile
						Status	      = 'OK'
						Timestamp	  = $timestamp
					})
			}
			catch
			{
				$errMsg = "Fehler auf Instanz '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						SqlInstance   = $instance
						DatabaseCount = 0
						HtmlFile	  = $null
						CsvFile	      = $null
						Status	      = 'Error'
						Message	      = $errMsg
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Instanzen verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}