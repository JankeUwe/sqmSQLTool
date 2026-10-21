#Requires -Modules Pester
<#
.SYNOPSIS
    Fehlerpfade, die frueher in leeren catch-Bloecken verschwanden.

.DESCRIPTION
    Jeder Test loest den Fehler aus, der vorher verschluckt wurde, und prueft die Meldung.
    Invoke-DbaQuery wirft ohne -EnableException bei SQL-Fehlern nicht (es liefert 0 Zeilen, live
    geprueft mit dbatools 2.9.0). Die Mocks werfen deshalb nur mit -EnableException; ein Mock, der
    immer wirft, wuerde einen catch testen, den das echte dbatools nie erreicht.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmCertificateReport - Endpoint-/TDE-Zuordnung nicht ermittelbar' {
    BeforeEach {
        $script:Out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { [pscustomobject]@{ Name = 'SQL01'; VersionMajor = 16 } }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { } -ParameterFilter { $Query -like '*symmetric_keys*' -or $Query -like '*master_key*' }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            [pscustomobject]@{
                CertificateName = 'TDE_Cert'; certificate_id = 256; PrivateKeyEncryption = 'ENCRYPTED_BY_MASTER_KEY'
                IsActiveForDialog = $false; IssuerName = 'TDE_Cert'; Subject = 'TDE_Cert'
                ValidFrom = (Get-Date).AddYears(-1); ExpiryDate = (Get-Date).AddYears(5)
                Thumbprint = [byte[]](1, 2, 3); AttestedBy = $null; HasControl = 1; HasPrivateKey = 1
            }
        } -ParameterFilter { $Query -like '*pvt_key_encryption_type_desc*' }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($EnableException) { throw 'VIEW SERVER STATE verweigert' }
        } -ParameterFilter { $Query -like '*dm_database_encryption_keys*' -or $Query -like '*sys.endpoints*' }
    }

    It 'meldet beide fehlenden Zuordnungen im Ergebnis statt sie zu verschweigen' {
        $r = Get-sqmCertificateReport -SqlInstance 'SQL01' -OutputPath $script:Out -NoOpen -Confirm:$false
        @($r.PurposeWarnings).Count | Should -Be 2
        ($r.PurposeWarnings -join ' ') | Should -Match 'TDE-Zuordnung nicht ermittelbar.*VIEW SERVER STATE'
        ($r.PurposeWarnings -join ' ') | Should -Match 'Endpoint-Zuordnung nicht ermittelbar'
    }

    It 'schreibt den Hinweis in Text- und HTML-Bericht' {
        Get-sqmCertificateReport -SqlInstance 'SQL01' -OutputPath $script:Out -NoOpen -Confirm:$false | Out-Null
        $txt = Get-ChildItem $script:Out -Filter '*.txt' -Recurse | Select-Object -First 1
        $html = Get-ChildItem $script:Out -Filter '*.html' -Recurse | Select-Object -First 1
        Get-Content $txt.FullName -Raw | Should -Match 'HINWEIS: TDE-Zuordnung nicht ermittelbar'
        Get-Content $html.FullName -Raw | Should -Match 'HINWEIS: TDE-Zuordnung nicht ermittelbar'
    }

    It 'ohne Fehler keine Hinweise' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { } -ParameterFilter { $Query -like '*dm_database_encryption_keys*' -or $Query -like '*sys.endpoints*' }
        $r = Get-sqmCertificateReport -SqlInstance 'SQL01' -OutputPath $script:Out -NoOpen -Confirm:$false
        @($r.PurposeWarnings).Count | Should -Be 0
    }
}

