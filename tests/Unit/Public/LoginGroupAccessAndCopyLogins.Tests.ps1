#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Test-sqmLoginGroupAccess und Copy-sqmLogins.
.DESCRIPTION
    Test-sqmLoginGroupAccess: die Diagnose (NoGroups, NoLoginGroup, LoginBlocked, NoDatabaseAccess, OK) aus
    AD-Gruppen, Server-Logins und Datenbank-Usern, mit Namens- und SID-Abgleich.
    Copy-sqmLogins: kopiert Logins zwischen Instanzen. Geprueft werden die Schutzregeln (sa, sysadmin und
    Systemkonten werden nie kopiert), Auth-Mode-Konflikt, AD-Pruefung, Policy-Handling mit garantierter
    Reaktivierung, Statusuebersetzung und -WhatIf. dbatools, SMO und AD sind gemockt.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool {
        $script:dbatoolsAvailable = $true
        if (-not (Get-Item Function:\Get-ADObject -ErrorAction SilentlyContinue))
        {
            ${function:script:Get-ADObject} = { param($Filter, $ErrorAction) }
        }
    }
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    Remove-Variable -Name SqmAd, SqmCalls, SqmCopy -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Test-sqmLoginGroupAccess' {
    BeforeEach {
        $global:SqmAd = @{
            Status = 'OK'
            Groups = @(
                [pscustomobject]@{ SamAccountName = 'SQL_Sales'; DisplayName = 'SQL Sales'; Depth = 1 }
                [pscustomobject]@{ SamAccountName = 'SQL_Hr';    DisplayName = 'SQL HR';    Depth = 2 }
            )
            Logins = @(
                [pscustomobject]@{ LoginName = 'DOM\SQL_Sales'; IsDisabled = $false; Sid = [byte[]](1, 1); DenyConnectSql = 0 }
            )
            DbUsers = @{ Sales = @([pscustomobject]@{ DbUserName = 'DOM\SQL_Sales'; Sid = [byte[]](1, 1); Roles = 'db_datareader' }) }
        }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Get-sqmADMemberGroups {
            [pscustomobject]@{ Identity = 'alice'; Domain = 'DOM'; DisplayName = 'Alice A'; Status = $global:SqmAd.Status; Message = 'AD nicht erreichbar'; Groups = $global:SqmAd.Groups }
        }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase {
            @([pscustomobject]@{ Name = 'Sales'; IsAccessible = $true }, [pscustomobject]@{ Name = 'master'; IsAccessible = $true }, [pscustomobject]@{ Name = 'Offline'; IsAccessible = $false })
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -like '*DenyConnectSql*') { $global:SqmAd.Logins }
            elseif ($Query -like '*AS DbUserName*') { $global:SqmAd.DbUsers["$Database"] }
        }
    }

    It 'OK: Gruppe ist Login, aktiv und hat Datenbankzugriff (Domaenenpraefix wird ignoriert)' {
        $r = Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf
        $r.Diagnosis | Should -Be 'OK'
        $r.Status | Should -Be 'OK'
        $r.GroupsChecked | Should -Be 2
        $sales = $r.Detail | Where-Object GroupSamAccountName -eq 'SQL_Sales'
        $sales.HasServerLogin | Should -BeTrue
        $sales.DatabaseAccessSummary | Should -Be 'Sales (db_datareader)'
        ($r.Detail | Where-Object GroupSamAccountName -eq 'SQL_Hr').HasServerLogin | Should -BeFalse
    }

    It 'NoGroups: Benutzer ist in keiner Gruppe' {
        $global:SqmAd.Groups = @()
        (Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf).Diagnosis | Should -Be 'NoGroups'
    }

    It 'NoLoginGroup: keine der Gruppen ist als Login angelegt' {
        $global:SqmAd.Logins = @()
        $r = Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf
        $r.Diagnosis | Should -Be 'NoLoginGroup'
        $r.Status | Should -Be 'Warning'
    }

    It 'LoginBlocked: Login deaktiviert oder DENY CONNECT SQL' {
        $global:SqmAd.Logins[0].IsDisabled = $true
        (Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf).Diagnosis | Should -Be 'LoginBlocked'
        $global:SqmAd.Logins[0].IsDisabled = $false
        $global:SqmAd.Logins[0].DenyConnectSql = 1
        $r = Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf
        $r.Diagnosis | Should -Be 'LoginBlocked'
        ($r.Detail | Where-Object LoginName -eq 'DOM\SQL_Sales').Assessment | Should -Match 'DENY CONNECT SQL'
    }

    It 'NoDatabaseAccess bei -Database, NoDatabaseAccessAnywhere ohne' {
        $global:SqmAd.DbUsers = @{}
        (Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -Database 'Sales' -WhatIf).Diagnosis | Should -Be 'NoDatabaseAccess'
        (Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf).Diagnosis | Should -Be 'NoDatabaseAccessAnywhere'
    }

    It 'ordnet DB-User ueber die SID zu, nicht ueber den Namen' {
        $global:SqmAd.DbUsers = @{ Sales = @([pscustomobject]@{ DbUserName = 'DOM\SQL_Sales'; Sid = [byte[]](9, 9); Roles = 'db_owner' }) }
        (Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf).Diagnosis | Should -Be 'NoDatabaseAccessAnywhere'
    }

    It '-Database, -ExcludeDatabase und -ExcludeSystemDatabases begrenzen die Datenbanken; nicht erreichbare werden uebergangen' {
        $global:SqmAd.DbUsers = @{
            Sales   = @([pscustomobject]@{ DbUserName = 'u'; Sid = [byte[]](1, 1); Roles = 'a' })
            master  = @([pscustomobject]@{ DbUserName = 'u'; Sid = [byte[]](1, 1); Roles = 'b' })
            Offline = @([pscustomobject]@{ DbUserName = 'u'; Sid = [byte[]](1, 1); Roles = 'c' })
        }
        $all = Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf
        ($all.Detail | Where-Object LoginName).DatabaseAccessSummary | Should -Be 'Sales (a); master (b)'
        (Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -ExcludeSystemDatabases -WhatIf).Detail.DatabaseAccessSummary |
            Where-Object { $_ } | Should -Be 'Sales (a)'
        (Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -ExcludeDatabase 'Sales' -WhatIf).Detail.DatabaseAccessSummary |
            Where-Object { $_ } | Should -Be 'master (b)'
    }

    It 'AD-Fehler: Error-Ergebnis, wirft aber ohne -ContinueOnError' {
        $global:SqmAd.Status = 'Error'
        { Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf } | Should -Throw '*AD nicht erreichbar*'
        $r = Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -WhatIf -ContinueOnError
        $r.Diagnosis | Should -Be 'Error'
    }

    It 'prueft mehrere Identitaeten einzeln' {
        $r = @(Test-sqmLoginGroupAccess -Identity 'alice', 'bob' -SqlInstance 'SQL01' -WhatIf)
        $r.Count | Should -Be 2
        Should -Invoke -ModuleName sqmSQLTool Get-sqmADMemberGroups -Times 2 -Exactly
    }

    It 'schreibt ohne -WhatIf TXT, CSV und HTML in -OutputPath, mit -WhatIf nichts' {
        $out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        $null = Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -OutputPath $out -WhatIf
        Test-Path $out | Should -BeFalse
        $r = Test-sqmLoginGroupAccess -Identity 'alice' -SqlInstance 'SQL01' -OutputPath $out -NoOpen
        Test-Path $r.TxtFile | Should -BeTrue
        Test-Path $r.CsvFile | Should -BeTrue
        Test-Path $r.HtmlFile | Should -BeTrue
        (Get-Content $r.TxtFile -Raw) | Should -Match 'Diagnose   : OK'
    }
}

