#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmWaitStatistics

.DESCRIPTION
    Die Fixture ist ein echter Kundenlauf (SQL 2022, SUEB011IBP, Top 25). Genau
    dieser Datensatz hat beide Schwaechen gezeigt: SOS_WORK_DISPATCHER mit 88 %
    der ausgewiesenen Wartezeit und Fehlalarme auf PAGEIOLATCH_SH (2,05 ms) und
    SOS_SCHEDULER_YIELD (0,12 ms).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory

    function New-WaitRow {
        param($Type, [long]$Count, [long]$WaitMs, [long]$MaxMs, [long]$SignalMs, [double]$AvgMs)
        [PSCustomObject]@{
            wait_type             = $Type
            waiting_tasks_count   = $Count
            wait_time_ms          = $WaitMs
            max_wait_time_ms      = $MaxMs
            signal_wait_time_ms   = $SignalMs
            resource_wait_time_ms = $WaitMs - $SignalMs
            avg_wait_ms           = $AvgMs
        }
    }

    $script:CustomerWaits = @(
        New-WaitRow 'SOS_WORK_DISPATCHER' 8481864 59046197000 82628850 3954784 6961.46
        New-WaitRow 'CXCONSUMER' 177252141 2587228100 3953651 37350540 14.6
        New-WaitRow 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP' 19101 1146148900 60160 11790 60004.65
        New-WaitRow 'QDS_ASYNC_QUEUE' 7404 1145894500 109166243 3154 154766.95
        New-WaitRow 'CXPACKET' 395601356 915066700 941341 49989992 2.31
        New-WaitRow 'CXSYNC_PORT' 400081 882142800 26664599 150022 2204.91
        New-WaitRow 'PREEMPTIVE_XE_DISPATCHER' 3 508874500 268086608 0 169624832.33
        New-WaitRow 'BACKUPBUFFER' 97202564 123778700 714 3260932 1.27
        New-WaitRow 'ASYNC_IO_COMPLETION' 327 91442400 4596846 47 279640.5
        New-WaitRow 'BACKUPIO' 67566859 84269500 372 3132415 1.25
        New-WaitRow 'PAGEIOLATCH_SH' 36858777 75560600 1988 3547287 2.05
        New-WaitRow 'OLEDB' 1468903916 47558200 43282 0 0.03
        New-WaitRow 'LATCH_EX' 23827142 36934800 3224 5263450 1.55
        New-WaitRow 'SOS_SCHEDULER_YIELD' 270528765 31433700 3844 31012820 0.12
        New-WaitRow 'BACKUPTHREAD' 8088 24494200 1195866 1286 3028.46
        New-WaitRow 'BROKER_TASK_STOP' 2440 24420700 10061 1400 10008.5
        New-WaitRow 'PAGEIOLATCH_EX' 63742912 16873600 413 156640 0.26
        New-WaitRow 'MEMORY_ALLOCATION_EXT' 9034020323 11463300 221 0 0
        New-WaitRow 'ASYNC_NETWORK_IO' 30531253 7683100 2016 933681 0.25
        New-WaitRow 'MSQL_XP' 107679 6905200 3894 0 64.13
        New-WaitRow 'BUFFERPOOL_SCAN' 3045 4932900 17288 1692 1619.99
        New-WaitRow 'IO_COMPLETION' 6256567 3765500 719 156454 0.6
        New-WaitRow 'SLEEP_BPOOL_FLUSH' 335245 3666700 216 38944 10.94
        New-WaitRow 'WAIT_ON_SYNC_STATISTICS_REFRESH' 10763 3121200 20119 0 289.99
        New-WaitRow 'WRITELOG' 1288894 2546100 839 97178 1.98
    )
}

