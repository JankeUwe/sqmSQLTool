#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmDatabaseRestoreHistory
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

Describe 'Get-sqmDatabaseRestoreHistory' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Get-sqmDatabaseRestoreHistory | Should -Not -BeNullOrEmpty
        }

        It 'SqlInstance ist nicht mandatory (Default = Computername)' {
            $cmd = Get-Command Get-sqmDatabaseRestoreHistory
            $mandatory = $cmd.Parameters['SqlInstance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $false
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmDatabaseRestoreHistory).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'WhatIf wird unterstuetzt' {
            (Get-Command Get-sqmDatabaseRestoreHistory).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'ExcludeDatabase Parameter existiert' {
            (Get-Command Get-sqmDatabaseRestoreHistory).Parameters.ContainsKey('ExcludeDatabase') | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance {
                New-MockSqlInstance -Name 'TESTSERVER'
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase {
                @(
                    New-MockDatabase -Name 'TestDB1' -Status 'Normal' -RecoveryModel 'Full'
                    New-MockDatabase -Name 'TestDB2' -Status 'Normal' -RecoveryModel 'Simple'
                    New-MockDatabase -Name 'TestDB3' -Status 'Normal' -RecoveryModel 'Full'
                )
            }
            # TestDB1 wurde restauriert, TestDB2/TestDB3 tauchen bewusst NICHT in der
            # Restore-Historie auf - genau der Fall, den die Funktion trotzdem sichtbar machen soll.
            Mock -ModuleName sqmSQLTool Get-DbaDbRestoreHistory {
                @(
                    [PSCustomObject]@{
                        Database    = 'TestDB1'
                        Username    = 'DOMAIN\dba'
                        RestoreType = 'Database'
                        Date	    = (Get-Date).AddDays(-3)
                        From	    = 'F:\Backup\TestDB1.bak'
                    }
                )
            }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft ohne Fehler mit gemockten Daten' {
            { Get-sqmDatabaseRestoreHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf } |
                Should -Not -Throw
        }

        It 'Erstellt keine Dateien bei -WhatIf' {
            Get-sqmDatabaseRestoreHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf
            (Get-ChildItem $script:TestDir -File).Count | Should -Be 0
        }

        It 'Listet auch Datenbanken ohne Restore-Historie explizit als "nie restauriert"' {
            $result = Get-sqmDatabaseRestoreHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -Confirm:$false
            $rows = $result.DetailRows

            $rows.Count | Should -Be 3

            $db1 = $rows | Where-Object Database -eq 'TestDB1'
            $db1.LastRestoreDate | Should -Not -BeNullOrEmpty
            $db1.RestoreType | Should -Be 'Database'
            $db1.RestoredBy | Should -Be 'DOMAIN\dba'

            $db2 = $rows | Where-Object Database -eq 'TestDB2'
            $db2.LastRestoreDate | Should -BeNullOrEmpty
            $db2.RestoreType | Should -Be '(nie restauriert)'
        }

        It 'Schreibt CSV/TXT/HTML-Berichte ohne -WhatIf' {
            Get-sqmDatabaseRestoreHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -Confirm:$false | Out-Null
            (Get-ChildItem $script:TestDir -Filter 'DatabaseRestoreHistory_*.csv').Count | Should -BeGreaterThan 0
            (Get-ChildItem $script:TestDir -Filter 'DatabaseRestoreHistory_*.txt').Count | Should -BeGreaterThan 0
            (Get-ChildItem $script:TestDir -Filter 'DatabaseRestoreHistory_*.html').Count | Should -BeGreaterThan 0
        }
    }

    Context 'Fehlerbehandlung' {
        It 'Wirft Fehler bei nicht erreichbarer Instanz (kein Mock)' {
            { Get-sqmDatabaseRestoreHistory -SqlInstance 'NICHT_ERREICHBAR_99999' -OutputPath $script:TestDir -EnableException -ErrorAction Stop } |
                Should -Throw
        }
    }
}
