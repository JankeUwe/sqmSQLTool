#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Move-sqmDatabaseFile

.DESCRIPTION
    Geprueft wird vor allem, was NICHT passieren darf: kein ALTER DATABASE, wenn eine Vorpruefung
    scheitert, kein Offline-Setzen einer AG-Datenbank, kein Entfernen alter Dateien, solange der
    neue Ort nicht bestaetigt ist. Genau dort entscheidet sich, ob ein Dateiumzug eine Instanz
    stehen laesst oder nicht.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Move-sqmDatabaseFile - Vertrag' {

    It 'Funktion existiert und ist exportiert' {
        Get-Command Move-sqmDatabaseFile -Module sqmSQLTool | Should -Not -BeNullOrEmpty
    }

    It 'Database ist Mandatory' {
        (Get-Command Move-sqmDatabaseFile).Parameters['Database'].Attributes.Mandatory | Should -Contain $true
    }

    It 'FileDestination ist Mandatory' {
        (Get-Command Move-sqmDatabaseFile).Parameters['FileDestination'].Attributes.Mandatory | Should -Contain $true
    }

    It 'Unterstuetzt -WhatIf' {
        (Get-Command Move-sqmDatabaseFile).Parameters.ContainsKey('WhatIf') | Should -Be $true
    }

    It 'FileType laesst nur All/Data/Log zu' {
        $set = (Get-Command Move-sqmDatabaseFile).Parameters['FileType'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $set.ValidValues | Should -Be @('All', 'Data', 'Log')
    }

    It 'Nutzt nicht Move-DbaDbFile (lehnt Systemdatenbanken ab)' {
        $source = Get-Content "$PSScriptRoot\..\..\..\Public\Move-sqmDatabaseFile.ps1" -Raw
        $source | Should -Not -Match 'Move-DbaDbFile\s+-SqlInstance'
    }
}

