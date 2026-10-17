#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Zertifikatsfunktionen (v1.9.179.0): Install-sqmCertificate (PFX-Syntax,
    Partner-Public-Key mit AUTHORIZATION statt Endpoint-Umstellung, Service-Broker-Endpoint,
    TLS-Bindung ueber Set-sqmSqlTlsCertificate), New-sqmSqlCertificate (Sicherung des neuen
    Zertifikats, kein Umbenennen, SERVICE_BROKER-Klausel), Set-sqmConfig -TrustServerCertificate
    und New-sqmCertificateRequest fuer benannte Instanzen. Invoke-DbaQuery wird gemockt; die
    erzeugten T-SQL-Befehle sind live gegen SQL Server 2022 geprueft.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
	$script:pwd = ConvertTo-SecureString "p'w" -AsPlainText -Force
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'New-sqmCertImportSql' {
	It 'PFX: WITH FORMAT = PFX und PRIVATE KEY nur mit DECRYPTION BY PASSWORD' {
		$sql = InModuleScope sqmSQLTool -Parameters @{ P = $script:pwd } {
			New-sqmCertImportSql -CertificateName 'C1' -CertFile 'C:\c\a.pfx' -CertPassword $P -IsPfx $true -HasPrivKey $true
		}
		$sql | Should -Match "FROM FILE = N'C:\\c\\a\.pfx'"
		$sql | Should -Match "WITH FORMAT = 'PFX'"
		$sql | Should -Match "PRIVATE KEY \(DECRYPTION BY PASSWORD = N'p''w'\);"
		$sql | Should -Not -Match 'PRIVATE KEY \(FILE'
	}

	It 'CER + PVK: PRIVATE KEY (FILE, DECRYPTION BY PASSWORD), Anfuehrungszeichen maskiert' {
		$sql = InModuleScope sqmSQLTool -Parameters @{ P = $script:pwd } {
			New-sqmCertImportSql -CertificateName 'C1' -CertFile "C:\o'k\a.cer" -PrivateKeyFile 'C:\c\a.pvk' -CertPassword $P -IsPfx $false -HasPrivKey $true
		}
		$sql | Should -Match "FROM FILE = N'C:\\o''k\\a\.cer'"
		$sql | Should -Match "WITH PRIVATE KEY \(FILE = N'C:\\c\\a\.pvk', DECRYPTION BY PASSWORD = N'p''w'\);"
	}

	It 'Public Key mit AUTHORIZATION' {
		$sql = InModuleScope sqmSQLTool {
			New-sqmCertImportSql -CertificateName 'SQL01_AG' -CertFile 'C:\c\a.cer' -IsPfx $false -HasPrivKey $false -AuthorizationUser 'ag_user'
		}
		$sql | Should -Match '^CREATE CERTIFICATE \[SQL01_AG\] AUTHORIZATION \[ag_user\]'
		$sql | Should -Match "FROM FILE = N'C:\\c\\a\.cer';$"
	}
}

