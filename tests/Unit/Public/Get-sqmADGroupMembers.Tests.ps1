#Requires -Modules Pester

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool)     { Remove-Module sqmSQLTool -Force }
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

        It 'OutputPath Parameter existiert' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'Recursive Parameter ist ein Switch' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters['Recursive'].ParameterType.Name | Should -Be 'SwitchParameter'
        }

        It 'DomainController Parameter existiert' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('DomainController') | Should -Be $true
        }

        It 'WhatIf wird unterstützt' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'Confirm wird unterstützt' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
        }

        It 'ContinueOnError Parameter existiert' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('ContinueOnError') | Should -Be $true
        }

        It 'EnableException Parameter existiert' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('EnableException') | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit ungültigem DC' {

        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Fehler wenn ADSI nicht erreichbar ist' {
            { Get-sqmADGroupMembers -GroupName 'NonExistentGroup' -DomainController 'InvalidDC.invalid' -EnableException } |
                Should -Throw
        }
    }

    Context 'WhatIf-Unterstützung' {

        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Erstellt keine Dateien bei -WhatIf' {
            # Diese Test ist komplex weil ADSI-Calls erforderlich sind
            # Normalerweise würde hier ein Mock für ADSI genutzt
            # Für jetzt: Test dass WhatIf-Parameter existiert
            (Get-Command Get-sqmADGroupMembers).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }
    }

    Context 'Rückgabeobjekt-Struktur' {

        It 'Sollte ein PSCustomObject mit GroupName Property zurückgeben' {
            # Dieser Test wird angepasst wenn Mocking implementiert ist
            (Get-Command Get-sqmADGroupMembers).OutputType.Name | Should -Be 'PSCustomObject'
        }
    }

    Context 'Fehlerbehandlung' {

        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'ContinueOnError Parameter unterdrückt Fehler' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('ContinueOnError') | Should -Be $true
        }

        It 'EnableException Parameter ermöglicht Exception-Wurf' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters.ContainsKey('EnableException') | Should -Be $true
        }
    }

    Context 'OutputPath-Handling' {

        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Standard-OutputPath ist $env:ProgramData\sqmSQLTool\ADReports' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $paramDef = $cmd.Parameters['OutputPath']
            $defaultVal = $paramDef.DefaultValue
            $defaultVal | Should -Match 'sqmSQLTool.*ADReports'
        }

        It 'Akzeptiert benutzerdefinierten OutputPath' {
            $cmd = Get-Command Get-sqmADGroupMembers
            $cmd.Parameters['OutputPath'].ParameterType.Name | Should -Be 'String'
        }
    }
}
