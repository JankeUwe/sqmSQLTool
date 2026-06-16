<#
.SYNOPSIS
    Enhanced SSIS Lineage Parser - Complete extraction from packages and projects

.DESCRIPTION
    Full-featured parser that extracts complete lineage from SSIS packages:
    - Package metadata and structure
    - All executables (tasks, containers)
    - Data flow components and columns
    - Connection managers and parameters
    - Precedence constraints (edges)
    - Circular dependency detection

.EXAMPLE
    $graph = Parse-SsisPackageEnhanced -PackagePath "C:\path\to\package.dtsx"
    $graph = Parse-SsisProjectEnhanced -ProjectPath "C:\path\to\project.ispac"

    Get-CircularDependencies $graph

.NOTES
    Phase 1A Enhanced Implementation
    Compatible with SSIS 2012+
#>

function Parse-SsisPackageEnhanced {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$PackagePath,

        [Parameter(Mandatory=$false)]
        [switch]$Verbose
    )

    if (-not (Test-Path $PackagePath)) {
        throw "Package not found: $PackagePath"
    }

    # Load data model
    $dmPath = 'C:\CMP\SQL-Tools\sqmSQLTool\04 Ressourcen\SSIS-Lineage-DataModel.ps1'
    if (Test-Path $dmPath) { . $dmPath }

    [xml]$xml = Get-Content $PackagePath -Raw -Encoding UTF8
    $root = $xml.DocumentElement

    # Create graph
    $graph = [LineageGraph]::new()
    $graph.SourceProject = $PackagePath

    # Parse package
    $pkgName = $root.GetAttribute("DTS:ObjectName")
    $pkgNode = [PackageNode]::new($pkgName)
    $pkgNode.Id = $root.GetAttribute("DTS:DTSID")
    $pkgNode.Description = $root.GetAttribute("DTS:Description")
    $pkgNode.Creator = $root.GetAttribute("DTS:CreationName")

    $graph.AddNode($pkgNode)
    if ($Verbose) { Write-Host "Package: $pkgName" }

    # Parse Executables (tasks)
    $execContainer = $root.ChildNodes | Where-Object { $_.LocalName -eq "Executables" }
    if ($execContainer) {
        $tasks = $execContainer.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq "Executable" }

        foreach ($task in $tasks) {
            $taskName = $task.GetAttribute("DTS:ObjectName")
            $taskType = $task.GetAttribute("DTS:ExecutableType")

            # Create appropriate node type
            if ($taskType -match "DataFlowTask") {
                $taskNode = [DataFlowTaskNode]::new($taskName)
                $taskNode.ExecutionMode = $task.GetAttribute("DTS:ExecutionMode")
            }
            else {
                $taskNode = [ExecutableNode]::new($taskName, $taskType)
            }

            $taskNode.Id = $task.GetAttribute("DTS:DTSID")
            $taskNode.Description = $task.GetAttribute("DTS:Description")
            $taskNode.PackageId = $pkgNode.Id
            $taskNode.Priority = [int]($task.GetAttribute("DTS:Priority") -as [int])

            $graph.AddNode($taskNode)

            # Edge: Package contains Task
            $edge = [LineageEdge]::new($pkgNode, $taskNode, "CONTAINS")
            $graph.AddEdge($edge)

            if ($Verbose) { Write-Host "  Task: $taskName [$taskType]" }

            # Parse data flow components (if this is a DataFlowTask)
            if ($taskType -match "DataFlowTask") {
                _ParseDataFlowComponents $task $taskNode $graph $Verbose
            }
        }
    }

    # Parse Connections
    $connContainer = $root.ChildNodes | Where-Object { $_.LocalName -eq "ConnectionManagers" }
    if ($connContainer) {
        $conns = $connContainer.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq "ConnectionManager" }

        foreach ($conn in $conns) {
            $connName = $conn.GetAttribute("DTS:ObjectName")
            if (-not $connName) { continue }

            $connNode = [ConnectionNode]::new($connName)
            $connNode.Id = $conn.GetAttribute("DTS:DTSID")
            $connNode.Provider = $conn.GetAttribute("DTS:CreationName")

            # Try to extract connection details
            $objData = $conn.ChildNodes | Where-Object { $_.LocalName -eq "ObjectData" }
            if ($objData) {
                $innerConn = $objData.ChildNodes | Where-Object { $_.LocalName -eq "ConnectionManager" }
                if ($innerConn) {
                    $connStr = $innerConn.GetAttribute("dts:ConnectionString")
                    if ($connStr) {
                        $connNode.ConnectionString = $connStr
                        # Parse server/database
                        if ($connStr -match "Server=([^;]+)") { $connNode.Server = $matches[1] }
                        if ($connStr -match "Initial Catalog=([^;]+)") { $connNode.Database = $matches[1] }
                    }
                }
            }

            $graph.AddNode($connNode)
            if ($Verbose) { Write-Host "  Connection: $connName [$($connNode.Provider)]" }
        }
    }

    # Parse Variables/Parameters
    $varContainer = $root.ChildNodes | Where-Object { $_.LocalName -eq "Variables" }
    if ($varContainer) {
        $vars = $varContainer.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq "Variable" }

        foreach ($var in $vars) {
            $varName = $var.GetAttribute("DTS:ObjectName")
            if (-not $varName) { continue }

            $dataType = $var.GetAttribute("DTS:DataType")
            $paramNode = [ParameterNode]::new($varName, $dataType)
            $paramNode.Id = $var.GetAttribute("DTS:DTSID")
            $paramNode.Scope = "Package"

            $graph.AddNode($paramNode)
            if ($Verbose) { Write-Host "  Variable: $varName [$dataType]" }
        }
    }

    # Parse Precedence Constraints (edges)
    $constraintContainer = $root.ChildNodes | Where-Object { $_.LocalName -eq "PrecedenceConstraints" }
    if ($constraintContainer) {
        $constraints = $constraintContainer.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq "PrecedenceConstraint" }

        foreach ($constraint in $constraints) {
            $fromRef = $constraint.GetAttribute("DTS:From")
            $toRef = $constraint.GetAttribute("DTS:To")

            if ($fromRef -and $toRef) {
                $fromNode = $graph.Nodes | Where-Object { $_.Id -match $fromRef }
                $toNode = $graph.Nodes | Where-Object { $_.Id -match $toRef }

                if ($fromNode -and $toNode) {
                    $edge = [LineageEdge]::new($fromNode, $toNode, "DEPENDS_ON")
                    $graph.AddEdge($edge)
                    if ($Verbose) { Write-Host "  Constraint: $($fromNode.Name) -> $($toNode.Name)" }
                }
            }
        }
    }

    return $graph
}

