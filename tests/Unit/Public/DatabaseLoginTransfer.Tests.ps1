#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Export-sqmDatabaseLogins, Import-sqmDatabaseLogins und Sync-sqmDatabaseLogins.
.DESCRIPTION
    Der Export schreibt eine SQL-Datei mit Passwort-Hashes und SIDs, der Import fuehrt sie blockweise aus.
    Geprueft werden: sysadmin/sa/System-Logins landen nie in der Datei, Namen werden escaped, Hashes und
    Policy-Flags uebernommen, Dateiauswahl im Verzeichnis (neueste, KeepLatest), Statuswerte aus den
    PRINT-Meldungen der Bloecke, Policy wird immer wieder aktiviert, und ein Rundlauf Export -> Import.
    Dateien liegen in einem Testverzeichnis, dbatools ist gemockt.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
    $script:TestDir = New-TempTestDirectory

    function script:New-ExportSetup
    {
        param([string[]]$DbUsers = @('app_user', 'report]user', "o'brien", 'sa', 'svc_admin', 'NT SERVICE\x'),
              [string[]]$SysAdmins = @('sa', 'svc_admin'))
        $global:SqmExport = @{ Users = $DbUsers; SysAdmins = $SysAdmins; MetaQuery = $null; FailSysadminQuery = $false }
    }
}

