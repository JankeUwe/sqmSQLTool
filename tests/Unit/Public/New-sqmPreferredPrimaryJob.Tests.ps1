#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer New-sqmPreferredPrimaryJob.
    New-sqmAgentCommandJob und die dbatools-Aufrufe werden gemockt - getestet wird, WAS an Job,
    Step-Parametern und Zeitplan erzeugt wuerde.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'New-sqmPreferredPrimaryJob' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command New-sqmPreferredPrimaryJob | Should -Not -BeNullOrEmpty
        }

        It '<_> Parameter existiert' -ForEach @(
            'AvailabilityGroup', 'PreferredReplica', 'JobName', 'IntervalMinutes', 'StartTime',
            'CheckOnly', 'FailOnBlocked', 'Force', 'StartJob'
        ) {
            (Get-Command New-sqmPreferredPrimaryJob).Parameters.ContainsKey($_) | Should -Be $true
        }

        It 'IntervalMinutes ausserhalb 1-1440 wird abgelehnt' {
            {
                New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' `
                    -PreferredReplica 'SQL01' -IntervalMinutes 0 -Confirm:$false
            } | Should -Throw
        }
    }

    Context 'Joberzeugung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool New-DbaAgentSchedule { }
            Mock -ModuleName sqmSQLTool Start-DbaAgentJob { }
            Mock -ModuleName sqmSQLTool New-sqmAgentCommandJob {
                [PSCustomObject]@{ JobName = 'x'; Status = 'Success'; Timestamp = Get-Date }
            }
        }

        It 'Leitet den Jobnamen aus dem AG-Namen ab' {
            $r = New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Success'
            $r.JobName | Should -Be 'sqmPreferredPrimary_AG_Test'
            $r.ScheduleName | Should -Be 'sch_sqmPreferredPrimary_AG_Test'
        }

        It 'Legt genau einen Step mit der Pruefroutine an' {
            New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                @($Command)[0].FunctionName -eq 'Invoke-sqmPreferredPrimaryCheck' -and
                @($Command)[0].Parameters['AvailabilityGroup'] -eq 'AG_Test' -and
                @($Command)[0].Parameters['PreferredReplica'] -eq 'SQL01' -and
                $ScheduleType -eq 'None'
            }
        }

        It 'Uebernimmt nur gesetzte Policy-Parameter in den Step' {
            New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -MinRoleAgeMinutes 45 -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                @($Command)[0].Parameters['MinRoleAgeMinutes'] -eq 45 -and
                -not @($Command)[0].Parameters.ContainsKey('MaxRedoQueueMB') -and
                -not @($Command)[0].Parameters.ContainsKey('CheckOnly')
            }
        }

        It 'Reicht -CheckOnly und -FailOnBlocked an die Pruefroutine durch' {
            New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -CheckOnly -FailOnBlocked -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                @($Command)[0].Parameters['CheckOnly'] -eq $true -and
                @($Command)[0].Parameters['FailOnBlocked'] -eq $true
            }
        }

        It 'Legt einen Minutenzeitplan mit dem gewuenschten Intervall an' {
            New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -IntervalMinutes 15 -StartTime '06:30' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-DbaAgentSchedule -Exactly 1 -ParameterFilter {
                $FrequencyType -eq 'Daily' -and
                $FrequencySubdayType -eq 'Minutes' -and
                $FrequencySubdayInterval -eq 15 -and
                $StartTime -eq '063000'
            }
        }

        It 'Startet den Job nur mit -StartJob' {
            New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Start-DbaAgentJob -Exactly 0

            New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -StartJob -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Start-DbaAgentJob -Exactly 1
        }

        It 'Ersetzt bei -WhatIf nichts' {
            New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -WhatIf | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-DbaAgentSchedule -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Start-DbaAgentJob -Exactly 0
        }
    }

    Context 'Fehlerbehandlung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool New-DbaAgentSchedule { }
            Mock -ModuleName sqmSQLTool Start-DbaAgentJob { }
        }

        It 'Legt keinen Zeitplan an, wenn der Job nicht erzeugt werden konnte' {
            Mock -ModuleName sqmSQLTool New-sqmAgentCommandJob {
                [PSCustomObject]@{ JobName = 'x'; Status = 'Failed'; Message = 'Job existiert bereits'; Timestamp = Get-Date }
            }
            $r = New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -Confirm:$false -ErrorAction SilentlyContinue
            $r.Status | Should -Be 'Failed'
            Should -Invoke -ModuleName sqmSQLTool New-DbaAgentSchedule -Exactly 0
        }

        It 'AllowedTimeStart ohne AllowedTimeEnd wird abgelehnt' {
            Mock -ModuleName sqmSQLTool New-sqmAgentCommandJob { [PSCustomObject]@{ Status = 'Success' } }
            {
                New-sqmPreferredPrimaryJob -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' `
                    -PreferredReplica 'SQL01' -AllowedTimeStart '06:00' -EnableException -Confirm:$false
            } | Should -Throw
        }
    }
}
