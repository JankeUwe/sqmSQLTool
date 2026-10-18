#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die sysadmin-Funktionen: Invoke-sqmTempSysadminAction, Grant-sqmTemporarySysadmin
    und Restore-sqmSysadminAccess.
.DESCRIPTION
    Diese Funktionen vergeben bzw. entziehen die maechtigste Serverrolle. Getestet wird deshalb vor allem,
    was NICHT passieren darf: kein stilles Erfolgsergebnis ohne Mitgliedschaft, keine dauerhaft
    deaktivierten Server-Trigger, kein Notfall-Zugriff bei vorhandenem sysadmin, kein Login-Drop mit
    weiteren Rollen, und der Dienst wird nach der Notfallprozedur immer wieder normal gestartet.
    Invoke-DbaQuery wird durch einen kleinen Zustandsautomaten ersetzt (Login, Rollen, Trigger).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
}

AfterAll {
    Remove-Variable -Name SqmQueries, SqmState, SqmCalls, SqmTick -Scope Global -ErrorAction SilentlyContinue
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmTempSysadminAction' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        $global:SqmState = @{ LoginExists = $true; Direct = $false; Effective = $false; OtherRoles = 0; Triggers = @('trg_audit', 'trg]odd'); AlterWorks = $true }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Write-sqmEventLogSafe { }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { $null }
        Mock -ModuleName sqmSQLTool Set-sqmSqlPolicyState { [pscustomobject]@{ Status = 'Success' } }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            $st = $global:SqmState
            switch -Wildcard ($Query)
            {
                '*FROM sys.server_triggers*'        { $st.Triggers | ForEach-Object { [pscustomobject]@{ name = $_ } } }
                'DISABLE TRIGGER*'                  { }
                'ENABLE TRIGGER*'                   { }
                '*COUNT(*) AS Cnt FROM sys.server_principals*' { [pscustomobject]@{ Cnt = [int]$st.LoginExists } }
                '*AS IsEffective, CASE*'            { [pscustomobject]@{ IsEffective = [int]$st.Effective; IsDirect = [int]$st.Direct } }
                'CREATE LOGIN*'                     { $st.LoginExists = $true }
                '*ADD MEMBER*'                      { if ($st.AlterWorks) { $st.Direct = $true; $st.Effective = $true } }
                '*DROP MEMBER*'                     { $st.Direct = $false; $st.Effective = $false }
                '*AS IsDirectMember*'               { [pscustomobject]@{ IsDirectMember = [int]$st.Direct } }
                '*AS IsEffective;'                  { [pscustomobject]@{ IsEffective = [int]$st.Effective } }
                '*r.name <> ''public''*'            { [pscustomobject]@{ Cnt = $st.OtherRoles } }
                '*DROP LOGIN*'                      { $st.LoginExists = $false }
                '*sp_delete_job*'                   { }
            }
        }
    }

    Context 'Grant' {
        It 'vergibt die Rolle an ein vorhandenes Login und bestaetigt die direkte Mitgliedschaft' {
            $r = Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant
            $r.Status | Should -Be 'Success'
            $r.LoginCreated | Should -BeFalse
            $global:SqmQueries | Where-Object { $_ -like '*ALTER SERVER ROLE [[]sysadmin] ADD MEMBER [[]DOM\user]*' } | Should -Not -BeNullOrEmpty
            $global:SqmQueries | Where-Object { $_ -like 'CREATE LOGIN*' } | Should -BeNullOrEmpty
        }

        It 'legt ein fehlendes AD-Login mit -CreateLoginIfMissing an' {
            $global:SqmState.LoginExists = $false
            $r = Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\neu' -Action Grant -CreateLoginIfMissing
            $r.LoginCreated | Should -BeTrue
            $global:SqmQueries | Should -Contain 'CREATE LOGIN [DOM\neu] FROM WINDOWS;'
        }

        It 'verweigert ein fehlendes Login ohne -CreateLoginIfMissing' {
            $global:SqmState.LoginExists = $false
            { Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\neu' -Action Grant } | Should -Throw '*CreateLoginIfMissing*'
            $global:SqmQueries | Where-Object { $_ -like '*ADD MEMBER*' } | Should -BeNullOrEmpty
        }

        It 'legt kein SQL-Login ohne Domaene automatisch an' {
            $global:SqmState.LoginExists = $false
            { Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'appuser' -Action Grant -CreateLoginIfMissing } |
                Should -Throw '*Windows-/AD-Logins*'
            $global:SqmQueries | Where-Object { $_ -like 'CREATE LOGIN*' } | Should -BeNullOrEmpty
        }

        It 'meldet einen Fehler, wenn die Mitgliedschaft nach ALTER SERVER ROLE nicht besteht' {
            $global:SqmState.AlterWorks = $false
            { Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant } |
                Should -Throw '*KEIN direktes Mitglied*'
        }

        It 'escaped ] im Login und Hochkommas im Literal' {
            Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login "DOM\o]'x" -Action Grant | Out-Null
            ($global:SqmQueries -join "`n") | Should -Match ([regex]::Escape('ADD MEMBER [DOM\o]]''x]'))
            ($global:SqmQueries -join "`n") | Should -Match ([regex]::Escape("m.name = N'DOM\o]''x'"))
        }

        It 'unterstuetzt dbcreator und nutzt dann diese Rolle' {
            Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant -Role dbcreator | Out-Null
            ($global:SqmQueries | Where-Object { $_ -like '*ADD MEMBER*' }) | Should -Match '\[dbcreator\]'
        }

        It 'lehnt unbekannte Rollen ab' {
            { Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant -Role securityadmin } | Should -Throw
        }
    }

    Context 'Server-Trigger und Policy' {
        It 'deaktiviert Server-Trigger vor der Aenderung und aktiviert sie danach wieder' {
            Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant | Out-Null
            $q = @($global:SqmQueries)
            $disable = $q.IndexOf('DISABLE TRIGGER [trg_audit] ON ALL SERVER;')
            $alter   = ($q | Where-Object { $_ -like '*ADD MEMBER*' } | Select-Object -First 1)
            $enable  = $q.IndexOf('ENABLE TRIGGER [trg_audit] ON ALL SERVER;')
            $disable | Should -BeGreaterOrEqual 0
            $enable | Should -BeGreaterThan $q.IndexOf($alter)
            $q.IndexOf($alter) | Should -BeGreaterThan $disable
            $q | Should -Contain 'DISABLE TRIGGER [trg]]odd] ON ALL SERVER;'
            $q | Should -Contain 'ENABLE TRIGGER [trg]]odd] ON ALL SERVER;'
        }

        It 'aktiviert Trigger auch dann wieder, wenn die Vergabe scheitert' {
            $global:SqmState.AlterWorks = $false
            { Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant } | Should -Throw
            $global:SqmQueries | Should -Contain 'ENABLE TRIGGER [trg_audit] ON ALL SERVER;'
        }

        It '-DisableServerTriggers $false laesst Trigger in Ruhe' {
            Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant -DisableServerTriggers $false | Out-Null
            $global:SqmQueries | Where-Object { $_ -like '*TRIGGER*' } | Should -BeNullOrEmpty
        }

        It 'deaktiviert die konfigurierte Policy und stellt sie danach wieder her' {
            Mock -ModuleName sqmSQLTool Get-sqmConfig { 'PolicyX' } -ParameterFilter { $Key -eq 'DefaultPolicy' }
            Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Grant | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Set-sqmSqlPolicyState -Times 1 -Exactly -ParameterFilter { $State -eq 'Disable' -and $Policy -eq 'PolicyX' }
            Should -Invoke -ModuleName sqmSQLTool Set-sqmSqlPolicyState -Times 1 -Exactly -ParameterFilter { $State -eq 'Enable' }
        }
    }

    Context 'Revoke' {
        BeforeEach { $global:SqmState.Direct = $true; $global:SqmState.Effective = $true }

        It 'entzieht die direkte Mitgliedschaft' {
            $r = Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Revoke
            $r.Status | Should -Be 'Success'
            $global:SqmState.Direct | Should -BeFalse
            ($global:SqmQueries | Where-Object { $_ -like '*DROP MEMBER*' }) | Should -Not -BeNullOrEmpty
        }

        It '-RemoveLogin entfernt das Login, wenn es keine weiteren Rollen hat' {
            $r = Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Revoke -RemoveLogin
            $r.LoginRemoved | Should -BeTrue
            ($global:SqmQueries | Where-Object { $_ -like '*DROP LOGIN [[]DOM\user]*' }) | Should -Not -BeNullOrEmpty
        }

        It '-RemoveLogin behaelt das Login, wenn es noch weiteren Serverrollen angehoert' {
            $global:SqmState.OtherRoles = 1
            $r = Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Revoke -RemoveLogin
            $r.LoginRemoved | Should -BeFalse
            ($global:SqmQueries | Where-Object { $_ -like '*DROP LOGIN*' }) | Should -BeNullOrEmpty
        }

        It 'loescht den angegebenen Agent-Job (Hochkommas verdoppelt)' {
            $r = Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Revoke -JobName "Job'1"
            $r.JobDeleted | Should -BeTrue
            ($global:SqmQueries | Where-Object { $_ -like '*sp_delete_job*' }) | Should -Match "N'Job''1'"
        }

        It 'ohne -JobName wird kein Job geloescht' {
            Invoke-sqmTempSysadminAction -SqlInstance 'SQL01' -Login 'DOM\user' -Action Revoke | Out-Null
            ($global:SqmQueries | Where-Object { $_ -like '*sp_delete_job*' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Grant-sqmTemporarySysadmin' {
    BeforeEach {
        $global:SqmCalls = [System.Collections.Generic.List[string]]::new()
        $global:SqmState = @{ Replicas = @('SQL01', 'SQL02', 'SQL03'); LoginCount = 1; JobExists = $false }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmTempSysadminAction {
            $global:SqmCalls.Add("Action:${Action}:$("$SqlInstance"):${Login}:${Role}")
            [pscustomobject]@{ LoginCreated = $false }
        }
        Mock -ModuleName sqmSQLTool Get-DbaAgentJob { if ($global:SqmState.JobExists) { [pscustomobject]@{ Name = "$Job" } } }
        Mock -ModuleName sqmSQLTool Remove-DbaAgentJob { $global:SqmCalls.Add("RemoveJob:$Job") }
        Mock -ModuleName sqmSQLTool New-DbaAgentJob { $global:SqmCalls.Add("NewJob:$("$SqlInstance"):${Job}") }
        Mock -ModuleName sqmSQLTool New-DbaAgentJobStep { $global:SqmCalls.Add("Step:$Command") }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -like '*availability_replicas*') { $global:SqmState.Replicas | ForEach-Object { [pscustomobject]@{ replica_server_name = $_ } } }
            elseif ($Query -like '*COUNT(*) AS Cnt*') { [pscustomobject]@{ Cnt = $global:SqmState.LoginCount } }
        }
    }

    It 'vergibt sofort und legt je Replikat einen Entzugs-Job an' {
        $r = @(Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 7 -TicketNumber 'CHG1')
        $r.Status | Should -Be @('Success', 'Success', 'Success')
        $r.SqlInstance | Should -Be @('SQL01', 'SQL02', 'SQL03')
        ($global:SqmCalls | Where-Object { $_ -like 'Action:Grant:*' }).Count | Should -Be 3
        ($global:SqmCalls | Where-Object { $_ -like 'NewJob:*' }).Count | Should -Be 3
        $r[0].Immediate | Should -BeTrue
        $r[0].GrantJob | Should -BeNullOrEmpty
        $r[0].RevocationTime | Should -BeGreaterThan (Get-Date).AddDays(6.9)
    }

    It '-PrimaryOnly und -SkipSecondaryServers begrenzen die Zielserver' {
        (@(Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 1 -PrimaryOnly)).SqlInstance | Should -Be @('SQL01')
        $global:SqmCalls.Clear()
        (@(Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 1 -SkipSecondaryServers 'SQL02')).SqlInstance |
            Should -Be @('SQL01', 'SQL03')
    }

    It 'faellt auf die eigene Instanz zurueck, wenn keine AG-Replikate ermittelt werden' {
        $global:SqmState.Replicas = @()
        (@(Grant-sqmTemporarySysadmin -SqlInstance 'SQL09' -Login 'DOM\user' -Days 1)).SqlInstance | Should -Be @('SQL09')
    }

    It 'der Entzugs-Job ruft Revoke mit Login, Rolle, Ticket und Jobname auf' {
        Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 2 -PrimaryOnly -TicketNumber "CHG'1" -Role dbcreator | Out-Null
        $cmd = $global:SqmCalls | Where-Object { $_ -like 'Step:*' } | Select-Object -First 1
        $cmd | Should -Match '-Action Revoke'
        $cmd | Should -Match "-Login 'DOM\\user'"
        $cmd | Should -Match "-Role 'dbcreator'"
        $cmd | Should -Match "-TicketNumber 'CHG''1'"
        $cmd | Should -Match '-JobName ''sqmTempDbcreator_'
    }

    It 'ein neu angelegtes Login wird beim Entzug mit -RemoveLogin entfernt' {
        Mock -ModuleName sqmSQLTool Invoke-sqmTempSysadminAction { [pscustomobject]@{ LoginCreated = $true } }
        Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\neu' -Days 1 -PrimaryOnly | Out-Null
        ($global:SqmCalls | Where-Object { $_ -like 'Step:*' } | Select-Object -First 1) | Should -Match '-RemoveLogin'
    }

    It 'mit -StartDate in der Zukunft werden Vergabe UND Entzug als Jobs geplant, ohne sofort zu vergeben' {
        $start = (Get-Date).AddDays(3)
        $r = Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 2 -PrimaryOnly -StartDate $start
        $r.Immediate | Should -BeFalse
        $r.GrantJob | Should -Match '_Grant$'
        $r.RevokeJob | Should -Match '_Revoke$'
        ($global:SqmCalls | Where-Object { $_ -like 'Action:*' }) | Should -BeNullOrEmpty
        ($global:SqmCalls | Where-Object { $_ -like 'NewJob:*' }).Count | Should -Be 2
        $r.RevocationTime | Should -BeGreaterThan $start.AddDays(1.9)
    }

    It '-WhatIf vergibt nichts und legt keine Jobs an' {
        $r = @(Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 1 -WhatIf)
        $r.Status | Should -Be @('WhatIf', 'WhatIf', 'WhatIf')
        $global:SqmCalls | Should -BeNullOrEmpty
    }

    It 'bricht pro Server ab, wenn der Job schon existiert, ausser mit -Force' {
        $global:SqmState.JobExists = $true
        $r = Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 1 -PrimaryOnly
        $r.Status | Should -Be 'Error'
        $r.Message | Should -Match 'existiert'
        $global:SqmCalls.Clear()
        $r2 = Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 1 -PrimaryOnly -Force
        $r2.Status | Should -Be 'Success'
        ($global:SqmCalls | Where-Object { $_ -like 'RemoveJob:*' }).Count | Should -Be 1
    }

    It 'meldet Error und vergibt nichts, wenn die Login-Pruefung scheitert' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { if ($Query -like '*COUNT(*) AS Cnt*') { throw 'nicht erreichbar' } }
        $r = Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 1 -PrimaryOnly
        $r.Status | Should -Be 'Error'
        $r.Message | Should -Match 'Login-Pruefung fehlgeschlagen'
        $global:SqmCalls | Should -BeNullOrEmpty
    }

    It 'validiert -Days und -Role' {
        { Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 0 } | Should -Throw
        { Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 3651 } | Should -Throw
        { Grant-sqmTemporarySysadmin -SqlInstance 'SQL01' -Login 'DOM\user' -Days 1 -Role 'securityadmin' } | Should -Throw
    }
}

Describe 'Restore-sqmSysadminAccess' {
    BeforeEach {
        $global:SqmCalls = [System.Collections.Generic.List[string]]::new()
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        $global:SqmState = @{ Probe = 'fail'; Batch = 'ok'; ResetFails = $false }
        $global:SqmTick = 0
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Write-sqmEventLogSafe { $global:SqmCalls.Add("Event:$EventId") }
        Mock -ModuleName sqmSQLTool Start-Sleep { }
        Mock -ModuleName sqmSQLTool Test-Path { $false } -ParameterFilter { $Path -like 'HKLM:\Cluster*' }
        Mock -ModuleName sqmSQLTool Stop-DbaService { $global:SqmCalls.Add('Stop') }
        Mock -ModuleName sqmSQLTool Start-DbaService { $global:SqmCalls.Add('Start') }
        Mock -ModuleName sqmSQLTool Set-DbaStartupParameter {
            $global:SqmCalls.Add("Startup:SingleUser=$([bool]$SingleUser)")
            if (-not $SingleUser -and $global:SqmState.ResetFails) { throw 'Registry gesperrt' }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*IS_SRVROLEMEMBER*' -and $Query -notlike '*DECLARE*')
            {
                if ($global:SqmState.Probe -eq 'sysadmin') { [pscustomobject]@{ IsSysadmin = 1 } }
                elseif ($global:SqmState.Probe -eq 'user') { [pscustomobject]@{ IsSysadmin = 0 } }
                else { throw 'Anmeldung fehlgeschlagen' }
            }
            else
            {
                $global:SqmCalls.Add("Batch:pwd=$($SqlParameter.pwd.Length)")
                switch ($global:SqmState.Batch)
                {
                    'ok'     { [pscustomobject]@{ LoginExisted = 0; TriggersReEnabled = 1; IsSysadminNow = 1 } }
                    'nomember' { [pscustomobject]@{ LoginExisted = 0; TriggersReEnabled = 0; IsSysadminNow = 0 } }
                    'down'   { throw 'Server startet noch' }
                }
            }
        }
    }

    It 'stoppt den Dienst, startet Single-User, fuehrt den Batch aus und startet den Dienst wieder normal' {
        $r = Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -Confirm:$false
        $r.Status | Should -Be 'Success'
        ($global:SqmCalls | Where-Object { $_ -notlike 'Event:*' }) | Should -Be @(
            'Stop', 'Startup:SingleUser=True', 'Start', 'Batch:pwd=24', 'Stop', 'Startup:SingleUser=False', 'Start')
    }

    It 'erzeugt ohne -Password ein 24-stelliges Passwort und liefert es zurueck' {
        $r = Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -Confirm:$false
        $r.Password | Should -BeOfType [securestring]
        $r.PasswordPlainText.Length | Should -Be 24
    }

    It 'verwendet ein uebergebenes Passwort' {
        $pw = ConvertTo-SecureString 'Aa1!bbbbbbbbbbbbbbbbbbbb' -AsPlainText -Force
        $r = Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -Password $pw -Confirm:$false
        $r.PasswordPlainText | Should -Be 'Aa1!bbbbbbbbbbbbbbbbbbbb'
        $global:SqmCalls | Should -Contain 'Batch:pwd=24'
    }

    It 'der Batch escaped ] im Login und uebergibt das Passwort nur als Parameter' {
        Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login "DOM\a]b'c" -Confirm:$false | Out-Null
        $batch = $global:SqmQueries | Where-Object { $_ -like '*DECLARE @triggerNames*' }
        $batch | Should -Match ([regex]::Escape('ALTER SERVER ROLE sysadmin ADD MEMBER [DOM\a]]b''c];'))
        $batch | Should -Match "N'DOM\\a]b''c'"
        $batch | Should -Match 'PASSWORD = @pwd'
    }

    It 'verweigert die Notfallprozedur, wenn das aktuelle Konto schon sysadmin ist' {
        $global:SqmState.Probe = 'sysadmin'
        { Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -Confirm:$false } | Should -Throw '*bereits sysadmin*'
        $global:SqmCalls | Should -BeNullOrEmpty
    }

    It '-Force umgeht die sysadmin-Pruefung' {
        $global:SqmState.Probe = 'sysadmin'
        (Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -Force -Confirm:$false).Status | Should -Be 'Success'
    }

    It 'verweigert auf einem Cluster-Knoten, ausser mit -Force' {
        Mock -ModuleName sqmSQLTool Test-Path { $true } -ParameterFilter { $Path -like 'HKLM:\Cluster*' }
        $inst = $env:COMPUTERNAME
        { Restore-sqmSysadminAccess -SqlInstance $inst -Login 'DOM\rescue' -Confirm:$false } | Should -Throw '*Failover-Cluster*'
        $global:SqmCalls | Should -BeNullOrEmpty
    }

    It '-WhatIf stoppt keinen Dienst' {
        $r = Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -WhatIf
        $r | Should -BeNullOrEmpty
        $global:SqmCalls | Should -BeNullOrEmpty
    }

    It 'stellt den normalen Start auch dann wieder her, wenn der Batch scheitert' {
        $global:SqmState.Batch = 'nomember'
        { Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -Confirm:$false } | Should -Throw '*KEIN direktes Mitglied*'
        $calls = $global:SqmCalls | Where-Object { $_ -notlike 'Event:*' }
        $calls[-3..-1] | Should -Be @('Stop', 'Startup:SingleUser=False', 'Start')
        $global:SqmCalls | Should -Contain 'Event:9021'
    }

    It 'gibt nach dem Timeout auf und stellt den Dienst trotzdem wieder her' {
        $global:SqmState.Batch = 'down'
        Mock -ModuleName sqmSQLTool Get-Date { [datetime]::new(2030, 1, 1).AddMinutes($global:SqmTick++) }
        { Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -TimeoutSeconds 30 -Confirm:$false } |
            Should -Throw '*nimmt*Verbindung an*'
        $calls = $global:SqmCalls | Where-Object { $_ -notlike 'Event:*' }
        $calls[-3..-1] | Should -Be @('Stop', 'Startup:SingleUser=False', 'Start')
    }

    It 'meldet ein nicht zurueckgesetztes Startparameter-Flag als kritisch, startet den Dienst aber trotzdem' {
        $global:SqmState.ResetFails = $true
        $r = Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -Confirm:$false
        $r.Status | Should -Be 'Success'
        $global:SqmCalls | Should -Contain 'Event:9022'
        ($global:SqmCalls | Where-Object { $_ -notlike 'Event:*' })[-1] | Should -Be 'Start'
    }

    It 'lehnt zu kurze Timeouts ab' {
        { Restore-sqmSysadminAccess -SqlInstance 'SQL01' -Login 'DOM\rescue' -TimeoutSeconds 5 -Confirm:$false } | Should -Throw
    }
}
