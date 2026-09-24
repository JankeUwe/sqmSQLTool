#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Status-Ableitung von Get-sqmAgentJobScheduleReport. Get-DbaAgentJob und
    Invoke-DbaQuery sind gemockt - kein Serverzugriff noetig.

.DESCRIPTION
    Hintergrund: die Funktion hat drei nachweisbare Fehler gehabt, alle gegen eine echte SQL
    2022-Instanz reproduziert, bevor sie behoben wurden:

        1. Ein Job ohne jemals gelaufene Historie wurde als 'Failed' gemeldet statt als "noch nie
           gelaufen" - die T-SQL-CASE-Anweisung fiel bei run_status = NULL in den ELSE-Zweig.
        2. MAX() auf die Ergebnisstrings 'Success'/'Failed' aggregierte alphabetisch statt
           zeitlich ('Success' > 'Failed'): ein Job, dessen LETZTER Lauf tatsaechlich
           fehlgeschlagen ist, aber irgendwann vorher einmal erfolgreich war, wurde als 'Success'
           gemeldet.
        3. Ein Job mit zwei oder mehr Zeitplaenen wurde durch den JOIN auf sysjobschedules
           vervielfacht - PowerShell bekam pro Job mehrere Zeilen und behandelte Felder wie
           LastRunDate/LastRunStatus faelschlich als Arrays statt als Einzelwerte (sichtbar als
           "Never" bei LastExecution und "System.Object[]" bei LastStatus in Berichten).

    Der SQL-seitige Teil (ROW_NUMBER-basierte Ermittlung des tatsaechlich letzten Laufs, ein
    reprsentativer Zeitplan je Job statt Vervielfachung) wurde live gegen SQL Server 2022 verifiziert
    und laesst sich hier nicht sinnvoll nachbilden - Mocks liefern bereits das fertige Abfrageergebnis.
    Diese Tests sichern die PowerShell-seitige Interpretation: die Drei-Zustands-Ableitung
    (Success/Failed/Never Run) und die Zeitplan-Anzeige bei mehreren Zeitplaenen.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmAgentJobScheduleReport - Statusableitung' {

    BeforeAll {
        $script:FakeJobs = @(
            [PSCustomObject]@{ Name = 'JobNieGelaufen'; IsEnabled = $true }
            [PSCustomObject]@{ Name = 'JobErfolgreich'; IsEnabled = $true }
            [PSCustomObject]@{ Name = 'JobLetzterLaufFehlgeschlagen'; IsEnabled = $true }
            [PSCustomObject]@{ Name = 'JobMitZweiZeitplaenen'; IsEnabled = $true }
        )

        $script:FakeHistory = @(
            # 1) Noch nie gelaufen: kein LastRun-Datensatz, keine Zeitplaene.
            [PSCustomObject]@{
                JobName = 'JobNieGelaufen'; IsEnabled = $true; ScheduleCount = 0
                ScheduleName = $null; FrequencyType = $null; FrequencyInterval = $null
                SubdayType = $null; SubdayInterval = $null; ActiveStartTime = $null
                LastRunDate = $null; LastRunTime = $null; LastRunStatus = $null
                AvgDurationSeconds = $null; LastErrorMessage = $null
            }
            # 2) Ein Zeitplan, letzter (und einziger) Lauf erfolgreich.
            [PSCustomObject]@{
                JobName = 'JobErfolgreich'; IsEnabled = $true; ScheduleCount = 1
                ScheduleName = 'Taeglich_0200'; FrequencyType = 4; FrequencyInterval = 1
                SubdayType = 0; SubdayInterval = 0; ActiveStartTime = 20000
                LastRunDate = 20260729; LastRunTime = 70000; LastRunStatus = 'Success'
                AvgDurationSeconds = 12.5; LastErrorMessage = $null
            }
            # 3) Simuliert das Ergebnis NACH dem ROW_NUMBER-Fix: der zurueckgegebene Datensatz
            #    entspricht bereits dem tatsaechlich letzten (fehlgeschlagenen) Lauf, obwohl ein
            #    frueherer Lauf erfolgreich war (das war der eigentliche MAX()-Bug).
            [PSCustomObject]@{
                JobName = 'JobLetzterLaufFehlgeschlagen'; IsEnabled = $true; ScheduleCount = 0
                ScheduleName = $null; FrequencyType = $null; FrequencyInterval = $null
                SubdayType = $null; SubdayInterval = $null; ActiveStartTime = $null
                LastRunDate = 20260729; LastRunTime = 71204; LastRunStatus = 'Failed'
                AvgDurationSeconds = 5.0; LastErrorMessage = 'Absichtlicher Testfehler'
            }
            # 4) Zwei Zeitplaene - die Abfrage liefert nur noch EINEN reprsentativen Zeitplan samt
            #    Gesamtzahl, keine Vervielfachung mehr.
            [PSCustomObject]@{
                JobName = 'JobMitZweiZeitplaenen'; IsEnabled = $true; ScheduleCount = 2
                ScheduleName = 'Taeglich_0200'; FrequencyType = 4; FrequencyInterval = 1
                SubdayType = 0; SubdayInterval = 0; ActiveStartTime = 20000
                LastRunDate = 20260729; LastRunTime = 70412; LastRunStatus = 'Success'
                AvgDurationSeconds = 8.0; LastErrorMessage = $null
            }
        )
    }

    # Mocks und Funktionsaufruf muessen im SELBEN InModuleScope-Block stehen - ein Mock, der in
    # einem separaten InModuleScope-Aufruf (z.B. in einem eigenen BeforeEach) gesetzt wird, gilt
    # nicht automatisch in einem weiteren InModuleScope-Aufruf im It-Block.

    It 'meldet einen Job ohne Historie als "Never Run", NICHT als "Failed"' {
        InModuleScope sqmSQLTool -Parameters @{ FakeJobs = $script:FakeJobs; FakeHistory = $script:FakeHistory } {
            param($FakeJobs, $FakeHistory)
            Mock Invoke-sqmLogging { }
            Mock Invoke-sqmOpenReport { }
            Mock Get-DbaAgentJob { $FakeJobs }
            Mock Invoke-DbaQuery { $FakeHistory }

            $data = Get-sqmAgentJobScheduleReport -SqlInstance 'SQL01' -OutputPath $TestDrive -EnableException -NoOpen
            $job = $data | Where-Object JobName -eq 'JobNieGelaufen'

            $job.LastStatus    | Should -Be 'Never Run'
            $job.LastExecution | Should -Be 'Never'
            $job.Schedule      | Should -Be 'No Schedule'
        }
    }

    It 'meldet einen erfolgreichen Job korrekt als "Success" mit lesbarem Zeitplan' {
        InModuleScope sqmSQLTool -Parameters @{ FakeJobs = $script:FakeJobs; FakeHistory = $script:FakeHistory } {
            param($FakeJobs, $FakeHistory)
            Mock Invoke-sqmLogging { }
            Mock Invoke-sqmOpenReport { }
            Mock Get-DbaAgentJob { $FakeJobs }
            Mock Invoke-DbaQuery { $FakeHistory }

            $data = Get-sqmAgentJobScheduleReport -SqlInstance 'SQL01' -OutputPath $TestDrive -EnableException -NoOpen
            $job = $data | Where-Object JobName -eq 'JobErfolgreich'

            $job.LastStatus    | Should -Be 'Success'
            $job.LastExecution | Should -Be '2026-07-29 07:00:00'
            $job.Schedule      | Should -Match 'Daily'
        }
    }

    It 'meldet den tatsaechlich letzten (fehlgeschlagenen) Lauf als "Failed" samt Fehlermeldung' {
        InModuleScope sqmSQLTool -Parameters @{ FakeJobs = $script:FakeJobs; FakeHistory = $script:FakeHistory } {
            param($FakeJobs, $FakeHistory)
            Mock Invoke-sqmLogging { }
            Mock Invoke-sqmOpenReport { }
            Mock Get-DbaAgentJob { $FakeJobs }
            Mock Invoke-DbaQuery { $FakeHistory }

            $data = Get-sqmAgentJobScheduleReport -SqlInstance 'SQL01' -OutputPath $TestDrive -EnableException -NoOpen
            $job = $data | Where-Object JobName -eq 'JobLetzterLaufFehlgeschlagen'

            $job.LastStatus | Should -Be 'Failed'
            $job.LastError  | Should -Match 'Testfehler'
        }
    }

    It 'zeigt bei mehreren Zeitplaenen einen sauberen Skalarwert, nicht "System.Object[]", und nennt die Gesamtzahl' {
        InModuleScope sqmSQLTool -Parameters @{ FakeJobs = $script:FakeJobs; FakeHistory = $script:FakeHistory } {
            param($FakeJobs, $FakeHistory)
            Mock Invoke-sqmLogging { }
            Mock Invoke-sqmOpenReport { }
            Mock Get-DbaAgentJob { $FakeJobs }
            Mock Invoke-DbaQuery { $FakeHistory }

            $data = Get-sqmAgentJobScheduleReport -SqlInstance 'SQL01' -OutputPath $TestDrive -EnableException -NoOpen
            $job = $data | Where-Object JobName -eq 'JobMitZweiZeitplaenen'

            $job.LastStatus    | Should -Be 'Success'
            $job.LastStatus    | Should -BeOfType [string]
            $job.LastExecution | Should -Be '2026-07-29 07:04:12'
            $job.Schedule      | Should -Match 'weitere'
        }
    }

    It 'zaehlt "Never Run" weder als Erfolg noch als Fehlschlag in der Zusammenfassung' {
        InModuleScope sqmSQLTool -Parameters @{ FakeJobs = $script:FakeJobs; FakeHistory = $script:FakeHistory } {
            param($FakeJobs, $FakeHistory)
            Mock Invoke-sqmLogging { }
            Mock Invoke-sqmOpenReport { }
            Mock Get-DbaAgentJob { $FakeJobs }
            Mock Invoke-DbaQuery { $FakeHistory }

            $data = Get-sqmAgentJobScheduleReport -SqlInstance 'SQL01' -OutputPath $TestDrive -EnableException -NoOpen
            $neverRunJobs = @($data | Where-Object LastStatus -eq 'Never Run')
            $neverRunJobs.Count | Should -BeGreaterThan 0
            foreach ($j in $neverRunJobs)
            {
                $j.LastStatus | Should -Not -Be 'Success'
                $j.LastStatus | Should -Not -Be 'Failed'
            }
        }
    }
}

