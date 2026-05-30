<#
.SYNOPSIS
Generiert die sqmSQLTool-reference.html automatisch aus allen .ps1 Dateien im Public-Verzeichnis.

.DESCRIPTION
Liest alle .ps1 Dateien aus dem Public-Verzeichnis, extrahiert:
- Funktionsnamen
- Beschreibungen (SYNOPSIS oder erste Zeile nach 'function')
- Parameter
- Kategorien (aus Dateiname oder Funktion-Prefix)
- Code-Beispiele

Generiert eine HTML-Referenzdatei mit der gleichen Struktur wie das Template.

.PARAMETER PublicDir
Pfad zum Public-Verzeichnis mit den Funktionen. Default: .\Public

.PARAMETER TemplateFile
Pfad zur existierenden Template-HTML. Default: .\Docs\sqmSQLTool-reference.html

.PARAMETER OutputFile
Zieldatei für die neue HTML. Default: .\Docs\sqmSQLTool-reference.html

.EXAMPLE
.\Generate-ReferenceHTML.ps1 -PublicDir "C:\CMP\SQL-Tools\sqmSQLTool\Public" -OutputFile "C:\CMP\SQL-Tools\sqmSQLTool\Docs\sqmSQLTool-reference.html"

#>

param(
    [string]$PublicDir = ".\Public",
    [string]$TemplateFile = ".\Docs\sqmSQLTool-reference.html",
    [string]$OutputFile = ".\Docs\sqmSQLTool-reference.html"
)

# ============================================================================
# Kategorien und Icon-Mapping
# ============================================================================
$categoryMap = @{
    'AlwaysOn'        = @{ emoji = '🔄'; badge = 'psdb-st-badge-alwayson'; prefix = @('Add.*AG', 'Remove.*AG', 'Sync.*Ag', 'Invoke.*Failover', 'Repair.*AlwaysOn', 'New.*AlwaysOnRepair', 'Invoke.*Autoseed', 'Get.*AgHealth') }
    'Backup'          = @{ emoji = '💾'; badge = 'psdb-st-badge-backup'; prefix = @('Backup', 'Invoke.*Backup', 'Test.*Backup', 'Sync.*Exclude', 'Set.*Exclude') }
    'Restore'         = @{ emoji = '♻️'; badge = 'psdb-st-badge-restore'; prefix = @('Invoke.*Restore', 'Restore') }
    'Sicherheit'      = @{ emoji = '🔒'; badge = 'psdb-st-badge-sicherheit'; prefix = @('Obfuscation', 'Sysadmin', 'LoginAudit', 'CopyLogins', 'ADStatus', 'DatabaseOwner') }
    'Diagnose'        = @{ emoji = '🩺'; badge = 'psdb-st-badge-diagnose'; prefix = @('Health', 'InstanceCheck', 'TempDb', 'DiskSpace', 'DiskBlock', 'DiskInfo', 'CostThreshold', 'SetupReport', 'AgentProxy', 'NTFSPerm', 'OperationStatus', 'SpnReport', 'ConnStats', 'OrphanedFiles', 'PatchAnalysis') }
    'Performance'     = @{ emoji = '⚡'; badge = 'psdb-st-badge-performance'; prefix = @('IndexFrag', 'MissingIdx', 'Blocking', 'Deadlock', 'LongRunning', 'UpdateStats', 'AutoGrowth', 'QueryStore', 'XEvents', 'WaitStats', 'PerfCounters', 'PerfBaseline') }
    'Wartung'         = @{ emoji = '🔧'; badge = 'psdb-st-badge-wartung'; prefix = @('OlaInstall', 'OlaJobs', 'OlaSysDb', 'OlaUsrDb', 'FormatDrive', 'SQLFirewall', 'OlaTest', 'LogShrink') }
    'Konfiguration'   = @{ emoji = '⚙️'; badge = 'psdb-st-badge-konfiguration'; prefix = @('GetConfig', 'SetConfig', 'ServerSetting', 'Compare.*Config', 'Collation', 'RecoveryMode') }
    'Inventar'        = @{ emoji = '📋'; badge = 'psdb-st-badge-inventar'; prefix = @('Inventory', 'ExportDoc', 'FindObject', 'LinkedUsage', 'AgentHistory') }
    'Cluster'         = @{ emoji = '🖥️'; badge = 'psdb-st-badge-monitoring'; prefix = @('ClusterInfo', 'SsrsInstall', 'SsrsConfig', 'SsisConfig', 'SsasDirectory') }
    'TLS'             = @{ emoji = '🔐'; badge = 'psdb-st-badge-monitoring'; prefix = @('CertReport', 'InstallCert', 'CertRequest', 'SqlCertificate', 'TlsStatus', 'SqlTlsCert', 'CertificateStore', 'SsrsHttps') }
    'TSM'             = @{ emoji = '📼'; badge = 'psdb-st-badge-tsm'; prefix = @('Tsm') }
    'Splunk'          = @{ emoji = '📊'; badge = 'psdb-st-badge-monitoring'; prefix = @('Splunk') }
    'Deployment'      = @{ emoji = '🚀'; badge = 'psdb-st-badge-deployment'; prefix = @('Deploy.*Scripts', 'Sign.*Module') }
    'Sonstige'        = @{ emoji = '🔹'; badge = 'psdb-st-badge-sonstige'; prefix = @('PolicyState', 'MonitoringKey', 'CentralPath', 'AdModule', 'Hpu') }
}