AfterAll {
    Remove-Variable -Name SqmExport, SqmCalls, SqmQueries -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Export-sqmDatabaseLogins' {
    BeforeEach {
        New-ExportSetup
        $script:Out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $q = $Query
            if ($q -like '*FROM sys.database_principals*') { $global:SqmExport.Users | ForEach-Object { [pscustomobject]@{ UserName = $_ } } }
            elseif ($q -like '*SUSER_SNAME(0x01)*') { [pscustomobject]@{ n = 'sa' } }
            elseif ($q -like '*is_srvrolemember*')
            {
                if ($global:SqmExport.FailSysadminQuery) { throw 'kein Zugriff' }
                $global:SqmExport.SysAdmins | ForEach-Object { [pscustomobject]@{ name = $_ } }
            }
            elseif ($q -like '*sys.sql_logins*')
            {
                $global:SqmExport.MetaQuery = $q
                $names = [regex]::Matches($q, "N'((?:[^']|'')*)'") | ForEach-Object { $_.Groups[1].Value -replace "''", "'" }
                $names | ForEach-Object {
                    [pscustomobject]@{
                        LoginName = $_; SidHex = 'AABBCC' + ('{0:X2}' -f $names.IndexOf($_)); PasswordHashHex = '0200DEADBEEF'
                        IsPolicyChecked = ($_ -ne 'app_user'); IsExpirationChecked = $false
                        DefaultDatabaseName = if ($_ -eq 'app_user') { 'Sales' } else { 'OtherDb' }
                    }
                }
            }
        }
    }

    It 'exportiert nur Nicht-sysadmin-Logins und zaehlt die ausgeschlossenen' {
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false
        $r.Status | Should -Be 'Success'
        $r.LoginCount | Should -Be 3
        $r.ExcludedSysadminCount | Should -Be 3
        $sql = Get-Content $r.OutputFile -Raw
        $sql | Should -Match '===LOGIN:app_user==='
        $sql | Should -Not -Match '===LOGIN:sa==='
        $sql | Should -Not -Match '===LOGIN:svc_admin==='
        $sql | Should -Not -Match 'NT SERVICE'
        $global:SqmExport.MetaQuery | Should -Not -Match "N'sa'"
    }

    It 'uebernimmt Hash (HASHED), SID, Policy-Flags und mappt fremde Default-Datenbanken auf master' {
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false
        $sql = Get-Content $r.OutputFile -Raw
        $sql | Should -Match 'PASSWORD = 0x0200DEADBEEF HASHED'
        $sql | Should -Match 'SID = 0xAABBCC00'
        $sql | Should -Match 'CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = \[Sales\]'
        $sql | Should -Match 'CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = \[master\]'
        $sql | Should -Not -Match 'OtherDb'
    }

    It 'jeder Block schuetzt sysadmin/sa und ist idempotent' {
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false
        $sql = Get-Content $r.OutputFile -Raw
        ([regex]::Matches($sql, "IS_SRVROLEMEMBER\('sysadmin'")).Count | Should -Be 3
        ([regex]::Matches($sql, 'SICHERHEIT')).Count | Should -Be 3
        $sql | Should -Match 'IF EXISTS \(SELECT 1 FROM sys\.server_principals WHERE sid = 0x'
    }

    It 'escaped ] und Hochkommas in Login-Namen' {
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false
        $sql = Get-Content $r.OutputFile -Raw
        $sql | Should -Match ([regex]::Escape('ALTER LOGIN [report]]user] WITH PASSWORD'))
        $sql | Should -Match ([regex]::Escape("N'o''brien'"))
        $global:SqmExport.MetaQuery | Should -Match ([regex]::Escape("N'o''brien'"))
    }

    It '-Login und -ExcludeLogin filtern per Wildcard' {
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Login 'app*', 'o*' -ExcludeLogin 'o*' -Confirm:$false
        $r.LoginCount | Should -Be 1
        (Get-Content $r.OutputFile -Raw) | Should -Match '===LOGIN:app_user==='
    }

    It 'meldet Skipped und schreibt nichts, wenn keine SQL-User oder nach dem Filter nichts uebrig ist' {
        New-ExportSetup -DbUsers @()
        (Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false -WarningAction SilentlyContinue).Status | Should -Be 'Skipped'
        New-ExportSetup
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Login 'gibtsnicht' -Confirm:$false -WarningAction SilentlyContinue
        $r.Status | Should -Be 'Skipped'
        Test-Path "$script:Out\x.sql" | Should -BeFalse
    }

    It 'faellt bei nicht ermittelbarer sysadmin-Liste auf "sa" allein zurueck (und exportiert die anderen)' {
        $global:SqmExport.FailSysadminQuery = $true
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false
        $r.Status | Should -Be 'Success'
        (Get-Content $r.OutputFile -Raw) | Should -Not -Match '===LOGIN:sa==='
    }

    It 'bei einem Verzeichnis als -OutputPath entsteht ein Dateiname mit Datenbank, Instanz und Zeitstempel' {
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01\INST1' -Database 'Sales' -OutputPath $script:Out -Confirm:$false
        (Split-Path $r.OutputFile -Leaf) | Should -Match '^DatabaseLogins_Sales_SQL01_INST1_\d{14}\.sql$'
    }

    It '-KeepLatest loescht aeltere Exporte derselben Datenbank, aber keine fremden Dateien' {
        New-Item -ItemType Directory -Path $script:Out -Force | Out-Null
        foreach ($stamp in '20200101000000', '20200102000000', '20200103000000')
        {
            Set-Content -Path (Join-Path $script:Out "DatabaseLogins_Sales_SQL01_$stamp.sql") -Value "-- Datenbank     : Sales`n-- Quelle        : SQL01"
        }
        Set-Content -Path (Join-Path $script:Out 'DatabaseLogins_Other_SQL01_20200101000000.sql') -Value "-- Datenbank     : Other"
        Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath $script:Out -KeepLatest 2 -Confirm:$false | Out-Null
        $left = (Get-ChildItem $script:Out -Filter 'DatabaseLogins_Sales_*.sql').Name
        $left.Count | Should -Be 2
        $left | Should -Not -Contain 'DatabaseLogins_Sales_SQL01_20200101000000.sql'
        Test-Path (Join-Path $script:Out 'DatabaseLogins_Other_SQL01_20200101000000.sql') | Should -BeTrue
    }

    It '-WhatIf schreibt keine Datei' {
        $r = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -WhatIf
        $r.Status | Should -Be 'WhatIf'
        Test-Path "$script:Out\x.sql" | Should -BeFalse
    }

    It 'meldet Failed bzw. wirft mit -EnableException bei Verbindungsfehler' {
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { throw 'Login failed' }
        (Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false -ErrorAction SilentlyContinue).Status | Should -Be 'Failed'
        { Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath "$script:Out\x.sql" -Confirm:$false -EnableException } | Should -Throw '*Login failed*'
    }
}

