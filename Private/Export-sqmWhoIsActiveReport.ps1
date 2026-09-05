<#
.SYNOPSIS
    Schreibt CSV (alle Snapshots) und HTML (nur letzter Snapshot) fuer einen WhoIsActive-Lauf.

.DESCRIPTION
    Gemeinsame Report-Erzeugung fuer Get-sqmWhoIsActive und Show-sqmWhoIsActiveMonitor:
    die CSV enthaelt die komplette Historie aller Iterationen eines Laufs (fuer
    Nachanalyse), der HTML-Bericht bewusst NUR den letzten Snapshot - bei einem
    Dauerlauf ueber ggf. hunderte Iterationen ist der aktuelle Zustand relevant,
    nicht ein sich staendig verlaengernder Verlauf.

.PARAMETER AllSnapshots
    Alle Zeilen aus allen Iterationen des Laufs (-> CSV).

.PARAMETER LastSnapshotRows
    Nur die Zeilen der letzten Iteration (-> HTML).

.PARAMETER IterationCount
    Anzahl der insgesamt durchgefuehrten Iterationen (fuer die HTML-Kopfzeile).

.NOTES
    Privat - wird ausschliesslich von Get-sqmWhoIsActive und Show-sqmWhoIsActiveMonitor
    aufgerufen. Schreibt nichts und liefert leere Pfade, wenn AllSnapshots leer ist.
#>
function Export-sqmWhoIsActiveReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[object[]]$AllSnapshots,
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[object[]]$LastSnapshotRows,
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$OutputPath,
		[Parameter(Mandatory = $true)]
		[int]$IterationCount,
		[Parameter(Mandatory = $true)]
		[datetime]$LoopStart,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	$result = [PSCustomObject]@{ CsvFile = $null; HtmlFile = $null }
	if (-not $OutputPath -or $AllSnapshots.Count -eq 0) { return $result }

	if (-not (Test-Path $OutputPath))
	{
		New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
	}
	$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
	$safeInst = $SqlInstance -replace '\\', '_'

	$csvFile = Join-Path $OutputPath "WhoIsActive_${safeInst}_${stamp}.csv"
	$AllSnapshots | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

	$htmlFile = Join-Path $OutputPath "WhoIsActive_${safeInst}_${stamp}.html"
	$rowsHtml = foreach ($s in $LastSnapshotRows)
	{
		$elapsedTxt = Format-sqmTimeSpan -Seconds ([math]::Max(0, [int]$s.ElapsedSeconds))
		$sevClass = if ($s.BlockingSessionId -gt 0) { 'crit' } elseif ($s.ElapsedSeconds -ge 30) { 'warn' } else { 'ok' }
		"<tr><td class='$sevClass'>$($s.SessionId)</td><td>$elapsedTxt</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.Status))</td><td>$($s.BlockingSessionId)</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.WaitInfo))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.DatabaseName))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.LoginName))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.HostName))</td><td>$($s.CpuTimeMs)</td><td>$($s.Reads)</td><td>$($s.TempdbAllocMB)</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$s.SqlText))</td></tr>"
	}
	$bodyHtml = "<p>$IterationCount Snapshot(s) erfasst zwischen $($LoopStart.ToString('yyyy-MM-dd HH:mm:ss')) und $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')). Letzter Snapshot: $($LastSnapshotRows.Count) Session(s).</p>" +
		"<table><tr><th>SPID</th><th>Elapsed</th><th>Status</th><th>Blocked by</th><th>Wait Info</th><th>Datenbank</th><th>Login</th><th>Host</th><th>CPU ms</th><th>Reads</th><th>Tempdb MB</th><th>SQL Text</th></tr>" +
		($rowsHtml -join '') + "</table>"
	$html = ConvertTo-sqmHtmlReport -Title "Who Is Active - $SqlInstance" -Subtitle "Letzter Snapshot: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ($IterationCount Snapshot(s) gesamt)" -BodyHtml $bodyHtml
	$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

	Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

	$result.CsvFile = $csvFile
	$result.HtmlFile = $htmlFile
	return $result
}
