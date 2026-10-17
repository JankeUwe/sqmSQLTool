#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Test-sqmOlaInstallation, Find-sqmDatabaseObject, Get-sqmLinkedServerUsage,
    Test-sqmBackupIntegrity und Remove-sqmDatabaseFromAG.
    dbatools wird gemockt; geprueft werden Auswertung, gebaute SQL-Abfragen (Escaping, Klammerung)
    und dass -WhatIf bzw. Fehler nichts loeschen.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
}

AfterAll {
    Remove-Variable -Name SqmQueries -Scope Global -ErrorAction SilentlyContinue
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Test-sqmOlaInstallation' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { [pscustomobject]@{ JobServer = [pscustomobject]@{ ServiceStatus = 'Running' } } }
    }

    It 'erkennt eine vollstaendige Backup-Installation mit laufendem Agent' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [pscustomobject]@{ cnt = 1 } }
        $r = Test-sqmOlaInstallation -SqlInstance 'SQL01'
        $r.IsInstalled | Should -BeTrue
        $r.AgentRunning | Should -BeTrue
        $r.PresentObjects | Should -Be @('DatabaseBackup')
        $r.Warnings | Should -BeNullOrEmpty
    }

    It 'meldet fehlende Prozedur und fehlende CommandLog-Tabelle' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [pscustomobject]@{ cnt = 0 } }
        $r = Test-sqmOlaInstallation -SqlInstance 'SQL01'
        $r.IsInstalled | Should -BeFalse
        $r.Message | Should -Match 'DatabaseBackup'
        $r.Warnings | Should -Match 'CommandLog'
    }

    It 'prueft je nach -RequiredSet weitere Prozeduren' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [pscustomobject]@{ cnt = 1 } }
        (Test-sqmOlaInstallation -SqlInstance 'SQL01' -RequiredSet Integrity).PresentObjects |
            Should -Be @('DatabaseBackup', 'DatabaseIntegrityCheck')
        (Test-sqmOlaInstallation -SqlInstance 'SQL01' -RequiredSet Index).PresentObjects |
            Should -Be @('DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize')
    }

    It 'AgentRunning ist false, wenn der Agent steht' {
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { [pscustomobject]@{ JobServer = [pscustomobject]@{ ServiceStatus = 'Stopped' } } }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [pscustomobject]@{ cnt = 1 } }
        (Test-sqmOlaInstallation -SqlInstance 'SQL01').AgentRunning | Should -BeFalse
    }

    It 'meldet einen Verbindungsfehler in Message' {
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { throw 'timeout' }
        $r = Test-sqmOlaInstallation -SqlInstance 'SQL01' -ErrorAction SilentlyContinue
        $r.IsInstalled | Should -BeFalse
        $r.Message | Should -Match 'timeout'
    }
}