Describe 'Import-sqmDatabaseLogins' {
    BeforeEach {
        $global:SqmCalls = [System.Collections.Generic.List[string]]::new()
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        $script:Dir = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { 'PolicyX' } -ParameterFilter { $Key -eq 'DefaultPolicy' }
        Mock -ModuleName sqmSQLTool Set-sqmSqlPolicyState { $global:SqmCalls.Add("Policy:${State}"); [pscustomobject]@{ Status = 'Success' } }
        Mock -ModuleName sqmSQLTool Repair-DbaDbOrphanUser { $global:SqmCalls.Add('Repair'); @(1, 2) }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*===LOGIN:sa_clash===*') { 'SICHERHEIT: sa_clash ist sysadmin/sa auf diesem Server - NICHT angefasst.' }
            elseif ($Query -like '*===LOGIN:sid_clash===*') { 'UEBERSPRUNGEN: SID gehoert bereits zu einem anders benannten Login' }
            elseif ($Query -like '*===LOGIN:broken===*') { throw 'Syntaxfehler' }
        }
        $script:File = Join-Path $script:Dir 'DatabaseLogins_Sales_SQL01_20260101000000.sql'
        @"
-- Quelle        : SQL01
-- Datenbank     : Sales
-- Zeitstempel   : 2026-01-01 00:00:00
-- ===LOGIN:app_user===
CREATE LOGIN [app_user] WITH PASSWORD = 0x01 HASHED;

-- ===LOGIN:sa_clash===
PRINT N'SICHERHEIT';

-- ===LOGIN:sid_clash===
PRINT N'UEBERSPRUNGEN';
"@ | Set-Content -Path $script:File -Encoding UTF8
    }

    It 'fuehrt jeden Login-Block einzeln aus und uebersetzt PRINT-Meldungen in Status' {
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Sales' -Confirm:$false
        $apply = $r | Where-Object Action -eq 'ApplyLogin'
        $apply.Count | Should -Be 3
        ($apply | Where-Object LoginName -eq 'app_user').Status | Should -Be 'Success'
        ($apply | Where-Object LoginName -eq 'sa_clash').Status | Should -Be 'SkippedSysadmin'
        ($apply | Where-Object LoginName -eq 'sid_clash').Status | Should -Be 'SkippedSidCollision'
        ($global:SqmQueries | Where-Object { $_ -like '*===LOGIN:app_user===*' }).Count | Should -Be 1
        ($global:SqmQueries | Where-Object { $_ -like '*===LOGIN:app_user===*' }) | Should -Not -Match 'sa_clash'
    }

    It 'deaktiviert die Policy davor, aktiviert sie danach wieder und repariert verwaiste User' {
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Sales' -Confirm:$false
        $global:SqmCalls | Should -Be @('Policy:Disable', 'Policy:Enable', 'Repair')
        ($r | Where-Object Action -eq 'RepairOrphanUsers').Message | Should -Match '2 Eintraege'
    }

    It 'aktiviert die Policy auch dann wieder, wenn ein Block scheitert und -EnableException wirft' {
        Add-Content -Path $script:File -Value "`n-- ===LOGIN:broken===`nSELECT 1;"
        { Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Sales' -Confirm:$false -EnableException } | Should -Throw '*Syntaxfehler*'
        $global:SqmCalls | Should -Contain 'Policy:Enable'
    }

    It 'ein fehlgeschlagener Block bricht mit -ContinueOnError die anderen nicht ab' {
        Add-Content -Path $script:File -Value "`n-- ===LOGIN:broken===`nSELECT 1;"
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Sales' -Confirm:$false -ContinueOnError
        ($r | Where-Object LoginName -eq 'broken').Status | Should -Be 'Failed'
        ($r | Where-Object { $_.Action -eq 'ApplyLogin' -and $_.Status -eq 'Success' }).Count | Should -Be 1
    }

    It 'ueberspringt das Policy-Handling ohne konfigurierte DefaultPolicy' {
        Mock -ModuleName sqmSQLTool Get-sqmConfig { $null } -ParameterFilter { $Key -eq 'DefaultPolicy' }
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Sales' -Confirm:$false
        ($r | Where-Object Action -eq 'PolicyDisable').Status | Should -Be 'Skipped'
        $global:SqmCalls | Should -Not -Contain 'Policy:Enable'
    }

    It '-DisablePolicy $false laesst die Policy in Ruhe' {
        Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Sales' -DisablePolicy $false -Confirm:$false | Out-Null
        $global:SqmCalls | Where-Object { $_ -like 'Policy:*' } | Should -BeNullOrEmpty
    }

    It 'warnt, wenn die Datei fuer eine andere Datenbank exportiert wurde, wendet sie aber an' {
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Other' -Confirm:$false -WarningAction SilentlyContinue
        ($r | Where-Object Action -eq 'HeaderCheck').Status | Should -Be 'Warning'
        ($r | Where-Object Action -eq 'ApplyLogin').Count | Should -Be 3
    }

    It 'meldet Skipped, wenn die Datei keine Login-Bloecke enthaelt' {
        $empty = Join-Path $script:Dir 'leer.sql'
        Set-Content -Path $empty -Value '-- Datenbank     : Sales'
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $empty -Database 'Sales' -Confirm:$false -WarningAction SilentlyContinue
        ($r | Where-Object Action -eq 'ParseFile').Status | Should -Be 'Skipped'
        $global:SqmQueries | Should -BeNullOrEmpty
    }

    It '-WhatIf fuehrt nichts aus' {
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:File -Database 'Sales' -WhatIf
        ($r | Where-Object Action -eq 'ApplyLogin').Status | Should -Be @('WhatIf', 'WhatIf', 'WhatIf')
        $global:SqmQueries | Should -BeNullOrEmpty
        $global:SqmCalls | Should -BeNullOrEmpty
    }

    It 'nimmt bei einem Verzeichnis die neueste Datei der Datenbank nach Zeitstempel im Namen' {
        $old = Join-Path $script:Dir 'DatabaseLogins_Sales_SQL01_20250101000000.sql'
        Set-Content -Path $old -Value "-- Quelle        : SQL01`n-- Datenbank     : Sales`n-- ===LOGIN:alt===`nSELECT 1;"
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(1)  # LastWriteTime darf nicht entscheiden
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:Dir -Database 'Sales' -Confirm:$false
        ($r | Where-Object Action -eq 'SelectFile').Message | Should -Match '20260101000000'
        ($r | Where-Object Action -eq 'ApplyLogin').LoginName | Should -Not -Contain 'alt'
    }

    It 'Verzeichnis ohne passende Datei ergibt Failed' {
        $emptyDir = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $emptyDir | Out-Null
        $r = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $emptyDir -Database 'Sales' -Confirm:$false -ErrorAction SilentlyContinue
        ($r | Where-Object Action -eq 'SelectFile').Status | Should -Be 'Failed'
    }

    It '-KeepLatest im Verzeichnis loescht aeltere Exporte erst nach dem Import' {
        $old = Join-Path $script:Dir 'DatabaseLogins_Sales_SQL01_20250101000000.sql'
        Set-Content -Path $old -Value "-- Quelle        : SQL01`n-- Datenbank     : Sales`n-- ===LOGIN:alt===`nSELECT 1;"
        Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $script:Dir -Database 'Sales' -KeepLatest 1 -Confirm:$false | Out-Null
        Test-Path $old | Should -BeFalse
        Test-Path $script:File | Should -BeTrue
    }

    It 'verlangt einen vorhandenen -InputPath' {
        { Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath (Join-Path $script:Dir 'gibtsnicht.sql') -Database 'Sales' -Confirm:$false } | Should -Throw
    }
}

