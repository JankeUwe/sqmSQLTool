<#
.SYNOPSIS
    SSIS Lineage Graph Data Model - Core Classes and Node/Edge Types

.DESCRIPTION
    Defines canonical data structures for representing SSIS package lineage:
    - LineageNode: Abstract base for all lineage entities
    - LineageEdge: Represents relationships between nodes
    - LineageGraph: Container for all nodes and edges
    - Specialized node types: Package, Task, DataFlowComponent, Column, etc.

.NOTES
    Phase 1A Foundation - Data Model & Foundations
    Compatible with SSIS 2012, 2014, 2016, 2017, 2019, 2022
    Neo4j target schema: 10 node types, 8 edge types
#>

# Allow fresh load each time (classes can be redefined in PS 5.1)

# ============================================================================
# BASE CLASSES
# ============================================================================

class LineageNode {
    [string]$Id
    [string]$Name
    [string]$Type           # Package, Task, Component, Column, Connection, Table, etc.
    [string]$Description
    [datetime]$CreatedDate
    [hashtable]$Metadata    # Custom properties

    LineageNode([string]$name, [string]$type) {
        $this.Id = [guid]::NewGuid().ToString()
        $this.Name = $name
        $this.Type = $type
        $this.CreatedDate = [datetime]::Now
        $this.Metadata = @{}
    }

    [string] ToString() {
        return "$($this.Type):$($this.Name) [$($this.Id.Substring(0,8))]"
    }
}

class LineageEdge {
    [string]$Id
    [LineageNode]$FromNode
    [LineageNode]$ToNode
    [string]$RelationType   # CONTAINS, TRANSFORMS, OUTPUTS_TO, DEPENDS_ON, etc.
    [string]$Description
    [hashtable]$Metadata

    LineageEdge([LineageNode]$from, [LineageNode]$to, [string]$relationType) {
        $this.Id = [guid]::NewGuid().ToString()
        $this.FromNode = $from
        $this.ToNode = $to
        $this.RelationType = $relationType
        $this.Metadata = @{}
    }

    [string] ToString() {
        return "$($this.FromNode.Name) --$($this.RelationType)--> $($this.ToNode.Name)"
    }
}

# ============================================================================
# SPECIALIZED NODE TYPES
# ============================================================================

class PackageNode : LineageNode {
    [string]$Creator
    [string]$Version
    [string]$Path           # Filesystem or SSISDB path
    [int]$PackageTaskCount

    PackageNode([string]$name) : base($name, "Package") {}
}

class ExecutableNode : LineageNode {
    [string]$ExecutableType  # Task, Container, Sequence, Loop, etc.
    [string]$PackageId
    [int]$Priority
    [string]$ParentId        # For nested tasks

    ExecutableNode([string]$name, [string]$executableType) : base($name, "Executable") {
        $this.ExecutableType = $executableType
    }
}

class DataFlowTaskNode : LineageNode {
    [string]$PackageId
    [string]$ExecutionMode   # Row, Batch, Partial
    [int]$ComponentCount

    DataFlowTaskNode([string]$name) : base($name, "DataFlowTask") {}
}

class ComponentNode : LineageNode {
    [string]$ComponentType   # OleDbSource, Lookup, Multicast, OleDbDestination, etc.
    [string]$DataFlowTaskId
    [string]$LineageId       # For column tracking
    [int]$InputCount
    [int]$OutputCount

    ComponentNode([string]$name, [string]$componentType) : base($name, "Component") {
        $this.ComponentType = $componentType
    }
}

class ColumnNode : LineageNode {
    [string]$DataType        # DT_STR, DT_I4, DT_DATE, etc.
    [int]$Precision
    [int]$Scale
    [string]$ComponentId     # Parent component
    [string]$LineageId       # For tracking through components
    [bool]$IsKey

    ColumnNode([string]$name, [string]$dataType) : base($name, "Column") {
        $this.DataType = $dataType
    }
}

class ConnectionNode : LineageNode {
    [string]$Provider        # OleDb, ADO.NET, Flat File, etc.
    [string]$ConnectionString
    [string]$Server
    [string]$Database

    ConnectionNode([string]$name) : base($name, "Connection") {}
}

class TableNode : LineageNode {
    [string]$Schema
    [string]$Database
    [string]$Server
    [string]$ConnectionId    # Reference to ConnectionNode
    [int]$ColumnCount

