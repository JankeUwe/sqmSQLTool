<#
.SYNOPSIS
    Simplified SSIS Lineage Parser PoC - Direct XML traversal

.DESCRIPTION
    Proof of Concept parser for Phase 1A that extracts basic lineage from SSIS packages
    using simple XML element traversal (no XPath).

.EXAMPLE
    $graph = Parse-SsisPackageSimple -PackagePath "C:\path\to\package.dtsx"

.NOTES
    Phase 1A PoC Implementation
    Simple XML traversal without XPath (PS 5.1 compatible)
#>

function Parse-SsisPackageSimple {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$PackagePath
    )

    if (-not (Test-Path $PackagePath)) {
        throw "Package not found: $PackagePath"
    }

    # Load classes
    $dmPath = 'C:\CMP\SQL-Tools\sqmSQLTool\04 Ressourcen\SSIS-Lineage-DataModel.ps1'
    if (Test-Path $dmPath) { . $dmPath }

    # Create graph
    $graph = [LineageGraph]::new()
    $graph.SourceProject = $PackagePath

    # Parse XML
    [xml]$xml = Get-Content $PackagePath -Raw -Encoding UTF8

    # Get root package node
    $root = $xml.DocumentElement
    $pkgName = $root.GetAttribute("DTS:ObjectName")

    $pkgNode = [PackageNode]::new($pkgName)
    $pkgNode.Id = $root.GetAttribute("DTS:DTSID")
    $pkgNode.Description = $root.GetAttribute("DTS:Description")
    $pkgNode.Creator = $root.GetAttribute("DTS:CreationName")

    $graph.AddNode($pkgNode)

    # Parse all Executable elements (tasks)
    foreach ($exec in $root.GetElementsByTagName("Executable")) {
        $execName = $exec.GetAttribute("DTS:ObjectName")
        if (-not $execName) { continue }

        $execType = $exec.GetAttribute("DTS:ExecutableType")

        # Create appropriate node type
        if ($execType -match "DataFlowTask") {
            $execNode = [DataFlowTaskNode]::new($execName)
        }
        else {
            $execNode = [ExecutableNode]::new($execName, $execType)
        }

        $execNode.Id = $exec.GetAttribute("DTS:DTSID")
        $execNode.Description = $exec.GetAttribute("DTS:Description")
        $execNode.PackageId = $pkgNode.Id

        $graph.AddNode($execNode)

        # Add edge: Package contains Executable
        $edge = [LineageEdge]::new($pkgNode, $execNode, "CONTAINS")
        $graph.AddEdge($edge)
    }

    # Parse ConnectionManagers
    foreach ($conn in $root.GetElementsByTagName("ConnectionManager")) {
        $connName = $conn.GetAttribute("DTS:ObjectName")
        if (-not $connName) { continue }

        $connNode = [ConnectionNode]::new($connName)
        $connNode.Id = $conn.GetAttribute("DTS:DTSID")
        $connNode.Provider = $conn.GetAttribute("DTS:CreationName")

        $graph.AddNode($connNode)
    }

    # Parse Variables
    foreach ($var in $root.GetElementsByTagName("Variable")) {
        $varName = $var.GetAttribute("DTS:ObjectName")
        if (-not $varName) { continue }

        $dataType = $var.GetAttribute("DTS:DataType")
        $paramNode = [ParameterNode]::new($varName, $dataType)
        $paramNode.Id = $var.GetAttribute("DTS:DTSID")
        $paramNode.Scope = "Package"

        $graph.AddNode($paramNode)
    }

    # Parse DtsComponents (inside DataFlowTasks)
    foreach ($comp in $root.GetElementsByTagName("DtsComponent")) {
        $compName = $comp.GetAttribute("DTS:ObjectName")
        if (-not $compName) { continue }

        $compType = $comp.GetAttribute("DTS:ComponentClassID")
        $compNode = [ComponentNode]::new($compName, $compType)
        $compNode.Id = $comp.GetAttribute("DTS:DTSID")

        $graph.AddNode($compNode)
    }

    # Parse OutputColumns
    foreach ($outCol in $root.GetElementsByTagName("OutputColumn")) {
        $colName = $outCol.GetAttribute("DTS:Name")
        if (-not $colName) { continue }

        $dataType = $outCol.GetAttribute("DTS:DataType")
        $colNode = [ColumnNode]::new($colName, $dataType)
        $colNode.Id = $outCol.GetAttribute("DTS:LineageID")
        $colNode.LineageId = $outCol.GetAttribute("DTS:LineageID")

        $graph.AddNode($colNode)
    }

    return $graph
}

Export-ModuleMember -Function Parse-SsisPackageSimple
