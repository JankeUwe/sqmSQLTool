#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmDbOwnerRisk, Repair-sqmDbOwnerRisk, Set-sqmDatabaseOwner und
    Remove-sqmMasterDbCustomObjects.
.DESCRIPTION
    dbatools wird gemockt, alle an Invoke-DbaQuery uebergebenen Abfragen werden mitgeschrieben.
    Schwerpunkt: Bewertung (OK/Warning/Critical), -WhatIf aendert nichts, und Bezeichner mit ']'
    werden als ']]' escaped. Letzteres war in 1.9.182.0 kaputt: die Ersetzung '\]\]' liefert
    woertlich '\]\]' und damit ungueltiges SQL fuer jeden Namen mit ']'.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    Remove-Variable -Name SqmQueries -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmDbOwnerRisk' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Get-sqmDatabaseTrustIsolationMap { @{} }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase {
            @(
                [pscustomobject]@{ Name = 'DbOk';   IsSystemObject = $false }
                [pscustomobject]@{ Name = 'DbCrit'; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'DbWarn'; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'DbSvc';  IsSystemObject = $false }
                [pscustomobject]@{ Name = 'master'; IsSystemObject = $true }
                [pscustomobject]@{ Name = 'tempdb'; IsSystemObject = $true }
            )
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            @(
                [pscustomobject]@{ DatabaseName = 'DbOk';   IsTrustworthyOn = $false; DbOwnerLogin = 'sa';   OwnerIsSysAdmin = 1 }
                [pscustomobject]@{ DatabaseName = 'DbCrit'; IsTrustworthyOn = $true;  DbOwnerLogin = 'sa';   OwnerIsSysAdmin = 1 }
                [pscustomobject]@{ DatabaseName = 'DbWarn'; IsTrustworthyOn = $false; DbOwnerLogin = 'app';  OwnerIsSysAdmin = 0 }
                [pscustomobject]@{ DatabaseName = 'DbSvc';  IsTrustworthyOn = $true;  DbOwnerLogin = 'sa';   OwnerIsSysAdmin = 1 }
                [pscustomobject]@{ DatabaseName = 'master'; IsTrustworthyOn = $false; DbOwnerLogin = 'sa';   OwnerIsSysAdmin = 1 }
            )
        } -ParameterFilter { $Query -like '*is_trustworthy_on*' }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            switch ("$Database")
            {
                'DbCrit' { [pscustomobject]@{ MemberName = 'dbo' }, [pscustomobject]@{ MemberName = 'app_user' } }
                'DbWarn' { [pscustomobject]@{ MemberName = 'app_user' } }
                'DbSvc'  { [pscustomobject]@{ MemberName = 'svc_backup' }, [pscustomobject]@{ MemberName = 'dbo' } }
                'master' { [pscustomobject]@{ MemberName = 'x' } }
                default  { [pscustomobject]@{ MemberName = 'dbo' } }
            }
        } -ParameterFilter { $Query -like '*database_role_members*' }
    }

    It 'bewertet OK, Warning und Critical' {
        $r = Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -WhatIf
        ($r | Where-Object DatabaseName -eq 'DbOk').Severity   | Should -Be 'OK'
        ($r | Where-Object DatabaseName -eq 'DbWarn').Severity | Should -Be 'Warning'
        $crit = $r | Where-Object DatabaseName -eq 'DbCrit'
        $crit.Severity | Should -Be 'Critical'
        $crit.EscalationPossible | Should -BeTrue
        $crit.DbOwnerMembers | Should -Be @('app_user')
    }

    It 'dbo zaehlt nicht als Mitglied' {
        $r = Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -WhatIf
        ($r | Where-Object DatabaseName -eq 'DbOk').MemberCount | Should -Be 0
    }

    It '-ExcludeLogin nimmt Mitglieder aus der Bewertung' {
        $r = Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -ExcludeLogin 'svc_*' -WhatIf
        ($r | Where-Object DatabaseName -eq 'DbSvc').Severity | Should -Be 'OK'
        $r2 = Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -WhatIf
        ($r2 | Where-Object DatabaseName -eq 'DbSvc').Severity | Should -Be 'Critical'
    }

    It 'laesst Systemdatenbanken weg, tempdb immer' {
        $names = (Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -WhatIf).DatabaseName
        $names | Should -Not -Contain 'master'
        $namesAll = (Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -IncludeSystemDatabases -WhatIf).DatabaseName
        $namesAll | Should -Contain 'master'
        $namesAll | Should -Not -Contain 'tempdb'
    }

    It '-Database und -ExcludeDatabase arbeiten mit Wildcards' {
        (Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -Database 'DbC*' -WhatIf).DatabaseName | Should -Be @('DbCrit')
        (Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -ExcludeDatabase 'Db*' -WhatIf) | Should -BeNullOrEmpty
    }

    It 'wirft bei Verbindungsfehler, ausser mit -ContinueOnError' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'nicht erreichbar' } -ParameterFilter { $Query -like '*is_trustworthy_on*' }
        { Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -WhatIf } | Should -Throw '*nicht erreichbar*'
        { Get-sqmDbOwnerRisk -SqlInstance 'SQL01' -WhatIf -ContinueOnError } | Should -Not -Throw
    }
}

