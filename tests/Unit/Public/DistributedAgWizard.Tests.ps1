#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer den Distributed-AG-Migrationsassistenten: Fehlerklassifizierung, Eingabepruefung,
    Zustand und Sperre, Vorabpruefung, Schritt-Executor, Failover-Ablauf und Trockenlauf.
    dbatools (Invoke-DbaQuery) wird vollstaendig gemockt, es wird nie ein Server angesprochen.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:StateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dagwiz-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
}

AfterAll {
    if ($script:StateDir -and (Test-Path $script:StateDir)) { Remove-Item $script:StateDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Resolve-sqmDagError' {
    It 'erkennt <Category>' -ForEach @(
        @{ Msg = "Login failed for user 'x'. (18456)"; Category = 'Auth' }
        @{ Msg = 'A network-related or instance-specific error occurred'; Category = 'Unreachable' }
        @{ Msg = 'Timeout expired.'; Category = 'Timeout' }
        @{ Msg = 'The server principal does not have permission. permission was denied'; Category = 'Permission' }
        @{ Msg = 'Msg 35250 The connection to the primary replica is not active'; Category = 'EndpointConnection' }
        @{ Msg = 'Cannot open backup device. Operating system error 5(Access is denied.)'; Category = 'BackupPath' }
        @{ Msg = 'Database X already exists'; Category = 'AlreadyExists' }
    ) {
        $r = InModuleScope sqmSQLTool -Parameters @{ m = $Msg } { param ($m) Resolve-sqmDagError -Message $m }
        $r.Category | Should -Be $Category
        $r.CauseDe | Should -Not -BeNullOrEmpty
        $r.FixEn | Should -Not -BeNullOrEmpty
    }
    It 'liefert fuer Unbekanntes immer ein Objekt mit Originaltext' {
        $r = InModuleScope sqmSQLTool { Resolve-sqmDagError -Message 'voellig unbekannt xyz' }
        $r.Category | Should -Be 'Unknown'
        $r.Raw | Should -Be 'voellig unbekannt xyz'
    }
    It 'akzeptiert eine leere Meldung' {
        $r = InModuleScope sqmSQLTool { Resolve-sqmDagError -Message '' }
        $r.Category | Should -Be 'Unknown'
    }
}

Describe 'Test-sqmDagInputValue' {
    It 'akzeptiert <Kind> <Value>' -ForEach @(
        @{ Kind = 'Instance'; Value = 'SQL01' }
        @{ Kind = 'Instance'; Value = 'SQL01\INST1' }
        @{ Kind = 'Instance'; Value = 'SQL01,1433' }
        @{ Kind = 'AgName'; Value = 'ProdAG' }
        @{ Kind = 'Fqdn'; Value = 'sql01.corp.local' }
        @{ Kind = 'Port'; Value = '5022' }
        @{ Kind = 'Path'; Value = '\\fileserver\backup' }
        @{ Kind = 'Path'; Value = 'D:\Backup\SQL' }
        @{ Kind = 'ServiceAccount'; Value = 'CORP\svc-sql' }
        @{ Kind = 'ServiceAccount'; Value = 'CORP\SQL01$' }
    ) {
        InModuleScope sqmSQLTool -Parameters @{ k = $Kind; v = $Value } { param ($k, $v) Test-sqmDagInputValue -Kind $k -Value $v } | Should -BeNullOrEmpty
    }
    It 'lehnt <Kind> <Value> ab' -ForEach @(
        @{ Kind = 'Instance'; Value = '' }
        @{ Kind = 'Instance'; Value = 'SQL 01' }
        @{ Kind = 'Instance'; Value = 'SQL01,99999' }
        @{ Kind = 'AgName'; Value = 'Bad]Name' }
        @{ Kind = 'AgName'; Value = "Bad'Name" }
        @{ Kind = 'DagName'; Value = 'a;DROP' }
        @{ Kind = 'Fqdn'; Value = 'sql01' }
        @{ Kind = 'Port'; Value = '80' }
        @{ Kind = 'Port'; Value = 'abc' }
        @{ Kind = 'Path'; Value = 'relative\path' }
        @{ Kind = 'ServiceAccount'; Value = 'nodomain' }
    ) {
        InModuleScope sqmSQLTool -Parameters @{ k = $Kind; v = $Value } { param ($k, $v) Test-sqmDagInputValue -Kind $k -Value $v } | Should -Not -BeNullOrEmpty
    }
    It 'liefert die Meldung in der gewaehlten Sprache' {
        $de = InModuleScope sqmSQLTool { Test-sqmDagInputValue -Kind Port -Value '1' -Lang de }
        $en = InModuleScope sqmSQLTool { Test-sqmDagInputValue -Kind Port -Value '1' -Lang en }
        $de | Should -Match 'Port'
        $en | Should -Match 'must be a number'
    }
}

Describe 'Zustand und Sperre' {
    It 'speichert Zustand ohne Geheimnisse und liest ihn zurueck' {
        InModuleScope sqmSQLTool -Parameters @{ d = $script:StateDir } {
            param ($d)
            $st = @{ SourceAgName = 'A1'; TargetAgName = 'B1'; Page = 5; Password = 'geheim'; SqlCredential = 'x'; Config = @{ DistributedAgName = 'A1_B1' } }
            $f = Save-sqmDagMigrationState -State $st -BasePath $d
            Test-Path $f | Should -BeTrue
            (Get-Content $f -Raw) | Should -Not -Match 'geheim'
            $r = Get-sqmDagMigrationState -SourceAgName 'A1' -TargetAgName 'B1' -BasePath $d
            $r.Page | Should -Be 5
            $r.Config.DistributedAgName | Should -Be 'A1_B1'
            $r.Corrupt | Should -BeFalse
        }
    }
    It 'meldet eine beschaedigte Zustandsdatei statt zu werfen' {
        InModuleScope sqmSQLTool -Parameters @{ d = $script:StateDir } {
            param ($d)
            Set-Content -Path (Join-Path $d 'kaputt.json') -Value '{ das ist kein json'
            $all = @(Get-sqmDagMigrationState -BasePath $d)
            ($all | Where-Object { $_.Corrupt }).Count | Should -BeGreaterThan 0
        }
    }
    It 'sperrt doppelten Zugriff und uebernimmt verwaiste Sperren' {
        InModuleScope sqmSQLTool -Parameters @{ d = $script:StateDir } {
            param ($d)
            $a = Enter-sqmDagMigrationLock -SourceAgName 'L1' -TargetAgName 'L2' -BasePath $d
            $a.Acquired | Should -BeTrue
            $b = Enter-sqmDagMigrationLock -SourceAgName 'L1' -TargetAgName 'L2' -BasePath $d
            $b.Acquired | Should -BeFalse
            $b.OwnerPid | Should -Be $PID
            Exit-sqmDagMigrationLock -LockFile $a.LockFile
            # verwaiste Sperre: Prozess-ID gibt es nicht mehr
            $lock = [System.IO.Path]::ChangeExtension((Get-sqmDagStateFile -SourceAgName 'L1' -TargetAgName 'L2' -BasePath $d), '.lock')
            @{ Pid = 999999; Host = $env:COMPUTERNAME; User = 'x'; Started = '2020-01-01T00:00:00' } | ConvertTo-Json | Set-Content $lock
            $c = Enter-sqmDagMigrationLock -SourceAgName 'L1' -TargetAgName 'L2' -BasePath $d
            $c.Acquired | Should -BeTrue
            $c.StaleTakeover | Should -BeTrue
            Exit-sqmDagMigrationLock -LockFile $c.LockFile
        }
    }
}

Describe 'Test-sqmDagFailoverReady' {
    It 'ist bereit, wenn alles synchronisiert und die Queues klein sind' {
        $snap = @([PSCustomObject]@{ DatabaseName = 'a'; IsLocal = $true; SyncState = 'SYNCHRONIZED'; Suspended = $false; SendQueueKB = 0; RedoQueueKB = 0 },
            [PSCustomObject]@{ DatabaseName = 'a'; IsLocal = $false; SyncState = 'SYNCHRONIZING'; Suspended = $false; SendQueueKB = 10; RedoQueueKB = 5 })
        $r = InModuleScope sqmSQLTool -Parameters @{ s = $snap } { param ($s) Test-sqmDagFailoverReady -Snapshot $s }
        $r.Ready | Should -BeTrue
    }
    It 'sperrt bei <Why>' -ForEach @(
        @{ Why = 'suspendierter Datenbank'; Row = @{ SyncState = 'SYNCHRONIZING'; Suspended = $true; SendQueueKB = 0; RedoQueueKB = 0 } }
        @{ Why = 'NOT SYNCHRONIZING'; Row = @{ SyncState = 'NOT SYNCHRONIZING'; Suspended = $false; SendQueueKB = 0; RedoQueueKB = 0 } }
        @{ Why = 'grosser Send-Queue'; Row = @{ SyncState = 'SYNCHRONIZING'; Suspended = $false; SendQueueKB = 999999; RedoQueueKB = 0 } }
    ) {
        $row = [PSCustomObject]($Row + @{ DatabaseName = 'x'; IsLocal = $false })
        $r = InModuleScope sqmSQLTool -Parameters @{ s = @($row) } { param ($s) Test-sqmDagFailoverReady -Snapshot $s }
        $r.Ready | Should -BeFalse
        $r.Reasons.Count | Should -BeGreaterThan 0
    }
    It 'sperrt ohne Daten der Gegenseite' {
        $r = InModuleScope sqmSQLTool { Test-sqmDagFailoverReady -Snapshot @() }
        $r.Ready | Should -BeFalse
    }
}

Describe 'Invoke-sqmDagMigrationUnit' {
    BeforeEach {
        $script:cfg = @{ SourceInstance = 'S1'; TargetInstance = 'T1'; SourceAgName = 'AG1'; TargetAgName = 'AG2'; DistributedAgName = 'DAG1'
            SourceFqdn = 's1.x.local'; TargetFqdn = 't1.x.local'; EndpointPort = 5023; SeedingMode = 'Automatic' }
    }
    It 'reicht DAG-Name und Port an New-sqmDistributedAvailabilityGroup durch' {
        Mock New-sqmDistributedAvailabilityGroup -ModuleName sqmSQLTool { [PSCustomObject]@{ Status = 'SUCCESS'; Steps = @() } }
        $r = InModuleScope sqmSQLTool -Parameters @{ c = $script:cfg } { param ($c) Invoke-sqmDagMigrationUnit -Unit CreateDag -Config $c }
        $r.Ok | Should -BeTrue
        Should -Invoke New-sqmDistributedAvailabilityGroup -ModuleName sqmSQLTool -Times 1 -ParameterFilter { $DistributedAgName -eq 'DAG1' -and $EndpointPort -eq 5023 -and $PrimaryInstance -eq 'S1' }
    }
    It 'meldet Status FAILED als Fehler mit Klassifizierung' {
        Mock New-sqmDistributedAvailabilityGroup -ModuleName sqmSQLTool { [PSCustomObject]@{ Status = 'FAILED'; Error = 'Login failed for user x' } }
        $r = InModuleScope sqmSQLTool -Parameters @{ c = $script:cfg } { param ($c) Invoke-sqmDagMigrationUnit -Unit CreateDag -Config $c }
        $r.Ok | Should -BeFalse
        $r.Error.Category | Should -Be 'Auth'
    }
    It 'faengt Ausnahmen ab und wirft nie' {
        Mock New-sqmDistributedAvailabilityGroup -ModuleName sqmSQLTool { throw 'Timeout expired' }
        $r = InModuleScope sqmSQLTool -Parameters @{ c = $script:cfg } { param ($c) Invoke-sqmDagMigrationUnit -Unit CreateDag -Config $c }
        $r.Ok | Should -BeFalse
        $r.Error.Retryable | Should -BeTrue
    }
    It 'fuehrt den Rollback in umgekehrter Richtung aus' {
        Mock Invoke-sqmDistributedFailover -ModuleName sqmSQLTool { [PSCustomObject]@{ Status = 'SUCCESS' } }
        $null = InModuleScope sqmSQLTool -Parameters @{ c = $script:cfg } { param ($c) Invoke-sqmDagMigrationUnit -Unit Rollback -Config $c }
        Should -Invoke Invoke-sqmDistributedFailover -ModuleName sqmSQLTool -Times 1 -ParameterFilter { "$SqlInstance" -eq 'T1' -and $TargetInstance -eq 'S1' -and $Rollback }
    }
    It 'gibt im Trockenlauf WhatIf weiter' {
        Mock New-sqmDistributedAvailabilityGroup -ModuleName sqmSQLTool { [PSCustomObject]@{ Status = 'WHATIF'; Steps = @() } }
        $r = InModuleScope sqmSQLTool -Parameters @{ c = $script:cfg } { param ($c) Invoke-sqmDagMigrationUnit -Unit CreateDag -Config $c -DryRun }
        $r.Status | Should -Be 'WHATIF'
        Should -Invoke New-sqmDistributedAvailabilityGroup -ModuleName sqmSQLTool -Times 1 -ParameterFilter { $PesterBoundParameters.WhatIf -eq $true }
    }
}

Describe 'New-sqmDistributedAvailabilityGroup' {
    BeforeEach {
        $global:DagStmts = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-sqmLogging -ModuleName sqmSQLTool { }
        Mock Start-Sleep -ModuleName sqmSQLTool { }
        Mock Invoke-DbaQuery -ModuleName sqmSQLTool {
            $global:DagStmts.Add([string]$Query)
            if ($Query -match 'SELECT COUNT\(\*\) AS C FROM sys.availability_groups WHERE is_distributed = 1 AND name') { return [PSCustomObject]@{ C = $(if ($global:DagCreated) { 1 } else { 0 }) } }
            if ($Query -match 'CREATE AVAILABILITY GROUP') { $global:DagCreated = $true }
            if ($Query -match 'role_desc') { return [PSCustomObject]@{ name = 'x'; role_desc = 'PRIMARY'; synchronization_health_desc = 'HEALTHY'; ReplicaCount = 2; DatabaseCount = 1 } }
            return $null
        }
        $global:DagCreated = $false
        $script:args1 = @{ PrimaryInstance = 'S1'; PrimaryAgName = 'AG1'; SecondaryInstance = 'T1'; SecondaryAgName = 'AG2'
            PrimaryFqdn = 's1.x.local'; SecondaryFqdn = 't1.x.local'; OutputPath = $script:StateDir; EnableException = $true }
    }
    AfterEach { Remove-Variable DagStmts, DagCreated -Scope Global -ErrorAction SilentlyContinue }

    It 'veraendert im Trockenlauf nichts' {
        $r = New-sqmDistributedAvailabilityGroup @script:args1 -WhatIf
        $r.Status | Should -Be 'WHATIF'
        Should -Invoke Invoke-DbaQuery -ModuleName sqmSQLTool -Times 0
    }
    It 'verwendet freien DAG-Namen und Endpoint-Port in der LISTENER_URL' {
        $r = New-sqmDistributedAvailabilityGroup @script:args1 -DistributedAgName 'MeineDag' -EndpointPort 5099 -Confirm:$false
        $r.Status | Should -Be 'SUCCESS'
        $r.DistributedAgName | Should -Be 'MeineDag'
        ($global:DagStmts | Where-Object { $_ -match 'CREATE AVAILABILITY GROUP \[MeineDag\]' }).Count | Should -Be 1
        ($global:DagStmts | Where-Object { $_ -match 'TCP://s1.x.local:5099' }).Count | Should -BeGreaterThan 0
        ($global:DagStmts | Where-Object { $_ -match ':5022' }).Count | Should -Be 0
    }
    It 'lehnt unzulaessige Zeichen im DAG-Namen ab' {
        { New-sqmDistributedAvailabilityGroup @script:args1 -DistributedAgName 'a];DROP' -Confirm:$false } | Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }
    It 'legt eine bereits vorhandene DAG nicht erneut an (Wiederaufnahme)' {
        $global:DagCreated = $true
        $r = New-sqmDistributedAvailabilityGroup @script:args1 -Confirm:$false
        ($global:DagStmts | Where-Object { $_ -match '^CREATE AVAILABILITY GROUP' }).Count | Should -Be 0
        ($r.Steps | Where-Object { $_.Step -eq 'Create Distributed AG' }).Status | Should -Be 'SKIPPED'
    }
}

Describe 'Invoke-sqmDistributedFailover' {
    BeforeEach {
        $global:FoStmts = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-sqmLogging -ModuleName sqmSQLTool { }
        Mock Start-Sleep -ModuleName sqmSQLTool { }
        Mock Invoke-DbaQuery -ModuleName sqmSQLTool {
            $global:FoStmts.Add("$("$SqlInstance")|$Query")
            if ($Query -match 'ar.replica_server_name AS AgName') { return @([PSCustomObject]@{ AgName = 'AG1'; IsLocal = 1 }, [PSCustomObject]@{ AgName = 'AG2'; IsLocal = $null }) }
            if ($Query -match 'ars.role_desc, ars.synchronization_health_desc') { return @([PSCustomObject]@{ name = 'DAG1'; replica_server_name = 'AG2'; role_desc = 'PRIMARY'; synchronization_health_desc = 'HEALTHY' }) }
            return $null
        }
        $script:snapOk = @([PSCustomObject]@{ DatabaseName = 'a'; IsLocal = $true; SyncState = 'SYNCHRONIZED'; Suspended = $false; SendQueueKB = 0; RedoQueueKB = 0 },
            [PSCustomObject]@{ DatabaseName = 'a'; IsLocal = $false; SyncState = 'SYNCHRONIZED'; Suspended = $false; SendQueueKB = 0; RedoQueueKB = 0 })
        $script:foArgs = @{ SqlInstance = 'S1'; TargetInstance = 'T1'; AvailabilityGroupName = 'DAG1'; OutputPath = $script:StateDir; EnableException = $true }
    }
    AfterEach { Remove-Variable FoStmts -Scope Global -ErrorAction SilentlyContinue }

    It 'fuehrt den dokumentierten Ablauf in der richtigen Reihenfolge aus' {
        Mock Get-sqmDagSyncSnapshot -ModuleName sqmSQLTool { $script:snapOk }
        $r = Invoke-sqmDistributedFailover @script:foArgs -Force
        $r.Status | Should -Be 'SUCCESS'
        $r.NewPrimaryAg | Should -Be 'AG2'
        $order = $global:FoStmts | Where-Object { $_ -match 'SYNCHRONOUS_COMMIT|ROLE = SECONDARY|FORCE_FAILOVER_ALLOW_DATA_LOSS' }
        $order[0] | Should -Match '^S1\|.*SYNCHRONOUS_COMMIT'
        $order[1] | Should -Match '^T1\|.*SYNCHRONOUS_COMMIT'
        $order[2] | Should -Match '^S1\|.*ROLE = SECONDARY'
        $order[3] | Should -Match '^T1\|.*FORCE_FAILOVER_ALLOW_DATA_LOSS'
        ($global:FoStmts | Where-Object { $_ -match '\] FAILOVER$' }).Count | Should -Be 0
    }
    It 'schaltet im Trockenlauf nichts um' {
        Mock Get-sqmDagSyncSnapshot -ModuleName sqmSQLTool { $script:snapOk }
        $r = Invoke-sqmDistributedFailover @script:foArgs -WhatIf
        $r.Status | Should -Be 'WHATIF'
        ($global:FoStmts | Where-Object { $_ -match 'ALTER AVAILABILITY GROUP' }).Count | Should -Be 0
    }
    It 'bricht bei nicht bereiten Datenbanken ab, ohne etwas zu aendern' {
        Mock Get-sqmDagSyncSnapshot -ModuleName sqmSQLTool { @([PSCustomObject]@{ DatabaseName = 'a'; IsLocal = $false; SyncState = 'NOT SYNCHRONIZING'; Suspended = $false; SendQueueKB = 0; RedoQueueKB = 0 }) }
        { Invoke-sqmDistributedFailover @script:foArgs -Force } | Should -Throw '*NICHT empfohlen*'
        ($global:FoStmts | Where-Object { $_ -match 'ALTER AVAILABILITY GROUP' }).Count | Should -Be 0
    }
    It 'verlangt die Ziel-Instanz' {
        Mock Get-sqmDagSyncSnapshot -ModuleName sqmSQLTool { $script:snapOk }
        $a = $script:foArgs.Clone(); $a.Remove('TargetInstance')
        { Invoke-sqmDistributedFailover @a -Force } | Should -Throw '*TargetInstance*'
    }
    It 'setzt bei ausbleibender Synchronisation auf ASYNCHRONOUS_COMMIT zurueck und schaltet nicht um' {
        $global:Polls = 0
        Mock Get-sqmDagSyncSnapshot -ModuleName sqmSQLTool {
            $global:Polls++
            if ($global:Polls -le 1) { return $script:snapOk }   # Bereitschaftspruefung
            @([PSCustomObject]@{ DatabaseName = 'a'; IsLocal = $false; SyncState = 'SYNCHRONIZING'; Suspended = $false; SendQueueKB = 0; RedoQueueKB = 0 })
        }
        { Invoke-sqmDistributedFailover @script:foArgs -Force -SyncTimeoutSeconds 30 } | Should -Throw '*nicht SYNCHRONIZED*'
        ($global:FoStmts | Where-Object { $_ -match 'ROLE = SECONDARY|FORCE_FAILOVER' }).Count | Should -Be 0
        ($global:FoStmts | Where-Object { $_ -match 'ASYNCHRONOUS_COMMIT' }).Count | Should -BeGreaterThan 0
        Remove-Variable Polls -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Test-sqmDistributedAgMigrationPrerequisite' {
    BeforeEach {
        Mock Invoke-DbaQuery -ModuleName sqmSQLTool {
            switch -Regex ($Query)
            {
                'SERVERPROPERTY' { return [PSCustomObject]@{ ProductVersion = '16.0.4135.4'; Edition = 'Enterprise Edition (64-bit)'; IsHadrEnabled = 1; Collation = 'Latin1_General_CI_AS'; IsSysadmin = 1 } }
                'dm_hadr_availability_group_states' { return [PSCustomObject]@{ name = $SqlParameters.n; is_distributed = 0; primary_replica = "$SqlInstance"; role_desc = $(if ($global:PreRole) { $global:PreRole } else { 'PRIMARY' }); synchronization_health_desc = 'HEALTHY' } }
                'replica_server_name IN' { return @() }
                'WHERE name = @n' { return @() }
                'database_mirroring_endpoints' { return [PSCustomObject]@{ name = 'Hadr_endpoint'; state_desc = 'STARTED'; port = 5022; role_desc = 'ALL'; encryption_algorithm_desc = 'AES' } }
                'dm_hadr_database_replica_states' { return @([PSCustomObject]@{ DatabaseName = 'AppDb'; synchronization_state_desc = 'SYNCHRONIZED'; synchronization_health_desc = 'HEALTHY'; is_suspended = 0 }) }
                'sys.master_files mf\s+JOIN' { return @([PSCustomObject]@{ DatabaseName = 'AppDb'; physical_name = 'D:\Data\AppDb.mdf'; SizeMB = 100 }) }
                'FROM sys.databases' { return @() }
                'adc.database_name AS name' { return @() }
                'xp_fileexist' { return [PSCustomObject]@{ IsDir = 1 } }
                'dm_os_volume_stats' { return @([PSCustomObject]@{ volume_mount_point = 'D:\'; AvailableMB = 500000 }) }
                'dm_server_services' { return [PSCustomObject]@{ service_account = 'CORP\svc' } }
                'server_permissions' { return [PSCustomObject]@{ Grantee = 'CORP\svc' } }
                default { return $null }
            }
        }
        $script:pre = @{ SourceInstance = 'S1'; SourceAgName = 'AG1'; TargetInstance = 'T1'; TargetAgName = 'AG2' }
    }
    AfterEach { Remove-Variable PreRole -Scope Global -ErrorAction SilentlyContinue }

    It 'erlaubt die Migration bei gesunder Ausgangslage' {
        $r = Test-sqmDistributedAgMigrationPrerequisite @script:pre
        $r.CanProceed | Should -BeTrue
        $r.Blockers.Count | Should -Be 0
        $r.SourceDatabases | Should -Contain 'AppDb'
        $r.DistributedAgName | Should -Be 'AG1_AG2'
    }
    It 'blockiert, wenn der Knoten nicht PRIMARY ist' {
        $global:PreRole = 'SECONDARY'
        $r = Test-sqmDistributedAgMigrationPrerequisite @script:pre
        $r.CanProceed | Should -BeFalse
        ($r.Blockers | Where-Object { $_.Id -like '*.primary' }).Count | Should -BeGreaterThan 0
        $b = $r.Blockers | Where-Object { $_.Id -like '*.primary' } | Select-Object -First 1
        $b.MessageDe | Should -Match 'nicht PRIMARY'
        $b.MessageEn | Should -Match 'not PRIMARY'
        $b.RemedyDe | Should -Not -BeNullOrEmpty
    }
    It 'blockiert bei Standard Edition' {
        Mock Invoke-DbaQuery -ModuleName sqmSQLTool {
            if ($Query -match 'SERVERPROPERTY') { return [PSCustomObject]@{ ProductVersion = '16.0.4135.4'; Edition = 'Standard Edition (64-bit)'; IsHadrEnabled = 1; Collation = 'x'; IsSysadmin = 1 } }
            return $null
        }
        $r = Test-sqmDistributedAgMigrationPrerequisite @script:pre
        ($r.Blockers | Where-Object { $_.Id -like '*.edition' }).Count | Should -Be 2
    }
    It 'blockiert, wenn das Ziel eine aeltere Version hat' {
        Mock Invoke-DbaQuery -ModuleName sqmSQLTool {
            if ($Query -match 'SERVERPROPERTY') { return [PSCustomObject]@{ ProductVersion = $(if ("$SqlInstance" -eq 'T1') { '14.0.3500.1' } else { '16.0.4135.4' }); Edition = 'Enterprise Edition'; IsHadrEnabled = 1; Collation = 'x'; IsSysadmin = 1 } }
            return $null
        }
        $r = Test-sqmDistributedAgMigrationPrerequisite @script:pre
        ($r.Blockers | Where-Object { $_.Id -eq 'x.version' }).Count | Should -Be 1
    }
    It 'meldet eine nicht erreichbare Instanz als Blocker mit Loesung, statt zu werfen' {
        Mock Invoke-DbaQuery -ModuleName sqmSQLTool { throw 'A network-related or instance-specific error occurred' }
        $r = Test-sqmDistributedAgMigrationPrerequisite @script:pre
        $r.CanProceed | Should -BeFalse
        ($r.Blockers | Where-Object { $_.Id -eq 'src.connect' }).RemedyDe | Should -Not -BeNullOrEmpty
    }
    It 'blockiert bei Namenskollision von Datenbanken auf dem Ziel' {
        Mock Invoke-DbaQuery -ModuleName sqmSQLTool {
            switch -Regex ($Query)
            {
                'SERVERPROPERTY' { return [PSCustomObject]@{ ProductVersion = '16.0.4135.4'; Edition = 'Enterprise'; IsHadrEnabled = 1; Collation = 'x'; IsSysadmin = 1 } }
                'dm_hadr_availability_group_states' { return [PSCustomObject]@{ name = 'x'; is_distributed = 0; primary_replica = 'p'; role_desc = 'PRIMARY'; synchronization_health_desc = 'HEALTHY' } }
                'dm_hadr_database_replica_states' { return @([PSCustomObject]@{ DatabaseName = 'AppDb'; synchronization_state_desc = 'SYNCHRONIZED'; synchronization_health_desc = 'HEALTHY'; is_suspended = 0 }) }
                'FROM sys.databases' { return @([PSCustomObject]@{ name = 'AppDb' }) }
                'replica_server_name IN' { return @() }
                'WHERE name = @n' { return @() }
                default { return $null }
            }
        }
        $r = Test-sqmDistributedAgMigrationPrerequisite @script:pre
        ($r.Blockers | Where-Object { $_.Id -eq 'tgt.dbclash' }).Count | Should -Be 1
    }
    It 'verlangt bei manuellem Seeding einen Backup-Pfad' {
        $r = Test-sqmDistributedAgMigrationPrerequisite @script:pre -SeedingMode Manual
        ($r.Blockers | Where-Object { $_.Id -eq 'seed.path' }).Count | Should -Be 1
    }
}

Describe 'GUI-Oberflaeche' {
    It 'Show-sqmDistributedAgGui ist exportiert und hat Sprach- und Statusparameter' {
        $c = Get-Command Show-sqmDistributedAgGui
        $c.Parameters.ContainsKey('Language') | Should -BeTrue
        $c.Parameters.ContainsKey('StatePath') | Should -BeTrue
    }
    It 'baut das Fenster, zeigt alle Seiten ohne Fehler und schliesst sauber' {
        $script:guiErr = @()
        Show-sqmDistributedAgGui -Language en -StatePath $script:StateDir -OnShown {
            param ($api)
            try
            {
                $api.State.PJob = 1
                $api.State.Config = @{ SourceInstance = 'a'; TargetInstance = 'b'; SourceAgName = 'x'; TargetAgName = 'y'; DistributedAgName = 'x_y'; SeedingMode = 'Automatic'; ListenerPort = 1433 }
                $api.State.PreflightRan = $true
                foreach ($p in 0..9) { & $api.Go $p; if (-not $api.Pages[$p].Visible) { throw "Seite $p nicht sichtbar" } }
                & $api.Apply
            }
            catch { $script:guiErr += $_.Exception.Message }
            $api.State.PJob = $null; $api.State.Started = $false
            $api.Form.Close()
        }
        $script:guiErr | Should -BeNullOrEmpty
    }
}
