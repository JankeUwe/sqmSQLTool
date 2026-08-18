<#
.SYNOPSIS
    Reports how full each database's data and log files are.

.DESCRIPTION
    Reads per-file space usage (allocated size vs. actually used space) for every accessible
    database and rolls it up per database: how full the data files are as a group, and how full
    the log file(s) are as a group. This is the classic "database fill level" view - not to be
    confused with Get-sqmDiskSpaceReport (free space on the underlying Windows volume) or
    Get-sqmAutoGrowthReport (allocated file size and autogrowth configuration).

    Databases at or above -WarnThresholdPct / -CriticalThresholdPct are flagged accordingly, both
    in the returned objects and in the HTML report (colour-coded).

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Filter: only these databases (wildcards allowed). Default: all accessible.

.PARAMETER ExcludeDatabase
    Databases to skip (wildcards allowed).

.PARAMETER IncludeSystemDatabases
    Also include master/model/msdb (tempdb is always included by SQL Server itself but rarely
    interesting here - use -Database 'tempdb' explicitly if needed). Default: user databases only.

.PARAMETER WarnThresholdPct
    Fill percentage (data or log) at which a database is flagged 'Warning'. Default: 80.

.PARAMETER CriticalThresholdPct
    Fill percentage (data or log) at which a database is flagged 'Critical'. Default: 90.

.PARAMETER OutputPath
    Directory for the CSV (file-level detail) and HTML (database summary) report.
    Default: <OutputPath config>\DatabaseSpaceReport.

.PARAMETER ContinueOnError
    Continue with the next instance on error instead of aborting.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.PARAMETER NoOpen
    Do not automatically open the HTML report after creation.

.EXAMPLE
    Get-sqmDatabaseSpaceReport -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmDatabaseSpaceReport -SqlInstance "SQL01" -CriticalThresholdPct 95 |
        Select-Object -ExpandProperty Databases | Where-Object Status -ne 'OK'

.EXAMPLE
    'SQL01','SQL02' | Get-sqmDatabaseSpaceReport -ContinueOnError

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath
    Needs VIEW DATABASE STATE on the target databases.
    Built on dbatools' Get-DbaDbSpace. Its own -IncludeSystemDBs switch is deprecated in dbatools
    2.8.4 and aborts the call without returning anything, so system-database inclusion/exclusion is
    handled here via -ExcludeDatabase (master/model/msdb/tempdb) instead.
