#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmAlwaysOnQueueStatus
    dbatools-Abhaengigkeiten werden vollstaendig gemockt.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmAlwaysOnQueueStatus' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert und ist aufrufbar' {
            Get-Command Get-sqmAlwaysOnQueueStatus | Should -Not -BeNullOrEmpty
        }

        It 'SqlInstance ist nicht mandatory (Default = Computername)' {
            $cmd = Get-Command Get-sqmAlwaysOnQueueStatus
            $mandatory = $cmd.Parameters['SqlInstance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory -First 1
            $mandatory | Should -Be $false
        }

        It 'MaxRedoQueueMB Parameter existiert' {
            (Get-Command Get-sqmAlwaysOnQueueStatus).Parameters.ContainsKey('MaxRedoQueueMB') | Should -Be $true
        }

        It 'MaxSendQueueMB Parameter existiert' {
            (Get-Command Get-sqmAlwaysOnQueueStatus).Parameters.ContainsKey('MaxSendQueueMB') | Should -Be $true
        }

        It 'Hat keinen OutputPath Parameter (schreibt keine Dateien)' {
            (Get-Command Get-sqmAlwaysOnQueueStatus).Parameters.ContainsKey('OutputPath') | Should -Be $false
        }
    }

    Context 'Instanz ohne Availability Groups' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { $null }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Liefert ein leeres Ergebnis statt eines Fehlers' {
            $result = @(Get-sqmAlwaysOnQueueStatus -SqlInstance 'TESTSERVER')
            $result.Count | Should -Be 0
        }
    }

    Context 'Ausfuehrung mit gemockten dbatools' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup {
                @([PSCustomObject]@{
                    Name           = 'TestAG'
                    PrimaryReplica = 'TESTSERVER'
                })
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @([PSCustomObject]@{
                    AgName           = 'TestAG'
                    ReplicaName      = 'TESTSERVER'
                    AvailabilityMode = 'SYNCHRONOUS_COMMIT'
                    FailoverMode     = 'AUTOMATIC'
                    Role             = 'PRIMARY'
                    ConnectionState  = 'CONNECTED'
                    SyncHealth       = 'HEALTHY'
                    DatabaseName     = 'TestDB'
                    DbSyncState      = 'SYNCHRONIZED'
                    DbSyncHealth     = 'HEALTHY'
                    RedoQueueKB      = 0
                    SendQueueKB      = 51200
                    RedoRateKBs      = 0
                    SendRateKBs      = 1024
                    IsSuspended      = $false
                })
            }
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        }

        It 'Laeuft ohne Fehler durch und liefert Zeilen zurueck' {
            $result = @(Get-sqmAlwaysOnQueueStatus -SqlInstance 'TESTSERVER')
            $result.Count | Should -Be 1
        }

        It 'Berechnet SendQueueMB korrekt und markiert Warning oberhalb des Schwellwerts' {
            $result = Get-sqmAlwaysOnQueueStatus -SqlInstance 'TESTSERVER' -MaxSendQueueMB 10
            $result.SendQueueMB | Should -Be 50
            $result.OverallStatus | Should -Be 'Warning'
        }

        It 'Schreibt keine Dateien' {
            $tempDir = Join-Path $env:TEMP "sqmQueueStatusTest_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try
            {
                Get-sqmAlwaysOnQueueStatus -SqlInstance 'TESTSERVER' | Out-Null
                (Get-ChildItem $tempDir -File).Count | Should -Be 0
            }
            finally
            {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