Describe 'Enable-sqmServiceBroker - Rollback auf MULTI_USER scheitert' {
    BeforeEach {
        $script:Out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        $global:SqmBrokerQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Connect-DbaInstance {
            $srv = [pscustomobject]@{ Name = 'SQL01' }
            $srv | Add-Member -MemberType ScriptMethod -Name Query -Value {
                $global:SqmBrokerQueries.Add($args[0])
                if ($args[0] -like '*ENABLE_BROKER*') { throw 'Broker-Fehler' }
                if ($args[0] -like '*SET MULTI_USER*') { throw 'Sperre' }
            }
            $srv
        }
    }

    AfterEach { Remove-Variable -Name SqmBrokerQueries -Scope Global -ErrorAction SilentlyContinue }

    It 'nennt SINGLE_USER und den manuellen Befehl in der Fehlermeldung' {
        { Enable-sqmServiceBroker -SqlInstance 'SQL01' -DatabaseName 'App' -OutputPath $script:Out -Force -EnableException -Confirm:$false } |
            Should -Throw -ExpectedMessage '*Broker-Fehler*steht noch in SINGLE_USER*ALTER DATABASE `[App`] SET MULTI_USER*'
    }

    It 'wirft weiter den Broker-Fehler, wenn das Rollback klappt' {
        Mock -ModuleName sqmSQLTool Connect-DbaInstance {
            $srv = [pscustomobject]@{ Name = 'SQL01' }
            $srv | Add-Member -MemberType ScriptMethod -Name Query -Value { if ($args[0] -like '*ENABLE_BROKER*') { throw 'Broker-Fehler' } }
            $srv
        }
        { Enable-sqmServiceBroker -SqlInstance 'SQL01' -DatabaseName 'App' -OutputPath $script:Out -Force -EnableException -Confirm:$false } |
            Should -Throw -ExpectedMessage '*Broker-Fehler*'
        try { Enable-sqmServiceBroker -SqlInstance 'SQL01' -DatabaseName 'App' -OutputPath $script:Out -Force -EnableException -Confirm:$false }
        catch { "$_" | Should -Not -Match 'SINGLE_USER' }
    }
}

Describe 'Invoke-sqmSetupReport - sysadmin-Mitglieder nicht ermittelbar' {
    BeforeEach {
        $script:Out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        Mock -ModuleName sqmSQLTool Get-WmiObject { [pscustomobject]@{ TotalPhysicalMemory = 8GB } }
        # Ein String bindet an DbaInstanceParameter; Server-Eigenschaften sind dann leer, das reicht hier
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { 'SQL01' }
        # Splunk- und Monitoring-Abschnitte greifen per WinRM auf den Host zu; im Test abgeschaltet
        foreach ($cmd in 'Get-DbaLogin', 'Get-DbaAgentJob', 'Get-DbaDatabase', 'Get-DbaService',
            'Get-sqmDatabaseTrustIsolationMap', 'Get-sqmSpnReport', 'Invoke-sqmSplunkConfiguration', 'Invoke-sqmMonitoringKey')
        {
            Mock -ModuleName sqmSQLTool $cmd { }
        }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($EnableException) { throw 'kein VIEW SERVER STATE' }
        } -ParameterFilter { $Query -like "*r.name = N'sysadmin'*" }
        Mock -ModuleName sqmSQLTool Get-DbaServerRoleMember { if ($EnableException) { throw 'kein Zugriff' } }
    }

    It 'zeigt im Bericht "nicht ermittelbar" und eine Fehlermeldung statt "None"' {
        $file = Invoke-sqmSetupReport -SqlInstance 'SQL01' -OutputPath $script:Out -NoOpen
        $html = Get-Content (Get-ChildItem $script:Out -Filter '*.html' -Recurse | Select-Object -First 1).FullName -Raw
        $html | Should -Match '\(nicht ermittelbar\)'
        $html | Should -Match 'FEHLER: sysadmin-Mitglieder nicht ermittelbar, BUILTIN-Pruefung nicht durchgefuehrt \(kein Zugriff\)'
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmLogging -ParameterFilter { $Level -eq 'WARNING' -and $Message -like '*sysadmin-Mitglieder nicht ermittelbar*' }
    }
}
