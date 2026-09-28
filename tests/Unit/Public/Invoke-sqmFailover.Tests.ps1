#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Invoke-sqmFailover: Standard-Instanz, automatische AG-Auswahl und
    Umleitung auf den Primary, wenn die angegebene Instanz Secondary ist.
    dbatools wird vollstaendig gemockt; die Abfragen werden an ihrem Text unterschieden.
#>

# Hinweis: -SqlInstance kommt im Mock als DbaInstanceParameter an, deshalb "$SqlInstance".
BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    # Standard-Topologie: SQL01 Primary, SQL02 Secondary, eine AG 'AG1'
    $script:SetupTopology = {
        param ([string[]]$AgNames = @('AG1'), $PrimaryReplica = 'SQL01')
        $script:agNames = $AgNames
        $script:primary = $PrimaryReplica
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Write-Host { }
        Mock -ModuleName sqmSQLTool Start-Sleep { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'SELECT name FROM sys.availability_groups' } -MockWith {
            $script:agNames | ForEach-Object { [PSCustomObject]@{ name = $_ } }
        }
        # Lokaler Zustand (Pre-Check 1): erkennbar an OperState
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'OperState' } -MockWith {
            $role = if ("$SqlInstance" -eq 'SQL01') { 'PRIMARY' } else { 'SECONDARY' }
            [PSCustomObject]@{ AgName = 'AG1'; Role = $role; SyncHealth = 'HEALTHY'; OperState = 'ONLINE'; PrimaryReplica = $script:primary }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match "role_desc = 'SECONDARY'" } -MockWith {
            [PSCustomObject]@{ ReplicaServer = 'SQL02'; Role = 'SECONDARY'; SyncHealth = 'HEALTHY'; SyncState = 'SYNCHRONIZED'; RedoQueueKB = 0; LogSendQueueKB = 0; AvailMode = 'SYNCHRONOUS_COMMIT' }
        }
        # Post-Check: is_local ohne OperState
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'is_local = 1' -and $Query -notmatch 'OperState' } -MockWith {
            [PSCustomObject]@{ AgName = 'AG1'; Role = 'PRIMARY'; SyncHealth = 'HEALTHY' }
        }
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmFailover' {

    Context 'Parameter' {
        It '<_> ist nicht mehr Pflicht' -ForEach 'SqlInstance', 'AvailabilityGroup' {
            $attr = (Get-Command Invoke-sqmFailover).Parameters[$_].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attr.Mandatory | Should -Be $false
        }
    }

    Context 'Standard: Primary, eine AG' {
        BeforeEach { & $script:SetupTopology }

        It 'Ohne -SqlInstance wird der Rechnername verwendet' {
            & $script:SetupTopology -PrimaryReplica $env:COMPUTERNAME
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'OperState' } -MockWith {
                [PSCustomObject]@{ AgName = 'AG1'; Role = 'PRIMARY'; SyncHealth = 'HEALTHY'; OperState = 'ONLINE'; PrimaryReplica = $env:COMPUTERNAME }
            }
            $r = Invoke-sqmFailover -AvailabilityGroup 'AG1' -WhatIf
            $r.OldPrimary | Should -Be $env:COMPUTERNAME
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'OperState' -and "$SqlInstance" -eq $env:COMPUTERNAME } -Exactly 1
        }

        It 'Ohne -AvailabilityGroup wird die einzige AG genommen' {
            $r = Invoke-sqmFailover -SqlInstance 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Success'
            $r.AvailabilityGroup | Should -Be 'AG1'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'ALTER AVAILABILITY GROUP \[AG1\] FAILOVER' -and "$SqlInstance" -eq 'SQL02' } -Exactly 1
        }
    }

    Context 'Angegebene Instanz ist Secondary' {
        BeforeEach { & $script:SetupTopology }

        It 'Wechselt auf den Primary und fuehrt den Failover von dort aus' {
            $r = Invoke-sqmFailover -SqlInstance 'SQL02' -AvailabilityGroup 'AG1' -Confirm:$false
            $r.Status | Should -Be 'Success'
            $r.OldPrimary | Should -Be 'SQL01'
            $r.NewPrimary | Should -Be 'SQL02'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match "role_desc = 'SECONDARY'" -and "$SqlInstance" -eq 'SQL01' } -Exactly 1
        }

        It 'Primary nicht ermittelbar (NULL): bricht ab, kein Failover' {
            & $script:SetupTopology -PrimaryReplica ([System.DBNull]::Value)
            $r = Invoke-sqmFailover -SqlInstance 'SQL02' -AvailabilityGroup 'AG1' -Confirm:$false
            $r.Status | Should -Be 'Failed'
            $r.Message | Should -BeLike '*SQL02*AG1*'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FAILOVER;' } -Exactly 0
        }
    }

    Context 'Mehrere AGs ohne -AvailabilityGroup' {
        BeforeEach { & $script:SetupTopology -AgNames @('AG1', 'AG2') }

        It 'Nicht-interaktiv: Abbruch mit Namensliste, kein Failover' {
            Mock -ModuleName sqmSQLTool Test-sqmInteractiveSession { $false }
            Mock -ModuleName sqmSQLTool Read-Host { throw 'darf nicht fragen' }
            $r = Invoke-sqmFailover -SqlInstance 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Failed'
            $r.Message | Should -BeLike '*AG1, AG2*'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FAILOVER;' } -Exactly 0
        }

        It 'Interaktiv: nimmt die gewaehlte AG' {
            Mock -ModuleName sqmSQLTool Test-sqmInteractiveSession { $true }
            Mock -ModuleName sqmSQLTool Read-Host { '2' }
            $r = Invoke-sqmFailover -SqlInstance 'SQL01' -WhatIf
            $r.AvailabilityGroup | Should -Be 'AG2'
            $r.Status | Should -Be 'WhatIfSkipped'
        }

        It 'Leere Eingabe bricht ab' {
            Mock -ModuleName sqmSQLTool Test-sqmInteractiveSession { $true }
            Mock -ModuleName sqmSQLTool Read-Host { '' }
            $r = Invoke-sqmFailover -SqlInstance 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Failed'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FAILOVER;' } -Exactly 0
        }
    }
}
