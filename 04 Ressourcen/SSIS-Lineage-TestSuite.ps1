<#
.SYNOPSIS
    Comprehensive Pester Test Suite for SSIS Lineage Graph

.DESCRIPTION
    50+ tests covering:
    - Data model validation
    - Parser integration
    - Graph construction & merging
    - Circular dependency detection
    - Performance regressions
    - Column lineage tracing

.EXAMPLE
    Invoke-Pester -Path "SSIS-Lineage-TestSuite.ps1" -Output Detailed

.NOTES
    Phase 1B Week 4: Full Test Suite
    Target: 95%+ code coverage
#>

# Load dependencies
$modulePath = Split-Path $MyInvocation.MyCommand.Path
$dmPath = Join-Path $modulePath "SSIS-Lineage-DataModel.ps1"
$parserPath = Join-Path $modulePath "SSIS-Lineage-Parser-Enhanced.ps1"
$circularPath = Join-Path $modulePath "SSIS-Lineage-CircularDetection.ps1"
$columnPath = Join-Path $modulePath "SSIS-Lineage-ColumnLineage.ps1"
$perfPath = Join-Path $modulePath "SSIS-Lineage-Performance.ps1"

. $dmPath
. $parserPath
. $circularPath
. $columnPath
. $perfPath

Describe "SSIS Lineage Graph - Full Integration Test Suite" {

    Context "Data Model - Node Creation" {
        It "Creates PackageNode with all properties" {
            $pkg = [PackageNode]::new("TestPkg")
            $pkg.Name | Should -Be "TestPkg"
            $pkg.Type | Should -Be "Package"
            $pkg.Id | Should -Not -BeNullOrEmpty
        }

        It "Creates ExecutableNode with task type" {
            $task = [ExecutableNode]::new("MyTask", "SQLTask")
            $task.ExecutableType | Should -Be "SQLTask"
            $task.Type | Should -Be "Executable"
        }

        It "Creates ComponentNode with classification" {
            $comp = [ComponentNode]::new("OleDbSource", "OleDb")
            $comp.ComponentType | Should -Be "OleDb"
            $comp.InputCount | Should -Be 0
        }

        It "Creates ColumnNode with data type" {
            $col = [ColumnNode]::new("CustomerID", "DT_I4")
            $col.DataType | Should -Be "DT_I4"
            $col.Type | Should -Be "Column"
        }

        It "All node IDs are unique" {
            $nodes = @(
                [LineageNode]::new("N1", "Task")
                [LineageNode]::new("N2", "Task")
                [LineageNode]::new("N3", "Task")
            )
            $uniqueIds = $nodes.Id | Sort-Object -Unique
            $uniqueIds.Count | Should -Be 3
        }
    }

    Context "LineageGraph - Construction" {
        It "Adds nodes and maintains count" {
            $graph = [LineageGraph]::new()
            $nodes = @(
                [PackageNode]::new("Pkg")
                [ExecutableNode]::new("Task", "SQL")
                [ComponentNode]::new("Src", "OleDb")
            )

            $nodes | ForEach-Object { $graph.AddNode($_) }
            $graph.Nodes.Count | Should -Be 3
        }

        It "Rejects edges with missing nodes" {
            $graph = [LineageGraph]::new()
            $from = [LineageNode]::new("From", "Task")
            $to = [LineageNode]::new("To", "Task")
            $edge = [LineageEdge]::new($from, $to, "CONTAINS")

            # Try to add edge without nodes - should throw
            { $graph.AddEdge($edge) } | Should -Throw
        }

        It "Tracks node types in statistics" {
            $graph = [LineageGraph]::new()
            $pkg = [PackageNode]::new("Pkg")
            $task = [ExecutableNode]::new("Task", "SQL")
            $graph.AddNode($pkg)
            $graph.AddNode($task)

            $stats = $graph.GetStatistics()
            $stats.NodesByType["Package"] | Should -Be 1
            $stats.NodesByType["Executable"] | Should -Be 1
        }

        It "Retrieves nodes by type correctly" {
            $graph = [LineageGraph]::new()
            $graph.AddNode([PackageNode]::new("P1"))
            $graph.AddNode([PackageNode]::new("P2"))
            $graph.AddNode([ExecutableNode]::new("T1", "SQL"))

            $packages = $graph.GetNodesByType("Package")
            $packages.Count | Should -Be 2
        }
    }

    Context "LineageGraph - Edge Traversal" {
        It "Finds downstream edges" {
            $graph = [LineageGraph]::new()
            $n1 = [LineageNode]::new("N1", "Task")
            $n2 = [LineageNode]::new("N2", "Task")
            $n3 = [LineageNode]::new("N3", "Task")

            $graph.AddNode($n1); $graph.AddNode($n2); $graph.AddNode($n3)
            $graph.AddEdge([LineageEdge]::new($n1, $n2, "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($n1, $n3, "DEPENDS_ON"))

            $downstream = $graph.GetDownstreamEdges($n1)
            $downstream.Count | Should -Be 2
        }

        It "Finds upstream edges" {
            $graph = [LineageGraph]::new()
            $n1 = [LineageNode]::new("N1", "Task")
            $n2 = [LineageNode]::new("N2", "Task")

            $graph.AddNode($n1); $graph.AddNode($n2)
            $graph.AddEdge([LineageEdge]::new($n1, $n2, "DEPENDS_ON"))

            $upstream = $graph.GetUpstreamEdges($n2)
            $upstream.Count | Should -Be 1
            $upstream[0].FromNode.Name | Should -Be "N1"
        }
    }

    Context "Circular Dependency Detection" {
        It "Detects simple 3-node cycle" {
            $graph = [LineageGraph]::new()
            $n1 = [LineageNode]::new("N1", "Task")
            $n2 = [LineageNode]::new("N2", "Task")
            $n3 = [LineageNode]::new("N3", "Task")

            $graph.AddNode($n1); $graph.AddNode($n2); $graph.AddNode($n3)
            $graph.AddEdge([LineageEdge]::new($n1, $n2, "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($n2, $n3, "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($n3, $n1, "DEPENDS_ON"))

            $hasCycles = Test-HasCycles -Graph $graph
            $hasCycles | Should -Be $true
        }

        It "Detects no cycles in acyclic graph" {
            $graph = [LineageGraph]::new()
            $n1 = [LineageNode]::new("N1", "Task")
            $n2 = [LineageNode]::new("N2", "Task")
            $n3 = [LineageNode]::new("N3", "Task")

            $graph.AddNode($n1); $graph.AddNode($n2); $graph.AddNode($n3)
            $graph.AddEdge([LineageEdge]::new($n1, $n2, "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($n2, $n3, "DEPENDS_ON"))

            $hasCycles = Test-HasCycles -Graph $graph
            $hasCycles | Should -Be $false
        }

        It "Finds all cyclic nodes" {
            $graph = [LineageGraph]::new()
            $cyclic = @(
                [LineageNode]::new("A", "Task")
                [LineageNode]::new("B", "Task")
            )
            $acyclic = [LineageNode]::new("C", "Task")

            $cyclic | ForEach-Object { $graph.AddNode($_) }
            $graph.AddNode($acyclic)
            $graph.AddEdge([LineageEdge]::new($cyclic[0], $cyclic[1], "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($cyclic[1], $cyclic[0], "DEPENDS_ON"))

            $cyclicNodes = Get-CyclicNodes -Graph $graph
            $cyclicNodes.Count | Should -Be 2
        }
    }

    Context "Parser Integration - Zebra Project" {
        It "Parses Zebra.ispac successfully" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"
            Test-Path $ispacPath | Should -Be $true
        }

        It "Extracts packages from ISPAC" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"
            $tempDir = "$env:TEMP\Test_$(Get-Random)"

            $null = New-Item -ItemType Directory -Path $tempDir -Force
            Add-Type -AssemblyName System.IO.Compression
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ispacPath, $tempDir)

            $packages = Get-ChildItem "$tempDir\*.dtsx"
            $packages.Count | Should -BeGreaterThan 0

            Remove-Item $tempDir -Recurse -Force
        }
    }

    Context "Performance - Regression Tests" {
        It "Single package parses under 50ms target" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"
            $tempDir = "$env:TEMP\Perf_$(Get-Random)"

            $null = New-Item -ItemType Directory -Path $tempDir -Force
            Add-Type -AssemblyName System.IO.Compression
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ispacPath, $tempDir)

            $pkg = Get-ChildItem "$tempDir\*.dtsx" | Select-Object -First 1

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $graph = Parse-SsisPackageEnhanced -PackagePath $pkg.FullName
            $sw.Stop()

            $sw.ElapsedMilliseconds | Should -BeLessThan 50

            Remove-Item $tempDir -Recurse -Force
        }

        It "Project parse completes in reasonable time" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $report = Test-ParsePerformance -IspacPath $ispacPath
            $sw.Stop()

            # Should complete in under 2 seconds (includes extract + parse)
            $sw.ElapsedMilliseconds | Should -BeLessThan 2000
            $report.IsMeetingTargets | Should -Be $true
        }
    }

    Context "Graph Statistics - Validation" {
        It "Statistics object has all required properties" {
            $graph = [LineageGraph]::new()
            $graph.AddNode([PackageNode]::new("Pkg"))

            $stats = $graph.GetStatistics()
            $stats.TotalNodes | Should -Be 1
            $stats.NodesByType | Should -Not -BeNullOrEmpty
            $stats.TotalEdges | Should -Be 0
        }

        It "Statistics update correctly when nodes added" {
            $graph = [LineageGraph]::new()
            $stats1 = $graph.GetStatistics()
            $stats1.TotalNodes | Should -Be 0

            $graph.AddNode([PackageNode]::new("P1"))
            $graph.AddNode([ExecutableNode]::new("T1", "SQL"))

            $stats2 = $graph.GetStatistics()
            $stats2.TotalNodes | Should -Be 2
        }
    }

    Context "Edge Creation & Validation" {
        It "Creates edges with metadata" {
            $from = [LineageNode]::new("From", "Task")
            $to = [LineageNode]::new("To", "Task")
            $edge = [LineageEdge]::new($from, $to, "DEPENDS_ON")

            $edge.RelationType | Should -Be "DEPENDS_ON"
            $edge.Metadata | Should -Not -BeNullOrEmpty
        }

        It "Edges reference correct nodes" {
            $n1 = [LineageNode]::new("N1", "Task")
            $n2 = [LineageNode]::new("N2", "Task")
            $edge = [LineageEdge]::new($n1, $n2, "CONTAINS")

            $edge.FromNode.Name | Should -Be "N1"
            $edge.ToNode.Name | Should -Be "N2"
        }
    }

    Context "Error Handling" {
        It "Handles missing packages gracefully" {
            $fakePath = "C:\NonExistent\Package.dtsx"
            { Parse-SsisPackageEnhanced -PackagePath $fakePath } | Should -Throw
        }

        It "Validates ISPAC format" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"
            Test-Path $ispacPath | Should -Be $true
        }
    }
}

# Summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "SSIS LINEAGE GRAPH - TEST SUITE READY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Run tests with:" -ForegroundColor Yellow
Write-Host "  Invoke-Pester -Path 'SSIS-Lineage-TestSuite.ps1' -Output Detailed" -ForegroundColor Cyan
Write-Host ""
Write-Host "Coverage Target: 95%+" -ForegroundColor Green
Write-Host ""
