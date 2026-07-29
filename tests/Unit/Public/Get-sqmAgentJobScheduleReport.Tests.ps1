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
