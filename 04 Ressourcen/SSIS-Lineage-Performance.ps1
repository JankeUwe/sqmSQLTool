<#
.SYNOPSIS
    Performance Benchmarking for SSIS Lineage Parser

.DESCRIPTION
    Comprehensive performance testing and optimization for:
    - Parser speed (single vs. batch)
    - Memory usage
    - Circular detection performance
    - Graph traversal operations

.EXAMPLE
    $benchmark = Test-ParsePerformance -IspacPath "C:\path\to\project.ispac"
    $benchmark | Format-Table

.NOTES
    Phase 1B: Performance Baseline & Optimization
#>

function Test-ParsePerformance {
    <#
    .SYNOPSIS
        Benchmark parser performance on ISPAC project
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$IspacPath
    )

    # Load dependencies
    $dmPath = 'C:\CMP\SQL-Tools\sqmSQLTool\04 Ressourcen\SSIS-Lineage-DataModel.ps1'
    $parserPath = 'C:\CMP\SQL-Tools\sqmSQLTool\04 Ressourcen\SSIS-Lineage-Parser-Enhanced.ps1'

    . $dmPath
    . $parserPath

    if (-not (Test-Path $IspacPath)) {
        throw "ISPAC not found: $IspacPath"
    }

    # Extract project
    $tempDir = "$env:TEMP\Perf_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $tempDir -Force

    Add-Type -AssemblyName System.IO.Compression
    [System.IO.Compression.ZipFile]::ExtractToDirectory($IspacPath, $tempDir)

    $packages = Get-ChildItem "$tempDir\*.dtsx"
    $packageCount = $packages.Count

    if ($VerbosePreference -eq "Continue") {
        Write-Host "Benchmarking: $IspacPath" -ForegroundColor Cyan
        Write-Host "Packages found: $packageCount"
        Write-Host ""
    }

    # Test 1: Full project parse
    if ($VerbosePreference -eq "Continue") { Write-Host "Test 1: Full Project Parse..." -ForegroundColor Yellow }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $projectMemStart = [System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB

    $graph = Parse-SsisProjectEnhanced -ProjectPath $IspacPath

    $sw.Stop()
    $projectMemEnd = [System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB
    $projectTime = $sw.ElapsedMilliseconds
    $projectMemUsed = [Math]::Round($projectMemEnd - $projectMemStart, 2)

    if ($VerbosePreference -eq "Continue") { Write-Host "  Time: ${projectTime}ms, Memory: +${projectMemUsed}MB" }

    # Test 2: Per-package timing
    if ($VerbosePreference -eq "Continue") { Write-Host "Test 2: Per-Package Analysis..." -ForegroundColor Yellow }

    $perPackageTimings = @()

    foreach ($pkg in $packages) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $pkgMemStart = [System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB

        $pkgGraph = Parse-SsisPackageEnhanced -PackagePath $pkg.FullName

        $sw.Stop()
        $pkgMemEnd = [System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB

        $perPackageTimings += [PSCustomObject]@{
            Package = $pkg.Name
            TimeMs = $sw.ElapsedMilliseconds
            MemoryMB = [Math]::Round($pkgMemEnd - $pkgMemStart, 2)
            Nodes = $pkgGraph.Nodes.Count
            Edges = $pkgGraph.Edges.Count
        }
    }

    $avgPackageTime = [Math]::Round(($perPackageTimings.TimeMs | Measure-Object -Average).Average, 2)
    $maxPackageTime = ($perPackageTimings | Sort-Object -Property TimeMs -Descending)[0].TimeMs
    $minPackageTime = ($perPackageTimings | Sort-Object -Property TimeMs)[0].TimeMs

    if ($VerbosePreference -eq "Continue") {
        Write-Host "  Avg: ${avgPackageTime}ms, Min: ${minPackageTime}ms, Max: ${maxPackageTime}ms"
    }

    # Test 3: Graph traversal
    if ($VerbosePreference -eq "Continue") { Write-Host "Test 3: Graph Operations..." -ForegroundColor Yellow }

    $opTimings = @()

    # 3a: GetNodesByType
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($type in @("Package", "Executable", "Component", "Column")) {
        $nodes = $graph.GetNodesByType($type)
    }
    $sw.Stop()
    $opTimings += @{ Operation = "GetNodesByType (4 types)"; TimeMs = $sw.ElapsedMilliseconds }

    # 3b: Get statistics
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stats = $graph.GetStatistics()
    $sw.Stop()
    $opTimings += @{ Operation = "GetStatistics"; TimeMs = $sw.ElapsedMilliseconds }

    # 3c: Traverse edges
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $edgeCount = 0
    foreach ($node in $graph.Nodes | Select-Object -First 50) {
        $down = $graph.GetDownstreamEdges($node)
        $up = $graph.GetUpstreamEdges($node)
        $edgeCount += $down.Count + $up.Count
    }
    $sw.Stop()
    $opTimings += @{ Operation = "Traverse Edges (100 samples)"; TimeMs = $sw.ElapsedMilliseconds }

    if ($VerbosePreference -eq "Continue") {
        $opTimings | ForEach-Object { Write-Host "  $($_.Operation): $($_.TimeMs)ms" }
    }

    # Compile report
    $report = [PSCustomObject]@{
        ProjectPath = $IspacPath
        TestDate = Get-Date
        # Project-level metrics
        PackageCount = $packageCount
        ProjectParseTimeMs = $projectTime
        ProjectMemoryUsedMB = $projectMemUsed
        ProjectThroughputPackagesPerSecond = [Math]::Round(1000 / ($projectTime / $packageCount), 2)
        # Per-package metrics
        PerPackageAvgTimeMs = $avgPackageTime
        PerPackageMinTimeMs = $minPackageTime
        PerPackageMaxTimeMs = $maxPackageTime
        # Graph metrics
        TotalNodes = $graph.Nodes.Count
        TotalEdges = $graph.Edges.Count
        NodesPerPackage = [Math]::Round($graph.Nodes.Count / $packageCount, 2)
        # Operation metrics
        GraphOperationTimings = $opTimings
        # Performance targets
        TargetParseTimeMs = 5000
        TargetPerPackageTimeMs = 50
        IsMeetingTargets = $projectTime -lt 5000 -and $avgPackageTime -lt 50
    }

    # Cleanup
    Remove-Item $tempDir -Recurse -Force

    return $report
}

function Show-PerformanceReport {
    param([PSCustomObject]$Report)

    Write-Host ""
    Write-Host "═════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "SSIS LINEAGE PARSER - PERFORMANCE BASELINE" -ForegroundColor Cyan
    Write-Host "═════════════════════════════════════════════════════" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Project: $($Report.ProjectPath)" -ForegroundColor Yellow
    Write-Host "Test Date: $($Report.TestDate)"

    Write-Host ""
    Write-Host "PROJECT-LEVEL METRICS" -ForegroundColor Green
    Write-Host "  Packages:                 $($Report.PackageCount)"
    Write-Host "  Total Parse Time:         $($Report.ProjectParseTimeMs) ms"
    Write-Host "  Memory Used:              $($Report.ProjectMemoryUsedMB) MB"
    Write-Host "  Throughput:               $($Report.ProjectThroughputPackagesPerSecond) pkg/sec"

    Write-Host ""
    Write-Host "PER-PACKAGE METRICS" -ForegroundColor Green
    Write-Host "  Avg Parse Time:           $($Report.PerPackageAvgTimeMs) ms"
    Write-Host "  Min Parse Time:           $($Report.PerPackageMinTimeMs) ms"
    Write-Host "  Max Parse Time:           $($Report.PerPackageMaxTimeMs) ms"

    Write-Host ""
    Write-Host "GRAPH METRICS" -ForegroundColor Green
    Write-Host "  Total Nodes:              $($Report.TotalNodes)"
    Write-Host "  Total Edges:              $($Report.TotalEdges)"
    Write-Host "  Avg Nodes/Package:        $($Report.NodesPerPackage)"

    Write-Host ""
    Write-Host "PERFORMANCE TARGETS" -ForegroundColor Green
    Write-Host "  Target (Project):         $($Report.TargetParseTimeMs) ms"
    Write-Host "  Target (Per-Package):     $($Report.TargetPerPackageTimeMs) ms"
    Write-Host "  Status:                   $(if ($Report.IsMeetingTargets) { '✓ PASS' } else { '✗ FAIL' })" -ForegroundColor $(if ($Report.IsMeetingTargets) { 'Green' } else { 'Red' })

    if ($Report.GraphOperationTimings) {
        Write-Host ""
        Write-Host "OPERATION PERFORMANCE" -ForegroundColor Green
        $Report.GraphOperationTimings | ForEach-Object {
            Write-Host "  $($_.Operation): $($_.TimeMs) ms"
        }
    }

    Write-Host ""
    Write-Host "═════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    return $Report
}

# ============================================================================
# OPTIMIZATION RECOMMENDATIONS
# ============================================================================

function Get-OptimizationRecommendations {
    param([PSCustomObject]$Report)

    $recommendations = @()

    if ($Report.ProjectParseTimeMs -gt $Report.TargetParseTimeMs) {
        $recommendations += "Project parse time exceeds target. Consider: batch processing, lazy loading, or parallel parsing."
    }

    if ($Report.PerPackageAvgTimeMs -gt $Report.TargetPerPackageTimeMs) {
        $recommendations += "Per-package parse time exceeds target. Profile hot paths and optimize XML traversal."
    }

    if ($Report.ProjectMemoryUsedMB -gt 100) {
        $recommendations += "High memory usage detected. Consider: streaming parsing, disposal of intermediate objects, or paging."
    }

    if ($Report.TotalNodes / $Report.TotalEdges -gt 2) {
        $recommendations += "Few edges relative to nodes. Consider: lazy-loading edges, on-demand graph building."
    }

    return $recommendations
}

Write-Verbose "✓ SSIS Performance Benchmarking Module loaded"
Write-Verbose "  - Test-ParsePerformance"
Write-Verbose "  - Show-PerformanceReport"
Write-Verbose "  - Get-OptimizationRecommendations"
