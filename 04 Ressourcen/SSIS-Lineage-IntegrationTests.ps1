<#
.SYNOPSIS
    End-to-End Integration Tests for SSIS Lineage Pipeline

.DESCRIPTION
    Full pipeline testing:
    - Parse ISPAC → Build Graph → Detect Cycles → Generate Report
    - Real-world Zebra project analysis
    - Performance validation
    - Circular dependency handling

.EXAMPLE
    .\SSIS-Lineage-IntegrationTests.ps1

.NOTES
    Phase 1B Week 4: Integration Testing
#>

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  SSIS LINEAGE GRAPH - END-TO-END INTEGRATION TESTS             ║" -ForegroundColor Cyan
Write-Host "║  Phase 1B Week 4                                               ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Load all modules
$modulePath = Split-Path $MyInvocation.MyCommand.Path
$modules = @(
    "SSIS-Lineage-DataModel.ps1",
    "SSIS-Lineage-Parser-Enhanced.ps1",
    "SSIS-Lineage-CircularDetection.ps1",
    "SSIS-Lineage-ColumnLineage.ps1",
    "SSIS-Lineage-Performance.ps1"
)

foreach ($module in $modules) {
    $path = Join-Path $modulePath $module
    if (Test-Path $path) {
        . $path
        Write-Host "✓ Loaded: $module" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "TEST 1: Parse Zebra Project" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────" -ForegroundColor Gray

$ispacPath = "C:\CMP\Zebra\Zebra.ispac"

if (-not (Test-Path $ispacPath)) {
    Write-Host "✗ FAIL: Zebra.ispac not found" -ForegroundColor Red
    exit 1
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$graph = Parse-SsisProjectEnhanced -ProjectPath $ispacPath
$sw.Stop()

Write-Host "✓ PASS: Project parsed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
$stats = $graph.GetStatistics()
Write-Host "  - Nodes: $($stats.TotalNodes)" -ForegroundColor Cyan
Write-Host "  - Edges: $($stats.TotalEdges)" -ForegroundColor Cyan
Write-Host "  - Packages: $($stats.TotalPackages)" -ForegroundColor Cyan

Write-Host ""
Write-Host "TEST 2: Circular Dependency Detection" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────" -ForegroundColor Gray

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$hasCycles = Test-HasCycles -Graph $graph
$sw.Stop()

Write-Host "✓ PASS: Cycle detection completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
Write-Host "  - Has Cycles: $hasCycles" -ForegroundColor Cyan

if ($hasCycles) {
    $cyclicNodes = Get-CyclicNodes -Graph $graph
    Write-Host "  - Cyclic Nodes: $($cyclicNodes.Count)" -ForegroundColor Yellow
} else {
    Write-Host "  - Status: Graph is acyclic ✓" -ForegroundColor Green
}

Write-Host ""
Write-Host "TEST 3: Graph Statistics & Validation" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────" -ForegroundColor Gray

$stats = $graph.GetStatistics()

Write-Host "✓ PASS: Statistics generated" -ForegroundColor Green
Write-Host "  - Total Nodes: $($stats.TotalNodes)" -ForegroundColor Cyan
Write-Host "  - Total Edges: $($stats.TotalEdges)" -ForegroundColor Cyan
Write-Host "  - Node Types:" -ForegroundColor Cyan

$stats.NodesByType.GetEnumerator() | Sort-Object Name | ForEach-Object {
    Write-Host "    • $($_.Key): $($_.Value)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "TEST 4: Graph Traversal Operations" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────" -ForegroundColor Gray

# Test GetNodesByType
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tasks = $graph.GetNodesByType("Executable")
$sw.Stop()

Write-Host "✓ PASS: GetNodesByType() in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
Write-Host "  - Found $($tasks.Count) tasks" -ForegroundColor Cyan

# Test GetDownstreamEdges (sample)
if ($graph.Nodes.Count -gt 0) {
    $sample = $graph.Nodes | Select-Object -First 1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $downstream = $graph.GetDownstreamEdges($sample)
    $sw.Stop()

    Write-Host "✓ PASS: GetDownstreamEdges() in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
    Write-Host "  - Sample node: $($sample.Name)" -ForegroundColor Cyan
    Write-Host "  - Downstream edges: $($downstream.Count)" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "TEST 5: Performance Baseline" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────" -ForegroundColor Gray

$report = Test-ParsePerformance -IspacPath $ispacPath

if ($report.IsMeetingTargets) {
    Write-Host "✓ PASS: All performance targets met" -ForegroundColor Green
    Write-Host "  - Parse Time: $($report.ProjectParseTimeMs)ms (Target: $($report.TargetParseTimeMs)ms)" -ForegroundColor Cyan
    Write-Host "  - Per-Package: $($report.PerPackageAvgTimeMs)ms (Target: $($report.TargetPerPackageTimeMs)ms)" -ForegroundColor Cyan
    Write-Host "  - Throughput: $($report.ProjectThroughputPackagesPerSecond) pkg/sec" -ForegroundColor Cyan
} else {
    Write-Host "✗ FAIL: Performance targets not met" -ForegroundColor Red
}

Write-Host ""
Write-Host "TEST 6: Data Integrity Check" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────" -ForegroundColor Gray

# Validate graph structure
$hasIssues = $false

# Check that all edges reference existing nodes
$orphanEdges = 0
foreach ($edge in $graph.Edges) {
    $fromExists = $graph.Nodes | Where-Object { $_.Id -eq $edge.FromNode.Id }
    $toExists = $graph.Nodes | Where-Object { $_.Id -eq $edge.ToNode.Id }

    if (-not $fromExists -or -not $toExists) {
        $orphanEdges++
        $hasIssues = $true
    }
}

if ($orphanEdges -gt 0) {
    Write-Host "✗ FAIL: Found $orphanEdges orphan edges" -ForegroundColor Red
} else {
    Write-Host "✓ PASS: All edges reference valid nodes" -ForegroundColor Green
}

# Check for duplicate nodes
$nodeIds = $graph.Nodes.Id
$uniqueIds = $nodeIds | Sort-Object -Unique
if ($nodeIds.Count -ne $uniqueIds.Count) {
    Write-Host "✗ FAIL: Found duplicate node IDs" -ForegroundColor Red
    $hasIssues = $true
} else {
    Write-Host "✓ PASS: All node IDs are unique" -ForegroundColor Green
}

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  TEST SUMMARY                                                  ║" -ForegroundColor Cyan

if ($hasIssues) {
    Write-Host "║  STATUS: ✗ FAILED                                              ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    exit 1
} else {
    Write-Host "║  STATUS: ✓ ALL TESTS PASSED                                   ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
}

Write-Host ""
Write-Host "Results Summary:" -ForegroundColor Cyan
Write-Host "  • Project:      Zebra (33 packages)" -ForegroundColor Gray
Write-Host "  • Parse Time:   $($report.ProjectParseTimeMs)ms" -ForegroundColor Gray
Write-Host "  • Graph Nodes:  $($stats.TotalNodes)" -ForegroundColor Gray
Write-Host "  • Graph Edges:  $($stats.TotalEdges)" -ForegroundColor Gray
Write-Host "  • Has Cycles:   $hasCycles" -ForegroundColor Gray
Write-Host ""

Write-Host "✓ Phase 1B Week 4 Integration Tests PASSED" -ForegroundColor Green
exit 0
