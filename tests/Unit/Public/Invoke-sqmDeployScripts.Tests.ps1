﻿#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Wrapper-Transaktion von Invoke-sqmDeployScripts.

.DESCRIPTION
    Bis 1.9.187.0 liefen BEGIN TRANSACTION, die Skripte und COMMIT als getrennte Invoke-DbaQuery-Aufrufe.
    Invoke-DbaQuery setzt die Sitzung zwischen zwei Aufrufen zurueck; live auf DEV01 war @@TRANCOUNT im
    naechsten Aufruf wieder 0, jedes Skript sofort festgeschrieben, und COMMIT meldete "keine
    entsprechende BEGIN TRANSACTION". Jetzt laeuft alles ueber eine ServerConnection.

    Die Attrappe unten bildet die ServerConnection nach und fuehrt @@TRANCOUNT wie SQL Server:
    BeginTransaction erhoeht, CommitTransaction/RollBackTransaction setzen auf 0, ein Skript mit
    'COMMIT' beendet die Transaktion, 'XACT_ABORT' beendet sie und wirft.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory

    function New-FakeTxConnection
    {
        $cc = [pscustomobject]@{ StatementTimeout = 0 }
        $cc | Add-Member -MemberType ScriptMethod -Name ExecuteNonQuery -Value {
            param($Sql)
            $global:SqmTx.Calls.Add("EXEC $Sql")
            if ($Sql -like 'USE *') { return 0 }
            if ($global:SqmTx.FailOn -and $Sql -like "*$($global:SqmTx.FailOn)*")
            {
                throw [System.Exception]::new('An exception occurred while executing a Transact-SQL statement or batch.',
                    [System.Exception]::new('Fehler aufgrund einer Division durch Null.'))
            }
            if ($Sql -like '*XACT_ABORT*') { $global:SqmTx.Tc = 0; throw 'XACT_ABORT-Fehler' }
            if ($Sql -like '*BEGIN TRAN*') { $global:SqmTx.Tc++ }
            if ($Sql -like '*COMMIT*') { $global:SqmTx.Tc = 0 }
            0
        }
        $cc | Add-Member -MemberType ScriptMethod -Name ExecuteScalar -Value {
            param($Sql)
            if ($Sql -like '*@@SPID*') { return 77 }
            $global:SqmTx.Tc
        }
        $cc | Add-Member -MemberType ScriptMethod -Name BeginTransaction -Value { $global:SqmTx.Calls.Add('BEGIN'); $global:SqmTx.Tc++ }
        $cc | Add-Member -MemberType ScriptMethod -Name CommitTransaction -Value {
            $global:SqmTx.Calls.Add('COMMIT')
            if ($global:SqmTx.FailCommit) { throw 'Commit-Fehler' }
            $global:SqmTx.Tc = 0
        }
        $cc | Add-Member -MemberType ScriptMethod -Name RollBackTransaction -Value { $global:SqmTx.Calls.Add('ROLLBACK'); $global:SqmTx.Tc = 0 }
        $cc | Add-Member -MemberType ScriptMethod -Name Disconnect -Value { $global:SqmTx.Calls.Add('DISCONNECT') }
        $cc
    }
}