Describe 'Move-sqmDatabaseFile - Sperren vor jeder Aenderung' {

    It 'lehnt master ab und setzt kein ALTER DATABASE ab' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'master' -FileDestination 'G:\Data' -Confirm:$false

            $r.Status | Should -Contain 'Blocked'
            ($r | Where-Object Status -eq 'Blocked').Message | Should -BeLike '*Startparameter*'
            Should -Not -Invoke Invoke-DbaQuery
        }
    }

    It 'lehnt -NoRestart fuer msdb ab (Pfad umgetragen, Datei noch am alten Ort)' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'msdb' -FileDestination 'G:\Data' -NoRestart -Confirm:$false

            $r.Status | Should -Contain 'Blocked'
            Should -Not -Invoke Invoke-DbaQuery
        }
    }

    It 'bricht bei einer AG-Datenbank ab, ohne sie offline zu setzen' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith {
                [PSCustomObject]@{ DbName = 'SalesDB'; StateDesc = 'ONLINE'; IsReadOnly = $false; SourceDatabaseId = $null }
            }
            Mock Get-sqmDatabaseAgMembership {
                [PSCustomObject]@{ HadrEnabled = $true; IsAgDatabase = $true; AvailabilityGroupName = 'AG_Prod'; PrimaryReplica = 'SQL01' }
            }
            Mock Set-DbaDbState { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'SalesDB' -FileDestination 'G:\Data' -Confirm:$false

            $r.Status | Should -Contain 'Blocked'
            ($r | Where-Object Status -eq 'Blocked').Message | Should -BeLike '*AG_Prod*'
            Should -Not -Invoke Set-DbaDbState
        }
    }

    It 'bricht ab, wenn die AG-Frage gar nicht beantwortet werden kann' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith {
                [PSCustomObject]@{ DbName = 'SalesDB'; StateDesc = 'ONLINE'; IsReadOnly = $false; SourceDatabaseId = $null }
            }
            Mock Get-sqmDatabaseAgMembership { throw 'VIEW ANY DEFINITION denied' }
            Mock Set-DbaDbState { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'SalesDB' -FileDestination 'G:\Data' -Confirm:$false

            $r.Status | Should -Contain 'Blocked'
            Should -Not -Invoke Set-DbaDbState
        }
    }

    It 'bricht ab, wenn die Schreibprobe im Ziel scheitert - ohne ALTER DATABASE' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith {
                [PSCustomObject]@{ DbName = 'tempdb'; StateDesc = 'ONLINE'; IsReadOnly = $false; SourceDatabaseId = $null }
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.master_files' } -MockWith {
                [PSCustomObject]@{ FileId = 1; LogicalName = 'tempdev'; PhysicalName = 'C:\Data\tempdb.mdf'; TypeDesc = 'ROWS'; SizeMB = 512 }
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'CREATE DATABASE' } -MockWith { throw "Operating system error 5(Access is denied.)" }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'DROP DATABASE' } -MockWith { }
            Mock Test-DbaPath { $true }
            Mock Restart-DbaService { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -Confirm:$false

            ($r | Where-Object { $_.Step -eq 'Precheck' -and $_.Status -eq 'Failed' }).Message |
                Should -BeLike '*Schreibprobe*'
            $r.Status | Should -Contain 'Aborted'
            Should -Not -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'MODIFY FILE' }
            Should -Not -Invoke Restart-DbaService
        }
    }

    It 'bricht ab, wenn am Ziel zu wenig Platz frei ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith {
                [PSCustomObject]@{ DbName = 'tempdb'; StateDesc = 'ONLINE'; IsReadOnly = $false; SourceDatabaseId = $null }
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.master_files' } -MockWith {
                [PSCustomObject]@{ FileId = 1; LogicalName = 'tempdev'; PhysicalName = 'C:\Data\tempdb.mdf'; TypeDesc = 'ROWS'; SizeMB = 10000 }
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'xp_fixeddrives' } -MockWith {
                [PSCustomObject]@{ drive = 'G'; 'MB free' = 500 }
            }
            Mock Invoke-DbaQuery { }
            Mock Get-DbaDiskSpace { throw 'WMI nicht erreichbar' }
            Mock Test-DbaPath { $true }
            Mock Restart-DbaService { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -SkipWriteProbe -Confirm:$false

            ($r | Where-Object { $_.Step -eq 'Precheck' -and $_.Status -eq 'Failed' }).Message |
                Should -BeLike '*Zu wenig Platz*'
            Should -Not -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'MODIFY FILE' }
            Should -Not -Invoke Restart-DbaService
        }
    }

    It 'ueberspringt Dateien, die bereits am Ziel liegen' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith {
                [PSCustomObject]@{ DbName = 'tempdb'; StateDesc = 'ONLINE'; IsReadOnly = $false; SourceDatabaseId = $null }
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.master_files' } -MockWith {
                [PSCustomObject]@{ FileId = 1; LogicalName = 'tempdev'; PhysicalName = 'G:\TempDB\tempdb.mdf'; TypeDesc = 'ROWS'; SizeMB = 512 }
            }
            Mock Invoke-DbaQuery { }
            Mock Test-DbaPath { $true }
            Mock Restart-DbaService { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -Confirm:$false

            $r.Status | Should -Contain 'AlreadyInPlace'
            Should -Not -Invoke Restart-DbaService
        }
    }
}