Describe 'Repair-sqmDbOwnerRisk' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase {
            @([pscustomobject]@{ Name = 'Sales'; IsSystemObject = $false }, [pscustomobject]@{ Name = 'Clean'; IsSystemObject = $false })
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*database_role_members*')
            {
                if ("$Database" -eq 'Sales') { [pscustomobject]@{ MemberName = 'dbo' }, [pscustomobject]@{ MemberName = 'app]user' } }
                else { [pscustomobject]@{ MemberName = 'dbo' } }
            }
            elseif ($Query -like '*database_principals WHERE name*') { [pscustomobject]@{ Found = 1 } }
            elseif ($Query -like '*sys.procedures*') { [pscustomobject]@{ SchemaName = 'sch]ema'; ProcName = 'p]roc' } }
        }
    }

    It 'escaped ] in Bezeichnern als ]] und nicht als \]\]' {
        $r = Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -OutputPath $script:TestDir -Confirm:$false
        $all = $global:SqmQueries -join "`n"
        $all | Should -Match ([regex]::Escape('ALTER ROLE db_owner DROP MEMBER [app]]user];'))
        $all | Should -Match ([regex]::Escape('GRANT EXECUTE ON OBJECT::[sch]]ema].[p]]roc] TO [db_execute];'))
        $all | Should -Not -Match '\\\]'
        ($r | Where-Object LoginName -eq 'app]user').Status | Should -Be 'OK'
    }

    It 'escaped auch einen Rollennamen mit ]' {
        Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -ExecuteRoleName 'exec]role' -OutputPath $script:TestDir -Confirm:$false | Out-Null
        ($global:SqmQueries -join "`n") | Should -Match ([regex]::Escape('ALTER ROLE [exec]]role] ADD MEMBER [app]]user];'))
    }

    It 'fasst Datenbanken ohne zusaetzliche db_owner-Mitglieder nicht an' {
        $r = Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -Database 'Clean' -OutputPath $script:TestDir -Confirm:$false
        $r | Should -BeNullOrEmpty
        ($global:SqmQueries | Where-Object { $_ -like '*ALTER ROLE*' }) | Should -BeNullOrEmpty
    }

    It '-WhatIf fuehrt keine aendernde Abfrage aus' {
        Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -OutputPath $script:TestDir -WhatIf | Out-Null
        ($global:SqmQueries | Where-Object { $_ -match 'ALTER ROLE|GRANT |CREATE ROLE' }) | Should -BeNullOrEmpty
    }

    It 'legt die Ausfuehrungsrolle an, wenn sie fehlt' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*database_role_members*') { [pscustomobject]@{ MemberName = 'app_user' } }
        }
        Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -Database 'Sales' -OutputPath $script:TestDir -Confirm:$false | Out-Null
        ($global:SqmQueries | Where-Object { $_ -like 'CREATE ROLE [[]db_execute] AUTHORIZATION [[]dbo];' }) | Should -Not -BeNullOrEmpty
    }

    It 'meldet Failed pro Mitglied, wenn die Zuweisung scheitert' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*database_role_members*') { [pscustomobject]@{ MemberName = 'app_user' } }
            elseif ($Query -like '*database_principals WHERE name*') { [pscustomobject]@{ Found = 1 } }
            elseif ($Query -like 'ALTER ROLE*') { throw 'Berechtigung fehlt' }
        }
        $r = Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -Database 'Sales' -OutputPath $script:TestDir -Confirm:$false
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'Berechtigung fehlt'
    }
}

