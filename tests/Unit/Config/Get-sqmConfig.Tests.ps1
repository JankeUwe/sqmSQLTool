#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmConfig
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmConfig' {

    Context 'Ohne Parameter' {
        It 'Gibt eine Hashtable zurueck' {
            $result = Get-sqmConfig
            $result | Should -BeOfType [hashtable]
        }

        It 'Hashtable enthaelt erwartete Schluessel' {
            $result = Get-sqmConfig
            $result.Keys | Should -Contain 'LogPath'
            $result.Keys | Should -Contain 'OutputPath'
            $result.Keys | Should -Contain 'OlaJobNameFull'
            $result.Keys | Should -Contain 'ModuleVersion'
            $result.Keys | Should -Contain 'AutoUpdate'
        }
    }

    Context 'Mit gueltigem -Key' {
        It 'Gibt den Wert von LogPath zurueck' {
            $result = Get-sqmConfig -Key 'LogPath'
            $result | Should -Not -BeNullOrEmpty
        }

        It 'Gibt den Wert von OlaJobNameFull zurueck' {
            $result = Get-sqmConfig -Key 'OlaJobNameFull'
            $result | Should -Not -BeNullOrEmpty
        }

        It 'Gibt Boolean fuer AutoUpdate zurueck' {
            $result = Get-sqmConfig -Key 'AutoUpdate'
            $result | Should -BeOfType [bool]
        }
    }

    Context 'Mit ungueltigem -Key' {
        It 'Gibt null zurueck' {
            $result = Get-sqmConfig -Key 'GibtEsNicht'
            $result | Should -BeNullOrEmpty
        }

        It 'Schreibt eine Warnung' {
            { Get-sqmConfig -Key 'GibtEsNicht' -WarningAction Stop } |
                Should -Throw
        }
    }
}
