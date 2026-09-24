#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Invoke-sqmDatabaseStandardization und den Aufruf aus Invoke-sqmRestoreDatabase.

.DESCRIPTION
    Geprueft wird vor allem, was NICHT passieren darf: kein ALTER an Secondary-, Offline- oder
    Read-only-Datenbanken, kein Absenken der Kompatibilitaetsstufe, kein DROP eines Windows-Users,
    der ueber einen Gruppen-Login Zugriff hat, und kein stilles Verschlucken eines gescheiterten
    DROP USER (der alte Restore-Schritt lief mit -ErrorAction SilentlyContinue).
    Die SQL-Haelfte ist zusaetzlich live gegen DEV01 (SQL 2022) geprueft.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	$env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmDatabaseStandardization - Vertrag' {

	It 'Funktion existiert und ist exportiert' {
		Get-Command Invoke-sqmDatabaseStandardization -Module sqmSQLTool | Should -Not -BeNullOrEmpty
	}

	It 'Unterstuetzt -WhatIf' {
		(Get-Command Invoke-sqmDatabaseStandardization).Parameters.ContainsKey('WhatIf') | Should -Be $true
	}

	It 'Jeder Schritt laesst sich einzeln abschalten' {
		$p = (Get-Command Invoke-sqmDatabaseStandardization).Parameters
		foreach ($name in 'SkipOrphanRepair', 'SkipUserRemoval', 'SkipCompatibilityLevel', 'SkipTargetRecoveryTime', 'SkipOwner')
		{
			$p.ContainsKey($name) | Should -Be $true -Because $name
		}
	}

	It 'TargetRecoveryTimeSeconds ist standardmaessig 60' {
		$source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmDatabaseStandardization.ps1" -Raw
		$source | Should -Match '\[int\]\$TargetRecoveryTimeSeconds = 60'
	}

	It 'DROP USER laeuft nicht mit SilentlyContinue' {
		$source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmDatabaseStandardization.ps1" -Raw
		$source | Should -Not -Match 'SilentlyContinue'
	}
}