    TableNode([string]$name) : base($name, "Table") {}
}

class ParameterNode : LineageNode {
    [string]$DataType
    [string]$Scope           # Package, Project, Environment
    [string]$DefaultValue
    [bool]$IsRequired

    ParameterNode([string]$name, [string]$dataType) : base($name, "Parameter") {
        $this.DataType = $dataType
    }
}

# ============================================================================
# LINEAGE GRAPH CONTAINER
# ============================================================================

class LineageGraph {
    [System.Collections.Generic.List[LineageNode]]$Nodes
    [System.Collections.Generic.List[LineageEdge]]$Edges
    [string]$SourceProject   # Path to ISPAC or SSISDB project
    [datetime]$CreatedDate
    [hashtable]$Statistics

    LineageGraph() {
        $this.Nodes = [System.Collections.Generic.List[LineageNode]]::new()
        $this.Edges = [System.Collections.Generic.List[LineageEdge]]::new()
        $this.CreatedDate = [datetime]::Now
        $this.Statistics = @{
            TotalNodes = 0
            NodesByType = @{}
            TotalEdges = 0
            EdgesByType = @{}
        }
    }

    [void] AddNode([LineageNode]$node) {
        $this.Nodes.Add($node)
        $this.Statistics.TotalNodes++

        if (-not $this.Statistics.NodesByType.ContainsKey($node.Type)) {
            $this.Statistics.NodesByType[$node.Type] = 0
        }
        $this.Statistics.NodesByType[$node.Type]++
    }

    [void] AddEdge([LineageEdge]$edge) {
        # Validate nodes exist in graph
        if (-not ($this.Nodes | Where-Object { $_.Id -eq $edge.FromNode.Id })) {
            throw "FromNode not in graph: $($edge.FromNode.Id)"
        }
        if (-not ($this.Nodes | Where-Object { $_.Id -eq $edge.ToNode.Id })) {
            throw "ToNode not in graph: $($edge.ToNode.Id)"
        }

        $this.Edges.Add($edge)
        $this.Statistics.TotalEdges++

        if (-not $this.Statistics.EdgesByType.ContainsKey($edge.RelationType)) {
            $this.Statistics.EdgesByType[$edge.RelationType] = 0
        }
        $this.Statistics.EdgesByType[$edge.RelationType]++
    }

    [LineageNode[]] GetNodesByType([string]$type) {
        return @($this.Nodes | Where-Object { $_.Type -eq $type })
    }

    [LineageEdge[]] GetDownstreamEdges([LineageNode]$node) {
        return @($this.Edges | Where-Object { $_.FromNode.Id -eq $node.Id })
    }

    [LineageEdge[]] GetUpstreamEdges([LineageNode]$node) {
        return @($this.Edges | Where-Object { $_.ToNode.Id -eq $node.Id })
    }

    [PSCustomObject] GetStatistics() {
        return [PSCustomObject]@{
            SourceProject = $this.SourceProject
            CreatedDate = $this.CreatedDate
            TotalNodes = $this.Statistics.TotalNodes
            NodesByType = $this.Statistics.NodesByType
            TotalEdges = $this.Statistics.TotalEdges
            EdgesByType = $this.Statistics.EdgesByType
            TotalPackages = $this.GetNodesByType("Package").Count
            TotalTasks = $this.GetNodesByType("Executable").Count
            TotalDataFlows = $this.GetNodesByType("DataFlowTask").Count
            TotalComponents = $this.GetNodesByType("Component").Count
            TotalColumns = $this.GetNodesByType("Column").Count
        }
    }

    [string] ToString() {
        $stats = $this.GetStatistics()
        return "LineageGraph: $($stats.TotalNodes) nodes, $($stats.TotalEdges) edges"
    }
}

# ============================================================================
# EXPORT TO SUMMARY
# ============================================================================

Write-Verbose @"
✓ SSIS Lineage Data Model Classes Loaded:
  - LineageNode (base class)
  - LineageEdge (relationship)
  - LineageGraph (container)

  Specialized Node Types (8):
  - PackageNode
  - ExecutableNode
  - DataFlowTaskNode
  - ComponentNode
  - ColumnNode
  - ConnectionNode
  - TableNode
  - ParameterNode

Ready for parser implementation (Phase 1A).
"@
