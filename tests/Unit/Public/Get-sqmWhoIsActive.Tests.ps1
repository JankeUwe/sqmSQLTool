#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmWhoIsActive
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory

    function New-ActiveSessionRow
    {
        param(
            [int]$SessionId = 55,
            [int]$BlockingSessionId = 0,
            [string]$Status = 'running',
            [int]$ElapsedSeconds = 12,
            [int]$OpenTranCount = 0
        )
        [PSCustomObject]@{
            SessionId		    = $SessionId
            RequestId		    = 0
            LoginName		    = 'domain\user1'
            HostName		    = 'APP01'
            ProgramName	        = 'MyApp'
            DatabaseName	    = 'TestDB'
            Status			    = $Status
            Command		        = 'SELECT'
            BlockingSessionId   = $BlockingSessionId
            WaitType		    = if ($BlockingSessionId -gt 0) { 'LCK_M_X' } else { $null }
            WaitTimeMs		    = if ($BlockingSessionId -gt 0) { 1500 } else { $null }
            WaitResource	    = $null
            WaitInfo		    = if ($BlockingSessionId -gt 0) { "LCK_M_X (1500 ms) blocked by $BlockingSessionId" } else { $null }
            OpenTranCount	    = $OpenTranCount
            PercentComplete	    = 0
            RequestStartTime    = (Get-Date).AddSeconds(-$ElapsedSeconds)
            LoginTime		    = (Get-Date).AddMinutes(-30)
            LastRequestStartTime = (Get-Date).AddSeconds(-$ElapsedSeconds)
            LastRequestEndTime  = (Get-Date).AddSeconds(-$ElapsedSeconds)
            ElapsedSeconds	    = $ElapsedSeconds
            CpuTimeMs		    = 250
            Reads			    = 1000
            Writes		        = 0
            LogicalReads	    = 5000
            GrantedMemoryMB	    = $null
            TempdbAllocMB	    = 0.5
            SqlText		        = 'SELECT * FROM dbo.Test WHERE Id = 1'
            SqlFullBatch	    = 'SELECT * FROM dbo.Test WHERE Id = 1'
        }
    }
}

AfterAll {
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmWhoIsActive' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Get-sqmWhoIsActive | Should -Not -BeNullOrEmpty
        }

        It '<_> Parameter existiert' -ForEach @(
            'ShowSleepingSpids', 'MinElapsedSeconds', 'RepeatIntervalSeconds',
            'RepeatCount', 'DurationMinutes', 'OutputPath', 'NoConsoleOutput'
        ) {
            (Get-Command Get-sqmWhoIsActive).Parameters.ContainsKey($_) | Should -Be $true
        }

        It 'ShowSleepingSpids lehnt ungueltige Werte ab' {
            { Get-sqmWhoIsActive -SqlInstance 'TESTSERVER' -ShowSleepingSpids 3 -EnableException } | Should -Throw
        }
    }

    Context 'Einzelabruf (kein Repeat)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @(New-ActiveSessionRow) }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Laeuft ohne Fehler durch und liefert genau einen Snapshot' {
            $r = Get-sqmWhoIsActive -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen -NoConsoleOutput -EnableException
            $r.Iterations | Should -Be 1
            $r.SnapshotCount | Should -Be 1
            $r.LastSnapshot[0].SessionId | Should -Be 55
        }

        It 'Ruft Invoke-DbaQuery genau einmal auf, wenn RepeatIntervalSeconds 0 ist' {
            Get-sqmWhoIsActive -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen -NoConsoleOutput -EnableException | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 1
        }
    }

    Context 'Repeat-Steuerung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @(New-ActiveSessionRow) }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'RepeatCount begrenzt die Anzahl Iterationen' {
            $r = Get-sqmWhoIsActive -SqlInstance 'TESTSERVER' -RepeatIntervalSeconds 1 -RepeatCount 3 `
                -OutputPath $script:TestDir -NoOpen -NoConsoleOutput -EnableException
            $r.Iterations | Should -Be 3
            $r.SnapshotCount | Should -Be 3
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 3
        }
    }

    Context 'Report-Erzeugung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @(New-ActiveSessionRow -BlockingSessionId 42) }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Schreibt CSV und HTML nach OutputPath' {
            $r = Get-sqmWhoIsActive -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen -NoConsoleOutput -EnableException
            $r.CsvFile | Should -Not -BeNullOrEmpty
            $r.HtmlFile | Should -Not -BeNullOrEmpty
            Test-Path $r.CsvFile | Should -Be $true
            Test-Path $r.HtmlFile | Should -Be $true
        }
    }

    Context 'Keine Sessions gefunden' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Wirft nicht und liefert SnapshotCount 0 ohne Report-Dateien' {
            $script:r = $null
            { $script:r = Get-sqmWhoIsActive -SqlInstance 'TESTSERVER' -OutputPath $script:TestDir -NoOpen -NoConsoleOutput -EnableException } | Should -Not -Throw
            $script:r.SnapshotCount | Should -Be 0
            $script:r.CsvFile | Should -BeNullOrEmpty
        }
    }
}