AfterAll {
    Remove-Variable -Name SqmTx -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmDeployScripts - Wrapper-Transaktion in einer Sitzung' {
    BeforeEach {
        $script:Scripts = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        $script:Logs = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Scripts, $script:Logs -Force
        Set-Content -Path (Join-Path $script:Scripts '01_eins.sql') -Value 'CREATE TABLE dbo.A (Id int);'
        Set-Content -Path (Join-Path $script:Scripts '02_zwei.sql') -Value 'CREATE TABLE dbo.B (Id int);'
        Set-Content -Path (Join-Path $script:Scripts '03_drei.sql') -Value 'CREATE TABLE dbo.C (Id int);'

        $global:SqmTx = @{ Tc = 0; Calls = [System.Collections.Generic.List[string]]::new(); FailOn = $null; FailCommit = $false }
        $script:FakeConn = New-FakeTxConnection
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Write-Host { }
        # Ein String bindet an DbaInstanceParameter (Backup-/NoWrap-Pfad), die Wrapper-Verbindung ist die Attrappe
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { 'SQL01' }
        $conn = $script:FakeConn
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { [pscustomobject]@{ ConnectionContext = $conn } }.GetNewClosure() -ParameterFilter { $NonPooledConnection }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { }

        $script:Run = {
            param([hashtable]$Extra = @{})
            Invoke-sqmDeployScripts -SqlInstance 'SQL01' -Database 'App' -ScriptPath $script:Scripts -LogPath $script:Logs -SkipBackup -Confirm:$false @Extra
        }
        $script:LogText = { (Get-ChildItem $script:Logs -Filter '*.log' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    }

    It 'fuehrt alle Skripte ueber die eine Verbindung aus und schreibt am Ende fest' {
        $r = & $script:Run
        $summary = $r | Where-Object OverallStatus
        $summary.OverallStatus | Should -Be 'SUCCESS'
        $summary.TransactionStatus | Should -Be 'Committed'
        $global:SqmTx.Calls[0] | Should -Be 'EXEC USE [App]'
        @($global:SqmTx.Calls | Where-Object { $_ -like 'EXEC CREATE TABLE*' }).Count | Should -Be 3
        $global:SqmTx.Calls | Should -Contain 'COMMIT'
        $global:SqmTx.Calls[-1] | Should -Be 'DISCONNECT'
        Should -Invoke -ModuleName sqmSQLTool Connect-DbaInstance -Times 1 -Exactly -ParameterFilter { $NonPooledConnection -and $Database -eq 'App' }
        # Kein Skript, kein BEGIN/COMMIT mehr per Invoke-DbaQuery
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -Exactly
    }

    It 'nimmt bei einem Skriptfehler alles zurueck und fuehrt die folgenden Skripte nicht aus' {
        $global:SqmTx.FailOn = 'dbo.B'
        $r = & $script:Run
        ($r | Where-Object ScriptName -eq '02_zwei.sql').Status | Should -Be 'Failed'
        ($r | Where-Object ScriptName -eq '02_zwei.sql').ErrorMessage | Should -Be 'Fehler aufgrund einer Division durch Null.'
        ($r | Where-Object ScriptName -eq '03_drei.sql').Status | Should -Be 'NotExecuted'
        ($r | Where-Object OverallStatus).TransactionStatus | Should -Be 'RolledBack'
        $global:SqmTx.Calls | Should -Contain 'ROLLBACK'
        $global:SqmTx.Calls | Should -Not -Contain 'COMMIT'
        & $script:LogText | Should -Match 'ROLLBACK TRANSACTION \(02_zwei.sql failed\)'
    }

    It 'wertet ein Skript, das die Wrapper-Transaktion selbst beendet, als Fehler' {
        Set-Content -Path (Join-Path $script:Scripts '02_zwei.sql') -Value 'CREATE TABLE dbo.B (Id int); COMMIT;'
        $r = & $script:Run
        ($r | Where-Object ScriptName -eq '02_zwei.sql').Status | Should -Be 'Failed'
        ($r | Where-Object ScriptName -eq '02_zwei.sql').ErrorMessage | Should -Match '@@TRANCOUNT is 0 after the script, expected 1'
        ($r | Where-Object OverallStatus).TransactionStatus | Should -Be 'EndedByScript'
        & $script:LogText | Should -Match 'Check whether changes of the failed script were committed'
    }

    It 'wertet eine offen gelassene eigene Transaktion als Fehler und nimmt alles zurueck' {
        Set-Content -Path (Join-Path $script:Scripts '02_zwei.sql') -Value 'BEGIN TRAN; CREATE TABLE dbo.B (Id int);'
        # Die Vorpruefung fragt bei BEGIN TRANSACTION im Skript per Read-Host nach; ohne Mock haengt der
        # Test an der Konsoleneingabe (unter pwsh -NonInteractive bricht er ab)
        Mock -ModuleName sqmSQLTool Read-Host { 'Y' }
        $r = & $script:Run
        Should -Invoke -ModuleName sqmSQLTool Read-Host -Times 1 -Exactly
        ($r | Where-Object ScriptName -eq '02_zwei.sql').ErrorMessage | Should -Match '@@TRANCOUNT is 2'
        ($r | Where-Object OverallStatus).TransactionStatus | Should -Be 'RolledBack'
        $global:SqmTx.Calls | Should -Contain 'ROLLBACK'
    }

    It 'ruft kein ROLLBACK, wenn SQL Server die Transaktion schon beendet hat (XACT_ABORT)' {
        Set-Content -Path (Join-Path $script:Scripts '02_zwei.sql') -Value 'SET XACT_ABORT ON; SELECT 1/0;'
        $r = & $script:Run
        ($r | Where-Object OverallStatus).TransactionStatus | Should -Be 'EndedByScript'
        $global:SqmTx.Calls | Should -Not -Contain 'ROLLBACK'
    }

    It 'meldet FAILED, wenn COMMIT scheitert, obwohl kein Skript gescheitert ist' {
        $global:SqmTx.FailCommit = $true
        $r = & $script:Run
        @($r | Where-Object Status -eq 'Failed').Count | Should -Be 0
        ($r | Where-Object OverallStatus).OverallStatus | Should -Be 'FAILED'
        ($r | Where-Object OverallStatus).TransactionStatus | Should -Be 'RolledBack'
        & $script:LogText | Should -Match 'Failed to commit transaction: Commit-Fehler'
        & $script:LogText | Should -Match 'ROLLBACK TRANSACTION \(commit failed\)'
    }

    It '-NoWrapTransaction nutzt weiter Invoke-DbaQuery und keine eigene Verbindung' {
        $r = & $script:Run @{ NoWrapTransaction = $true }
        ($r | Where-Object OverallStatus).TransactionStatus | Should -Be 'NotWrapped'
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 3 -Exactly
        Should -Invoke -ModuleName sqmSQLTool Connect-DbaInstance -Times 0 -Exactly -ParameterFilter { $NonPooledConnection }
    }
}
