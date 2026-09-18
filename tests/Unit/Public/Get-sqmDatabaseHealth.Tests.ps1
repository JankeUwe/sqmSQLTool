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

    Context 'Backup-Ausschluss (sqm_BackupExclude)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance {
                New-MockSqlInstance -Name 'TESTSERVER'
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase {
                @(
                    New-MockDatabase -Name 'ExcludedDb' -Status 'Normal' -RecoveryModel 'Full'
                    New-MockDatabase -Name 'NormalDb'   -Status 'Normal' -RecoveryModel 'Full'
                )
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*sys.objects*sqm_BackupExclude*'
            } { @(1) }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like 'SELECT DatabaseName, Reason FROM master.dbo.sqm_BackupExclude*'
            } { @([PSCustomObject]@{ DatabaseName = 'ExcludedDb'; Reason = 'Read-Replika, Backup laeuft auf Primary' }) }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'markiert die in sqm_BackupExclude gelistete Datenbank als ausgeschlossen' {
            $r = Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            $rows = $r.DetailRows
            ($rows | Where-Object Database -eq 'ExcludedDb').ExcludedFromBackup | Should -Be $true
            ($rows | Where-Object Database -eq 'ExcludedDb').ExcludeReason | Should -Be 'Read-Replika, Backup laeuft auf Primary'
        }

        It 'laesst nicht gelistete Datenbanken unmarkiert' {
            $r = Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            ($r.DetailRows | Where-Object Database -eq 'NormalDb').ExcludedFromBackup | Should -Be $false
        }

        It 'schreibt den Ausschluss-Hinweis und die Spalte in den HTML-Bericht' {
            $r = Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            $html = Get-Content $r.HtmlFile -Raw
            $html | Should -Match 'Backup-Ausschluss'
            $html | Should -Match 'Ausgeschlossen'
        }
    }

    Context 'COPY_ONLY-Backups und Groessenformatierung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance {
                New-MockSqlInstance -Name 'TESTSERVER'
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase {
                @(
                    New-MockDatabase -Name 'CopyOnlyDb' -Status 'Normal' -RecoveryModel 'Full' -Size 12345.6
                    New-MockDatabase -Name 'RegularDb'  -Status 'Normal' -RecoveryModel 'Full' -Size 512
                )
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*msdb.dbo.backupset*'
            } {
                @(
                    # CopyOnlyDb hat NUR ein COPY_ONLY-Full
                    [PSCustomObject]@{ database_name = 'CopyOnlyDb'; type = 'D'; is_copy_only = $true;  LastBackup = [datetime]'2026-09-18 06:18:00' }
                    # RegularDb hat beides - das regulaere Full gewinnt
                    [PSCustomObject]@{ database_name = 'RegularDb';  type = 'D'; is_copy_only = $false; LastBackup = [datetime]'2026-09-17 22:00:00' }
                    [PSCustomObject]@{ database_name = 'RegularDb';  type = 'D'; is_copy_only = $true;  LastBackup = [datetime]'2026-09-18 06:18:00' }
                )
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'meldet ein reines COPY_ONLY-Full nicht als "(keins)"' {
            $r = Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            $row = $r.DetailRows | Where-Object Database -eq 'CopyOnlyDb'
            $row.LastFullBackup   | Should -Be '(nur COPY_ONLY: 2026-09-18 06:18)'
            $row.LastCopyOnlyFull | Should -Be '2026-09-18 06:18'
        }

        It 'bevorzugt das regulaere Full, wenn beides vorhanden ist' {
            $r = Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            $row = $r.DetailRows | Where-Object Database -eq 'RegularDb'
            $row.LastFullBackup   | Should -Be '2026-09-17 22:00'
            $row.LastCopyOnlyFull | Should -Be '2026-09-18 06:18'
        }

        It 'schreibt die COPY_ONLY-Spalte und den Hinweis in die Berichte' {
            $r = Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            $html = Get-Content $r.HtmlFile -Raw
            $html | Should -Match 'Nur COPY_ONLY'
            (Get-Content $r.TxtFile -Raw) | Should -Match 'Nur COPY_ONLY-Full vorhanden'
        }

        It 'gibt die Groesse rechtsbuendig mit Tausendertrennung aus' {
            $r = Get-sqmDatabaseHealth -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            $html = Get-Content $r.HtmlFile -Raw
            $expected = '{0:N1}' -f 12345.6   # kulturabhaengig, genau wie im Bericht
            $html | Should -BeLike "*<td class='num'>$expected</td>*"
            $html | Should -Match "th class='num'>SizeMB"
        }
    }

    Context 'Fehlerbehandlung' {
        It 'Wirft Fehler bei nicht erreichbarer Instanz (kein Mock)' {
            { Get-sqmDatabaseHealth -SqlInstance 'NICHT_ERREICHBAR_99999' -OutputPath $script:TestDir -EnableException -ErrorAction Stop } |
                Should -Throw
        }
    }
}
