#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmBlockingReport
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

Describe 'Get-sqmBlockingReport' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Get-sqmBlockingReport | Should -Not -BeNullOrEmpty
        }

        It 'MinWaitSeconds Parameter existiert' {
            (Get-Command Get-sqmBlockingReport).Parameters.ContainsKey('MinWaitSeconds') | Should -Be $true
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmBlockingReport).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @([PSCustomObject]@{
                    BlockedSpid      = 55
                    BlockingSpid     = 42
                    WaitTimeSeconds  = 30
                    DatabaseName     = 'TestDB'
                    BlockedQuery     = 'SELECT * FROM dbo.Test'
                    BlockingQuery    = 'UPDATE dbo.Test SET Col=1'
                    BlockedLoginName = 'domain\user1'
                })
            }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft ohne Fehler mit gemockten Daten durch' {
            { Get-sqmBlockingReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir } |
                Should -Not -Throw
        }
    }
}
