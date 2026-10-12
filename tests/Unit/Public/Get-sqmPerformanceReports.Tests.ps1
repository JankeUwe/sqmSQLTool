#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmIndexUsageReport, Get-sqmFileLatencyReport und Get-sqmPlanCacheReport.
    Invoke-DbaQuery wird gemockt - getestet wird die Auswertungslogik (Befunde, Bewertung,
    Versionspruefung), nicht die DMVs selbst. Die SQL-Seite ist live gegen SQL Server 2025 geprueft.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    function New-TestIndex {
        param ($Name, $Id, $Type = 2, $Keys = '', $Incl = '', $Seeks = 0, $Updates = 0, [switch]$Pk, [switch]$Unique, [switch]$Disabled, [switch]$Hypo, $Table = 'Orders', $SizeMB = 10)
        [PSCustomObject]@{
            SchemaName = 'dbo'; TableName = $Table; IndexName = $(if ($Id -eq 0) { [DBNull]::Value } else { $Name }); IndexId = $Id
            IndexType = $Type; IndexTypeDesc = 'X'; IsPrimaryKey = [bool]$Pk; IsUnique = [bool]($Unique -or $Pk); IsUniqueConstraint = $false
            IsDisabled = [bool]$Disabled; IsHypothetical = [bool]$Hypo; FilterDefinition = ''
            KeyColumns = $Keys; IncludeColumns = $Incl
            UserSeeks = $Seeks; UserScans = 0; UserLookups = 0; UserUpdates = $Updates; LastUserRead = [DBNull]::Value
            RowCnt = 1000; SizeMB = $SizeMB; NonclusteredCount = 0
        }
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmIndexUsageReport' {
    BeforeAll {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'sqlserver_start_time' } { [PSCustomObject]@{ t = (Get-Date).AddDays(-30) } }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM sys.databases' } { [PSCustomObject]@{ name = 'AppDb' } }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_index_usage_stats' } {
            New-TestIndex -Name 'PK_Orders' -Id 1 -Type 1 -Keys '[Id]' -Seeks 500 -Pk
            New-TestIndex -Name 'IX_Cust' -Id 2 -Keys '[Cust]' -Incl '[Amount]' -Seeks 10
            New-TestIndex -Name 'IX_Cust_Dup' -Id 3 -Keys '[Cust]' -Seeks 5
            New-TestIndex -Name 'IX_Cust_Amt' -Id 4 -Keys '[Cust], [Amount]' -Seeks 7
            New-TestIndex -Name 'IX_Unused' -Id 5 -Keys '[Note]' -Updates 999
            New-TestIndex -Name 'UX_Code' -Id 6 -Keys '[Code]' -Unique
            New-TestIndex -Name 'IX_Off' -Id 7 -Keys '[X]' -Disabled
            New-TestIndex -Name 'IX_Hypo' -Id 8 -Keys '[Y]' -Hypo
            New-TestIndex -Name 'heap' -Id 0 -Type 0 -Table 'Log'
        }
    }

    It 'Meldet ungenutzte Indizes, aber nie Unique/PK' {
        $r = Get-sqmIndexUsageReport -SqlInstance 'SQL01' -Finding Unused -NoReport
        $r.IndexName | Should -Contain 'IX_Unused'
        $r.IndexName | Should -Not -Contain 'UX_Code'
        $r.IndexName | Should -Not -Contain 'PK_Orders'
        ($r | Where-Object IndexName -eq 'IX_Unused').Writes | Should -Be 999
    }

    It 'Erkennt Duplikate und behaelt das niedrigere index_id' {
        $r = @(Get-sqmIndexUsageReport -SqlInstance 'SQL01' -Finding Duplicate -NoReport)
        $r.Count | Should -Be 1
        $r[0].IndexName | Should -Be 'IX_Cust_Dup'
        $r[0].RelatedIndex | Should -Be 'IX_Cust'
        $r[0].Detail | Should -Match 'Includes abweichend'
        $r[0].DropStatement | Should -Match '^DROP INDEX \[IX_Cust_Dup\] ON \[AppDb\]\.\[dbo\]\.\[Orders\];$'
    }

    It 'Erkennt Ueberlappung und prueft die Include-Abdeckung' {
        $r = @(Get-sqmIndexUsageReport -SqlInstance 'SQL01' -Finding Overlapping -NoReport)
        $o = $r | Where-Object IndexName -eq 'IX_Cust'
        $o.RelatedIndex | Should -Be 'IX_Cust_Amt'
        $o.Detail | Should -Match 'Alle Include-Spalten'
        $r.IndexName | Should -Not -Contain 'IX_Cust_Dup'
    }

    It 'Meldet Heap, deaktivierten und hypothetischen Index' {
        $r = Get-sqmIndexUsageReport -SqlInstance 'SQL01' -Finding Heap, Disabled, Hypothetical -NoReport
        ($r | Where-Object Finding -eq 'Heap').TableName | Should -Be 'Log'
        ($r | Where-Object Finding -eq 'Disabled').IndexName | Should -Be 'IX_Off'
        ($r | Where-Object Finding -eq 'Hypothetical').IndexName | Should -Be 'IX_Hypo'
    }

    It 'Warnt bei kurzer Laufzeit und markiert Unused als unzuverlaessig' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'sqlserver_start_time' } { [PSCustomObject]@{ t = (Get-Date).AddHours(-5) } }
        $r = Get-sqmIndexUsageReport -SqlInstance 'SQL01' -Finding Unused -NoReport -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -Match 'unzuverlaessig'
        ($r | Where-Object IndexName -eq 'IX_Unused').Detail | Should -Match 'UNZUVERLAESSIG'
    }
}

