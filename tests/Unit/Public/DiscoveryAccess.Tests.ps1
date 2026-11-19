#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Discovery-Konto-Funktionen: Get-sqmDiscoveryDefinition (privat),
    Install-sqmDiscoveryRole, Set-sqmDiscoveryWmiAccess und der Abgleich in Test-sqmDiscoveryAccess
    (Rollen-Drift gegen die Standarddefinition, -CheckWmi).
    Die T-SQL-Seite (Rolle, GRANTs, Abfragen als Mitglied) ist zusaetzlich live gegen SQL Server 2022
    geprueft. Der WMI-Teil laeuft hier nur gemockt: das Setzen von Namespace-Rechten braucht lokale
    Administratorrechte auf dem Zielrechner.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
	$script:TestDir = New-TempTestDirectory
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmDiscoveryDefinition' {
	It 'verwendet bis SQL 2019 VIEW SERVER STATE' {
		InModuleScope sqmSQLTool {
			$d = Get-sqmDiscoveryDefinition -MajorVersion 15
			$d.ServerPermissions | Should -Contain 'VIEW SERVER STATE'
			$d.ServerPermissions | Should -Not -Contain 'VIEW SERVER PERFORMANCE STATE'
		}
	}

	It 'verwendet ab SQL 2022 das feinere VIEW SERVER PERFORMANCE STATE' {
		InModuleScope sqmSQLTool {
			$d = Get-sqmDiscoveryDefinition -MajorVersion 16
			$d.ServerPermissions | Should -Contain 'VIEW SERVER PERFORMANCE STATE'
			$d.ServerPermissions | Should -Not -Contain 'VIEW SERVER STATE'
		}
	}

	It 'enthaelt immer VIEW ANY DEFINITION und VIEW ANY DATABASE, aber kein sysadmin-artiges Recht' {
		InModuleScope sqmSQLTool {
			$d = Get-sqmDiscoveryDefinition -MajorVersion 16
			$d.ServerPermissions | Should -Contain 'VIEW ANY DEFINITION'
			$d.ServerPermissions | Should -Contain 'VIEW ANY DATABASE'
			($d.ServerPermissions -join ' ') | Should -Not -Match 'CONTROL|ALTER|IMPERSONATE'
			$d.RoleName | Should -Be 'SQL_ServiceNow_Discovery'
		}
	}

	It 'fordert Enable Account plus Remote Enable (0x21), Execute Methods nicht' {
		InModuleScope sqmSQLTool {
			$d = Get-sqmDiscoveryDefinition
			$d.WmiAccessMask | Should -Be 0x21
			($d.WmiAccessMask -band $d.WmiMethodExecute) | Should -Be 0
		}
	}
}

Describe 'Get-sqmDiscoveryHostName' {
	It 'liefert den Rechnernamen aus <Instance>' -ForEach @(
		@{ Instance = 'SQL01'; Expected = 'SQL01' }
		@{ Instance = 'SQL01\INST1'; Expected = 'SQL01' }
		@{ Instance = 'SQL01,1433'; Expected = 'SQL01' }
		@{ Instance = 'tcp:SQL01,1433'; Expected = 'SQL01' }
	) {
		InModuleScope sqmSQLTool -Parameters @{ Instance = $Instance; Expected = $Expected } {
			Get-sqmDiscoveryHostName -SqlInstance $Instance | Should -Be $Expected
		}
	}

	It 'loest localhost auf den lokalen Rechnernamen auf' {
		InModuleScope sqmSQLTool {
			Get-sqmDiscoveryHostName -SqlInstance 'localhost' | Should -Be $env:COMPUTERNAME
			Get-sqmDiscoveryHostName -SqlInstance '.\SQLEXPRESS' | Should -Be $env:COMPUTERNAME
		}
	}
}