Describe 'Set-sqmDatabaseOwner' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase {
            @(
                [pscustomobject]@{ Name = 'Sales';    Owner = 'DOM\alice'; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'Already';  Owner = 'sa';        IsSystemObject = $false }
                [pscustomobject]@{ Name = 'We]ird';   Owner = 'DOM\bob';   IsSystemObject = $false }
                [pscustomobject]@{ Name = 'master';   Owner = 'sa';        IsSystemObject = $true }
            )
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*sid = 0x01*') { [pscustomobject]@{ name = 'sa' } }
            elseif ($Query -like '*FROM sys.server_principals WHERE name = N*') { [pscustomobject]@{ name = 'found' } }
        }
    }

    It 'setzt den Owner auf den sa-Account (SID 0x01), wenn kein Login angegeben ist' {
        $r = Set-sqmDatabaseOwner -SqlInstance 'SQL01' -OutputPath $script:TestDir -Confirm:$false
        ($r | Where-Object DatabaseName -eq 'Sales').NewOwner | Should -Be 'sa'
        ($r | Where-Object DatabaseName -eq 'Sales').Status | Should -Be 'OK'
        $global:SqmQueries | Should -Contain 'ALTER AUTHORIZATION ON DATABASE::[Sales] TO [sa]'
    }

    It 'ueberspringt Datenbanken, die schon dem Ziel gehoeren, ausser mit -Force' {
        $r = Set-sqmDatabaseOwner -SqlInstance 'SQL01' -OutputPath $script:TestDir -Confirm:$false
        ($r | Where-Object DatabaseName -eq 'Already').Status | Should -Be 'Skipped'
        $rForce = Set-sqmDatabaseOwner -SqlInstance 'SQL01' -Force -OutputPath $script:TestDir -Confirm:$false
        ($rForce | Where-Object DatabaseName -eq 'Already').Status | Should -Be 'OK'
    }

    It 'laesst Systemdatenbanken aus' {
        (Set-sqmDatabaseOwner -SqlInstance 'SQL01' -OutputPath $script:TestDir -Confirm:$false).DatabaseName |
            Should -Not -Contain 'master'
    }

    It 'escaped ] im Datenbanknamen und im Ziel-Login' {
        Set-sqmDatabaseOwner -SqlInstance 'SQL01' -OwnerLogin 'DOM\a]b' -Database 'We]ird' -OutputPath $script:TestDir -Confirm:$false | Out-Null
        $global:SqmQueries | Should -Contain 'ALTER AUTHORIZATION ON DATABASE::[We]]ird] TO [DOM\a]]b]'
    }

    It '-WhatIf aendert nichts und meldet WhatIf' {
        $r = Set-sqmDatabaseOwner -SqlInstance 'SQL01' -OutputPath $script:TestDir -WhatIf
        ($r | Where-Object DatabaseName -eq 'Sales').Status | Should -Be 'WhatIf'
        ($global:SqmQueries | Where-Object { $_ -like 'ALTER AUTHORIZATION*' }) | Should -BeNullOrEmpty
    }

    It 'bricht ab, wenn der Ziel-Login nicht existiert' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*sid = 0x01*') { [pscustomobject]@{ name = 'sa' } }
        }
        { Set-sqmDatabaseOwner -SqlInstance 'SQL01' -OwnerLogin 'gibt\es\nicht' -OutputPath $script:TestDir -Confirm:$false -EnableException } |
            Should -Throw '*existiert nicht*'
        ($global:SqmQueries | Where-Object { $_ -like 'ALTER AUTHORIZATION*' }) | Should -BeNullOrEmpty
    }

    It 'meldet Failed und macht mit der naechsten Datenbank weiter' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*sid = 0x01*') { [pscustomobject]@{ name = 'sa' } }
            elseif ($Query -like '*FROM sys.server_principals WHERE name = N*') { [pscustomobject]@{ name = 'found' } }
            elseif ($Query -like '*[[]Sales]*') { throw 'Zugriff verweigert' }
        }
        $r = Set-sqmDatabaseOwner -SqlInstance 'SQL01' -OutputPath $script:TestDir -Confirm:$false
        ($r | Where-Object DatabaseName -eq 'Sales').Status   | Should -Be 'Failed'
        ($r | Where-Object DatabaseName -eq 'We]ird').Status  | Should -Be 'OK'
    }
}