Describe 'Install-sqmCertificate' {
	BeforeEach {
		$script:cer = Join-Path $TestDrive 'part.cer'; Set-Content $script:cer 'x'
		$script:pvk = Join-Path $TestDrive 'part.pvk'; Set-Content $script:pvk 'x'
		$script:pfx = Join-Path $TestDrive 'srv.pfx'; Set-Content $script:pfx 'x'
		$script:major = 16; $script:dmk = 1; $script:userExists = $true
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
		Mock -ModuleName sqmSQLTool Write-Host { }
		Mock -ModuleName sqmSQLTool Get-sqmCertFileInfo {
			[PSCustomObject]@{ Subject = 'CN=t'; Issuer = 'CN=t'; NotBefore = (Get-Date).AddDays(-1); NotAfter = (Get-Date).AddYears(1); Thumbprint = 'AABBCC' }
		}
		Mock -ModuleName sqmSQLTool Add-sqmCertToMachineStore { }
		Mock -ModuleName sqmSQLTool Set-sqmSqlTlsCertificate { [PSCustomObject]@{ PrivateKeyGranted = $true; ServiceAccount = 'NT Service\MSSQLSERVER' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'ProductMajorVersion' } { [PSCustomObject]@{ MajorVersion = $script:major; HasDmk = $script:dmk } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'database_principals' } { if ($script:userExists) { [PSCustomObject]@{ name = 'ag_user' } } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM sys.certificates WHERE name' } { }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'database_mirroring_endpoints' } { [PSCustomObject]@{ name = 'Hadr_endpoint' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'service_broker_endpoints' } { [PSCustomObject]@{ name = 'Broker_EP' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^CREATE CERTIFICATE|^ALTER ' } { }
		$script:out = Join-Path $TestDrive 'out'
	}

	It 'Partner-Public-Key: CREATE ... AUTHORIZATION, Endpoint wird NICHT umgestellt' {
		$r = Install-sqmCertificate -SqlInstance 'SQL02' -CertFile $script:cer -CertificateName 'SQL01_AG' -Purpose AlwaysOn -AuthorizationUser 'ag_user' -OutputPath $script:out -Confirm:$false
		$r.Success | Should -BeTrue
		$r.EndpointBound | Should -BeFalse
		$r.PartnerKeyOwner | Should -Be 'ag_user'
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match 'CREATE CERTIFICATE \[SQL01_AG\] AUTHORIZATION \[ag_user\]' }
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter { $Query -match 'ALTER ENDPOINT' }
	}

	It 'Partner-Public-Key ohne -AuthorizationUser: Import mit Warnung, kein ALTER ENDPOINT' {
		$r = Install-sqmCertificate -SqlInstance 'SQL02' -CertFile $script:cer -Purpose AlwaysOn -OutputPath $script:out -Confirm:$false -WarningAction SilentlyContinue
		$r.Warnings -join ' ' | Should -Match 'ALTER AUTHORIZATION ON CERTIFICATE'
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter { $Query -match 'ALTER ENDPOINT' }
	}

	It 'Unbekannter -AuthorizationUser bricht vor dem Import ab' {
		$script:userExists = $false
		{ Install-sqmCertificate -SqlInstance 'SQL02' -CertFile $script:cer -Purpose AlwaysOn -AuthorizationUser 'nope' -OutputPath $script:out -Confirm:$false -EnableException } |
		Should -Throw '*nope*existiert nicht*'
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter { $Query -match '^CREATE CERTIFICATE' }
	}

	It 'Mit Private Key: lokaler AlwaysOn-Endpoint FOR DATABASE_MIRRORING' {
		$r = Install-sqmCertificate -SqlInstance 'SQL01' -CertFile $script:cer -PrivateKeyFile $script:pvk -CertPassword $script:pwd -CertificateName 'AG_NEW' -Purpose AlwaysOn -OutputPath $script:out -Confirm:$false
		$r.EndpointBound | Should -BeTrue
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -eq 'ALTER ENDPOINT [Hadr_endpoint] FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE [AG_NEW]);' }
	}

	It 'Service Broker: Endpoint aus sys.service_broker_endpoints, FOR SERVICE_BROKER' {
		$r = Install-sqmCertificate -SqlInstance 'SQL01' -CertFile $script:cer -PrivateKeyFile $script:pvk -CertPassword $script:pwd -CertificateName 'SB_NEW' -Purpose ServiceBroker -OutputPath $script:out -Confirm:$false
		$r.EndpointBound | Should -BeTrue
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -eq 'ALTER ENDPOINT [Broker_EP] FOR SERVICE_BROKER (AUTHENTICATION = CERTIFICATE [SB_NEW]);' }
	}

	It 'PFX vor SQL Server 2022: klare Fehlermeldung, kein CREATE' {
		$script:major = 15
		{ Install-sqmCertificate -SqlInstance 'SQL01' -CertFile $script:pfx -CertPassword $script:pwd -Purpose UserDefined -OutputPath $script:out -Confirm:$false -EnableException } |
		Should -Throw '*erst ab SQL Server 2022*'
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter { $Query -match '^CREATE CERTIFICATE' }
	}

	It 'PFX ab SQL Server 2022: CREATE mit FORMAT = PFX' {
		Install-sqmCertificate -SqlInstance 'SQL01' -CertFile $script:pfx -CertPassword $script:pwd -CertificateName 'P1' -OutputPath $script:out -Confirm:$false | Out-Null
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match "WITH FORMAT = 'PFX'" }
	}

	It 'Private Key ohne Database Master Key: klare Fehlermeldung' {
		$script:dmk = 0
		{ Install-sqmCertificate -SqlInstance 'SQL01' -CertFile $script:cer -PrivateKeyFile $script:pvk -CertPassword $script:pwd -OutputPath $script:out -Confirm:$false -EnableException } |
		Should -Throw '*Database Master Key*'
	}

	It 'SSL: kein Import nach SQL Server, Bindung ueber Set-sqmSqlTlsCertificate' {
		$r = Install-sqmCertificate -SqlInstance 'SQL01\INST1' -CertFile $script:pfx -CertPassword $script:pwd -Purpose SSL -SetSqlServerSslCert -OutputPath $script:out -Confirm:$false -WarningAction SilentlyContinue
		$r.Success | Should -BeTrue
		$r.WindowsStoreImport | Should -BeTrue
		$r.SslCertSet | Should -BeTrue
		$r.SqlImported | Should -BeFalse
		Should -Invoke -ModuleName sqmSQLTool Set-sqmSqlTlsCertificate -Times 1 -Exactly -ParameterFilter { $SqlInstance -eq 'SQL01\INST1' -and $Thumbprint -eq 'AABBCC' }
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -Exactly
	}

	It 'SSL: fehlendes Private-Key-Recht landet in den Warnungen' {
		Mock -ModuleName sqmSQLTool Set-sqmSqlTlsCertificate { [PSCustomObject]@{ PrivateKeyGranted = $false; ServiceAccount = 'NT Service\MSSQLSERVER' } }
		$r = Install-sqmCertificate -SqlInstance 'SQL01' -CertFile $script:pfx -CertPassword $script:pwd -Purpose SSL -SetSqlServerSslCert -OutputPath $script:out -Confirm:$false -WarningAction SilentlyContinue
		$r.Warnings -join ' ' | Should -Match 'Private Key'
	}
}

