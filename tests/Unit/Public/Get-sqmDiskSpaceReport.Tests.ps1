#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmDiskSpaceReport
    dbatools-Abhaengigkeiten werden vollstaendig gemockt.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmDiskSpaceReport' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Get-sqmDiskSpaceReport | Should -Not -BeNullOrEmpty
        }

        It 'SqlInstance ist nicht mandatory (Default = Computername)' {
            $cmd = Get-Command Get-sqmDiskSpaceReport
            $mandatory = $cmd.Parameters['SqlInstance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $false
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmDiskSpaceReport).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'WhatIf wird unterstuetzt' {
            (Get-Command Get-sqmDiskSpaceReport).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'WarnThresholdPct Parameter existiert' {
            (Get-Command Get-sqmDiskSpaceReport).Parameters.ContainsKey('WarnThresholdPct') | Should -Be $true
        }

        It 'CriticalThresholdPct Parameter existiert' {
            (Get-Command Get-sqmDiskSpaceReport).Parameters.ContainsKey('CriticalThresholdPct') | Should -Be $true
        }

        It 'HistoryDays Parameter existiert' {
            (Get-Command Get-sqmDiskSpaceReport).Parameters.ContainsKey('HistoryDays') | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance -Name 'TESTSERVER' }
            Mock -ModuleName sqmSQLTool Get-DbaDiskSpace {
                @([PSCustomObject]@{
                    ComputerName  = 'TESTSERVER'
                    Name          = 'C:\'
                    Label         = 'System'
                    Capacity      = [int64]200GB
                    Free          = [int64]50GB
                    PercentFree   = 25.0
                    BlockSize     = 4096
                    FileSystem    = 'NTFS'
                    IsSqlDisk     = $true
                })
            }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft ohne Fehler mit gemockten Daten durch' {
            { Get-sqmDiskSpaceReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf } |
                Should -Not -Throw
        }

        It 'Erstellt keine Dateien bei -WhatIf' {
            Get-sqmDiskSpaceReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -WhatIf
            (Get-ChildItem $script:TestDir -File).Count | Should -Be 0
        }
    }

    Context 'SupportsShouldProcess' {
        It 'Funktion unterstuetzt ShouldProcess' {
            $cmd = Get-Command Get-sqmDiskSpaceReport
            $cmd.Parameters.ContainsKey('WhatIf')   | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm')  | Should -Be $true
        }
    }
}