# ============================================================================
# Hilfsfunktionen
# ============================================================================

function Get-AllFunctionsFromFile {
    param([string]$FilePath)

    try {
        $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        $functions = @()

        # Finde ALLE function-Definitionen in der Datei
        $functionMatches = [regex]::Matches($content, 'function\s+([\w-]+)\s*\{?(?:.*?)(?=function\s+[\w-]+|$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)

        if ($functionMatches.Count -eq 0) {
            # Fallback: Nutze Dateiname wenn kein function-Keyword
            $fileName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $FilePath -Leaf))
            $functions += Get-FunctionInfoFromContent -Content $content -FunctionName $fileName -FilePath $FilePath
        } else {
            # Extrahiere alle gefundenen Funktionen
            foreach ($match in $functionMatches) {
                $funcName = $match.Groups[1].Value
                if ($funcName) {
                    $functions += Get-FunctionInfoFromContent -Content $content -FunctionName $funcName -FilePath $FilePath
                }
            }
        }

        return $functions
    }
    catch {
        Write-Warning "Fehler bei $FilePath`: $_"
        return @()
    }
}

function Get-FunctionInfoFromContent {
    param(
        [string]$Content,
        [string]$FunctionName,
        [string]$FilePath
    )

    # Finde die spezifische Funktion im Content
    $funcPattern = "function\s+$([regex]::Escape($FunctionName))\s*\{(.*?)(?=function\s+|\`$)"
    $funcMatch = [regex]::Match($Content, $funcPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $funcBlock = if ($funcMatch.Success) { $funcMatch.Groups[1].Value } else { $Content }

    # Extrahiere SYNOPSIS
    $synopsisMatch = [regex]::Match($funcBlock, '\.SYNOPSIS\s*\n\s*(.+?)(?=\s*\.|\s*#>|$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $synopsis = if ($synopsisMatch.Success) {
        $synopsisMatch.Groups[1].Value.Trim() -replace '\s+', ' '
    } else {
        'Keine Beschreibung verfügbar'
    }

    # Extrahiere Parameter
    $paramMatch = [regex]::Match($funcBlock, '\bparam\s*\(\s*(.+?)\s*\)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $parameters = @()
    if ($paramMatch.Success) {
        $paramBlock = $paramMatch.Groups[1].Value
        $paramLines = $paramBlock -split "`n" | Where-Object { $_ -match '^\s*\[' }
        foreach ($line in $paramLines) {
            if ($line -match '\$(\w+)') {
                $parameters += $Matches[1]
            }
        }
    }

    # Extrahiere Beispiele (erste 2)
    $examplesPattern = '\.EXAMPLE\s*\n\s*(.+?)(?=\s*\.EXAMPLE|\s*#>|$)'
    $exampleMatches = [regex]::Matches($funcBlock, $examplesPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $examples = @()
    foreach ($match in $exampleMatches | Select-Object -First 2) {
        $example = $match.Groups[1].Value.Trim()
        if ($example -and $example.Length -gt 5) {
            $examples += $example
        }
    }

    if ($examples.Count -eq 0) {
        $examples += "$FunctionName"
    }

    return @{
        Name       = $FunctionName
        Synopsis   = $synopsis
        Parameters = $parameters
        Examples   = $examples
        FilePath   = $FilePath
    }
}

function Get-CategoryForFunction {
    param([string]$FunctionName)

    foreach ($cat in $categoryMap.Keys) {
        $prefixes = $categoryMap[$cat].prefix
        foreach ($prefix in $prefixes) {
            if ($FunctionName -match $prefix) {
                return $cat
            }
        }
    }
    return 'Sonstige'
}

function Escape-Html {
    param([string]$Text)
    return $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
}

function New-FunctionCard {
    param(
        [object]$FuncInfo,
        [string]$Category
    )

    $categoryInfo = $categoryMap[$Category]
    $badgeClass = $categoryInfo.badge

    # Sichere HTML-Sonderzeichen
    $name = Escape-Html $FuncInfo.Name
    $synopsis = Escape-Html $FuncInfo.Synopsis

    # Generiere ID aus Funktionsnamen
    $id = 'f-' + ($name -replace '[^a-zA-Z0-9]', '').ToLower()

    $html = @"
<div class="psdb-st-func-card" id="$id">
<div class="psdb-st-func-header">
<span class="psdb-st-func-name">$name</span>
<span class="psdb-st-badge $badgeClass">$(Escape-Html $Category)</span>
</div>
<div class="psdb-st-func-desc">$synopsis</div>
"@

    # Beispiele hinzufügen
    if ($FuncInfo.Examples.Count -gt 0) {
        $exampleCount = $FuncInfo.Examples.Count
        $html += "`n<div class=`"psdb-st-examples-toggle`" onclick=`"psstToggleEx(this)`">&#9658; $exampleCount Beispiele anzeigen</div>"
        $html += "`n<div class=`"psdb-st-examples`">"

        foreach ($example in $FuncInfo.Examples) {
            $escapedExample = Escape-Html $example
            $html += @"

<div class="psdb-st-example">
<div class="psdb-st-example-label">Beispiel</div>
<div class="psdb-st-pre-wrap"><pre class="psdb-st-code">$escapedExample</pre><button class="psdb-st-copy-btn" onclick="psstCopy(this)">copy</button></div>
</div>
"@
        }

        $html += "`n</div>"
    }

    $html += "`n</div>"
    return $html
}

function New-SidebarNavigation {
    param([hashtable]$Functions)

    $html = '<input class="psdb-st-sidebar-search" type="text" placeholder="Funktion suchen..." oninput="psstSearch(this.value)">' + "`n"

    foreach ($category in $categoryMap.Keys | Sort-Object) {
        $funcsInCat = $Functions.Values | Where-Object { $_.Category -eq $category } | Sort-Object Name

        if ($funcsInCat.Count -eq 0) {
            continue
        }

        $categoryInfo = $categoryMap[$category]
        $navId = "nav-" + ($category -replace '\s+', '').ToLower()
        $emoji = $categoryInfo.emoji
        $count = $funcsInCat.Count

        $html += @"
<div class="psdb-st-nav-group" id="$navId">
<div class="psdb-st-nav-cat" onclick="dtcToggleCat('$navId-list')">
<span>$emoji $category</span><span class="psdb-st-nav-count">$count</span>
</div>
<ul class="psdb-st-nav-funcs" id="$navId-list">
"@

        foreach ($func in $funcsInCat) {
            $funcId = 'f-' + ($func.Name -replace '[^a-zA-Z0-9]', '').ToLower()
            $funcName = Escape-Html $func.Name
            $html += "`n<li><span class=`"psdb-st-nav-func`" onclick=`"psstJump('$funcId')`">$funcName</span></li>"
        }

        $html += "`n</ul>`n</div>`n"
    }

    return $html
}

function New-ContentSections {
    param([hashtable]$Functions)

    $html = ''

    foreach ($category in $categoryMap.Keys | Sort-Object) {
        $funcsInCat = $Functions.Values | Where-Object { $_.Category -eq $category } | Sort-Object Name

        if ($funcsInCat.Count -eq 0) {
            continue
        }

        $categoryInfo = $categoryMap[$category]
        $emoji = $categoryInfo.emoji
        $catId = "cat-" + ($category -replace '\s+', '').ToLower()

        $html += @"
<section class="psdb-st-section" id="$catId">
<h2 class="psdb-st-section-title">$emoji $category</h2>
"@

        foreach ($func in $funcsInCat) {
            $html += "`n$(New-FunctionCard -FuncInfo $func -Category $category)"
        }

        $html += "`n</section>`n"
    }

    return $html
}

function New-OverviewTable {
    param([hashtable]$Functions)

    $html = @"
<table class="psdb-st-overview-table">
<thead>
<tr>
<th>Kategorie</th>
<th>Funktion</th>
<th>Beschreibung</th>
</tr>
</thead>
<tbody>
"@

    foreach ($func in $Functions.Values | Sort-Object { $_.Category }, { $_.Name }) {
        $category = Escape-Html $func.Category
        $name = Escape-Html $func.Name
        $synopsis = Escape-Html $func.Synopsis

        # Kürze lange Beschreibungen
        if ($synopsis.Length -gt 100) {
            $synopsis = $synopsis.Substring(0, 97) + '...'
        }

        $catId = "cat-" + ($func.Category -replace '\s+', '').ToLower()

        $html += @"

<tr>
<td class="psdb-st-ov-cat"><a href="#$catId">$category</a></td>
<td class="psdb-st-ov-fn">$name</td>
<td>$synopsis</td>
</tr>
"@
    }

    $html += "`n</tbody>`n</table>"
    return $html
}

# ============================================================================
# HAUPTPROGRAMM
# ============================================================================

Write-Host "sqmSQLTool Reference HTML Generator"
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""

# Verifiziere Eingabeverzeichnisse
if (-not (Test-Path -Path $PublicDir)) {
    Write-Error "PublicDir nicht gefunden: $PublicDir"
    exit 1
}

Write-Host "Lese Funktionen aus: $PublicDir" -ForegroundColor Green

# Lese alle .ps1 Dateien (außer .TempPoint.ps1)
$psFiles = Get-ChildItem -Path $PublicDir -Filter "*.ps1" | Where-Object { $_.Name -notmatch '\.TempPoint\.ps1' }

Write-Host "Gefunden: $($psFiles.Count) Funktionsdateien"

# Extrahiere Funktionsinformationen
$functions = @{}
$processedCount = 0
$totalFuncsFound = 0

foreach ($file in $psFiles) {
    $funcsInFile = Get-AllFunctionsFromFile -FilePath $file.FullName

    foreach ($funcInfo in $funcsInFile) {
        if ($funcInfo.Name) {
            # Filter: Nur öffentliche Funktionen (nicht private/interne mit _ oder # Prefix)
            # und nur die mit erwarteten Präfixen
            if ($funcInfo.Name -match '^(Invoke|Get|Set|New|Remove|Test|Copy|Find|Sync|Install|Export|Compare|Repair|Invoke)-sqm\w+$') {
                $category = Get-CategoryForFunction -FunctionName $funcInfo.Name
                $funcInfo | Add-Member -NotePropertyName 'Category' -NotePropertyValue $category

                # Nur einmal hinzufügen (falls Duplikate)
                if (-not $functions.ContainsKey($funcInfo.Name)) {
                    $functions[$funcInfo.Name] = $funcInfo
                    $totalFuncsFound++
                }
            }
        }
    }

    $processedCount++
    Write-Progress -Activity "Verarbeite Funktionsdateien" -Status $file.Name -PercentComplete (($processedCount / $psFiles.Count) * 100)
}

Write-Host "Verarbeitete Funktionen: $($functions.Count)" -ForegroundColor Green
Write-Host ""

# Generiere HTML-Teile
Write-Host "Generiere Sidebar-Navigation..." -ForegroundColor Cyan
$sidebarNav = New-SidebarNavigation -Functions $functions

Write-Host "Generiere Content-Sections..." -ForegroundColor Cyan
$contentSections = New-ContentSections -Functions $functions

Write-Host "Generiere Overview-Tabelle..." -ForegroundColor Cyan
$overviewTable = New-OverviewTable -Functions $functions

# Zusammenstellen der vollständigen HTML
$totalFunctions = $functions.Count

$html = @"
<div class="psdb-st">
<style>
.psdb-st { font-family: 'Segoe UI',system-ui,sans-serif; background: #060f20; color: #e2e8f0; }
	.psdb-st {
	--psdb-st-blue: #5dade2;
	--psdb-st-blue2: #5dade2;
	--psdb-st-accent: #2e86c1;
	--psdb-st-bg: #060f20;
	--psdb-st-surface: rgba(255,255,255,0.04);
	--psdb-st-border: rgba(46,134,193,0.25);
	--psdb-st-text: #e2e8f0;
	--psdb-st-muted: #94a8c0;
	--psdb-st-code-bg: #012456;
	--psdb-st-code-text: #e8e8e8;
	--psdb-st-r: 6px;
	--psdb-st-shadow: 0 1px 4px rgba(0,0,0,.08);
	--psdb-st-sans: 'Segoe UI', system-ui, sans-serif;
	--psdb-st-mono: 'Consolas', 'Courier New', monospace;
	}

	* { box-sizing: border-box; margin: 0; padding: 0; }

	/* -- HEADER -- */
	.psdb-st-header { background: var(--psdb-st-blue); color: #fff; padding: 24px 32px 20px; border-radius: var(--psdb-st-r) var(--psdb-st-r) 0 0; }
	.psdb-st-header h1 { font-size: 1.8rem; font-weight: 900; margin: 0 0 4px; letter-spacing: -.5px; }
	.psdb-st-header p { font-size: .88rem; opacity: .8; margin: 0; }
	.psdb-st-header-meta { display: flex; gap: 10px; margin-top: 14px; flex-wrap: wrap; }
	.psdb-st-pill { background: rgba(255,255,255,.15); border-radius: 20px; padding: 3px 12px; font-size: .78rem; }

	/* -- TABS -- */
	.psdb-st-tabs { display: flex; background: var(--psdb-st-blue); padding: 0 32px; gap: 2px; border-bottom: 3px solid var(--psdb-st-accent); overflow-x: auto; }
	.psdb-st-tab { padding: 9px 18px; font-size: .83rem; font-weight: 600; color: rgba(255,255,255,.6); cursor: pointer; border-bottom: 3px solid transparent; margin-bottom: -3px; transition: .15s; user-select: none; white-space: nowrap; }
	.psdb-st-tab:hover { color: #fff; }
	.psdb-st-tab.psdb-st-active { color: #fff; border-bottom-color: var(--psdb-st-accent); }
	.psdb-st-panel { display: none; }
	.psdb-st-panel.psdb-st-active { display: block; }

	/* -- LAYOUT -- */
	.psdb-st-wrap { display: flex; min-height: 600px; }
	.psdb-st-sidebar { width: 240px; min-width: 240px; background: var(--psdb-st-surface); border-right: 1px solid var(--psdb-st-border); padding: 12px 0; font-size: .8rem; height: calc(100vh - 140px); overflow-y: auto; position: sticky; top: 0; }
	.psdb-st-sidebar-search { margin: 0 10px 10px; padding: 5px 9px; border: 1px solid var(--psdb-st-border); border-radius: var(--psdb-st-r); font-size: .79rem; width: calc(100% - 20px); font-family: var(--psdb-st-sans); background: #0b1e3d; color: #e2e8f0; }
	.psdb-st-sidebar-search:focus { outline: none; border-color: var(--psdb-st-accent); }
	.psdb-st-nav-group { border-bottom: 1px solid var(--psdb-st-border); }
	.psdb-st-nav-cat { display: flex; justify-content: space-between; align-items: center; padding: 7px 12px; font-weight: 700; font-size: .79rem; color: var(--psdb-st-blue); cursor: pointer; background: rgba(255,255,255,0.04); user-select: none; }
	.psdb-st-nav-cat:hover { background: rgba(255,255,255,0.06); }
	.psdb-st-nav-count { background: var(--psdb-st-blue2); color: #fff; border-radius: 10px; padding: 1px 6px; font-size: .68rem; }
	.psdb-st-nav-funcs { list-style: none; padding: 3px 0; background: var(--psdb-st-surface); }
	.psdb-st-nav-funcs.psdb-st-collapsed { display: none; }
	.psdb-st-nav-func { display: block; padding: 3px 12px 3px 20px; color: #94a8c0; text-decoration: none; font-size: .75rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; cursor: pointer; }
	.psdb-st-nav-func:hover { color: var(--psdb-st-blue2); background: rgba(46,134,193,0.12); }
	.psdb-st-nav-func.psdb-st-active { color: var(--psdb-st-blue2); font-weight: 700; background: rgba(46,134,193,0.12); }

	.psdb-st-content { flex: 1; padding: 20px 24px; height: calc(100vh - 140px); overflow-y: auto; }
	.psdb-st-section { margin-bottom: 28px; }
	.psdb-st-section-title { font-size: 1rem; font-weight: 800; color: var(--psdb-st-blue); border-bottom: 2px solid var(--psdb-st-accent); padding-bottom: 5px; margin: 0 0 14px; }

	/* -- FUNC CARDS -- */
	.psdb-st-func-card { background: var(--psdb-st-surface); border: 1px solid var(--psdb-st-border); border-radius: var(--psdb-st-r); margin-bottom: 10px; box-shadow: var(--psdb-st-shadow); }
	.psdb-st-func-header { display: flex; align-items: center; justify-content: space-between; padding: 9px 14px; border-bottom: 1px solid var(--psdb-st-border); background: rgba(255,255,255,0.04); border-radius: var(--psdb-st-r) var(--psdb-st-r) 0 0; flex-wrap: wrap; gap: 5px; }
	.psdb-st-func-name { font-family: var(--psdb-st-mono); font-size: .85rem; font-weight: 700; color: var(--psdb-st-blue2); }
	.psdb-st-func-desc { padding: 9px 14px; font-size: .82rem; line-height: 1.6; color: #94a8c0; }
	.psdb-st-examples-toggle { padding: 5px 14px 9px; font-size: .78rem; color: var(--psdb-st-blue2); cursor: pointer; user-select: none; font-weight: 600; }
	.psdb-st-examples-toggle:hover { color: var(--psdb-st-accent); }
	.psdb-st-examples { padding: 0 14px 10px; display: none; }
	.psdb-st-example { margin-bottom: 12px; }
	.psdb-st-example-label { font-size: .72rem; font-weight: 700; color: #94a8c0; margin-bottom: 3px; text-transform: uppercase; letter-spacing: .4px; }
	.psdb-st-code { background: var(--psdb-st-code-bg); color: var(--psdb-st-code-text); padding: 10px 12px; border-radius: var(--psdb-st-r); font-family: var(--psdb-st-mono); font-size: .74rem; line-height: 1.55; overflow-x: auto; margin: 0; white-space: pre; display: block; position: relative; }
	.psdb-st-copy-btn { position: absolute; top: 6px; right: 8px; background: rgba(255,255,255,.12); border: none; color: #94a3b8; border-radius: 4px; padding: 2px 7px; font-size: .68rem; cursor: pointer; font-family: var(--psdb-st-sans); }
	.psdb-st-copy-btn:hover { background: rgba(255,255,255,.22); color: #fff; }
	.psdb-st-pre-wrap { position: relative; }

	/* -- BADGES -- */
	.psdb-st-badge { font-size: .68rem; font-weight: 700; padding: 2px 8px; border-radius: 10px; white-space: nowrap; text-transform: uppercase; letter-spacing: .3px; }
	.psdb-st-badge-alwayson { background: rgba(29,78,216,0.2); color: #93c5fd; }
	.psdb-st-badge-restore { background: rgba(157,23,77,0.2); color: #f9a8d4; }
	.psdb-st-badge-sicherheit { background: rgba(146,64,14,0.2); color: #fde68a; }
	.psdb-st-badge-diagnose { background: rgba(22,101,52,0.2); color: #86efac; }
	.psdb-st-badge-performance { background: rgba(107,33,168,0.2); color: #d8b4fe; }
	.psdb-st-badge-kapazitaet { background: rgba(154,52,18,0.2); color: #fdba74; }
	.psdb-st-badge-monitoring { background: rgba(12,74,110,0.2); color: #7dd3fc; }
	.psdb-st-badge-backup { background: rgba(6,78,59,0.2); color: #6ee7b7; }
	.psdb-st-badge-wartung { background: rgba(112,26,117,0.2); color: #e879f9; }
	.psdb-st-badge-konfiguration { background: rgba(6,95,70,0.2); color: #6ee7b7; }
	.psdb-st-badge-inventar { background: rgba(255,255,255,0.08); color: #cbd5e1; }
	.psdb-st-badge-sonstige { background: rgba(71,85,105,0.3); color: #94a3b8; }
	.psdb-st-badge-tsm { background: rgba(159,18,57,0.2); color: #fca5a5; }

	/* -- OVERVIEW TABLE -- */
	.psdb-st-overview-table { width: 100%; border-collapse: collapse; font-size: .8rem; }
	.psdb-st-overview-table th { background: #2e86c1; color: #fff; padding: 7px 11px; text-align: left; font-size: .75rem; text-transform: uppercase; letter-spacing: .4px; }
	.psdb-st-overview-table td { padding: 6px 11px; border-bottom: 1px solid rgba(46,134,193,0.25); background: #060f20; color: #e2e8f0; vertical-align: top; }
	.psdb-st-overview-table tr:hover td { background: rgba(255,255,255,0.04); }
	.psdb-st-ov-cat a { color: #5dade2; font-weight: 700; text-decoration: none; }
	.psdb-st-ov-fn { font-family: Consolas,'Courier New',monospace; font-size: .76rem; color: #e2e8f0; }

	/* -- QUICK START -- */
	.psdb-st-qs-step { display: flex; gap: 12px; margin-bottom: 14px; align-items: flex-start; }
	.psdb-st-qs-num { background: var(--psdb-st-blue2); color: #fff; border-radius: 50%; width: 24px; height: 24px; display: flex; align-items: center; justify-content: center; font-size: .75rem; font-weight: 700; flex-shrink: 0; margin-top: 2px; }
	.psdb-st-qs-body { flex: 1; }
	.psdb-st-qs-title { font-weight: 700; font-size: .85rem; margin-bottom: 4px; color: var(--psdb-st-blue); }

	/* -- INFO BOXES -- */
	.psdb-st-info { background: rgba(46,134,193,0.12); border-left: 3px solid #2e86c1; color: #e2e8f0; padding: 9px 12px; border-radius: 0 6px 6px 0; font-size: .81rem; margin-bottom: 12px; line-height: 1.55; }
	.psdb-st-warn { background: rgba(240,192,64,0.08); border-left: 3px solid #f59e0b; color: #e2e8f0; padding: 9px 12px; border-radius: 0 6px 6px 0; font-size: .81rem; margin-bottom: 12px; line-height: 1.55; }

	/* -- CONFIG TABLE -- */
	.psdb-st-config-table { width: 100%; border-collapse: collapse; font-size: .8rem; margin-bottom: 12px; }
	.psdb-st-config-table th { background: #2e86c1; color: #fff; padding: 6px 10px; text-align: left; font-size: .74rem; }
	.psdb-st-config-table td { padding: 5px 10px; border-bottom: 1px solid rgba(46,134,193,0.25); background: #0a1929; color: #e2e8f0; vertical-align: top; }
	.psdb-st-config-table code { font-family: var(--psdb-st-mono); font-size: .76rem; background: rgba(255,255,255,0.12); color: #e8e8e8; padding: 1px 4px; border-radius: 3px; }

	/* scrollbar */
	.psdb-st-sidebar::-webkit-scrollbar, .psdb-st-content::-webkit-scrollbar { width: 5px; }
	.psdb-st-sidebar::-webkit-scrollbar-thumb, .psdb-st-content::-webkit-scrollbar-thumb { background: #cbd5e1; border-radius: 3px; }

	@media (max-width: 700px) {
	.psdb-st-sidebar { display: none; }
	.psdb-st-header { padding: 16px; }
	.psdb-st-tabs { padding: 0 8px; }
	.psdb-st-content { padding: 12px; height: auto; }
	}
	.psdb-st-badge-deployment { background: rgba(46,134,193,0.2); color: #5dade2; }
</style>

<div class="psdb-st-header">
<h1>🛢 sqmSQLTool</h1>
<p>PowerShell SQL Admin Toolset · dtcSoftware · Janke</p>
<div class="psdb-st-header-meta">
<span class="psdb-st-pill">v 1.0.0</span>
<span class="psdb-st-pill">PowerShell 5.1+</span>
<span class="psdb-st-pill">dbatools required</span>
<span class="psdb-st-pill">$totalFunctions Funktionen</span>
<span class="psdb-st-pill">MS SQL Server</span>
</div>
</div>

<div class="psdb-st-tabs">
<div class="psdb-st-tab psdb-st-active" onclick="psstTab(this,'tab-ref')">📖 Referenz</div>
<div class="psdb-st-tab" onclick="psstTab(this,'tab-quick')">🚀 Quick Start</div>
<div class="psdb-st-tab" onclick="psstTab(this,'tab-config')">⚙️ Konfiguration</div>
<div class="psdb-st-tab" onclick="psstTab(this,'tab-install')">&#128230; Installation</div>
<div class="psdb-st-tab" onclick="psstTab(this,'tab-overview')">&#128202; Übersicht</div>
</div>

<div id="tab-ref" class="psdb-st-panel psdb-st-active">
<div class="psdb-st-wrap">

<!-- SIDEBAR -->
<div class="psdb-st-sidebar">
$sidebarNav
</div><!-- /sidebar -->

<!-- CONTENT -->
<div class="psdb-st-content" id="psdb-st-content">
$contentSections
</div><!-- /content -->

</div><!-- /wrap -->
</div><!-- /tab-ref -->

<div id="tab-overview" class="psdb-st-panel">
<div class="psdb-st-content">
<h2 class="psdb-st-section-title">Alle Funktionen - Übersicht</h2>
$overviewTable
</div>
</div>

<div id="tab-quick" class="psdb-st-panel">
<div class="psdb-st-content">
<h2 class="psdb-st-section-title">Quick Start</h2>
<div class="psdb-st-info">sqmSQLTool ist ein modulares PowerShell-Toolset für die SQL Server Administration mit über $totalFunctions Funktionen zur Verwaltung von AlwaysOn, Backup/Restore, Performance, Sicherheit und mehr.</div>
</div>
</div>

<div id="tab-config" class="psdb-st-panel">
<div class="psdb-st-content">
<h2 class="psdb-st-section-title">Konfiguration</h2>
<p style="color: #94a8c0;">Konfigurationsdetails folgen...</p>
</div>
</div>

<div id="tab-install" class="psdb-st-panel">
<div class="psdb-st-content">
<h2 class="psdb-st-section-title">Installation</h2>
<p style="color: #94a8c0;">Installationsanweisungen folgen...</p>
</div>
</div>

</div><!-- /psdb-st -->

<script>
function psstTab(el, tabId) {
	document.querySelectorAll('.psdb-st-tab').forEach(t => t.classList.remove('psdb-st-active'));
	document.querySelectorAll('.psdb-st-panel').forEach(p => p.classList.remove('psdb-st-active'));
	el.classList.add('psdb-st-active');
	document.getElementById(tabId).classList.add('psdb-st-active');
}

function dtcToggleCat(listId) {
	const list = document.getElementById(listId);
	list.classList.toggle('psdb-st-collapsed');
}

function psstJump(funcId) {
	const el = document.getElementById(funcId);
	if (el) {
		el.scrollIntoView({ behavior: 'smooth' });
		el.style.backgroundColor = 'rgba(93, 173, 226, 0.2)';
		setTimeout(() => el.style.backgroundColor = '', 1500);
	}
}

function psstSearch(query) {
	const q = query.toLowerCase();
	document.querySelectorAll('.psdb-st-nav-func').forEach(el => {
		const text = el.textContent.toLowerCase();
		el.style.display = text.includes(q) ? 'block' : 'none';
	});
}

function psstToggleEx(el) {
	const examples = el.nextElementSibling;
	if (examples && examples.classList.contains('psdb-st-examples')) {
		examples.style.display = examples.style.display === 'none' ? 'block' : 'none';
	}
}

function psstCopy(btn) {
	const code = btn.previousElementSibling?.textContent;
	if (code) {
		navigator.clipboard.writeText(code).then(() => {
			btn.textContent = '✓ copied';
			setTimeout(() => btn.textContent = 'copy', 2000);
		});
	}
}
</script>
</div>
"@

# Schreibe die HTML-Datei
Write-Host ""
Write-Host "Schreibe HTML zu: $OutputFile" -ForegroundColor Green

if (Test-Path -Path $OutputFile) {
    $backup = "$OutputFile.bak"
    Copy-Item -Path $OutputFile -Destination $backup -Force
    Write-Host "Backup erstellt: $backup" -ForegroundColor Yellow
}

$html | Out-File -FilePath $OutputFile -Encoding UTF8 -Force

Write-Host "Fertig!" -ForegroundColor Green
Write-Host ""
Write-Host "Zusammenfassung:" -ForegroundColor Cyan
Write-Host "  Gesamt Funktionen: $totalFunctions"
foreach ($cat in $categoryMap.Keys | Sort-Object) {
    $count = ($functions.Values | Where-Object { $_.Category -eq $cat } | Measure-Object).Count
    if ($count -gt 0) {
        Write-Host "  $cat`: $count"
    }
}
Write-Host ""
Write-Host "Datei: $OutputFile" -ForegroundColor Green

# Überprüfe die generierte HTML
Write-Host ""
Write-Host "Verifikation:" -ForegroundColor Cyan
if (Test-Path $OutputFile) {
    $htmlContent = Get-Content $OutputFile -Raw
    $funcCardsCount = [regex]::Matches($htmlContent, 'psdb-st-func-card').Count
    $tableRowsCount = [regex]::Matches($htmlContent, 'class="psdb-st-ov-fn"').Count
    Write-Host "  Funktions-Cards in HTML: $funcCardsCount"
    Write-Host "  Funktions-Zeilen in Tabelle: $tableRowsCount"
    Write-Host "  Dateigröße: $((Get-Item $OutputFile).Length / 1KB)KB"
} else {
    Write-Host "  FEHLER: Output-Datei nicht gefunden!" -ForegroundColor Red
}
