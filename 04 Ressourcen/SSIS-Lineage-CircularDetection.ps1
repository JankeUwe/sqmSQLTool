<#
.SYNOPSIS
    Circular Dependency Detection for SSIS Lineage Graphs

.DESCRIPTION
    Detects and reports cycles in package execution dependencies:
    - Task-level cycles (precedence constraints)
    - Package-level cycles (nested ExecutePackageTask calls)
    - Complex cycle patterns with detailed reporting
    - Suggests remediation strategies

.EXAMPLE
    $cycles = Get-CircularDependencies -Graph $graph
    $riskReport = Get-CyclicRiskReport -Graph $graph

.NOTES
    Phase 1B: Circular Dependency Detection
#>

function Get-AllCycles {
    <#
    .SYNOPSIS
        Find all cycles in the lineage graph using DFS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph
    )

    $allCycles = @()
    $globalVisited = @{}

    function _DFS {
        param(
            [LineageNode]$startNode,
            [LineageNode[]]$path,
            [hashtable]$pathSet
        )

        $nodeKey = $startNode.Id

        # If already fully explored globally, skip
        if ($globalVisited.ContainsKey($nodeKey) -and $globalVisited[$nodeKey] -eq "DONE") {
            return
        }

        # If in current path, we have a cycle
        if ($pathSet.ContainsKey($nodeKey)) {
            # Found cycle - extract cycle path
            $cycleStart = [Array]::IndexOf($path, $startNode, [System.Collections.Generic.EqualityComparer[object]]::Default)
            if ($cycleStart -ge 0) {
                $cyclePath = $path[$cycleStart..($path.Length-1)] + @($startNode)
                $allCycles += [PSCustomObject]@{
                    Cycle = $cyclePath
                    Length = $cyclePath.Count
                    Nodes = @($cyclePath | ForEach-Object { $_.Name })
                    NodeIds = @($cyclePath | ForEach-Object { $_.Id })
                    Types = @($cyclePath | ForEach-Object { $_.Type })
                }
            }
            return
        }

        # Mark as in current path
        $pathSet[$nodeKey] = $true
        $newPath = $path + @($startNode)

        # Explore neighbors (outgoing edges)
        $outgoing = $Graph.GetDownstreamEdges($startNode)

        foreach ($edge in $outgoing) {
            _DFS $edge.ToNode $newPath $pathSet
        }

        # Unmark from current path (backtrack)
        $pathSet.Remove($nodeKey) | Out-Null
        $globalVisited[$nodeKey] = "DONE"
    }

    # Run DFS from all nodes
    foreach ($node in $Graph.Nodes) {
        if (-not $globalVisited.ContainsKey($node.Id)) {
            _DFS $node @() @{}
        }
    }

    # Remove duplicate cycles
    $uniqueCycles = @()
    $seen = @{}

    foreach ($cycle in $allCycles) {
        $key = ($cycle.NodeIds | Sort-Object) -join ","
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $uniqueCycles += $cycle
        }
    }

    return $uniqueCycles | Sort-Object -Property Length -Descending
}

function Test-HasCycles {
    <#
    .SYNOPSIS
        Quick boolean check if graph has any cycles
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph
    )

    $cycles = Get-AllCycles -Graph $Graph
    return $cycles.Count -gt 0
}

function Get-CyclicNodes {
    <#
    .SYNOPSIS
        Get all nodes involved in any cycle
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph
    )

    $cycles = Get-AllCycles -Graph $Graph
    $cyclicNodeIds = @()

    foreach ($cycle in $cycles) {
        $cyclicNodeIds += $cycle.NodeIds
    }

    # Return unique nodes
    return $Graph.Nodes | Where-Object { $cyclicNodeIds -contains $_.Id } | Sort-Object -Property Name -Unique
}

