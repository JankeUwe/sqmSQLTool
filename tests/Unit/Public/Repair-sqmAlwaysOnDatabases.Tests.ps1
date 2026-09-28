#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Repair-sqmAlwaysOnDatabases, Schwerpunkt: nur AGs reparieren, in denen
    die Instanz Primary ist. dbatools wird vollstaendig gemockt.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Repair-sqmAlwaysOnDatabases' {

    BeforeAll {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Write-EventLog { }
        Mock -ModuleName sqmSQLTool Invoke-sqmSqlAlwaysOnAutoseeding { @() }
        Mock -ModuleName sqmSQLTool Get-DbaAgDatabase {
            [PSCustomObject]@{ Name = "DB_$AvailabilityGroup"; SynchronizationState = 'NotSynchronizing' }
        }
        Mock -ModuleName sqmSQLTool Remove-DbaAgDatabase { }
        Mock -ModuleName sqmSQLTool Get-DbaAgReplica {
            @([PSCustomObject]@{ Name = 'SQL01'; Role = 'Primary' },
                [PSCustomObject]@{ Name = 'SQL02'; Role = 'Secondary' })
        }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'X'; RecoveryModel = 'Full' } }
        Mock -ModuleName sqmSQLTool Remove-DbaDatabase { }
        Mock -ModuleName sqmSQLTool Add-DbaAgDatabase { }
    }

    It 'Repariert nur die AG, in der die Instanz Primary ist' {
        Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup {
            @([PSCustomObject]@{ Name = 'AG_P'; LocalReplicaRole = 'Primary'; PrimaryReplica = 'SQL01' },
                [PSCustomObject]@{ Name = 'AG_S'; LocalReplicaRole = 'Secondary'; PrimaryReplica = 'SQL03' })
        }
        $r = Repair-sqmAlwaysOnDatabases -SqlInstance 'SQL01' -Confirm:$false
        $r.DatabaseName | Should -Be 'DB_AG_P'
        $r.Status | Should -Be 'RepairSuccess'
        Should -Invoke -ModuleName sqmSQLTool Get-DbaAgDatabase -ParameterFilter { $AvailabilityGroup -eq 'AG_S' } -Exactly 0
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaAgDatabase -ParameterFilter { $AvailabilityGroup -eq 'AG_S' } -Exactly 0
        Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -ParameterFilter { $AvailabilityGroup -eq 'AG_P' } -Exactly 1
    }

    It 'Automatic Seeding wird nur fuer die Primary-AGs gesetzt' {
        Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup {
            @([PSCustomObject]@{ Name = 'AG_P'; LocalReplicaRole = 'Primary'; PrimaryReplica = 'SQL01' },
                [PSCustomObject]@{ Name = 'AG_S'; LocalReplicaRole = 'Secondary'; PrimaryReplica = 'SQL03' })
        }
        Repair-sqmAlwaysOnDatabases -SqlInstance 'SQL01' -Confirm:$false | Out-Null
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmSqlAlwaysOnAutoseeding -ParameterFilter {
            ($AvailabilityGroup -join ',') -eq 'AG_P' -and -not $All
        } -Exactly 1
    }

    It 'Instanz ist nirgends Primary: aendert nichts' {
        Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup {
            [PSCustomObject]@{ Name = 'AG_S'; LocalReplicaRole = 'Secondary'; PrimaryReplica = 'SQL03' }
        }
        $r = Repair-sqmAlwaysOnDatabases -SqlInstance 'SQL01' -Confirm:$false
        $r | Should -BeNullOrEmpty
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmSqlAlwaysOnAutoseeding -Exactly 0
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaAgDatabase -Exactly 0
        Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 0
    }
}
