#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Unlock-sqmSqlLogin
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Unlock-sqmSqlLogin' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Unlock-sqmSqlLogin | Should -Not -BeNullOrEmpty
        }

        It 'Login Parameter ist Mandatory' {
            (Get-Command Unlock-sqmSqlLogin).Parameters['Login'].Attributes.Mandatory | Should -Contain $true
        }

        It 'NewPassword Parameter existiert und ist SecureString' {
            (Get-Command Unlock-sqmSqlLogin).Parameters['NewPassword'].ParameterType.Name | Should -Be 'SecureString'
        }

        It 'Unterstuetzt -WhatIf' {
            (Get-Command Unlock-sqmSqlLogin).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }
    }

    Context 'Login existiert nicht' {
        It 'Meldet NotFound statt einen Fehler zu werfen' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'BadPasswordCount' } -MockWith { @() }

                $r = Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'ghost_user' -Confirm:$false

                $r.Status | Should -Be 'NotFound'
            }
        }
    }

    Context 'Login ist nicht gesperrt' {
        It 'Meldet AlreadyUnlocked und ruft kein CHECK_POLICY-Toggle auf' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'BadPasswordCount' } -MockWith {
                    [PSCustomObject]@{ IsDisabled = 0; IsPolicyChecked = 1; IsExpirationChecked = 1; IsLocked = 0; IsExpired = 0; BadPasswordCount = 0; LockoutTime = $null }
                }

                $r = Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'app_user' -Confirm:$false

                $r.Status | Should -Be 'AlreadyUnlocked'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'CHECK_POLICY = OFF' } -Times 0
            }
        }
    }

    Context 'Gesperrter Login - nur entsperren (kein NewPassword)' {
        BeforeEach {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'BadPasswordCount' } -MockWith {
                    [PSCustomObject]@{ IsDisabled = 0; IsPolicyChecked = 1; IsExpirationChecked = 1; IsLocked = 1; IsExpired = 0; BadPasswordCount = 5; LockoutTime = (Get-Date) }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'CHECK_POLICY = OFF' } -MockWith { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'PASSWORD = @newpwd' } -MockWith { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -notmatch 'BadPasswordCount' -and $Query -match 'IsLocked' -and $Query -notmatch 'ALTER' } -MockWith {
                    [PSCustomObject]@{ IsPolicyChecked = 1; IsExpirationChecked = 1; IsLocked = 0 }
                }
            }
        }

        It 'Entsperrt per CHECK_POLICY-Toggle, ohne das Passwort anzufassen' {
            InModuleScope sqmSQLTool {
                $r = Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'app_user' -Confirm:$false

                $r.Status          | Should -Be 'Success'
                $r.PasswordChanged | Should -Be $false
                $r.IsLockedNow     | Should -Be $false
                $r.CheckPolicy     | Should -Be $true
                $r.CheckExpiration | Should -Be $true
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'CHECK_POLICY = OFF' } -Times 1
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'PASSWORD = @newpwd' } -Times 0
            }
        }

        It 'Aendert unter -WhatIf nichts' {
            InModuleScope sqmSQLTool {
                $r = Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'app_user' -WhatIf

                $r.Status | Should -Be 'WhatIfSkipped'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'CHECK_POLICY = OFF' } -Times 0
            }
        }
    }

    Context 'Gesperrter Login - Passwort-Reset mit -NewPassword' {
        BeforeEach {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'BadPasswordCount' } -MockWith {
                    [PSCustomObject]@{ IsDisabled = 0; IsPolicyChecked = 1; IsExpirationChecked = 1; IsLocked = 1; IsExpired = 0; BadPasswordCount = 5; LockoutTime = (Get-Date) }
                }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'PASSWORD = @newpwd' } -MockWith { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -notmatch 'BadPasswordCount' -and $Query -match 'IsLocked' -and $Query -notmatch 'ALTER' } -MockWith {
                    [PSCustomObject]@{ IsPolicyChecked = 1; IsExpirationChecked = 1; IsLocked = 0 }
                }
            }
        }

        It 'Setzt das Passwort zurueck, entsperrt, und CHECK_POLICY/CHECK_EXPIRATION bleiben unveraendert' {
            InModuleScope sqmSQLTool {
                $securePw = ConvertTo-SecureString 'NewC0mplex!Pw' -AsPlainText -Force
                $r = Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'app_user' -NewPassword $securePw -Confirm:$false

                $r.Status          | Should -Be 'Success'
                $r.PasswordChanged | Should -Be $true
                $r.CheckPolicy     | Should -Be $true
                $r.CheckExpiration | Should -Be $true
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'PASSWORD = @newpwd' -and $Query -notmatch 'MUST_CHANGE' } -Times 1
            }
        }

        It 'Haengt MUST_CHANGE an, wenn -MustChange gesetzt ist' {
            InModuleScope sqmSQLTool {
                $securePw = ConvertTo-SecureString 'NewC0mplex!Pw' -AsPlainText -Force
                $r = Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'app_user' -NewPassword $securePw -MustChange -Confirm:$false

                $r.Status | Should -Be 'Success'
                Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'MUST_CHANGE' } -Times 1
            }
        }
    }

    Context '-MustChange ohne -NewPassword' {
        It 'Wirft einen Fehler statt still zu ignorieren' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                { Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'app_user' -MustChange -Confirm:$false } | Should -Throw
            }
        }
    }

    Context '-MustChange, aber CHECK_EXPIRATION ist auf dem Login OFF' {
        It 'Bricht mit klarer Fehlermeldung ab statt die rohe SQL-Fehlermeldung durchzureichen' {
            InModuleScope sqmSQLTool {
                Mock Invoke-sqmLogging { }
                Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'BadPasswordCount' } -MockWith {
                    [PSCustomObject]@{ IsDisabled = 0; IsPolicyChecked = 1; IsExpirationChecked = 0; IsLocked = 1; IsExpired = 0; BadPasswordCount = 5; LockoutTime = (Get-Date) }
                }

                $securePw = ConvertTo-SecureString 'NewC0mplex!Pw' -AsPlainText -Force
                { Unlock-sqmSqlLogin -SqlInstance 'SQL01' -Login 'app_user' -NewPassword $securePw -MustChange -Confirm:$false -EnableException } | Should -Throw '*CHECK_EXPIRATION*'
            }
        }
    }
}
