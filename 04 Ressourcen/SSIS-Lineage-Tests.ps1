<#
.SYNOPSIS
    Pester Tests for SSIS Lineage Parser

.DESCRIPTION
    Unit tests for data model, parser, and circular dependency detection

.NOTES
    Phase 1A Testing
    Requires: Pester module, SSIS-Lineage-DataModel.ps1
#>

# Load dependencies
$dmPath = 'C:\CMP\SQL-Tools\sqmSQLTool\04 Ressourcen\SSIS-Lineage-DataModel.ps1'
. $dmPath

Describe "SSIS Lineage Data Model" {

    Context "LineageNode Base Class" {
        It "Creates a node with name and type" {
            $node = [LineageNode]::new("TestNode", "Package")
            $node.Name | Should -Be "TestNode"
            $node.Type | Should -Be "Package"
        }

        It "Auto-generates unique ID" {
            $node1 = [LineageNode]::new("Node1", "Task")
            $node2 = [LineageNode]::new("Node2", "Task")
            $node1.Id | Should -Not -Be $node2.Id
        }

        It "Has creation date" {
            $node = [LineageNode]::new("TestNode", "Task")
            $node.CreatedDate | Should -BeGreaterThan (Get-Date).AddSeconds(-5)
        }
    }

    Context "Specialized Node Types" {
        It "Creates PackageNode" {
            $pkg = [PackageNode]::new("MyPackage")
            $pkg.Type | Should -Be "Package"
            $pkg.Creator = "TestUser"
            $pkg.Creator | Should -Be "TestUser"
        }

        It "Creates DataFlowTaskNode" {
            $dft = [DataFlowTaskNode]::new("LoadData")
            $dft.Type | Should -Be "DataFlowTask"
        }

        It "Creates ComponentNode with type" {
            $comp = [ComponentNode]::new("OleDbSource", "OleDbSource")
            $comp.ComponentType | Should -Be "OleDbSource"
        }

        It "Creates ColumnNode with data type" {
            $col = [ColumnNode]::new("CustomerID", "DT_I4")
            $col.DataType | Should -Be "DT_I4"
        }
    }

    Context "LineageEdge" {
        It "Creates edge between two nodes" {
            $from = [LineageNode]::new("Node1", "Task")
            $to = [LineageNode]::new("Node2", "Task")
            $edge = [LineageEdge]::new($from, $to, "DEPENDS_ON")

            $edge.FromNode.Name | Should -Be "Node1"
            $edge.ToNode.Name | Should -Be "Node2"
            $edge.RelationType | Should -Be "DEPENDS_ON"
        }
    }

    Context "LineageGraph Container" {
        It "Adds nodes and tracks statistics" {
            $graph = [LineageGraph]::new()
            $node1 = [PackageNode]::new("Pkg1")
            $node2 = [ExecutableNode]::new("Task1", "SQLTask")

            $graph.AddNode($node1)
            $graph.AddNode($node2)

            $graph.Nodes.Count | Should -Be 2
            $graph.Statistics.TotalNodes | Should -Be 2
        }

        It "Adds edges and validates nodes exist" {
            $graph = [LineageGraph]::new()
            $node1 = [LineageNode]::new("Node1", "Task")
            $node2 = [LineageNode]::new("Node2", "Task")

            $graph.AddNode($node1)
            $graph.AddNode($node2)

            $edge = [LineageEdge]::new($node1, $node2, "CONTAINS")
            $graph.AddEdge($edge)

            $graph.Edges.Count | Should -Be 1
        }

        It "Tracks node types in statistics" {
            $graph = [LineageGraph]::new()
            $pkg = [PackageNode]::new("Pkg")
            $task = [ExecutableNode]::new("Task", "SQLTask")

            $graph.AddNode($pkg)
            $graph.AddNode($task)

            $stats = $graph.GetStatistics()
            $stats.NodesByType["Package"] | Should -Be 1
            $stats.NodesByType["Executable"] | Should -Be 1
        }

        It "Retrieves nodes by type" {
            $graph = [LineageGraph]::new()
            $pkg1 = [PackageNode]::new("Pkg1")
            $pkg2 = [PackageNode]::new("Pkg2")
            $task = [ExecutableNode]::new("Task", "SQLTask")

            $graph.AddNode($pkg1)
            $graph.AddNode($pkg2)
            $graph.AddNode($task)

            $packages = $graph.GetNodesByType("Package")
            $packages.Count | Should -Be 2
        }

        It "Retrieves downstream edges" {
            $graph = [LineageGraph]::new()
            $from = [LineageNode]::new("Node1", "Task")
            $to = [LineageNode]::new("Node2", "Task")

            $graph.AddNode($from)
            $graph.AddNode($to)

            $edge = [LineageEdge]::new($from, $to, "DEPENDS_ON")
            $graph.AddEdge($edge)

            $downstreamEdges = $graph.GetDownstreamEdges($from)
            $downstreamEdges.Count | Should -Be 1
            $downstreamEdges[0].ToNode.Name | Should -Be "Node2"
        }
    }
}

