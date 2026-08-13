<#
.SYNOPSIS
    Tracks database file size growth over time and forecasts when bounded files
    will hit their MaxSize.

.DESCRIPTION
    Uses Get-sqmAutoGrowthReport as the single data source for the current size and
    AutoGrowth configuration of every data/log file, then appends each run's sizes
    to a per-instance JSON snapshot history (method B1, same approach as
    Get-sqmDiskSpaceReport): a linear least-squares regression over the last
    -HistoryDays days yields MB/day growth per file and, for files with a bounded
    MaxSize, the estimated days until MaxSize is reached.

    It needs at least -MinDataPoints regular runs before a forecast is produced;
    until then a file is reported as "collecting" instead of a silent n/a.

    Results are saved as TXT/CSV/HTML report in the specified directory.
    The function also returns an object with the detail data and file paths.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER Database
    Restrict to specific databases (array of names).

.PARAMETER IncludeSystem
    Include system databases. Default: $false.

.PARAMETER HistoryDays
    Look-back window (in days) of the snapshot history used for the regression. Default: 30.

.PARAMETER OutputPath
    Output directory for report files. Default: <Get-sqmDefaultOutputPath>\FileGrowthReports

.PARAMETER HistoryPath
    Directory holding the per-instance snapshot history (FileGrowthHistory_<instance>.json).
    Default: a 'History' subfolder under -OutputPath.

.PARAMETER MinDataPoints
    Minimum number of snapshots within the window before a forecast is produced. Default: 5.

.PARAMETER NoHistory
    Do not append the current run to the history (forecast still uses whatever history exists).