function _ParseDataFlowComponents {
    param(
        [System.Xml.XmlElement]$dataFlowTask,
        [DataFlowTaskNode]$taskNode,
        [LineageGraph]$graph,
        [bool]$Verbose
    )

    # Find ObjectData (contains DtsComponents)
    $objData = $dataFlowTask.ChildNodes | Where-Object { $_.LocalName -eq "ObjectData" }
    if (-not $objData) { return }

    # Get all components
    $components = $objData.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq "DtsComponent" }

    foreach ($comp in $components) {
        $compName = $comp.GetAttribute("DTS:ObjectName")
        if (-not $compName) { continue }

        $compType = $comp.GetAttribute("DTS:ComponentClassID")
        $compNode = [ComponentNode]::new($compName, $compType)
        $compNode.Id = $comp.GetAttribute("DTS:DTSID")
        $compNode.DataFlowTaskId = $taskNode.Id

        # Count inputs/outputs
        $inputs = $comp.ChildNodes | Where-Object { $_.LocalName -eq "DtsInput" }
        $outputs = $comp.ChildNodes | Where-Object { $_.LocalName -eq "DtsOutput" }
        $compNode.InputCount = $inputs.Count
        $compNode.OutputCount = $outputs.Count

        $graph.AddNode($compNode)

        # Edge: Task contains Component
        $edge = [LineageEdge]::new($taskNode, $compNode, "CONTAINS")
        $graph.AddEdge($edge)

        if ($Verbose) { Write-Host "    Component: $compName [$compType] (In:$($compNode.InputCount) Out:$($compNode.OutputCount))" }

        # Parse output columns
        foreach ($output in $outputs) {
            $columns = $output.ChildNodes | Where-Object { $_.LocalName -eq "OutputColumn" }

            foreach ($col in $columns) {
                $colName = $col.GetAttribute("DTS:Name")
                if (-not $colName) { continue }

                $colType = $col.GetAttribute("DTS:DataType")
                $colNode = [ColumnNode]::new($colName, $colType)
                $colNode.Id = $col.GetAttribute("DTS:LineageID")
                $colNode.ComponentId = $compNode.Id
                $colNode.LineageId = $col.GetAttribute("DTS:LineageID")

                $graph.AddNode($colNode)

                # Edge: Component outputs Column
                $colEdge = [LineageEdge]::new($compNode, $colNode, "OUTPUTS")
                $graph.AddEdge($colEdge)
            }
        }
    }
}

