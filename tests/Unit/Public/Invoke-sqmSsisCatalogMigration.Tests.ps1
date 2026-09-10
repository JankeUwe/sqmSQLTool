#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Invoke-sqmSsisCatalogMigration.
    Invoke-DbaQuery und die dbatools-/Modul-Aufrufe werden gemockt; getestet wird die
    Entscheidungslogik: Blocker, Reihenfolge der Schritte, Umschluesselung, Schemavergleich
    und die WhatIf-/AssessOnly-Zusicherung, dass nichts geaendert wird.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory

    $script:Pw = ConvertTo-SecureString 'Cat#Pwd!2026' -AsPlainText -Force

    # Invoke-sqmRestoreDatabase validiert -BackupFile per ValidateScript, und ein Pester-Mock
    # UEBERNIMMT den Parameterblock des Originals - die Validierung laeuft also auch gegen den
    # Mock. Deshalb braucht es eine Datei, die es wirklich gibt. Der Pfad wird ueber $env:TEMP
    # gebildet, damit ihn auch die Mock-Bodies aufloesen koennen (die laufen im Modulkontext).
    $script:FakeBackup = Join-Path $env:TEMP 'sqmSsisMig_TestBackup.bak'
    Set-Content -Path $script:FakeBackup -Value 'x' -Encoding ASCII
}