Describe 'Find-sqmDatabaseObject' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase {
            @([pscustomobject]@{ Name = 'Sales' }, [pscustomobject]@{ Name = 'Hr' }, [pscustomobject]@{ Name = 'Sales2' })
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ("$Database" -ne 'Hr')
            {
                [pscustomobject]@{ DatabaseName = "$Database"; SchemaName = 'dbo'; ObjectName = 'Orders'; ObjectType = 'USER_TABLE'; DefinitionPreview = $null }
            }
        }
    }

    It 'sucht in allen passenden Datenbanken und liefert die Treffer' {
        $r = @(Find-sqmDatabaseObject -SqlInstance 'SQL01' -ObjectName 'Orders')
        $r.Count | Should -Be 2
        $r.Database | Should -Be @('Sales', 'Sales2')
        $r[0].SqlInstance | Should -Be 'SQL01'
    }

    It '-Database filtert per Wildcard' {
        $r = @(Find-sqmDatabaseObject -SqlInstance 'SQL01' -ObjectName 'Orders' -Database 'Sales2')
        $r.Database | Should -Be @('Sales2')
    }

    It 'verdoppelt Hochkommas im Suchbegriff und in -ObjectType' {
        Find-sqmDatabaseObject -SqlInstance 'SQL01' -ObjectName "O'Brien" -ObjectType "A'B", 'USER_TABLE' | Out-Null
        $q = $global:SqmQueries[0]
        $q | Should -Match "LIKE 'O''Brien'"
        $q | Should -Match "IN \('A''B','USER_TABLE'\)"
    }

    It 'klammert bei -SearchDefinition die OR-Bedingung, damit -ObjectType fuer beide Teile gilt' {
        Find-sqmDatabaseObject -SqlInstance 'SQL01' -ObjectName 'x' -SearchDefinition -ObjectType 'SQL_STORED_PROCEDURE' | Out-Null
        $q = $global:SqmQueries[0]
        $q | Should -Match "WHERE \(o\.name LIKE 'x' OR m\.definition LIKE '%x%'\)\s+AND type_desc IN"
    }

    It 'ohne -SearchDefinition wird die Definition nicht durchsucht' {
        Find-sqmDatabaseObject -SqlInstance 'SQL01' -ObjectName 'x' | Out-Null
        $global:SqmQueries[0] | Should -Not -Match 'm\.definition LIKE'
    }

    It 'schluckt Fehler einzelner Datenbanken, wirft sie aber mit -EnableException' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'offline' }
        { Find-sqmDatabaseObject -SqlInstance 'SQL01' -ObjectName 'x' } | Should -Not -Throw
        { Find-sqmDatabaseObject -SqlInstance 'SQL01' -ObjectName 'x' -EnableException } | Should -Throw '*offline*'
    }
}

Describe 'Get-sqmLinkedServerUsage' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Get-Module { [pscustomobject]@{ Name = 'dbatools' } } -ParameterFilter { $ListAvailable }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase { @([pscustomobject]@{ Name = 'Sales' }) }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*sys.sql_modules*')
            {
                [pscustomobject]@{ DatabaseName = 'Sales'; SchemaName = 'dbo'; ObjectName = 'usp_Load'; ObjectType = 'SQL_STORED_PROCEDURE' }
            }
            elseif ($Query -like '*sysjobsteps*')
            {
                [pscustomobject]@{ job_id = 'job-1'; step_name = 'Step 1'; command = 'SELECT * FROM [LS1].db.dbo.t' }
            }
        }
        Mock -ModuleName sqmSQLTool Get-DbaAgentJob { [pscustomobject]@{ Id = 'job-1'; Name = 'Nightly load' } }
    }

    It 'wandelt * in % um und liefert Modul-Treffer' {
        $r = @(Get-sqmLinkedServerUsage -SqlInstance 'SQL01' -LinkedServer 'LS*')
        $global:SqmQueries[0] | Should -Match "LIKE '%LS%%'"
        $r.Count | Should -Be 1
        $r[0].ObjectName | Should -Be 'usp_Load'
    }

    It 'verdoppelt Hochkommas im Namen des Linked Servers' {
        Get-sqmLinkedServerUsage -SqlInstance 'SQL01' -LinkedServer "L'S" | Out-Null
        $global:SqmQueries[0] | Should -Match "LIKE '%L''S%'"
    }

    It '-IncludeJobs ergaenzt Jobschritte mit dem Jobnamen' {
        $r = @(Get-sqmLinkedServerUsage -SqlInstance 'SQL01' -LinkedServer 'LS1' -IncludeJobs)
        $step = $r | Where-Object ObjectType -eq 'JOBSTEP'
        $step.ObjectName | Should -Be 'Nightly load'
        $step.Database | Should -Be 'msdb'
    }

    It 'ohne -IncludeJobs wird msdb nicht abgefragt' {
        Get-sqmLinkedServerUsage -SqlInstance 'SQL01' -LinkedServer 'LS1' | Out-Null
        $global:SqmQueries | Where-Object { $_ -like '*sysjobsteps*' } | Should -BeNullOrEmpty
    }
}

