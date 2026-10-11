#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Parameteruebergabe von Sync-sqmAgNode an Copy-Dba*.

.DESCRIPTION
    Hintergrund: Alle fuenf Copy-Dba*-Aufrufe wurden mit dem Verbindungs-Splat @primaryConn
    (SqlInstance/SqlCredential) aufgerufen. Copy-Dba* kennt aber nur -Source/-SourceSqlCredential,
    der erste Sync-Typ brach deshalb mit "Es wurde kein Parameter gefunden, der dem Parameternamen
    'SqlInstance' entspricht" ab - die Funktion hat nie etwas synchronisiert. Pester-Mocks behalten
    die echte Parameter-Signatur von dbatools, der Binding-Fehler tritt hier also genauso auf.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Sync-sqmAgNode - Copy-Dba* Parameter' {

    BeforeEach {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Get-DbaAvailabilityGroup { [PSCustomObject]@{ Name = 'AG1'; PrimaryReplica = 'SQLA' } }
            Mock Get-DbaAgReplica {
                [PSCustomObject]@{ Name = 'SQLA'; Role = 'Primary' }
                [PSCustomObject]@{ Name = 'SQLB'; Role = 'Secondary' }
            }
            Mock Get-DbaAgDatabase { }
            Mock Get-DbaLogin { [PSCustomObject]@{ Name = 'AppLogin'; IsSystemObject = $false } }
            Mock Get-DbaAgentJob { [PSCustomObject]@{ Name = 'AppJob' } }
            Mock Get-DbaLinkedServer { [PSCustomObject]@{ Name = 'LS1' } }
            Mock Get-DbaAgentOperator { [PSCustomObject]@{ Name = 'DBA' } }
            Mock Get-DbaAgentAlert { [PSCustomObject]@{ Name = 'Sev17' } }
            Mock Copy-DbaLogin { [PSCustomObject]@{ Name = 'AppLogin'; Status = 'Successful' } }
            Mock Copy-DbaAgentJob { [PSCustomObject]@{ Name = 'AppJob'; Status = 'Successful' } }
            Mock Copy-DbaLinkedServer { [PSCustomObject]@{ Name = 'LS1'; Status = 'Successful' } }
            Mock Copy-DbaAgentOperator { [PSCustomObject]@{ Name = 'DBA'; Status = 'Successful' } }
            Mock Copy-DbaAgentAlert { [PSCustomObject]@{ Name = 'Sev17'; Status = 'Successful' } }
        }
    }

    It 'synchronisiert alle fuenf Typen vom Primary (-Source) auf den Secondary' {
        InModuleScope sqmSQLTool {
            $result = Sync-sqmAgNode -SqlInstance 'SQLB' -EnableException -Confirm:$false

            @($result | Where-Object Status -eq 'Success').Count | Should -Be 5
            foreach ($cmd in 'Copy-DbaLogin', 'Copy-DbaAgentJob', 'Copy-DbaLinkedServer', 'Copy-DbaAgentOperator', 'Copy-DbaAgentAlert')
            {
                Should -Invoke $cmd -Times 1 -Exactly -ParameterFilter { "$Source" -eq 'SQLA' -and "$Destination" -eq 'SQLB' }
            }
        }
    }

    It 'reicht -SqlCredential als Source- und DestinationSqlCredential weiter' {
        InModuleScope sqmSQLTool {
            $cred = [PSCredential]::new('dev', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            Sync-sqmAgNode -SqlInstance 'SQLB' -SqlCredential $cred -ExcludeType Jobs, LinkedServers, Operators, Alerts -EnableException -Confirm:$false | Out-Null

            Should -Invoke Copy-DbaLogin -Times 1 -Exactly -ParameterFilter {
                $SourceSqlCredential.UserName -eq 'dev' -and $DestinationSqlCredential.UserName -eq 'dev'
            }
        }
    }
}
