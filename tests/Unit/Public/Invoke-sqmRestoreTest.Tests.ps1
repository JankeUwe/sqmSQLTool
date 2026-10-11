#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die -DatabaseName-Aufloesung von Invoke-sqmRestoreTest.

.DESCRIPTION
    Hintergrund: -DatabaseName war unbedingt Mandatory, obwohl der Name bei Angabe von
    -BackupFile bereits im Backup selbst steht (RESTORE HEADERONLY) - PowerShell fragte den
    Namen deshalb immer interaktiv ab, selbst wenn -BackupFile mitgegeben wurde. Angeglichen an
    Invoke-sqmRestoreDatabase, das denselben Fall schon immer aus dem Backup-Header loest.
    -DatabaseName bleibt erforderlich, wenn -BackupFile FEHLT, da der Name dort als Suchschluessel
    fuer die msdb-Sicherungshistorie dient und es keinen anderen Weg gibt, das Backup zu finden.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmRestoreTest - DatabaseName-Aufloesung' {

    It '-DatabaseName ist nicht mehr Mandatory (Voraussetzung dafuer, dass -BackupFile allein reicht)' {
        $cmd = Get-Command Invoke-sqmRestoreTest
        $param = $cmd.Parameters['DatabaseName']
        $isMandatory = ($param.ParameterSets.Values | ForEach-Object { $_.IsMandatory }) -contains $true
        $isMandatory | Should -BeFalse
    }

    It 'liest -DatabaseName aus dem Backup-Header, wenn nur -BackupFile angegeben ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RESTORE HEADERONLY' } -MockWith {
                [PSCustomObject]@{ DatabaseName = 'KundeAutoDetected' }
            }
            # Sentinel statt vollem Restore-Pfad: sobald Connect-DbaInstance erreicht wird, steht
            # fest, dass die Guards (Praefix/Zielname) mit dem aufgeloesten Namen bereits
            # durchlaufen sind - die eigentliche Fragestellung (wurde der Name ueberhaupt
            # aufgeloest, statt nach ihm zu fragen) ist damit beantwortet.
            Mock Connect-DbaInstance { throw 'SENTINEL_REACHED_CONNECT' }

            {
                Invoke-sqmRestoreTest -SqlInstance 'SQL01' -BackupFile 'D:\Backup\Kunde_Full.bak' `
                    -EnableException -Confirm:$false
            } | Should -Throw -ExpectedMessage '*SENTINEL_REACHED_CONNECT*'

            Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'RESTORE HEADERONLY' } -Times 1
        }
    }

    It 'lehnt fehlenden -DatabaseName OHNE -BackupFile ab, bevor ueberhaupt eine Verbindung aufgebaut wird' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { throw 'DARF_NICHT_AUFGERUFEN_WERDEN' }

            $result = Invoke-sqmRestoreTest -SqlInstance 'SQL01' -Confirm:$false

            $result.Status | Should -Be 'Rejected'
            Should -Invoke Connect-DbaInstance -Times 0
        }
    }

    It '-DatabaseName weiterhin nutzbar, wenn explizit angegeben (kein Header-Lookup noetig)' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RESTORE HEADERONLY' } -MockWith {
                throw 'HEADER LOOKUP HAETTE NICHT LAUFEN DUERFEN'
            }
            Mock Connect-DbaInstance { throw 'SENTINEL_REACHED_CONNECT' }

            {
                Invoke-sqmRestoreTest -SqlInstance 'SQL01' -BackupFile 'D:\Backup\Kunde_Full.bak' -DatabaseName 'Kunde' `
                    -EnableException -Confirm:$false
            } | Should -Throw -ExpectedMessage '*SENTINEL_REACHED_CONNECT*'

            Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'RESTORE HEADERONLY' } -Times 0
        }
    }
}

Describe 'Get-sqmBackupHeaderSize - Stripes, angehaengte Saetze, Kette' {
    # Hintergrund (v1.9.164.0): Restore-DbaDatabase meldet bei gestripten Backups nur den Anteil
    # EINER Stripe-Datei; der Nachweis zeigte Datenmenge/Durchsatz um den Faktor der Stripe-Anzahl
    # zu klein. Die Groesse kommt jetzt aus dem Header - und zwar nur fuer die restaurierten Saetze.

    It 'zaehlt nur den restaurierten Satz (FILE = n) und je Satz nur einmal' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            # Medium mit zwei angehaengten Saetzen (NOINIT); jede Stripe-Datei liefert beide
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'RESTORE HEADERONLY' } -MockWith {
                [PSCustomObject]@{ Position = 1; BackupSetGUID = 'g1'; BackupSize = 7000; CompressedBackupSize = 600 }
                [PSCustomObject]@{ Position = 2; BackupSetGUID = 'g2'; BackupSize = 8000; CompressedBackupSize = 700 }
            }
            $files = @('D:\B\db-1-of-3.bak', 'D:\B\db-2-of-3.bak', 'D:\B\db-3-of-3.bak')
            $row = [PSCustomObject]@{
                BackupFileRaw = $files
                Script = "RESTORE DATABASE [x] FROM DISK = N'D:\B\db-1-of-3.bak', DISK = N'D:\B\db-2-of-3.bak', DISK = N'D:\B\db-3-of-3.bak' WITH FILE = 2, NOUNLOAD"
            }

            $r = Get-sqmBackupHeaderSize -Server 'SQL01' -Files $files -RestoreRows @($row)

            $r.BackupSizeBytes | Should -Be 8000
            $r.CompressedBackupSizeBytes | Should -Be 700
            $r.SetCount | Should -Be 1
        }
    }

    It 'summiert eine Kette ueber die Dateien aus dem jeweiligen Skript, nicht aus BackupFileRaw' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'full-1' } -MockWith {
                [PSCustomObject]@{ Position = 1; BackupSetGUID = 'full'; BackupSize = 7000; CompressedBackupSize = 600 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'diff-1' } -MockWith {
                [PSCustomObject]@{ Position = 1; BackupSetGUID = 'diff'; BackupSize = 2000; CompressedBackupSize = 100 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'log\.trn' } -MockWith {
                [PSCustomObject]@{ Position = 1; BackupSetGUID = 'log'; BackupSize = 1000; CompressedBackupSize = 50 } }
            $all = @('D:\B\full-1.bak', 'D:\B\full-2.bak', 'D:\B\diff-1.bak', 'D:\B\diff-2.bak', 'D:\B\log.trn')
            $rows = @(
                [PSCustomObject]@{ BackupFileRaw = $all; Script = "RESTORE DATABASE [x] FROM DISK = N'D:\B\full-1.bak', DISK = N'D:\B\full-2.bak' WITH FILE = 1" }
                [PSCustomObject]@{ BackupFileRaw = $all; Script = "RESTORE DATABASE [x] FROM DISK = N'D:\B\diff-1.bak', DISK = N'D:\B\diff-2.bak' WITH FILE = 1" }
                [PSCustomObject]@{ BackupFileRaw = $all; Script = "RESTORE LOG [x] FROM DISK = N'D:\B\log.trn' WITH FILE = 1" }
            )

            $r = Get-sqmBackupHeaderSize -Server 'SQL01' -Files $all -RestoreRows $rows

            $r.BackupSizeBytes | Should -Be 10000
            $r.SetCount | Should -Be 3
        }
    }
}