Describe 'Move-sqmDatabaseFile - tempdb' {

    BeforeEach {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith {
                [PSCustomObject]@{ DbName = 'tempdb'; StateDesc = 'ONLINE'; IsReadOnly = $false; SourceDatabaseId = $null }
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.master_files' } -MockWith {
                @(
                    [PSCustomObject]@{ FileId = 1; LogicalName = 'tempdev'; PhysicalName = 'C:\Data\tempdb.mdf'; TypeDesc = 'ROWS'; SizeMB = 512 }
                    [PSCustomObject]@{ FileId = 2; LogicalName = 'templog'; PhysicalName = 'C:\Data\templog.ldf'; TypeDesc = 'LOG'; SizeMB = 128 }
                )
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'SELECT 1 AS Up' } -MockWith { [PSCustomObject]@{ Up = 1 } }
            Mock Test-DbaPath { $true }
            Mock Get-DbaDiskSpace {
                [PSCustomObject]@{ Name = 'G:\'; Free = [PSCustomObject]@{ Megabyte = 100000 } }
            }
            Mock Get-DbaService { [PSCustomObject]@{ State = 'Running'; StartName = 'NT Service\MSSQLSERVER' } }
            Mock Restart-DbaService { }
            Mock Start-DbaService { }
            Mock Stop-DbaService { }
            Mock Copy-Item { }
            Mock Remove-Item { }
            Mock Test-Path { $true }
        }
    }

    It 'traegt jede Datei per MODIFY FILE um, startet neu und entfernt die alten Dateien' {
        InModuleScope sqmSQLTool {
            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -Confirm:$false

            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'MODIFY FILE' -and $Query -match "NAME = N'tempdev'" -and $Query -match 'G:\\TempDB\\tempdb\.mdf'
            }
            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'MODIFY FILE' -and $Query -match "NAME = N'templog'"
            }
            Should -Invoke Restart-DbaService -Times 1 -Exactly
            # tempdb wird beim Start neu angelegt - es darf nichts kopiert werden
            Should -Not -Invoke Copy-Item
            Should -Invoke Remove-Item -Times 2 -Exactly

            ($r | Where-Object Step -eq 'Cleanup').Status | Should -Be @('Success', 'Success')
        }
    }

    It 'trennt Daten- und Logziel, wenn -LogFileDestination angegeben ist' {
        InModuleScope sqmSQLTool {
            $null = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' `
                -FileDestination 'G:\TempDB' -LogFileDestination 'H:\TempLog' -Confirm:$false

            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'MODIFY FILE' -and $Query -match 'H:\\TempLog\\templog\.ldf'
            }
        }
    }

    It 'verschiebt mit -LogicalFileName nur die genannte Datei' {
        InModuleScope sqmSQLTool {
            $null = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' `
                -FileDestination 'G:\TempDB' -LogicalFileName 'templog' -Confirm:$false

            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match 'MODIFY FILE' }
            Should -Invoke Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter {
                $Query -match 'MODIFY FILE' -and $Query -match "NAME = N'tempdev'"
            }
        }
    }

    It 'startet mit -NoRestart nicht neu und entfernt nichts' {
        InModuleScope sqmSQLTool {
            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -NoRestart -Confirm:$false

            $r.Status | Should -Contain 'PendingRestart'
            Should -Not -Invoke Restart-DbaService
            Should -Not -Invoke Remove-Item
        }
    }

    It 'laesst die alten Dateien mit -KeepOldFiles liegen' {
        InModuleScope sqmSQLTool {
            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -KeepOldFiles -Confirm:$false

            Should -Invoke Restart-DbaService -Times 1 -Exactly
            Should -Not -Invoke Remove-Item
            ($r | Where-Object Step -eq 'Cleanup').Status | Should -Be @('Skipped', 'Skipped')
        }
    }

    It 'entfernt keine alte Datei, wenn die neue nach dem Neustart fehlt' {
        InModuleScope sqmSQLTool {
            # Zielverzeichnis sichtbar, die neue Datei danach aber nicht
            Mock Test-DbaPath -ParameterFilter { $Path -match '\.(mdf|ldf)$' } -MockWith { $false }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -Confirm:$false

            Should -Not -Invoke Remove-Item
            ($r | Where-Object { $_.Step -eq 'Move' -and $_.Status -eq 'Failed' }).Count | Should -Be 2
        }
    }

    It 'meldet einen fehlgeschlagenen Neustart und raeumt nicht auf' {
        InModuleScope sqmSQLTool {
            Mock Restart-DbaService { throw 'Zugriff verweigert (WMI)' }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -Confirm:$false

            ($r | Where-Object { $_.Step -eq 'Restart' -and $_.Status -eq 'Failed' }).Message |
                Should -BeLike '*sys.master_files*'
            Should -Not -Invoke Remove-Item
        }
    }

    It 'aendert mit -WhatIf nichts' {
        InModuleScope sqmSQLTool {
            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'tempdb' -FileDestination 'G:\TempDB' -WhatIf

            $r.Status | Should -Contain 'WhatIfSkipped'
            Should -Not -Invoke Invoke-DbaQuery -ParameterFilter { $Query -match 'MODIFY FILE' }
            Should -Not -Invoke Restart-DbaService
            Should -Not -Invoke Remove-Item
        }
    }
}

