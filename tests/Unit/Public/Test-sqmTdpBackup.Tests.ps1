#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Test-sqmTdpBackup. Invoke-DbaQuery wird je Abfragemarkierung (TDPCHK:name) gemockt,
    die Dateien liegen in einem Temp-Verzeichnis. Getestet wird die Bewertung: Grenzen aus dem
    Zeitplan, Agent-Job, Tracking, Plan, Backup-Alter aus msdb, "Erfolg ohne Backup", Fremd-Full,
    Wrapper ohne Exit-Code, JSON-Fehler, ANS-Meldungen im Log, Berichtsdateien.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:srvNow = [datetime]'2030-01-15 12:00'   # Dienstag, bewusst weit weg von der Clientuhr

    # Gesunder Grundzustand der SQL-Antworten; Tests ueberschreiben einzelne Schluessel
    function script:New-TdpFixture
    {
        param ([string]$TdpDir)
        $n = [DBNull]::Value
        @{
            env     = @([PSCustomObject]@{ HostName = $env:COMPUTERNAME; ServerNow = $script:srvNow; AgentStatus = 'Running' })
            objects = @('TDP_BackupPlan', 'BackupStatus', 'BackupLog', 'BackupLog_Errors', 'sp_UpdateBackupStatus', 'sp_LogBackupResult', 'v_DatabasesWithoutFullBackup' | ForEach-Object { [PSCustomObject]@{ ObjectName = $_ } })
            job     = @([PSCustomObject]@{ JobId = [guid]::NewGuid(); Enabled = 1; OwnerName = 'sa' })
            steps   = @([PSCustomObject]@{ StepId = 1; StepName = 'Execute_TdpFull_Backup'; Subsystem = 'CmdExec'; Command = (Join-Path $TdpDir '01_Backup_CMD\Backup_TdpFull.cmd'); ProxyId = 1; ProxyName = 'TDP_Backup_Proxy'; ProxyEnabled = 1 })
            sched   = @([PSCustomObject]@{ ScheduleName = 'Daily_20_00'; Enabled = 1; FreqType = 4; FreqInterval = 1; StartTime = 200000 })
            hist    = @(
                [PSCustomObject]@{ StepId = 0; StepName = '(Job outcome)'; RunStatus = 1; RunTime = [datetime]'2030-01-14 20:00'; Message = 'ok' }
                [PSCustomObject]@{ StepId = 1; StepName = 'Execute_TdpFull_Backup'; RunStatus = 1; RunTime = [datetime]'2030-01-14 20:00'; Message = 'ok' }
            )
            act     = @()
            plan    = @([PSCustomObject]@{ DatabaseName = 'Shop'; Enabled = 1; IncludeInDifferential = 1; BackupType = 'FULL' })
            status  = @([PSCustomObject]@{ DatabaseName = 'Shop'; FullBackupExists = 1; LastFullBackupDate = [datetime]'2030-01-13 20:30'; LastFullBackupStatus = 'SUCCESS'; LastDifferentialDate = [datetime]'2030-01-14 20:35'; ConsecutiveFailures = 0; LastErrorMessage = $n; CreatedDate = [datetime]'2029-01-01' })
            log     = @(
                [PSCustomObject]@{ DatabaseName = 'Shop'; BackupType = 'FULL'; LastSuccess = [datetime]'2030-01-13 20:30'; LastFailed = $n; FailedLast7d = 0; LastEntry = [datetime]'2030-01-13 20:30' }
                [PSCustomObject]@{ DatabaseName = 'Shop'; BackupType = 'DIFF'; LastSuccess = [datetime]'2030-01-14 20:35'; LastFailed = $n; FailedLast7d = 0; LastEntry = [datetime]'2030-01-14 20:35' }
            )
            logmax  = @([PSCustomObject]@{ LastEntry = [datetime]'2030-01-14 20:40'; Cnt = 20 })
            logerr  = @()
            dbs     = @([PSCustomObject]@{ DatabaseName = 'Shop'; DatabaseId = 5; CreateDate = [datetime]'2029-01-01'; State = 'ONLINE'; RecoveryModel = 'FULL'; LogReuseWait = 'NOTHING'; IsAgSecondary = 0 })
            msdb    = @([PSCustomObject]@{ DatabaseName = 'Shop'; LastVdiFull = [datetime]'2030-01-13 20:45'; LastVdiDiff = [datetime]'2030-01-14 20:40'; LastOtherFull = $n; LastLog = [datetime]'2030-01-15 11:45' })
        }
    }

    # Gesunde Dateistruktur: TdpDir mit Exe, dsm.opt, tdpsql.cfg, Config, Wrapper, Skript, Plan, Log
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
        $wl = "$Dir\03_Log\Backup_TdpFull_20300114_200001.log"
        Set-Content $wl @('TDP Backup - Started', 'TDP Backup COMPLETED SUCCESSFULLY', 'ExitCode: 0')
        (Get-Item $wl).LastWriteTime = $script:srvNow.AddHours(-1)
    }

    $script:TestRoot = Join-Path $TestDrive 'tdp'
    $script:out = Join-Path $TestDrive 'out'

    function script:Invoke-Tdp
    {
        param ([hashtable]$Override = @{ }, [switch]$Report, [hashtable]$Extra = @{ })
        $fx = New-TdpFixture -TdpDir $script:TestRoot
        foreach ($k in $Override.Keys) { $fx[$k] = $Override[$k] }
        $global:TdpFx = $fx
        $p = @{ SqlInstance = 'SQL01'; TdpDir = $script:TestRoot; NoOpen = $true }
        if (-not $Report) { $p['NoReport'] = $true } else { $p['OutputPath'] = $script:out }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        Test-sqmTdpBackup @p
    }
}

