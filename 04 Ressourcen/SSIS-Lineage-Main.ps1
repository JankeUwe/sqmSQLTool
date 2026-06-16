<#
.SYNOPSIS
    SSIS Lineage Analysis - Main Entry Point for Users

.DESCRIPTION
    Simple, user-friendly entry point to analyze any SSIS project.
    Combines all modules into a single unified workflow:
    1. Parse SSIS project
    2. Detect circular dependencies
    3. Generate analysis report
    4. Save results

.PARAMETER ProjectPath
    Path to SSIS .ispac file or directory containing .dtsx packages

.PARAMETER OutputPath
    Directory where analysis reports will be saved
    Default: C:\System\WinSrvLog\SSIS

.PARAMETER OpenReport
    Open generated report in default browser
    Default: $true

.EXAMPLE
    # Analyze a single ISPAC file
    Invoke-SsisLineageAnalysis -ProjectPath "C:\MyProject\MyProject.ispac"

.EXAMPLE
    # Analyze a folder with loose DTSX files
    Invoke-SsisLineageAnalysis -ProjectPath "C:\My SSIS Packages" -OutputPath "D:\Reports"

.EXAMPLE
    # Analyze without opening report
    Invoke-SsisLineageAnalysis -ProjectPath "C:\Project.ispac" -OpenReport:$false

.NOTES
    Requires: All SSIS-Lineage-*.ps1 modules loaded
    Output: Analysis report + CSV summary
    Author: sqmSQLTool
#>

function Invoke-SsisLineageAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProjectPath,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = "C:\System\WinSrvLog\SSIS",

        [Parameter(Mandatory=$false)]
        [switch]$OpenReport = $true
    )

    # Validate input
    if (-not (Test-Path $ProjectPath)) {
        throw "Project path not found: $ProjectPath"
    }

    # Create output directory
    if (-not (Test-Path $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
        Write-Host "Created output directory: $OutputPath" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  SSIS LINEAGE ANALYSIS - MAIN WORKFLOW                       ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # STEP 1: Parse Project
    Write-Host "STEP 1: Parsing SSIS Project..." -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor Gray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $graph = Parse-SsisProjectEnhanced -ProjectPath $ProjectPath
        $sw.Stop()

        $stats = $graph.GetStatistics()
        Write-Host "✓ Parse Complete in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
        Write-Host "  Packages: $($stats.TotalPackages)" -ForegroundColor Cyan
        Write-Host "  Tasks: $($stats.TotalTasks)" -ForegroundColor Cyan
        Write-Host "  Components: $($stats.TotalComponents)" -ForegroundColor Cyan
        Write-Host "  Columns: $($stats.TotalColumns)" -ForegroundColor Cyan
        Write-Host ""
    }
    catch {
        Write-Host "✗ Parse Failed: $_" -ForegroundColor Red
        throw
    }

    # STEP 2: Detect Circular Dependencies
    Write-Host "STEP 2: Detecting Circular Dependencies..." -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor Gray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $riskReport = Get-CyclicRiskReport -Graph $graph
        $sw.Stop()

        Write-Host "✓ Analysis Complete in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
        Write-Host "  Cycles Found: $($riskReport.CycleCount)" -ForegroundColor Cyan
        Write-Host "  Risk Level: $($riskReport.RiskLevel)" -ForegroundColor Cyan

        if ($riskReport.HasCycles) {
            Write-Host "  ⚠️  WARNING: Circular dependencies detected!" -ForegroundColor Yellow
        } else {
            Write-Host "  ✓ No circular dependencies" -ForegroundColor Green
        }
        Write-Host ""
    }
    catch {
        Write-Host "⚠️  Cycle Detection Error: $_" -ForegroundColor Yellow
        $riskReport = $null
    }

    # STEP 3: Generate Reports
    Write-Host "STEP 3: Generating Analysis Reports..." -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor Gray

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $projectName = if ($ProjectPath -match '\.ispac$') {
        (Split-Path $ProjectPath -Leaf) -replace '\.ispac$', ''
    } else {
        Split-Path $ProjectPath -Leaf
    }

    # Text Report
    $reportPath = Join-Path $OutputPath "SSIS-Lineage-Report_${projectName}_$timestamp.txt"
    $csvPath = Join-Path $OutputPath "SSIS-Lineage-Summary_${projectName}_$timestamp.csv"

    try {
        # Create text report
        $report = @(
            "═" * 70
            "SSIS LINEAGE ANALYSIS REPORT"
            "═" * 70
            ""
            "Project: $ProjectPath"
            "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            ""
            "SUMMARY"
            "─" * 70
            "Total Packages: $($stats.TotalPackages)"
            "Total Tasks: $($stats.TotalTasks)"
            "Total Components: $($stats.TotalComponents)"
            "Total Columns: $($stats.TotalColumns)"
            "Total Edges: $($stats.TotalEdges)"
            ""
            "NODE TYPES BREAKDOWN"
            "─" * 70
        )

        $stats.NodesByType.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $report += "$($_.Key): $($_.Value)"
        }

        $report += ""
        $report += "EDGE TYPES BREAKDOWN"
        $report += "─" * 70

        $stats.EdgesByType.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $report += "$($_.Key): $($_.Value)"
        }

        if ($riskReport) {
            $report += ""
            $report += "CIRCULAR DEPENDENCY ANALYSIS"
            $report += "─" * 70
            $report += "Risk Level: $($riskReport.RiskLevel)"
            $report += "Cycles Found: $($riskReport.CycleCount)"
            $report += ""

            if ($riskReport.HasCycles) {
                $report += "⚠️  CYCLES DETECTED:"
                $riskReport.Cycles | ForEach-Object {
                    $report += ""
                    $report += "Cycle (Length: $($_.Length))"
                    $report += "  Path: $($_.Nodes -join ' → ')"
                }
            } else {
                $report += "✓ No circular dependencies detected"
            }
        }

        $report += ""
        $report += "═" * 70
        $report += "End of Report"
        $report += "═" * 70

        $report -join "`n" | Out-File -FilePath $reportPath -Encoding UTF8
        Write-Host "✓ Text Report: $reportPath" -ForegroundColor Green

        # Create CSV summary
        $csvData = @(
            "Metric,Value"
            "ProjectPath,$ProjectPath"
            "GeneratedDate,$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "TotalPackages,$($stats.TotalPackages)"
            "TotalTasks,$($stats.TotalTasks)"
            "TotalComponents,$($stats.TotalComponents)"
            "TotalColumns,$($stats.TotalColumns)"
            "TotalEdges,$($stats.TotalEdges)"
            "HasCycles,$(if ($riskReport) { $riskReport.HasCycles } else { 'Unknown' })"
            "RiskLevel,$(if ($riskReport) { $riskReport.RiskLevel } else { 'Unknown' })"
        )

        $csvData -join "`n" | Out-File -FilePath $csvPath -Encoding UTF8
        Write-Host "✓ CSV Summary: $csvPath" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Report Generation Failed: $_" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "STEP 4: Summary" -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor Gray

    Write-Host "✓ Analysis Complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Output Files:" -ForegroundColor Cyan
    Write-Host "  • Text Report: $reportPath" -ForegroundColor Gray
    Write-Host "  • CSV Summary: $csvPath" -ForegroundColor Gray
    Write-Host ""

    # Open report if requested
    if ($OpenReport -and (Test-Path $reportPath)) {
        try {
            Write-Host "Opening report in default application..." -ForegroundColor Cyan
            & notepad.exe $reportPath
        }
        catch {
            Write-Host "Note: Could not open report automatically, but file is saved." -ForegroundColor Yellow
        }
    }

    Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  ANALYSIS COMPLETE                                           ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    return [PSCustomObject]@{
        ProjectPath = $ProjectPath
        ReportPath = $reportPath
        CsvPath = $csvPath
        Statistics = $stats
        RiskReport = $riskReport
        Success = $true
    }
}

