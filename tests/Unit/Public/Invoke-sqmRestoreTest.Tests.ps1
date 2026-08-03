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