Describe 'Invoke-sqmDatabaseStandardization - Verhalten' {

	BeforeEach {
		InModuleScope sqmSQLTool {
			$script:stdQueries = [System.Collections.Generic.List[string]]::new()
			$script:stdDbRow = [PSCustomObject]@{
				name = 'AppDb'; state_desc = 'ONLINE'; is_read_only = 0; compatibility_level = 130
				target_recovery_time_in_seconds = 0; owner_is_sa = 0; owner_name = 'olduser'; is_ag_secondary = 0
			}
			$script:stdCandidates = @()
			$script:stdOrphans = @()
			$script:stdLoginInfo = @()
			$script:stdDropFails = $false
		}
	}

	BeforeAll {
		InModuleScope sqmSQLTool {
			function script:Set-StdMocks
			{
				Mock Invoke-sqmLogging { }
				Mock Copy-sqmToCentralPath { }
				Mock Invoke-DbaQuery {
					$script:stdQueries.Add($Query)
					if ($Query -match 'MICROSOFTVERSION') { return [PSCustomObject]@{ ServerCompatibilityLevel = 160; SaName = 'sa' } }
					if ($Query -match 'FROM sys\.databases d') { return $script:stdDbRow }
					if ($Query -match 'AS MappedUser') { return $script:stdOrphans }
					if ($Query -match 'AS WindowsAccount') { return $script:stdCandidates }
					if ($Query -match 'xp_logininfo') { return $script:stdLoginInfo }
					if ($Query -match "SELECT 'Schema' AS Kind") { return @() }
					if ($Query -match 'DROP USER' -and $script:stdDropFails) { throw 'The database principal owns objects in the database and cannot be dropped.' }
					return $null
				}
			}
		}
	}

	It 'fuehrt an einer Standard-Datenbank alle fuenf Schritte aus' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdOrphans = @([PSCustomObject]@{ UserName = 'app'; LoginName = 'app'; MappedUser = $null })
			$script:stdCandidates = @([PSCustomObject]@{ UserName = 'gone'; UserType = 'S'; AuthType = 1; WindowsAccount = $null })

			$r = Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false

			($r | Where-Object Status -eq 'OK').Step | Should -Be @('FixOrphanUser', 'RemoveUserWithoutLogin', 'CompatibilityLevel', 'TargetRecoveryTime', 'DatabaseOwner')
			$script:stdQueries | Where-Object { $_ -match 'ALTER USER \[app\] WITH LOGIN = \[app\]' } | Should -Not -BeNullOrEmpty
			$script:stdQueries | Where-Object { $_ -match 'DROP USER \[gone\]' } | Should -Not -BeNullOrEmpty
			$script:stdQueries | Where-Object { $_ -match 'SET COMPATIBILITY_LEVEL = 160' } | Should -Not -BeNullOrEmpty
			$script:stdQueries | Where-Object { $_ -match 'SET TARGET_RECOVERY_TIME = 60 SECONDS' } | Should -Not -BeNullOrEmpty
			$script:stdQueries | Where-Object { $_ -match 'ALTER AUTHORIZATION ON DATABASE::\[AppDb\] TO \[sa\]' } | Should -Not -BeNullOrEmpty
		}
	}

	It 'fasst Secondary-, Offline- und Read-only-Datenbanken nicht an' -TestCases @(
		@{ Prop = 'is_ag_secondary'; Value = 1 }
		@{ Prop = 'state_desc'; Value = 'RESTORING' }
		@{ Prop = 'is_read_only'; Value = 1 }
	) {
		param ($Prop, $Value)
		InModuleScope sqmSQLTool -Parameters @{ Prop = $Prop; Value = $Value } {
			param ($Prop, $Value)
			Set-StdMocks
			$script:stdDbRow.$Prop = $Value

			$r = Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false

			@($r).Count | Should -Be 1
			$r.Status | Should -Be 'Skipped'
			$script:stdQueries | Where-Object { $_ -match 'ALTER |DROP ' } | Should -BeNullOrEmpty
		}
	}

	It 'senkt eine hoehere Kompatibilitaetsstufe nicht ab' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdDbRow.compatibility_level = 170

			$r = Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false

			($r | Where-Object Step -eq 'CompatibilityLevel').Status | Should -Be 'Skipped'
			$script:stdQueries | Where-Object { $_ -match 'COMPATIBILITY_LEVEL =' } | Should -BeNullOrEmpty
		}
	}

	It 'laesst WITHOUT-LOGIN-User standardmaessig stehen' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false | Out-Null
			$script:stdQueries | Where-Object { $_ -match 'AS WindowsAccount' } | Should -Match '\(0 = 1 AND dp\.authentication_type = 0'
		}
	}

	It 'bezieht WITHOUT-LOGIN-User mit -IncludeUsersWithoutLogin ein' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -IncludeUsersWithoutLogin -Confirm:$false | Out-Null
			$script:stdQueries | Where-Object { $_ -match 'AS WindowsAccount' } | Should -Match '\(1 = 1 AND dp\.authentication_type = 0'
		}
	}

	It 'entfernt keinen Windows-User, der ueber einen Gruppen-Login Zugriff hat' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdCandidates = @([PSCustomObject]@{ UserName = 'DOM\anna'; UserType = 'U'; AuthType = 3; WindowsAccount = 'DOM\anna' })
			$script:stdLoginInfo = @([PSCustomObject]@{ 'account name' = 'DOM\anna'; 'permission path' = 'DOM\SQL-Readers' })

			$r = Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false

			$row = $r | Where-Object Step -eq 'RemoveUserWithoutLogin'
			$row.Status | Should -Be 'Skipped'
			$row.Message | Should -Match 'DOM\\SQL-Readers'
			$script:stdQueries | Where-Object { $_ -match 'DROP USER' } | Should -BeNullOrEmpty
		}
	}

	It 'entfernt einen Windows-User, den Windows nicht mehr kennt' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdCandidates = @([PSCustomObject]@{ UserName = 'DOM\left'; UserType = 'U'; AuthType = 3; WindowsAccount = $null })

			$r = Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false

			($r | Where-Object Step -eq 'RemoveUserWithoutLogin').Status | Should -Be 'OK'
			Should -Invoke Invoke-DbaQuery -Times 0 -ParameterFilter { $Query -match 'xp_logininfo' }
		}
	}

	It 'meldet einen gescheiterten DROP USER als Failed statt ihn zu verschlucken' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdCandidates = @([PSCustomObject]@{ UserName = 'gone'; UserType = 'S'; AuthType = 1; WindowsAccount = $null })
			$script:stdDropFails = $true

			$r = Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false

			$row = $r | Where-Object Step -eq 'RemoveUserWithoutLogin'
			$row.Status | Should -Be 'Failed'
			$row.Message | Should -Match 'owns objects'
			# Die uebrigen Schritte laufen trotzdem
			($r | Where-Object Step -eq 'DatabaseOwner').Status | Should -Be 'OK'
		}
	}

	It 'wirft mit -EnableException bei einem gescheiterten DROP USER' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdCandidates = @([PSCustomObject]@{ UserName = 'gone'; UserType = 'S'; AuthType = 1; WindowsAccount = $null })
			$script:stdDropFails = $true

			{ Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -EnableException -Confirm:$false } |
				Should -Throw -ExpectedMessage '*owns objects*'
		}
	}

	It 'aendert unter -WhatIf nichts und meldet einen per Name reparierbaren User nicht als "wuerde entfernt"' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdOrphans = @([PSCustomObject]@{ UserName = 'app'; LoginName = 'app'; MappedUser = $null })
			# Ohne echte Reparatur taucht 'app' auch in der Kandidatenliste von Schritt 2 auf
			$script:stdCandidates = @([PSCustomObject]@{ UserName = 'app'; UserType = 'S'; AuthType = 1; WindowsAccount = $null })

			$r = Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -WhatIf

			$r | Where-Object Step -eq 'RemoveUserWithoutLogin' | Should -BeNullOrEmpty
			($r | Where-Object Step -eq 'FixOrphanUser').Status | Should -Be 'WhatIf'
			$script:stdQueries | Where-Object { $_ -match 'ALTER |DROP ' } | Should -BeNullOrEmpty
		}
	}

	It 'maskiert Namen mit ] und Hochkomma korrekt' {
		InModuleScope sqmSQLTool {
			Set-StdMocks
			$script:stdDbRow.name = "a]b'c"
			$script:stdCandidates = @([PSCustomObject]@{ UserName = "x]y'z"; UserType = 'S'; AuthType = 1; WindowsAccount = $null })

			Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -OutputPath $TestDrive -Confirm:$false | Out-Null

			$script:stdQueries | Where-Object { $_ -match [regex]::Escape("DROP USER [x]]y'z];") } | Should -Not -BeNullOrEmpty
			$script:stdQueries | Where-Object { $_ -match [regex]::Escape("DATABASE_PRINCIPAL_ID(N'x]y''z')") } | Should -Not -BeNullOrEmpty
			$script:stdQueries | Where-Object { $_ -match [regex]::Escape("ALTER DATABASE [a]]b'c] SET TARGET_RECOVERY_TIME") } | Should -Not -BeNullOrEmpty
		}
	}
}

