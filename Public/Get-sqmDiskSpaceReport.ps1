<#
.SYNOPSIS
    Determines free disk space on all SQL-relevant volumes and estimates
    time to exhaustion based on a self-collected size history.

.DESCRIPTION
    Queries sys.dm_os_volume_stats for all database files and determines:
    - Free disk space per volume
    - Total size of database files on the volume
    - A growth forecast based on a snapshot history (method B1): each run appends the
      current per-volume usage to a JSON history; a linear least-squares regression over the
      last -HistoryDays days yields GB/day and the estimated days until the volume is full.
    - Warning when free space falls below -WarnThresholdPct

    Unlike the old default-trace approach, the forecast reflects the ACTUAL consumption trend
    (data growth inside pre-sized files too) and is keyed by volume mount point (mount-point safe).
    It needs at least -MinDataPoints regular runs before a forecast is produced; until then the
    volume is reported as "collecting" instead of a silent n/a.

    Results are saved as TXT/CSV/HTML report in the specified directory.
    The function also returns an object with the detail data and file paths.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER WarnThresholdPct
    Warning when free space falls below this percentage. Default: 20.

.PARAMETER CriticalThresholdPct
    Critical when free space falls below this percentage. Default: 10.

.PARAMETER HistoryDays
    Look-back window (in days) of the snapshot history used for the regression. Default: 30.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER HistoryPath
    Directory holding the per-instance snapshot history (DiskHistory_<instance>.json).
    Default: a 'History' subfolder under -OutputPath.

.PARAMETER MinDataPoints
    Minimum number of snapshots within the window before a forecast is produced. Default: 5.

.PARAMETER NoHistory
    Do not append the current run to the history (forecast still uses whatever history exists).

.PARAMETER SeedFromBackupHistory
    Bootstrap (method B2): while the snapshot history has fewer than -MinDataPoints points for a volume,
    derive a fallback growth rate from msdb full-backup sizes (data growth trend per database, mapped to
    volumes by data-file location). Used only as long as B1 is insufficient; reported with
    ForecastBasis='BackupHistory' and confidence Low. Requires read access to msdb.dbo.backupset.

