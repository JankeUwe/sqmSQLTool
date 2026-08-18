#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmDatabaseSpaceReport
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

Describe 'Get-sqmDatabaseSpaceReport' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Get-sqmDatabaseSpaceReport | Should -Not -BeNullOrEmpty
        }

        It 'OutputPath Parameter existiert' {
            (Get-Command Get-sqmDatabaseSpaceReport).Parameters.ContainsKey('OutputPath') | Should -Be $true
        }

        It 'wirft bei CriticalThresholdPct <= WarnThresholdPct' {
            { Get-sqmDatabaseSpaceReport -SqlInstance 'TESTSERVER' -WarnThresholdPct 90 -CriticalThresholdPct 80 -EnableException } |
                Should -Throw
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools-Daten' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Get-DbaDbSpace {
                @(
                    # AlmostFullDb: 1 Datendatei bei 95% (Critical), 1 Logdatei bei 50%
                    [PSCustomObject]@{
                        Database = 'AlmostFullDb'; FileName = 'AlmostFullDb_data'; FileGroup = 'PRIMARY'
                        PhysicalName = 'C:\Data\AlmostFullDb.mdf'; FileType = 'ROWS'
                        FileSize = [PSCustomObject]@{ Megabyte = 1000 }
                        UsedSpace = [PSCustomObject]@{ Megabyte = 950 }
                        FreeSpace = [PSCustomObject]@{ Megabyte = 50 }
                        PercentUsed = 95; AutoGrowType = 'MB'
                    }
                    [PSCustomObject]@{
                        Database = 'AlmostFullDb'; FileName = 'AlmostFullDb_log'; FileGroup = $null
                        PhysicalName = 'C:\Data\AlmostFullDb.ldf'; FileType = 'LOG'
                        FileSize = [PSCustomObject]@{ Megabyte = 200 }
                        UsedSpace = [PSCustomObject]@{ Megabyte = 100 }
                        FreeSpace = [PSCustomObject]@{ Megabyte = 100 }
                        PercentUsed = 50; AutoGrowType = 'pct'
                    }
                    # HealthyDb: alles unter dem Warn-Schwellwert
                    [PSCustomObject]@{
                        Database = 'HealthyDb'; FileName = 'HealthyDb_data'; FileGroup = 'PRIMARY'
                        PhysicalName = 'C:\Data\HealthyDb.mdf'; FileType = 'ROWS'
                        FileSize = [PSCustomObject]@{ Megabyte = 500 }
                        UsedSpace = [PSCustomObject]@{ Megabyte = 100 }
                        FreeSpace = [PSCustomObject]@{ Megabyte = 400 }
                        PercentUsed = 20; AutoGrowType = 'MB'
                    }
                )
            }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        }

        It 'Laeuft ohne Fehler durch und liefert ein Ergebnis je Instanz' {
            $r = Get-sqmDatabaseSpaceReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir
            $r.SqlInstance | Should -Be 'TESTSERVER'
            $r.Databases.Count | Should -Be 2
        }

        It 'markiert AlmostFullDb als Critical (Datendatei 95% >= Default-Schwellwert 90%)' {
            $r = Get-sqmDatabaseSpaceReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir
            $db = $r.Databases | Where-Object DatabaseName -eq 'AlmostFullDb'
            $db.DataPercentUsed | Should -Be 95
            $db.Status | Should -Be 'Critical'
        }

        It 'markiert HealthyDb als OK' {
            $r = Get-sqmDatabaseSpaceReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir
            $db = $r.Databases | Where-Object DatabaseName -eq 'HealthyDb'
            $db.Status | Should -Be 'OK'
        }

        It 'schreibt CSV+HTML nach -OutputPath' {
            $r = Get-sqmDatabaseSpaceReport -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen
            Test-Path $r.CsvFile | Should -Be $true
            Test-Path $r.HtmlFile | Should -Be $true
        }

        It 'schreibt CSV+HTML ohne explizites -OutputPath in den Default-Ordner' {
            $r = Get-sqmDatabaseSpaceReport -SqlInstance 'TESTSERVER'
            $r.CsvFile | Should -BeLike 'C:\System\WinSrvLog\MSSQL\DatabaseSpaceReport\*'
            Test-Path $r.CsvFile | Should -Be $true
        }
    }
}
