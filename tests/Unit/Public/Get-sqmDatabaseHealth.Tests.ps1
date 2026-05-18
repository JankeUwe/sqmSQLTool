#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmDatabaseHealth
    dbatools-Abhaengigkeiten werden vollstaendig gemockt.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmDatabaseHealth' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Get-sqmDatabaseHealth | Should -Not -BeNullOrEmpty
        }

        It 'SqlInstance ist nicht mandatory (Default = Computername)' {
            $cmd = Get-Command Get-sqmDatabaseHealth
            $mandatory = $cmd.Parameters['SqlInstance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $false
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmDatabaseHealth).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'WhatIf wird unterstuetzt' {
            (Get-Command Get-sqmDatabaseHealth).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'ExcludeDatabase Parameter existiert' {
            (Get-Command Get-sqmDatabaseHealth).Parameters.ContainsKey('ExcludeDatabase') | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools' {
        BeforeAll {
            # dbatools-Funktionen mocken
            Mock -ModuleName sqmSQLTool Connect-DbaInstance {
                New-MockSqlInstance -Name 'TESTSERVER'
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase {
                @(
                    New-MockDatabase -Name 'TestDB1' -Status 'Normal'     -RecoveryModel 'Full'
                    New-MockDatabase -Name 'TestDB2' -Status 'Normal'     -RecoveryModel 'Simple'
                    New-MockDatabase -Name 'TestDB3' -Status 'Restoring'  -RecoveryModel 'Full'
                )
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft ohne Fehler mit gemockten Daten' {
            { Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf } |
                Should -Not -Throw
        }

        It 'Erstellt keine Dateien bei -WhatIf' {
            Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf
            (Get-ChildItem $script:TestDir -File).Count | Should -Be 0
        }
    }

    Context 'Fehlerbehandlung' {
        It 'Wirft Fehler bei nicht erreichbarer Instanz (kein Mock)' {
            { Get-sqmDatabaseHealth -SqlInstance 'NICHT_ERREICHBAR_99999' -OutputPath $script:TestDir -EnableException -ErrorAction Stop } |
                Should -Throw
        }
    }
}