AfterAll {
    if ($script:FakeBackup -and (Test-Path $script:FakeBackup)) { Remove-Item $script:FakeBackup -Force }
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmSsisCatalogMigration' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Invoke-sqmSsisCatalogMigration | Should -Not -BeNullOrEmpty
        }

        It '<_> Parameter existiert' -ForEach @(
            'SourceSqlInstance', 'SourceSqlCredential', 'DestinationSqlInstance', 'DestinationSqlCredential',
            'CatalogPassword', 'KeyFilePassword', 'SharedPath', 'DestinationDataPath', 'DestinationLogPath',
            'AssessOnly', 'UseKeyBackupRestore', 'UpgradeCatalog', 'UpgradeWizardPath', 'UpgradeWizardArgument',
            'SkipAgentJobScan', 'Force', 'OutputPath', 'NoOpen', 'NoReport', 'EnableException'
        ) {
            (Get-Command Invoke-sqmSsisCatalogMigration).Parameters.ContainsKey($_) | Should -Be $true
        }

        It 'Unterstuetzt ShouldProcess (WhatIf/Confirm)' {
            $cmd = Get-Command Invoke-sqmSsisCatalogMigration
            $cmd.Parameters.ContainsKey('WhatIf') | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
        }

        It 'Verlangt -CatalogPassword fuer eine echte Migration' {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
            { Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' -Confirm:$false } |
                Should -Throw '*CatalogPassword*'
        }

        It 'Laesst -AssessOnly ohne Kennwort zu' {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Developer Edition'; DefaultBackupPath = 'C:\Backup'; ClrEnabled = 0; StartupProcCount = 0; MaintenanceJobCount = 0 }) }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference { @() }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
            { Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' -AssessOnly -NoReport -Confirm:$false } |
                Should -Not -Throw
        }
    }

    Context 'Bewertung: keine SSISDB auf der Quelle' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @([PSCustomObject]@{
                        SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Developer Edition'
                        DefaultBackupPath = 'C:\Backup'; ClrEnabled = 0; StartupProcCount = 0; MaintenanceJobCount = 0
                    })
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Meldet Blocked statt zu migrieren' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            $r.Reason | Should -Match 'keine SSISDB'
        }

        It 'Legt kein Backup an' {
            Mock -ModuleName sqmSQLTool Backup-DbaDatabase { }
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Backup-DbaDatabase -Exactly 0
        }
    }

    Context 'Bewertung: Ziel ist aelter als die Quelle' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') {
                        @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '16.0.1200.5'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 })
                    } else {
                        @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '15.0.4360.2'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 0; MaintenanceJobCount = 0 })
                    }
                }
                elseif ($Query -match 'is_trustworthy_on') {
                    @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 512.00 })
                }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') {
                    @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '7'; SchemaBuild = '16.0.1200'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 3; ProjectCount = 12; PackageCount = 88; EnvironmentCount = 4 })
                }
                else { @() }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Blockt den Downgrade-Restore' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            $r.Reason | Should -Match 'aelter als die Quelle'
        }
    }

    Context 'Bewertung: vollstaendiger Katalog' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference {
                @([PSCustomObject]@{ JobName = 'ETL Nightly'; StepName = 'Run package'; Subsystem = 'SSIS'; LineText = '/ISSERVER "\SSISDB\ETL\Load\Main.dtsx" /SERVER OLD' })
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') {
                        @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 })
                    } else {
                        @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 0; StartupProcCount = 0; MaintenanceJobCount = 0 })
                    }
                }
                elseif ($Query -match 'is_trustworthy_on') {
                    @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 512.00 })
                }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') {
                    @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '6'; SchemaBuild = '15.0.4360'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 3; ProjectCount = 12; PackageCount = 88; EnvironmentCount = 4 })
                }
                else { @() }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Liefert das Inventar der Quelle' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false
            $r.Status | Should -Be 'Success'
            $r.Action | Should -Be 'Assess'
            $r.Source.ProjectCount | Should -Be 12
            $r.Source.PackageCount | Should -Be 88
            $r.Source.EnvironmentCount | Should -Be 4
            $r.SchemaVersionSource | Should -Be '6'
        }

        It 'Prueft das Master-Key-Kennwort gegen die Quelle, bevor irgendetwas geaendert wird' {
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -match 'OPEN MASTER KEY' -and "$SqlInstance" -eq 'OLD'
            }
        }

        It 'Listet die Agent-Jobs, die umgehaengt werden muessen' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false
            @($r.AgentJobsToRepoint).Count | Should -Be 1
            @($r.AgentJobsToRepoint)[0].JobName | Should -Be 'ETL Nightly'
        }

        It 'SkipAgentJobScan unterdrueckt den Scan' {
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -SkipAgentJobScan -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Find-sqmAgentJobReference -Exactly 0
        }

        It 'AssessOnly aendert nichts' {
            Mock -ModuleName sqmSQLTool Backup-DbaDatabase { }
            Mock -ModuleName sqmSQLTool New-DbaSsisCatalog { }
            Mock -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase { }
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Backup-DbaDatabase -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool New-DbaSsisCatalog -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase -Exactly 0
        }

        It 'Ein falsches Master-Key-Kennwort blockt die Migration' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'OPEN MASTER KEY') { throw 'Der Schluessel wird nicht mit der angegebenen Entschluesselungsmethode verschluesselt.' }
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') {
                        @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 })
                    } else {
                        @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 0; StartupProcCount = 0; MaintenanceJobCount = 0 })
                    }
                }
                elseif ($Query -match 'is_trustworthy_on') { @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 512.00 }) }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') { @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '6'; SchemaBuild = '15.0'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 1; ProjectCount = 1; PackageCount = 1; EnvironmentCount = 0 }) }
                else { @() }
            }
            Mock -ModuleName sqmSQLTool Backup-DbaDatabase { }

            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -NoReport -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            $r.Reason | Should -Match 'nicht oeffnen'
            Should -Invoke -ModuleName sqmSQLTool Backup-DbaDatabase -Exactly 0
        }

        It 'Eine vorhandene SSISDB auf dem Ziel blockt ohne -Force' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') {
                        @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 })
                    } else {
                        @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '16.0.1200.5'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 })
                    }
                }
                elseif ($Query -match 'is_trustworthy_on') { @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 512.00 }) }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') { @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '6'; SchemaBuild = '15.0'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 1; ProjectCount = 1; PackageCount = 1; EnvironmentCount = 0 }) }
                elseif ($Query -match 'SCHEMA_VERSION') { @([PSCustomObject]@{ SchemaVersion = '7'; SchemaBuild = '16.0' }) }
                else { @() }
            }
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            $r.Reason | Should -Match 'bereits eine SSISDB'
        }
    }

    Context 'Migration' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference { @() }
            Mock -ModuleName sqmSQLTool Backup-DbaDatabase { [PSCustomObject]@{ FullName = (Join-Path $env:TEMP 'sqmSsisMig_TestBackup.bak') } }
            Mock -ModuleName sqmSQLTool New-DbaSsisCatalog { [PSCustomObject]@{ SsisCatalog = 'SSISDB' } }
            Mock -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase {
                @([PSCustomObject]@{ Action = 'RestoreStep'; Status = 'Success'; Message = 'Wiederhergestellt.' })
            }
            Mock -ModuleName sqmSQLTool Repair-DbaDbOrphanUser { @() }
            Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') {
                        @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 })
                    } else {
                        @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Enterprise'; DefaultBackupPath = 'C:\B'; ClrEnabled = 0; StartupProcCount = 0; MaintenanceJobCount = 0 })
                    }
                }
                elseif ($Query -match 'is_trustworthy_on') { @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 512.00 }) }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') { @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '6'; SchemaBuild = '15.0'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 3; ProjectCount = 12; PackageCount = 88; EnvironmentCount = 4 }) }
                elseif ($Query -match 'is_master_key_encrypted_by_server AS ByService') { @([PSCustomObject]@{ ByService = $true }) }
                elseif ($Query -match 'SCHEMA_VERSION') { @([PSCustomObject]@{ SchemaVersion = '7' }) }
                else { @() }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Sichert Master Key und Datenbank, legt den Katalog an und stellt wieder her' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false
            $r.Status | Should -BeIn @('Success', 'Failed')
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'BACKUP MASTER KEY' }
            Should -Invoke -ModuleName sqmSQLTool Backup-DbaDatabase -Exactly 1
            Should -Invoke -ModuleName sqmSQLTool New-DbaSsisCatalog -Exactly 1
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase -Exactly 1
        }

        It 'Aktiviert CLR auf dem Ziel, wenn es dort aus ist' {
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -match "clr enabled', 1" -and "$SqlInstance" -eq 'NEW'
            }
        }

        It 'Setzt TRUSTWORTHY und den Eigentuemer nach dem Restore' {
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -match 'SET TRUSTWORTHY ON' -and $Query -match 'ALTER AUTHORIZATION'
            }
        }

        It 'Schluesselt den Hauptschluessel auf den Service Master Key des Ziels um' {
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter {
                $Query -match 'ADD ENCRYPTION BY SERVICE MASTER KEY' -and "$SqlInstance" -eq 'NEW'
            }
        }

        It 'Ruft catalog.startup auf' {
            Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'catalog\.startup' }
        }

        It 'Kein Upgrade, wenn die wiederhergestellte Schemaversion der des Zielservers entspricht' {
            Mock -ModuleName sqmSQLTool Start-Process { }
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false
            $r.UpgradeRequired | Should -Be $false
            $r.UpgradeResult | Should -Be 'NotAttempted'
            Should -Invoke -ModuleName sqmSQLTool Start-Process -Exactly 0
        }

        It 'Meldet einen fehlgeschlagenen Restore als Failed und arbeitet nicht weiter' {
            Mock -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase {
                @([PSCustomObject]@{ Action = 'RestoreStep'; Status = 'Failed'; Message = 'Exclusive access could not be obtained.' })
            }
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'Exclusive access'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'catalog\.startup' } -Exactly 0
        }

        It 'Meldet Failed, wenn der Schluessel danach immer noch nicht am Dienstschluessel haengt' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'is_master_key_encrypted_by_server AS ByService') { return @([PSCustomObject]@{ ByService = $false }) }
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') { @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 }) }
                    else { @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 0; MaintenanceJobCount = 0 }) }
                }
                elseif ($Query -match 'is_trustworthy_on') { @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 1 }) }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') { @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '6'; SchemaBuild = '15.0'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 1; ProjectCount = 1; PackageCount = 1; EnvironmentCount = 0 }) }
                elseif ($Query -match 'SCHEMA_VERSION') { @([PSCustomObject]@{ SchemaVersion = '6' }) }
                else { @() }
            }
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -Confirm:$false
            $r.Status | Should -Be 'Failed'
            @($r.Steps | Where-Object { $_.Step -eq 'Master Key umschluesseln' -and $_.Status -eq 'Failed' }).Count | Should -BeGreaterThan 0
        }

        It '-UseKeyBackupRestore ohne -Force verweigert das erzwungene RESTORE MASTER KEY' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -UseKeyBackupRestore -NoReport -Confirm:$false
            @($r.Steps | Where-Object { $_.Step -eq 'Master Key umschluesseln' -and $_.Status -eq 'Failed' -and $_.Detail -match 'FORCE' }).Count |
                Should -BeGreaterThan 0
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'RESTORE MASTER KEY' } -Exactly 0
        }

        It 'Schreibt einen HTML-Bericht' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -OutputPath $script:TestDir -NoOpen -Confirm:$false
            $r.ReportFile | Should -Not -BeNullOrEmpty
            Test-Path $r.ReportFile | Should -Be $true
            (Get-Content $r.ReportFile -Raw) | Should -Match 'SSIS-Katalog-Migration'
        }

        It 'Schreibt das Kennwort nicht in den Bericht' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -OutputPath $script:TestDir -NoOpen -Confirm:$false
            (Get-Content $r.ReportFile -Raw) | Should -Not -Match 'Cat#Pwd!2026'
        }
    }

    Context 'Schemaanhebung' {
        # Ziel hat bereits einen Katalog (Schemaversion 7 = das, was dieser Server erzeugt), die
        # wiederhergestellte SSISDB kommt mit 6 an. Genau daran wird das Upgrade erkannt - ohne
        # fest verdrahtete Versionstabelle.
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference { @() }
            Mock -ModuleName sqmSQLTool Backup-DbaDatabase { [PSCustomObject]@{ FullName = (Join-Path $env:TEMP 'sqmSsisMig_TestBackup.bak') } }
            Mock -ModuleName sqmSQLTool New-DbaSsisCatalog { }
            Mock -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase {
                @([PSCustomObject]@{ Action = 'RestoreStep'; Status = 'Success'; Message = 'Wiederhergestellt.' })
            }
            Mock -ModuleName sqmSQLTool Repair-DbaDbOrphanUser { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') { @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 }) }
                    else { @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '16.0.1200.5'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 }) }
                }
                elseif ($Query -match 'is_trustworthy_on') { @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 1 }) }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') { @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '6'; SchemaBuild = '15.0'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 1; ProjectCount = 1; PackageCount = 1; EnvironmentCount = 0 }) }
                elseif ($Query -match 'is_master_key_encrypted_by_server AS ByService') { @([PSCustomObject]@{ ByService = $true }) }
                elseif ($Query -match 'SCHEMA_BUILD') { @([PSCustomObject]@{ SchemaVersion = '7'; SchemaBuild = '16.0' }) }
                elseif ($Query -match 'SCHEMA_VERSION') { @([PSCustomObject]@{ SchemaVersion = '6' }) }
                else { @() }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Erkennt die noetige Anhebung und laesst sie ohne -UpgradeCatalog liegen' {
            Mock -ModuleName sqmSQLTool Start-Process { }
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -Force -NoReport -Confirm:$false
            $r.UpgradeRequired | Should -Be $true
            $r.UpgradeResult | Should -Be 'NotAttempted'
            Should -Invoke -ModuleName sqmSQLTool Start-Process -Exactly 0
            @($r.Steps | Where-Object { $_.Step -eq 'Schemaversion pruefen' -and $_.Status -eq 'Warning' }).Count | Should -BeGreaterThan 0
        }

        It 'Meldet einen wirkungslosen Assistentenlauf als Fehler statt als Erfolg' {
            $fakeWizard = Join-Path $script:TestDir 'ISDBUpgradeWizard.exe'
            Set-Content -Path $fakeWizard -Value 'x' -Encoding ASCII
            Mock -ModuleName sqmSQLTool Start-Process { [PSCustomObject]@{ ExitCode = 0 } }

            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -Force -UpgradeCatalog `
                -UpgradeWizardPath $fakeWizard -NoReport -Confirm:$false

            Should -Invoke -ModuleName sqmSQLTool Start-Process -Exactly 1
            $r.UpgradeResult | Should -Be 'NoEffect'
            $r.Status | Should -Be 'Failed'
        }

        It 'Meldet einen fehlenden Assistenten als Warnung mit manueller Anweisung' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -Force -UpgradeCatalog `
                -UpgradeWizardPath 'C:\gibt-es-nicht\ISDBUpgradeWizard.exe' -NoReport -Confirm:$false
            $r.UpgradeResult | Should -Be 'WizardNotFound'
            @($r.Steps | Where-Object { $_.Step -eq 'Katalog-Upgrade' -and $_.Detail -match 'SSMS' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Beschaedigter Katalog' {
        # Regression: die Pruefung des Hauptschluessels hing frueher an derselben Abfrage wie die
        # Katalogsichten. Fielen die aus, galt der Schluessel als "unbekannt" und die
        # Kennwortpruefung wurde stillschweigend uebersprungen - ausgerechnet in dem Zustand, in
        # dem sie am wichtigsten ist. Gegen einen echten Server aufgefallen.
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') { @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 }) }
                    else { @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 0; MaintenanceJobCount = 0 }) }
                }
                elseif ($Query -match 'is_trustworthy_on') { @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $false; MasterKeyByService = $true; DbOwner = 'dev'; SizeMB = 16.00 }) }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') { throw 'Ungueltiger Objektname "catalog.catalog_properties".' }
                elseif ($Query -match 'OPEN MASTER KEY') { throw 'Der Schluessel wird nicht mit der angegebenen Entschluesselungsmethode verschluesselt.' }
                else { @() }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Prueft das Kennwort auch dann, wenn die Katalogsichten fehlen' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false
            $r.Source.MasterKeyPresent | Should -Be $true
            @($r.Steps | Where-Object { $_.Step -eq 'Master-Key-Kennwort pruefen' }).Count | Should -Be 1
            $r.Reason | Should -Match 'nicht oeffnen'
        }

        It 'Meldet beide Befunde, nicht nur den ersten' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -AssessOnly -NoReport -Confirm:$false
            $r.Status | Should -Be 'Blocked'
            $r.Reason | Should -Match 'catalog.catalog_properties'
            $r.Source.CatalogReadError | Should -Match 'catalog.catalog_properties'
        }
    }

    Context 'WhatIf' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Find-sqmAgentJobReference { @() }
            Mock -ModuleName sqmSQLTool Backup-DbaDatabase { [PSCustomObject]@{ FullName = (Join-Path $env:TEMP 'sqmSsisMig_TestBackup.bak') } }
            Mock -ModuleName sqmSQLTool New-DbaSsisCatalog { }
            Mock -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'SsisDbExists') {
                    if ("$SqlInstance" -eq 'OLD') { @([PSCustomObject]@{ SsisDbExists = 1; ProductVersion = '15.0.4360.2'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 1; StartupProcCount = 1; MaintenanceJobCount = 1 }) }
                    else { @([PSCustomObject]@{ SsisDbExists = 0; ProductVersion = '16.0.1200.5'; Edition = 'Ent'; DefaultBackupPath = 'C:\B'; ClrEnabled = 0; StartupProcCount = 0; MaintenanceJobCount = 0 }) }
                }
                elseif ($Query -match 'is_trustworthy_on') { @([PSCustomObject]@{ DatabaseState = 'ONLINE'; IsTrustworthy = $true; MasterKeyByService = $true; DbOwner = 'sa'; SizeMB = 1 }) }
                elseif ($Query -match 'AS DmkCount') { @([PSCustomObject]@{ DmkCount = 1 }) }
                elseif ($Query -match 'FolderCount') { @([PSCustomObject]@{ DmkCount = 1; SchemaVersion = '6'; SchemaBuild = '15.0'; EncryptionAlgorithm = 'AES_256'; RetentionWindow = '365'; FolderCount = 1; ProjectCount = 1; PackageCount = 1; EnvironmentCount = 0 }) }
                else { @() }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Aendert im WhatIf-Lauf nichts' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -CatalogPassword $script:Pw -SharedPath $script:TestDir -NoReport -WhatIf
            Should -Invoke -ModuleName sqmSQLTool Backup-DbaDatabase -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool New-DbaSsisCatalog -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmRestoreDatabase -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'BACKUP MASTER KEY' } -Exactly 0
        }
    }

    Context 'Fehlerbehandlung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'Login failed' }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Wirft mit -EnableException' {
            { Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                    -AssessOnly -NoReport -EnableException -Confirm:$false } | Should -Throw
        }

        It 'Ohne -EnableException wird ein Failed-Ergebnis zurueckgegeben' {
            $r = Invoke-sqmSsisCatalogMigration -SourceSqlInstance 'OLD' -DestinationSqlInstance 'NEW' `
                -AssessOnly -NoReport -Confirm:$false
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'Login failed'
        }
    }
}
