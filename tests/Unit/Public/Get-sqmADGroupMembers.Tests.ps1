#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmADGroupMembers (Parameter-Contract).
    Reine Metadaten-Pruefung - keine Live-ADSI-Aufrufe (CI-tauglich).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmADGroupMembers' {

    Context 'Parameter-Validierung' {

        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Get-sqmADGroupMembers | Should -Not -BeNullOrEmpty
        }

        It 'GroupName ist Mandatory' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters['GroupName'].Attributes.Where{ $_.TypeId.Name -eq 'ParameterAttribute' }.Mandatory | Should -Be $true
        }

        It 'GroupName akzeptiert Pipeline-Input' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters['GroupName'].Attributes.Where{ $_.TypeId.Name -eq 'ParameterAttribute' }.ValueFromPipeline | Should -Be $true
        }

        It 'GroupName Parameter ist vom Typ string[]' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters['GroupName'].ParameterType.Name | Should -Match 'string'
        }

        It 'Domain Parameter existiert' {
            (Get-Command Get-sqmADGroupMembers).Parameters.ContainsKey('Domain') | Should -Be $true
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmADGroupMembers).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'WhatIf wird unterstützt' {
            (Get-Command Get-sqmADGroupMembers).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'Confirm wird unterstützt' {
            (Get-Command Get-sqmADGroupMembers).Parameters.ContainsKey('Confirm') | Should -Be $true
        }
    }

    Context 'Rückgabeobjekt-Struktur' {

        It 'Deklariert PSCustomObject als OutputType' {
            (Get-Command Get-sqmADGroupMembers).OutputType.Name | Should -Match 'PSObject'
        }
    }

    Context 'OutputPath-Handling' {

        It 'OutputPath ist vom Typ String' {
            (Get-Command Get-sqmADGroupMembers).Parameters['OutputPath'].ParameterType.Name | Should -Be 'String'
        }
    }
}
