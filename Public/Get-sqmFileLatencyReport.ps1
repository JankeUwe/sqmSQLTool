<#
.SYNOPSIS
    Measures read and write latency per database file (sys.dm_io_virtual_file_stats), either
    since the last restart or as a live sample over a few seconds.

.DESCRIPTION
    Reads sys.dm_io_virtual_file_stats joined with sys.master_files and calculates per file:
      - Reads / writes, MB read / written
      - Average read and write latency in ms (io_stall / number of I/Os)
      - Rating per file: OK, Warning, Critical
      - Drive / mount point, so slow volumes stand out in the per-drive summary

    Two modes:
      Cumulative (default)  Values since the last SQL Server start. Good for the overall
                            picture, but a short slow phase disappears in a long uptime.
      Sample (-SampleSeconds N)
                            Two snapshots N seconds apart, values are the difference. Shows
                            what the storage delivers right now (e.g. during the nightly batch).

    Rating thresholds (average latency):
      Data files  read and write  OK <= 20 ms, Warning <= 50 ms, Critical > 50 ms
      Log files   write           OK <= 5 ms,  Warning <= 15 ms, Critical > 15 ms
      Log files   read            rated like data files (reads happen on backup, AG, CDC)
    Files with fewer I/Os than -MinIo are listed but not rated: a few slow I/Os on an idle
    file say nothing.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Only files of these databases (wildcards allowed). Default: all, including tempdb.

.PARAMETER SampleSeconds
    0 (default) = cumulative since start. 1-3600 = live sample over that many seconds.

.PARAMETER MinIo
    Minimum number of reads (for the read rating) or writes (for the write rating) before a
    file is rated. Default: 1000 cumulative, 10 in sample mode.

.PARAMETER OutputPath
    Directory for the CSV/HTML report. Default: <OutputPath config>\FileLatencyReport.

.PARAMETER NoReport
    Do not write files (objects are still returned).

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmFileLatencyReport -SqlInstance "SQL01"

.EXAMPLE
    # What does the storage deliver during the batch right now (60 s sample)?
    Get-sqmFileLatencyReport -SqlInstance "SQL01" -SampleSeconds 60

.EXAMPLE
    # Only critical files
    Get-sqmFileLatencyReport -SqlInstance "SQL01" -NoReport | Where-Object Rating -eq 'Critical'

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE on the instance.
    Latency measured by SQL Server includes the whole I/O path (driver, HBA, SAN, cache).
    For the volume itself compare with the Windows counters Avg. Disk sec/Read and sec/Write.
#>
function Get-sqmFileLatencyReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 3600)]
		[int]$SampleSeconds = 0,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, [long]::MaxValue)]
		[long]$MinIo = 0,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'FileLatencyReport'),
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
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

		if (-not $PSBoundParameters.ContainsKey('MinIo')) { $MinIo = if ($SampleSeconds -gt 0) { 10 } else { 1000 } }

		$statsQuery = @"
