#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer New-sqmAvailabilityGroup und Invoke-sqmAlwaysOnSetup.
    dbatools- und Cluster-Abhaengigkeiten werden vollstaendig gemockt.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'New-sqmAvailabilityGroup' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command New-sqmAvailabilityGroup | Should -Not -BeNullOrEmpty
        }

        It 'AvailabilityGroupName ist mandatory' {
            $cmd = Get-Command New-sqmAvailabilityGroup
            $mandatory = $cmd.Parameters['AvailabilityGroupName'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $true
        }

        It 'SqlInstance ist nicht mandatory (Default = Computername)' {
            $cmd = Get-Command New-sqmAvailabilityGroup
            $mandatory = $cmd.Parameters['SqlInstance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $false
        }

        It 'Unterstuetzt ShouldProcess (WhatIf/Confirm)' {
            $cmd = Get-Command New-sqmAvailabilityGroup
            $cmd.Parameters.ContainsKey('WhatIf')  | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
        }

        It 'FailoverMode akzeptiert nur Automatic/Manual' {
            $vs = (Get-Command New-sqmAvailabilityGroup).Parameters['FailoverMode'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                Select-Object -ExpandProperty ValidValues
            $vs | Should -Contain 'Automatic'
            $vs | Should -Contain 'Manual'
        }

        It 'BackupPreference akzeptiert die vier WSFC-Werte' {
            $vs = (Get-Command New-sqmAvailabilityGroup).Parameters['BackupPreference'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                Select-Object -ExpandProperty ValidValues
            'Primary','Secondary','PreferSecondary','None' | ForEach-Object { $vs | Should -Contain $_ }
        }

        It 'Listener-Parameter existieren' {
            $cmd = Get-Command New-sqmAvailabilityGroup
            $cmd.Parameters.ContainsKey('ListenerName')      | Should -Be $true
            $cmd.Parameters.ContainsKey('ListenerIPAddress') | Should -Be $true
            $cmd.Parameters.ContainsKey('ListenerPort')      | Should -Be $true
        }
    }

    Context 'Ausfuehrung mit -WhatIf (gemockt, keine Writes)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance -Name 'SQL01' }
            # Alle Reads liefern leer -> Funktion wuerde Erstellen wollen, unter -WhatIf aber nicht
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Get-WmiObject { $null }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft mit -WhatIf ohne Fehler durch' {
            { New-sqmAvailabilityGroup -SqlInstance 'SQL01' -SecondaryReplica 'SQL02' `
                -AvailabilityGroupName 'TestAG' -Database 'AppDb' -WhatIf } | Should -Not -Throw
        }

        It 'Fuehrt unter -WhatIf KEINE schreibenden T-SQL-Aufrufe aus' {
            New-sqmAvailabilityGroup -SqlInstance 'SQL01' -SecondaryReplica 'SQL02' `
                -AvailabilityGroupName 'TestAG' -Database 'AppDb' -WhatIf | Out-Null
            # Keine CREATE/ALTER/EXEC sp_configure Schreib-Queries
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -ParameterFilter {
                $Query -match 'CREATE\s+(ENDPOINT|AVAILABILITY|DATABASE|LOGIN)' -or
                $Query -match 'ALTER\s+(AVAILABILITY|ENDPOINT|DATABASE)' -or
                $Query -match "sp_configure\s+'hadr enabled'"
            }
        }

        It 'Gibt ein Status-Objekt mit Status=WhatIf zurueck' {
            $r = New-sqmAvailabilityGroup -SqlInstance 'SQL01' -SecondaryReplica 'SQL02' `
                -AvailabilityGroupName 'TestAG' -WhatIf
            $r.Status            | Should -Be 'WhatIf'
            $r.AvailabilityGroup | Should -Be 'TestAG'
            $r.PrimaryReplica    | Should -Be 'SQL01'
        }
    }

    Context 'Ausfuehrung (gemockt) - bereits vorhandene AG wird uebersprungen' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance -Name 'SQL01' }
            Mock -ModuleName sqmSQLTool Get-WmiObject { $null }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Start-Sleep { }
            # HADR aktiv, Endpoint vorhanden, AG vorhanden -> alle Schritte idempotent uebersprungen
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'hadr enabled')             { return [PSCustomObject]@{ value_in_use = 1 } }
                if ($Query -match 'sys.endpoints')            { return [PSCustomObject]@{ name = 'HADR_Endpoint' } }
                if ($Query -match 'sys.availability_groups')  { return [PSCustomObject]@{ name = 'TestAG' } }
                return @()
            }
        }

        It 'Laeuft ohne Fehler und meldet Success' {
            $r = New-sqmAvailabilityGroup -SqlInstance 'SQL01' -SecondaryReplica 'SQL02' `
                -AvailabilityGroupName 'TestAG' -Confirm:$false
            $r.Status | Should -BeIn @('Success', 'CompletedWithErrors')
        }

        It 'Legt keine AG an wenn sie bereits existiert' {
            New-sqmAvailabilityGroup -SqlInstance 'SQL01' -SecondaryReplica 'SQL02' `
                -AvailabilityGroupName 'TestAG' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -ParameterFilter {
                $Query -match 'CREATE AVAILABILITY GROUP'
            }
        }
    }
}

Describe 'Invoke-sqmAlwaysOnSetup' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Invoke-sqmAlwaysOnSetup | Should -Not -BeNullOrEmpty
        }

        It 'Unterstuetzt ShouldProcess (WhatIf/Confirm)' {
            $cmd = Get-Command Invoke-sqmAlwaysOnSetup
            $cmd.Parameters.ContainsKey('WhatIf')  | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
        }

        It 'Kernparameter existieren' {
            $cmd = Get-Command Invoke-sqmAlwaysOnSetup
            $cmd.Parameters.ContainsKey('AvailabilityGroupName') | Should -Be $true
            $cmd.Parameters.ContainsKey('Database')              | Should -Be $true
            $cmd.Parameters.ContainsKey('SqlCredential')         | Should -Be $true
        }
    }
}
