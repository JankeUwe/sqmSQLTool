<#
.SYNOPSIS
    Pester-Konfiguration fuer sqmSQLTool
    Aufruf: Invoke-Pester -Configuration (. .\tests\pester.config.ps1)
#>

$config = New-PesterConfiguration

# Testpfade
$config.Run.Path            = "$PSScriptRoot"
$config.Run.ExcludePath     = "$PSScriptRoot\Integration"  # Nur bei -Integration Flag ausfuehren

# Ausgabe
$config.Output.Verbosity    = 'Detailed'

# Code Coverage
$config.CodeCoverage.Enabled    = $true
$config.CodeCoverage.Path       = "$PSScriptRoot\..\Public\*.ps1"
$config.CodeCoverage.OutputPath = "$PSScriptRoot\..\tests\coverage.xml"
$config.CodeCoverage.OutputFormat = 'JaCoCo'

# Testresultate
$config.TestResult.Enabled      = $true
$config.TestResult.OutputPath   = "$PSScriptRoot\testresults.xml"
$config.TestResult.OutputFormat = 'NUnitXml'

return $config
