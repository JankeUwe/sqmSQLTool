#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Test-sqmTdpConfiguration (ohne SQL-Zugriff): gesunde Konfiguration, fehlende
    Dateien, JSON-Fehler, Wrapper ohne Exit-Code, FAILED-Wrapper-Log, ANS-Meldungen mit Hinweis,
    Zeitfenster -LogDays, Berichtsdateien. Es wird nichts gemockt ausser Logging und Berichtsoeffnen.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    function script:New-TdpFiles
    {
        param ([string]$Dir)
        if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
        foreach ($d in $Dir, "$Dir\01_Backup_CMD", "$Dir\03_Log", "$Dir\scripts") { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Set-Content "$Dir\tdpsqlc.exe" 'x'
        Set-Content "$Dir\TdpBackup.config" 'x'
        Set-Content "$Dir\dsm.opt" @('NODENAME TESTNODE', 'TCPSERVERADDRESS tsm.example.test', 'TCPPORT 1500')
        Set-Content "$Dir\tdpsql.cfg" @('BUFFers 3', 'LOGFile tdpsql.log')
        Set-Content "$Dir\scripts\Backup-TdpFull.ps1" '# test'
        Set-Content "$Dir\01_Backup_CMD\Backup_TdpFull.cmd" @('@echo off', "SET BackupScriptsDir=$Dir\scripts", 'powershell.exe -File x', 'SET PowerShellExitCode=%ERRORLEVEL%', 'exit /b %PowerShellExitCode%')
        $plan = [ordered]@{
            Version = '1.0'
            Configuration = [ordered]@{ TdpDir = $Dir; SQLServer = 'SQL01'; TsmOptFile = "$Dir\dsm.opt"; TdpConfigFile = "$Dir\tdpsql.cfg"; LogPath = "$Dir\03_Log" }
            Schedule = [ordered]@{ FullBackupDays = @('Sunday'); DifferentialBackupDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'); AllowSpecialHandling = $true }
            SelectedDatabases = @([ordered]@{ Name = 'Shop'; Enabled = $true; BackupType = 'FULL'; IncludeInDifferential = $true; Priority = 50 })
            ExcludedDatabases = @('tempdb', 'model', 'msdb', 'master')
        }
        $plan | ConvertTo-Json -Depth 6 | Set-Content "$Dir\BackupPlan.json" -Encoding UTF8
        Set-Content "$Dir\03_Log\Backup_TdpFull_20300114_200001.log" @('TDP Backup - Started', 'TDP Backup COMPLETED SUCCESSFULLY', 'ExitCode: 0')
    }

    function script:Set-LogLine
    {
        param ([string]$Path, [string[]]$Lines)
        Set-Content $Path $Lines
    }

    $script:Root = Join-Path $TestDrive 'tdpcfg'
    $script:out = Join-Path $TestDrive 'out'
    $script:stamp = { (Get-Date).AddHours(-2).ToString('MM/dd/yyyy HH:mm:ss', [cultureinfo]::InvariantCulture) }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Test-sqmTdpConfiguration' {
    BeforeEach {
        New-TdpFiles -Dir $script:Root
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'SQL darf nicht angefasst werden' }
    }

    It 'meldet bei gesunder Konfiguration OK und braucht keinen SQL-Zugriff' {
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        @($r.Findings | Where-Object Severity -ne 'Info') | Should -BeNullOrEmpty
        $r.Status | Should -Be 'OK'
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0
    }

    It 'meldet fehlende TDP-Dateien als kritisch' {
        Remove-Item "$script:Root\tdpsqlc.exe", "$script:Root\dsm.opt", "$script:Root\tdpsql.cfg", "$script:Root\TdpBackup.config"
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        foreach ($m in 'tdpsqlc.exe', 'dsm.opt', 'tdpsql.cfg', 'TdpBackup.config')
        {
            ($r.Findings | Where-Object Message -match ([regex]::Escape($m))).Severity | Should -Be 'Critical'
        }
        $r.Status | Should -Be 'Critical'
    }

    It 'meldet nicht erreichbares TDP-Verzeichnis' {
        $r = Test-sqmTdpConfiguration -TdpDir (Join-Path $TestDrive 'gibtsnicht') -NoReport -NoOpen
        ($r.Findings | Where-Object Message -match 'TDP-Verzeichnis nicht erreichbar').Severity | Should -Be 'Critical'
    }

    It 'erkennt ungueltiges JSON, Platzhalter, falsche Wochentage und leere Datenbankliste' {
        Set-Content "$script:Root\BackupPlan.json" '{ kaputt' -Encoding UTF8
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        ($r.Findings | Where-Object Message -match 'kein gueltiges JSON').Severity | Should -Be 'Critical'

        New-TdpFiles -Dir $script:Root
        $j = Get-Content "$script:Root\BackupPlan.json" -Raw | ConvertFrom-Json
        $j.Configuration.SQLServer = '<SQLInstance>'
        $j.Schedule.FullBackupDays = @('Sonntag')
        $j.SelectedDatabases = @()
        $j | ConvertTo-Json -Depth 6 | Set-Content "$script:Root\BackupPlan.json" -Encoding UTF8
        $r2 = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        ($r2.Findings | Where-Object Message -match 'Platzhalter').Severity | Should -Be 'Critical'
        ($r2.Findings | Where-Object Message -match 'Ungueltige Wochentage').Severity | Should -Be 'Critical'
        ($r2.Findings | Where-Object Message -match 'keine Datenbanken').Severity | Should -Be 'Critical'
    }

    It 'erkennt Wrapper ohne Exit-Code-Rueckgabe und fehlendes Backup-TdpFull.ps1' {
        Set-Content "$script:Root\01_Backup_CMD\Backup_TdpFull.cmd" @('@echo off', "SET BackupScriptsDir=$script:Root\scripts", 'powershell.exe -File x')
        Remove-Item "$script:Root\scripts\Backup-TdpFull.ps1"
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        ($r.Findings | Where-Object Message -match 'Exit-Code nicht').Severity | Should -Be 'Critical'
        ($r.Findings | Where-Object Message -match 'Backup-TdpFull.ps1 nicht gefunden').Severity | Should -Be 'Critical'
    }

    It 'erkennt dsm.opt ohne TCPServeraddress' {
        Set-Content "$script:Root\dsm.opt" @('NODENAME TESTNODE')
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        ($r.Findings | Where-Object Message -match 'keine TCPServeraddress').Severity | Should -Be 'Critical'
    }

    It 'meldet ein Wrapper-Log, das mit FAILED endet, mit Exit-Code' {
        Set-Content "$script:Root\03_Log\Backup_TdpFull_20300115_200001.log" @('TDP Backup - Started', 'FATAL ERROR: boom', 'TDP Backup FAILED', 'ExitCode: 1')
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        $f = $r.Findings | Where-Object Message -match 'endet mit FAILED'
        $f.Severity | Should -Be 'Critical'
        $f.Message | Should -Match 'ExitCode 1'
    }

    It 'findet ANS-Meldungen mit Hinweis, Schwere nach Endbuchstabe' {
        $t = & $script:stamp
        Set-LogLine "$script:Root\03_Log\backup_FULL_Shop_x.log" @("$t ANS1017E Session rejected: TCP/IP connection failure", "$t ANS1035S Options file not found")
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        $e = $r.Findings | Where-Object Message -match 'ANS1017E'
        $e.Severity | Should -Be 'Warning'
        $e.Hint | Should -Match 'TCP/IP'
        ($r.Findings | Where-Object Message -match 'ANS1035S').Severity | Should -Be 'Critical'
    }

    It 'wertet auch tdpsql.log aus der tdpsql.cfg aus' {
        $t = & $script:stamp
        Set-LogLine "$script:Root\tdpsql.log" @("$t ACO5436E A failure occurred on stripe number (0), rc = 418")
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        ($r.Findings | Where-Object Message -match 'ACO5436E.*tdpsql.log|tdpsql.log.*ACO5436E').Severity | Should -Be 'Warning'
    }

    It 'beachtet das Zeitfenster -LogDays' {
        $old = (Get-Date).AddDays(-3).ToString('MM/dd/yyyy HH:mm:ss', [cultureinfo]::InvariantCulture)
        Set-LogLine "$script:Root\03_Log\backup_FULL_Shop_x.log" @("$old ANS1017E Session rejected")
        $r1 = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen
        @($r1.Findings | Where-Object Message -match 'ANS1017E').Count | Should -Be 1
        $r2 = Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen -LogDays 1
        @($r2.Findings | Where-Object Message -match 'ANS1017E') | Should -BeNullOrEmpty
    }

    It 'schreibt TXT, CSV und HTML, aber nichts mit -NoReport' {
        $r = Test-sqmTdpConfiguration -TdpDir $script:Root -OutputPath $script:out -NoOpen
        Test-Path $r.TxtFile | Should -BeTrue
        Test-Path $r.CsvFile | Should -BeTrue
        Test-Path $r.HtmlFile | Should -BeTrue
        (Get-Content $r.TxtFile -Raw) | Should -Match 'Test-sqmTdpBackup'
        (Test-sqmTdpConfiguration -TdpDir $script:Root -NoReport -NoOpen).TxtFile | Should -BeNullOrEmpty
    }
}