# ============================================================================
# QUICK START GUIDE
# ============================================================================

function Show-SsisLineageQuickStart {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  SSIS LINEAGE ANALYSIS - QUICK START GUIDE                   ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "STEP 1: Load the modules" -ForegroundColor Yellow
    Write-Host @"
`$modulePath = 'C:\CMP\SQL-Tools\sqmSQLTool\04 Ressourcen'
. "`$modulePath\SSIS-Lineage-DataModel.ps1"
. "`$modulePath\SSIS-Lineage-Parser-Enhanced.ps1"
. "`$modulePath\SSIS-Lineage-CircularDetection.ps1"
. "`$modulePath\SSIS-Lineage-ColumnLineage.ps1"
. "`$modulePath\SSIS-Lineage-Performance.ps1"
. "`$modulePath\SSIS-Lineage-Main.ps1"
"@ -ForegroundColor Cyan
    Write-Host ""

    Write-Host "STEP 2: Analyze your project" -ForegroundColor Yellow
    Write-Host "Invoke-SsisLineageAnalysis -ProjectPath 'C:\MyProject.ispac'" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "STEP 3: Review the reports" -ForegroundColor Yellow
    Write-Host "  • Text report opens automatically in Notepad" -ForegroundColor Gray
    Write-Host "  • CSV summary saved for Excel analysis" -ForegroundColor Gray
    Write-Host ""

    Write-Host "EXAMPLES" -ForegroundColor Yellow
    Write-Host @"
# Analyze ISPAC file with default output
Invoke-SsisLineageAnalysis -ProjectPath 'C:\Projects\MyProject.ispac'

# Analyze folder with custom output path
Invoke-SsisLineageAnalysis -ProjectPath 'C:\SSIS Packages' -OutputPath 'D:\Reports'

# Analyze without auto-opening report
Invoke-SsisLineageAnalysis -ProjectPath 'C:\Project.ispac' -OpenReport:$false

# Store result for further analysis
`$result = Invoke-SsisLineageAnalysis -ProjectPath 'C:\Project.ispac'
`$result.Statistics | Format-Table
"@ -ForegroundColor Cyan
    Write-Host ""

    Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Ready to analyze SSIS projects!                             ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# Auto-show quick start
Show-SsisLineageQuickStart

Write-Verbose "✓ SSIS Lineage Analysis Main Module loaded"
Write-Verbose "  - Invoke-SsisLineageAnalysis (main entry point)"
Write-Verbose "  - Show-SsisLineageQuickStart (this guide)"
