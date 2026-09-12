#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Add-sqmDatabaseToAG, Schwerpunkt TDE-Behandlung.
    dbatools wird vollstaendig gemockt; getestet wird die Entscheidungslogik:
    Versionsschranke SQL 2019, Zertifikatspruefung ueber den Thumbprint, Verteilung
    an die Secondaries und die Zusicherung, dass bei einem Abbruch nichts veraendert wurde.
#>

# Hinweis zu den ParameterFiltern: ein Pester-Mock uebernimmt den Parameterblock des
# Originals, deshalb kommt -SqlInstance als DbaInstanceParameter an und nicht als String.
# Ein blosses $SqlInstance -eq 'SQL02' greift nicht - erst "$SqlInstance" -eq 'SQL02'.
BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory
    $script:Pw = ConvertTo-SecureString 'Cert#Pwd!2026' -AsPlainText -Force
}

AfterAll {
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Add-sqmDatabaseToAG' {

    Context 'Parameter-Validierung' {
        It '<_> Parameter existiert' -ForEach @(
            'SqlInstance', 'SqlCredential', 'AvailabilityGroup', 'Database', 'All',
            'SyncTdeCertificate', 'TdeCertificateBackupPath', 'TdeCertificatePassword',
            'TdeMasterKeyPassword', 'KeepTdeCertificateBackup', 'EnableException'
        ) {
            (Get-Command Add-sqmDatabaseToAG).Parameters.ContainsKey($_) | Should -Be $true
        }

        It 'Unterstuetzt ShouldProcess (WhatIf/Confirm)' {
            $cmd = Get-Command Add-sqmDatabaseToAG
            $cmd.Parameters.ContainsKey('WhatIf')  | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
        }

        It 'Die TDE-Parameter gelten in beiden Parametersaetzen' {
            $cmd = Get-Command Add-sqmDatabaseToAG
            foreach ($setName in 'Specific', 'All')
            {
                $set = $cmd.ParameterSets | Where-Object { $_.Name -eq $setName }
                $set.Parameters.Name | Should -Contain 'SyncTdeCertificate'
                $set.Parameters.Name | Should -Contain 'TdeCertificatePassword'
            }
        }

        It '-SyncTdeCertificate ohne -TdeCertificateBackupPath wird abgelehnt' {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            { Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'DB1' `
                    -SyncTdeCertificate -TdeCertificatePassword $script:Pw -WhatIf } |
                Should -Throw '*TdeCertificateBackupPath*'
        }

        It '-SyncTdeCertificate ohne -TdeCertificatePassword wird abgelehnt' {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            { Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'DB1' `
                    -SyncTdeCertificate -TdeCertificateBackupPath $script:TestDir -WhatIf } |
                Should -Throw '*TdeCertificatePassword*'
        }

        It 'Ein nicht vorhandener Ablagepfad wird abgelehnt' {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            { Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'DB1' `
                    -SyncTdeCertificate -TdeCertificateBackupPath 'C:\gibt\es\nicht' `
                    -TdeCertificatePassword $script:Pw -WhatIf } |
                Should -Throw '*nicht gefunden*'
        }
    }

    Context 'Datenbank ohne TDE (unveraendertes Verhalten)' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { [PSCustomObject]@{ Name = 'AG1' } }
            Mock -ModuleName sqmSQLTool Get-DbaAgReplica {
                @([PSCustomObject]@{ Name = 'SQL01'; Role = 'Primary' },
                    [PSCustomObject]@{ Name = 'SQL02'; Role = 'Secondary' })
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'PlainDB'; RecoveryModel = 'Full'; IsAccessible = $true } }
            Mock -ModuleName sqmSQLTool Get-DbaAgDatabase { $null }
            Mock -ModuleName sqmSQLTool Remove-DbaDatabase { }
            Mock -ModuleName sqmSQLTool Add-DbaAgDatabase { }
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { [PSCustomObject]@{ VersionMajor = 16 } }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
        }

        It 'Wird ganz normal zur AG hinzugefuegt' {
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PlainDB' -Confirm:$false
            $r.Status | Should -Be 'Success'
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 1
        }

        It 'Fragt die Zertifikate gar nicht erst ab' {
            Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PlainDB' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WHERE CONVERT\(varchar\(100\), thumbprint, 1\)' } -Exactly 0
        }
    }

    Context 'TDE-Datenbank auf einem Replica unterhalb SQL 2019' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { [PSCustomObject]@{ Name = 'AG1' } }
            Mock -ModuleName sqmSQLTool Get-DbaAgReplica {
                @([PSCustomObject]@{ Name = 'SQL01'; Role = 'Primary' },
                    [PSCustomObject]@{ Name = 'SQL02'; Role = 'Secondary' })
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'PayrollDB'; RecoveryModel = 'Full'; IsAccessible = $true } }
            Mock -ModuleName sqmSQLTool Get-DbaAgDatabase { $null }
            Mock -ModuleName sqmSQLTool Remove-DbaDatabase { }
            Mock -ModuleName sqmSQLTool Add-DbaAgDatabase { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_database_encryption_keys' } -MockWith {
                [PSCustomObject]@{ DatabaseName = 'PayrollDB'; EncryptionState = 3; CertificateName = 'TDE_Cert'; EncryptorThumbprint = '0xAA11' }
            }
            # Primary SQL 2022, Secondary noch SQL 2016
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { [PSCustomObject]@{ VersionMajor = 16 } }
            Mock -ModuleName sqmSQLTool Connect-DbaInstance -ParameterFilter { "$SqlInstance" -eq 'SQL02' } -MockWith { [PSCustomObject]@{ VersionMajor = 13 } }
        }

        It 'Meldet TdeUnsupportedVersion und nennt das zu alte Replica' {
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' -Confirm:$false
            $r.Status | Should -Be 'TdeUnsupportedVersion'
            $r.Message | Should -BeLike '*SQL02*'
        }

        It 'Veraendert dabei nichts: kein Drop, kein Add' {
            Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' -Confirm:$false | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Remove-DbaDatabase -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 0
        }
    }

    Context 'TDE-Datenbank, Zertifikat fehlt auf dem Secondary' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { [PSCustomObject]@{ Name = 'AG1' } }
            Mock -ModuleName sqmSQLTool Get-DbaAgReplica {
                @([PSCustomObject]@{ Name = 'SQL01'; Role = 'Primary' },
                    [PSCustomObject]@{ Name = 'SQL02'; Role = 'Secondary' })
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'PayrollDB'; RecoveryModel = 'Full'; IsAccessible = $true } }
            Mock -ModuleName sqmSQLTool Get-DbaAgDatabase { $null }
            Mock -ModuleName sqmSQLTool Remove-DbaDatabase { }
            Mock -ModuleName sqmSQLTool Add-DbaAgDatabase { }
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { [PSCustomObject]@{ VersionMajor = 16 } }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_database_encryption_keys' } -MockWith {
                [PSCustomObject]@{ DatabaseName = 'PayrollDB'; EncryptionState = 3; CertificateName = 'TDE_Cert'; EncryptorThumbprint = '0xAA11' }
            }
        }

        It 'Ohne -SyncTdeCertificate wird uebersprungen, mit Nennung des Knotens' {
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' -Confirm:$false
            $r.Status | Should -Be 'TdeCertificateMissing'
            $r.Message | Should -BeLike '*SQL02*'
            Should -Invoke -ModuleName sqmSQLTool Remove-DbaDatabase -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 0
        }

        It 'Mit -SyncTdeCertificate wird exportiert, der Hauptschluessel angelegt und das Zertifikat erzeugt' {
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' `
                -SyncTdeCertificate -TdeCertificateBackupPath $script:TestDir -TdeCertificatePassword $script:Pw -Confirm:$false
            $r.Status | Should -Be 'Success'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'BACKUP CERTIFICATE' -and "$SqlInstance" -eq 'SQL01' } -Exactly 1
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'CREATE MASTER KEY' -and "$SqlInstance" -eq 'SQL02' } -Exactly 1
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'CREATE CERTIFICATE' -and "$SqlInstance" -eq 'SQL02' } -Exactly 1
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 1
        }

        It 'Unter -WhatIf wird nichts exportiert und nichts hinzugefuegt' {
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' `
                -SyncTdeCertificate -TdeCertificateBackupPath $script:TestDir -TdeCertificatePassword $script:Pw -WhatIf
            $r.Status | Should -Be 'TdeSyncSkipped'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'BACKUP CERTIFICATE' } -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 0
        }
    }

    Context 'TDE-Datenbank, Zertifikat auf allen Secondaries vorhanden' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { [PSCustomObject]@{ Name = 'AG1' } }
            Mock -ModuleName sqmSQLTool Get-DbaAgReplica {
                @([PSCustomObject]@{ Name = 'SQL01'; Role = 'Primary' },
                    [PSCustomObject]@{ Name = 'SQL02'; Role = 'Secondary' })
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'PayrollDB'; RecoveryModel = 'Full'; IsAccessible = $true } }
            Mock -ModuleName sqmSQLTool Get-DbaAgDatabase { $null }
            Mock -ModuleName sqmSQLTool Remove-DbaDatabase { }
            Mock -ModuleName sqmSQLTool Add-DbaAgDatabase { }
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { [PSCustomObject]@{ VersionMajor = 15 } }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_database_encryption_keys' } -MockWith {
                [PSCustomObject]@{ DatabaseName = 'PayrollDB'; EncryptionState = 3; CertificateName = 'TDE_Cert'; EncryptorThumbprint = '0xAA11' }
            }
            # Thumbprint-Treffer auf dem Secondary, dort unter anderem Namen - das genuegt SQL Server
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WHERE CONVERT\(varchar\(100\), thumbprint, 1\)' } -MockWith {
                [PSCustomObject]@{ name = 'TDE_Cert_Kopie' }
            }
        }

        It 'Wird hinzugefuegt, ohne etwas zu exportieren' {
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' -Confirm:$false
            $r.Status | Should -Be 'Success'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'BACKUP CERTIFICATE' } -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 1
        }
    }

    Context 'Sonderfaelle der Verschluesselung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Get-DbaAvailabilityGroup { [PSCustomObject]@{ Name = 'AG1' } }
            Mock -ModuleName sqmSQLTool Get-DbaAgReplica {
                @([PSCustomObject]@{ Name = 'SQL01'; Role = 'Primary' },
                    [PSCustomObject]@{ Name = 'SQL02'; Role = 'Secondary' })
            }
            Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'PayrollDB'; RecoveryModel = 'Full'; IsAccessible = $true } }
            Mock -ModuleName sqmSQLTool Get-DbaAgDatabase { $null }
            Mock -ModuleName sqmSQLTool Remove-DbaDatabase { }
            Mock -ModuleName sqmSQLTool Add-DbaAgDatabase { }
            Mock -ModuleName sqmSQLTool Connect-DbaInstance { [PSCustomObject]@{ VersionMajor = 16 } }
        }

        It 'Asymmetrischer Schluessel (EKM) wird als solcher gemeldet, nicht als fehlendes Zertifikat' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_database_encryption_keys' } -MockWith {
                [PSCustomObject]@{ DatabaseName = 'PayrollDB'; EncryptionState = 3; CertificateName = [System.DBNull]::Value; EncryptorThumbprint = '0xBB22' }
            }
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' -Confirm:$false
            $r.Status | Should -Be 'TdeEncryptorNotCertificate'
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 0
        }

        It 'Gleicher Name mit abweichendem Thumbprint wird nicht ueberschrieben' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { @() }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_database_encryption_keys' } -MockWith {
                [PSCustomObject]@{ DatabaseName = 'PayrollDB'; EncryptionState = 3; CertificateName = 'TDE_Cert'; EncryptorThumbprint = '0xAA11' }
            }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'WHERE name = N' } -MockWith {
                [PSCustomObject]@{ Thumb = '0xCC33' }
            }
            $r = Add-sqmDatabaseToAG -SqlInstance 'SQL01' -AvailabilityGroup 'AG1' -Database 'PayrollDB' `
                -SyncTdeCertificate -TdeCertificateBackupPath $script:TestDir -TdeCertificatePassword $script:Pw -Confirm:$false
            $r.Status | Should -Be 'TdeCertificateNameConflict'
            $r.Message | Should -BeLike '*0xCC33*'
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'CREATE CERTIFICATE' } -Exactly 0
            Should -Invoke -ModuleName sqmSQLTool Add-DbaAgDatabase -Exactly 0
        }
    }
}