Describe 'Install-sqmDiscoveryRole' {
	BeforeEach {
		InModuleScope sqmSQLTool {
			$script:dbatoolsAvailable = $true
			$script:queries = [System.Collections.Generic.List[string]]::new()
			Mock Invoke-sqmLogging { }
			Mock Invoke-DbaQuery {
				$script:queries.Add([string]$Query)
				if ($Query -match 'ProductMajorVersion') { return [PSCustomObject]@{ MajorVersion = 16 } }
				if ($Query -match 'RoleExists') { return [PSCustomObject]@{ RoleExists = $script:fakeRoleExists; LoginExists = $script:fakeLoginExists; IsMember = $script:fakeIsMember } }
			}
			$script:fakeRoleExists = 0; $script:fakeLoginExists = 0; $script:fakeIsMember = 0
		}
	}

	It 'legt Rolle, Rechte, Login und Mitgliedschaft an' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow'
			$r.Status | Should -Be 'OK'
			$r.RoleCreated | Should -BeTrue
			$r.LoginCreated | Should -BeTrue
			$r.MemberAdded | Should -BeTrue
			$sql = $script:queries -join "`n"
			$sql | Should -Match 'CREATE SERVER ROLE \[SQL_ServiceNow_Discovery\]'
			$sql | Should -Match 'GRANT VIEW ANY DEFINITION TO \[SQL_ServiceNow_Discovery\]'
			$sql | Should -Match 'GRANT VIEW ANY DATABASE TO \[SQL_ServiceNow_Discovery\]'
			$sql | Should -Match 'GRANT VIEW SERVER PERFORMANCE STATE TO \[SQL_ServiceNow_Discovery\]'
			$sql | Should -Match 'CREATE LOGIN \[CORP\\svc_snow\] FROM WINDOWS'
			$sql | Should -Match 'ADD MEMBER \[CORP\\svc_snow\]'
		}
	}

	It 'ist idempotent: vorhandene Rolle, Login und Mitgliedschaft werden nicht erneut angelegt' {
		InModuleScope sqmSQLTool {
			$script:fakeRoleExists = 1; $script:fakeLoginExists = 1; $script:fakeIsMember = 1
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow'
			$r.Status | Should -Be 'OK'
			$r.RoleCreated | Should -BeFalse
			$r.LoginCreated | Should -BeFalse
			$r.MemberAdded | Should -BeFalse
			($script:queries -join "`n") | Should -Not -Match 'CREATE SERVER ROLE|CREATE LOGIN|ADD MEMBER'
			# die GRANTs laufen trotzdem, damit ein spaeter entzogenes Recht wiederkommt
			($script:queries -join "`n") | Should -Match 'GRANT VIEW ANY DEFINITION'
		}
	}

	It 'aendert mit -WhatIf nichts' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -WhatIf
			$r.Status | Should -Be 'WhatIf'
			($script:queries -join "`n") | Should -Not -Match 'CREATE|GRANT|ALTER'
		}
	}

	It 'legt ein fehlendes SQL-Login nicht an (Name nicht als Windows-Konto aufloesbar)' {
		InModuleScope sqmSQLTool {
			Mock Resolve-sqmDiscoveryLoginName { $null }
			{ Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'snow_sql' } |
				Should -Throw -ExpectedMessage "*nicht als Windows-Konto aufloesen*"
			($script:queries -join "`n") | Should -Not -Match 'CREATE LOGIN'
		}
	}

	It 'loest einen Namen ohne Domaene auf und legt das Windows-Login an' {
		InModuleScope sqmSQLTool {
			Mock Resolve-sqmDiscoveryLoginName { 'CORP\svc_snow' }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'svc_snow'
			$r.Status | Should -Be 'OK'
			$r.LoginCreated | Should -BeTrue
			$r.LoginName | Should -Be 'CORP\svc_snow'
			$sql = $script:queries -join "`n"
			$sql | Should -Match 'CREATE LOGIN \[CORP\\svc_snow\] FROM WINDOWS'
			$sql | Should -Match 'ADD MEMBER \[CORP\\svc_snow\]'
		}
	}

	It 'schneidet Leerzeichen am Rand des Kontonamens ab' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow '
			$r.Status | Should -Be 'OK'
			($script:queries -join "`n") | Should -Match 'CREATE LOGIN \[CORP\\svc_snow\] FROM WINDOWS'
		}
	}

	It 'laesst ] im Rollennamen nicht zu, damit er nie in das T-SQL gelangt' {
		InModuleScope sqmSQLTool {
			{ Install-sqmDiscoveryRole -SqlInstance 'SQL01' -RoleName 'a]b' } |
				Should -Throw -ExpectedMessage "*RoleName*"
		}
	}
}