Describe 'Invoke-sqmRestoreDatabase - Aufruf der Standardisierung' {

	It 'reicht -KeepCompatibilityLevel als -SkipCompatibilityLevel durch' {
		InModuleScope sqmSQLTool {
			$fakeBackup = Join-Path ([System.IO.Path]::GetTempPath()) 'sqmRestoreTest_std.bak'
			Set-Content -Path $fakeBackup -Value 'dummy' -Encoding Ascii

			Mock Invoke-sqmLogging { }
			Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01'; Databases = @{} } }
			Mock Get-sqmDatabaseAgMembership { [PSCustomObject]@{ IsAgDatabase = $false; HadrEnabled = $false } }
			Mock Invoke-DbaQuery { $null }
			Mock Restore-DbaDatabase { [PSCustomObject]@{ Database = 'amb'; RestoreComplete = $true } }
			Mock Invoke-sqmDatabaseStandardization {
				[PSCustomObject]@{ Step = 'CompatibilityLevel'; Target = 'amb'; OldValue = 130; NewValue = 160; Status = 'OK'; Message = 'Angehoben.' }
			}

			$result = Invoke-sqmRestoreDatabase -SqlInstance 'SQL01' -BackupFile $fakeBackup -DatabaseName 'amb' -KeepCompatibilityLevel -Confirm:$false

			Should -Invoke Invoke-sqmDatabaseStandardization -Times 1 -ParameterFilter { $Database -eq 'amb' -and $SkipCompatibilityLevel }
			($result | Where-Object Action -eq 'CompatibilityLevel').Status | Should -Be 'Success'

			Remove-Item $fakeBackup -ErrorAction SilentlyContinue
		}
	}

	It 'loest den Aufruf nur mit -DatabaseName (Backup aus der Historie) auf den Satz FromHistory auf' {
		# Regression 1.9.149.0: DefaultParameterSetName stand auf SingleFile, der dokumentierte Aufruf
		# scheiterte beim Parameter-Binding am fehlenden -BackupFile.
		$cmd = Get-Command Invoke-sqmRestoreDatabase
		$cmd.DefaultParameterSet | Should -Be 'FromHistory'
	}
}
