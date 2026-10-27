#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Sync-sqmLoginsToAlwaysOn -SyncMode Union und den Kern Invoke-sqmLoginUnionSync.
    Invoke-DbaQuery und Copy-sqmLogins werden gemockt: getestet wird, WAS kopiert, gemeldet und im
    Snapshot fortgeschrieben wuerde. Gegen echte Instanzen getestet: siehe CHANGELOG v1.9.191.0.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    function New-TestLogin
    {
        param ([string]$Name, [byte[]]$Sid = @(1, 2, 3), [string]$Hash = '0x0200AA', [string]$Machine = 'HOSTA', [int]$Sysadmin = 0, [string]$Type = 'S')
        [PSCustomObject]@{
            name                  = $Name
            sid                   = $Sid
            type                  = $Type
            is_disabled           = 0
            default_database_name = 'master'
            default_language_name = 'us_english'
            pwd_hash              = $Hash
            pwd_set               = [datetime]'2026-10-01 10:00'
            is_sysadmin           = $Sysadmin
            machine               = $Machine
        }
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmLoginUnionSync' {

    BeforeEach {
        # Pro Replikat: Erstlauf ja/nein, Snapshot, aktuelle Logins, geschriebener Snapshot-XML.
        $script:T = @{
            Baseline = @{ A = 0; B = 0 }
            State    = @{ A = @(); B = @() }
            Logins   = @{ A = @(); B = @() }
            Updates  = @{}
            Deleted  = @()
        }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $inst = [string](@($SqlInstance)[0])
            if (-not $script:T.Baseline.ContainsKey($inst)) { if ($EnableException) { throw "Verbindung zu $inst fehlgeschlagen" }; return }
            if ($Query -match 'OBJECT_ID') { return [PSCustomObject]@{ Created = $script:T.Baseline[$inst] } }
            if ($Query -match '^SELECT login_name') { return $script:T.State[$inst] }
            if ($Query -match 'FROM sys.server_principals') { return $script:T.Logins[$inst] }
            if ($Query -match 'DECLARE @x xml') { $script:T.Updates[$inst] = @($SqlParameter)[0]['list']; return }
            if ($Query -match '^DELETE') { $script:T.Deleted += "$inst/$(@($SqlParameter)[0]['n'])"; return }
        }
        Mock -ModuleName sqmSQLTool Copy-sqmLogins {
            foreach ($l in $Login) { [PSCustomObject]@{ Action = 'CopyLogin'; LoginName = ($l -replace '`', ''); Status = 'Success'; Message = 'Successful' } }
        }
    }

    It 'Kopiert einen Login vom Secondary auf den Primary, dem er fehlt (Failover-Fall)' {
        $script:T.Logins.A = @(New-TestLogin 'shared')
        $script:T.Logins.B = @(New-TestLogin 'shared'; New-TestLogin 'neu')
        $script:T.State.A = @([PSCustomObject]@{ login_name = 'shared'; sid = $null; dropped_at = $null; note = $null })
        $script:T.State.B = @([PSCustomObject]@{ login_name = 'shared'; sid = $null; dropped_at = $null; note = $null })

        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'A' -Confirm:$false }

        $c = @($r | Where-Object Action -eq 'Copy')
        $c.Count | Should -Be 1
        $c[0].LoginName | Should -Be 'neu'
        $c[0].SourceReplica | Should -Be 'B'
        $c[0].TargetReplica | Should -Be 'A'
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 1 -ParameterFilter { $Source -eq 'B' -and $Destination -eq 'A' -and -not $Force }
    }

    It 'Stellt einen auf einem Replikat geloeschten Login nicht wieder her (Tombstone)' {
        $script:T.Logins.A = @()
        $script:T.Logins.B = @(New-TestLogin 'weg')
        $script:T.State.A = @([PSCustomObject]@{ login_name = 'weg'; sid = $null; dropped_at = $null; note = $null })
        $script:T.State.B = @([PSCustomObject]@{ login_name = 'weg'; sid = $null; dropped_at = $null; note = $null })

        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'B' -Confirm:$false }

        ($r | Where-Object { $_.Action -eq 'Tombstone' -and $_.LoginName -eq 'weg' }).Status | Should -Be 'Warning'
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 0
    }

    It 'Erstlauf: auf dem Primary fehlender Login wird nicht kopiert, sondern als Baseline vorgemerkt' {
        $script:T.Baseline = @{ A = 1; B = 1 }
        $script:T.Logins.A = @()
        $script:T.Logins.B = @(New-TestLogin 'alt')

        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'A' -Confirm:$false }

        ($r | Where-Object { $_.Action -eq 'Tombstone' -and $_.LoginName -eq 'alt' }).Message | Should -Match 'Erstlauf'
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 0
        $script:T.Updates.A | Should -Match '<b n="alt"/>'
        $script:T.Updates.B | Should -Not -Match '<b '
    }

    It 'Erstlauf: auf einem Secondary fehlender Login wird kopiert' {
        $script:T.Baseline = @{ A = 1; B = 1 }
        $script:T.Logins.A = @(New-TestLogin 'app')
        $script:T.Logins.B = @()

        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'A' -Confirm:$false }

        ($r | Where-Object Action -eq 'Copy').TargetReplica | Should -Be 'B'
    }

    It 'Meldet Passwort-Konflikt, aendert nichts und kopiert bei widerspruechlichen Quellen nicht' {
        $script:T.Baseline.C = 0
        $script:T.State.C = @()
        $script:T.Logins.A = @(New-TestLogin 'app' -Hash '0x0200AA')
        $script:T.Logins.B = @(New-TestLogin 'app' -Hash '0x0200BB')
        $script:T.Logins.C = @()

        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B', 'C' -PrimaryReplica 'A' -Confirm:$false }

        $conf = @($r | Where-Object Action -eq 'Conflict')
        $conf.Count | Should -Be 2
        ($conf | Where-Object TargetReplica -eq '(alle)').Message | Should -Match 'Passwort-Hash'
        ($conf | Where-Object TargetReplica -eq 'C').Message | Should -Match 'Nicht kopiert'
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 0
    }

    It 'Laesst sysadmins, Systemkonten und lokale Maschinenkonten aus' {
        $script:T.Logins.A = @(
            New-TestLogin 'admin' -Sysadmin 1
            New-TestLogin 'NT SERVICE\SQLAgent' -Type 'U'
            New-TestLogin 'HOSTA\lokal' -Type 'U'
        )
        $script:T.Logins.B = @(New-TestLogin 'dummy' -Machine 'HOSTB')
        $script:T.State.B = @([PSCustomObject]@{ login_name = 'dummy'; sid = $null; dropped_at = $null; note = $null })
        $script:T.State.A = @([PSCustomObject]@{ login_name = 'dummy'; sid = $null; dropped_at = $null; note = 'Baseline' })

        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'A' -Confirm:$false }

        @($r | Where-Object Action -eq 'Copy').Count | Should -Be 0
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 0
    }

    It 'Escaped Wildcard-Zeichen im Loginnamen fuer Copy-sqmLogins' {
        $script:T.Logins.A = @(New-TestLogin 'app[1]')
        $script:T.Logins.B = @()

        InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'A' -Confirm:$false } | Out-Null

        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 1 -ParameterFilter { @($Login)[0] -eq 'app`[1`]' }
    }

    It '-ResetTombstone loescht den Snapshot-Eintrag auf jedem Replikat vorab' {
        $script:T.Logins.A = @()
        $script:T.Logins.B = @(New-TestLogin 'weg')

        InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'B' -ResetTombstone 'weg' -Confirm:$false } | Out-Null

        $script:T.Deleted | Should -Be @('A/weg', 'B/weg')
    }

    It 'Entfernt erledigte Tombstones nur, wenn alle Replikate gelesen wurden' {
        $script:T.State.A = @([PSCustomObject]@{ login_name = 'ganzweg'; sid = $null; dropped_at = [datetime]'2026-10-01'; note = $null })
        InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'A' -Confirm:$false } | Out-Null
        $script:T.Updates.A | Should -Match '<p n="ganzweg"/>'

        $script:T.Updates = @{}
        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B', 'X' -PrimaryReplica 'A' -Confirm:$false }
        ($r | Where-Object { $_.Action -eq 'ReadReplica' -and $_.TargetReplica -eq 'X' }).Status | Should -Be 'Failed'
        $script:T.Updates.A | Should -Not -Match '<p '
    }

    It 'Bricht ab, wenn weniger als zwei Replikate lesbar sind' {
        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'X' -PrimaryReplica 'A' -Confirm:$false }
        ($r | Where-Object { $_.TargetReplica -eq '(alle)' -and $_.Status -eq 'Failed' }).Message | Should -Match 'kein Abgleich'
        $script:T.Updates.Count | Should -Be 0
    }

    It '-WhatIf kopiert nicht, legt keine Tabelle an und schreibt keinen Snapshot' {
        $script:T.Logins.A = @(New-TestLogin 'app')
        $script:T.Logins.B = @()

        $r = InModuleScope sqmSQLTool { Invoke-sqmLoginUnionSync -Replica 'A', 'B' -PrimaryReplica 'A' -WhatIf }

        ($r | Where-Object Action -eq 'Copy').Status | Should -Be 'WhatIf'
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 0
        Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 0 -ParameterFilter { $Query -match 'CREATE TABLE|DECLARE @x xml' }
    }
}