Describe 'Set-sqmDiscoveryWmiAccess' {
	BeforeEach {
		InModuleScope sqmSQLTool {
			Mock Invoke-sqmLogging { }
			$script:sid = [PSCustomObject]@{ Sid = [System.Security.Principal.SecurityIdentifier]'S-1-5-21-1-2-3-1001'; Binary = [byte[]](1, 2, 3) }
			Mock Get-sqmDiscoveryAccountSid { $script:sid }
			Mock Open-sqmDiscoveryCimSession { $null }
			Mock Get-sqmDiscoveryWmiNamespaceList { @('Root\CIMv2', 'Root\Microsoft\SqlServer\ComputerManagement16') }
			Mock Get-sqmDiscoveryWmiAccessMask { $script:currentMask }
			Mock Write-sqmDiscoveryWmiAccessEntry { }
			Mock Test-sqmDiscoveryDcomMember { $script:isMember }
			Mock Get-sqmDiscoveryDcomGroup { $g = New-Object psobject; $g | Add-Member ScriptMethod Add { param ($m) $script:added = $m }; $g | Add-Member ScriptMethod Remove { param ($m) $script:removed = $m }; $g }
			Mock Get-sqmDiscoveryWmiState {
				[PSCustomObject]@{
					ComputerName = 'SQL01'; DcomMember = $script:isMember; RemoteRegistryState = 'Stopped'; RemoteRegistryStart = 'Disabled'
					Namespaces = @(
						[PSCustomObject]@{ Namespace = 'Root\CIMv2'; AccessMask = $script:currentMask; Required = 0x21; Ok = ($script:currentMask -eq 0x21) }
						[PSCustomObject]@{ Namespace = 'Root\Microsoft\SqlServer\ComputerManagement16'; AccessMask = $script:currentMask; Required = 0x21; Ok = ($script:currentMask -eq 0x21) }
					)
					Ok = ($script:isMember -and $script:currentMask -eq 0x21)
				}
			}
			$script:currentMask = $null; $script:isMember = $false; $script:added = $null; $script:removed = $null
		}
	}

	It 'Check aendert nichts und meldet Fehler, wenn Rechte fehlen' {
		InModuleScope sqmSQLTool {
			$r = Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -ComputerName 'SQL01'
			$r.Mode | Should -Be 'Check'
			$r.Status | Should -Be 'Fehler'
			$r.Ok | Should -BeFalse
			$r.Message | Should -Match 'WMI fehlt auf'
			$r.Message | Should -Match 'Distributed COM Users'
			Should -Invoke Write-sqmDiscoveryWmiAccessEntry -Times 0 -Exactly
			$script:added | Should -BeNullOrEmpty
		}
	}

	It 'Apply setzt beide Namespaces und die DCOM-Mitgliedschaft' {
		InModuleScope sqmSQLTool {
			$r = Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -ComputerName 'SQL01' -Mode Apply
			$r.Changed | Should -Be 3
			Should -Invoke Write-sqmDiscoveryWmiAccessEntry -Times 2 -Exactly -ParameterFilter { $Action -eq 'Apply' -and $AccessMask -eq 0x21 }
			$script:added | Should -Be 'WinNT://CORP/svc_snow'
		}
	}

	It 'Apply ist idempotent, wenn alles schon gesetzt ist' {
		InModuleScope sqmSQLTool {
			$script:currentMask = [uint32]0x21; $script:isMember = $true
			$r = Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -ComputerName 'SQL01' -Mode Apply
			$r.Changed | Should -Be 0
			$r.Status | Should -Be 'OK'
			Should -Invoke Write-sqmDiscoveryWmiAccessEntry -Times 0 -Exactly
		}
	}

	It 'Apply -WhatIf aendert nichts' {
		InModuleScope sqmSQLTool {
			$r = Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -ComputerName 'SQL01' -Mode Apply -WhatIf
			$r.Status | Should -Be 'WhatIf'
			Should -Invoke Write-sqmDiscoveryWmiAccessEntry -Times 0 -Exactly
			$script:added | Should -BeNullOrEmpty
		}
	}

	It '-AllowExecuteMethods fordert 0x23' {
		InModuleScope sqmSQLTool {
			Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -ComputerName 'SQL01' -Mode Apply -AllowExecuteMethods | Out-Null
			Should -Invoke Write-sqmDiscoveryWmiAccessEntry -Times 2 -Exactly -ParameterFilter { $AccessMask -eq 0x23 }
		}
	}

	It 'Remove nimmt Namespace-Rechte und DCOM-Mitgliedschaft zurueck' {
		InModuleScope sqmSQLTool {
			$script:currentMask = [uint32]0x21; $script:isMember = $true
			Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -ComputerName 'SQL01' -Mode Remove | Out-Null
			Should -Invoke Write-sqmDiscoveryWmiAccessEntry -Times 2 -Exactly -ParameterFilter { $Action -eq 'Remove' }
			$script:removed | Should -Be 'WinNT://CORP/svc_snow'
		}
	}

	It 'meldet den Remote-Registry-Zustand als Hinweis, ohne ihn zu aendern' {
		InModuleScope sqmSQLTool {
			$r = Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -ComputerName 'SQL01'
			$r.RemoteRegistryStart | Should -Be 'Disabled'
			$r.Message | Should -Match 'Remote Registry'
		}
	}
}

