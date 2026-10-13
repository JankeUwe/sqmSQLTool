#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmBackupExcludeReport. Invoke-DbaQuery wird gemockt - getestet werden
    Statuszuordnung, Hinweise, Filter, History-Beschriftung und der Fall ohne Tabelle. Die echten
    Abfragen sind live gegen SQL Server 2025 geprueft.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:out = Join-Path $TestDrive 'bx'

    function script:New-ExRow
    {
        param ([string]$Name, [int]$InTable = 1, $IsActive = 1, $IsOrphaned = 0, $Reason, $ExcludedBy, $ExcludedAt,
            [int]$Exists = 1, [string]$Recovery = 'SIMPLE', $Created = '2029-01-01', $LastFull, $LastLog)
        $n = [DBNull]::Value
        [PSCustomObject]@{
            DatabaseName = $Name; InTable = $InTable
            IsActive = $(if ($InTable) { $IsActive } else { $n }); IsOrphaned = $(if ($InTable) { $IsOrphaned } else { $n })
            Reason = $(if ($Reason) { $Reason } else { $n }); RowAddedBy = $(if ($InTable) { 'svc_sync' } else { $n }); RowAddedAt = $(if ($InTable) { [datetime]'2029-01-02' } else { $n })
            ExcludedBy = $(if ($ExcludedBy) { $ExcludedBy } else { $n }); ExcludedAt = $(if ($ExcludedAt) { [datetime]$ExcludedAt } else { $n })
            DbExists = $Exists; State = $(if ($Exists) { 'ONLINE' } else { $n }); RecoveryModel = $(if ($Exists) { $Recovery } else { $n })
            CreateDate = $(if ($Exists) { [datetime]$Created } else { $n }); SizeMB = $(if ($Exists) { 512.5 } else { $n }); AgName = $n
            LastFull = $(if ($LastFull) { [datetime]$LastFull } else { $n }); LastLog = $(if ($LastLog) { [datetime]$LastLog } else { $n })
        }
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmBackupExcludeReport' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'HasTable' } {
            [PSCustomObject]@{ HasTable = 1; HasHistory = 1; HasDdlTrigger = 0 }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WITH bk' } {
            New-ExRow -Name 'Archiv' -IsActive 0 -Reason 'Nur lesend' -ExcludedBy 'DOM\dba' -ExcludedAt '2029-06-01 10:00'
            New-ExRow -Name 'Staging' -IsActive 0 -Recovery 'FULL' -ExcludedBy 'DOM\dev' -ExcludedAt '2029-07-01 08:00'
            New-ExRow -Name 'Doppelt' -IsActive 0 -Reason 'Kopie' -ExcludedBy 'DOM\dba' -ExcludedAt '2029-06-01 10:00' -LastFull '2029-08-01 21:15'
            New-ExRow -Name 'Alt' -IsActive 0 -Reason 'vor History' -ExcludedBy $null -ExcludedAt $null
            New-ExRow -Name 'Shop' -Recovery 'FULL' -LastFull '2029-08-01 21:15' -LastLog '2029-08-02 08:00'
            New-ExRow -Name 'Weg' -IsOrphaned 1 -Exists 0
            New-ExRow -Name 'Neu' -InTable 0 -Recovery 'FULL'
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM master.dbo.sqm_BackupExclude_History\s+WHERE ChangedAt' } {
            [PSCustomObject]@{ DatabaseName = 'Staging'; ChangedField = 'IsActive'; OldValue = '1'; NewValue = '0'; ChangedBy = 'DOM\dev'; ChangedAt = [datetime]'2029-07-01 08:00' }
            [PSCustomObject]@{ DatabaseName = 'Staging'; ChangedField = 'IsActive'; OldValue = [DBNull]::Value; NewValue = '1'; ChangedBy = 'svc_sync'; ChangedAt = [datetime]'2029-01-02' }
            [PSCustomObject]@{ DatabaseName = 'Staging'; ChangedField = 'IsOrphaned'; OldValue = [DBNull]::Value; NewValue = '0'; ChangedBy = 'svc_sync'; ChangedAt = [datetime]'2029-01-02' }
            [PSCustomObject]@{ DatabaseName = 'Archiv'; ChangedField = 'IsActive'; OldValue = '0'; NewValue = '1'; ChangedBy = 'DOM\dba'; ChangedAt = [datetime]'2029-05-01' }
            [PSCustomObject]@{ DatabaseName = 'Weg'; ChangedField = 'IsOrphaned'; OldValue = '0'; NewValue = '1'; ChangedBy = 'svc_sync'; ChangedAt = [datetime]'2029-04-01' }
        }
    }

    It 'Ordnet jede Zeile einem Status zu und zaehlt' {
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $r.ExcludedCount | Should -Be 4
        $r.ActiveCount | Should -Be 1
        $r.OrphanedCount | Should -Be 1
        $r.NotInTableCount | Should -Be 1
        ($r.DetailRows | Where-Object Database -eq 'Neu').Status | Should -Be 'NotInTable'
        ($r.DetailRows | Where-Object Database -eq 'Weg').Status | Should -Be 'Orphaned'
        $r.DetailRows[0].Status | Should -Be 'Excluded'
    }

    It 'Ausgeschlossen von/am kommt aus der History, nicht aus der Haupttabelle' {
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $a = $r.DetailRows | Where-Object Database -eq 'Archiv'
        $a.ExcludedBy | Should -Be 'DOM\dba'
        $a.ExcludedAt | Should -Be '2029-06-01 10:00'
        $a.RowAddedBy | Should -Be 'svc_sync'
        ($r.DetailRows | Where-Object Database -eq 'Alt').Hints | Should -Match 'vor Einrichtung der History'
    }

    It 'Hinweise: kein Grund, FULL-Recovery ohne Log-Backup, trotz Ausschluss gesichert' {
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $s = $r.DetailRows | Where-Object Database -eq 'Staging'
        $s.Hints | Should -Match 'Kein Grund eingetragen'
        $s.Hints | Should -Match 'Recovery FULL'
        ($r.DetailRows | Where-Object Database -eq 'Doppelt').Hints | Should -Match 'Trotz Ausschluss gesichert'
        ($r.DetailRows | Where-Object Database -eq 'Archiv').Hints | Should -BeNullOrEmpty
        ($r.DetailRows | Where-Object Database -eq 'Neu').Hints | Should -Match 'kein DDL-Trigger'
    }

    It '-Status filtert die Zeilen, die Zaehler bleiben vollstaendig' {
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -Status Excluded -OutputPath $script:out -NoOpen
        @($r.DetailRows).Count | Should -Be 4
        $r.DetailRows.Status | Sort-Object -Unique | Should -Be 'Excluded'
        $r.ActiveCount | Should -Be 1
    }

    It '-IncludeHistory beschriftet die Aenderungen' {
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -IncludeHistory -OutputPath $script:out -NoOpen
        $c = @($r.History | ForEach-Object { "$($_.Database):$($_.Change)" })
        $c | Should -Contain 'Staging:ausgeschlossen'
        $c | Should -Contain 'Staging:neu erfasst (wird gesichert)'
        $c | Should -Contain 'Archiv:wieder gesichert'
        $c | Should -Contain 'Weg:verwaist (Datenbank geloescht)'
        @($r.History).Count | Should -Be 4      # IsOrphaned 0 beim INSERT ist kein eigenes Ereignis
        (Get-Content $r.HtmlFile -Raw) | Should -Match 'Aenderungen der letzten 90 Tage'
    }

    It 'Ohne History-Tabelle: kein falsches Datum, sondern Hinweis' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'HasTable' } { [PSCustomObject]@{ HasTable = 1; HasHistory = 0; HasDdlTrigger = 1 } }
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 1 -ParameterFilter { $Query -match 'WITH bk' -and $Query -notmatch 'sqm_BackupExclude_History' }
        $r.HistoryPresent | Should -Be $false
    }

    It 'Ohne Tabelle: Status NoTable, keine Berichtsdateien' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'HasTable' } { [PSCustomObject]@{ HasTable = 0; HasHistory = 0; HasDdlTrigger = 0 } }
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $r.Status | Should -Be 'NoTable'
        $r.HtmlFile | Should -BeNullOrEmpty
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 0 -ParameterFilter { $Query -match 'WITH bk' }
    }

    It 'Schreibt TXT, CSV und HTML' {
        $r = Get-sqmBackupExcludeReport -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        Test-Path $r.TxtFile | Should -Be $true
        Test-Path $r.CsvFile | Should -Be $true
        (Get-Content $r.HtmlFile -Raw) | Should -Match 'Backup-Ausschlussliste'
    }
}
