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
        It 'Legt den Sync mit Force:$false, taeglich 02:00 und PrimaryOnly an' {
            $r = Install-sqmStandardJob -Name AgLoginSync -SqlInstance 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Success'
            $r.JobName | Should -Be 'sqmAutoLoginSync'
            Should -Invoke -ModuleName sqmSQLTool New-sqmAgentCommandJob -Exactly 1 -ParameterFilter {
                $JobName -eq 'sqmAutoLoginSync' -and
                $ScheduleType -eq 'Daily' -and $ScheduleTime -eq '02:00' -and
                @($Command)[0].FunctionName -eq 'Sync-sqmLoginsToAlwaysOn' -and
                @($Command)[0].PrimaryOnly -eq $true -and
                @($Command)[0].Parameters['Force'] -eq $false -and
                @($Command)[0].Parameters['SqlInstance'] -eq 'SQL01'
            }
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
        It 'Legt den Vergleich mit FailOnDrift, taeglich 06:00 und PrimaryOnly an' {
            Install-sqmStandardJob -Name AgLoginCompare -SqlInstance 'SQL01' -Confirm:$false | Out-Null
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