AfterAll {
    $global:TdpFx = $null
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Test-sqmTdpBackup' {
    BeforeEach {
        New-TdpFiles -Dir $script:TestRoot
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -match 'TDPCHK:(\w+)') { @($global:TdpFx[$Matches[1]]) } else { @() }
        }
    }

    It 'meldet bei gesundem Aufbau OK ohne Warnung oder Kritisches' {
        $r = Invoke-Tdp
        @($r.Findings | Where-Object Severity -ne 'Info') | Should -BeNullOrEmpty
        $r.Status | Should -Be 'OK'
        $r.DatabaseRows[0].Status | Should -Be 'OK'
    }

    It 'leitet die Grenzen aus dem Zeitplan ab (Full woechentlich, Diff taeglich)' {
        $r = Invoke-Tdp
        $r.MaxFullAgeHours | Should -Be (7 * 24 + 12)
        $r.MaxAnyAgeHours | Should -Be (1 * 24 + 12)
        $r.LimitSource | Should -Be 'Zeitplan'
    }

    It 'nimmt explizite Grenzen aus den Parametern' {
        $r = Invoke-Tdp -Extra @{ MaxFullAgeDays = 3; MaxAnyAgeHours = 10 }
        $r.MaxFullAgeHours | Should -Be 72
        $r.MaxAnyAgeHours | Should -Be 10
        $r.LimitSource | Should -Be 'Parameter'
        # Diff vom Vortag 20:40 ist 15 h alt > 10 h
        ($r.Findings | Where-Object { $_.Category -eq 'Backup' -and $_.Message -match 'Full/Diff' }).Severity | Should -Be 'Critical'
    }

    It 'erkennt deaktivierten Job und fehlgeschlagenen letzten Lauf' {
        $r = Invoke-Tdp -Override @{
            job  = @([PSCustomObject]@{ JobId = [guid]::NewGuid(); Enabled = 0; OwnerName = 'sa' })
            hist = @(
                [PSCustomObject]@{ StepId = 0; StepName = '(Job outcome)'; RunStatus = 0; RunTime = [datetime]'2030-01-14 20:00'; Message = 'fehlgeschlagen' }
                [PSCustomObject]@{ StepId = 1; StepName = 'Execute_TdpFull_Backup'; RunStatus = 0; RunTime = [datetime]'2030-01-14 20:00'; Message = 'Exit 1: ANS1017E' }
            )
        }
        ($r.Findings | Where-Object Message -match 'deaktiviert').Severity | Should -Be 'Critical'
        ($r.Findings | Where-Object Message -match 'Letzter Job-Lauf.*fehlgeschlagen.*ANS1017E').Severity | Should -Be 'Critical'
        $r.Status | Should -Be 'Critical'
    }

    It 'erkennt fehlenden Job, gestoppten Agent und deaktivierten Proxy' {
        $r = Invoke-Tdp -Override @{ job = @(); env = @([PSCustomObject]@{ HostName = $env:COMPUTERNAME; ServerNow = $script:srvNow; AgentStatus = 'Stopped' }) }
        ($r.Findings | Where-Object Message -match 'existiert nicht').Severity | Should -Be 'Critical'
        ($r.Findings | Where-Object Message -match 'Agent Dienst').Severity | Should -Be 'Critical'
        $r2 = Invoke-Tdp -Override @{ steps = @([PSCustomObject]@{ StepId = 1; StepName = 'S1'; Subsystem = 'CmdExec'; Command = (Join-Path $script:TestRoot '01_Backup_CMD\Backup_TdpFull.cmd'); ProxyId = 1; ProxyName = 'TDP_Backup_Proxy'; ProxyEnabled = 0 }) }
        ($r2.Findings | Where-Object Message -match "Proxy 'TDP_Backup_Proxy'.*deaktiviert").Severity | Should -Be 'Critical'
    }

    It 'erkennt Job ohne aktiven Zeitplan und seit Tagen nicht gelaufenen Job' {
        $r = Invoke-Tdp -Override @{
            hist = @([PSCustomObject]@{ StepId = 0; StepName = '(Job outcome)'; RunStatus = 1; RunTime = [datetime]'2030-01-10 20:00'; Message = 'ok' })
        }
        ($r.Findings | Where-Object Message -match 'nicht gelaufen').Severity | Should -Be 'Critical'
        $r2 = Invoke-Tdp -Override @{ sched = @() }
        ($r2.Findings | Where-Object Message -match 'kein Zeitplan').Severity | Should -Be 'Critical'
    }

    It 'meldet Plan-Datenbank ohne BackupStatus-Zeile als kritisch' {
        $r = Invoke-Tdp -Override @{ status = @() }
        $f = $r.Findings | Where-Object { $_.Database -eq 'Shop' -and $_.Message -match 'BackupStatus' }
        $f.Severity | Should -Be 'Critical'
        $r.DatabaseRows[0].Status | Should -Be 'Critical'
    }

    It 'meldet zu altes TDP-Full aus msdb' {
        $n = [DBNull]::Value
        $r = Invoke-Tdp -Override @{ msdb = @([PSCustomObject]@{ DatabaseName = 'Shop'; LastVdiFull = [datetime]'2030-01-01 20:45'; LastVdiDiff = [datetime]'2030-01-14 20:40'; LastOtherFull = $n; LastLog = [datetime]'2030-01-15 11:45' }) }
        ($r.Findings | Where-Object Message -match 'Letztes TDP-Full vor').Severity | Should -Be 'Critical'
    }

    It 'bewertet eine Datenbank ohne TDP-Backup je nach Alter als Warning oder Critical' {
        $young = [PSCustomObject]@{ DatabaseName = 'Shop'; DatabaseId = 5; CreateDate = [datetime]'2030-01-15 08:00'; State = 'ONLINE'; RecoveryModel = 'SIMPLE'; LogReuseWait = 'NOTHING'; IsAgSecondary = 0 }
        $r = Invoke-Tdp -Override @{ msdb = @(); dbs = @($young) }
        ($r.Findings | Where-Object Message -match 'Noch kein TDP-Full').Severity | Should -Be 'Warning'
        $r2 = Invoke-Tdp -Override @{ msdb = @() }
        ($r2.Findings | Where-Object Message -match 'Kein TDP-Full-Backup in msdb').Severity | Should -Be 'Critical'
    }

    It 'erkennt SUCCESS im BackupLog ohne passendes Backup in msdb' {
        $n = [DBNull]::Value
        $r = Invoke-Tdp -Override @{ msdb = @([PSCustomObject]@{ DatabaseName = 'Shop'; LastVdiFull = [datetime]'2030-01-13 20:45'; LastVdiDiff = $n; LastOtherFull = $n; LastLog = [datetime]'2030-01-15 11:45' }) }
        ($r.Findings | Where-Object Message -match 'SUCCESS fuer DIFF').Severity | Should -Be 'Critical'
    }

    It 'warnt vor Nicht-TDP-Full, das neuer ist als das TDP-Full' {
        $r = Invoke-Tdp -Override @{ msdb = @([PSCustomObject]@{ DatabaseName = 'Shop'; LastVdiFull = [datetime]'2030-01-13 20:45'; LastVdiDiff = [datetime]'2030-01-14 20:40'; LastOtherFull = [datetime]'2030-01-14 22:00'; LastLog = [datetime]'2030-01-15 11:45' }) }
        ($r.Findings | Where-Object Message -match 'Nicht-TDP-Full').Severity | Should -Be 'Warning'
    }

    It 'meldet Folgefehler laut BackupStatus (3 = Critical) mit Fehlermeldung' {
        $n = [DBNull]::Value
        $st = @([PSCustomObject]@{ DatabaseName = 'Shop'; FullBackupExists = 1; LastFullBackupDate = [datetime]'2030-01-13 20:30'; LastFullBackupStatus = 'FAILED'; LastDifferentialDate = $n; ConsecutiveFailures = 3; LastErrorMessage = 'ANS1025E Session rejected'; CreatedDate = [datetime]'2029-01-01' })
        $r = Invoke-Tdp -Override @{ status = $st }
        $f = $r.Findings | Where-Object Message -match '3 Fehlversuch'
        $f.Severity | Should -Be 'Critical'
        $f.Message | Should -Match 'ANS1025E'
    }

    It 'warnt bei FULL-Recovery ohne Log-Backup' {
        $n = [DBNull]::Value
        $r = Invoke-Tdp -Override @{
            msdb = @([PSCustomObject]@{ DatabaseName = 'Shop'; LastVdiFull = [datetime]'2030-01-13 20:45'; LastVdiDiff = [datetime]'2030-01-14 20:40'; LastOtherFull = $n; LastLog = $n })
            dbs  = @([PSCustomObject]@{ DatabaseName = 'Shop'; DatabaseId = 5; CreateDate = [datetime]'2029-01-01'; State = 'ONLINE'; RecoveryModel = 'FULL'; LogReuseWait = 'LOG_BACKUP'; IsAgSecondary = 0 })
        }
        $f = $r.Findings | Where-Object Message -match 'ohne Log-Backup'
        $f.Severity | Should -Be 'Warning'
        $f.Message | Should -Match 'waechst'
    }

    It 'erkennt Job-Erfolg ohne neuen BackupLog-Eintrag' {
        $r = Invoke-Tdp -Override @{ logmax = @([PSCustomObject]@{ LastEntry = [datetime]'2030-01-10 20:40'; Cnt = 20 }) }
        ($r.Findings | Where-Object { $_.Category -eq 'Tracking' }).Severity | Should -Be 'Critical'
    }

    It 'meldet fehlende Tracking-Objekte' {
        $r = Invoke-Tdp -Override @{ objects = @([PSCustomObject]@{ ObjectName = 'TDP_BackupPlan' }) }
        ($r.Findings | Where-Object { $_.Category -eq 'Tracking' -and $_.Message -match 'fehlen' }).Severity | Should -Be 'Critical'
    }

    It 'weist Benutzerdatenbank ausserhalb des Plans aus (Warning, ohne anderes Backup)' {
        $n = [DBNull]::Value
        $dbs = @(
            [PSCustomObject]@{ DatabaseName = 'Shop'; DatabaseId = 5; CreateDate = [datetime]'2029-01-01'; State = 'ONLINE'; RecoveryModel = 'FULL'; LogReuseWait = 'NOTHING'; IsAgSecondary = 0 }
            [PSCustomObject]@{ DatabaseName = 'Wild'; DatabaseId = 6; CreateDate = [datetime]'2029-01-01'; State = 'ONLINE'; RecoveryModel = 'SIMPLE'; LogReuseWait = 'NOTHING'; IsAgSecondary = 0 }
        )
        $r = Invoke-Tdp -Override @{ dbs = $dbs }
        ($r.Findings | Where-Object { $_.Database -eq 'Wild' -and $_.Message -match 'nicht im TDP-Backup-Plan' }).Severity | Should -Be 'Warning'
        $r3 = Invoke-Tdp -Override @{ dbs = $dbs } -Extra @{ ExcludeDatabase = @('Wild') }
        @($r3.Findings | Where-Object Database -eq 'Wild') | Should -BeNullOrEmpty
    }

    It 'erkennt Wrapper ohne Exit-Code-Rueckgabe' {
        Set-Content "$script:TestRoot\01_Backup_CMD\Backup_TdpFull.cmd" @('@echo off', "SET BackupScriptsDir=$script:TestRoot\scripts", 'powershell.exe -File x')
        $r = Invoke-Tdp
        ($r.Findings | Where-Object Message -match 'Exit-Code nicht').Severity | Should -Be 'Critical'
    }

    It 'erkennt fehlendes Backup-TdpFull.ps1 und fehlende TDP-Dateien' {
        Remove-Item "$script:TestRoot\scripts\Backup-TdpFull.ps1"
        Remove-Item "$script:TestRoot\tdpsqlc.exe"
        $r = Invoke-Tdp
        ($r.Findings | Where-Object Message -match 'Backup-TdpFull.ps1 nicht gefunden').Severity | Should -Be 'Critical'
        ($r.Findings | Where-Object Message -match 'tdpsqlc.exe').Severity | Should -Be 'Critical'
    }

    It 'erkennt ungueltiges JSON, Platzhalter und falsche Wochentage' {
        Set-Content "$script:TestRoot\BackupPlan.json" '{ kaputt' -Encoding UTF8
        $r = Invoke-Tdp
        ($r.Findings | Where-Object Message -match 'kein gueltiges JSON').Severity | Should -Be 'Critical'

        New-TdpFiles -Dir $script:TestRoot
        $j = Get-Content "$script:TestRoot\BackupPlan.json" -Raw | ConvertFrom-Json
        $j.Configuration.SQLServer = '<SQLInstance>'
        $j.Schedule.FullBackupDays = @('Sonntag')
        $j | ConvertTo-Json -Depth 6 | Set-Content "$script:TestRoot\BackupPlan.json" -Encoding UTF8
        $r2 = Invoke-Tdp
        ($r2.Findings | Where-Object Message -match 'Platzhalter').Severity | Should -Be 'Critical'
        ($r2.Findings | Where-Object Message -match 'Ungueltige Wochentage').Severity | Should -Be 'Critical'
    }

    It 'findet ANS-Meldungen in TDP-Logs mit Hinweis und Schwere nach Endbuchstabe' {
        $lg = "$script:TestRoot\03_Log\backup_FULL_Shop_20300114_200001.log"
        Set-Content $lg @('01/14/2030 20:31:05 ANS1017E Session rejected: TCP/IP connection failure', '01/14/2030 20:31:06 ANS1035S Options file not found')
        (Get-Item $lg).LastWriteTime = $script:srvNow.AddHours(-1)
        $r = Invoke-Tdp
        $e = $r.Findings | Where-Object Message -match 'ANS1017E'
        $e.Severity | Should -Be 'Warning'
        $e.Hint | Should -Match 'TCP/IP'
        ($r.Findings | Where-Object Message -match 'ANS1035S').Severity | Should -Be 'Critical'
    }

    It 'ignoriert Meldungen die aelter als 7 Tage sind' {
        $lg = "$script:TestRoot\03_Log\backup_FULL_Shop_20300101_200001.log"
        Set-Content $lg @('01/01/2030 20:31:05 ANS1017E Session rejected')
        (Get-Item $lg).LastWriteTime = $script:srvNow.AddHours(-1)
        $r = Invoke-Tdp
        @($r.Findings | Where-Object Message -match 'ANS1017E') | Should -BeNullOrEmpty
    }

    It 'meldet ein Wrapper-Log, das mit FAILED endet' {
        $wl = "$script:TestRoot\03_Log\Backup_TdpFull_20300115_200001.log"
        Set-Content $wl @('TDP Backup - Started', 'FATAL ERROR: boom', 'TDP Backup FAILED', 'ExitCode: 1')
        (Get-Item $wl).LastWriteTime = $script:srvNow.AddMinutes(-10)
        $r = Invoke-Tdp
        $f = $r.Findings | Where-Object Message -match 'endet mit FAILED'
        $f.Severity | Should -Be 'Critical'
        $f.Message | Should -Match 'ExitCode 1'
    }

    It 'schreibt TXT, CSV und HTML, aber nichts mit -NoReport' {
        $r = Invoke-Tdp -Report
        Test-Path $r.TxtFile | Should -BeTrue
        Test-Path $r.CsvFile | Should -BeTrue
        Test-Path $r.HtmlFile | Should -BeTrue
        $r2 = Invoke-Tdp
        $r2.TxtFile | Should -BeNullOrEmpty
    }

    It 'wirft bei SQL-Fehler mit -NoFileFallback und liefert mit -ContinueOnError Status Error' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'login failed' }
        { Test-sqmTdpBackup -SqlInstance 'SQL01' -TdpDir $script:TestRoot -NoReport -NoOpen -NoFileFallback } | Should -Throw -ExpectedMessage '*login failed*'
        $r = Test-sqmTdpBackup -SqlInstance 'SQL01' -TdpDir $script:TestRoot -NoReport -NoOpen -NoFileFallback -ContinueOnError
        $r.Status | Should -Be 'Error'
    }

    It 'faellt bei nicht erreichbarem SQL auf die Dateipruefung zurueck und meldet den SQL-Fehler kritisch' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'login failed' }
        $r = Test-sqmTdpBackup -SqlInstance "$($env:COMPUTERNAME)\INST1" -TdpDir $script:TestRoot -NoReport -NoOpen
        $r.SqlReachable | Should -BeFalse
        $r.Status | Should -Be 'Critical'
        $f = $r.Findings | Where-Object Category -eq 'SQL'
        $f.Severity | Should -Be 'Critical'
        $f.Message | Should -Match 'login failed'
        $r.DatabaseRows | Should -BeNullOrEmpty
        # die Dateipruefung lief wirklich (gesunder Aufbau: nur der SQL-Befund ist uebrig)
        @($r.Findings | Where-Object Category -ne 'SQL' | Where-Object Severity -ne 'Info') | Should -BeNullOrEmpty
    }

    It 'findet beim Fallback auch Dateifehler' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'login failed' }
        Remove-Item (Join-Path $script:TestRoot 'tdpsqlc.exe')
        $r = Test-sqmTdpBackup -SqlInstance $env:COMPUTERNAME -TdpDir $script:TestRoot -NoReport -NoOpen
        ($r.Findings | Where-Object Message -match 'tdpsqlc.exe').Severity | Should -Be 'Critical'
        ($r.Findings | Where-Object Category -eq 'SQL') | Should -Not -BeNullOrEmpty
    }

    It 'meldet SqlReachable bei erreichbarem SQL' {
        (Invoke-Tdp).SqlReachable | Should -BeTrue
    }
}