Describe 'Test-sqmBackupIntegrity' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { $null }
    }

    It 'verifiziert jede angegebene Sicherung' {
        Mock -ModuleName sqmSQLTool Restore-DbaDatabase { }
        $r = @(Test-sqmBackupIntegrity -SqlInstance 'SQL01' -BackupPath 'C:\b\a.bak', 'C:\b\b.bak')
        $r.Count | Should -Be 2
        $r.Verified | Should -Be @($true, $true)
        Should -Invoke -ModuleName sqmSQLTool Restore-DbaDatabase -Times 2 -Exactly -ParameterFilter { $VerifyOnly }
    }

    It 'meldet eine kaputte Sicherung als nicht verifiziert und macht weiter' {
        Mock -ModuleName sqmSQLTool Restore-DbaDatabase { throw 'Backup beschaedigt' } -ParameterFilter { $Path -like '*bad.bak' }
        Mock -ModuleName sqmSQLTool Restore-DbaDatabase { } -ParameterFilter { $Path -like '*good.bak' }
        $r = @(Test-sqmBackupIntegrity -SqlInstance 'SQL01' -BackupPath 'C:\b\bad.bak', 'C:\b\good.bak')
        ($r | Where-Object BackupFile -like '*bad.bak').Verified | Should -BeFalse
        ($r | Where-Object BackupFile -like '*bad.bak').Message | Should -Match 'beschaedigt'
        ($r | Where-Object BackupFile -like '*good.bak').Verified | Should -BeTrue
    }

    It '-EnableException wirft beim ersten Fehler' {
        Mock -ModuleName sqmSQLTool Restore-DbaDatabase { throw 'kaputt' }
        { Test-sqmBackupIntegrity -SqlInstance 'SQL01' -BackupPath 'C:\b\a.bak' -EnableException } | Should -Throw '*kaputt*'
    }

    It '-FileListOnly liest nur den Header und rechnet die Groesse um' {
        Mock -ModuleName sqmSQLTool Restore-DbaDatabase { }
        Mock -ModuleName sqmSQLTool Read-DbaBackupHeader {
            [pscustomobject]@{ LogicalName = 'Sales'; PhysicalName = 'D:\Sales.mdf'; Type = 'D'; FileGroupName = 'PRIMARY'; Size = 2048 }
        }
        $r = Test-sqmBackupIntegrity -SqlInstance 'SQL01' -BackupPath 'C:\b\a.bak' -FileListOnly
        $r.LogicalName | Should -Be 'Sales'
        $r.SizeMB | Should -Be 2
        Should -Invoke -ModuleName sqmSQLTool Restore-DbaDatabase -Times 0 -Exactly
    }

    It 'nimmt den Pfad aus der Modulkonfiguration' {
        Mock -ModuleName sqmSQLTool Get-sqmConfig { 'E:\Backup' } -ParameterFilter { $Key -eq 'BackupDirectory' }
        Mock -ModuleName sqmSQLTool Restore-DbaDatabase { }
        (Test-sqmBackupIntegrity -SqlInstance 'SQL01').BackupFile | Should -Be 'E:\Backup'
    }

    It 'faellt auf das Sicherungsverzeichnis der Instanz zurueck' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [pscustomobject]@{ BackupDirectory = 'F:\SqlBackup' } }
        Mock -ModuleName sqmSQLTool Restore-DbaDatabase { }
        (Test-sqmBackupIntegrity -SqlInstance 'SQL01').BackupFile | Should -Be 'F:\SqlBackup'
    }

    It 'bricht ab, wenn nirgends ein Pfad zu finden ist' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'kein Zugriff' }
        { Test-sqmBackupIntegrity -SqlInstance 'SQL01' } | Should -Throw '*BackupPath*'
    }
}

