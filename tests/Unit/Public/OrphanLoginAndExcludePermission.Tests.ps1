#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Remove-sqmAdOrphanLogin und Set-sqmBackupExcludePermission.
.DESCRIPTION
    Remove-sqmAdOrphanLogin loescht Logins und ist deshalb der Schwerpunkt: Schutzregeln (sysadmin,
    Systemkonten, ExcludeLogin, Datenbankbesitzer), Rollback-Skript, -WhatIf. Ein nicht geschriebenes
    Rollback-Skript muss das Loeschen verhindern (1.9.182.0: es wurde nur gewarnt und trotzdem geloescht).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool {
        $script:dbatoolsAvailable = $true
        # Ohne RSAT gibt es Get-ADObject nicht; fuer den Mock braucht es ein Kommando im Modul.
        if (-not (Get-Item Function:\Get-ADObject -ErrorAction SilentlyContinue))
        {
            ${function:script:Get-ADObject} = { param($Filter, $ErrorAction) }
        }
    }
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    Remove-Variable -Name SqmQueries, SqmAdCalls -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Remove-sqmAdOrphanLogin' {
    BeforeEach {
        $script:Backup = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Get-DbaLogin {
            @(
                [pscustomobject]@{ Name = 'DOM\gone';       LoginType = 'WindowsUser' }
                [pscustomobject]@{ Name = 'DOM\gone]x';     LoginType = 'WindowsUser' }
                [pscustomobject]@{ Name = 'DOM\admin_gone'; LoginType = 'WindowsUser' }
                [pscustomobject]@{ Name = 'DOM\alive';      LoginType = 'WindowsUser' }
                [pscustomobject]@{ Name = 'DOM\owner_gone'; LoginType = 'WindowsGroup' }
                [pscustomobject]@{ Name = 'NT SERVICE\MSSQLSERVER'; LoginType = 'WindowsUser' }
                [pscustomobject]@{ Name = 'BUILTIN\Users';  LoginType = 'WindowsGroup' }
                [pscustomobject]@{ Name = 'sqlonly';        LoginType = 'SqlLogin' }
            )
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [pscustomobject]@{ name = 'DOM\admin_gone' } } -ParameterFilter { $Query -like '*is_srvrolemember*' }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($SqlParameter.login -eq 'DOM\owner_gone') { [pscustomobject]@{ name = 'Sales' } }
        } -ParameterFilter { $Query -like '*owner_sid*' }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { [pscustomobject]@{ RoleName = 'dbcreator' } } -ParameterFilter { $Query -like '*server_role_members*' }
        # Nur 'alive' existiert noch in AD. Der Filter ist ein Scriptblock mit $samName und laesst sich im Mock
        # nicht auswerten; deshalb nach Aufrufreihenfolge: gone, gone]x, alive, owner_gone (admin_gone wird
        # schon vorher als sysadmin uebersprungen).
        $global:SqmAdCalls = 0
        Mock -ModuleName sqmSQLTool Get-ADObject {
            $global:SqmAdCalls++
            if ($global:SqmAdCalls -eq 3) { [pscustomobject]@{ Name = 'alive' } }
        }
        Mock -ModuleName sqmSQLTool Remove-DbaLogin { }
    }

    It 'entfernt nur verwaiste Windows-Logins, die nicht geschuetzt sind' {
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false
        ($r | Where-Object Status -eq 'Removed').Login | Should -Be @('DOM\gone', 'DOM\gone]x')
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaLogin -Times 2 -Exactly
    }

    It 'laesst sysadmin, Datenbankbesitzer, lebende Konten, Systemkonten und SQL-Logins in Ruhe' {
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false
        ($r | Where-Object Login -eq 'DOM\admin_gone').Status | Should -Be 'Skipped'
        ($r | Where-Object Login -eq 'DOM\admin_gone').Reason | Should -Match 'sysadmin'
        ($r | Where-Object Login -eq 'DOM\owner_gone').Reason | Should -Match 'Besitzt Datenbank'
        $r.Login | Should -Not -Contain 'DOM\alive'
        $r.Login | Should -Not -Contain 'NT SERVICE\MSSQLSERVER'
        $r.Login | Should -Not -Contain 'BUILTIN\Users'
        $r.Login | Should -Not -Contain 'sqlonly'
    }

    It '-ExcludeLogin schuetzt per Wildcard' {
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -ExcludeLogin 'DOM\gone*', 'DOM\alive' -BackupPath $script:Backup -Confirm:$false
        ($r | Where-Object Status -eq 'Removed') | Should -BeNullOrEmpty
        ($r | Where-Object Login -eq 'DOM\gone').Reason | Should -Be 'ExcludeLogin'
    }

    It 'schreibt vor dem Loeschen ein Rollback-Skript mit escaptem Login und Serverrollen' {
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false
        $file = ($r | Where-Object Login -eq 'DOM\gone]x').BackupFile
        $file | Should -Not -BeNullOrEmpty
        $sql = Get-Content $file -Raw
        $sql | Should -Match ([regex]::Escape('CREATE LOGIN [DOM\gone]]x] FROM WINDOWS;'))
        $sql | Should -Match ([regex]::Escape('ALTER SERVER ROLE [dbcreator] ADD MEMBER [DOM\gone]]x];'))
    }

    It 'loescht nicht, wenn das Rollback-Skript nicht geschrieben werden kann' {
        # BackupPath zeigt auf eine Datei statt auf ein Verzeichnis -> Out-File scheitert
        $notADir = Join-Path $script:TestDir 'datei.txt'
        Set-Content -Path $notADir -Value 'x'
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $notADir -Confirm:$false
        ($r | Where-Object Status -eq 'Removed') | Should -BeNullOrEmpty
        ($r | Where-Object Login -eq 'DOM\gone').Reason | Should -Match 'Rollback-Skript'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaLogin -Times 0 -Exactly
    }

    It '-SkipBackup loescht ohne Skript' {
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -SkipBackup -Confirm:$false
        ($r | Where-Object Status -eq 'Removed').Count | Should -Be 2
        Test-Path $script:Backup | Should -BeFalse
    }

    It '-WhatIf loescht nichts und schreibt kein Skript' {
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -WhatIf
        ($r | Where-Object Status -eq 'WhatIf').Login | Should -Be @('DOM\gone', 'DOM\gone]x')
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaLogin -Times 0 -Exactly
        @(Get-ChildItem $script:Backup -Filter '*.sql' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'meldet Failed, wenn DROP LOGIN scheitert' {
        Mock -ModuleName sqmSQLTool Remove-DbaLogin { throw 'in Benutzung' }
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false
        ($r | Where-Object Login -eq 'DOM\gone').Status | Should -Be 'Failed'
        ($r | Where-Object Login -eq 'DOM\gone').Reason | Should -Match 'in Benutzung'
    }

    It 'ueberspringt ein Login, wenn die AD-Abfrage scheitert, statt es zu loeschen' {
        Mock -ModuleName sqmSQLTool Get-ADObject { throw 'Domaene nicht erreichbar' }
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false
        ($r | Where-Object Status -eq 'Removed') | Should -BeNullOrEmpty
        ($r | Where-Object Login -eq 'DOM\gone').Reason | Should -Match 'AD-Abfrage fehlgeschlagen'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaLogin -Times 0 -Exactly
    }

    It 'bricht ab, wenn die sysadmin-Liste nicht ermittelt werden kann' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'kein Zugriff' } -ParameterFilter { $Query -like '*is_srvrolemember*' }
        { Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false -EnableException } |
            Should -Throw '*Sysadmin-Logins*'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaLogin -Times 0 -Exactly
    }

    # Die Mocks oben werfen immer. Das echte Invoke-DbaQuery wirft aber nur mit -EnableException;
    # mit nur ErrorAction Stop liefert es bei einem SQL-Fehler 0 Zeilen (live geprueft, dbatools 2.9.0).
    # Diese Tests ahmen das nach, damit die Schutzregeln auch gegen das echte Verhalten halten.
    It 'bricht ab, wenn die sysadmin-Abfrage scheitert, auch mit dbatools-Verhalten ohne Ausnahme' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($EnableException) { throw 'kein Zugriff' }
        } -ParameterFilter { $Query -like '*is_srvrolemember*' }
        { Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false -EnableException } |
            Should -Throw '*Sysadmin-Logins*'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaLogin -Times 0 -Exactly
    }

    It 'ueberspringt ein Login, wenn die DB-Owner-Pruefung scheitert, statt es zu loeschen' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($EnableException) { throw 'Timeout' }
        } -ParameterFilter { $Query -like '*owner_sid*' }
        $r = Remove-sqmAdOrphanLogin -SqlInstance 'SQL01' -BackupPath $script:Backup -Confirm:$false
        ($r | Where-Object Status -eq 'Removed') | Should -BeNullOrEmpty
        ($r | Where-Object Login -eq 'DOM\gone').Status | Should -Be 'Skipped'
        ($r | Where-Object Login -eq 'DOM\gone').Reason | Should -Match 'DB-Owner-Pruefung fehlgeschlagen.*Timeout'
        Should -Invoke -ModuleName sqmSQLTool Remove-DbaLogin -Times 0 -Exactly
    }
}

