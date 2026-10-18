#Requires -Modules Pester
<#
.SYNOPSIS
    Vertragstest: ein process-Block darf nicht dieselbe Ergebnisliste zurueckgeben, die der end-Block
    ebenfalls zurueckgibt.
.DESCRIPTION
    Funktionen mit begin/process/end sammeln Ergebnisse in $results und geben sie im end-Block aus. Ein
    vorzeitiges "return $results" im process-Block gibt die Liste zusaetzlich aus: der Aufrufer bekommt
    jedes Ergebnis doppelt (aufgefallen bei Import-sqmDatabaseLogins ohne Login-Bloecke; dasselbe Muster
    steckte in sieben weiteren Funktionen). Im process-Block genuegt ein blosses "return".
#>

BeforeDiscovery {
    $script:publicDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Public'
    $script:files = Get-ChildItem $script:publicDir -Filter '*.ps1' | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } }
}

Describe 'process/end Ausgabe' {
    It '<Name>: process-Block gibt nicht dieselbe Liste aus wie der end-Block' -ForEach $script:files {
        $tok = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$errs)
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | Select-Object -First 1
        $dups = @()
        if ($fn -and $fn.Body.EndBlock -and $fn.Body.ProcessBlock)
        {
            $returnAst = [System.Management.Automation.Language.ReturnStatementAst]
            $endRet = @($fn.Body.EndBlock.FindAll({ $args[0] -is $returnAst -and $args[0].Pipeline }, $true) |
                    ForEach-Object { $_.Pipeline.Extent.Text })
            foreach ($r in $fn.Body.ProcessBlock.FindAll({ $args[0] -is $returnAst -and $args[0].Pipeline }, $true))
            {
                $p = $r.Parent; $nested = $false
                while ($p -and $p -ne $fn.Body.ProcessBlock)
                {
                    if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $nested = $true; break }
                    $p = $p.Parent
                }
                if (-not $nested -and $r.Pipeline.Extent.Text -in $endRet) { $dups += "Zeile $($r.Extent.StartLineNumber): $($r.Extent.Text)" }
            }
        }
        $dups | Should -BeNullOrEmpty
    }
}
