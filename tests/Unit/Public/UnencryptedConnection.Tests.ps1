#Requires -Modules Pester
<#
.SYNOPSIS
    Tests fuer Get-sqmUnencryptedConnection (Klassifizierung, Zusammenfassung, Rechtepruefung).
.DESCRIPTION
    Invoke-DbaQuery wird gemockt. Die beiden T-SQL-Abfragen sind gegen SQL Server 2025 (Docker)
    manuell geprueft.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\TestHelpers.ps1"
    Import-sqmTestModule

    function script:New-Row { param ([hashtable]$p) [PSCustomObject]$p }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Get-sqmUnencryptedConnection' {
    BeforeAll {
        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uc_{0}" -f [guid]::NewGuid().ToString('N'))
    }
    AfterAll {
        Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'hat die erwarteten Parameter' {
        $c = Get-Command Get-sqmUnencryptedConnection
        foreach ($p in 'SqlInstance', 'SqlCredential', 'IncludeLocal', 'InstanceSummary', 'OutputPath', 'NoOpen') {
            $c.Parameters.Keys | Should -Contain $p
        }
    }

    Context 'ForceEncryption = 0 mit Remote- und lokalen Verbindungen' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'ForceEncryption') {
                    [PSCustomObject]@{ ServerName = 'SQL01'; ProductVersion = '16.0'; ForceEncryption = '0'; ForceStrictEncryption = [DBNull]::Value; RegistryRows = 1; HasViewServerState = 1 }
                }
                else {
                    $now = Get-Date
                    # zwei gleiche Remote-Verbindungen (werden zusammengefasst), eine Remote mit anderem Login, eine Loopback, eine Shared Memory
                    [PSCustomObject]@{ SessionId = 60; NetTransport = 'TCP'; AuthScheme = 'SQL'; ClientAddress = '10.0.0.5'; LocalAddress = '10.0.0.1'; LoginName = 'app'; HostName = 'WEB1'; ProgramName = 'Web'; LoginTime = $now.AddHours(-2) }
                    [PSCustomObject]@{ SessionId = 61; NetTransport = 'TCP'; AuthScheme = 'SQL'; ClientAddress = '10.0.0.5'; LocalAddress = '10.0.0.1'; LoginName = 'app'; HostName = 'WEB1'; ProgramName = 'Web'; LoginTime = $now.AddHours(-1) }
                    [PSCustomObject]@{ SessionId = 62; NetTransport = 'TCP'; AuthScheme = 'NTLM'; ClientAddress = '10.0.0.9'; LocalAddress = '10.0.0.1'; LoginName = 'DOM\bob'; HostName = 'PC1'; ProgramName = 'SSMS'; LoginTime = $now }
                    [PSCustomObject]@{ SessionId = 63; NetTransport = 'TCP'; AuthScheme = 'NTLM'; ClientAddress = '127.0.0.1'; LocalAddress = '127.0.0.1'; LoginName = 'DOM\svc'; HostName = 'SQL01'; ProgramName = 'Agent'; LoginTime = $now }
                    [PSCustomObject]@{ SessionId = 64; NetTransport = 'Shared memory'; AuthScheme = 'NTLM'; ClientAddress = '<local machine>'; LocalAddress = ''; LoginName = 'DOM\svc'; HostName = 'SQL01'; ProgramName = 'x'; LoginTime = $now }
                }
            }
        }

        It 'fasst gleiche Verbindungen zusammen und blendet lokale standardmaessig aus' {
            $r = @(Get-sqmUnencryptedConnection -SqlInstance SQL01 -OutputPath $script:Tmp -NoOpen -Confirm:$false)
            $r.Count | Should -Be 2
            ($r | Where-Object LoginName -eq 'app').ConnectionCount | Should -Be 2
            ($r | Where-Object LoginName -eq 'app').SessionIds | Should -Be '60,61'
            $r.RiskLevel | Should -Not -Contain 'Info'
            $r.Scope | Should -Not -Contain 'Lokal'
        }

        It 'zeigt mit -IncludeLocal Loopback, aber nie Shared Memory' {
            $r = @(Get-sqmUnencryptedConnection -SqlInstance SQL01 -IncludeLocal -OutputPath $script:Tmp -NoOpen -Confirm:$false)
            $r.Count | Should -Be 3
            ($r | Where-Object LoginName -eq 'DOM\svc').Scope | Should -Be 'Lokal'
            ($r | Where-Object LoginName -eq 'DOM\svc').RiskLevel | Should -Be 'Info'
            $r.NetTransport | Should -Not -Contain 'Shared memory'
        }

        It 'meldet die Instanz als annehmend mit Warning' {
            $i = Get-sqmUnencryptedConnection -SqlInstance SQL01 -InstanceSummary -OutputPath $script:Tmp -NoOpen -Confirm:$false
            $i.ForceEncryption | Should -BeFalse
            $i.AcceptsUnencrypted | Should -BeTrue
            $i.UnencryptedRemote | Should -Be 3
            $i.RiskLevel | Should -Be 'Warning'
            $i.PermissionOk | Should -BeTrue
        }

        It 'schreibt HTML, TXT und CSV' {
            Get-sqmUnencryptedConnection -SqlInstance SQL01 -OutputPath $script:Tmp -NoOpen -Confirm:$false | Out-Null
            (Get-ChildItem $script:Tmp -Filter 'UnencryptedConnections_*.html').Count | Should -BeGreaterThan 0
            (Get-ChildItem $script:Tmp -Filter 'UnencryptedConnections_*.txt').Count | Should -BeGreaterThan 0
            (Get-ChildItem $script:Tmp -Filter 'UnencryptedConnections_*.csv').Count | Should -BeGreaterThan 0
        }
    }

    Context 'ForceEncryption = 1' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'ForceEncryption') {
                    [PSCustomObject]@{ ServerName = 'SQL02'; ProductVersion = '16.0'; ForceEncryption = '1'; ForceStrictEncryption = [DBNull]::Value; RegistryRows = 1; HasViewServerState = 1 }
                }
            }
        }
        It 'meldet OK und nimmt nicht an' {
            $i = Get-sqmUnencryptedConnection -SqlInstance SQL02 -InstanceSummary -OutputPath $script:Tmp -NoOpen -Confirm:$false
            $i.AcceptsUnencrypted | Should -BeFalse
            $i.RiskLevel | Should -Be 'OK'
        }
    }

    Context 'ForceEncryption unbekannt (Linux)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'ForceEncryption') {
                    [PSCustomObject]@{ ServerName = 'LNX'; ProductVersion = '17.0'; ForceEncryption = [DBNull]::Value; ForceStrictEncryption = [DBNull]::Value; RegistryRows = 0; HasViewServerState = 1 }
                }
                else {
                    [PSCustomObject]@{ SessionId = 70; NetTransport = 'TCP'; AuthScheme = 'SQL'; ClientAddress = '172.17.0.1'; LocalAddress = '172.17.0.2'; LoginName = 'sa'; HostName = 'H'; ProgramName = 'P'; LoginTime = Get-Date }
                }
            }
        }
        It 'schliesst aus einer beobachteten Remote-Verbindung, dass die Instanz annimmt' {
            $i = Get-sqmUnencryptedConnection -SqlInstance LNX -InstanceSummary -OutputPath $script:Tmp -NoOpen -Confirm:$false
            $i.ForceEncryption | Should -BeNullOrEmpty
            $i.AcceptsUnencrypted | Should -BeTrue
        }
    }

    Context 'fehlendes VIEW SERVER STATE' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'ForceEncryption') {
                    [PSCustomObject]@{ ServerName = 'SQL03'; ProductVersion = '16.0'; ForceEncryption = '1'; ForceStrictEncryption = [DBNull]::Value; RegistryRows = 1; HasViewServerState = 0 }
                }
            }
        }
        It 'kennzeichnet das Ergebnis als nicht belastbar' {
            $i = Get-sqmUnencryptedConnection -SqlInstance SQL03 -InstanceSummary -OutputPath $script:Tmp -NoOpen -Confirm:$false -WarningAction SilentlyContinue
            $i.PermissionOk | Should -BeFalse
            $i.Hint | Should -Match 'VIEW SERVER STATE'
        }
    }
}