.PARAMETER ContinueOnError
    Continue on error for an instance (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER NoOpen
    Do not automatically open the generated HTML report.

.PARAMETER Confirm
    Request confirmation before writing files.

.PARAMETER WhatIf
    Shows which files would be created without actually writing them (history is not persisted).

.EXAMPLE
    Get-sqmFileGrowthHistory -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmFileGrowthHistory -SqlInstance "SQL01" -HistoryDays 14 -OutputPath "D:\Reports"

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmAutoGrowthReport
    The forecast needs a recurring schedule (e.g. a daily Agent job) to accumulate snapshots.
    With fewer than -MinDataPoints snapshots in the window, a file is reported as "collecting".
#>
function Get-sqmFileGrowthHistory
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystem,
		[Parameter(Mandatory = $false)]
		[int]$HistoryDays = 30,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'FileGrowthReports'),
		[Parameter(Mandatory = $false)]
		[string]$HistoryPath,
		[Parameter(Mandatory = $false)]
		[int]$MinDataPoints = 5,
		[Parameter(Mandatory = $false)]
		[switch]$NoHistory,
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
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()

			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade AutoGrowth-Report ..." -FunctionName $functionName -Level "INFO"

				$growthParams = @{
					SqlInstance = $instance
					Detailed    = $true
					EnableException = $true
				}
				if ($SqlCredential) { $growthParams['SqlCredential'] = $SqlCredential }
				if ($Database) { $growthParams['Database'] = $Database }
				if ($IncludeSystem) { $growthParams['IncludeSystem'] = $true }

				$growthRows = $null
				try
				{
					$growthRows = Get-sqmAutoGrowthReport @growthParams
				}
				catch
				{
					$errMsg = "AutoGrowth-Report fehlgeschlagen: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "[$instance] $errMsg" -FunctionName $functionName -Level "ERROR"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Error'
							Message	    = $errMsg
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
							HtmlFile    = $null
						})
					if ($EnableException) { throw }
					continue
				}

				if (-not $growthRows)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Datenbankdateien gefunden (oder keine zugaenglich)." -FunctionName $functionName -Level "WARNING"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Warning'
							Message	    = 'Keine Datenbankdateien gefunden (oder keine zugaenglich).'
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
							HtmlFile    = $null
						})
					continue
				}

				# Snapshot-Historie laden (Methode B1) und aktuellen Messpunkt bilden.
				# Geschluesselt nach DatabaseName + FileName (innerhalb einer DB eindeutig).
				$reportTime  = Get-Date
				$safeInst    = $instance -replace '[\\/:*?"<>|]', '_'
				$historyDir  = if ($HistoryPath) { $HistoryPath } else { Join-Path $OutputPath 'History' }
				$historyFile = Join-Path $historyDir ("FileGrowthHistory_" + $safeInst + ".json")

				$history = @()
				if (Test-Path $historyFile)
				{
					try
					{
						$raw = Get-Content $historyFile -Raw -ErrorAction Stop
						if ($raw -and $raw.Trim())
						{
							$history = @(ConvertFrom-Json $raw -ErrorAction Stop | ForEach-Object {
									[PSCustomObject]@{
										Timestamp    = [datetime]::Parse($_.Timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
										DatabaseName = [string]$_.DatabaseName
										FileType     = [string]$_.FileType
										FileName     = [string]$_.FileName
										SizeMB	     = [double]$_.SizeMB
									}
								})
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$instance] Historie '$historyFile' nicht lesbar ($($_.Exception.Message)) - wird neu angelegt." -FunctionName $functionName -Level "WARNING"
						$history = @()
					}
				}

				$currentSnaps = foreach ($file in $growthRows)
				{
					[PSCustomObject]@{
						Timestamp    = $reportTime
						DatabaseName = [string]$file.DatabaseName
						FileType     = [string]$file.FileType
						FileName     = [string]$file.FileName
						SizeMB	     = [double]$file.CurrentSizeMB
					}
				}

				# Fenster fuer die Regression: vorhandene Historie + aktueller Punkt.
				$windowStart  = $reportTime.AddDays(-$HistoryDays)
				$histForecast = @(($history + $currentSnaps) | Where-Object { $_.Timestamp -ge $windowStart })

				# Aktuellen Snapshot persistieren (nicht unter -WhatIf, nicht bei -NoHistory).
				if (-not $NoHistory)
				{
					if ($PSCmdlet.ShouldProcess($historyFile, "Datei-Groessen-Snapshot in Historie schreiben"))
					{
						try
						{
							if (-not (Test-Path $historyDir)) { New-Item -ItemType Directory -Path $historyDir -Force -ErrorAction Stop | Out-Null }
							$retentionStart = $reportTime.AddDays(-400)
							$toSave = @($history | Where-Object { $_.Timestamp -ge $retentionStart }) + $currentSnaps
							$serial = $toSave | ForEach-Object {
								[PSCustomObject]@{
									Timestamp    = $_.Timestamp.ToString('o')
									DatabaseName = $_.DatabaseName
									FileType     = $_.FileType
									FileName     = $_.FileName
									SizeMB	     = $_.SizeMB
								}
							}
							$tmpFile = "$historyFile.tmp"
							(@($serial) | ConvertTo-Json -Depth 4) | Out-File -FilePath $tmpFile -Encoding UTF8 -Force
							Move-Item -LiteralPath $tmpFile -Destination $historyFile -Force
							Invoke-sqmLogging -Message "[$instance] Snapshot in Historie geschrieben ($($currentSnaps.Count) Datei(en)): $historyFile" -FunctionName $functionName -Level "VERBOSE"
						}
						catch
						{
							Invoke-sqmLogging -Message "[$instance] Historie konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						}
					}
				}

				# Detailzeilen aufbereiten (Prognose je Datei aus der Historie)
				foreach ($file in $growthRows)
				{
					$dbName = [string]$file.DatabaseName
					$fName  = [string]$file.FileName
					$currentSizeMB = [double]$file.CurrentSizeMB
					$bounded = ($file.MaxSizeMB -ne 'Unlimited') -and ($null -ne $file.MaxSizeMB)
					$maxSizeMB = if ($bounded) { [double]$file.MaxSizeMB } else { $null }

					$fileHist = @($histForecast | Where-Object { $_.DatabaseName -eq $dbName -and $_.FileName -eq $fName } |
							ForEach-Object { [PSCustomObject]@{ Timestamp = $_.Timestamp; UsedGB = $_.SizeMB } })

					$freeForCalc = if ($bounded) { [math]::Max(0, $maxSizeMB - $currentSizeMB) } else { 0 }
					$fc = Get-sqmVolumeForecast -History $fileHist -FreeGB $freeForCalc -MinDataPoints $MinDataPoints

					$growthPerDayMB = if ($fc.Basis -eq 'History' -and $fc.SlopePerDayGB -gt 0) { $fc.SlopePerDayGB } else { $null }
					$growthLastPeriodMB = if ($fc.Basis -eq 'History') { $fc.GrowthWindowGB } else { $null }
					$daysUntilFull = if ($bounded -and $fc.Basis -eq 'History' -and $fc.SlopePerDayGB -gt 0) { $fc.DaysUntilFull } else { $null }

					$forecastWarn = $bounded -and $daysUntilFull -and $daysUntilFull -le 30
					$status = if ($file.Status -eq 'Warning' -or $forecastWarn) { 'Warning' }
					elseif ($file.Status -eq 'Info') { 'Info' }
					else { 'OK' }

					$msgParts = @()
					if ($file.Assessment -and $file.Assessment -ne 'OK - Best Practice') { $msgParts += $file.Assessment }
					if ($forecastWarn) { $msgParts += "Prognose: MaxSize in ca. $daysUntilFull Tagen erreicht ($($fc.Confidence))" }
					elseif ($fc.Basis -ne 'History') { $msgParts += "Prognose sammelt noch Daten ($($fc.DataPoints) von $MinDataPoints Laeufen)" }
					$message = if ($msgParts) { $msgParts -join "; " } else { "OK" }

					$detailRows.Add([PSCustomObject]@{
							SqlInstance	   = $instance
							DatabaseName	   = $dbName
							FileType	   = [string]$file.FileType
							FileName	   = $fName
							CurrentSizeMB	   = $currentSizeMB
							GrowthType	   = $file.GrowthType
							GrowthValue	   = $file.GrowthValue
							MaxSizeMB	   = if ($bounded) { $maxSizeMB } else { 'Unlimited' }
							GrowthLastPeriodMB = $growthLastPeriodMB
							GrowthPerDayMB	   = $growthPerDayMB
							DaysUntilFull	   = $daysUntilFull
							HistoryDays	   = $HistoryDays
							DataPoints	   = $fc.DataPoints
							ForecastConfidence = $fc.Confidence
							ForecastBasis	   = $fc.Basis
							Status		   = $status
							Message		   = $message
						})
				}

				# Berichtsdateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$txtFile = Join-Path $OutputPath "FileGrowthReport_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "FileGrowthReport_${safeInst}_${datestamp}.csv"
				$htmlFile = Join-Path $OutputPath "FileGrowthReport_${safeInst}_${datestamp}.html"

				$cntWarn = ($detailRows | Where-Object Status -eq 'Warning').Count
				$cntCollecting = ($detailRows | Where-Object ForecastBasis -ne 'History').Count

				if ($PSCmdlet.ShouldProcess($instance, "Erstelle File-Growth-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}

					# TXT-Bericht
					$reference = Get-sqmReportReference
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - File Growth Report")
					$lines.Add("# $reference")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# Prognose  : Snapshot-Historie, Fenster $HistoryDays Tage, min. $MinDataPoints Laeufe")
					$lines.Add("# Historie  : $historyFile")
					$lines.Add("# Warning: $cntWarn | Prognose sammelt noch: $cntCollecting Datei(en)")
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-7} {1,-20} {2,-6} {3,-25} {4,-10} {5,-9} {6,-9} {7,-8} {8}" -f
							'Status', 'Datenbank', 'Typ', 'Datei', 'GroesseMB', 'MB/Tag', 'DaysFull', 'Konf', 'Info'))
					$lines.Add(("-" * 130))
					foreach ($e in ($detailRows | Sort-Object Status, DatabaseName, FileName))
					{
						$perDayDisplay = if ($e.GrowthPerDayMB) { $e.GrowthPerDayMB }
						elseif ($e.ForecastBasis -ne 'History') { 'sammelt' }
						else { 'stabil' }
						$daysDisplay = if ($e.DaysUntilFull) { $e.DaysUntilFull }
						elseif (-not ($e.MaxSizeMB -eq 'Unlimited')) { '-' }
						else { 'n/a' }
						$confDisplay = if ($e.ForecastBasis -eq 'History') { $e.ForecastConfidence } else { '-' }
						$lines.Add(("{0,-7} {1,-20} {2,-6} {3,-25} {4,-10} {5,-9} {6,-9} {7,-8} {8}" -f
								$e.Status, $e.DatabaseName, $e.FileType, $e.FileName, $e.CurrentSizeMB,
								$perDayDisplay, $daysDisplay, $confDisplay, $e.Message))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					# CSV-Datei
					$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# HTML-Bericht (farbcodiert nach Status)
					$rowsHtml = ''
					foreach ($e in ($detailRows | Sort-Object Status, DatabaseName, FileName))
					{
						$cls = switch ($e.Status) { 'Warning' { 'warn' } 'Info' { 'warn' } default { 'ok' } }
						$perDayDisplay = if ($e.GrowthPerDayMB) { $e.GrowthPerDayMB } elseif ($e.ForecastBasis -ne 'History') { 'sammelt' } else { 'stabil' }
						$daysDisplay   = if ($e.DaysUntilFull) { $e.DaysUntilFull } else { '-' }
						$confDisplay   = if ($e.ForecastBasis -eq 'History') { $e.ForecastConfidence } else { '-' }
						$fn = [string]$e.FileName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
						$rowsHtml += "<tr><td class='$cls'>$($e.Status)</td><td>$($e.DatabaseName)</td><td>$($e.FileType)</td><td>$fn</td><td>$($e.CurrentSizeMB)</td><td>$perDayDisplay</td><td>$daysDisplay</td><td>$confDisplay</td></tr>`n"
					}
					$bodyHtml = @"
<table>
<thead><tr><th>Status</th><th>Datenbank</th><th>Typ</th><th>Datei</th><th>Groesse MB</th><th>MB/Tag</th><th>Days Full</th><th>Konfidenz</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<p style="color:#94a8c0;font-size:12px;">Prognose: Snapshot-Historie, Fenster $HistoryDays Tage, min. $MinDataPoints Laeufe &nbsp;|&nbsp; Warning: $cntWarn, sammelt: $cntCollecting</p>
"@
					$html = ConvertTo-sqmHtmlReport -Title "File Growth Report - $instance" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
					$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$instance] File-Growth-Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
					$htmlFile = $null
				}

				$result = [PSCustomObject]@{
					SqlInstance = $instance
					Timestamp   = $timestamp
					DetailRows  = $detailRows
					TxtFile	    = $txtFile
					CsvFile	    = $csvFile
					HtmlFile    = $htmlFile
					Status	    = if ($cntWarn -gt 0) { 'Warning' } else { 'OK' }
				}
				$allInstanceResults.Add($result)

				if ($cntWarn -gt 0)
				{
					Invoke-sqmLogging -Message "[$instance] $cntWarn Warning(s) - Bericht: $txtFile" -FunctionName $functionName -Level "WARNING"
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
