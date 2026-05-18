#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmSysadminAccounts
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

Describe 'Get-sqmSysadminAccounts' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Get-sqmSysadminAccounts | Should -Not -BeNullOrEmpty
        }

        It 'SqlInstance ist nicht mandatory (Default = Computername)' {
            $cmd = Get-Command Get-sqmSysadminAccounts
            $mandatory = $cmd.Parameters['SqlInstance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $false
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmSysadminAccounts).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'WhatIf wird unterstuetzt' {
            (Get-Command Get-sqmSysadminAccounts).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'ExcludeLogin Parameter existiert' {
            (Get-Command Get-sqmSysadminAccounts).Parameters.ContainsKey('ExcludeLogin') | Should -Be $true
        }

        It 'ExcludeSysAccounts Parameter existiert' {
            (Get-Command Get-sqmSysadminAccounts).Parameters.ContainsKey('ExcludeSysAccounts') | Should -Be $true
        }

        It 'IncludeDisabled Parameter existiert' {
            (Get-Command Get-sqmSysadminAccounts).Parameters.ContainsKey('IncludeDisabled') | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance -Name 'TESTSERVER' }
            Mock -ModuleName sqmSQLTool Get-DbaLogin {
                @(
                    [PSCustomObject]@{
                        Name        = 'sa'
                        LoginType   = 'SqlLogin'
                        IsDisabled  = $false
                        HasAccess   = $true
                        IsSysAdmin  = $true
                    }
                    [PSCustomObject]@{
                        Name        = 'domain\DBA-Group'
                        LoginType   = 'WindowsGroup'
                        IsDisabled  = $false
                        HasAccess   = $true
                        IsSysAdmin  = $true
                    }
                )
            }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft ohne Fehler mit gemockten Daten durch' {
            { Get-sqmSysadminAccounts -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf } |
                Should -Not -Throw
        }

        It 'Erstellt keine Dateien bei -WhatIf' {
            Get-sqmSysadminAccounts -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf
            (Get-ChildItem $script:TestDir -File).Count | Should -Be 0
        }
    }

    Context 'SupportsShouldProcess' {
        It 'Funktion unterstuetzt ShouldProcess' {
            $cmd = Get-Command Get-sqmSysadminAccounts
            $cmd.Parameters.ContainsKey('WhatIf')   | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm')  | Should -Be $true
        }
    }
}
