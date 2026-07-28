#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die AG-Erkennung von Invoke-sqmRestoreDatabase und die private
    Hilfsfunktion Get-sqmDatabaseAgMembership. Alle SQL-Zugriffe sind gemockt.

.DESCRIPTION
    Hintergrund (1.9.27.0): die Erkennung lief ueber
    "Get-DbaAgDatabase ... -ErrorAction SilentlyContinue" und konnte damit "die Datenbank ist in
    keiner AG" nicht von "ich konnte es nicht feststellen" unterscheiden. Fehlende Rechte, eine
    stolpernde SMO-Enumeration oder die falsche Instanz lieferten dasselbe leere Ergebnis wie eine
    echte Standalone-Datenbank. Die Funktion uebersprang daraufhin das Entfernen aus der AG und
    scheiterte erst Schritte spaeter an ALTER DATABASE und RESTORE.

    Diese Tests halten genau diese Unterscheidung fest. Der wichtigste Fall ist
    "Mitgliedschaftsabfrage schlaegt fehl -> Ausnahme": geht der jemals wieder verloren, ist der
    Fehler von 2026-07-28 zurueck.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmDatabaseAgMembership' {

    It 'meldet HadrEnabled=false und bricht NICHT ab, wenn AlwaysOn nicht aktiviert ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery { [PSCustomObject]@{ HadrEnabled = 0 } }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.HadrEnabled  | Should -BeFalse
            $r.IsAgDatabase | Should -BeFalse
            $r.AvailabilityGroupName | Should -BeNullOrEmpty
        }
    }

    It 'meldet IsAgDatabase=false, wenn AlwaysOn aktiv ist, die Datenbank aber kein Mitglied ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { @() }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.HadrEnabled  | Should -BeTrue
            $r.IsAgDatabase | Should -BeFalse
        }
    }

    It 'erkennt die Mitgliedschaft samt AG-Name und Primary' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { [PSCustomObject]@{ AvailabilityGroupName = 'AG_Prod' } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } -MockWith { [PSCustomObject]@{ PrimaryReplica = 'NODE1' } }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.IsAgDatabase          | Should -BeTrue
            $r.AvailabilityGroupName | Should -Be 'AG_Prod'
            $r.PrimaryReplica        | Should -Be 'NODE1'
        }
    }

    It 'WIRFT, wenn die Mitgliedschaftsabfrage fehlschlaegt, statt "keine AG" zu melden' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { throw 'The SELECT permission was denied' }

            { Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb' } |
                Should -Throw -ExpectedMessage '*konnte nicht ermittelt werden*'
        }
    }

    It 'WIRFT, wenn schon der AlwaysOn-Status nicht ermittelbar ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery { throw 'Verbindung fehlgeschlagen' }

            { Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb' } |
                Should -Throw -ExpectedMessage '*konnte nicht ermittelt werden*'
        }
    }

    It 'liefert die Mitgliedschaft auch dann, wenn nur die Primary-Abfrage fehlschlaegt' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { [PSCustomObject]@{ AvailabilityGroupName = 'AG_Prod' } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } -MockWith { throw 'VIEW SERVER STATE denied' }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.IsAgDatabase   | Should -BeTrue
            $r.PrimaryReplica | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-sqmRestoreDatabase - AG-Erkennung' {

    It 'verwendet Get-sqmDatabaseAgMembership und nicht mehr Get-DbaAgDatabase' {
        $source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1" -Raw
        $source | Should -Match 'Get-sqmDatabaseAgMembership'
        # Get-DbaAgDatabase darf fuer die Erkennung nicht mehr verwendet werden - der Aufruf mit
        # unterdruecktem Fehler war die Ursache des Fehlverhaltens.
        $source | Should -Not -Match 'Get-DbaAgDatabase\s+-SqlInstance'
    }

    It 'bricht ab, bevor irgendetwas passiert, wenn die AG-Zugehoerigkeit nicht ermittelbar ist' {
        InModuleScope sqmSQLTool {
            $fakeBackup = Join-Path ([System.IO.Path]::GetTempPath()) 'sqmRestoreTest_dummy.bak'
            Set-Content -Path $fakeBackup -Value 'dummy' -Encoding Ascii

            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
            Mock Get-sqmDatabaseAgMembership { throw 'AG-Mitgliedschaft von "amb" konnte nicht ermittelt werden' }
            Mock Export-DbaUser { }
            Mock Restore-DbaDatabase { }

            {
                Invoke-sqmRestoreDatabase -SqlInstance 'SQL01' -BackupFile $fakeBackup `
                    -DatabaseName 'amb' -EnableException -Confirm:$false
            } | Should -Throw

            # Entscheidend: kein Schritt darf gelaufen sein. Genau das war der Fehler - der Lauf
            # kam bis zum User-Export und zum Restore, bevor SQL Server ihn abgewiesen hat.
            Should -Invoke Export-DbaUser -Times 0
            Should -Invoke Restore-DbaDatabase -Times 0

            Remove-Item $fakeBackup -ErrorAction SilentlyContinue
        }
    }
}