Describe 'Copy-sqmLogins' {
    BeforeEach {
        $global:SqmCalls = [System.Collections.Generic.List[string]]::new()
        $global:SqmCopy = @{
            SrcMode = 1; DstMode = 1; AlterCalled = $false; CopyThrows = $false; AdPresent = $true; AdKnown = @('alice', 'bob')
            Logins = @(
                [pscustomobject]@{ Name = 'app_user'; LoginType = 'SqlLogin';   Sid = [byte[]](5, 5, 5); IsSystemObject = $false }
                [pscustomobject]@{ Name = 'DOM\alice'; LoginType = 'WindowsUser'; Sid = [byte[]](6, 6); IsSystemObject = $false }
                [pscustomobject]@{ Name = 'DOM\ghost'; LoginType = 'WindowsUser'; Sid = [byte[]](7, 7); IsSystemObject = $false }
                [pscustomobject]@{ Name = 'sa';        LoginType = 'SqlLogin';   Sid = [byte[]](1);       IsSystemObject = $false }
                [pscustomobject]@{ Name = 'dba_admin'; LoginType = 'SqlLogin';   Sid = [byte[]](8, 8);    IsSystemObject = $false }
                [pscustomobject]@{ Name = '##MS_PolicyEventProcessingLogin##'; LoginType = 'SqlLogin'; Sid = [byte[]](9, 9); IsSystemObject = $true }
                [pscustomobject]@{ Name = 'NT SERVICE\MSSQLSERVER'; LoginType = 'WindowsUser'; Sid = [byte[]](4, 4); IsSystemObject = $true }
            )
        }
        $script:Src = [pscustomobject]@{ LoginMode = 1 }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Start-Sleep { }
        Mock -ModuleName sqmSQLTool Test-sqmInteractiveSession { $true }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { 'PolicyX' } -ParameterFilter { $Key -eq 'DefaultPolicy' }
        Mock -ModuleName sqmSQLTool Get-Module { if ($global:SqmCopy.AdPresent) { [pscustomobject]@{ Name = 'ActiveDirectory' } } } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock -ModuleName sqmSQLTool Import-Module { } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock -ModuleName sqmSQLTool Install-sqmAdModule { $false }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -like '*SUSER_SNAME(0x01)*') { [pscustomobject]@{ n = 'sa' } }
            elseif ($Query -like '*is_srvrolemember*') { [pscustomobject]@{ name = 'sa' }, [pscustomobject]@{ name = 'dba_admin' } }
        }
        Mock -ModuleName sqmSQLTool Connect-DbaInstance {
            $mode = if ("$SqlInstance" -eq 'SRC') { $global:SqmCopy.SrcMode } else { $global:SqmCopy.DstMode }
            $o = [pscustomobject]@{ LoginMode = $mode }
            $o | Add-Member -MemberType ScriptMethod -Name Alter -Value { $global:SqmCopy.AlterCalled = $true }
            $o
        }
        Mock -ModuleName sqmSQLTool Get-DbaLogin { $global:SqmCopy.Logins }
        # Reihenfolge der AD-Abfragen = Reihenfolge der Windows-Logins (alice, ghost); nur alice existiert
        Mock -ModuleName sqmSQLTool Get-ADObject {
            $global:SqmCalls.Add('AD')
            if ($global:SqmCalls.Where({ $_ -eq 'AD' }).Count -eq 1) { [pscustomobject]@{ Name = 'alice' } }
        }
        Mock -ModuleName sqmSQLTool Set-sqmSqlPolicyState { $global:SqmCalls.Add("Policy:${State}"); [pscustomobject]@{ Status = 'Success' } }
        Mock -ModuleName sqmSQLTool Copy-DbaLogin {
            $global:SqmCalls.Add("Copy:$($Login -join ',')")
            $global:SqmCalls.Add("CopyCred:$([bool]$SourceSqlCredential):$([bool]$DestinationSqlCredential):$([bool]$Force)")
            if ($global:SqmCopy.CopyThrows) { throw 'Copy kaputt' }
            $Login | ForEach-Object { [pscustomobject]@{ Name = $_; Status = if ($_ -eq 'app_user') { 'Successful' } else { 'Skipped' }; Notes = "Notiz $_" } }
        }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase {
            @([pscustomobject]@{ Name = 'Sales'; IsSystemObject = $false; Status = 'Normal' }, [pscustomobject]@{ Name = 'Old'; IsSystemObject = $false; Status = 'Offline' }, [pscustomobject]@{ Name = 'master'; IsSystemObject = $true; Status = 'Normal' })
        }
        Mock -ModuleName sqmSQLTool Repair-DbaDbOrphanUser { $global:SqmCalls.Add("Repair:$($Database -join ',')"); @(1) }
        Mock -ModuleName sqmSQLTool Restart-DbaService { $global:SqmCalls.Add('Restart') }
        Mock -ModuleName sqmSQLTool Write-Host { }
    }

    It 'kopiert nur Nicht-System-, Nicht-sysadmin-Logins, die im AD existieren' {
        $r = Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue
        ($global:SqmCalls | Where-Object { $_ -like 'Copy:*' }) | Should -Be 'Copy:app_user,DOM\alice'
        ($r | Where-Object LoginName -eq 'DOM\ghost').Status | Should -Be 'AdOrphan'
    }

    It 'uebersetzt Successful in Success und uebernimmt die Notiz als Meldung' {
        $r = Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue
        $app = $r | Where-Object { $_.Action -eq 'CopyLogin' -and $_.LoginName -eq 'app_user' }
        $app.Status | Should -Be 'Success'
        $app.Message | Should -Be 'Notiz app_user'
        ($r | Where-Object { $_.Action -eq 'CopyLogin' -and $_.LoginName -eq 'DOM\alice' }).Status | Should -Be 'Skipped'
    }

    It '-IncludeSystemLogins nimmt Systemkonten mit, aber nie das sa-Login (SID 0x01)' {
        Copy-sqmLogins -Source SRC -Destination DST -IncludeSystemLogins -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        $copied = (($global:SqmCalls | Where-Object { $_ -like 'Copy:*' }) -replace '^Copy:', '') -split ','
        $copied | Should -Not -Contain 'sa'
        $copied | Should -Contain '##MS_PolicyEventProcessingLogin##'
        $copied | Should -Contain 'dba_admin'
    }

    It '-Login und -ExcludeLogin filtern per Wildcard' {
        Copy-sqmLogins -Source SRC -Destination DST -Login 'app*', 'DOM\alice' -ExcludeLogin 'DOM\a*' -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        ($global:SqmCalls | Where-Object { $_ -like 'Copy:*' }) | Should -Be 'Copy:app_user'
    }

    It 'meldet Skipped, wenn nach den Filtern nichts uebrig bleibt, und kopiert nichts' {
        $r = @(Copy-sqmLogins -Source SRC -Destination DST -Login 'gibtsnicht' -Confirm:$false -WarningAction SilentlyContinue)
        $r.Where({ $_.Action -eq 'FilterLogins' }).Status | Should -Be 'Skipped'
        $global:SqmCalls | Where-Object { $_ -like 'Copy:*' } | Should -BeNullOrEmpty
    }

    It 'leitet Source-/DestinationCredential und -Force an Copy-DbaLogin weiter' {
        $c = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
        Copy-sqmLogins -Source SRC -Destination DST -SourceCredential $c -DestinationCredential $c -Force -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        $global:SqmCalls | Should -Contain 'CopyCred:True:True:True'
        $global:SqmCalls.Clear()
        Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        $global:SqmCalls | Should -Contain 'CopyCred:False:False:False'
    }

    Context 'Auth-Mode' {
        It 'Konflikt (Quelle Mixed, Ziel nur Windows) ohne -AdjustAuthMode: Failed, nichts wird kopiert' {
            $global:SqmCopy.SrcMode = 2
            $r = Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            ($r | Where-Object Action -eq 'AuthModeCheck').Status | Should -Be 'Failed'
            $global:SqmCopy.AlterCalled | Should -BeFalse
            $global:SqmCalls | Where-Object { $_ -like 'Copy:*' } | Should -BeNullOrEmpty
        }

        It '-AdjustAuthMode stellt das Ziel um und warnt vor dem noetigen Neustart' {
            $global:SqmCopy.SrcMode = 2
            $r = Copy-sqmLogins -Source SRC -Destination DST -AdjustAuthMode -Confirm:$false -WarningAction SilentlyContinue
            $global:SqmCopy.AlterCalled | Should -BeTrue
            ($r | Where-Object Action -eq 'AdjustAuthMode' | Select-Object -Last 1).Status | Should -Be 'Warning'
            $global:SqmCalls | Should -Not -Contain 'Restart'
        }

        It '-RestartServiceIfRequired startet den Dienst neu' {
            $global:SqmCopy.SrcMode = 2
            Copy-sqmLogins -Source SRC -Destination DST -AdjustAuthMode -RestartServiceIfRequired -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            $global:SqmCalls | Should -Contain 'Restart'
        }

        It 'kein Konflikt, wenn beide Seiten Mixed sind' {
            $global:SqmCopy.SrcMode = 2; $global:SqmCopy.DstMode = 2
            $r = Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue
            ($r | Where-Object Action -eq 'AuthModeCheck').Status | Should -Be 'OK'
        }
    }

    Context 'AD-Pruefung' {
        It 'ein AD-Abfragefehler ueberspringt das Login statt es zu kopieren' {
            Mock -ModuleName sqmSQLTool Get-ADObject { throw 'Domaene nicht erreichbar' }
            $r = Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue
            ($r | Where-Object LoginName -eq 'DOM\alice').Status | Should -Be 'AdQueryFailed'
            ($global:SqmCalls | Where-Object { $_ -like 'Copy:*' }) | Should -Be 'Copy:app_user'
        }

        It 'ohne AD-Modul und -AdModuleAction Skip werden Windows-Logins ohne AD-Pruefung kopiert' {
            $global:SqmCopy.AdPresent = $false
            $r = Copy-sqmLogins -Source SRC -Destination DST -AdModuleAction Skip -Confirm:$false -WarningAction SilentlyContinue
            ($r | Where-Object Action -eq 'AdCheck').Status | Should -Be 'Skipped'
            ($global:SqmCalls | Where-Object { $_ -like 'Copy:*' }) | Should -Be 'Copy:app_user,DOM\alice,DOM\ghost'
        }

        It '-AdModuleAction Abort bricht ohne AD-Modul ab' {
            $global:SqmCopy.AdPresent = $false
            { Copy-sqmLogins -Source SRC -Destination DST -AdModuleAction Abort -Confirm:$false } | Should -Throw '*Abort*'
            $global:SqmCalls | Where-Object { $_ -like 'Copy:*' } | Should -BeNullOrEmpty
        }

        It 'nicht interaktiv wird die Installation des AD-Moduls nicht versucht (Skip)' {
            $global:SqmCopy.AdPresent = $false
            Mock -ModuleName sqmSQLTool Test-sqmInteractiveSession { $false }
            Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Install-sqmAdModule -Times 0 -Exactly
        }
    }

    Context 'Policy' {
        It 'deaktiviert die Policy vor dem Kopieren und aktiviert sie danach wieder' {
            Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            $order = $global:SqmCalls | Where-Object { $_ -like 'Policy:*' -or $_ -like 'Copy:*' }
            $order | Should -Be @('Policy:Disable', 'Copy:app_user,DOM\alice', 'Policy:Enable')
        }

        It 'aktiviert die Policy auch dann wieder, wenn Copy-DbaLogin scheitert' {
            $global:SqmCopy.CopyThrows = $true
            $r = Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue
            ($r | Where-Object { $_.Action -eq 'CopyLogin' }).Status | Should -Be 'Failed'
            $global:SqmCalls | Should -Contain 'Policy:Enable'
        }

        It 'ohne konfigurierte DefaultPolicy wird nichts deaktiviert oder aktiviert' {
            Mock -ModuleName sqmSQLTool Get-sqmConfig { $null } -ParameterFilter { $Key -eq 'DefaultPolicy' }
            $r = Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue
            ($r | Where-Object Action -eq 'PolicyDisable').Status | Should -Be 'Skipped'
            $global:SqmCalls | Where-Object { $_ -like 'Policy:*' } | Should -BeNullOrEmpty
        }

        It '-DisablePolicy $false laesst die Policy in Ruhe' {
            Copy-sqmLogins -Source SRC -Destination DST -DisablePolicy $false -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            $global:SqmCalls | Where-Object { $_ -like 'Policy:*' } | Should -BeNullOrEmpty
        }
    }

    Context 'Orphan-Repair, WhatIf und Fehler' {
        It 'repariert verwaiste User nur in Benutzerdatenbanken im Status Normal' {
            Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            $global:SqmCalls | Should -Contain 'Repair:Sales'
        }

        It '-WhatIf kopiert, deaktiviert und repariert nichts' {
            $r = Copy-sqmLogins -Source SRC -Destination DST -WhatIf -WarningAction SilentlyContinue
            ($r | Where-Object Action -eq 'CopyLogin').Status | Should -Be @('WhatIf', 'WhatIf')
            $global:SqmCalls | Where-Object { $_ -notlike 'AD' } | Should -BeNullOrEmpty
        }

        It 'Verbindungsfehler zur Quelle ergibt genau ein Failed-Ergebnis (nicht doppelt)' {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { throw 'unbekannter Host' } -ParameterFilter { "$SqlInstance" -eq 'SRC' }
            $r = @(Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false)
            $r.Count | Should -Be 1
            $r[0].Action | Should -Be 'Connect'
            $r[0].Status | Should -Be 'Failed'
        }

        It '-EnableException wirft bei Verbindungsfehler zum Ziel' {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { throw 'Ziel weg' } -ParameterFilter { "$SqlInstance" -eq 'DST' }
            { Copy-sqmLogins -Source SRC -Destination DST -Confirm:$false -EnableException } | Should -Throw '*Ziel weg*'
        }
    }
}
