<#
.SYNOPSIS
    Prueft eine Instanz (oder eine zweite Baseline) gegen eine mit Save-sqmConfigBaseline gespeicherte Baseline.

.DESCRIPTION
    Config-Drift-Pruefung ueber die Zeit und zwischen Instanzen. Verglichen werden alle Optionen aus
    sys.configurations (aktiver Wert, ausstehende Aenderungen RECONFIGURE/Neustart) und die globalen
    Trace Flags. Zwei Betriebsarten:
    - Live (Standard): -SqlInstance wird jetzt gelesen und gegen die Baseline geprueft.
    - File: -ComparePath vergleicht zwei gespeicherte Baselines (z.B. vor und nach einem Patch).

    Unterscheiden sich die Hauptversionen von Baseline und Vergleich, gibt es eine Warnung; Optionen, die nur
    in einer der Versionen existieren, werden nicht als Drift gewertet. 'version high part' und
    'version low part' werden immer ignoriert. Sicherheitsrelevante Optionen (xp_cmdshell, Ole Automation,
    Ad Hoc Distributed Queries, CLR, ...) sind bei Abweichung Critical.

    Rueckgabe: eine Zeile pro Abweichung (Category, Setting, SourceValue = Baseline, TargetValue = Vergleich,
    Status, DriftType). Kein Drift = leere Rueckgabe. Zusaetzlich TXT- und HTML-Report.

.PARAMETER BaselinePath
    JSON-Datei aus Save-sqmConfigBaseline (Referenz).

.PARAMETER SqlInstance
    Live-Modus: Instanz, die gegen die Baseline geprueft wird.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung (Live-Modus).

.PARAMETER ComparePath
    File-Modus: zweite Baseline-Datei, die gegen -BaselinePath geprueft wird.

.PARAMETER IgnoreOption
    Zusaetzliche Optionsnamen (Wildcards erlaubt), die nicht verglichen werden.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer TXT/HTML. Standard: <Ausgabepfad der Modulkonfiguration>\ConfigBaselineCompare.

.PARAMETER NoOpen
    Report nicht automatisch oeffnen.

.PARAMETER NoReport
    Keine Report-Dateien schreiben.

.PARAMETER EnableException
    Fehler werfen statt melden.

.EXAMPLE
    Compare-sqmConfigBaseline -BaselinePath "D:\Baselines\ConfigBaseline_SQL01_v15_20261101_090000.json" -SqlInstance "SQL02"

.EXAMPLE
    Compare-sqmConfigBaseline -BaselinePath $vorPatch -ComparePath $nachPatch -NoOpen

.OUTPUTS
    [PSCustomObject[]] Category, Setting, SourceValue, TargetValue, Status, DriftType.

.NOTES
    Uses Invoke-DbaQuery (Live-Modus).