Describe 'Set-sqmBackupExcludePermission' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Get-Module { [pscustomobject]@{ Name = 'dbatools' } } -ParameterFilter { $ListAvailable }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*OBJECT_ID*') { [pscustomobject]@{ TableExists = 1 } }
        }
        Mock -ModuleName sqmSQLTool Get-DbaLogin { [pscustomobject]@{ Name = 'DOM\ops' } }
        Mock -ModuleName sqmSQLTool Get-DbaDbUser { [pscustomobject]@{ Name = 'DOM\ops' } }
        Mock -ModuleName sqmSQLTool New-DbaLogin { }
        Mock -ModuleName sqmSQLTool New-DbaDbUser { }
    }

    It 'vergibt SELECT, INSERT, UPDATE und escaped ] im Login' {
        $r = Set-sqmBackupExcludePermission -SqlInstance 'SQL01' -LoginName 'DOM\o]ps' -Confirm:$false
        $r.Status | Should -Be 'Granted'
        $global:SqmQueries | Should -Contain 'GRANT SELECT, INSERT, UPDATE ON master.dbo.sqm_BackupExclude TO [DOM\o]]ps];'
    }

    It 'legt fehlendes Login und fehlenden master-Benutzer an' {
        Mock -ModuleName sqmSQLTool Get-DbaLogin { }
        Mock -ModuleName sqmSQLTool Get-DbaDbUser { }
        Set-sqmBackupExcludePermission -SqlInstance 'SQL01' -LoginName 'DOM\ops' -Confirm:$false | Out-Null
        Should -Invoke -ModuleName sqmSQLTool New-DbaLogin -Times 1 -Exactly
        Should -Invoke -ModuleName sqmSQLTool New-DbaDbUser -Times 1 -Exactly
    }

    It 'meldet TableMissing und vergibt nichts, wenn die Tabelle fehlt' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { $global:SqmQueries.Add($Query) }
        $r = Set-sqmBackupExcludePermission -SqlInstance 'SQL01' -LoginName 'DOM\ops' -Confirm:$false
        $r.Status | Should -Be 'TableMissing'
        $global:SqmQueries | Where-Object { $_ -like 'GRANT*' } | Should -BeNullOrEmpty
    }

    It '-WhatIf aendert nichts' {
        Mock -ModuleName sqmSQLTool Get-DbaLogin { }
        $r = Set-sqmBackupExcludePermission -SqlInstance 'SQL01' -LoginName 'DOM\ops' -WhatIf
        $r.Status | Should -Be 'WhatIfSkipped'
        Should -Invoke -ModuleName sqmSQLTool New-DbaLogin -Times 0 -Exactly
        $global:SqmQueries | Where-Object { $_ -like 'GRANT*' } | Should -BeNullOrEmpty
    }

    It 'meldet Failed bzw. wirft mit -EnableException, wenn GRANT scheitert' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -like 'GRANT*') { throw 'Zugriff verweigert' }
            if ($Query -like '*OBJECT_ID*') { [pscustomobject]@{ TableExists = 1 } }
        }
        (Set-sqmBackupExcludePermission -SqlInstance 'SQL01' -LoginName 'DOM\ops' -Confirm:$false).Status | Should -Be 'Failed'
        { Set-sqmBackupExcludePermission -SqlInstance 'SQL01' -LoginName 'DOM\ops' -Confirm:$false -EnableException } |
            Should -Throw '*Zugriff verweigert*'
    }
}
