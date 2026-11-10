#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Stepnamen-Vergabe von New-sqmAgentCommandJob (v1.9.222.0). dbatools-Cmdlets
    sind gemockt, es wird mit -WhatIf aufgerufen - kein Server- oder Dateizugriff.

.DESCRIPTION
    Fehler: -AppendStep mit einem Befehl, dessen abgeleiteter Stepname (= Funktionsname) im Job
    schon vorkam, brach mit "StepName existiert bereits" ab, weil Eindeutigkeit nur innerhalb von
    -Command geprueft wurde.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'New-sqmAgentCommandJob - Stepnamen bei -AppendStep' {

    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [PSCustomObject]@{ HostName = $env:COMPUTERNAME; InstanceName = 'MSSQLSERVER' } }
        Mock -ModuleName sqmSQLTool Get-DbaAgentJob { [PSCustomObject]@{ Name = 'J1' } }
        Mock -ModuleName sqmSQLTool Get-DbaAgentJobStep {
            @(
                [PSCustomObject]@{ ID = 1; Name = 'Get-sqmDiskSpaceReport'; OnSuccessAction = 'GoToNextStep' }
                [PSCustomObject]@{ ID = 2; Name = 'Get-sqmDiskSpaceReport_2'; OnSuccessAction = 'QuitWithSuccess' }
            )
        }
        Mock -ModuleName sqmSQLTool New-Item { }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
    }

    It 'haengt denselben Befehl an und vergibt einen freien Zaehlernamen' {
        $r = New-sqmAgentCommandJob -SqlInstance 'X' -JobName 'J1' -AppendStep -WhatIf -Command @{ FunctionName = 'Get-sqmDiskSpaceReport' }
        $r.Status | Should -Be 'Success'
        $r.Steps[0].StepName | Should -Be 'Get-sqmDiskSpaceReport_3'
        $r.Steps[0].StepId | Should -Be 3
    }

    It 'zaehlt auch innerhalb von -Command weiter' {
        $r = New-sqmAgentCommandJob -SqlInstance 'X' -JobName 'J1' -AppendStep -WhatIf -Command @(
            @{ FunctionName = 'Get-sqmDiskSpaceReport' }, @{ FunctionName = 'Get-sqmDiskSpaceReport' })
        ($r.Steps.StepName) | Should -Be @('Get-sqmDiskSpaceReport_3', 'Get-sqmDiskSpaceReport_4')
    }

    It 'uebernimmt einen freien, ausdruecklichen StepName unveraendert' {
        $r = New-sqmAgentCommandJob -SqlInstance 'X' -JobName 'J1' -AppendStep -WhatIf -Command @{ FunctionName = 'Get-sqmDiskSpaceReport'; StepName = 'Disk Nachmittag' }
        $r.Steps[0].StepName | Should -Be 'Disk Nachmittag'
    }

    It 'meldet einen ausdruecklichen, schon vorhandenen StepName als Fehler' {
        $r = New-sqmAgentCommandJob -SqlInstance 'X' -JobName 'J1' -AppendStep -WhatIf -ErrorAction SilentlyContinue -Command @{ FunctionName = 'Get-sqmDiskSpaceReport'; StepName = 'Get-sqmDiskSpaceReport' }
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'existiert bereits'
    }
}

Describe 'New-sqmAgentCommandJob - AlwaysOn-Propagierung' {

    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -match 'availability_replicas') { [PSCustomObject]@{ replica_server_name = 'NODE2' } }
            else { [PSCustomObject]@{ HostName = $env:COMPUTERNAME; InstanceName = 'MSSQLSERVER' } }
        }
        Mock -ModuleName sqmSQLTool Get-DbaAgentJob { $null }
        Mock -ModuleName sqmSQLTool New-Item { }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
    }

    It 'legt den Job auch auf dem anderen Replica an und biegt SqlInstance dorthin um' {
        $r = New-sqmAgentCommandJob -SqlInstance 'NODE1' -JobName 'J1' -WhatIf -Command @{
            FunctionName = 'Get-sqmDiskSpaceReport'; Parameters = @{ SqlInstance = 'NODE1' } }
        $r.Status | Should -Be 'Success'
        $r.Replicas.SqlInstance | Should -Be 'NODE2'
        $r.Replicas.Status | Should -Be 'Success'
        Should -Invoke -ModuleName sqmSQLTool Get-DbaAgentJob -ParameterFilter { $SqlInstance.ComputerName -eq 'NODE2' } -Times 2 -Exactly
    }

    It 'bearbeitet mit -SkipAlwaysOnPropagation nur die angegebene Instanz' {
        $r = New-sqmAgentCommandJob -SqlInstance 'NODE1' -JobName 'J1' -WhatIf -SkipAlwaysOnPropagation -Command @{ FunctionName = 'Get-sqmDiskSpaceReport' }
        @($r.Replicas).Count | Should -Be 0
    }
}