#>
function Get-sqmDatabaseSpaceReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$WarnThresholdPct = 80,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$CriticalThresholdPct = 90,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'DatabaseSpaceReport'),
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

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		if ($CriticalThresholdPct -le $WarnThresholdPct)
		{
			$msg = "-CriticalThresholdPct ($CriticalThresholdPct) muss groesser sein als -WarnThresholdPct ($WarnThresholdPct)."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		Invoke-sqmLogging -Message "Starte $functionName (Warn=${WarnThresholdPct}% Critical=${CriticalThresholdPct}%)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			try
			{
				$connParams = @{ SqlInstance = $instance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
				if ($Database.Count -gt 0) { $connParams['Database'] = $Database }

				# Get-DbaDbSpace's eigener -IncludeSystemDBs-Switch ist in dbatools 2.8.4
				# deprecated und bricht den Aufruf ohne Rueckgabe ab (siehe .NOTES) - System-DBs
				# werden deshalb hier ueber -ExcludeDatabase gesteuert statt ueber den Switch.
				$excludeDb = @($ExcludeDatabase)
				if (-not $IncludeSystemDatabases) { $excludeDb += @('master', 'model', 'msdb', 'tempdb') }
				if ($excludeDb.Count -gt 0) { $connParams['ExcludeDatabase'] = $excludeDb }

				Invoke-sqmLogging -Message "[$instance] Lese Datei-Speicherbelegung..." -FunctionName $functionName -Level "INFO"
				$spaceRows = @(Get-DbaDbSpace @connParams -EnableException:$EnableException)

				if ($spaceRows.Count -eq 0)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Datenbankdateien gefunden." -FunctionName $functionName -Level "WARNING"
					continue
				}

				# ---- Datei-Detailzeilen (fuer CSV) ----
				$fileRows = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($row in $spaceRows)
				{
					$pct = [double]$row.PercentUsed
					$status = if ($pct -ge $CriticalThresholdPct) { 'Critical' }
					elseif ($pct -ge $WarnThresholdPct) { 'Warning' }
					else { 'OK' }

					$fileRows.Add([PSCustomObject]@{
							SqlInstance   = $instance
							DatabaseName  = $row.Database
							FileName	  = $row.FileName
							FileGroup	  = $row.FileGroup
							FileType	  = $row.FileType
							PhysicalName  = $row.PhysicalName
							SizeMB	      = [math]::Round($row.FileSize.Megabyte, 1)
							UsedMB	      = [math]::Round($row.UsedSpace.Megabyte, 1)
							FreeMB	      = [math]::Round($row.FreeSpace.Megabyte, 1)
							PercentUsed   = $pct
							AutoGrowType  = $row.AutoGrowType
							Status	      = $status
						})
				}

				# ---- Datenbank-Zusammenfassung: Data- und Log-Dateien je DB aggregieren ----
				# type_desc-Werte aus sys.database_files: 'LOG' fuer Transaktionslogs, alles andere
				# (typischerweise 'ROWS', selten 'FILESTREAM'/'FULLTEXT') zaehlt als Datendatei.
				$dbSummaries = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($grp in ($fileRows | Group-Object DatabaseName))
				{
					$dataFiles = @($grp.Group | Where-Object { $_.FileType -ne 'LOG' })
					$logFiles = @($grp.Group | Where-Object { $_.FileType -eq 'LOG' })

					$dataSizeMB = [double](($dataFiles | Measure-Object -Property SizeMB -Sum).Sum)
					$dataUsedMB = [double](($dataFiles | Measure-Object -Property UsedMB -Sum).Sum)
					$dataPct = if ($dataSizeMB -gt 0) { [math]::Round(($dataUsedMB / $dataSizeMB) * 100, 1) } else { 0 }

					$logSizeMB = [double](($logFiles | Measure-Object -Property SizeMB -Sum).Sum)
					$logUsedMB = [double](($logFiles | Measure-Object -Property UsedMB -Sum).Sum)
					$logPct = if ($logSizeMB -gt 0) { [math]::Round(($logUsedMB / $logSizeMB) * 100, 1) } else { 0 }

					$worstPct = [math]::Max($dataPct, $logPct)
					$dbStatus = if ($worstPct -ge $CriticalThresholdPct) { 'Critical' }
					elseif ($worstPct -ge $WarnThresholdPct) { 'Warning' }
					else { 'OK' }

					$dbSummaries.Add([PSCustomObject]@{
							SqlInstance	    = $instance
							DatabaseName    = $grp.Name
							DataFileCount   = $dataFiles.Count
							DataSizeMB	    = [math]::Round($dataSizeMB, 1)
							DataUsedMB	    = [math]::Round($dataUsedMB, 1)
							DataPercentUsed = $dataPct
							LogFileCount    = $logFiles.Count
							LogSizeMB	    = [math]::Round($logSizeMB, 1)
							LogUsedMB	    = [math]::Round($logUsedMB, 1)
							LogPercentUsed  = $logPct
							Status		    = $dbStatus
						})
				}

				$warningCount = @($dbSummaries | Where-Object { $_.Status -eq 'Warning' }).Count
				$criticalCount = @($dbSummaries | Where-Object { $_.Status -eq 'Critical' }).Count

				# ---- CSV + HTML schreiben ----
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $instance -replace '[\\/:<>|]', '_'
				$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

				$csvFile = Join-Path $OutputPath "DatabaseSpace_${safeInst}_${stamp}.csv"
				$fileRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "[$instance] CSV gespeichert: $csvFile" -FunctionName $functionName -Level "INFO"

				$rowsHtml = foreach ($d in ($dbSummaries | Sort-Object { [math]::Max($_.DataPercentUsed, $_.LogPercentUsed) } -Descending))
				{
					$cls = switch ($d.Status) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
					"<tr><td class='$cls'>$($d.Status)</td><td>$([System.Net.WebUtility]::HtmlEncode($d.DatabaseName))</td><td>$($d.DataUsedMB) / $($d.DataSizeMB) MB ($($d.DataPercentUsed)%)</td><td>$($d.LogUsedMB) / $($d.LogSizeMB) MB ($($d.LogPercentUsed)%)</td></tr>"
				}
				$bodyHtml = "<p>$($dbSummaries.Count) Datenbank(en) geprueft. Warnung: $warningCount, Kritisch: $criticalCount " +
				"(Schwellwerte: Warnung ab ${WarnThresholdPct}%, kritisch ab ${CriticalThresholdPct}%).</p>" +
				"<table><tr><th>Status</th><th>Datenbank</th><th>Datendateien belegt</th><th>Log belegt</th></tr>" +
				($rowsHtml -join '') + "</table>"
				$html = ConvertTo-sqmHtmlReport -Title "Database Space Report - $instance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml

				$htmlFile = Join-Path $OutputPath "DatabaseSpace_${safeInst}_${stamp}.html"
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "[$instance] HTML-Bericht gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
				Copy-sqmToCentralPath -Path @($csvFile, $htmlFile)

				$instanceResult = [PSCustomObject]@{
					SqlInstance   = $instance
					CaptureTime   = Get-Date
					Databases	  = $dbSummaries.ToArray()
					Files		  = $fileRows.ToArray()
					WarningCount  = $warningCount
					CriticalCount = $criticalCount
					CsvFile	      = $csvFile
					HtmlFile	  = $htmlFile
				}
				$allInstanceResults.Add($instanceResult)

				$msg = "[$instance] $($dbSummaries.Count) Datenbank(en) geprueft: $warningCount Warnung(en), $criticalCount kritisch."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "[$instance] Fehler: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { Write-Error $errMsg; return }
				Write-Warning $errMsg
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanz(en) verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults.ToArray()
	}
}