Describe 'Sync-sqmDatabaseLogins' {
    BeforeEach {
        $global:SqmCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Export-sqmDatabaseLogins {
            Set-Content -Path $OutputPath -Value 'x'
            $global:SqmCalls.Add("Export:${SqlInstance}:$([bool]$SqlCredential):$($SqlCredential.UserName):${OutputPath}")
            [pscustomobject]@{ Status = 'Success'; LoginCount = 2 }
        }
        Mock -ModuleName sqmSQLTool Import-sqmDatabaseLogins {
            $global:SqmCalls.Add("Import:${SqlInstance}:$($SqlCredential.UserName):${InputPath}")
            [pscustomobject]@{ Action = 'ApplyLogin'; Status = 'Success' }
        }
    }

    It 'exportiert von der Quelle und importiert mit derselben Datei auf das Ziel' {
        $r = @(Sync-sqmDatabaseLogins -Source 'SQL01' -Destination 'SQL02' -Database 'Sales' -Confirm:$false)
        $r.Count | Should -Be 2
        $exp = ($global:SqmCalls | Where-Object { $_ -like 'Export:*' }) -replace '^Export:SQL01:False::', ''
        $imp = ($global:SqmCalls | Where-Object { $_ -like 'Import:*' }) -replace '^Import:SQL02::', ''
        $imp | Should -Be $exp
        $exp | Should -Match 'sqmDatabaseLogins_Sales_\d{14}\.sql$'
    }

    It 'leitet SourceCredential und DestinationCredential getrennt weiter, -SqlCredential gilt fuer beide' {
        $src = [pscredential]::new('srcuser', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        $dst = [pscredential]::new('dstuser', (ConvertTo-SecureString 'y' -AsPlainText -Force))
        Sync-sqmDatabaseLogins -Source 'SQL01' -Destination 'SQL02' -Database 'Sales' -SourceCredential $src -DestinationCredential $dst -Confirm:$false | Out-Null
        ($global:SqmCalls -join "`n") | Should -Match 'Export:SQL01:True:srcuser:'
        ($global:SqmCalls -join "`n") | Should -Match 'Import:SQL02:dstuser:'
        $global:SqmCalls.Clear()
        Sync-sqmDatabaseLogins -Source 'SQL01' -Destination 'SQL02' -Database 'Sales' -SqlCredential $src -Confirm:$false | Out-Null
        ($global:SqmCalls -join "`n") | Should -Match 'Export:SQL01:True:srcuser:'
        ($global:SqmCalls -join "`n") | Should -Match 'Import:SQL02:srcuser:'
    }

    It 'importiert nicht, wenn der Export nicht erfolgreich war' {
        Mock -ModuleName sqmSQLTool Export-sqmDatabaseLogins { [pscustomobject]@{ Status = 'Skipped'; LoginCount = 0 } }
        $r = @(Sync-sqmDatabaseLogins -Source 'SQL01' -Destination 'SQL02' -Database 'Sales' -Confirm:$false)
        $r.Count | Should -Be 1
        $global:SqmCalls | Where-Object { $_ -like 'Import:*' } | Should -BeNullOrEmpty
    }

    It '-WhatIf exportiert, importiert aber nicht' {
        Sync-sqmDatabaseLogins -Source 'SQL01' -Destination 'SQL02' -Database 'Sales' -WhatIf | Out-Null
        ($global:SqmCalls | Where-Object { $_ -like 'Export:*' }).Count | Should -Be 1
        $global:SqmCalls | Where-Object { $_ -like 'Import:*' } | Should -BeNullOrEmpty
    }

    It 'loescht die temporaere Datei, auch wenn der Import scheitert' {
        Mock -ModuleName sqmSQLTool Export-sqmDatabaseLogins {
            Set-Content -Path $OutputPath -Value 'x'
            $global:SqmCalls.Add("File:${OutputPath}")
            [pscustomobject]@{ Status = 'Success'; LoginCount = 1 }
        }
        Mock -ModuleName sqmSQLTool Import-sqmDatabaseLogins { throw 'Ziel nicht erreichbar' }
        Sync-sqmDatabaseLogins -Source 'SQL01' -Destination 'SQL02' -Database 'Sales' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $file = ($global:SqmCalls | Where-Object { $_ -like 'File:*' }) -replace '^File:', ''
        $file | Should -Not -BeNullOrEmpty
        Test-Path $file | Should -BeFalse
    }
}

Describe 'Export -> Import Rundlauf' {
    It 'jeder exportierte Login-Block wird vom Import als eigener Block ausgefuehrt' {
        New-ExportSetup
        $dir = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { $null }
        Mock -ModuleName sqmSQLTool Repair-DbaDbOrphanUser { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -like '*===LOGIN:*') { $global:SqmQueries.Add($Query) }
            elseif ($Query -like '*FROM sys.database_principals*') { 'app_user', 'report]user' | ForEach-Object { [pscustomobject]@{ UserName = $_ } } }
            elseif ($Query -like '*SUSER_SNAME(0x01)*') { [pscustomobject]@{ n = 'sa' } }
            elseif ($Query -like '*is_srvrolemember*') { [pscustomobject]@{ name = 'sa' } }
            elseif ($Query -like '*sys.sql_logins*')
            {
                'app_user', 'report]user' | ForEach-Object {
                    [pscustomobject]@{ LoginName = $_; SidHex = '0102'; PasswordHashHex = 'ABCD'; IsPolicyChecked = $true; IsExpirationChecked = $true; DefaultDatabaseName = 'master' }
                }
            }
        }
        $e = Export-sqmDatabaseLogins -SqlInstance 'SQL01' -Database 'Sales' -OutputPath $dir -Confirm:$false
        $i = Import-sqmDatabaseLogins -SqlInstance 'SQL02' -InputPath $dir -Database 'Sales' -Confirm:$false
        ($i | Where-Object Action -eq 'ApplyLogin').LoginName | Should -Be @('app_user', 'report]user')
        $global:SqmQueries.Count | Should -Be $e.LoginCount
    }
}
