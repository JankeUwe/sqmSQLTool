#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Install-sqmStandardJob und New-sqmAutoLoginSyncJob.
    New-sqmAgentCommandJob wird gemockt - getestet wird, WAS an Job, Step-Parametern und
    Zeitplan erzeugt wuerde.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Install-sqmStandardJob' {

    BeforeAll {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool New-sqmAgentCommandJob {
            [PSCustomObject]@{ JobName = $JobName; ScheduleName = "sch_$JobName"; Started = [bool]$StartJob; Status = 'Success'; Timestamp = Get-Date }
        }
        # Failover-Alert (msdb): ohne Mock ginge der Aufruf an einen echten Server.
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            [PSCustomObject]@{ Result = 'Created'; AlertName = @($SqlParameter)[0]['alertName'] }
        }
    }

    Context 'Katalog' {
        It '-List zeigt alle Standard-Jobs ohne etwas anzulegen' {
            $l = @(Install-sqmStandardJob -List)
            $l.Name | Should -Contain 'AgLoginSync'
            $l.Name | Should -Contain 'AgLoginCompare'
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 0
        }

        It 'Unbekannter Name wird abgelehnt' {
            { Install-sqmStandardJob -Name 'Gibtsnicht' -Confirm:$false } | Should -Throw
        }
    }

    Context 'AgLoginSync' {
        It 'Legt den Sync mit Force:$false, SyncMode Union, taeglich 02:00 und PrimaryOnly an' {
            $r = Install-sqmStandardJob -Name AgLoginSync -SqlInstance 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Success'
            $r.JobName | Should -Be 'sqmAutoLoginSync'
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                $JobName -eq 'sqmAutoLoginSync' -and
                $ScheduleType -eq 'Daily' -and $ScheduleTime -eq '02:00' -and
                @($Command)[0].FunctionName -eq 'Sync-sqmLoginsToAlwaysOn' -and
                @($Command)[0].PrimaryOnly -eq $true -and
                @($Command)[0].Parameters['Force'] -eq $false -and
                @($Command)[0].Parameters['SyncMode'] -eq 'Union' -and
                @($Command)[0].Parameters['SqlInstance'] -eq 'SQL01'
            }
        }

        It 'Legt den Failover-Alert auf Meldung 1480 fuer den Job an' {
            $r = Install-sqmStandardJob -Name AgLoginSync -SqlInstance 'SQL01' -Confirm:$false
            $r.AlertStatus | Should -Be 'Created'
            $r.AlertName | Should -Be 'sqmAutoLoginSync - AG failover (1480)'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 1 -ParameterFilter {
                $Database -eq 'msdb' -and $Query -match 'sp_add_alert' -and $Query -match '@message_id = 1480' -and
                $Query -match '@delay_between_responses = 600' -and @($SqlParameter)[0]['jobName'] -eq 'sqmAutoLoginSync'
            }
        }

        It 'Haengt den Job an einen vorhandenen 1480-Alert ohne Job' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [PSCustomObject]@{ Result = 'Linked'; AlertName = 'AG Rollenwechsel' } }
            $r = Install-sqmStandardJob -Name AgLoginSync -Confirm:$false
            $r.AlertStatus | Should -Be 'Linked'
            $r.AlertName | Should -Be 'AG Rollenwechsel'
            $r.Status | Should -Be 'Success'
        }

        It 'Warnt, wenn 1480 schon einen anderen Job startet, und laesst den Alert in Ruhe' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [PSCustomObject]@{ Result = 'Occupied'; AlertName = 'Fremd' } }
            $r = Install-sqmStandardJob -Name AgLoginSync -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
            $r.AlertStatus | Should -Be 'Occupied'
            $r.Status | Should -Be 'Success'
            ($w -join ' ') | Should -Match "'Fremd' ueberwacht 1480"
        }

        It 'Job bleibt Success, wenn der Alert scheitert' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { if ($EnableException) { throw 'msdb nicht erreichbar' } }
            $r = Install-sqmStandardJob -Name AgLoginSync -Confirm:$false -WarningAction SilentlyContinue
            $r.Status | Should -Be 'Success'
            $r.AlertStatus | Should -Be 'Failed'
            $r.Message | Should -Match 'msdb nicht erreichbar'
        }

        It '-NoFailoverAlert legt keinen Alert an und entfernt einen eigenen alten' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [PSCustomObject]@{ Result = 'Removed' } }
            $r = Install-sqmStandardJob -Name AgLoginSync -NoFailoverAlert -Confirm:$false
            $r.AlertStatus | Should -Be 'Removed'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 0 -ParameterFilter { $Query -match 'sp_add_alert' }
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 1 -ParameterFilter {
                $Query -match 'sp_delete_alert' -and @($SqlParameter)[0]['alertName'] -eq 'sqmAutoLoginSync - AG failover (1480)'
            }
        }

        It 'Kein Alert, wenn der Job nicht angelegt wurde' {
            Mock -ModuleName sqmSQLTool New-sqmAgentCommandJob { [PSCustomObject]@{ JobName = 'x'; Status = 'Failed'; Message = 'Job existiert bereits' } }
            Install-sqmStandardJob -Name AgLoginSync -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 0
        }

        It 'AG-Name, eigene Parameter und Zeitplan ueberschreiben den Katalog' {
            Install-sqmStandardJob -Name AgLoginSync -SqlInstance 'SQL01' -AvailabilityGroupName 'AG1' `
                -Parameters @{ AuditAdOrphans = $true } -ScheduleTime '04:15' -JobName 'X_Sync' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                $JobName -eq 'X_Sync' -and $ScheduleTime -eq '04:15' -and
                @($Command)[0].Parameters['AvailabilityGroupName'] -eq 'AG1' -and
                @($Command)[0].Parameters['AuditAdOrphans'] -eq $true -and
                @($Command)[0].Parameters['Force'] -eq $false
            }
        }

        It 'Warnt bei Force=$true (DROP+CREATE)' {
            Install-sqmStandardJob -Name AgLoginSync -Parameters @{ Force = $true } -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            ($w -join ' ') | Should -Match 'DROP\+CREATE'
        }

        It 'Reicht -Force und -StartJob durch' {
            Install-sqmStandardJob -Name AgLoginSync -Force -StartJob -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                $Force -eq $true -and $StartJob -eq $true
            }
        }

        It 'Legt bei -WhatIf nichts an' {
            Install-sqmStandardJob -Name AgLoginSync -WhatIf | Out-Null
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 0
        }
    }

    Context 'AgLoginCompare' {
        It 'Legt den Vergleich mit FailOnDrift, taeglich 06:00 und PrimaryOnly an, ohne Failover-Alert' {
            Install-sqmStandardJob -Name AgLoginCompare -SqlInstance 'SQL01' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                $JobName -eq 'sqmAutoLoginCompare' -and $ScheduleTime -eq '06:00' -and
                @($Command)[0].FunctionName -eq 'Compare-sqmAlwaysOnLogins' -and
                @($Command)[0].PrimaryOnly -eq $true -and
                @($Command)[0].Parameters['FailOnDrift'] -eq $true
            }
        }
    }

    Context 'Fehlerbehandlung' {
        It 'Meldet Failed, wenn der Job nicht angelegt werden konnte' {
            Mock -ModuleName sqmSQLTool New-sqmAgentCommandJob {
                [PSCustomObject]@{ JobName = 'x'; Status = 'Failed'; Message = 'Job existiert bereits'; Timestamp = Get-Date }
            }
            $r = Install-sqmStandardJob -Name AgLoginSync -Confirm:$false
            $r.Status | Should -Be 'Failed'
            $r.Message | Should -Match 'existiert bereits'
        }
    }
}

Describe 'New-sqmAutoLoginSyncJob' {
    BeforeAll {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool New-sqmAgentCommandJob {
            [PSCustomObject]@{ JobName = $JobName; Status = 'Success'; Timestamp = Get-Date }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [PSCustomObject]@{ Result = 'Created'; AlertName = @($SqlParameter)[0]['alertName'] } }
    }

    It 'Reicht -NoFailoverAlert durch' {
        New-sqmAutoLoginSyncJob -SqlInstance 'SQL01' -NoFailoverAlert | Out-Null
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 0 -ParameterFilter { $Query -match 'sp_add_alert' }
    }

    It 'Installiert den Standard-Job AgLoginSync unter dem bisherigen Jobnamen' {
        $r = New-sqmAutoLoginSyncJob -SqlInstance 'SQL01' -AvailabilityGroupName 'AG1' -AuditAdOrphans -BackupRetentionDays 14 -Force
        $r.Name | Should -Be 'AgLoginSync'
        Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
            $JobName -eq 'sqmAutoLoginSync' -and $Force -eq $true -and
            @($Command)[0].Parameters['AvailabilityGroupName'] -eq 'AG1' -and
            @($Command)[0].Parameters['AuditAdOrphans'] -eq $true -and
            @($Command)[0].Parameters['BackupRetentionDays'] -eq 14 -and
            @($Command)[0].Parameters['Force'] -eq $false
        }
    }
}
