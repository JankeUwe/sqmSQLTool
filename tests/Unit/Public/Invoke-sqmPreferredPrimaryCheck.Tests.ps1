#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Invoke-sqmPreferredPrimaryCheck.
    dbatools und Invoke-sqmFailover werden vollstaendig gemockt - getestet wird die
    Entscheidungslogik (schwenken / nicht schwenken), nicht der Failover selbst.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    # Liefert je nach abgesetzter Abfrage die passende Zeilenform zurueck. Die Zuordnung laeuft
    # ueber je einen Spaltenalias, der nur in genau einer der Abfragen vorkommt.
    function New-AgMockQueryResult
    {
        param(
            [string]$Query,
            [string]$PrimaryReplica = 'SQL02',
            [string]$TargetRole = 'SECONDARY',
            [string]$AvailMode = 'SYNCHRONOUS_COMMIT',
            [string]$SyncHealth = 'HEALTHY',
            [int]$TargetUptimeMinutes = 600,
            [int]$RoleAgeMinutes = 600,
            [string]$DbSyncState = 'SYNCHRONIZED',
            [int]$JoinedDbCount = 2,
            [int]$AgDbCount = 2,
            [int]$RedoQueueKB = 0,
            [switch]$SuspendedDbNull
        )

        switch -Regex ($Query)
        {
            'AS ReplicaServer' {
                return @(
                    [PSCustomObject]@{ ReplicaServer = 'SQL01'; AvailabilityMode = 'SYNCHRONOUS_COMMIT'; FailoverMode = 'MANUAL' }
                    [PSCustomObject]@{ ReplicaServer = 'SQL02'; AvailabilityMode = 'SYNCHRONOUS_COMMIT'; FailoverMode = 'MANUAL' }
                )
            }
            'AS PrimaryReplica' {
                return @([PSCustomObject]@{
                        PrimaryReplica        = $PrimaryReplica
                        AgSyncHealth          = 'HEALTHY'
                        PrimaryRecoveryHealth = 'ONLINE'
                    })
            }
            'AS SqlStartTime' {
                return @([PSCustomObject]@{
                        Role         = $TargetRole
                        OperState    = 'ONLINE'
                        ConnState    = 'CONNECTED'
                        SyncHealth   = $SyncHealth
                        AvailMode    = $AvailMode
                        FailoverMode = 'MANUAL'
                        SqlStartTime = (Get-Date).AddMinutes(-$TargetUptimeMinutes)
                    })
            }
            'AS AgDbCount' {
                $rows = @()
                for ($i = 1; $i -le $JoinedDbCount; $i++)
                {
                    $rows += [PSCustomObject]@{
                        DatabaseName = "DB$i"
                        SyncState    = $DbSyncState
                        DbState      = 'ONLINE'
                        IsSuspended  = if ($SuspendedDbNull) { [DBNull]::Value } else { $false }
                        RedoQueueKB  = $RedoQueueKB
                        AgDbCount    = $AgDbCount
                    }
                }
                return $rows
            }
            'AS RoleStartUtc' {
                return @([PSCustomObject]@{ RoleStartUtc = (Get-Date).ToUniversalTime().AddMinutes(-$RoleAgeMinutes) })
            }
        }

        return @()
    }

    function New-FailoverSuccessResult
    {
        [PSCustomObject]@{
            AvailabilityGroup   = 'AG_Test'
            OldPrimary          = 'SQL02'
            NewPrimary          = 'SQL01'
            Status              = 'Success'
            PreCheckPassed      = $true
            PostCheckPassed     = $true
            FailoverDurationSec = 4.2
            Message             = 'ok'
        }
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmPreferredPrimaryCheck' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Invoke-sqmPreferredPrimaryCheck | Should -Not -BeNullOrEmpty
        }

        It '<_> Parameter existiert' -ForEach @(
            'AvailabilityGroup', 'PreferredReplica', 'MaxRedoQueueMB', 'MinRoleAgeMinutes',
            'MinTargetUptimeMinutes', 'AllowedDay', 'AllowedTimeStart', 'AllowedTimeEnd',
            'CheckOnly', 'FailOnBlocked'
        ) {
            (Get-Command Invoke-sqmPreferredPrimaryCheck).Parameters.ContainsKey($_) | Should -Be $true
        }

        It 'Unterstuetzt WhatIf' {
            (Get-Command Invoke-sqmPreferredPrimaryCheck).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'AllowedTimeStart ohne AllowedTimeEnd wird abgelehnt' {
            {
                Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                    -PreferredReplica 'SQL01' -AllowedTimeStart '06:00' -Confirm:$false
            } | Should -Throw
        }

        It 'Ungueltige Zeitangabe wird abgelehnt' {
            {
                Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                    -PreferredReplica 'SQL01' -AllowedTimeStart '25:00' -AllowedTimeEnd '06:00' -Confirm:$false
            } | Should -Throw
        }
    }

    Context 'Bevorzugtes Replikat ist bereits Primary' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmFailover { New-FailoverSuccessResult }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -PrimaryReplica 'SQL01' }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Meldet AlreadyPrimary und schwenkt nicht' {
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'AlreadyPrimary'
            $r.Action | Should -Be 'None'
            $r.CurrentPrimary | Should -Be 'SQL01'
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Fragt die Zustaende der anderen Replikate gar nicht erst ab' {
            Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL01' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 2
        }
    }

    Context 'Falscher Primary, alle Bedingungen erfuellt' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmFailover { New-FailoverSuccessResult }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Schwenkt auf das bevorzugte Replikat zurueck' {
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'FailedOver'
            $r.Action | Should -Be 'Failover'
            $r.NewPrimary | Should -Be 'SQL01'
        }

        It 'Ruft Invoke-sqmFailover mit dem aktuellen Primary und dem bevorzugten Ziel auf' {
            Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 1 -ParameterFilter {
                $SqlInstance -eq 'SQL02' -and $TargetReplica -eq 'SQL01' -and $AvailabilityGroup -eq 'AG_Test'
            }
        }

        It 'Loest mit -WhatIf keinen Failover aus' {
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -WhatIf
            $r.Status | Should -Be 'FailoverRequired'
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Loest mit -CheckOnly keinen Failover aus, meldet aber den Bedarf' {
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -CheckOnly -Confirm:$false
            $r.Status | Should -Be 'FailoverRequired'
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Erkennt das bevorzugte Replikat auch in FQDN-Schreibweise' {
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'sql01.contoso.local' -Confirm:$false
            $r.PreferredReplica | Should -Be 'SQL01'
            $r.Status | Should -Be 'FailedOver'
        }

        It 'Schwenkt ausserhalb der erlaubten Wochentage nicht' {
            $otherDay = (Get-Date).AddDays(2).DayOfWeek.ToString()
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -AllowedDay $otherDay -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            ($r.Checks | Where-Object Name -eq 'AllowedDay').Passed | Should -Be $false
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Schwenkt innerhalb des erlaubten Zeitfensters' {
            $start = (Get-Date).AddMinutes(-30).ToString('HH:mm')
            $end = (Get-Date).AddMinutes(30).ToString('HH:mm')
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -AllowedTimeStart $start -AllowedTimeEnd $end -Confirm:$false
            ($r.Checks | Where-Object Name -eq 'AllowedTimeWindow').Passed | Should -Be $true
            $r.Status | Should -Be 'FailedOver'
        }
    }

    Context 'Falscher Primary, aber Bedingungen verletzt' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmFailover { New-FailoverSuccessResult }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Nicht synchronisierte Datenbank blockiert den Schwenk' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -DbSyncState 'SYNCHRONIZING' }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            ($r.Checks | Where-Object Name -eq 'AllDatabasesSynchronized').Passed | Should -Be $false
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Nicht gejointe Datenbank blockiert den Schwenk' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -JoinedDbCount 1 -AgDbCount 2 }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            ($r.Checks | Where-Object Name -eq 'AllDatabasesJoined').Passed | Should -Be $false
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Asynchrones Zielreplikat blockiert den Schwenk' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -AvailMode 'ASYNCHRONOUS_COMMIT' }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            ($r.Checks | Where-Object Name -eq 'TargetSynchronousCommit').Passed | Should -Be $false
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Zu kurze Laufzeit des Zielknotens blockiert den Schwenk' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -TargetUptimeMinutes 2 }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            ($r.Checks | Where-Object Name -eq 'TargetUptime').Passed | Should -Be $false
        }

        It 'Zu junger Rollenwechsel blockiert den Schwenk (Flatterschutz)' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -RoleAgeMinutes 3 }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            ($r.Checks | Where-Object Name -eq 'PrimaryRoleAge').Passed | Should -Be $false
        }

        It 'MinRoleAgeMinutes 0 schaltet den Flatterschutz ab' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -RoleAgeMinutes 3 }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -MinRoleAgeMinutes 0 -Confirm:$false
            $r.Status | Should -Be 'FailedOver'
        }

        It 'NULL in is_suspended wird nicht als suspendiert gewertet' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -SuspendedDbNull }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            ($r.Checks | Where-Object Name -eq 'AllDatabasesSynchronized').Passed | Should -Be $true
            $r.Status | Should -Be 'FailedOver'
        }

        It 'Zu grosse Redo-Queue blockiert den Schwenk' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -RedoQueueKB 204800 }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -MaxRedoQueueMB 50 -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            ($r.Checks | Where-Object Name -eq 'RedoQueue').Passed | Should -Be $false
        }

        It '-FailOnBlocked meldet den blockierten Schwenk als Fehler' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -DbSyncState 'SYNCHRONIZING' }
            {
                Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                    -PreferredReplica 'SQL01' -FailOnBlocked -EnableException -Confirm:$false
            } | Should -Throw
        }

        It 'Ohne -FailOnBlocked bleibt ein blockierter Schwenk fehlerfrei' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -DbSyncState 'SYNCHRONIZING' }
            {
                Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                    -PreferredReplica 'SQL01' -EnableException -Confirm:$false
            } | Should -Not -Throw
        }
    }

    Context 'Konfigurations- und Zustandsfehler' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmFailover { New-FailoverSuccessResult }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Unbekanntes bevorzugtes Replikat ist ein harter Fehler (Tippfehler wuerde sonst nie auffallen)' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query }
            {
                Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                    -PreferredReplica 'SQL99' -EnableException -Confirm:$false
            } | Should -Throw
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Unbekannte Availability Group ist ein harter Fehler' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            {
                Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Falsch' `
                    -PreferredReplica 'SQL01' -EnableException -Confirm:$false
            } | Should -Throw
        }

        It 'Kein ermittelbarer Primary (RESOLVING) blockiert statt zu schwenken' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query -PrimaryReplica '' }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' -PreferredReplica 'SQL01' -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmFailover -Exactly 0
        }

        It 'Fehlgeschlagener Failover wird als FailoverFailed gemeldet' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-AgMockQueryResult -Query $Query }
            Mock -ModuleName sqmSQLTool Invoke-sqmFailover {
                [PSCustomObject]@{ Status = 'Failed'; NewPrimary = $null; Message = 'Redo-Queue zu gross'; FailoverDurationSec = 0 }
            }
            $r = Invoke-sqmPreferredPrimaryCheck -SqlInstance 'SQL02' -AvailabilityGroup 'AG_Test' `
                -PreferredReplica 'SQL01' -Confirm:$false -ErrorAction SilentlyContinue
            $r.Status | Should -Be 'FailoverFailed'
        }
    }
}