SET NOCOUNT ON;
SELECT
    DB_NAME(vfs.database_id)      AS DatabaseName,
    vfs.database_id               AS DatabaseId,
    vfs.file_id                   AS FileId,
    mf.name                       AS LogicalName,
    mf.type_desc                  AS FileType,
    mf.physical_name              AS PhysicalName,
    vfs.num_of_reads              AS NumReads,
    vfs.num_of_bytes_read         AS BytesRead,
    vfs.io_stall_read_ms          AS StallReadMs,
    vfs.num_of_writes             AS NumWrites,
    vfs.num_of_bytes_written      AS BytesWritten,
    vfs.io_stall_write_ms         AS StallWriteMs,
    vfs.size_on_disk_bytes        AS SizeOnDiskBytes
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id;
"@

		Invoke-sqmLogging -Message ("Starte " + $functionName + " auf " + $SqlInstance) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance; SqlCredential = $SqlCredential; Database = 'master' }

			$startTime = (Invoke-DbaQuery @connParams -Query "SELECT sqlserver_start_time AS t FROM sys.dm_os_sys_info" -EnableException).t
			$first = @(Invoke-DbaQuery @connParams -Query $statsQuery -EnableException)

			if ($SampleSeconds -gt 0)
			{
				Invoke-sqmLogging -Message "Messung ueber $SampleSeconds Sekunde(n) ..." -FunctionName $functionName -Level "INFO"
				Start-Sleep -Seconds $SampleSeconds
				$second = @(Invoke-DbaQuery @connParams -Query $statsQuery -EnableException)
				$before = @{}
				foreach ($f in $first) { $before["$($f.DatabaseId)|$($f.FileId)"] = $f }
				$rows = foreach ($f in $second)
				{
					$b = $before["$($f.DatabaseId)|$($f.FileId)"]
					if (-not $b) { continue }
					[PSCustomObject]@{
						DatabaseName = $f.DatabaseName; LogicalName = $f.LogicalName; FileType = $f.FileType; PhysicalName = $f.PhysicalName
						NumReads = [long]$f.NumReads - [long]$b.NumReads; BytesRead = [long]$f.BytesRead - [long]$b.BytesRead; StallReadMs = [long]$f.StallReadMs - [long]$b.StallReadMs
						NumWrites = [long]$f.NumWrites - [long]$b.NumWrites; BytesWritten = [long]$f.BytesWritten - [long]$b.BytesWritten; StallWriteMs = [long]$f.StallWriteMs - [long]$b.StallWriteMs
						SizeOnDiskBytes = [long]$f.SizeOnDiskBytes
					}
				}
				$mode = "Messung $SampleSeconds s"
			}
			else
			{
				$rows = $first
				$mode = "kumuliert seit $startTime"
			}

			$rate = {
				param ([double]$ms, [long]$ios, [bool]$isLogWrite)
				if ($ios -lt $MinIo) { return 'n/a' }
				$warn = if ($isLogWrite) { 5 } else { 20 }
				$crit = if ($isLogWrite) { 15 } else { 50 }
				if ($ms -gt $crit) { 'Critical' } elseif ($ms -gt $warn) { 'Warning' } else { 'OK' }
			}
			$severity = @{ 'Critical' = 3; 'Warning' = 2; 'OK' = 1; 'n/a' = 0 }

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			foreach ($r in $rows)
			{
				if ($Database.Count -gt 0 -and @($Database | Where-Object { $r.DatabaseName -like $_ }).Count -eq 0) { continue }

				$isLog = $r.FileType -eq 'LOG'
				$avgRead = if ([long]$r.NumReads -gt 0) { [math]::Round([double]$r.StallReadMs / [long]$r.NumReads, 2) } else { 0 }
				$avgWrite = if ([long]$r.NumWrites -gt 0) { [math]::Round([double]$r.StallWriteMs / [long]$r.NumWrites, 2) } else { 0 }
				$readRating = & $rate $avgRead ([long]$r.NumReads) $false
				$writeRating = & $rate $avgWrite ([long]$r.NumWrites) $isLog
				$overall = if ($severity[$readRating] -ge $severity[$writeRating]) { $readRating } else { $writeRating }

				$path = [string]$r.PhysicalName
				$drive = if ($path -match '^([A-Za-z]:)\\') { $Matches[1].ToUpper() } elseif ($path -match '^(\\\\[^\\]+\\[^\\]+)') { $Matches[1] } else { ([regex]::Match($path, '^.*[\\/]').Value) }

				$results.Add([PSCustomObject]@{
					SqlInstance     = $SqlInstance
					DatabaseName    = $r.DatabaseName
					LogicalName     = $r.LogicalName
					FileType        = $r.FileType
					Drive           = $drive
					Reads           = [long]$r.NumReads
					AvgReadMs       = $avgRead
					ReadRating      = $readRating
					MBRead          = [math]::Round([double]$r.BytesRead / 1MB, 1)
					Writes          = [long]$r.NumWrites
					AvgWriteMs      = $avgWrite
					WriteRating     = $writeRating
					MBWritten       = [math]::Round([double]$r.BytesWritten / 1MB, 1)
					Rating          = $overall
					SizeMB          = [math]::Round([double]$r.SizeOnDiskBytes / 1MB, 1)
					PhysicalName    = $path
					Mode            = $mode
				})
			}

			$sorted = @($results | Sort-Object @{ Expression = { $severity[$_.Rating] }; Descending = $true }, @{ Expression = { [math]::Max($_.AvgReadMs, $_.AvgWriteMs) }; Descending = $true })

			# Zusammenfassung je Laufwerk (gewichteter Durchschnitt ueber alle Dateien)
			$byDrive = foreach ($g in ($results | Group-Object Drive))
			{
				$rd = ($g.Group | Measure-Object Reads -Sum).Sum
				$wr = ($g.Group | Measure-Object Writes -Sum).Sum
				$rdStall = ($g.Group | ForEach-Object { $_.AvgReadMs * $_.Reads } | Measure-Object -Sum).Sum
				$wrStall = ($g.Group | ForEach-Object { $_.AvgWriteMs * $_.Writes } | Measure-Object -Sum).Sum
				[PSCustomObject]@{
					Drive      = $g.Name
					Files      = $g.Count
					Reads      = $rd
					AvgReadMs  = if ($rd -gt 0) { [math]::Round($rdStall / $rd, 2) } else { 0 }
					Writes     = $wr
					AvgWriteMs = if ($wr -gt 0) { [math]::Round($wrStall / $wr, 2) } else { 0 }
					Worst      = ($g.Group | Sort-Object { $severity[$_.Rating] } -Descending | Select-Object -First 1).Rating
				}
			}

			if (-not $NoReport -and $results.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:*?"<>|,]', '_'
				$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
				$csvFile = Join-Path $OutputPath ("FileLatencyReport_" + $safeInst + "_" + $stamp + ".csv")
				$sorted | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

				$enc = { param ($s) ([string]$s) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
				$cls = { param ($rt) switch ($rt) { 'Critical' { 'crit' } 'Warning' { 'warn' } 'OK' { 'ok' } default { '' } } }
				$sb = New-Object System.Text.StringBuilder
				[void]$sb.Append("<p>Modus: $(& $enc $mode). Grenzwerte: Daten &le; 20 ms OK, &le; 50 ms Warnung; Log-Schreiben &le; 5 ms OK, &le; 15 ms Warnung. Dateien mit weniger als $MinIo I/Os werden nicht bewertet (n/a).</p>")
				[void]$sb.Append("<h2>Je Laufwerk</h2><table><tr><th>Laufwerk</th><th class='num'>Dateien</th><th class='num'>Reads</th><th class='num'>Read ms</th><th class='num'>Writes</th><th class='num'>Write ms</th><th>Schlechteste Datei</th></tr>")
				foreach ($d in ($byDrive | Sort-Object Drive))
				{
					[void]$sb.Append("<tr><td>$(& $enc $d.Drive)</td><td class='num'>$($d.Files)</td><td class='num'>$($d.Reads)</td><td class='num'>$($d.AvgReadMs)</td><td class='num'>$($d.Writes)</td><td class='num'>$($d.AvgWriteMs)</td><td class='$(& $cls $d.Worst)'>$($d.Worst)</td></tr>")
				}
				[void]$sb.Append("</table><h2>Je Datei</h2><table><tr><th>Datenbank</th><th>Datei</th><th>Typ</th><th>Laufwerk</th><th class='num'>Reads</th><th class='num'>Read ms</th><th class='num'>Writes</th><th class='num'>Write ms</th><th class='num'>MB gelesen</th><th class='num'>MB geschrieben</th><th>Bewertung</th></tr>")
				foreach ($f in $sorted)
				{
					[void]$sb.Append("<tr><td>$(& $enc $f.DatabaseName)</td><td>$(& $enc $f.LogicalName)</td><td>$($f.FileType)</td><td>$(& $enc $f.Drive)</td><td class='num'>$($f.Reads)</td><td class='num $(& $cls $f.ReadRating)'>$($f.AvgReadMs)</td><td class='num'>$($f.Writes)</td><td class='num $(& $cls $f.WriteRating)'>$($f.AvgWriteMs)</td><td class='num'>$($f.MBRead)</td><td class='num'>$($f.MBWritten)</td><td class='$(& $cls $f.Rating)'>$($f.Rating)</td></tr>")
				}
				[void]$sb.Append('</table>')

				$htmlFile = Join-Path $OutputPath ("FileLatencyReport_" + $safeInst + "_" + $stamp + ".html")
				$html = ConvertTo-sqmHtmlReport -Title "File Latency - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $sb.ToString()
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Copy-sqmToCentralPath -Path @($csvFile, $htmlFile)
				Invoke-sqmLogging -Message ("Report gespeichert: " + $htmlFile) -FunctionName $functionName -Level "INFO"
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}

			$crit = @($results | Where-Object Rating -eq 'Critical').Count
			$warn = @($results | Where-Object Rating -eq 'Warning').Count
			$level = if ($crit -gt 0) { 'WARNING' } else { 'INFO' }
			Invoke-sqmLogging -Message "$($results.Count) Datei(en) ausgewertet ($mode): Critical=$crit, Warning=$warn." -FunctionName $functionName -Level $level
			return $sorted
		}
		catch
		{
			$errMsg = "Fehler bei der Latenzmessung: " + $_.Exception.Message
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}

	end
	{
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen.") -FunctionName $functionName -Level "INFO"
	}
}
