#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Invoke-sqmHealthReport. Alle aufgerufenen Teilfunktionen und Invoke-DbaQuery
    werden gemockt - getestet wird die Orchestrierung: Abschnittsauswahl, Befund-Sammlung und
    -Sortierung, Fehlertoleranz je Abschnitt, Messfenster-Reihenfolge, Abbruch bei
    unerreichbarer Instanz. Die echten Abfragen sind live gegen SQL Server 2025 geprueft.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:out = Join-Path $TestDrive 'hr'
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmHealthReport' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_os_sys_info' } {
            [PSCustomObject]@{ ServerName = 'SQL01'; ProductVersion = '16.0.1'; ProductLevel = 'RTM'; ProductUpdateLevel = 'CU1'; Edition = 'Enterprise'
                IsHadrEnabled = 0; IsClustered = 0; StartTime = (Get-Date).AddDays(-20); CpuCount = 8; PhysicalMemoryMB = 65536; CommittedMB = 50000; TargetMB = 58000; UserDatabases = 3 }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_tran_session_transactions' } {
            [PSCustomObject]@{ SessionId = 77; LoginName = 'app'; HostName = 'h'; ProgramName = 'App'; DatabaseName = 'Shop'; BeginTime = (Get-Date).AddMinutes(-30); OpenSeconds = 1800; SessionStatus = 'sleeping'; LogUsedMB = 12.5; LastSqlText = 'UPDATE x' }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_session_space_usage' } { }
        Mock -ModuleName sqmSQLTool Get-sqmSQLInstanceCheck {
            [PSCustomObject]@{ Check = 'MAXDOP'; CurrentValue = 0; Recommended = '2..8'; Status = 'Warning'; Message = 'm' }
            [PSCustomObject]@{ Check = 'CTFP'; CurrentValue = 5; Recommended = '>= 50'; Status = 'Failed'; Message = 'm' }
            [PSCustomObject]@{ Check = 'Backup'; CurrentValue = 'x'; Recommended = 'x'; Status = 'OK'; Message = 'm' }
        }
        Mock -ModuleName sqmSQLTool Get-sqmWaitStatistics { [PSCustomObject]@{ WaitType = 'PAGEIOLATCH_SH'; Category = 'IO'; WaitTimePct = 40; AvgWaitMs = 12; SignalWaitPct = 1; Recommendation = 'Check storage' } }
        Mock -ModuleName sqmSQLTool Get-sqmWhoIsActive { [PSCustomObject]@{ LastSnapshot = @([PSCustomObject]@{ SessionId = 60; BlockingSessionId = 55; ElapsedSeconds = 30 }) } }
        Mock -ModuleName sqmSQLTool Get-sqmTempDbRecommendation { [PSCustomObject]@{ Status = 'OK'; FileCount = 8; RecommendedCount = 8; FileSizesMB = 8; GrowthMB = 64; Recommendations = @() } }
        Mock -ModuleName sqmSQLTool Get-sqmDatabaseHealth { [PSCustomObject]@{ DetailRows = @([PSCustomObject]@{ Database = 'Shop'; OverallStatus = 'Critical'; CheckDbStatus = 'Critical'; VlfStatus = 'OK'; LastCheckDb = 'never'; LastFullBackup = '(keins)' }) } }
        Mock -ModuleName sqmSQLTool Get-sqmPlanCacheReport { [PSCustomObject]@{ Ranks = 'CPU#1'; DatabaseName = 'Shop'; ObjectName = 'dbo.P'; CpuPercent = 60; Findings = 'ImplicitConversion'; StatementText = 'SELECT 1' } }
        Mock -ModuleName sqmSQLTool Get-sqmIndexUsageReport { [PSCustomObject]@{ Finding = 'Unused'; SizeMB = 2048; DatabaseName = 'Shop' } }
        Mock -ModuleName sqmSQLTool Get-sqmMissingIndexes { }
        Mock -ModuleName sqmSQLTool Get-sqmFileLatencyReport { [PSCustomObject]@{ DatabaseName = 'Shop'; LogicalName = 'Shop'; FileType = 'ROWS'; Rating = 'Critical'; AvgReadMs = 80; AvgWriteMs = 3; Drive = 'E:'; Mode = 'm' } }
        Mock -ModuleName sqmSQLTool Get-sqmDeadlockReport { }
        Mock -ModuleName sqmSQLTool Get-sqmSysadminAccounts { [PSCustomObject]@{ DetailRows = @([PSCustomObject]@{ LoginName = 'sa'; Status = 'OK' }) } }
        Mock -ModuleName sqmSQLTool Get-sqmDiskSpaceReport { [PSCustomObject]@{ DetailRows = @([PSCustomObject]@{ MountPoint = 'E:\'; FreePct = 4; Status = 'Critical'; Message = 'voll' }) } }
    }

    It 'Fuehrt alle 12 Abschnitte aus und schreibt index.html' {
        $r = Invoke-sqmHealthReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $r.Sections.Count | Should -Be 12
        Test-Path $r.HtmlFile | Should -Be $true
        (Get-Content $r.HtmlFile -Raw) | Should -Match "id='s-OpenTransactions'"
    }

    It 'Sammelt Befunde aus allen Abschnitten, Critical zuerst' {
        $r = Invoke-sqmHealthReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $r.Status | Should -Be 'Critical'
        $r.Findings[0].Severity | Should -Be 'Critical'
        $sections = $r.Findings.Section | Sort-Object -Unique
        foreach ($s in 'Instance', 'Waits', 'Activity', 'OpenTransactions', 'Databases', 'PlanCache', 'Indexes', 'FileLatency', 'Disk') { $sections | Should -Contain $s }
        ($r.Findings | Where-Object Section -eq 'OpenTransactions').Severity | Should -Be 'Critical'
        ($r.Findings | Where-Object { $_.Section -eq 'Instance' -and $_.Finding -like 'MAXDOP*' }).Severity | Should -Be 'Warning'
        ($r.Findings | Where-Object { $_.Section -eq 'Indexes' }).Severity | Should -Be 'Warning'
    }

    It 'Ein fehlschlagender Abschnitt stoppt die anderen nicht' {
        Mock -ModuleName sqmSQLTool Get-sqmPlanCacheReport { throw 'VIEW SERVER STATE fehlt' }
        $r = Invoke-sqmHealthReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        ($r.Sections | Where-Object Section -eq 'PlanCache').Status | Should -Be 'Failed'
        ($r.Sections | Where-Object Section -eq 'PlanCache').Error | Should -Match 'VIEW SERVER STATE'
        ($r.Sections | Where-Object Section -eq 'Disk').Status | Should -Be 'Critical'
    }

    It '-Section und -SkipSection waehlen Abschnitte aus' {
        $r = Invoke-sqmHealthReport -SqlInstance 'SQL01' -Section Instance, Waits, Disk -SkipSection Disk -OutputPath $script:out -NoOpen
        $r.Sections.Section | Should -Be @('Instance', 'Waits')
        Should -Invoke -ModuleName sqmSQLTool Get-sqmDiskSpaceReport -Exactly 0
    }

    It 'Misst Waits und Latenz im selben Fenster (Latenz vor Waits)' {
        Mock -ModuleName sqmSQLTool Get-sqmWaitStatistics -ParameterFilter { $SaveSnapshot } { @([PSCustomObject]@{ WaitType = 'x' }) }
        $r = Invoke-sqmHealthReport -SqlInstance 'SQL01' -Section Waits, FileLatency, Instance -SampleSeconds 2 -OutputPath $script:out -NoOpen
        $r.Sections.Section | Should -Be @('Instance', 'FileLatency', 'Waits')
        Should -Invoke -ModuleName sqmSQLTool Get-sqmFileLatencyReport -Exactly 1 -ParameterFilter { $SampleSeconds -eq 2 }
        Should -Invoke -ModuleName sqmSQLTool Get-sqmWaitStatistics -Exactly 1 -ParameterFilter { $SnapshotBefore }
    }

    It '-InDepth nutzt alle Plan-Cache-Metriken' {
        Mock -ModuleName sqmSQLTool Start-Sleep { }
        Invoke-sqmHealthReport -SqlInstance 'SQL01' -Section PlanCache -InDepth -OutputPath $script:out -NoOpen | Out-Null
        Should -Invoke -ModuleName sqmSQLTool Get-sqmPlanCacheReport -Exactly 1 -ParameterFilter { $SortBy -contains 'All' }
    }

    It 'Bricht bei unerreichbarer Instanz mit -EnableException ab' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_os_sys_info' } { throw 'network path not found' }
        { Invoke-sqmHealthReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen -EnableException } | Should -Throw '*nicht erreichbar*'
    }

    It '-Zip packt den Berichtsordner' {
        $r = Invoke-sqmHealthReport -SqlInstance 'SQL01' -Section Instance -Zip -OutputPath $script:out -NoOpen
        Test-Path $r.ZipFile | Should -Be $true
    }
}