Describe '_ConvertJobSchedule - Zeitplantext' {

    # Frueher lieferte freq_type 8 nur 'Weekly' ohne Wochentag, freq_type 32 nur 'Monthly (relative)'.
    It 'liefert fuer <Case> den Text "<Expected>"' -TestCases @(
        @{ Case = 'Weekly Sonntag';          Expected = 'Weekly on Sunday @ 00:00';                 P = @{ FrequencyType = 8;  FrequencyInterval = 1;   RecurrenceFactor = 1; StartTime = 0 } }
        @{ Case = 'Weekly Mo+Mi+Fr';         Expected = 'Weekly on Monday, Wednesday, Friday @ 22:30'; P = @{ FrequencyType = 8;  FrequencyInterval = 42;  RecurrenceFactor = 1; StartTime = 223000 } }
        @{ Case = 'Weekly alle Tage';        Expected = 'Weekly on all days @ 01:00';              P = @{ FrequencyType = 8;  FrequencyInterval = 127; RecurrenceFactor = 1; StartTime = 10000 } }
        @{ Case = 'alle 2 Wochen Samstag';   Expected = 'Weekly (every 2 weeks) on Saturday @ 03:00'; P = @{ FrequencyType = 8; FrequencyInterval = 64; RecurrenceFactor = 2; StartTime = 30000 } }
        @{ Case = 'Monthly Tag 15';          Expected = 'Monthly on day 15 @ 04:00';                P = @{ FrequencyType = 16; FrequencyInterval = 15;  RecurrenceFactor = 1; StartTime = 40000 } }
        @{ Case = 'letzter Sonntag im Monat';Expected = 'Monthly on the last Sunday @ 05:00';       P = @{ FrequencyType = 32; FrequencyInterval = 1;   RelativeInterval = 16; RecurrenceFactor = 1; StartTime = 50000 } }
        @{ Case = 'erster Wochentag';        Expected = 'Monthly on the first weekday @ 06:00';     P = @{ FrequencyType = 32; FrequencyInterval = 9;   RelativeInterval = 1;  RecurrenceFactor = 1; StartTime = 60000 } }
        @{ Case = 'Daily alle 15 Min';       Expected = 'Daily (every 1 day(s)) every 15 minute(s)'; P = @{ FrequencyType = 4; FrequencyInterval = 1; SubdayType = 4; SubdayInterval = 15; StartTime = 0; EndTime = 235959 } }
        @{ Case = 'Weekly Mo stuendl. Fenster'; Expected = 'Weekly on Monday every 1 hour(s) between 06:00 and 18:00'; P = @{ FrequencyType = 8; FrequencyInterval = 2; RecurrenceFactor = 1; SubdayType = 8; SubdayInterval = 1; StartTime = 60000; EndTime = 180000 } }
        @{ Case = 'One Time';                Expected = 'One Time on 2026-10-01 @ 12:00';          P = @{ FrequencyType = 1;  FrequencyInterval = 0;   StartDate = 20261001; StartTime = 120000 } }
    ) {
        param($Case, $Expected, $P)
        InModuleScope sqmSQLTool -Parameters @{ P = $P; Expected = $Expected } {
            param($P, $Expected)
            _ConvertJobSchedule @P | Should -Be $Expected
        }
    }
}
