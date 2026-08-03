#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Repair-sqmServerName (dbatools gemockt).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Repair-sqmServerName' {
    It 'Funktion existiert und unterstuetzt ShouldProcess' {
        $cmd = Get-Command Repair-sqmServerName
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.ContainsKey('WhatIf')  | Should -Be $true
        $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
        $cmd.Parameters.ContainsKey('Force')   | Should -Be $true
    }

    Context 'Bereits korrekt' {
        It 'meldet AlreadyCorrect, wenn RegisteredServerName bereits dem MachineName entspricht' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'SQL01'; MachineName = 'SQL01'; InstanceName = $null; IsClustered = 0 }
                }

                $r = Repair-sqmServerName -SqlInstance 'SQL01' -Confirm:$false

                $r.Status | Should -Be 'AlreadyCorrect'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -Times 0
            }
        }
    }

    Context 'Abweichung erkannt - Guard-Checks' {
        It 'blockiert bei IsClustered=1 ohne -Force' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'OLDNAME'; MachineName = 'NEWNAME'; InstanceName = $null; IsClustered = 1 }
                }

                $r = Repair-sqmServerName -SqlInstance 'SQL01' -Confirm:$false

                $r.Status | Should -Be 'Blocked'
                $r.Message | Should -Match 'Cluster'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -Times 0
            }
        }

        It 'blockiert bei AG-Mitgliedschaft ohne -Force' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'OLDNAME'; MachineName = 'NEWNAME'; InstanceName = $null; IsClustered = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.availability_replicas' -and $Query -match 'COUNT' } -MockWith {
                    [PSCustomObject]@{ Cnt = 1 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.availability_groups' } -MockWith {
                    [PSCustomObject]@{ name = 'AG_Prod' }
                }

                $r = Repair-sqmServerName -SqlInstance 'SQL01' -Confirm:$false

                $r.Status | Should -Be 'Blocked'
                $r.Message | Should -Match 'AG_Prod'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -Times 0
            }
        }

        It 'blockiert bei Replikationsrolle (Distributor/Publisher/Subscriber) ohne -Force' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'OLDNAME'; MachineName = 'NEWNAME'; InstanceName = $null; IsClustered = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.availability_replicas' -and $Query -match 'COUNT' } -MockWith {
                    [PSCustomObject]@{ Cnt = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'is_distributor' } -MockWith {
                    [PSCustomObject]@{ name = 'ReplDB' }
                }

                $r = Repair-sqmServerName -SqlInstance 'SQL01' -Confirm:$false

                $r.Status | Should -Be 'Blocked'
                $r.Message | Should -Match 'ReplDB'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -Times 0
            }
        }
    }

    Context 'Ausfuehrung (gemockt, keine Guard-Treffer)' {
        BeforeEach {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'OLDNAME'; MachineName = 'NEWNAME'; InstanceName = $null; IsClustered = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.availability_replicas' -and $Query -match 'COUNT' } -MockWith {
                    [PSCustomObject]@{ Cnt = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'is_distributor' } -MockWith { @() }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -MockWith { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_addserver' } -MockWith { }
            }
        }

        It 'aendert unter -WhatIf nichts (Status WhatIf, kein sp_dropserver/sp_addserver)' {
            InModuleScope sqmSQLTool {
                $r = Repair-sqmServerName -SqlInstance 'SQL01' -WhatIf

                $r.Status | Should -Be 'WhatIf'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -Times 0
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_addserver' } -Times 0
            }
        }

        It 'korrigiert den Servernamen und meldet Changed + RestartRequired' {
            InModuleScope sqmSQLTool {
                $r = Repair-sqmServerName -SqlInstance 'SQL01' -Confirm:$false

                $r.Status               | Should -Be 'Changed'
                $r.RestartRequired      | Should -Be $true
                $r.RegisteredServerName | Should -Be 'OLDNAME'
                $r.ExpectedServerName   | Should -Be 'NEWNAME'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -Times 1
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_addserver' } -Times 1
            }
        }

        It 'haengt \InstanceName an, wenn es sich um eine Named Instance handelt' {
            InModuleScope sqmSQLTool {
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'OLDNAME\INST01'; MachineName = 'NEWNAME'; InstanceName = 'INST01'; IsClustered = 0 }
                }

                $r = Repair-sqmServerName -SqlInstance 'SQL01\INST01' -Confirm:$false

                $r.ExpectedServerName | Should -Be 'NEWNAME\INST01'
                $r.Status             | Should -Be 'Changed'
            }
        }
    }

    Context '-Force ueberspringt die Guard-Checks' {
        It 'fuehrt die Korrektur trotz erkannter AG-Mitgliedschaft aus' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'OLDNAME'; MachineName = 'NEWNAME'; InstanceName = $null; IsClustered = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -MockWith { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_addserver' } -MockWith { }

                $r = Repair-sqmServerName -SqlInstance 'SQL01' -Force -Confirm:$false

                $r.Status | Should -Be 'Changed'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.availability_replicas' } -Times 0
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -Times 1
            }
        }
    }

    Context 'sp_addserver schlaegt nach erfolgreichem sp_dropserver fehl' {
        It 'meldet Status Error mit klarem Hinweis auf den fehlenden lokalen Server-Eintrag' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RegisteredServerName' } -MockWith {
                    [PSCustomObject]@{ RegisteredServerName = 'OLDNAME'; MachineName = 'NEWNAME'; InstanceName = $null; IsClustered = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.availability_replicas' -and $Query -match 'COUNT' } -MockWith {
                    [PSCustomObject]@{ Cnt = 0 }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'is_distributor' } -MockWith { @() }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_dropserver' } -MockWith { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sp_addserver' } -MockWith { throw 'boom' }

                $r = Repair-sqmServerName -SqlInstance 'SQL01' -Confirm:$false

                $r.Status  | Should -Be 'Error'
                $r.Message | Should -Match 'KEINEN lokalen Server-Eintrag'
            }
        }
    }
}