AfterAll {
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmWaitStatistics' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Get-sqmWaitStatistics | Should -Not -BeNullOrEmpty
        }

        It '<_> Parameter existiert' -ForEach @('TopN', 'IncludeIdle', 'SnapshotBefore', 'SaveSnapshot', 'OutputPath') {
            (Get-Command Get-sqmWaitStatistics).Parameters.ContainsKey($_) | Should -Be $true
        }
    }

    Context 'Kundenlauf SUEB011IBP (SQL 2022)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { $script:CustomerWaits }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }

            $script:Result = Get-sqmWaitStatistics -SqlInstance 'SUEB011IBP' -TopN 25
            $script:ByType = @{}
            foreach ($r in $script:Result) { $script:ByType[$r.WaitType] = $r }
        }

        It 'Idle-Wait <_> erscheint nicht im Report' -ForEach @(
            'SOS_WORK_DISPATCHER', 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_ASYNC_QUEUE',
            'PREEMPTIVE_XE_DISPATCHER', 'BROKER_TASK_STOP', 'SLEEP_BPOOL_FLUSH',
            'MEMORY_ALLOCATION_EXT'
        ) {
            $script:ByType.ContainsKey($_) | Should -Be $false
        }

        It 'Parallelismus ist der dominierende Befund (~88 % der echten Waits)' {
            $cx = ($script:Result | Where-Object Category -eq 'Parallelism' |
                Measure-Object WaitTimePct -Sum).Sum
            $cx | Should -BeGreaterThan 85
        }

        It 'CXSYNC_PORT wird als Parallelism erkannt, nicht als Other' {
            $script:ByType['CXSYNC_PORT'].Category | Should -Be 'Parallelism'
        }

        It 'CXCONSUMER meldet weiterhin eine Empfehlung' {
            $script:ByType['CXCONSUMER'].Recommendation | Should -Match 'MAXDOP'
        }

        It 'PAGEIOLATCH_SH mit 2,05 ms meldet keinen I/O-Engpass' {
            $script:ByType['PAGEIOLATCH_SH'].Recommendation | Should -Not -Match 'bottleneck|Engpass'
        }

        It 'PAGEIOLATCH_SH weist den Durchschnitt als unauffaellig aus' {
            $script:ByType['PAGEIOLATCH_SH'].Recommendation | Should -Match '2[.,]05'
        }

        It 'SOS_SCHEDULER_YIELD meldet keinen CPU-Druck (Signal-Wait-Anteil 2,7 %)' {
            $rec = $script:ByType['SOS_SCHEDULER_YIELD'].Recommendation
            $rec | Should -Not -Match 'optimize long-running|langlaufende Abfragen'
            $rec | Should -Match 'Inconspicuous|Unauffaellig'
        }

        It 'ASYNC_NETWORK_IO mit 0,25 ms meldet keinen langsamen Client' {
            $script:ByType['ASYNC_NETWORK_IO'].Recommendation | Should -Not -Match 'too slowly|zu langsam'
        }

        It 'SignalWaitPct wird je Wait ausgewiesen' {
            $script:ByType['SOS_SCHEDULER_YIELD'].SignalWaitPct | Should -BeGreaterThan 90
        }

        It 'WaitTimePct summiert sich ueber die bereinigte Basis auf ~100 %' {
            ($script:Result | Measure-Object WaitTimePct -Sum).Sum | Should -BeGreaterThan 99
        }
    }

    Context 'Schwellwerte feuern bei echten Problemen' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'PAGEIOLATCH_SH mit 45 ms meldet den I/O-Engpass' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-WaitRow 'PAGEIOLATCH_SH' 1000 45000 500 100 45.0)
            }
            $r = Get-sqmWaitStatistics -SqlInstance 'TESTSERVER'
            $r.Recommendation | Should -Match 'bottleneck|Engpass'
        }

        It 'SOS_SCHEDULER_YIELD meldet CPU-Druck bei hohem Signal-Wait-Anteil' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-WaitRow 'SOS_SCHEDULER_YIELD' 100000 50000 10 45000 0.5)
            }
            $r = Get-sqmWaitStatistics -SqlInstance 'TESTSERVER'
            $r.Recommendation | Should -Match 'CPU pressure|CPU-Druck'
        }

        It 'THREADPOOL meldet immer, unabhaengig vom Durchschnitt' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-WaitRow 'THREADPOOL' 10 20 5 2 2.0)
            }
            $r = Get-sqmWaitStatistics -SqlInstance 'TESTSERVER'
            $r.Recommendation | Should -Match 'worker|Worker'
        }
    }

    Context 'IncludeIdle' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { $script:CustomerWaits }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Mit -IncludeIdle erscheinen die Idle-Waits wieder' {
            $r = Get-sqmWaitStatistics -SqlInstance 'SUEB011IBP' -IncludeIdle -TopN 25
            $r.WaitType | Should -Contain 'SOS_WORK_DISPATCHER'
        }
    }

    Context 'Snapshot-Vergleich' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'SaveSnapshot liefert die Rohdaten zurueck' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-WaitRow 'CXPACKET' 100 5000 50 20 50.0)
            }
            $snap = Get-sqmWaitStatistics -SqlInstance 'TESTSERVER' -SaveSnapshot
            $snap.wait_type    | Should -Be 'CXPACKET'
            $snap.wait_time_ms | Should -Be 5000
        }

        # Die Schwellwerte muessen im Delta-Modus auf den Delta-Durchschnitt greifen,
        # nicht auf den kumulierten - sonst haengt die Bewertung wieder an der Uptime.
        It 'Delta-Modus bewertet den Delta-Durchschnitt (60 ms meldet den Engpass)' {
            $before = @(New-WaitRow 'PAGEIOLATCH_SH' 100 1000 50 100 10.0)
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-WaitRow 'PAGEIOLATCH_SH' 200 7000 50 700 35.0)
            }
            $r = Get-sqmWaitStatistics -SqlInstance 'TESTSERVER' -SnapshotBefore $before -EnableException
            $r.IsDelta        | Should -Be $true
            $r.WaitTimeSec    | Should -Be 6.0
            $r.AvgWaitMs      | Should -Be 60
            $r.SignalWaitPct  | Should -Be 10
            $r.Recommendation | Should -Match 'bottleneck|Engpass'
        }

        It 'Delta-Modus: niedriger Delta-Durchschnitt meldet keinen Engpass' {
            $before = @(New-WaitRow 'PAGEIOLATCH_SH' 100 1000 50 100 10.0)
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-WaitRow 'PAGEIOLATCH_SH' 1100 3000 50 300 2.7)
            }
            $r = Get-sqmWaitStatistics -SqlInstance 'TESTSERVER' -SnapshotBefore $before -EnableException
            $r.AvgWaitMs      | Should -Be 2
            $r.Recommendation | Should -Match 'Inconspicuous|Unauffaellig'
        }
    }

    Context 'Randfaelle' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Nur Idle-Waits: leeres Ergebnis statt Division durch Null' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(
                    New-WaitRow 'SOS_WORK_DISPATCHER' 100 5000000 900 10 50000.0
                    New-WaitRow 'QDS_ASYNC_QUEUE' 50 4000000 800 5 80000.0
                )
            }
            $script:r = $null
            { $script:r = Get-sqmWaitStatistics -SqlInstance 'TESTSERVER' -EnableException } | Should -Not -Throw
            $script:r | Should -BeNullOrEmpty
        }

        It 'Wait mit wait_time_ms = 0 wirft nicht' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-WaitRow 'PAGEIOLATCH_SH' 5 0 0 0 0.0)
            }
            { Get-sqmWaitStatistics -SqlInstance 'TESTSERVER' -EnableException } | Should -Not -Throw
        }
    }

    Context 'Ausgabe' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { $script:CustomerWaits }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Laeuft mit OutputPath ohne Fehler durch' {
            { Get-sqmWaitStatistics -SqlInstance 'SUEB011IBP' -OutputPath $script:TestDir -NoOpen } |
                Should -Not -Throw
        }
    }
}