Describe 'Remove-sqmMasterDbCustomObjects' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { @('sqm_BackupExclude') } -ParameterFilter { $Key -eq 'MasterDbObjectWhitelist' }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*FROM sys.objects*')
            {
                @(
                    [pscustomobject]@{ SchemaName = 'dbo';    ObjectName = 'sqm_BackupExclude'; ObjectTypeCode = 'U '; ObjectTypeDesc = 'USER_TABLE' }
                    [pscustomobject]@{ SchemaName = 'dbo';    ObjectName = 'my]tbl';            ObjectTypeCode = 'U ';  ObjectTypeDesc = 'USER_TABLE' }
                    [pscustomobject]@{ SchemaName = 'we]ird'; ObjectName = 'proc1';             ObjectTypeCode = 'P ';  ObjectTypeDesc = 'SQL_STORED_PROCEDURE' }
                    [pscustomobject]@{ SchemaName = 'dbo';    ObjectName = 'v1';                ObjectTypeCode = 'V ';  ObjectTypeDesc = 'VIEW' }
                    [pscustomobject]@{ SchemaName = 'dbo';    ObjectName = 'f1';                ObjectTypeCode = 'FN';  ObjectTypeDesc = 'SQL_SCALAR_FUNCTION' }
                )
            }
        }
    }

    It 'baut je Objekttyp das passende DROP und escaped ]' {
        Remove-sqmMasterDbCustomObjects -SqlInstance 'SQL01' -OutputPath $script:TestDir -Confirm:$false | Out-Null
        $global:SqmQueries | Should -Contain 'DROP TABLE [dbo].[my]]tbl];'
        $global:SqmQueries | Should -Contain 'DROP PROCEDURE [we]]ird].[proc1];'
        $global:SqmQueries | Should -Contain 'DROP VIEW [dbo].[v1];'
        $global:SqmQueries | Should -Contain 'DROP FUNCTION [dbo].[f1];'
    }

    It 'loescht Objekte der Whitelist nie' {
        Remove-sqmMasterDbCustomObjects -SqlInstance 'SQL01' -OutputPath $script:TestDir -Confirm:$false | Out-Null
        ($global:SqmQueries | Where-Object { $_ -like '*sqm_BackupExclude*' -and $_ -like 'DROP*' }) | Should -BeNullOrEmpty
    }

    It '-ExcludeObject und -ObjectName begrenzen die Auswahl' {
        Remove-sqmMasterDbCustomObjects -SqlInstance 'SQL01' -ObjectName 'v*', 'f*' -ExcludeObject 'f1' -OutputPath $script:TestDir -Confirm:$false | Out-Null
        $drops = @($global:SqmQueries | Where-Object { $_ -like 'DROP*' })
        $drops | Should -Be @('DROP VIEW [dbo].[v1];')
    }

    It '-WhatIf loescht nichts' {
        Remove-sqmMasterDbCustomObjects -SqlInstance 'SQL01' -OutputPath $script:TestDir -WhatIf | Out-Null
        ($global:SqmQueries | Where-Object { $_ -like 'DROP*' }) | Should -BeNullOrEmpty
    }
}
