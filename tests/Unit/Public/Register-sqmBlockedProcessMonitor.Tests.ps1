#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Register-sqmBlockedProcessMonitor
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Register-sqmBlockedProcessMonitor' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Register-sqmBlockedProcessMonitor | Should -Not -BeNullOrEmpty
        }

        It 'IncludeFileTarget Parameter existiert' {
            (Get-Command Register-sqmBlockedProcessMonitor).Parameters.ContainsKey('IncludeFileTarget') | Should -Be $true
        }

        It 'WhatIf wird unterstuetzt' {
            (Get-Command Register-sqmBlockedProcessMonitor).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }
    }

    Context 'Session existiert noch nicht' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*sys.server_event_sessions*'
            } { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like 'CREATE EVENT SESSION*'
            } { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*STATE = START*'
            } { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'legt die Session an und meldet Action=Created' {
            $r = Register-sqmBlockedProcessMonitor -SqlInstance 'TESTSERVER' -Confirm:$false
            $r.Action | Should -Be 'Created'
            $r.SessionName | Should -Be 'sqm_BlockedProcessMonitor'
        }
    }

    Context 'Session existiert bereits und laeuft' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*sys.server_event_sessions*'
            } { @([PSCustomObject]@{ Found = 1 }) }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*sys.dm_xe_sessions*'
            } { @([PSCustomObject]@{ Running = 1 }) }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'meldet Action=Unchanged, ohne etwas anzulegen' {
            $r = Register-sqmBlockedProcessMonitor -SqlInstance 'TESTSERVER' -Confirm:$false
            $r.Action | Should -Be 'Unchanged'
        }
    }
}