Describe 'Move-sqmDatabaseFile - Benutzerdatenbank' {

    BeforeEach {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; IsClustered = $false } }
            Mock Invoke-DbaQuery { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith {
                [PSCustomObject]@{ DbName = 'SalesDB'; StateDesc = 'ONLINE'; IsReadOnly = $false; SourceDatabaseId = $null }
            }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.master_files' } -MockWith {
                [PSCustomObject]@{ FileId = 1; LogicalName = 'SalesDB'; PhysicalName = 'C:\Data\SalesDB.mdf'; TypeDesc = 'ROWS'; SizeMB = 2048 }
            }
            Mock Get-sqmDatabaseAgMembership {
                [PSCustomObject]@{ HadrEnabled = $false; IsAgDatabase = $false; AvailabilityGroupName = $null; PrimaryReplica = $null }
            }
            Mock Test-DbaPath { $true }
            Mock Get-DbaDiskSpace { [PSCustomObject]@{ Name = 'G:\'; Free = [PSCustomObject]@{ Megabyte = 100000 } } }
            Mock Set-DbaDbState { [PSCustomObject]@{ Status = 'OFFLINE' } }
            Mock Copy-Item { }
            Mock Get-Item { [PSCustomObject]@{ Length = 2147483648 } }
            Mock Remove-Item { }
            Mock Test-Path { $true }
            Mock Restart-DbaService { }
        }
    }

    It 'faehrt OFFLINE -> kopieren -> MODIFY FILE -> ONLINE und raeumt danach auf' {
        InModuleScope sqmSQLTool {
            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'SalesDB' -FileDestination 'G:\Data' -Confirm:$false

            Should -Invoke Set-DbaDbState -Times 1 -Exactly -ParameterFilter { $Offline -eq $true }
            Should -Invoke Copy-Item -Times 1 -Exactly
            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match 'MODIFY FILE' }
            Should -Invoke Set-DbaDbState -Times 1 -Exactly -ParameterFilter { $Online -eq $true }
            Should -Invoke Remove-Item -Times 1 -Exactly
            # Eine Benutzerdatenbank wird nie ueber einen Dienst-Neustart verschoben
            Should -Not -Invoke Restart-DbaService

            ($r | Where-Object { $_.Step -eq 'Move' -and $_.LogicalName -eq 'SalesDB' }).Status | Should -Be 'Success'
        }
    }

    It 'setzt den Pfad zurueck und raeumt nicht auf, wenn das Kopieren scheitert' {
        InModuleScope sqmSQLTool {
            Mock Copy-Item { throw 'Auf dem Datentraeger ist nicht genuegend Speicherplatz.' }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'SalesDB' -FileDestination 'G:\Data' -Confirm:$false

            ($r | Where-Object { $_.Step -eq 'Move' -and $_.Status -eq 'Failed' }).Message | Should -BeLike '*Speicherplatz*'
            Should -Not -Invoke Remove-Item
            # Datenbank muss trotzdem wieder online gehen
            Should -Invoke Set-DbaDbState -Times 1 -Exactly -ParameterFilter { $Online -eq $true }
        }
    }

    It 'setzt ein bereits umgetragenes MODIFY FILE zurueck, wenn eine spaetere Datei scheitert' {
        InModuleScope sqmSQLTool {
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.master_files' } -MockWith {
                @(
                    [PSCustomObject]@{ FileId = 1; LogicalName = 'SalesDB'; PhysicalName = 'C:\Data\SalesDB.mdf'; TypeDesc = 'ROWS'; SizeMB = 2048 }
                    [PSCustomObject]@{ FileId = 2; LogicalName = 'SalesDB_log'; PhysicalName = 'C:\Data\SalesDB_log.ldf'; TypeDesc = 'LOG'; SizeMB = 512 }
                )
            }
            $script:copyCount = 0
            Mock Copy-Item {
                $script:copyCount++
                if ($script:copyCount -ge 2) { throw 'Zugriff verweigert' }
            }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'SalesDB' -FileDestination 'G:\Data' -Confirm:$false

            $r.Status | Should -Contain 'RolledBack'
            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'MODIFY FILE' -and $Query -match 'C:\\Data\\SalesDB\.mdf'
            }
            Should -Not -Invoke Remove-Item
        }
    }

    It 'bricht ab, wenn die Datenbank nicht offline gesetzt werden kann' {
        InModuleScope sqmSQLTool {
            Mock Set-DbaDbState { throw 'Database is in use' }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'SalesDB' -FileDestination 'G:\Data' -Confirm:$false

            ($r | Where-Object Status -eq 'Failed').Message | Should -BeLike '*offline*'
            Should -Not -Invoke Copy-Item
            Should -Not -Invoke Remove-Item
        }
    }

    It 'meldet eine nicht existierende Datenbank als NotFound' {
        InModuleScope sqmSQLTool {
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'sys\.databases' } -MockWith { }

            $r = Move-sqmDatabaseFile -SqlInstance 'SQL01' -Database 'GibtsNicht' -FileDestination 'G:\Data' -Confirm:$false

            $r.Status | Should -Contain 'NotFound'
            Should -Not -Invoke Copy-Item
        }
    }
}