function Parse-SsisProjectEnhanced {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProjectPath
    )

    # Handle ISPAC (ZIP)
    $isTemp = $false
    if ($ProjectPath -match '\.ispac$') {
        $tempExtract = "$env:TEMP\SSIS_Extract_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $tempExtract -Force

        Add-Type -AssemblyName System.IO.Compression
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ProjectPath, $tempExtract)

        $projectPath = $tempExtract
        $isTemp = $true
    }

    try {
        $graph = [LineageGraph]::new()
        $graph.SourceProject = $ProjectPath

        $packages = Get-ChildItem -Path $projectPath -Filter "*.dtsx" -Recurse
        $packageCount = $packages.Count

        if ($VerbosePreference -eq "Continue") { Write-Host "Parsing project: $packageCount packages found" }

        $packages | ForEach-Object -Begin { $i = 0 } {
            $i++
            if ($VerbosePreference -eq "Continue") { Write-Host "[$i/$packageCount] $_" }

            $pkgGraph = Parse-SsisPackageEnhanced -PackagePath $_.FullName

            # Merge graphs
            foreach ($node in $pkgGraph.Nodes) {
                $graph.AddNode($node)
            }
            foreach ($edge in $pkgGraph.Edges) {
                $graph.AddEdge($edge)
            }
        }

        return $graph
    }
    finally {
        if ($isTemp) {
            Remove-Item $projectPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CircularDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph
    )

    $cycles = @()
    $visited = @{}
    $stack = @{}

    function _DFS {
        param([LineageNode]$node, [string[]]$path)

        if ($visited.ContainsKey($node.Id)) { return }

        $visited[$node.Id] = $true
        $stack[$node.Id] = $true
        $path += $node.Name

        # Get outgoing edges
        $outgoing = $Graph.GetDownstreamEdges($node)

        foreach ($edge in $outgoing) {
            if ($stack.ContainsKey($edge.ToNode.Id)) {
                # Cycle detected!
                $cycleStart = [Array]::IndexOf($path, $edge.ToNode.Name)
                if ($cycleStart -ge 0) {
                    $cycle = $path[$cycleStart..($path.Length-1)]
                    $cycles += @{
                        Path = $cycle
                        Nodes = @($cycle)
                        Length = $cycle.Count
                    }
                }
            }
            else {
                _DFS $edge.ToNode $path
            }
        }

        $stack.Remove($node.Id)
    }

    # Run DFS from all nodes
    foreach ($node in $Graph.Nodes) {
        if (-not $visited.ContainsKey($node.Id)) {
            _DFS $node @()
        }
    }

    return $cycles
}

# ============================================================================
# EXPORT
# ============================================================================

Write-Verbose "✓ SSIS Lineage Parser Enhanced loaded"
Write-Verbose "  - Parse-SsisPackageEnhanced"
Write-Verbose "  - Parse-SsisProjectEnhanced"
Write-Verbose "  - Get-CircularDependencies"
