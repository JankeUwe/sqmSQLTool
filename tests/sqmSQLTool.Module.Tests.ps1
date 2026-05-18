#Requires -Modules Pester
<#
.SYNOPSIS
    Modul-Level Tests fuer sqmSQLTool
    Prueft: Import, Manifest, Funktionsexport, Konfigurationsinitialisierung
#>

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Modul-Import' {
    It 'Importiert ohne Fehler' {
        { Import-sqmTestModule } | Should -Not -Throw
    }

    It 'Ist nach Import geladen' {
        Get-Module sqmSQLTool | Should -Not -BeNullOrEmpty
    }

    It 'Hat korrekte ModuleVersion im Manifest' {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'sqmSQLTool.psd1')
        $manifest.ModuleVersion | Should -Match '^\d+\.\d+\.\d+'
    }

    It 'Exportiert nur Funktionen mit -sqm- Prefix' {
        $exported = (Get-Module sqmSQLTool).ExportedFunctions.Keys
        $invalid  = $exported | Where-Object { $_ -notmatch '-sqm' }
        $invalid | Should -BeNullOrEmpty
    }
}

Describe 'Funktionsexport' {
    It 'Alle Public/*.ps1 Funktionen sind exportiert' {
        $exported     = (Get-Module sqmSQLTool).ExportedFunctions.Keys
        $publicFuncs  = Get-sqmPublicFunctionNames | Where-Object { $_ -match '^(Get|Set|New|Invoke|Install|Copy|Remove|Repair|Sync|Test|Export|Find|Update)-sqm' }
        foreach ($func in $publicFuncs) {
            $exported | Should -Contain $func -Because "$func sollte exportiert sein"
        }
    }

    It 'Mindestens 60 Funktionen exportiert' {
        (Get-Module sqmSQLTool).ExportedFunctions.Count | Should -BeGreaterOrEqual 60
    }
}

Describe 'Modulkonfiguration' {
    It 'LogPath ist nach Import gesetzt' {
        Get-sqmConfig -Key 'LogPath' | Should -Not -BeNullOrEmpty
    }

    It 'OutputPath ist nach Import gesetzt' {
        Get-sqmConfig -Key 'OutputPath' | Should -Not -BeNullOrEmpty
    }

    It 'LogPath enthaelt keinen FI-TS spezifischen Pfad' {
        Get-sqmConfig -Key 'LogPath' | Should -Not -BeLike '*WinSrvLog*'
        Get-sqmConfig -Key 'LogPath' | Should -Not -BeLike '*FITS*'
    }

    It 'Ola Job-Namen enthalten kein FITS-Prefix' {
        $keys = @('OlaJobNameFull','OlaJobNameDiff','OlaJobNameLog',
                  'OlaJobNameSysDbBackup','OlaJobNameIndexOpt',
                  'OlaJobNameIntUserDb','OlaJobNameIntSysDb')
        foreach ($key in $keys) {
            Get-sqmConfig -Key $key | Should -Not -BeLike 'FITS*' -Because "$key sollte keinen FI-TS Prefix haben"
        }
    }

    It 'ModuleVersion entspricht Manifest-Version' {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'sqmSQLTool.psd1')
        Get-sqmConfig -Key 'ModuleVersion' | Should -Be $manifest.ModuleVersion
    }
}