Describe 'Remove-sqmDatabaseFromAG' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { [pscustomobject]@{ Name = 'AG1' } }
        Mock -ModuleName sqmSQLTool Get-DbaAgDatabase {
            if ("$Database" -eq 'Orphan') { return }
            [pscustomobject]@{ Name = if ($Database) { "$Database" } else { 'Sales' }; AvailabilityGroupName = 'AG1' }
        }
        Mock -ModuleName sqmSQLTool Get-DbaAgReplica {
            @(
                [pscustomobject]@{ Name = 'SQL01'; AvailabilityGroupName = 'AG1'; Role = 'Primary' }
                [pscustomobject]@{ Name = 'SQL02'; AvailabilityGroupName = 'AG1'; Role = 'Secondary' }
                [pscustomobject]@{ Name = 'SQL03'; AvailabilityGroupName = 'AG2'; Role = 'Secondary' }
            )
        }
        Mock -ModuleName sqmSQLTool Remove-DbaAgDatabase { }
        Mock -ModuleName sqmSQLTool Remove-DbaDatabase { }
    }

    It 'nimmt die Datenbank aus der AG und loescht sie nur auf den Secondaries derselben AG' {
        $r = @(Remove-sqmDatabaseFromAG -SqlInstance 'SQL01' -Database 'Sales' -Confirm:$false)
        ($r.Status) | Should -Be @('RemovedFromAG', 'DroppedOnSecondary')
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaAgDatabase -Times 1 -Exactly
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaDatabase -Times 1 -Exactly -ParameterFilter { "$SqlInstance" -eq 'SQL02' }
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaDatabase -Times 0 -Exactly -ParameterFilter { "$SqlInstance" -in 'SQL01', 'SQL03' }
    }

    It 'meldet NotInAG fuer Datenbanken ausserhalb einer AG und aendert nichts' {
        $r = Remove-sqmDatabaseFromAG -SqlInstance 'SQL01' -Database 'Orphan' -Confirm:$false
        $r.Status | Should -Be 'NotInAG'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaAgDatabase -Times 0 -Exactly
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaDatabase -Times 0 -Exactly
    }

    It '-WhatIf entfernt und loescht nichts' {
        $r = @(Remove-sqmDatabaseFromAG -SqlInstance 'SQL01' -Database 'Sales' -WhatIf)
        $r.Status | Should -Be 'RemoveSkipped'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaAgDatabase -Times 0 -Exactly
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaDatabase -Times 0 -Exactly
    }

    It 'loescht die Secondary-Kopie nicht, wenn das Entfernen aus der AG scheitert' {
        Mock -ModuleName sqmSQLTool Remove-DbaAgDatabase { throw 'AG nicht erreichbar' }
        $r = @(Remove-sqmDatabaseFromAG -SqlInstance 'SQL01' -Database 'Sales' -Confirm:$false)
        $r.Status | Should -Be 'RemoveFromAGFailed'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaDatabase -Times 0 -Exactly
    }

    It '-EnableException wirft statt Fehlerzeile' {
        Mock -ModuleName sqmSQLTool Remove-DbaAgDatabase { throw 'AG nicht erreichbar' }
        { Remove-sqmDatabaseFromAG -SqlInstance 'SQL01' -Database 'Sales' -Confirm:$false -EnableException } |
            Should -Throw '*AG nicht erreichbar*'
    }

    It 'ohne -All und ohne -Database kommt ein GlobalError' {
        $r = Remove-sqmDatabaseFromAG -SqlInstance 'SQL01' -Confirm:$false
        $r.Status | Should -Be 'GlobalError'
        $r.Message | Should -Match 'Weder -All noch -Database'
    }

    It 'meldet eine Warnung ohne Verfuegbarkeitsgruppen' {
        Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { }
        $r = Remove-sqmDatabaseFromAG -SqlInstance 'SQL01' -Database 'Sales' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        "$w" | Should -Match 'Keine Verfuegbarkeitsgruppen'
    }
}