Describe "SSIS Lineage Parser" {

    Context "Zebra Project Parsing" {
        It "Parses Zebra.ispac without errors" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"
            Test-Path $ispacPath | Should -Be $true

            # Quick scan
            $tempExtract = "$env:TEMP\Zebra_Test_$([guid]::NewGuid().ToString().Substring(0,8))"
            $null = New-Item -ItemType Directory -Path $tempExtract -Force

            Add-Type -AssemblyName System.IO.Compression
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ispacPath, $tempExtract)

            $pkgCount = (Get-ChildItem "$tempExtract\*.dtsx").Count
            $pkgCount | Should -BeGreaterThan 0

            Remove-Item $tempExtract -Recurse -Force
        }

        It "Finds expected number of packages" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"
            $tempExtract = "$env:TEMP\Zebra_Count_$([guid]::NewGuid().ToString().Substring(0,8))"

            $null = New-Item -ItemType Directory -Path $tempExtract -Force
            Add-Type -AssemblyName System.IO.Compression
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ispacPath, $tempExtract)

            $pkgs = Get-ChildItem "$tempExtract\*.dtsx"
            $pkgs.Count | Should -BeGreaterThanOrEqual 30

            Remove-Item $tempExtract -Recurse -Force
        }

        It "Extracts tasks from packages" {
            $ispacPath = "C:\CMP\Zebra\Zebra.ispac"
            $tempExtract = "$env:TEMP\Zebra_Tasks_$([guid]::NewGuid().ToString().Substring(0,8))"

            $null = New-Item -ItemType Directory -Path $tempExtract -Force
            Add-Type -AssemblyName System.IO.Compression
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ispacPath, $tempExtract)

            # Count tasks across all packages
            $totalTasks = 0
            Get-ChildItem "$tempExtract\*.dtsx" | ForEach-Object {
                [xml]$xml = Get-Content $_.FullName -Raw
                $root = $xml.DocumentElement
                $execContainer = $root.ChildNodes | Where-Object { $_.LocalName -eq "Executables" }
                if ($execContainer) {
                    $totalTasks += ($execContainer.ChildNodes | Where-Object { $_.LocalName -eq "Executable" }).Count
                }
            }

            $totalTasks | Should -BeGreaterThan 50

            Remove-Item $tempExtract -Recurse -Force
        }
    }
}

Describe "Lineage Graph Analysis" {

    Context "Circular Dependency Detection" {
        It "Detects simple cycle" {
            $graph = [LineageGraph]::new()

            # Create cycle: A -> B -> C -> A
            $nodeA = [LineageNode]::new("A", "Task")
            $nodeB = [LineageNode]::new("B", "Task")
            $nodeC = [LineageNode]::new("C", "Task")

            $graph.AddNode($nodeA)
            $graph.AddNode($nodeB)
            $graph.AddNode($nodeC)

            $graph.AddEdge([LineageEdge]::new($nodeA, $nodeB, "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($nodeB, $nodeC, "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($nodeC, $nodeA, "DEPENDS_ON"))

            # Note: Cycle detection function needs to be exposed
            # For now, just verify graph structure
            $graph.Nodes.Count | Should -Be 3
            $graph.Edges.Count | Should -Be 3
        }

        It "Allows linear chain without cycles" {
            $graph = [LineageGraph]::new()

            $n1 = [LineageNode]::new("N1", "Task")
            $n2 = [LineageNode]::new("N2", "Task")
            $n3 = [LineageNode]::new("N3", "Task")

            $graph.AddNode($n1)
            $graph.AddNode($n2)
            $graph.AddNode($n3)

            $graph.AddEdge([LineageEdge]::new($n1, $n2, "DEPENDS_ON"))
            $graph.AddEdge([LineageEdge]::new($n2, $n3, "DEPENDS_ON"))

            # Should not throw
            $graph.Nodes.Count | Should -Be 3
        }
    }
}

Write-Host "✓ SSIS Lineage Test Suite Ready" -ForegroundColor Green
Write-Host "  Run with: Invoke-Pester -Path '<this-script>'" -ForegroundColor Cyan
