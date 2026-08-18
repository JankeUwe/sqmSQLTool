#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmBlockingHistory
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

Describe 'Get-sqmBlockingHistory' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Get-sqmBlockingHistory | Should -Not -BeNullOrEmpty
        }

        It 'Since Parameter existiert' {
            (Get-Command Get-sqmBlockingHistory).Parameters.ContainsKey('Since') | Should -Be $true
        }

        It 'MinWaitSeconds Parameter existiert' {
            (Get-Command Get-sqmBlockingHistory).Parameters.ContainsKey('MinWaitSeconds') | Should -Be $true
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmBlockingHistory).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }
    }

    Context 'Threshold deaktiviert (0)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*blocked process threshold*'
            } { @([PSCustomObject]@{ ThresholdSeconds = 0 }) }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*sys.dm_xe_sessions*'
            } { @([PSCustomObject]@{ name = 'sqm_BlockedProcessMonitor'; create_time = (Get-Date).AddDays(-3) }) }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*blocked_process_report*'
            } { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'meldet ThresholdConfigured = $false und keine Vorfaelle' {
            $r = Get-sqmBlockingHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -SkipMonitorSetup
            $r.ThresholdConfigured | Should -Be $false
            $r.HasIncidents | Should -Be $false
            $r.IncidentCount | Should -Be 0
        }
    }

    Context 'Threshold aktiv, Vorfaelle im Ring-Buffer' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*blocked process threshold*'
            } { @([PSCustomObject]@{ ThresholdSeconds = 20 }) }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*sys.dm_xe_sessions*'
            } { @([PSCustomObject]@{ SessionStartTime = (Get-Date).AddDays(-1) }) }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -like '*blocked_process_report*'
            } {
                @([PSCustomObject]@{
                        EventTime         = (Get-Date).AddMinutes(-30)
                        BlockingSpid      = 42
                        BlockingLogin     = 'domain\blocker'
                        BlockingHost      = 'APP01'
                        BlockingProgram   = 'MyApp'
                        BlockingLockMode  = 'X'
                        BlockingStatement = 'UPDATE dbo.Test SET Col = 1'
                        BlockedSpid       = 55
                        BlockedWaitMs     = 45000
                        BlockedLockMode   = 'S'
                        WaitResource      = 'KEY: 5:72057594045071360'
                        BlockedLogin      = 'domain\user1'
                        BlockedHost       = 'APP02'
                        BlockedProgram    = 'MyApp'
                        DatabaseName      = 'TestDB'
                        BlockedStatement  = 'SELECT * FROM dbo.Test'
                    })
            }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'gibt den Vorfall mit korrekter Wartezeit zurueck' {
            $r = Get-sqmBlockingHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -SkipMonitorSetup
            $r.ThresholdConfigured | Should -Be $true
            $r.HasIncidents | Should -Be $true
            $r.IncidentCount | Should -Be 1
            $r.Incidents[0].WaitSeconds | Should -Be 45
            $r.Incidents[0].BlockingSpid | Should -Be 42
            $r.Incidents[0].BlockedSpid | Should -Be 55
        }

        It 'filtert Vorfaelle unterhalb MinWaitSeconds heraus' {
            $r = Get-sqmBlockingHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -SkipMonitorSetup -MinWaitSeconds 60
            $r.IncidentCount | Should -Be 0
        }

        It 'schreibt einen HTML-Bericht' {
            $r = Get-sqmBlockingHistory -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -SkipMonitorSetup -NoOpen
            $r.HtmlFile | Should -Not -BeNullOrEmpty
            Test-Path $r.HtmlFile | Should -Be $true
        }
    }
}
