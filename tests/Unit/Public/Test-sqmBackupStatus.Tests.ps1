#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Test-sqmBackupStatus. Invoke-DbaQuery wird gemockt - getestet wird die
    Bewertung: Schwellwerte, sqm_BackupExclude, "nach dem letzten Lauf angelegt", Vorgaenger-
    Historie, Serveruhr statt Clientuhr, AG-Secondary liest beim Primary. Die echte Abfrage ist
    live gegen SQL Server 2025 geprueft.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:out = Join-Path $TestDrive 'bs'
    # Serveruhr bewusst weit weg von der Clientuhr: alle Alter muessen relativ dazu stimmen
    $script:srvNow = [datetime]'2030-01-15 12:00'

    function script:New-BkRow
    {
        param ([string]$Name, [int]$Id = 10, [datetime]$Created = '2029-01-01', [string]$Recovery = 'FULL', $Full, $Diff, $Log, $CopyOnly, $BeforeCreate,
            [string]$State = 'ONLINE', [int]$ReadOnly = 0, $Ag, $Role, $Primary)
        $n = [DBNull]::Value
        [PSCustomObject]@{
            DatabaseName = $Name; DatabaseId = $Id; CreateDate = $Created; State = $State; RecoveryModel = $Recovery
            IsReadOnly = $ReadOnly; IsStandby = 0
            AgName = $(if ($Ag) { $Ag } else { $n }); LocalRole = $(if ($Role) { $Role } else { $n }); PrimaryReplica = $(if ($Primary) { $Primary } else { $n })
            LastFull = $(if ($Full) { [datetime]$Full } else { $n }); LastDiff = $(if ($Diff) { [datetime]$Diff } else { $n })
            LastLog = $(if ($Log) { [datetime]$Log } else { $n }); LastCopyOnlyFull = $(if ($CopyOnly) { [datetime]$CopyOnly } else { $n })
            LastFullBeforeCreate = $(if ($BeforeCreate) { [datetime]$BeforeCreate } else { $n })
            ServerNow = $script:srvNow
        }
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Test-sqmBackupStatus' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'sqm_BackupExclude' } {
            [PSCustomObject]@{ DatabaseName = 'Archiv'; Reason = 'Nur lesend, Band'; ExcludedBy = 'DOM\dba'; ExcludedAt = [datetime]'2029-06-01'; IsActive = 0; IsOrphaned = 0 }
            [PSCustomObject]@{ DatabaseName = 'Shop'; Reason = [DBNull]::Value; ExcludedBy = 'sa'; ExcludedAt = [datetime]'2029-06-01'; IsActive = 1; IsOrphaned = 0 }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WITH bk' } {
            New-BkRow -Name 'master' -Id 1 -Recovery 'SIMPLE' -Full '2030-01-15 01:00'
            New-BkRow -Name 'Shop' -Full '2030-01-14 21:15' -Log '2030-01-15 11:45'
            New-BkRow -Name 'Lager' -Full '2030-01-13 21:15' -Log '2030-01-15 11:45'
            New-BkRow -Name 'Kasse' -Full '2030-01-14 21:15' -Log '2030-01-15 09:00'
            New-BkRow -Name 'Archiv' -Recovery 'SIMPLE'
            New-BkRow -Name 'NeuDb' -Created '2030-01-15 08:00'
            New-BkRow -Name 'Ersetzt' -Recovery 'SIMPLE' -Created '2030-01-15 10:00' -BeforeCreate '2030-01-14 21:15'
            New-BkRow -Name 'Altlast' -Created '2029-12-01'
            New-BkRow -Name 'Offline' -State 'OFFLINE'
        }
    }

    It 'Bewertet je Datenbank gegen die Grenzen' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $s = @{ }; foreach ($d in $r.DetailRows) { $s[$d.Database] = $d }
        $s['Shop'].Status | Should -Be 'OK'
        $s['Lager'].Status | Should -Be 'Critical'      # Full 39 h alt > 26 h
        $s['Kasse'].Status | Should -Be 'Warning'       # Log 180 min alt > 60 min
        $s['Altlast'].Status | Should -Be 'Critical'    # nie gesichert, alt
        $s['Offline'].Status | Should -Be 'Skipped'
        $s.ContainsKey('master') | Should -Be $false
        $r.Status | Should -Be 'Critical'
    }

    It 'Rechnet gegen die Serveruhr, nicht gegen die Clientuhr' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        ($r.DetailRows | Where-Object Database -eq 'Shop').FullAgeHours | Should -Be 14.8
        ($r.DetailRows | Where-Object Database -eq 'Kasse').LogAgeMinutes | Should -Be 180
    }

    It 'Beruecksichtigt sqm_BackupExclude (nur IsActive=0) mit Grund' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $a = $r.DetailRows | Where-Object Database -eq 'Archiv'
        $a.Status | Should -Be 'Excluded'
        $a.ExcludedFromBackup | Should -Be $true
        $a.Notes | Should -Match 'Nur lesend, Band'
        ($r.DetailRows | Where-Object Database -eq 'Shop').ExcludedFromBackup | Should -Be $false
        $r.ExcludedCount | Should -Be 1
    }

    It '-IgnoreExcludeTable bewertet ausgeschlossene Datenbanken normal' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen -IgnoreExcludeTable
        ($r.DetailRows | Where-Object Database -eq 'Archiv').Status | Should -Be 'Critical'
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'sqm_BackupExclude' } -Exactly 0
    }

    It 'Vermerkt Datenbanken, die nach dem letzten Backup-Lauf angelegt wurden' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $r.LastBackupRun | Should -Be ([datetime]'2030-01-14 21:15')   # master zaehlt nicht
        $r.NewSinceLastBackup | Should -Be @('NeuDb', 'Ersetzt')
        $n = $r.DetailRows | Where-Object Database -eq 'NeuDb'
        $n.NewSinceLastBackup | Should -Be $true
        $n.Status | Should -Be 'Warning'
        $n.Notes | Should -Match 'Nach dem letzten Backup-Lauf \(2030-01-14 21:15\) angelegt am 2030-01-15 08:00'
        ($r.DetailRows | Where-Object Database -eq 'Altlast').NewSinceLastBackup | Should -Be $false
        (Get-Content $r.TxtFile -Raw) | Should -Match 'Nach dem letzten Backup-Lauf angelegt: NeuDb, Ersetzt'
    }

    It 'Erkennt Historie einer frueheren gleichnamigen Datenbank' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $e = $r.DetailRows | Where-Object Database -eq 'Ersetzt'
        $e.LastFullBackup | Should -Be '(keins)'
        $e.Notes | Should -Match 'frueheren Datenbank gleichen Namens'
    }

    It '-ExcludeDatabase verschiebt den letzten Lauf nicht' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen -ExcludeDatabase 'Shop', 'Kasse'
        $r.LastBackupRun | Should -Be ([datetime]'2030-01-14 21:15')
        ($r.DetailRows | Where-Object Database -eq 'NeuDb').NewSinceLastBackup | Should -Be $true
        $r.DetailRows.Database | Should -Not -Contain 'Shop'
    }

    It 'AG-Secondary: liest die Historie beim Primary' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WITH bk' -and [string]$SqlInstance -eq 'SQL01' } {
            New-BkRow -Name 'AgDb' -Ag 'AG1' -Role 'SECONDARY' -Primary 'SQL02'
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WITH bk' -and [string]$SqlInstance -eq 'SQL02' } {
            New-BkRow -Name 'AgDb' -Ag 'AG1' -Role 'PRIMARY' -Primary 'SQL02' -Full '2030-01-14 21:15' -Log '2030-01-15 11:45'
        }
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $d = $r.DetailRows | Where-Object Database -eq 'AgDb'
        $d.Status | Should -Be 'OK'
        $d.HistorySource | Should -Be 'Primary SQL02'
        $d.ReplicaRole | Should -Be 'SECONDARY'
    }

    It 'AG-Secondary: unerreichbarer Primary ergibt Skipped mit Hinweis' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WITH bk' -and [string]$SqlInstance -eq 'SQL01' } {
            New-BkRow -Name 'AgDb' -Ag 'AG1' -Role 'SECONDARY' -Primary 'SQL02'
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WITH bk' -and [string]$SqlInstance -eq 'SQL02' } { throw 'Der Netzwerkpfad wurde nicht gefunden' }
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        $d = $r.DetailRows | Where-Object Database -eq 'AgDb'
        $d.Status | Should -Be 'Skipped'
        $d.Notes | Should -Match 'SQL02 nicht erreichbar'
    }

    It 'Schreibt TXT, CSV und HTML' {
        $r = Test-sqmBackupStatus -SqlInstance 'SQL01' -OutputPath $script:out -NoOpen
        Test-Path $r.TxtFile | Should -Be $true
        Test-Path $r.CsvFile | Should -Be $true
        (Get-Content $r.HtmlFile -Raw) | Should -Match 'Backup-Kontrolle'
    }
}
