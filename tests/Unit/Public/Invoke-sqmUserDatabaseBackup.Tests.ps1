#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die AG-Regel von Invoke-sqmUserDatabaseBackup: AG-Datenbanken nur und immer
    auf dem Primary sichern.

.DESCRIPTION
    Hintergrund: Bei lesbarem Secondary sicherten beide AG-Knoten dieselben Datenbanken in denselben
    Ordner. Erreichten sie eine Datenbank in derselben Sekunde, scheiterte einer mit OS-Fehler 32
    (gleicher Dateiname). Seit 1.9.166.0 werden AG-Datenbanken, deren lokales Replikat nicht Primary
    ist, immer uebersprungen - unabhaengig von der AG-Backup-Preference und von -CheckPreferredReplica.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmUserDatabaseBackup - AG-Datenbanken nur auf dem Primary' {

    BeforeEach {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Test-Path { $true }
            Mock Get-DbaDatabase {
                [PSCustomObject]@{ Name = 'AgDb';    IsAccessible = $true }
                [PSCustomObject]@{ Name = 'LocalDb'; IsAccessible = $true }
                [PSCustomObject]@{ Name = 'AgDb2';   IsAccessible = $true }
            }
            Mock Backup-DbaDatabase { }
        }
    }

    It 'ueberspringt AG-Datenbanken, deren lokales Replikat nicht Primary ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } {
                [PSCustomObject]@{ DatabaseName = 'AgDb' }
                [PSCustomObject]@{ DatabaseName = 'AgDb2' }
            }

            $result = Invoke-sqmUserDatabaseBackup -SqlInstance 'SQLB' -All -BackupPath 'C:\Backup\Usr-db' -Confirm:$false

            @($result | Where-Object Status -eq 'SkippedAgSecondary').DatabaseName | Sort-Object | Should -Be @('AgDb', 'AgDb2')
            @($result | Where-Object Status -eq 'Success').DatabaseName | Should -Be @('LocalDb')
            Should -Invoke Backup-DbaDatabase -Times 1 -Exactly
            Should -Invoke Backup-DbaDatabase -Times 0 -Exactly -ParameterFilter { $Database -like 'AgDb*' }
        }
    }

    It 'sichert auf dem Primary alle Datenbanken' {
        InModuleScope sqmSQLTool {
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } { }

            $result = Invoke-sqmUserDatabaseBackup -SqlInstance 'SQLA' -All -BackupPath 'C:\Backup\Usr-db' -Confirm:$false

            @($result | Where-Object Status -eq 'Success').Count | Should -Be 3
            Should -Invoke Backup-DbaDatabase -Times 3 -Exactly
        }
    }

    It '-CheckPreferredReplica bricht nicht mehr ab und warnt nur' {
        InModuleScope sqmSQLTool {
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } { }

            $result = Invoke-sqmUserDatabaseBackup -SqlInstance 'SQLA' -All -BackupPath 'C:\Backup\Usr-db' -CheckPreferredReplica -Confirm:$false

            @($result | Where-Object Status -eq 'Success').Count | Should -Be 3
            Should -Invoke Invoke-sqmLogging -ParameterFilter { $Level -eq 'WARNING' -and $Message -match 'CheckPreferredReplica' }
        }
    }

    It 'sichert ohne AG-Filter weiter, wenn die Rollenpruefung scheitert' {
        InModuleScope sqmSQLTool {
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } { throw 'connection lost' }

            $result = Invoke-sqmUserDatabaseBackup -SqlInstance 'SQLA' -All -BackupPath 'C:\Backup\Usr-db' -Confirm:$false

            @($result | Where-Object Status -eq 'Success').Count | Should -Be 3
            Should -Invoke Invoke-sqmLogging -ParameterFilter { $Level -eq 'WARNING' -and $Message -match 'AG-Rollenpruefung' }
        }
    }
}
