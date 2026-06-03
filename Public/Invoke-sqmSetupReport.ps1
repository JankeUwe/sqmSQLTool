<#
.SYNOPSIS
    Erstellt einen HTML-Abschlussbericht nach SQL Server Setup / PostInstall.

.DESCRIPTION
    Fuehrt alle konfigurierten Setup-Checks durch und erzeugt einen HTML-Report
    mit OK/WARN/ERROR-Badges. Welche Checks ausgefuehrt werden haengt vom
    CheckProfile in der Modulkonfiguration ab:

      Auto    - FI-TS-Checks nur wenn $script:sqmIsFitsEnvironment = $true
      FiTs    - FI-TS-Checks immer erzwingen
      Generic - nur Standard-Checks, keine FI-TS-spezifischen Pruefungen

    FI-TS-spezifische Checks:
      - Test-sqmCostThreshold   (CostThresholdForParallelism)
      - Test-sqmTempDbFileCount (TempDB-Datendateien vs. CPU-Kerne)
      - Get-sqmDiskBlockSize    (NTFS-Blockgroesse 64 KB)

    Der Report wird nach OutputPath und (wenn konfiguriert) CentralPath abgelegt.
    Dateiname: sqmSetupReport_<Instanz>_<Datum>.html

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung.

.PARAMETER CheckProfile
    Ueberschreibt den Wert aus der Modulkonfiguration.
    Gueltiger Werte: Auto | FiTs | Generic

.PARAMETER OutputPath
    Ausgabepfad fuer den HTML-Report. Standard: Get-sqmConfig OutputPath.

.PARAMETER PassThru
    Gibt den Pfad der erstellten HTML-Datei als String zurueck.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt Write-Error.

.OUTPUTS
    Kein Output (oder Dateipfad wenn -PassThru).

.EXAMPLE
    # Am Ende von PostInstall - CheckProfile aus Modulkonfiguration
    Invoke-sqmSetupReport -SqlInstance "SQL01"

.EXAMPLE
    # FI-TS-Checks erzwingen (z.B. fuer Tests ausserhalb der Domaene)
    Invoke-sqmSetupReport -SqlInstance "SQL01" -CheckProfile FiTs -PassThru

.EXAMPLE
    # Nur generische Checks - kein FI-TS-Profil
    Invoke-sqmSetupReport -SqlInstance "SQL01" -CheckProfile Generic

.NOTES
    Abhaengigkeiten: Invoke-sqmLogging, Get-sqmConfig, Copy-sqmToCentralPath
    FI-TS-Checks:   Test-sqmCostThreshold, Test-sqmTempDbFileCount, Get-sqmDiskBlockSize
    Standard-Check: Get-sqmSQLInstanceCheck