Describe 'Sync-sqmLoginsToAlwaysOn -SyncMode' {

    BeforeAll {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Write-EventLog { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -match 'FROM sys.availability_groups\s+ORDER BY') { return [PSCustomObject]@{ name = 'AG1' } }
            if ($Query -match 'availability_replicas') {
                return @(
                    [PSCustomObject]@{ replica_server_name = 'SQL01'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; role_desc = 'PRIMARY' }
                    [PSCustomObject]@{ replica_server_name = 'SQL02'; availability_mode_desc = 'SYNCHRONOUS_COMMIT'; role_desc = 'SECONDARY' }
                    [PSCustomObject]@{ replica_server_name = 'SQL03'; availability_mode_desc = 'ASYNCHRONOUS_COMMIT'; role_desc = 'SECONDARY' }
                )
            }
        }
        Mock -ModuleName sqmSQLTool Invoke-sqmLoginUnionSync {
            [PSCustomObject]@{ AvailabilityGroup = 'AG1'; SyncMode = 'Union'; Action = 'Copy'; LoginName = 'x'; SourceReplica = 'SQL02'; TargetReplica = 'SQL01'; Status = 'Success'; Message = ''; Timestamp = Get-Date }
        }
        Mock -ModuleName sqmSQLTool Copy-sqmLogins { [PSCustomObject]@{ Action = 'CopyLogin'; LoginName = 'x'; Status = 'Success' } }
    }

    It 'Union ist Standard: alle Replikate, Primary benannt, Copy-sqmLogins nicht direkt' {
        $r = @(Sync-sqmLoginsToAlwaysOn -SqlInstance 'SQL01' -NoReport -BackupRetentionDays 0 -Confirm:$false)
        $r[0].SyncMode | Should -Be 'Union'
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmLoginUnionSync -Exactly 1 -ParameterFilter {
            ($Replica -join ',') -eq 'SQL01,SQL02,SQL03' -and $PrimaryReplica -eq 'SQL01' -and $AvailabilityGroupName -eq 'AG1'
        }
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 0
    }

    It 'SkipSecondaryServers nimmt ein Replikat aus dem Union-Abgleich' {
        $r = @(Sync-sqmLoginsToAlwaysOn -SqlInstance 'SQL01' -SkipSecondaryServers 'SQL03' -BackupRetentionDays 0 -Confirm:$false)
        ($r | Where-Object Status -eq 'Skipped').TargetReplica | Should -Be 'SQL03'
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmLoginUnionSync -Exactly 1 -ParameterFilter { ($Replica -join ',') -eq 'SQL01,SQL02' }
    }

    It 'Reicht -ResetTombstone und Filter durch' {
        Sync-sqmLoginsToAlwaysOn -SqlInstance 'SQL01' -ResetTombstone 'AppUser' -Login 'App*' -BackupRetentionDays 0 -Confirm:$false | Out-Null
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmLoginUnionSync -Exactly 1 -ParameterFilter { $ResetTombstone -eq 'AppUser' -and $Login -eq 'App*' }
    }

    It 'Schreibt Event 9004, wenn Tombstones oder Konflikte zu pruefen sind' {
        Mock -ModuleName sqmSQLTool Invoke-sqmLoginUnionSync {
            [PSCustomObject]@{ AvailabilityGroup = 'AG1'; SyncMode = 'Union'; Action = 'Tombstone'; LoginName = 'weg'; SourceReplica = 'SQL02'; TargetReplica = 'SQL01'; Status = 'Warning'; Message = 'geloescht'; Timestamp = Get-Date }
        }
        Mock -ModuleName sqmSQLTool New-EventLog { }
        Sync-sqmLoginsToAlwaysOn -SqlInstance 'SQL01' -BackupRetentionDays 0 -Confirm:$false | Out-Null
        Should -Invoke -ModuleName sqmSQLTool Write-EventLog -Exactly 1 -ParameterFilter { $EventId -eq 9004 -and $Message -match 'Tombstone weg' }
    }

    It 'SyncMode Primary nutzt weiter Copy-sqmLogins pro Secondary und zaehlt kopierte Logins' {
        $r = @(Sync-sqmLoginsToAlwaysOn -SqlInstance 'SQL01' -SyncMode Primary -Force:$false -BackupRetentionDays 0 -Confirm:$false)
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmLoginUnionSync -Exactly 0
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmLogins -Exactly 2
        ($r | Measure-Object -Property LoginsCount -Sum).Sum | Should -Be 2
    }
}