Describe 'Get-sqmFileLatencyReport' {
    BeforeAll {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'sqlserver_start_time' } { [PSCustomObject]@{ t = (Get-Date).AddDays(-3) } }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_io_virtual_file_stats' } {
            $f = { param ($db, $id, $type, $path, $r, $sr, $w, $sw) [PSCustomObject]@{ DatabaseName = $db; DatabaseId = 5; FileId = $id; LogicalName = "$db$id"; FileType = $type; PhysicalName = $path
                NumReads = $r; BytesRead = $r * 8192; StallReadMs = $sr; NumWrites = $w; BytesWritten = $w * 8192; StallWriteMs = $sw; SizeOnDiskBytes = 1GB } }
            & $f 'App' 1 'ROWS' 'D:\Data\App.mdf' 10000 100000 5000 50000      # 10 ms / 10 ms -> OK
            & $f 'App' 2 'LOG'  'L:\Log\App.ldf'  0 0 10000 100000             # Log-Write 10 ms -> Warning
            & $f 'Big' 3 'ROWS' 'E:\Data\Big.mdf' 2000 200000 0 0              # 100 ms -> Critical
            & $f 'Idle' 4 'ROWS' 'E:\Data\Idle.mdf' 5 5000 0 0                 # zu wenig I/O -> n/a
        }
    }

    It 'Bewertet Daten- und Logdateien mit getrennten Grenzwerten' {
        $r = Get-sqmFileLatencyReport -SqlInstance 'SQL01' -NoReport
        ($r | Where-Object LogicalName -eq 'App1').Rating | Should -Be 'OK'
        ($r | Where-Object LogicalName -eq 'App2').Rating | Should -Be 'Warning'
        ($r | Where-Object LogicalName -eq 'Big3').Rating | Should -Be 'Critical'
        ($r | Where-Object LogicalName -eq 'Idle4').Rating | Should -Be 'n/a'
    }

    It 'Sortiert die kritischste Datei nach oben und ermittelt das Laufwerk' {
        $r = @(Get-sqmFileLatencyReport -SqlInstance 'SQL01' -NoReport)
        $r[0].LogicalName | Should -Be 'Big3'
        $r[0].Drive | Should -Be 'E:'
        $r[0].AvgReadMs | Should -Be 100
    }

    It 'Filtert nach Datenbank' {
        @(Get-sqmFileLatencyReport -SqlInstance 'SQL01' -Database 'App' -NoReport).Count | Should -Be 2
    }
}

Describe 'Get-sqmPlanCacheReport' {
    BeforeAll {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
    }

    It 'Ueberspringt MemoryGrant/Spills auf alten Versionen mit Warnung' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'sys.all_columns' } { [PSCustomObject]@{ name = 'total_worker_time' } }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '#q' } { }
        Get-sqmPlanCacheReport -SqlInstance 'SQL01' -SortBy MemoryGrant, CPU -NoReport -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        ($w -join ' ') | Should -Match 'MemoryGrant'
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '#q' -and $Query -match 'rn_CPU' -and $Query -notmatch 'rn_MemoryGrant' }
    }

    It 'Liefert Raenge und Befunde aus dem Plan' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'sys.all_columns' } { 'total_worker_time', 'total_grant_kb', 'total_spills' | ForEach-Object { [PSCustomObject]@{ name = $_ } } }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '#q' } {
            [PSCustomObject]@{ rn_CPU = 1; rn_Reads = [DBNull]::Value; total_worker_time = 5000000; total_elapsed_time = 6000000; total_logical_reads = 100; total_logical_writes = 0
                execution_count = 10; total_grant_kb = 0; max_grant_kb = 0; total_spills = 3; sum_cpu = 10000000; sum_dur = 6000000; sum_reads = 100
                DatabaseName = 'AppDb'; SchemaName = 'dbo'; ObjectName = 'GetOrders'; StatementText = ' SELECT 1 '; creation_time = Get-Date; last_execution_time = Get-Date
                query_hash = [byte[]](1, 2); PlanText = '<ShowPlanXML><RelOp Parallel="1"><ScalarOperator ScalarString="CONVERT_IMPLICIT(nvarchar)"/></RelOp><MissingIndexes></MissingIndexes></ShowPlanXML>' }
        }
        $r = @(Get-sqmPlanCacheReport -SqlInstance 'SQL01' -SortBy CPU, Reads -NoReport)
        $r.Count | Should -Be 1
        $r[0].Ranks | Should -Be 'CPU#1'
        $r[0].CpuPercent | Should -Be 50
        $r[0].AvgCpuMs | Should -Be 500
        $r[0].ObjectName | Should -Be 'dbo.GetOrders'
        $r[0].Findings | Should -Match 'ImplicitConversion'
        $r[0].Findings | Should -Match 'MissingIndex'
        $r[0].Findings | Should -Match 'Spill'
        $r[0].Findings | Should -Match 'ParallelPlan'
        $r[0].QueryHash | Should -Be '0x0102'
    }
}