#>
function Invoke-sqmSetupReport
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Auto', 'FiTs', 'Generic')]
        [string]$CheckProfile,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException,

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name

        if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
        {
            $SqlInstance = $env:COMPUTERNAME
        }

        # CheckProfile: Parameter > Config > Default 'Auto'
        if (-not $PSBoundParameters.ContainsKey('CheckProfile'))
        {
            $CheckProfile = Get-sqmConfig -Key 'CheckProfile'
            if (-not $CheckProfile) { $CheckProfile = 'Auto' }
        }

        # OutputPath: Parameter > Config
        if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath))
        {
            $OutputPath = Get-sqmConfig -Key 'OutputPath'
            if (-not $OutputPath) { $OutputPath = "$env:ProgramData\sqmSQLTool\Logs" }
        }

        # Entscheiden ob FI-TS-Checks laufen
        $runFitsChecks = switch ($CheckProfile)
        {
            'FiTs'    { $true }
            'Generic' { $false }
            default   { $script:sqmIsFitsEnvironment }   # Auto
        }

        Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Profil: $CheckProfile, FiTs-Checks: $runFitsChecks)" -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        try
        {
            $checkResults = [System.Collections.Generic.List[PSCustomObject]]::new()
            $timestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $safeInstance = $SqlInstance -replace '[\\:]', '_'
            $datestamp    = Get-Date -Format 'yyyyMMdd_HHmm'

            # ------------------------------------------------------------------
            # 1. Standard-Instanzcheck (Get-sqmSQLInstanceCheck)
            # ------------------------------------------------------------------
            Write-Host "  Fuehre Instanz-Check durch..." -ForegroundColor Gray
            try
            {
                $instanceChecks = Get-sqmSQLInstanceCheck -SqlInstance $SqlInstance -ErrorAction Stop
                foreach ($ic in @($instanceChecks))
                {
                    $checkResults.Add([PSCustomObject]@{
                        Category = 'Instanz-Konfiguration'
                        Check    = $ic.CheckName
                        Status   = $ic.Status
                        Current  = $ic.CurrentValue
                        Expected = $ic.RecommendedValue
                        Message  = $ic.Message
                    })
                }
            }
            catch
            {
                $checkResults.Add([PSCustomObject]@{
                    Category = 'Instanz-Konfiguration'
                    Check    = 'Get-sqmSQLInstanceCheck'
                    Status   = 'Error'
                    Current  = '-'
                    Expected = '-'
                    Message  = $_.Exception.Message
                })
            }

            # ------------------------------------------------------------------
            # 2. FI-TS-spezifische Checks
            # ------------------------------------------------------------------
            if ($runFitsChecks)
            {
                Write-Host "  Fuehre FI-TS-spezifische Checks durch..." -ForegroundColor Gray

                # 2a. CostThresholdForParallelism
                try
                {
                    $r = Test-sqmCostThreshold -SqlInstance $SqlInstance -ErrorAction Stop
                    $checkResults.Add([PSCustomObject]@{
                        Category = 'FI-TS Konfiguration'
                        Check    = 'CostThresholdForParallelism'
                        Status   = $r.Status
                        Current  = $r.CurrentValue
                        Expected = ">= $($r.RecommendedMinValue)"
                        Message  = $r.Message
                    })
                }
                catch
                {
                    $checkResults.Add([PSCustomObject]@{
                        Category = 'FI-TS Konfiguration'
                        Check    = 'CostThresholdForParallelism'
                        Status   = 'Error'
                        Current  = '-'
                        Expected = "-"
                        Message  = $_.Exception.Message
                    })
                }

                # 2b. TempDB-Datendateien
                try
                {
                    $r = Test-sqmTempDbFileCount -SqlInstance $SqlInstance -ErrorAction Stop
                    $checkResults.Add([PSCustomObject]@{
                        Category = 'FI-TS Konfiguration'
                        Check    = 'TempDB Datendateien'
                        Status   = $r.Status
                        Current  = "$($r.CurrentFileCount) Dateien"
                        Expected = "$($r.RecommendedCount) ($($r.LogicalCores) Kerne, max 8)"
                        Message  = $r.Message
                    })
                }
                catch
                {
                    $checkResults.Add([PSCustomObject]@{
                        Category = 'FI-TS Konfiguration'
                        Check    = 'TempDB Datendateien'
                        Status   = 'Error'
                        Current  = '-'
                        Expected = '-'
                        Message  = $_.Exception.Message
                    })
                }

                # 2c. NTFS-Blockgroesse aller SQL-Laufwerke
                try
                {
                    $diskResults = Get-sqmDiskBlockSize -SqlInstance $SqlInstance -ErrorAction Stop
                    foreach ($dr in @($diskResults))
                    {
                        $checkResults.Add([PSCustomObject]@{
                            Category = 'FI-TS Konfiguration'
                            Check    = "NTFS-Blockgroesse $($dr.Drive):\"
                            Status   = $dr.Status
                            Current  = if ($dr.BlockSizeKB) { "$($dr.BlockSizeKB) KB" } else { 'n/a' }
                            Expected = "$([Math]::Round($dr.RecommendedBlockSize/1024)) KB"
                            Message  = $dr.Message
                        })
                    }
                }
                catch
                {
                    $checkResults.Add([PSCustomObject]@{
                        Category = 'FI-TS Konfiguration'
                        Check    = 'NTFS-Blockgroesse'
                        Status   = 'Error'
                        Current  = '-'
                        Expected = '64 KB'
                        Message  = $_.Exception.Message
                    })
                }
            }

            # ------------------------------------------------------------------
            # 3. Zusammenfassung
            # ------------------------------------------------------------------
            $countOk   = ($checkResults | Where-Object { $_.Status -eq 'OK' }).Count
            $countWarn = ($checkResults | Where-Object { $_.Status -eq 'Warning' }).Count
            $countErr  = ($checkResults | Where-Object { $_.Status -in @('Error','NotNTFS') }).Count
            $overallStatus = if ($countErr -gt 0) { 'ERROR' } elseif ($countWarn -gt 0) { 'WARNING' } else { 'OK' }

            # ------------------------------------------------------------------
            # 4. HTML-Report generieren
            # ------------------------------------------------------------------
            $html = _Build-SetupReportHtml `
                -SqlInstance  $SqlInstance `
                -Timestamp    $timestamp `
                -CheckProfile $CheckProfile `
                -Results      $checkResults `
                -CountOk      $countOk `
                -CountWarn    $countWarn `
                -CountErr     $countErr `
                -Overall      $overallStatus

            # ------------------------------------------------------------------
            # 5. Report speichern
            # ------------------------------------------------------------------
            if (-not (Test-Path $OutputPath))
            {
                $null = New-Item -ItemType Directory -Path $OutputPath -Force
            }

            $htmlFile = Join-Path $OutputPath "sqmSetupReport_${safeInstance}_${datestamp}.html"
            $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

            # Oeffne HTML-Datei wenn nicht -NoOpen
            if (-not $NoOpen -and $htmlFile)
            {
                Start-Process $htmlFile
            }

            Invoke-sqmLogging -Message "HTML-Report gespeichert: $htmlFile" -FunctionName $functionName -Level 'INFO'
            Write-Host ""
            Write-Host "  Setup-Report: $htmlFile" -ForegroundColor Cyan
            Write-Host "  Ergebnis    : $overallStatus ($countOk OK / $countWarn Warnung(en) / $countErr Fehler)" -ForegroundColor $(
                if ($overallStatus -eq 'OK') { 'Green' } elseif ($overallStatus -eq 'WARNING') { 'Yellow' } else { 'Red' }
            )
            Write-Host ""

            Copy-sqmToCentralPath -Path $htmlFile

            if ($PassThru) { return $htmlFile }
        }
        catch
        {
            $errMsg = "Fehler in $functionName auf ${SqlInstance}: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw }
            Write-Error $errMsg
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level 'INFO'
    }
}

