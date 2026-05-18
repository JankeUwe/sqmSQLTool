# =============================================================================
# TestHelpers.ps1 — Gemeinsame Infrastruktur fuer alle sqmSQLTool Pester-Tests
# =============================================================================

# Modulpfad relativ zum tests/-Verzeichnis
$script:ModuleRoot = Split-Path $PSScriptRoot -Parent
$script:ModulePath = Join-Path $script:ModuleRoot 'sqmSQLTool.psm1'

# ---------------------------------------------------------------------------
# Hilfsfunktion: Modul frisch laden (isoliert, ohne AutoUpdate)
# ---------------------------------------------------------------------------
function Import-sqmTestModule {
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = '1'
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Alle oeffentlichen PS1-Funktionsnamen aus Public/ lesen
# ---------------------------------------------------------------------------
function Get-sqmPublicFunctionNames {
    Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' |
        Where-Object { $_.Name -notmatch 'TempPoint|Kopie|Copy' } |
        ForEach-Object { $_.BaseName }
}

# ---------------------------------------------------------------------------
# Mock-Factories fuer dbatools-Rueckgaben
# ---------------------------------------------------------------------------
function New-MockSqlInstance {
    param([string]$Name = 'TESTSERVER')
    [PSCustomObject]@{
        Name          = $Name
        ComputerName  = $Name
        InstanceName  = 'MSSQLSERVER'
        SqlInstance   = $Name
        IsConnected   = $true
    }
}

function New-MockDatabase {
    param(
        [string]$Name   = 'TestDB',
        [string]$Status = 'Normal',
        [string]$RecoveryModel = 'Full'
    )
    [PSCustomObject]@{
        Name          = $Name
        Status        = $Status
        RecoveryModel = $RecoveryModel
        SizeMB        = 1024
        SqlInstance   = 'TESTSERVER'
    }
}

# ---------------------------------------------------------------------------
# Temp-Verzeichnis fuer Output-Tests
# ---------------------------------------------------------------------------
function New-TempTestDirectory {
    $path = Join-Path $env:TEMP "sqmSQLTool_Test_$(Get-Random)"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