#>
function Compare-sqmConfigBaseline
{
	[CmdletBinding(DefaultParameterSetName = 'Live')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$BaselinePath,
		[Parameter(Mandatory = $true, ParameterSetName = 'Live')]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false, ParameterSetName = 'Live')]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true, ParameterSetName = 'File')]
		[string]$ComparePath,
		[Parameter(Mandatory = $false)]
		[string[]]$IgnoreOption = @(),
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'ConfigBaselineCompare'),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name

	function _Load
	{
		param ([string]$Path)
		if (-not (Test-Path -LiteralPath $Path)) { throw "Baseline-Datei nicht gefunden: $Path" }
		$j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
		if (-not $j.Options -or -not $j.Meta) { throw "Keine gueltige Baseline-Datei: $Path" }
		[PSCustomObject]@{
			Meta           = $j.Meta
			Options        = @($j.Options)
			TraceFlags     = @($j.TraceFlags | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
			TraceFlagsRead = [bool]$j.TraceFlagsRead
		}
	}

	function _h { param($x) [string]$x -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

	try
	{
		if (-not (Get-Module -ListAvailable -Name dbatools) -and $PSCmdlet.ParameterSetName -eq 'Live') { throw "dbatools-Modul nicht gefunden." }

		$ref = _Load $BaselinePath
		if ($PSCmdlet.ParameterSetName -eq 'File')
		{
			$dif = _Load $ComparePath
			$targetName = "Baseline $(Split-Path $ComparePath -Leaf)"
		}
		else
		{
			$dif = Get-sqmConfigOptionSet -SqlInstance $SqlInstance -SqlCredential $SqlCredential
			$targetName = $SqlInstance
		}
		$sourceName = "Baseline $(Split-Path $BaselinePath -Leaf)"

		$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
		if ($ref.Meta.MajorVersion -ne $dif.Meta.MajorVersion)
		{
			$vmsg = "Baseline ist Version $($ref.Meta.ProductVersion), Vergleich ist Version $($dif.Meta.ProductVersion): nur Optionen beider Versionen werden verglichen."
			Write-Warning $vmsg
			Invoke-sqmLogging -Message $vmsg -FunctionName $functionName -Level "WARNING"
			$rows.Add([PSCustomObject]@{
					Category = 'Version'; Setting = 'Hauptversion'; SourceValue = $ref.Meta.ProductVersion
					TargetValue = $dif.Meta.ProductVersion; Status = 'Warning'; DriftType = 'version differs'
				})
		}
		foreach ($r in @(Compare-sqmConfigOptionSet -Reference $ref -Difference $dif -IgnoreOption $IgnoreOption)) { $rows.Add($r) }

		$cntCrit = @($rows | Where-Object Status -eq 'Critical').Count
		$cntWarn = @($rows | Where-Object Status -eq 'Warning').Count
		Invoke-sqmLogging -Message "Baseline-Vergleich abgeschlossen ($sourceName vs $targetName). Critical: $cntCrit | Warning: $cntWarn" -FunctionName $functionName -Level "INFO"

		if (-not $NoReport)
		{
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
			$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
			$safe = ($ref.Meta.ServerName -replace '[\\/:*?"<>|]', '_')
			$txtFile = Join-Path $OutputPath "ConfigBaselineCompare_${safe}_$stamp.txt"
			$htmlFile = Join-Path $OutputPath "ConfigBaselineCompare_${safe}_$stamp.html"
			$statusOrder = @{ Critical = 0; Warning = 1; OK = 2 }
			$sorted = @($rows | Sort-Object @{ Expression = { $statusOrder[$_.Status] } }, Category, Setting)

			$lines = [System.Collections.Generic.List[string]]::new()
			$lines.Add("# ================================================================")
			$lines.Add("# sqmSQLTool - Config-Drift gegen Baseline")
			$lines.Add("# $(Get-sqmReportReference)")
			$lines.Add("# Baseline          : $BaselinePath (erfasst $($ref.Meta.CapturedAt), $($ref.Meta.ProductVersion))")
			$lines.Add("# Vergleich         : $targetName")
			$lines.Add("# Erstellt          : $timestamp")
			$lines.Add("# Critical: $cntCrit | Warning: $cntWarn")
			$lines.Add("# ================================================================")
			$lines.Add("")
			if ($sorted.Count -eq 0) { $lines.Add("Kein Drift gefunden.") }
			else
			{
				$lines.Add(("{0,-9} {1,-12} {2,-42} {3,-26} {4,-26} {5}" -f 'Status', 'Kategorie', 'Setting', 'Baseline', 'Vergleich', 'Art'))
				$lines.Add(('-' * 140))
				foreach ($e in $sorted)
				{
					$s = if ($e.Setting.Length -gt 42) { $e.Setting.Substring(0, 39) + '...' } else { $e.Setting }
					$lines.Add(("{0,-9} {1,-12} {2,-42} {3,-26} {4,-26} {5}" -f $e.Status, $e.Category, $s, $e.SourceValue, $e.TargetValue, $e.DriftType))
				}
			}
			[System.IO.File]::WriteAllText($txtFile, ($lines -join "`n"), [System.Text.Encoding]::UTF8)

			$rowsHtml = ''
			foreach ($e in $sorted)
			{
				$cls = switch ($e.Status) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
				$rowsHtml += "<tr><td class='$cls'>$(_h $e.Status)</td><td>$(_h $e.Category)</td><td>$(_h $e.Setting)</td>" +
				"<td>$(_h $e.SourceValue)</td><td>$(_h $e.TargetValue)</td><td>$(_h $e.DriftType)</td></tr>`n"
			}
			$summary = if ($sorted.Count -eq 0) { '<p>Kein Drift gefunden.</p>' }
			else
			{
				"<table><thead><tr><th>Status</th><th>Kategorie</th><th>Setting</th><th>Baseline</th><th>Vergleich ($(_h $targetName))</th><th>Art</th></tr></thead><tbody>`n$rowsHtml</tbody></table>"
			}
			$bodyHtml = "$summary<p style=""color:#94a8c0;font-size:12px;"">Critical: $cntCrit &nbsp;|&nbsp; Warning: $cntWarn &nbsp;|&nbsp; Baseline erfasst: $(_h $ref.Meta.CapturedAt) ($(_h $ref.Meta.ProductVersion))</p>"
			$html = ConvertTo-sqmHtmlReport -Title "Config-Drift gegen Baseline" -Subtitle "$(_h $ref.Meta.ServerName) vs $(_h $targetName) - Erstellt: $timestamp" -BodyHtml $bodyHtml
			[System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)

			Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
			Invoke-sqmLogging -Message "Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
		}

		return $rows
	}
	catch
	{
		Invoke-sqmLogging -Message "Baseline-Vergleich fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw }
		Write-Error "Baseline-Vergleich fehlgeschlagen: $($_.Exception.Message)"
		return $null
	}
}