.PARAMETER ContinueOnError
    Continue on error for an instance (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before writing files.

.PARAMETER WhatIf
    Shows which files would be created without actually writing them (history is not persisted).

.EXAMPLE
    Get-sqmDiskSpaceReport

.EXAMPLE
    Get-sqmDiskSpaceReport -SqlInstance "SQL01" -WarnThresholdPct 15 -OutputPath "D:\Reports"

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools, Invoke-sqmLogging
    Default output path: C:\System\WinSrvLog\MSSQL
    The forecast needs a recurring schedule (e.g. a daily Agent job) to accumulate snapshots.
    With fewer than -MinDataPoints snapshots in the window, a volume is reported as "collecting".
#>
function Get-sqmDiskSpaceReport
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$WarnThresholdPct = 20,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$CriticalThresholdPct = 10,
		[Parameter(Mandatory = $false)]
		[int]$HistoryDays = 30,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[string]$HistoryPath,
		[Parameter(Mandatory = $false)]
		[int]$MinDataPoints = 5,
		[Parameter(Mandatory = $false)]
		[switch]$NoHistory,
		[Parameter(Mandatory = $false)]
		[switch]$SeedFromBackupHistory,
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

			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()

			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade Volume-Statistiken ..." -FunctionName $functionName -Level "INFO"

				# 1. Volumedaten aus sys.dm_os_volume_stats
				$volumeQuery = @"
SELECT DISTINCT
    vs.volume_mount_point                              AS MountPoint,
    vs.logical_volume_name                             AS VolumeName,
    vs.total_bytes    / 1073741824.0                   AS TotalGB,
    vs.available_bytes / 1073741824.0                  AS FreeGB,
    (vs.total_bytes - vs.available_bytes) / 1073741824.0 AS UsedGB,
    CAST(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes,0) AS DECIMAL(5,1)) AS FreePct
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
ORDER BY vs.volume_mount_point;
"@
				# Verbindungs-/Auth-Fehler explizit fangen (EnableException erzwingen),
				# damit der echte Fehler nicht als "keine Daten" maskiert wird.
				$volRows = $null
				try
				{
					$volRows = Invoke-DbaQuery @connParams -Query $volumeQuery -EnableException:$true
				}
				catch
				{
					$origMsg = $_.Exception.Message

					# Kerberos / SPN / SSPI-Hinweis ergaenzen
					$hint = ''
					if ($origMsg -match 'target principal name|Kerberos|SSPI|cannot generate sspi')
					{
						$hint = ' | Kerberos/SPN-Problem: FQDN statt Alias verwenden, SPN pruefen (setspn -L <Dienstkonto>), oder -SqlCredential nutzen.'
					}

					$errMsg = "Verbindung/Abfrage fehlgeschlagen: $origMsg$hint"
					Invoke-sqmLogging -Message "[$instance] $errMsg" -FunctionName $functionName -Level "ERROR"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Error'
							Message	    = $errMsg
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
						})
					if ($EnableException) { throw }
					continue
				}

				# Verbunden, aber keine Zeilen (auf einer echten Instanz praktisch nie der Fall,
				# da sys.master_files immer Systemdatenbanken enthaelt).
				if (-not $volRows)
				{
					Invoke-sqmLogging -Message "[$instance] Verbindung ok, aber keine Volumedaten zurueckgegeben." -FunctionName $functionName -Level "WARNING"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Warning'
							Message	    = 'Keine Volumedaten zurueckgegeben (Verbindung war erfolgreich).'
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
						})
					continue
				}

				# 2. Snapshot-Historie laden (Methode B1) und aktuellen Messpunkt bilden.
				#    Geschluesselt nach volume_mount_point -> mountpoint-sicher.
				$reportTime  = Get-Date
				$safeInst    = $instance -replace '[\\/:*?"<>|]', '_'
				$historyDir  = if ($HistoryPath) { $HistoryPath } else { Join-Path $OutputPath 'History' }
				$historyFile = Join-Path $historyDir ("DiskHistory_" + $safeInst + ".json")

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
										Timestamp  = [datetime]::Parse($_.Timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
										MountPoint = [string]$_.MountPoint
										VolumeName = [string]$_.VolumeName
										TotalGB    = [double]$_.TotalGB
										UsedGB     = [double]$_.UsedGB
										FreeGB     = [double]$_.FreeGB
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

				$currentSnaps = foreach ($vol in $volRows)
				{
					[PSCustomObject]@{
						Timestamp  = $reportTime
						MountPoint = [string]$vol.MountPoint
						VolumeName = [string]$vol.VolumeName
						TotalGB    = [math]::Round([double]$vol.TotalGB, 2)
						UsedGB     = [math]::Round([double]$vol.UsedGB, 2)
						FreeGB     = [math]::Round([double]$vol.FreeGB, 2)
					}
				}

				# Fenster fuer die Regression: vorhandene Historie + aktueller Punkt.
				$windowStart  = $reportTime.AddDays(-$HistoryDays)
				$histForecast = @(($history + $currentSnaps) | Where-Object { $_.Timestamp -ge $windowStart })

				# Aktuellen Snapshot persistieren (nicht unter -WhatIf, nicht bei -NoHistory).
				if (-not $NoHistory)
				{
					if ($PSCmdlet.ShouldProcess($historyFile, "Disk-Snapshot in Historie schreiben"))
					{
						try
						{
							if (-not (Test-Path $historyDir)) { New-Item -ItemType Directory -Path $historyDir -Force -ErrorAction Stop | Out-Null }
							$retentionStart = $reportTime.AddDays(-400)
							$toSave = @($history | Where-Object { $_.Timestamp -ge $retentionStart }) + $currentSnaps
							$serial = $toSave | ForEach-Object {
								[PSCustomObject]@{
									Timestamp  = $_.Timestamp.ToString('o')
									MountPoint = $_.MountPoint
									VolumeName = $_.VolumeName
									TotalGB    = $_.TotalGB
									UsedGB     = $_.UsedGB
									FreeGB     = $_.FreeGB
								}
							}
							$tmpFile = "$historyFile.tmp"
							(@($serial) | ConvertTo-Json -Depth 4) | Out-File -FilePath $tmpFile -Encoding UTF8 -Force
							Move-Item -LiteralPath $tmpFile -Destination $historyFile -Force
							Invoke-sqmLogging -Message "[$instance] Snapshot in Historie geschrieben ($($currentSnaps.Count) Volume(s)): $historyFile" -FunctionName $functionName -Level "VERBOSE"
						}
						catch
						{
							Invoke-sqmLogging -Message "[$instance] Historie konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						}
					}
				}

				# 2b. Bootstrap (B2): Wachstumsrate aus msdb-Backup-Historie, solange B1 noch zu wenige
				#     Snapshots hat. Greift in der Detailschleife nur, wenn der B1-Forecast 'Insufficient' ist.
				$backupSeed = @{ }
				if ($SeedFromBackupHistory)
				{
					try
					{
						$backupSeed = Get-sqmBackupGrowthSeed -ConnParams $connParams -Days ([math]::Max($HistoryDays, 90)) -Volumes $volRows
						Invoke-sqmLogging -Message "[$instance] Backup-Historie-Seed: $($backupSeed.Keys.Count) Volume(s) mit Trend." -FunctionName $functionName -Level "VERBOSE"
					}
					catch
					{
						Invoke-sqmLogging -Message "[$instance] Backup-Historie-Seed nicht ermittelbar: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						$backupSeed = @{ }
					}
				}

				# 3. Detailzeilen aufbereiten (Prognose je Volume aus der Historie)
				foreach ($vol in $volRows)
				{
					$mount = $vol.MountPoint
					$totalGB = [math]::Round($vol.TotalGB, 1)
					$freeGB = [math]::Round($vol.FreeGB, 1)
					$usedGB = [math]::Round($vol.UsedGB, 1)
					$freePct = [math]::Round($vol.FreePct, 1)

					$volHist = @($histForecast | Where-Object { $_.MountPoint -eq $mount })
					$fc = Get-sqmVolumeForecast -History $volHist -FreeGB $freeGB -MinDataPoints $MinDataPoints

					$basis   = $fc.Basis
					$conf    = $fc.Confidence
					$dpoints = $fc.DataPoints
					$growthPerDay  = if ($fc.Basis -eq 'History' -and $fc.SlopePerDayGB -gt 0) { $fc.SlopePerDayGB } else { 0 }
					$daysUntilFull = if ($fc.Basis -eq 'History') { $fc.DaysUntilFull } else { $null }
					$growthGB      = if ($fc.Basis -eq 'History') { $fc.GrowthWindowGB } else { $null }

					# Bootstrap (B2) nur solange B1 noch nicht greift.
					if ($fc.Basis -ne 'History' -and $backupSeed.ContainsKey($mount) -and $backupSeed[$mount].SlopePerDayGB -gt 0)
					{
						$seedSlope = $backupSeed[$mount].SlopePerDayGB
						$growthPerDay  = $seedSlope
						$daysUntilFull = [math]::Round($freeGB / $seedSlope, 0)
						$growthGB      = [math]::Round($seedSlope * $HistoryDays, 2)
						$basis = 'BackupHistory'
						$conf  = 'Low'
					}

					$status = if ($freePct -le $CriticalThresholdPct) { 'Critical' }
					elseif ($freePct -le $WarnThresholdPct) { 'Warning' }
					elseif ($daysUntilFull -and $daysUntilFull -le 30) { 'Warning' }
					else { 'OK' }

					$detailRows.Add([PSCustomObject]@{
							SqlInstance = $instance
							MountPoint  = $mount
							VolumeName  = $vol.VolumeName
							TotalGB	    = $totalGB
							UsedGB	    = $usedGB
							FreeGB	    = $freeGB
							FreePct	    = $freePct
							GrowthLastPeriodGB = if ($growthGB) { $growthGB } else { $null }
							GrowthPerDayGB = if ($growthPerDay -gt 0) { $growthPerDay } else { $null }
							DaysUntilFull = $daysUntilFull
							HistoryDays = $HistoryDays
							DataPoints  = $dpoints
							ForecastConfidence = $conf
							ForecastBasis = $basis
							Status	    = $status
							Message	    = switch ($status)
							{
								'Critical' { "Kritisch: nur $freePct% frei ($freeGB GB)!" }
								'Warning'  {
									if ($daysUntilFull -and $daysUntilFull -le 30)
									{
										$src = if ($basis -eq 'BackupHistory') { 'Bootstrap Backup-Historie' } else { "Konfidenz $conf" }
										"Warnung: voll in ca. $daysUntilFull Tagen ($src)."
									}
									else { "Warnung: nur $freePct% frei ($freeGB GB)." }
								}
								default    {
									switch ($basis)
									{
										'BackupHistory' { "OK: $freePct% frei ($freeGB GB). Prognose (Bootstrap Backup-Historie): voll in ca. $daysUntilFull Tagen." }
										'History'       { "OK: $freePct% frei ($freeGB GB)." }
										default         { "OK: $freePct% frei ($freeGB GB). Prognose sammelt noch Daten ($dpoints von $MinDataPoints Laeufen)." }
									}
								}
							}
						})
				}

				# 4. Berichtsdateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$txtFile = Join-Path $OutputPath "DiskSpaceReport_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "DiskSpaceReport_${safeInst}_${datestamp}.csv"
				$htmlFile = Join-Path $OutputPath "DiskSpaceReport_${safeInst}_${datestamp}.html"

				$cntCrit = ($detailRows | Where-Object Status -eq 'Critical').Count
				$cntWarn = ($detailRows | Where-Object Status -eq 'Warning').Count
				$cntCollecting = ($detailRows | Where-Object ForecastBasis -ne 'History').Count

				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Disk-Space-Bericht in $OutputPath"))
				{
					# Verzeichnis anlegen
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}

					# TXT-Bericht
					$reference = Get-sqmReportReference
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - Disk Space Report")
					$lines.Add("# $reference")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# Warn: <${WarnThresholdPct}% | Critical: <${CriticalThresholdPct}% | Prognose: Snapshot-Historie, Fenster $HistoryDays Tage, min. $MinDataPoints Laeufe")
					$lines.Add("# Historie  : $historyFile")
					$lines.Add("# Critical: $cntCrit | Warning: $cntWarn | Prognose sammelt noch: $cntCollecting Volume(s)")
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-6} {1,-20} {2,-8} {3,-8} {4,-8} {5,-7} {6,-10} {7,-9} {8,-6} {9}" -f
							'Status', 'Laufwerk', 'TotalGB', 'UsedGB', 'FreeGB', 'Free%', 'GB/Tag', 'DaysFull', 'Konf', 'Info'))
					$lines.Add(("-" * 115))
					foreach ($e in ($detailRows | Sort-Object Status, MountPoint))
					{
						$perDayDisplay = if ($e.GrowthPerDayGB) { $e.GrowthPerDayGB }
						elseif ($e.ForecastBasis -ne 'History') { 'sammelt' }
						else { 'stabil' }
						$daysDisplay = if ($e.DaysUntilFull) { $e.DaysUntilFull }
						elseif ($e.ForecastBasis -ne 'History') { "$($e.DataPoints)/$MinDataPoints" }
						else { '-' }
						$confDisplay = switch ($e.ForecastBasis) { 'History' { $e.ForecastConfidence } 'BackupHistory' { 'Boot' } default { '-' } }
						$lines.Add(("{0,-6} {1,-20} {2,-8} {3,-8} {4,-8} {5,-7} {6,-10} {7,-9} {8,-6} {9}" -f
								$e.Status, $e.MountPoint, $e.TotalGB, $e.UsedGB, $e.FreeGB,
								"$($e.FreePct)%", $perDayDisplay, $daysDisplay, $confDisplay, $e.Message))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					# CSV-Datei
					$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# HTML-Bericht (farbcodiert nach Status)
					$rowsHtml = ''
					foreach ($e in ($detailRows | Sort-Object Status, MountPoint))
					{
						$cls = switch ($e.Status) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
						$perDayDisplay = if ($e.GrowthPerDayGB) { $e.GrowthPerDayGB } elseif ($e.ForecastBasis -ne 'History') { 'sammelt' } else { 'stabil' }
						$daysDisplay   = if ($e.DaysUntilFull) { $e.DaysUntilFull } elseif ($e.ForecastBasis -ne 'History') { "$($e.DataPoints)/$MinDataPoints" } else { '-' }
						$confDisplay   = switch ($e.ForecastBasis) { 'History' { $e.ForecastConfidence } 'BackupHistory' { 'Boot' } default { '-' } }
						$mp = [string]$e.MountPoint -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
						$rowsHtml += "<tr><td class='$cls'>$($e.Status)</td><td>$mp</td><td>$($e.TotalGB)</td><td>$($e.UsedGB)</td><td>$($e.FreeGB)</td><td>$($e.FreePct)%</td><td>$perDayDisplay</td><td>$daysDisplay</td><td>$confDisplay</td></tr>`n"
					}
					$bodyHtml = @"
<table>
<thead><tr><th>Status</th><th>Laufwerk</th><th>Total GB</th><th>Used GB</th><th>Free GB</th><th>Free %</th><th>GB/Tag</th><th>Days Full</th><th>Konfidenz</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<p style="color:#94a8c0;font-size:12px;">Warn: &lt;${WarnThresholdPct}% &nbsp;|&nbsp; Critical: &lt;${CriticalThresholdPct}% &nbsp;|&nbsp; Prognose: Snapshot-Historie, Fenster $HistoryDays Tage, min. $MinDataPoints Laeufe &nbsp;|&nbsp; Critical: $cntCrit, Warning: $cntWarn, sammelt: $cntCollecting</p>
"@
					$html = ConvertTo-sqmHtmlReport -Title "Disk Space Report - $instance" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
					$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					# Oeffnen: HTML vor TXT, CSV nie. -NoOpen unterdrueckt.
					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$instance] Disk-Space-Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
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
					DetailRows					     = $detailRows
					TxtFile						     = $txtFile
					CsvFile						     = $csvFile
					HtmlFile					     = $htmlFile
					Status						     = if ($cntCrit -gt 0) { 'Critical' } elseif ($cntWarn -gt 0) { 'Warning' } else { 'OK' }
				}
				$allInstanceResults.Add($result)

				if ($cntCrit -gt 0)
				{
					Invoke-sqmLogging -Message "[$instance] $cntCrit Critical Disk-Space-Issue(s) - Bericht: $txtFile" -FunctionName $functionName -Level "WARNING"
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

# ---------------------------------------------------------------------------
# Private Hilfsfunktion: lineare Wachstumsprognose je Volume (Least Squares)
# ---------------------------------------------------------------------------
function Get-sqmVolumeForecast
{
	param (
		# Historien-Punkte mit .Timestamp ([datetime]) und .UsedGB ([double]) fuer EIN Volume
		[object[]]$History,
		[double]$FreeGB,
		[int]$MinDataPoints = 5
	)

	$pts = @($History | Where-Object { $_.Timestamp -and ($null -ne $_.UsedGB) } | Sort-Object Timestamp)
	$n = $pts.Count

	$insufficient = [PSCustomObject]@{
		DataPoints = $n; SpanDays = 0; SlopePerDayGB = $null; R2 = $null
		Confidence = 'None'; GrowthWindowGB = $null; DaysUntilFull = $null; Basis = 'Insufficient'
	}

	if ($n -lt $MinDataPoints) { return $insufficient }

	$t0 = $pts[0].Timestamp
	$xs = @($pts | ForEach-Object { ($_.Timestamp - $t0).TotalDays })
	$ys = @($pts | ForEach-Object { [double]$_.UsedGB })
	$spanDays = [math]::Round(($pts[$n - 1].Timestamp - $t0).TotalDays, 2)

	# Zu kurze Zeitspanne (z.B. mehrere Laeufe innerhalb weniger Stunden) -> keine belastbare Steigung.
	if ($spanDays -lt 1) { return $insufficient }

	$xbar = ($xs | Measure-Object -Average).Average
	$ybar = ($ys | Measure-Object -Average).Average
	$sxx = 0.0; $sxy = 0.0; $syy = 0.0
	for ($i = 0; $i -lt $n; $i++)
	{
		$dx = $xs[$i] - $xbar
		$dy = $ys[$i] - $ybar
		$sxx += $dx * $dx
		$sxy += $dx * $dy
		$syy += $dy * $dy
	}
	if ($sxx -eq 0) { return $insufficient }

	$slope = $sxy / $sxx                              # GB pro Tag
	$r2 = if ($syy -gt 0) { ($sxy * $sxy) / ($sxx * $syy) } else { 1 }
	$growthWindow = [math]::Round($ys[$n - 1] - $ys[0], 2)   # tatsaechlich beobachtete Aenderung im Fenster
	$daysUntilFull = if ($slope -gt 0.0001) { [math]::Round($FreeGB / $slope, 0) } else { $null }

	$confidence = if ($n -ge 7 -and $r2 -ge 0.8) { 'High' }
	elseif ($n -ge 5 -and $r2 -ge 0.5) { 'Medium' }
	else { 'Low' }

	return [PSCustomObject]@{
		DataPoints     = $n
		SpanDays       = $spanDays
		SlopePerDayGB  = [math]::Round($slope, 3)
		R2             = [math]::Round($r2, 3)
		Confidence     = $confidence
		GrowthWindowGB = $growthWindow
		DaysUntilFull  = $daysUntilFull
		Basis          = 'History'
	}
}

# ---------------------------------------------------------------------------
# Private Hilfsfunktion: Bootstrap-Wachstumsrate je Volume aus msdb-Backup-Historie (Methode B2)
# Leitet pro DB den Daten-Wachstumstrend aus Full-Backup-Groessen ab und verteilt die Rate
# proportional zur Datendatei-Groesse auf die Volumes (volume_mount_point). Rueckgabe:
# Hashtable mountpoint -> @{ SlopePerDayGB; Dbs }. Fehler werden an den Aufrufer durchgereicht.
# ---------------------------------------------------------------------------
function Get-sqmBackupGrowthSeed
{
	param (
		[hashtable]$ConnParams,
		[int]$Days = 90,
		[object[]]$Volumes
	)

	$seed = @{ }

	$backupQuery = @"
SELECT bs.database_name                 AS DatabaseName,
       bs.backup_finish_date            AS FinishDate,
       bs.backup_size / 1073741824.0    AS BackupGB
FROM msdb.dbo.backupset bs
WHERE bs.type = 'D' AND bs.is_copy_only = 0 AND bs.backup_size > 0
  AND bs.backup_finish_date >= DATEADD(DAY, -$Days, GETDATE())
ORDER BY bs.database_name, bs.backup_finish_date;
"@
	$backups = @(Invoke-DbaQuery @ConnParams -Query $backupQuery -EnableException:$true)
	if ($backups.Count -eq 0) { return $seed }

	# Datendateien (ROWS) -> Volume ueber laengsten Pfad-Praefix der Mount Points.
	$fileRows = @(Invoke-DbaQuery @ConnParams -Query "SELECT DB_NAME(database_id) AS DatabaseName, physical_name AS PhysicalName, size * 8.0 / 1024 / 1024 AS FileGB FROM sys.master_files WHERE type = 0" -EnableException:$true)
	$mounts = @($Volumes | ForEach-Object { [string]$_.MountPoint } | Sort-Object { $_.Length } -Descending)

	$dbMountGB = @{ }   # "$db|$mount" -> GB
	$dbTotalGB = @{ }   # "$db"        -> GB
	foreach ($fl in $fileRows)
	{
		$path = [string]$fl.PhysicalName
		$mt = $null
		foreach ($m in $mounts) { if ($path -and $m -and $path.StartsWith($m, [System.StringComparison]::OrdinalIgnoreCase)) { $mt = $m; break } }
		if (-not $mt) { continue }
		$g = [double]$fl.FileGB
		$db = [string]$fl.DatabaseName
		$dbMountGB["$db|$mt"] = [double]($dbMountGB["$db|$mt"]) + $g
		$dbTotalGB[$db] = [double]($dbTotalGB[$db]) + $g
	}

	# Pro DB die Daten-Wachstumsrate (GB/Tag) aus dem Backup-Groessen-Trend bestimmen
	# (min. 3 Punkte genuegen fuer einen Bootstrap) und proportional auf die Volumes verteilen.
	foreach ($grp in ($backups | Group-Object DatabaseName))
	{
		$db = [string]$grp.Name
		$total = [double]($dbTotalGB[$db])
		if ($total -le 0) { continue }

		$pts = @($grp.Group | ForEach-Object { [PSCustomObject]@{ Timestamp = [datetime]$_.FinishDate; UsedGB = [double]$_.BackupGB } })
		$dbFc = Get-sqmVolumeForecast -History $pts -FreeGB 0 -MinDataPoints 3
		if ($dbFc.Basis -ne 'History' -or -not $dbFc.SlopePerDayGB -or $dbFc.SlopePerDayGB -le 0) { continue }
		$slope = [double]$dbFc.SlopePerDayGB

		foreach ($m in $mounts)
		{
			$key = "$db|$m"
			if ($dbMountGB.ContainsKey($key))
			{
				$frac = [double]($dbMountGB[$key]) / $total
				if (-not $seed.ContainsKey($m)) { $seed[$m] = @{ SlopePerDayGB = 0.0; Dbs = 0 } }
				$seed[$m].SlopePerDayGB += $slope * $frac
				$seed[$m].Dbs += 1
			}
		}
	}

	foreach ($k in @($seed.Keys)) { $seed[$k].SlopePerDayGB = [math]::Round($seed[$k].SlopePerDayGB, 3) }
	return $seed
}