function Get-CycleBreakingPoints {
    <#
    .SYNOPSIS
        Suggest which edges to remove to break cycles
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph,

        [Parameter(Mandatory=$false)]
        [int]$MaxSuggestions = 5
    )

    $cycles = Get-AllCycles -Graph $Graph
    if ($cycles.Count -eq 0) {
        return @()
    }

    $suggestions = @()

    foreach ($cycle in $cycles | Select-Object -First $MaxSuggestions) {
        $path = $cycle.Cycle

        for ($i = 0; $i -lt $path.Count; $i++) {
            $fromNode = $path[$i]
            $toNode = $path[($i + 1) % $path.Count]

            $suggestions += [PSCustomObject]@{
                Cycle = $cycle.Nodes -join " → "
                RemoveEdge = "$($fromNode.Name) → $($toNode.Name)"
                FromNodeId = $fromNode.Id
                ToNodeId = $toNode.Id
                EdgeType = ($Graph.Edges | Where-Object { $_.FromNode.Id -eq $fromNode.Id -and $_.ToNode.Id -eq $toNode.Id })[0].RelationType
                Impact = "Breaking this edge removes cycle of length $($path.Count)"
            }
        }
    }

    return $suggestions | Sort-Object -Property "Cycle" -Unique
}

function Get-CyclicRiskReport {
    <#
    .SYNOPSIS
        Generate comprehensive cycle risk report
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph
    )

    $cycles = Get-AllCycles -Graph $Graph
    $hasCycles = $cycles.Count -gt 0
    $cyclicNodes = Get-CyclicNodes -Graph $Graph
    $breakingPoints = Get-CycleBreakingPoints -Graph $Graph

    $report = [PSCustomObject]@{
        HasCycles = $hasCycles
        CycleCount = $cycles.Count
        LongestCycle = if ($cycles) { $cycles[0].Length } else { 0 }
        CyclicNodeCount = $cyclicNodes.Count
        CyclicNodeNames = @($cyclicNodes | ForEach-Object { $_.Name })
        Cycles = $cycles
        BreakingPoints = $breakingPoints
        RiskLevel = if ($hasCycles) {
            if ($cycles[0].Length -gt 5) { "CRITICAL" }
            elseif ($cycles[0].Length -gt 3) { "HIGH" }
            else { "MEDIUM" }
        } else { "NONE" }
        Recommendation = if ($hasCycles) {
            "Circular dependencies detected. Review $(($breakingPoints | Select-Object -Unique).Count) possible breaking points. Test impact before implementation."
        } else {
            "No circular dependencies detected. Graph is acyclic."
        }
    }

    return $report
}

function Find-CriticalCycles {
    <#
    .SYNOPSIS
        Find cycles that involve critical components (sources, destinations)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph
    )

    $cycles = Get-AllCycles -Graph $Graph
    $criticalCycles = @()

    foreach ($cycle in $cycles) {
        $hasSource = $cycle.Cycle | Where-Object { $_.Name -match "Source|Input|Load" }
        $hasDestination = $cycle.Cycle | Where-Object { $_.Name -match "Destination|Output|Target" }
        $hasDatabase = $cycle.Cycle | Where-Object { $_.Type -eq "Connection" }

        if ($hasSource -or $hasDestination -or $hasDatabase) {
            $criticalCycles += [PSCustomObject]@{
                Cycle = $cycle.Nodes -join " → "
                Length = $cycle.Length
                HasSource = $null -ne $hasSource
                HasDestination = $null -ne $hasDestination
                HasDatabase = $null -ne $hasDatabase
                Severity = "CRITICAL"
            }
        }
    }

    return $criticalCycles
}

# ============================================================================
# PERFORMANCE & ANALYSIS
# ============================================================================

function Measure-CircularDetection {
    <#
    .SYNOPSIS
        Benchmark circular detection performance
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cycles = Get-AllCycles -Graph $Graph
    $sw.Stop()

    return [PSCustomObject]@{
        ElapsedMilliseconds = $sw.ElapsedMilliseconds
        CyclesFound = $cycles.Count
        NodesInGraph = $Graph.Nodes.Count
        EdgesInGraph = $Graph.Edges.Count
        TimePerNode = [Math]::Round($sw.ElapsedMilliseconds / $Graph.Nodes.Count, 2)
    }
}

# ============================================================================
# EXPORT
# ============================================================================

Write-Verbose "✓ SSIS Circular Detection Module loaded"
Write-Verbose "  - Get-AllCycles"
Write-Verbose "  - Test-HasCycles"
Write-Verbose "  - Get-CyclicNodes"
Write-Verbose "  - Get-CycleBreakingPoints"
Write-Verbose "  - Get-CyclicRiskReport"