# ==============================================================================
# Hilfsfunktion: HTML aufbauen (privat, kein Export)
# ==============================================================================
function _Build-SetupReportHtml
{
    param(
        [string]$SqlInstance,
        [string]$Timestamp,
        [string]$CheckProfile,
        [System.Collections.Generic.List[PSCustomObject]]$Results,
        [int]$CountOk,
        [int]$CountWarn,
        [int]$CountErr,
        [string]$Overall
    )

    function _HtmlEncode
    {
        param([string]$Text)
        if (-not $Text) { return '' }
        $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
    }

    function _StatusBadge
    {
        param([string]$Status)
        switch ($Status)
        {
            'OK'       { '<span class="badge badge-ok">OK</span>' }
            'Warning'  { '<span class="badge badge-warn">WARN</span>' }
            'NotNTFS'  { '<span class="badge badge-warn">KEIN NTFS</span>' }
            'Error'    { '<span class="badge badge-err">FEHLER</span>' }
            default    { "<span class='badge badge-err'>$(_HtmlEncode $Status)</span>" }
        }
    }

    # Gesamtstatus-Farbe
    $overallColor = switch ($Overall)
    {
        'OK'      { '#27ae60' }
        'WARNING' { '#f39c12' }
        default   { '#e74c3c' }
    }

    # Zeilen nach Kategorie gruppiert
    $categories = $Results | Select-Object -ExpandProperty Category -Unique

    $tableRows = [System.Text.StringBuilder]::new()
    foreach ($cat in $categories)
    {
        $catItems = $Results | Where-Object { $_.Category -eq $cat }
        $first    = $true
        foreach ($item in $catItems)
        {
            $rowClass = switch ($item.Status)
            {
                'OK'      { 'row-ok' }
                'Warning' { 'row-warn' }
                default   { 'row-err' }
            }

            if ($first)
            {
                $rowCount = ($catItems | Measure-Object).Count
                $catCell  = "<td class='cat-cell' rowspan='$rowCount'>$(_HtmlEncode $cat)</td>"
                $first    = $false
            }
            else { $catCell = '' }

            [void]$tableRows.AppendLine(
                "<tr class='$rowClass'>$catCell<td>$(_HtmlEncode $item.Check)</td>" +
                "<td class='center'>$(_StatusBadge $item.Status)</td>" +
                "<td>$(_HtmlEncode $item.Current)</td>" +
                "<td>$(_HtmlEncode $item.Expected)</td>" +
                "<td class='msg'>$(_HtmlEncode $item.Message)</td></tr>"
            )
        }
    }

    $profileLabel = switch ($CheckProfile)
    {
        'FiTs'    { 'FI-TS' }
        'Generic' { 'Generisch' }
        default   { "Auto ($CheckProfile)" }
    }

    return @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SQL Server Setup Report - $(_HtmlEncode $SqlInstance)</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #060f20; color: #e2e8f0; font-size: 13px; }

  /* Header */
  .header { background: linear-gradient(160deg, #060f20 0%, #0b1e3d 100%);
            border-bottom: 2px solid #2e86c1; padding: 28px 32px 20px; }
  .header h1 { font-size: 22px; font-weight: 600; color: #e2e8f0; }
  .header h1 em { color: #5dade2; font-style: normal; }
  .header .meta { margin-top: 8px; color: #94a8c0; font-size: 12px; }
  .header .meta span { margin-right: 24px; }

  /* Summary Cards */
  .summary { display: flex; gap: 16px; padding: 20px 32px; background: #0a1628; }
  .summary-card { flex: 1; border-radius: 6px; padding: 14px 18px; text-align: center; }
  .summary-card .num { font-size: 28px; font-weight: 700; }
  .summary-card .lbl { font-size: 11px; color: #94a8c0; margin-top: 2px; }
  .card-overall { background: $overallColor; }
  .card-ok   { background: #1a3a2a; border: 1px solid #27ae60; }
  .card-ok   .num { color: #2ecc71; }
  .card-warn { background: #3a2a10; border: 1px solid #f39c12; }
  .card-warn .num { color: #f39c12; }
  .card-err  { background: #3a1010; border: 1px solid #e74c3c; }
  .card-err  .num { color: #e74c3c; }

  /* Table */
  .content { padding: 0 32px 32px; }
  table { width: 100%; border-collapse: collapse; margin-top: 16px;
          background: #0d1f38; border-radius: 6px; overflow: hidden; }
  th { background: #0b1e3d; color: #94a8c0; font-weight: 600; font-size: 11px;
       text-transform: uppercase; letter-spacing: 0.05em;
       padding: 10px 12px; text-align: left; border-bottom: 1px solid #1e3a5f; }
  td { padding: 9px 12px; border-bottom: 1px solid #0f2540; vertical-align: middle; }
  td.cat-cell { color: #5dade2; font-weight: 600; font-size: 11px;
                text-transform: uppercase; letter-spacing: 0.04em;
                border-right: 2px solid #1e3a5f; background: #0b1e3d; }
  td.center { text-align: center; }
  td.msg { color: #94a8c0; font-size: 12px; }
  tr:last-child td { border-bottom: none; }
  tr.row-ok   { }
  tr.row-warn { background: rgba(243,156,18,0.06); }
  tr.row-err  { background: rgba(231, 76, 60, 0.08); }

  /* Badges */
  .badge { display: inline-block; padding: 2px 9px; border-radius: 10px;
           font-size: 10px; font-weight: 700; letter-spacing: 0.05em; }
  .badge-ok   { background: #1a3a2a; color: #2ecc71; border: 1px solid #27ae60; }
  .badge-warn { background: #3a2a10; color: #f39c12; border: 1px solid #f39c12; }
  .badge-err  { background: #3a1010; color: #e74c3c; border: 1px solid #e74c3c; }

  /* Footer */
  .footer { padding: 16px 32px; border-top: 1px solid #1e3a5f;
            color: #4a6080; font-size: 11px; }
</style>
</head>
<body>

<div class="header">
  <h1>SQL Server Setup Report - <em>$(_HtmlEncode $SqlInstance)</em></h1>
  <div class="meta">
    <span>Erstellt: $(_HtmlEncode $Timestamp)</span>
    <span>Profil: $(_HtmlEncode $profileLabel)</span>
    <span>Checks: $(($Results | Measure-Object).Count)</span>
  </div>
</div>

<div class="summary">
  <div class="summary-card card-overall">
    <div class="num">$(_HtmlEncode $Overall)</div>
    <div class="lbl">Gesamtstatus</div>
  </div>
  <div class="summary-card card-ok">
    <div class="num">$CountOk</div>
    <div class="lbl">OK</div>
  </div>
  <div class="summary-card card-warn">
    <div class="num">$CountWarn</div>
    <div class="lbl">Warnungen</div>
  </div>
  <div class="summary-card card-err">
    <div class="num">$CountErr</div>
    <div class="lbl">Fehler</div>
  </div>
</div>

<div class="content">
  <table>
    <thead>
      <tr>
        <th style="width:160px">Kategorie</th>
        <th>Check</th>
        <th style="width:90px;text-align:center">Status</th>
        <th style="width:160px">Aktuell</th>
        <th style="width:180px">Empfohlen</th>
        <th>Meldung</th>
      </tr>
    </thead>
    <tbody>
$($tableRows.ToString())    </tbody>
  </table>
</div>

<div class="footer">
  sqmSQLTool - dtcSoftware / Uwe Janke &nbsp;|&nbsp; www.powershelldba.de
</div>

</body>
</html>
"@
}