Describe 'New-sqmSqlCertificate' {
	BeforeEach {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
		Mock -ModuleName sqmSQLTool Write-Host { }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM sys.certificates c\s+WHERE c.name' } {
			[PSCustomObject]@{ CertificateName = 'SB_CERT'; subject = 'SB_CERT'; issuer_name = 'SB_CERT'; start_date = (Get-Date).AddYears(-1)
				expiry_date = (Get-Date).AddDays(10); thumbprint = [byte[]](1, 2, 3); PrivateKeyEncryption = 'ENCRYPTED_BY_MASTER_KEY'; HasPrivateKey = 1 }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'service_broker_endpoints' } { [PSCustomObject]@{ EndpointName = 'Broker_EP'; EndpointType = 'SERVICE_BROKER' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_database_encryption_keys' } { }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'xp_create_subdir|^BACKUP CERTIFICATE|^CREATE CERTIFICATE|^ALTER ' } { }
	}

	It 'Sichert altes UND neues Zertifikat mit Private Key, legt Verzeichnis serverseitig an' {
		$r = New-sqmSqlCertificate -SqlInstance 'SQL01' -CertificateName 'SB_CERT' -BackupPath $TestDrive -BackupEncryptionPassword $script:pwd -Confirm:$false
		$r.Success | Should -BeTrue
		$r.NewPvkBackupFile | Should -Match 'SB_CERT_\d{4}\.pvk$'
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match 'xp_create_subdir' }
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match "^BACKUP CERTIFICATE \[SB_CERT\] .*SB_CERT_OLD\.pvk', ENCRYPTION BY PASSWORD = N'p''w'\)" }
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match "^BACKUP CERTIFICATE \[SB_CERT_\d{4}\] .*WITH PRIVATE KEY" }
	}

	It 'Kein Umbenennen/Entfernen des alten Zertifikats, kein Endpoint-Wechsel ohne -BindEndpoint' {
		New-sqmSqlCertificate -SqlInstance 'SQL01' -CertificateName 'SB_CERT' -BackupPath $TestDrive -BackupEncryptionPassword $script:pwd -Confirm:$false | Out-Null
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter { $Query -match 'ALTER CERTIFICATE|DROP CERTIFICATE|ALTER ENDPOINT' }
	}

	It '-BindEndpoint fuer Service Broker: FOR SERVICE_BROKER' {
		$r = New-sqmSqlCertificate -SqlInstance 'SQL01' -CertificateName 'SB_CERT' -NewCertificateName 'SB_NEW' -BindEndpoint -BackupPath $TestDrive -BackupEncryptionPassword $script:pwd -Confirm:$false
		$r.EndpointBound | Should -BeTrue
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match 'ALTER ENDPOINT \[Broker_EP\]\s+FOR SERVICE_BROKER \(AUTHENTICATION = CERTIFICATE \[SB_NEW\]\)' }
	}

	It 'Protokoll nennt keinen nicht existierenden Schalter mehr' {
		$r = New-sqmSqlCertificate -SqlInstance 'SQL01' -CertificateName 'SB_CERT' -BackupPath $TestDrive -BackupEncryptionPassword $script:pwd -Confirm:$false
		$txt = Get-Content $r.ProtocolFile -Raw
		$txt | Should -Not -Match 'ForAlwaysOn'
		$txt | Should -Match '-AuthorizationUser'
	}
}

