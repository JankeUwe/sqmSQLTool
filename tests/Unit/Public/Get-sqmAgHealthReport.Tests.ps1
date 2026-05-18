#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmAgHealthReport
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

Describe 'Get-sqmAgHealthReport' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Get-sqmAgHealthReport | Should -Not -BeNullOrEmpty
        }

        It 'SqlInstance ist nicht mandatory (Default = Computername)' {
            $cmd = Get-Command Get-sqmAgHealthReport
            $mandatory = $cmd.Parameters['SqlInstance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $false
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmAgHealthReport).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'WhatIf wird unterstuetzt' {
            (Get-Command Get-sqmAgHealthReport).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'MaxRedoQueueMB Parameter existiert' {
            (Get-Command Get-sqmAgHealthReport).Parameters.ContainsKey('MaxRedoQueueMB') | Should -Be $true
        }

        It 'MaxSendQueueMB Parameter existiert' {
            (Get-Command Get-sqmAgHealthReport).Parameters.ContainsKey('MaxSendQueueMB') | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance -Name 'TESTSERVER' }
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup {
                @([PSCustomObject]@{
                    Name              = 'TestAG'
                    PrimaryReplica    = 'TESTSERVER'
                    HealthState       = 'Healthy'
                    SynchronizationState = 'Synchronized'
                })
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft ohne Fehler mit gemockten Daten durch' {
            { Get-sqmAgHealthReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf } |
                Should -Not -Throw
        }

        It 'Erstellt keine Dateien bei -WhatIf' {
            Get-sqmAgHealthReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf
            (Get-ChildItem $script:TestDir -File).Count | Should -Be 0
        }
    }

    Context 'SupportsShouldProcess' {
        It 'Funktion unterstuetzt ShouldProcess' {
            $cmd = Get-Command Get-sqmAgHealthReport
            $cmd.Parameters.ContainsKey('WhatIf')   | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm')  | Should -Be $true
        }
    }
}
