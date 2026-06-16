<#
.SYNOPSIS
    SSIS Column-Level Lineage Extraction and Tracking

.DESCRIPTION
    Extracts column-level lineage from Data Flow tasks:
    - Maps source columns to transformations to outputs
    - Tracks column mappings through components
    - Detects column metadata (type, precision, scale)
    - Builds column dependency graph

.EXAMPLE
    $columnLineage = Get-ColumnLineage -Graph $graph -ComponentId $compId
    $impacted = Get-ImpactedColumns -Graph $graph -SourceColumn $column

.NOTES
    Phase 1B: Column-Level Lineage Extraction
#>

function Get-ColumnLineage {
    <#
    .SYNOPSIS
        Extract column lineage for a component
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph,

        [Parameter(Mandatory=$true)]
        [string]$ComponentId
    )

    # Find component node
    $component = $Graph.Nodes | Where-Object { $_.Id -eq $ComponentId -and $_.Type -eq "Component" }
    if (-not $component) {
        throw "Component not found: $ComponentId"
    }

    # Get output columns for this component
    $outputColumns = $Graph.Nodes | Where-Object {
        $_.Type -eq "Column" -and $_.ComponentId -eq $ComponentId
    }

    # For each output column, trace upstream (inputs)
    $lineageMap = @()

    foreach ($outCol in $outputColumns) {
        $lineageMap += [PSCustomObject]@{
            OutputColumn = $outCol.Name
            OutputColumnId = $outCol.Id
            OutputDataType = $outCol.DataType
            ComponentId = $component.Id
            ComponentName = $component.Name
            ComponentType = $component.ComponentType
            InputColumns = @()  # Will be populated from component mappings
        }
    }

    return $lineageMap
}

function Get-ImpactedColumns {
    <#
    .SYNOPSIS
        Find all columns impacted by a change to a source column
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph,

        [Parameter(Mandatory=$true)]
        [ColumnNode]$SourceColumn,

        [Parameter(Mandatory=$false)]
        [int]$MaxDepth = 10
    )

    $impacted = @()
    $visited = @{}

    function _TraceDownstream {
        param([ColumnNode]$col, [int]$depth)

        if ($depth -le 0 -or $visited.ContainsKey($col.Id)) { return }
        $visited[$col.Id] = $true

        # Find components that output this column
        $outputs = $Graph.Edges | Where-Object {
            $_.FromNode.Id -eq $col.ComponentId -and
            $_.ToNode.Id -eq $col.Id -and
            $_.RelationType -eq "OUTPUTS"
        }

        foreach ($output in $outputs) {
            # Find components that consume columns from this component
            $consumers = $Graph.Edges | Where-Object {
                $_.FromNode.Type -eq "Component" -and
                $_.ToNode.Type -eq "Component" -and
                $_.FromNode.Id -eq $col.ComponentId
            }

            foreach ($consumer in $consumers) {
                $impacted += [PSCustomObject]@{
                    Column = $col.Name
                    ComponentFrom = $col.ComponentId
                    ComponentTo = $consumer.ToNode.Id
                    Depth = $MaxDepth - $depth
                }

                # Recursively trace downstream
                $downstreamCols = $Graph.Nodes | Where-Object {
                    $_.Type -eq "Column" -and $_.ComponentId -eq $consumer.ToNode.Id
                }

                foreach ($dCol in $downstreamCols) {
                    _TraceDownstream $dCol ($depth - 1)
                }
            }
        }
    }

    _TraceDownstream $SourceColumn $MaxDepth
    return $impacted | Sort-Object -Property Depth -Unique
}

function Add-ColumnMappings {
    <#
    .SYNOPSIS
        Map input columns to output columns for a component
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph,

        [Parameter(Mandatory=$true)]
        [string]$ComponentId,

        [Parameter(Mandatory=$true)]
        [hashtable[]]$Mappings  # @{ InputColumn = "col1"; OutputColumn = "col2" }
    )

    $component = $Graph.Nodes | Where-Object { $_.Id -eq $ComponentId }
    if (-not $component) {
        throw "Component not found: $ComponentId"
    }

    foreach ($mapping in $Mappings) {
        $inputCol = $Graph.Nodes | Where-Object {
            $_.Name -eq $mapping.InputColumn -and $_.Type -eq "Column"
        } | Select-Object -First 1

        $outputCol = $Graph.Nodes | Where-Object {
            $_.Name -eq $mapping.OutputColumn -and $_.Type -eq "Column"
        } | Select-Object -First 1

        if ($inputCol -and $outputCol) {
            # Create edge: InputColumn -> Component -> OutputColumn
            $edge = [LineageEdge]::new($inputCol, $outputCol, "MAPS_TO")
            $edge.Metadata["ViaComponent"] = $component.Id
            $edge.Metadata["ViaComponentName"] = $component.Name
            $graph.AddEdge($edge)
        }
    }
}

function Get-ColumnImpactAnalysis {
    <#
    .SYNOPSIS
        Analyze impact of changing a specific column
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [LineageGraph]$Graph,

        [Parameter(Mandatory=$true)]
        [string]$ColumnName
    )

    $sourceCol = $Graph.Nodes | Where-Object {
        $_.Type -eq "Column" -and $_.Name -eq $ColumnName
    } | Select-Object -First 1

    if (-not $sourceCol) {
        throw "Column not found: $ColumnName"
    }

    # Get all downstream columns
    $impactedCols = Get-ImpactedColumns -Graph $Graph -SourceColumn $sourceCol

    # Get all components affected
    $affectedComponents = $impactedCols.ComponentTo | Sort-Object -Unique

    # Get all tables that depend on those components
    $affectedTables = @()
    foreach ($compId in $affectedComponents) {
        $comp = $Graph.Nodes | Where-Object { $_.Id -eq $compId }
        if ($comp) {
            # Find tables connected to this component
            $tables = $Graph.Nodes | Where-Object { $_.Type -eq "Table" }
            foreach ($table in $tables) {
                # Simple heuristic: same name or reference in component
                if ($comp.Name -match $table.Name -or $table.Name -match $comp.Name) {
                    $affectedTables += $table
                }
            }
        }
    }

    return [PSCustomObject]@{
        SourceColumn = $sourceCol.Name
        SourceDataType = $sourceCol.DataType
        ImpactedColumns = $impactedCols.Count
        AffectedComponents = $affectedComponents.Count
        AffectedTables = $affectedTables.Count
        ImpactChain = $impactedCols | Select-Object -First 10  # Top 10
        RiskLevel = if ($affectedTables.Count -gt 3) { "HIGH" } elseif ($affectedComponents.Count -gt 5) { "MEDIUM" } else { "LOW" }
    }
}

# ============================================================================
# EXPORT
# ============================================================================

Write-Verbose "✓ SSIS Column Lineage Module loaded"
Write-Verbose "  - Get-ColumnLineage"
Write-Verbose "  - Get-ImpactedColumns"
Write-Verbose "  - Add-ColumnMappings"
Write-Verbose "  - Get-ColumnImpactAnalysis"