Describe 'Set-sqmConfig -TrustServerCertificate' {
	BeforeAll {
		$script:ConfigFile = Join-Path $env:APPDATA 'MSSQLTools\config.json'
		$script:ConfigBackup = if (Test-Path $script:ConfigFile) { Get-Content $script:ConfigFile -Raw } else { $null }
	}
	AfterAll {
		if ($script:ConfigBackup) { Set-Content $script:ConfigFile -Value $script:ConfigBackup -Encoding UTF8 }
		elseif (Test-Path $script:ConfigFile) { Remove-Item $script:ConfigFile -Force }
		Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true
	}

	It '$false: sofort wirksam fuer dbatools und gespeichert' {
		Set-sqmConfig -TrustServerCertificate $false
		Get-sqmConfig -Key 'TrustServerCertificate' | Should -BeFalse
		Get-DbatoolsConfigValue -FullName 'sql.connection.trustcert' | Should -BeFalse
		(Get-Content $script:ConfigFile -Raw | ConvertFrom-Json).TrustServerCertificate | Should -BeFalse
	}

	It '$true: wieder vertrauen' {
		Set-sqmConfig -TrustServerCertificate $true
		Get-DbatoolsConfigValue -FullName 'sql.connection.trustcert' | Should -BeTrue
	}
}

Describe 'New-sqmCertificateRequest' {
	It 'Benannte Instanz ohne -Subject: Subject aus dem Hostteil' {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
		Mock -ModuleName sqmSQLTool Write-Host { }
		Mock -ModuleName sqmSQLTool Start-Process { [PSCustomObject]@{ ExitCode = 1 } }
		$r = New-sqmCertificateRequest -SqlInstance 'localhost\INST1' -OutputPath $TestDrive -Confirm:$false -WarningAction SilentlyContinue
		$r | Should -Not -BeNullOrEmpty
		$r.Subject | Should -Match '^CN=[^\\,]+,C=DE$'
		$r.SubjectAltNames | Should -Contain 'localhost'
	}
}
