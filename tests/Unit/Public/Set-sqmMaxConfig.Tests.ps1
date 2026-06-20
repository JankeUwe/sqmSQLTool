#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Set-sqmMaxMemory und Set-sqmMaxDop (dbatools gemockt).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Set-sqmMaxMemory' {
    It 'Funktion existiert und unterstuetzt ShouldProcess' {
        $cmd = Get-Command Set-sqmMaxMemory
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.ContainsKey('WhatIf')  | Should -Be $true
        $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
    }

    Context 'Ausfuehrung (gemockt)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Get-DbaMaxMemory { [PSCustomObject]@{ MaxValue = 4096; Total = 32768 } }
            Mock -ModuleName sqmSQLTool Set-DbaMaxMemory { [PSCustomObject]@{ MaxValue = 29491 } }
        }

        It 'Setzt unter -WhatIf nichts (Status WhatIf, kein Set-DbaMaxMemory)' {
            $r = Set-sqmMaxMemory -SqlInstance 'SQL01' -WhatIf
            $r.Status | Should -Be 'WhatIf'
            Should -Invoke -ModuleName sqmSQLTool Set-DbaMaxMemory -Times 0
        }

        It 'Setzt expliziten Wert und meldet Success' {
            $r = Set-sqmMaxMemory -SqlInstance 'SQL01' -MaxMemoryMB 29491 -Confirm:$false
            $r.Status      | Should -Be 'Success'
            $r.NewMaxMemMB | Should -Be 29491
            Should -Invoke -ModuleName sqmSQLTool Set-DbaMaxMemory -Times 1
        }
    }
}

Describe 'Set-sqmMaxDop' {
    It 'Funktion existiert und unterstuetzt ShouldProcess' {
        $cmd = Get-Command Set-sqmMaxDop
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.ContainsKey('WhatIf')           | Should -Be $true
        $cmd.Parameters.ContainsKey('SkipCostThreshold') | Should -Be $true
    }

    Context 'Ausfuehrung (gemockt)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Get-WmiObject { [PSCustomObject]@{ NumberOfLogicalProcessors = 4 } }
            Mock -ModuleName sqmSQLTool Get-DbaSpConfigure { [PSCustomObject]@{ RunningValue = 0 } }
            Mock -ModuleName sqmSQLTool Set-DbaSpConfigure { }
        }

        It 'Setzt unter -WhatIf nichts' {
            $r = Set-sqmMaxDop -SqlInstance 'SQL01' -WhatIf
            $r.Status    | Should -Be 'WhatIf'
            $r.NewMaxDop | Should -Be 4
            Should -Invoke -ModuleName sqmSQLTool Set-DbaSpConfigure -Times 0
        }

        It 'Setzt MAXDOP + Cost Threshold (2 sp_configure-Aufrufe)' {
            $r = Set-sqmMaxDop -SqlInstance 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Success'
            Should -Invoke -ModuleName sqmSQLTool Set-DbaSpConfigure -Times 2
        }

        It 'Mit -SkipCostThreshold nur MAXDOP (1 Aufruf)' {
            $r = Set-sqmMaxDop -SqlInstance 'SQL01' -MaxDop 2 -SkipCostThreshold -Confirm:$false
            $r.NewMaxDop | Should -Be 2
            Should -Invoke -ModuleName sqmSQLTool Set-DbaSpConfigure -Times 1
        }
    }
}