Describe 'Test-sqmDiscoveryAccess - Abgleich mit der Standarddefinition' {
	BeforeEach {
		InModuleScope sqmSQLTool {
			$script:dbatoolsAvailable = $true
			Mock Invoke-sqmLogging { }
			$script:row = [PSCustomObject]@{
				MajorVersion = 16; ProductVersion = '16.0.1000.6'; Edition = 'Developer'
				LoginExists = 1; LoginType = 'WINDOWS_LOGIN'; IsDisabled = 0; DenyConnectSql = 0; IsSysadmin = 0
				RoleExists = 1; InServerRole = 1; PublicViewAnyDb = 1
				ViewAnyDatabase = 1; ViewAnyDefinition = 1; ViewServerState = 1
				RoleGrants = 'VIEW ANY DATABASE, VIEW ANY DEFINITION, VIEW SERVER PERFORMANCE STATE'
				GrantedPermissions = 'VIEW ANY DATABASE, VIEW ANY DEFINITION, VIEW SERVER PERFORMANCE STATE'; ServerRoles = 'SQL_ServiceNow_Discovery'
			}
			Mock Invoke-DbaQuery { $script:row }
		}
	}

	It 'meldet OK, wenn die Standardrolle vollstaendig ist' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SQL_ServiceNow_Discovery' `
				-RequiredLevel Full -OutputPath $Out -NoOpen
			$r.Status | Should -Be 'OK'
			$r.RoleMissingPermissions.Count | Should -Be 0
		}
	}

	It 'findet ein nachtraeglich entzogenes Recht der Standardrolle' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$script:row.RoleGrants = 'VIEW ANY DATABASE, VIEW SERVER PERFORMANCE STATE'
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SQL_ServiceNow_Discovery' -OutputPath $Out -NoOpen
			$r.RoleMissingPermissions | Should -Contain 'VIEW ANY DEFINITION'
			($r.Findings -join ' ') | Should -Match 'nicht mehr alle Standardrechte'
			$r.Status | Should -Be 'Warnung'
		}
	}

	It 'akzeptiert VIEW SERVER STATE als Ersatz fuer VIEW SERVER PERFORMANCE STATE' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$script:row.RoleGrants = 'VIEW ANY DATABASE, VIEW ANY DEFINITION, VIEW SERVER STATE'
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SQL_ServiceNow_Discovery' -OutputPath $Out -NoOpen
			$r.RoleMissingPermissions.Count | Should -Be 0
		}
	}

	It 'vergleicht eine andere Rolle (z. B. SQL_Inventory_RO_Basic) nicht gegen die Standarddefinition' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$script:row.RoleGrants = ''
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SQL_Inventory_RO_Basic' -OutputPath $Out -NoOpen
			$r.RoleMissingPermissions.Count | Should -Be 0
		}
	}

	It 'prueft WMI nur mit -CheckWmi' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			Mock Get-sqmDiscoveryWmiState { }
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -OutputPath $Out -NoOpen
			$r.WmiChecked | Should -BeFalse
			Should -Invoke Get-sqmDiscoveryWmiState -Times 0 -Exactly
		}
	}

	It '-CheckWmi nimmt den Host aus dem Instanznamen und wertet fehlende WMI-Rechte als Fehler' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			Mock Get-sqmDiscoveryWmiState {
				[PSCustomObject]@{
					ComputerName = 'SQL01'; DcomMember = $false; RemoteRegistryState = 'Running'; RemoteRegistryStart = 'Auto'
					Namespaces = @([PSCustomObject]@{ Namespace = 'Root\CIMv2'; AccessMask = $null; Required = 0x21; Ok = $false })
					Ok = $false
				}
			}
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01\INST1' -LoginName 'CORP\svc_snow' -CheckWmi -OutputPath $Out -NoOpen
			Should -Invoke Get-sqmDiscoveryWmiState -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'SQL01' }
			$r.WmiChecked | Should -BeTrue
			$r.WmiOk | Should -BeFalse
			$r.Status | Should -Be 'Fehler'
			($r.Findings -join ' ') | Should -Match 'Root\\CIMv2'
			($r.Findings -join ' ') | Should -Match 'Distributed COM Users'
		}
	}

	It '-CheckWmi meldet OK, wenn SQL und WMI stimmen' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			Mock Get-sqmDiscoveryWmiState {
				[PSCustomObject]@{
					ComputerName = 'SQL01'; DcomMember = $true; RemoteRegistryState = 'Running'; RemoteRegistryStart = 'Auto'
					Namespaces = @([PSCustomObject]@{ Namespace = 'Root\CIMv2'; AccessMask = 0x21; Required = 0x21; Ok = $true })
					Ok = $true
				}
			}
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SQL_ServiceNow_Discovery' -RequiredLevel Full -CheckWmi -OutputPath $Out -NoOpen
			$r.WmiOk | Should -BeTrue
			$r.Status | Should -Be 'OK'
		}
	}

	It '-CheckWmi: eine nicht erreichbare WMI-Seite wird als Befund gemeldet, nicht als Absturz' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			Mock Get-sqmDiscoveryWmiState { throw 'Zugriff verweigert.' }
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -CheckWmi -OutputPath $Out -NoOpen
			$r.WmiOk | Should -BeFalse
			($r.Findings -join ' ') | Should -Match 'nicht moeglich: Zugriff verweigert'
			$r.Status | Should -Be 'Fehler'
		}
	}
}
