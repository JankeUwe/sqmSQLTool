#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Stop-sqmSqlProcess
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

Describe 'Stop-sqmSqlProcess' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Stop-sqmSqlProcess | Should -Not -BeNullOrEmpty
        }

        It 'Spid Parameter ist Mandatory' {
            (Get-Command Stop-sqmSqlProcess).Parameters['Spid'].Attributes.Mandatory | Should -Contain $true
        }

        It 'NotifyOwner Parameter existiert und ist ein Switch' {
            (Get-Command Stop-sqmSqlProcess).Parameters['NotifyOwner'].ParameterType.Name | Should -Be 'SwitchParameter'
        }

        It 'Unterstuetzt -WhatIf' {
            (Get-Command Stop-sqmSqlProcess).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }
    }

    Context 'Kill ohne Benachrichtigung (Default)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @([PSCustomObject]@{
                        Spid         = 62
                        LoginName    = 'domain\user1'
                        HostName     = 'WORKSTATION01'
                        ProgramName  = 'SSMS'
                        DatabaseName = 'TestDB'
                        Status       = 'running'
                    })
            }
            Mock -ModuleName sqmSQLTool Stop-DbaProcess { }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Killt die SPID ohne Fehler und ohne msg.exe aufzurufen' {
            $result = Stop-sqmSqlProcess -SqlInstance 'TESTSERVER' -Spid 62 -Confirm:$false
            $result.KillStatus | Should -Be 'Success'
            $result.NotifyStatus | Should -Be 'Skipped'
        }

        It 'Ruft Stop-DbaProcess mit der richtigen SPID auf' {
            Stop-sqmSqlProcess -SqlInstance 'TESTSERVER' -Spid 62 -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Stop-DbaProcess -ParameterFilter { $Spid -eq 62 }
        }
    }

    Context 'Unbekannte SPID' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Stop-DbaProcess { }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Meldet NotFound statt einen Fehler zu werfen' {
            $result = Stop-sqmSqlProcess -SqlInstance 'TESTSERVER' -Spid 999 -Confirm:$false
            $result.KillStatus | Should -Be 'NotFound'
            $result.NotifyStatus | Should -Be 'Skipped'
        }
    }

    Context 'NotifyOwner ohne bekannten Hostnamen' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @([PSCustomObject]@{
                        Spid         = 71
                        LoginName    = 'AppService'
                        HostName     = $null
                        ProgramName  = 'App'
                        DatabaseName = 'TestDB'
                        Status       = 'running'
                    })
            }
            Mock -ModuleName sqmSQLTool Stop-DbaProcess { }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Ueberspringt die Benachrichtigung statt msg.exe ohne Ziel aufzurufen' {
            $result = Stop-sqmSqlProcess -SqlInstance 'TESTSERVER' -Spid 71 -NotifyOwner -Confirm:$false
            $result.KillStatus | Should -Be 'Success'
            $result.NotifyStatus | Should -Be 'Skipped'
        }
    }

    Context 'NotifyOwner mit bekanntem Hostnamen' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @([PSCustomObject]@{
                        Spid         = 62
                        LoginName    = 'domain\user1'
                        HostName     = 'WORKSTATION01'
                        ProgramName  = 'SSMS'
                        DatabaseName = 'TestDB'
                        Status       = 'running'
                    })
            }
            Mock -ModuleName sqmSQLTool Stop-DbaProcess { }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Meldet Success, wenn Send-sqmWtsMessage zustellt' {
            Mock -ModuleName sqmSQLTool Send-sqmWtsMessage {
                [PSCustomObject]@{ ComputerName = 'WORKSTATION01'; WasDelivered = $true; SessionIds = @(1); Error = $null }
            }
            $result = Stop-sqmSqlProcess -SqlInstance 'TESTSERVER' -Spid 62 -NotifyOwner -Confirm:$false
            $result.KillStatus | Should -Be 'Success'
            $result.NotifyStatus | Should -Be 'Success'
        }

        It 'Meldet Failed statt zu werfen, wenn Send-sqmWtsMessage nicht zustellt' {
            Mock -ModuleName sqmSQLTool Send-sqmWtsMessage {
                [PSCustomObject]@{ ComputerName = 'WORKSTATION01'; WasDelivered = $false; SessionIds = @(); Error = 'Keine aktive interaktive Sitzung.' }
            }
            $result = Stop-sqmSqlProcess -SqlInstance 'TESTSERVER' -Spid 62 -NotifyOwner -Confirm:$false
            $result.KillStatus | Should -Be 'Success'
            $result.NotifyStatus | Should -Be 'Failed'
        }
    }

    Context 'WhatIf' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @([PSCustomObject]@{
                        Spid         = 62
                        LoginName    = 'domain\user1'
                        HostName     = 'WORKSTATION01'
                        ProgramName  = 'SSMS'
                        DatabaseName = 'TestDB'
                        Status       = 'running'
                    })
            }
            Mock -ModuleName sqmSQLTool Stop-DbaProcess { }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Killt nichts, wenn -WhatIf gesetzt ist' {
            $result = Stop-sqmSqlProcess -SqlInstance 'TESTSERVER' -Spid 62 -WhatIf
            $result.KillStatus | Should -Be 'WhatIf'
            Should -Invoke -ModuleName sqmSQLTool Stop-DbaProcess -Times 0
        }
    }
}
