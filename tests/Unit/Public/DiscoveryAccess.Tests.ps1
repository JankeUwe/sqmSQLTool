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
			$d.RoleName | Should -Be 'SNOWDISCO'
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

Describe 'Get-sqmDiscoveryDefinition - Produkte' {
	It 'Qualys fordert ALTER TRACE, VIEW SERVER STATE, VIEW ANY DEFINITION und die Katalogsichten aus Schritt 3b' {
		InModuleScope sqmSQLTool {
			foreach ($major in 14, 16, 17)
			{
				$d = Get-sqmDiscoveryDefinition -Product Qualys -MajorVersion $major
				$d.RoleName | Should -Be 'Qualis_Scan'
				$d.ServerPermissions | Should -Be @('ALTER TRACE', 'VIEW SERVER STATE', 'VIEW ANY DEFINITION')
			}
			$master = (Get-sqmDiscoveryDefinition -Product Qualys).DatabaseGrants | Where-Object Database -eq 'master'
			foreach ($v in 'all_objects', 'configurations', 'databases', 'database_permissions', 'syslogins', 'trace_events', 'traces', 'sysaltfiles', 'server_principals')
			{
				$master.Grants | Should -Contain "SELECT ON sys.$v"
			}
			$master.Grants | Should -Contain 'EXECUTE ON sys.xp_loginconfig'
		}
	}

	It 'SCOM fordert die drei Serverrechte, die Agent-Rechte in master und msdb und SQLAgentReaderRole' {
		InModuleScope sqmSQLTool {
			$d = Get-sqmDiscoveryDefinition -Product SCOM
			$d.RoleName | Should -Be 'SCOM_HealthService'
			$d.ServerPermissions | Should -Be @('VIEW ANY DATABASE', 'VIEW ANY DEFINITION', 'VIEW SERVER STATE')
			$d.DatabaseScope | Should -Be 'Eligible'
			$d.MsdbRoleMembership | Should -Be @('SQLAgentReaderRole')
			(($d.DatabaseGrants | Where-Object Database -eq 'msdb').Grants).Count | Should -Be 15
		}
	}

	It 'ServiceNow hat keine Datenbankrechte und bleibt bei den drei Serverrechten' {
		InModuleScope sqmSQLTool {
			$d = Get-sqmDiscoveryDefinition -Product ServiceNow -MajorVersion 15
			$d.RoleName | Should -Be 'SNOWDISCO'
			$d.DatabaseGrants.Count | Should -Be 0
			$d.DatabaseScope | Should -Be 'None'
		}
	}

	It 'die Auswahlliste von -RoleName stimmt mit der Produktliste ueberein' {
		InModuleScope sqmSQLTool {
			$attr = (Get-Command Install-sqmDiscoveryRole).Parameters['RoleName'].Attributes | Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] }
			$offered = & $attr.ScriptBlock 'x' 'RoleName' '' $null $null
			@($offered | Sort-Object) | Should -Be @((Get-sqmDiscoveryProductList).RoleName | Sort-Object)
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
			Mock Get-sqmDiscoveryPolicyBlocker { $null }
			Mock Set-sqmDiscoveryWmiAccess { [PSCustomObject]@{ Status = 'OK'; Message = 'WMI/DCOM vollstaendig' } }
			Mock Test-sqmDiscoveryAccess { [PSCustomObject]@{ Status = 'OK'; DiscoveryLevel = 'Full'; MeetsRequirement = $true; Findings = @() } }
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
			$sql | Should -Match 'CREATE SERVER ROLE \[SNOWDISCO\]'
			$sql | Should -Match 'GRANT VIEW ANY DEFINITION TO \[SNOWDISCO\]'
			$sql | Should -Match 'GRANT VIEW ANY DATABASE TO \[SNOWDISCO\]'
			$sql | Should -Match 'GRANT VIEW SERVER PERFORMANCE STATE TO \[SNOWDISCO\]'
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

	It 'bietet die drei Produkte mit festen Rollennamen an' {
		InModuleScope sqmSQLTool {
			$p = Get-sqmDiscoveryProductList
			($p | Where-Object Product -eq 'ServiceNow').RoleName | Should -Be 'SNOWDISCO'
			($p | Where-Object Product -eq 'Qualys').RoleName | Should -Be 'Qualis_Scan'
			($p | Where-Object Product -eq 'SCOM').RoleName | Should -Be 'SCOM_HealthService'
		}
	}

	It 'leitet das Produkt aus einem angebotenen Rollennamen ab' {
		InModuleScope sqmSQLTool {
			(Install-sqmDiscoveryRole -SqlInstance 'SQL01' -RoleName 'Qualis_Scan' -Confirm:$false).Product | Should -Be 'Qualys'
			(Install-sqmDiscoveryRole -SqlInstance 'SQL01' -RoleName 'SCOM_HealthService' -Confirm:$false).Product | Should -Be 'SCOM'
			(Install-sqmDiscoveryRole -SqlInstance 'SQL01' -RoleName 'SNOWDISCO' -Confirm:$false).Product | Should -Be 'ServiceNow'
		}
	}

	It 'nimmt ohne Produkt und ohne Rollennamen ServiceNow mit SNOWDISCO' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Confirm:$false
			$r.Product | Should -Be 'ServiceNow'
			$r.RoleName | Should -Be 'SNOWDISCO'
		}
	}

	It 'erlaubt einen freien Rollennamen mit den Rechten des gewaehlten Produkts' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product Qualys -RoleName 'Scan_Compliance' -Confirm:$false
			$r.Product | Should -Be 'Qualys'
			$r.RoleName | Should -Be 'Scan_Compliance'
			$sql = $script:queries -join "`n"
			$sql | Should -Match 'GRANT ALTER TRACE TO \[Scan_Compliance\]'
			$sql | Should -Match 'GRANT SELECT ON sys.traces TO \[Scan_Compliance\]'
			$sql | Should -Not -Match 'Qualis_Scan'
		}
	}

	It 'Qualys: Serverrechte, master- und msdb-Rechte der Datenbankrolle, Benutzer und Mitgliedschaft' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product Qualys -LoginName 'CORP\QUALYS_SCAN' -Confirm:$false
			$r.Status | Should -Be 'OK'
			$r.DatabasesConfigured | Should -Be @('master', 'msdb')
			$sql = $script:queries -join "`n"
			$sql | Should -Match 'GRANT ALTER TRACE TO \[Qualis_Scan\]'
			$sql | Should -Match 'GRANT VIEW SERVER STATE TO \[Qualis_Scan\]'
			$sql | Should -Match 'GRANT VIEW ANY DEFINITION TO \[Qualis_Scan\]'
			$sql | Should -Match 'GRANT SELECT ON sys.trace_events TO \[Qualis_Scan\]'
			$sql | Should -Match 'GRANT EXECUTE ON sys.xp_loginconfig TO \[Qualis_Scan\]'
			$sql | Should -Match 'GRANT EXECUTE ON dbo.sp_enum_login_for_proxy TO \[Qualis_Scan\]'
			$sql | Should -Match 'GRANT SELECT ON dbo.sysproxylogin TO \[Qualis_Scan\]'
			$sql | Should -Match 'CREATE USER \[CORP\\QUALYS_SCAN\] FOR LOGIN \[CORP\\QUALYS_SCAN\]'
			$sql | Should -Match 'ALTER ROLE \[Qualis_Scan\] ADD MEMBER \[CORP\\QUALYS_SCAN\]'
			$sql | Should -Not -Match 'VIEW ANY DATABASE'
		}
	}

	It 'SCOM: msdb-Rechte, SQLAgentReaderRole und Benutzer in jeder zulaessigen Datenbank' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				$script:queries.Add([string]$Query)
				if ($Query -match 'ProductMajorVersion') { return [PSCustomObject]@{ MajorVersion = 16 } }
				if ($Query -match 'RoleExists') { return [PSCustomObject]@{ RoleExists = 0; LoginExists = 1; IsMember = 0 } }
				if ($Query -match 'hadrstate') { return @([PSCustomObject]@{ name = 'master' }, [PSCustomObject]@{ name = 'msdb' }, [PSCustomObject]@{ name = 'Shop' }) }
			}
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product SCOM -LoginName 'CORP\svc_scom' -Confirm:$false
			$r.Status | Should -Be 'OK'
			$r.DatabasesConfigured | Should -Be @('master', 'msdb', 'Shop')
			$sql = $script:queries -join "`n"
			$sql | Should -Match 'GRANT EXECUTE ON sys.xp_readerrorlog TO \[SCOM_HealthService\]'
			$sql | Should -Match 'GRANT SELECT ON dbo.sysjobhistory TO \[SCOM_HealthService\]'
			$sql | Should -Match 'GRANT EXECUTE ON dbo.sp_help_job TO \[SCOM_HealthService\]'
			$sql | Should -Match 'ALTER ROLE \[SQLAgentReaderRole\] ADD MEMBER \[SCOM_HealthService\]'
			# Shop bekommt Benutzer und Rolle, aber keine der master-/msdb-GRANTs
			@($script:queries | Where-Object { $_ -match 'CREATE ROLE \[SCOM_HealthService\]' }).Count | Should -Be 3
		}
	}

	It 'ein GRANT auf ein fehlendes Objekt verhindert die uebrigen Rechte nicht und wird als Warnung gemeldet' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				$script:queries.Add([string]$Query)
				if ($Query -match 'ProductMajorVersion') { return [PSCustomObject]@{ MajorVersion = 16 } }
				if ($Query -match 'RoleExists') { return [PSCustomObject]@{ RoleExists = 0; LoginExists = 0; IsMember = 0 } }
				if ($Query -match 'GRANT SELECT ON dbo.sysproxies ') { throw 'Cannot find the object sysproxies' }
			}
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product Qualys -Confirm:$false
			$r.Status | Should -Be 'Warnung'
			@($r.Warnings).Count | Should -Be 1
			$r.Warnings[0] | Should -Match 'sysproxies'
			($script:queries -join "`n") | Should -Match 'GRANT SELECT ON dbo.sysproxylogin'
		}
	}

	It 'schaltet bei einer blockierenden PBM-Policy den Trigger nur fuer die Einrichtung ab und danach wieder an' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmDiscoveryPolicyBlocker { [PSCustomObject]@{ Policies = @('Login Policy'); TriggerActive = $true; Blocking = $true } }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Confirm:$false
			$r.Status | Should -Be 'OK'
			$r.BlockingPolicies | Should -Be @('Login Policy')
			$r.PolicyTriggerDisabled | Should -BeTrue
			$idxOff = [array]::FindIndex($script:queries.ToArray(), [Predicate[string]] { param ($q) $q -match 'DISABLE TRIGGER \[syspolicy_server_trigger\]' })
			$idxRole = [array]::FindIndex($script:queries.ToArray(), [Predicate[string]] { param ($q) $q -match 'CREATE SERVER ROLE' })
			$idxOn = [array]::FindIndex($script:queries.ToArray(), [Predicate[string]] { param ($q) $q -match '^ENABLE TRIGGER \[syspolicy_server_trigger\]' })
			$idxOff | Should -BeGreaterOrEqual 0
			$idxOff | Should -BeLessThan $idxRole
			$idxOn | Should -BeGreaterThan $idxRole
		}
	}

	It 'schaltet den PBM-Trigger auch nach einem Fehler wieder an' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmDiscoveryPolicyBlocker { [PSCustomObject]@{ Policies = @('Login Policy'); TriggerActive = $true; Blocking = $true } }
			Mock Invoke-DbaQuery {
				$script:queries.Add([string]$Query)
				if ($Query -match 'ProductMajorVersion') { return [PSCustomObject]@{ MajorVersion = 16 } }
				if ($Query -match 'RoleExists') { return [PSCustomObject]@{ RoleExists = 0; LoginExists = 0; IsMember = 0 } }
				if ($Query -match 'CREATE SERVER ROLE') { throw 'The transaction ended in the trigger. The batch has been aborted.' }
			}
			{ Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Confirm:$false } | Should -Throw -ExpectedMessage '*transaction ended in the trigger*'
			@($script:queries | Where-Object { $_ -match '^ENABLE TRIGGER \[syspolicy_server_trigger\]' }).Count | Should -Be 1
		}
	}

	It 'fasst PBM nicht an, wenn der Trigger nicht aktiv ist, meldet aber die Policies' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmDiscoveryPolicyBlocker { [PSCustomObject]@{ Policies = @('Login Policy'); TriggerActive = $false; Blocking = $false } }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Confirm:$false
			$r.BlockingPolicies | Should -Be @('Login Policy')
			$r.PolicyTriggerDisabled | Should -BeFalse
			($script:queries -join "`n") | Should -Not -Match 'TRIGGER'
		}
	}

	It 'fasst PBM mit -SkipPolicyHandling nicht an und fragt es nicht einmal ab' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmDiscoveryPolicyBlocker { [PSCustomObject]@{ Policies = @('P'); TriggerActive = $true; Blocking = $true } }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -SkipPolicyHandling -Confirm:$false
			$r.PolicyTriggerDisabled | Should -BeFalse
			($script:queries -join "`n") | Should -Not -Match 'TRIGGER'
			Should -Invoke Get-sqmDiscoveryPolicyBlocker -Times 0
		}
	}

	It 'ServiceNow: setzt die WMI/DCOM-Seite gleich mit, auf dem Host der Instanz' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01\INST1' -LoginName 'CORP\svc_snow' -Confirm:$false
			$r.Status | Should -Be 'OK'
			$r.WmiStatus | Should -Be 'OK'
			Should -Invoke Set-sqmDiscoveryWmiAccess -Times 1 -Exactly -ParameterFilter { $Account -eq 'CORP\svc_snow' -and $Mode -eq 'Apply' -and $ComputerName -eq 'SQL01' }
		}
	}

	It 'Qualys und SCOM: WMI nur mit -Wmi Apply' {
		InModuleScope sqmSQLTool {
			Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product Qualys -LoginName 'CORP\q' -Confirm:$false | Out-Null
			Should -Invoke Set-sqmDiscoveryWmiAccess -Times 0 -Exactly
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product Qualys -LoginName 'CORP\q' -Wmi Apply -Confirm:$false
			$r.WmiStatus | Should -Be 'OK'
			Should -Invoke Set-sqmDiscoveryWmiAccess -Times 1 -Exactly
		}
	}

	It '-Wmi Skip laesst die WMI-Seite aus, auch bei ServiceNow' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -Wmi Skip -Confirm:$false
			$r.WmiStatus | Should -Be 'NotRun'
			Should -Invoke Set-sqmDiscoveryWmiAccess -Times 0 -Exactly
		}
	}

	It 'ein WMI-Fehler nimmt die SQL-Rechte nicht zurueck und erscheint als Warnung' {
		InModuleScope sqmSQLTool {
			Mock Set-sqmDiscoveryWmiAccess { throw 'Zugriff verweigert' }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -Confirm:$false
			$r.Status | Should -Be 'Warnung'
			$r.WmiStatus | Should -Be 'Error'
			($r.Warnings -join ' ') | Should -Match 'Zugriff verweigert'
			$r.Granted | Should -Contain 'VIEW ANY DEFINITION'
			$r.MemberAdded | Should -BeTrue
		}
	}

	It 'ohne -LoginName gibt es keine WMI-Rechte zu setzen' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Confirm:$false
			$r.WmiStatus | Should -Be 'Skipped'
			Should -Invoke Set-sqmDiscoveryWmiAccess -Times 0 -Exactly
		}
	}

	It 'ein Name ohne Domaene wird zuerst auf dem Server gesucht, ein vorhandenes Login wird nicht noch einmal angelegt' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				$script:queries.Add([string]$Query)
				if ($Query -match 'ProductMajorVersion') { return [PSCustomObject]@{ MajorVersion = 15 } }
				if ($Query -match 'RIGHT\(name') { return [PSCustomObject]@{ name = 'CORP\svc_snow' } }
				if ($Query -match 'RoleExists') { return [PSCustomObject]@{ RoleExists = 1; LoginExists = 1; IsMember = 0 } }
			}
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'svc_snow' -Confirm:$false
			$r.LoginName | Should -Be 'CORP\svc_snow'
			$r.LoginCreated | Should -BeFalse
			$r.MemberAdded | Should -BeTrue
			($script:queries -join "`n") | Should -Not -Match 'CREATE LOGIN'
			($script:queries -join "`n") | Should -Match 'ADD MEMBER \[CORP\\svc_snow\]'
		}
	}

	It 'ein mehrdeutiger Name ohne Domaene bricht ab und raet nicht' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				$script:queries.Add([string]$Query)
				if ($Query -match 'ProductMajorVersion') { return [PSCustomObject]@{ MajorVersion = 15 } }
				if ($Query -match 'RIGHT\(name') { return @([PSCustomObject]@{ name = 'A\svc_snow' }, [PSCustomObject]@{ name = 'B\svc_snow' }) }
			}
			{ Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'svc_snow' -Confirm:$false } |
				Should -Throw -ExpectedMessage '*nicht eindeutig*A\svc_snow, B\svc_snow*'
			($script:queries -join "`n") | Should -Not -Match 'CREATE LOGIN|ADD MEMBER'
		}
	}

	It 'prueft nach dem Setzen automatisch, mit Rolle, Produkt, Stufe Full und -CheckWmi bei ServiceNow' {
		InModuleScope sqmSQLTool {
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -Confirm:$false
			$r.VerifyStatus | Should -Be 'OK'
			$r.VerifyLevel | Should -Be 'Full'
			$r.Status | Should -Be 'OK'
			Should -Invoke Test-sqmDiscoveryAccess -Times 1 -Exactly -ParameterFilter {
				$LoginName -eq 'CORP\svc_snow' -and $ServerRole -eq 'SNOWDISCO' -and $Product -eq 'ServiceNow' -and $RequiredLevel -eq 'Full' -and $CheckWmi
			}
		}
	}

	It 'die Pruefung laeuft nach den Rechten, nicht davor' {
		InModuleScope sqmSQLTool {
			Mock Test-sqmDiscoveryAccess { $script:queries.Add('<<VERIFY>>'); [PSCustomObject]@{ Status = 'OK'; DiscoveryLevel = 'Full'; MeetsRequirement = $true; Findings = @() } }
			Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -Confirm:$false | Out-Null
			$arr = $script:queries.ToArray()
			[array]::IndexOf($arr, '<<VERIFY>>') | Should -BeGreaterThan ([array]::FindIndex($arr, [Predicate[string]] { param ($q) $q -match 'ADD MEMBER' }))
		}
	}

	It 'Qualys: Pruefung ohne -CheckWmi, solange WMI nicht gesetzt wurde' {
		InModuleScope sqmSQLTool {
			Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product Qualys -LoginName 'CORP\q' -Confirm:$false | Out-Null
			Should -Invoke Test-sqmDiscoveryAccess -Times 1 -Exactly -ParameterFilter { $Product -eq 'Qualys' -and -not $CheckWmi }
		}
	}

	It 'ein freier Rollenname wird gegen das Produkt dieses Laufs geprueft' {
		InModuleScope sqmSQLTool {
			Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Product SCOM -RoleName 'Mon_Scan' -LoginName 'CORP\m' -Confirm:$false | Out-Null
			Should -Invoke Test-sqmDiscoveryAccess -Times 1 -Exactly -ParameterFilter { $ServerRole -eq 'Mon_Scan' -and $Product -eq 'SCOM' }
		}
	}

	It '-SkipVerification und fehlendes -LoginName lassen die Pruefung aus' {
		InModuleScope sqmSQLTool {
			(Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -SkipVerification -Confirm:$false).VerifyStatus | Should -Be 'NotRun'
			(Install-sqmDiscoveryRole -SqlInstance 'SQL01' -Confirm:$false).VerifyStatus | Should -Be 'NotRun'
			Should -Invoke Test-sqmDiscoveryAccess -Times 0 -Exactly
		}
	}

	It 'ein Befund der Pruefung macht den Status zur Warnung und nennt die Befunde' {
		InModuleScope sqmSQLTool {
			Mock Test-sqmDiscoveryAccess { [PSCustomObject]@{ Status = 'Fehler'; DiscoveryLevel = 'ServerOnly'; MeetsRequirement = $false; Findings = @('VIEW SERVER STATE fehlt.') } }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -Confirm:$false
			$r.Status | Should -Be 'Warnung'
			$r.VerifyStatus | Should -Be 'Fehler'
			$r.VerifyFindings | Should -Contain 'VIEW SERVER STATE fehlt.'
			($r.Warnings -join ' ') | Should -Match 'VIEW SERVER STATE fehlt'
		}
	}

	It 'ein bloss hinweisender Befund (Status Warnung, Anforderung erfuellt) laesst den Status auf OK' {
		InModuleScope sqmSQLTool {
			Mock Test-sqmDiscoveryAccess { [PSCustomObject]@{ Status = 'Warnung'; DiscoveryLevel = 'Full'; MeetsRequirement = $true; Findings = @('Hinweis: Remote Registry ist Stopped.') } }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -Confirm:$false
			$r.Status | Should -Be 'OK'
			$r.VerifyFindings.Count | Should -Be 1
		}
	}

	It 'eine Pruefung, die selbst scheitert, wird als Warnung gemeldet und stoppt die Einrichtung nicht' {
		InModuleScope sqmSQLTool {
			Mock Test-sqmDiscoveryAccess { throw 'Verbindung verloren' }
			$r = Install-sqmDiscoveryRole -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -Confirm:$false
			$r.Status | Should -Be 'Warnung'
			$r.VerifyStatus | Should -Be 'Error'
			$r.MemberAdded | Should -BeTrue
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
				GrantedPermissions = 'VIEW ANY DATABASE, VIEW ANY DEFINITION, VIEW SERVER PERFORMANCE STATE'; ServerRoles = 'SNOWDISCO'
			}
			Mock Invoke-DbaQuery { $script:row }
		}
	}

	It 'meldet OK, wenn die Standardrolle vollstaendig ist' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SNOWDISCO' `
				-RequiredLevel Full -OutputPath $Out -NoOpen
			$r.Status | Should -Be 'OK'
			$r.RoleMissingPermissions.Count | Should -Be 0
		}
	}

	It 'findet ein Konto ohne Domaene als DOMAIN\Name auf dem Server' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$script:sqls = [System.Collections.Generic.List[string]]::new()
			Mock Invoke-DbaQuery {
				$script:sqls.Add([string]$Query)
				if ($Query -match 'RIGHT\(name') { return [PSCustomObject]@{ name = 'CORP\svc_snow' } }
				$script:row
			}
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'svc_snow ' -ServerRole 'SNOWDISCO' -OutputPath $Out -NoOpen
			$r.LoginName | Should -Be 'CORP\svc_snow'
			$r.LoginExists | Should -BeTrue
			$r.Status | Should -Be 'OK'
			($script:sqls | Select-Object -Last 1) | Should -Match 'CORP\\svc_snow'
		}
	}

	It 'loest ein Konto ohne Domaene auf diesem Rechner auf, wenn der Server keinen Treffer hat' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			Mock Resolve-sqmDiscoveryLoginName { 'CORP\svc_snow' }
			Mock Invoke-DbaQuery {
				if ($Query -match 'RIGHT\(name') { return $null }
				$script:row
			}
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'svc_snow' -ServerRole 'SNOWDISCO' -OutputPath $Out -NoOpen
			$r.LoginName | Should -Be 'CORP\svc_snow'
			Should -Invoke Resolve-sqmDiscoveryLoginName -Times 1
		}
	}

	It 'meldet einen nicht eindeutigen Namen ohne Domaene als Befund und raet nicht' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			Mock Invoke-DbaQuery {
				if ($Query -match 'RIGHT\(name') { return @([PSCustomObject]@{ name = 'A\svc_snow' }, [PSCustomObject]@{ name = 'B\svc_snow' }) }
				$script:row
			}
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'svc_snow' -ServerRole 'SNOWDISCO' -OutputPath $Out -NoOpen
			$r.LoginName | Should -Be 'svc_snow'
			($r.Findings -join ' ') | Should -Match 'nicht eindeutig'
		}
	}

	It 'mit -Product wird eine Rolle mit freiem Namen gegen die Rechte des Produkts verglichen' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$script:row.RoleGrants = 'VIEW ANY DATABASE, VIEW SERVER PERFORMANCE STATE'
			$ohne = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc' -ServerRole 'Mon_Scan' -OutputPath $Out -NoOpen
			$ohne.RoleMissingPermissions.Count | Should -Be 0
			$mit = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc' -ServerRole 'Mon_Scan' -Product ServiceNow -OutputPath $Out -NoOpen
			$mit.RoleMissingPermissions | Should -Contain 'VIEW ANY DEFINITION'
		}
	}
	It 'findet ein nachtraeglich entzogenes Recht der Standardrolle' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$script:row.RoleGrants = 'VIEW ANY DATABASE, VIEW SERVER PERFORMANCE STATE'
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SNOWDISCO' -OutputPath $Out -NoOpen
			$r.RoleMissingPermissions | Should -Contain 'VIEW ANY DEFINITION'
			($r.Findings -join ' ') | Should -Match 'nicht mehr alle Standardrechte'
			$r.Status | Should -Be 'Warnung'
		}
	}

	It 'akzeptiert VIEW SERVER STATE als Ersatz fuer VIEW SERVER PERFORMANCE STATE' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$script:row.RoleGrants = 'VIEW ANY DATABASE, VIEW ANY DEFINITION, VIEW SERVER STATE'
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SNOWDISCO' -OutputPath $Out -NoOpen
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
			$r = Test-sqmDiscoveryAccess -SqlInstance 'SQL01' -LoginName 'CORP\svc_snow' -ServerRole 'SNOWDISCO' -RequiredLevel Full -CheckWmi -OutputPath $Out -NoOpen
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

Describe 'AlwaysOn: Knoten und Listener werden auf alle Replikate erweitert' {
	BeforeEach {
		InModuleScope sqmSQLTool {
			$script:dbatoolsAvailable = $true
			$script:queries = [System.Collections.Generic.List[string]]::new()
			$script:replicaRows = @(
				[PSCustomObject]@{ AgName = 'AG1'; ReplicaServerName = 'NODE1'; ListenerName = 'LSN1' }
				[PSCustomObject]@{ AgName = 'AG1'; ReplicaServerName = 'NODE2'; ListenerName = 'LSN1' }
				[PSCustomObject]@{ AgName = 'AG2'; ReplicaServerName = 'NODE1'; ListenerName = 'LSN2' }
				[PSCustomObject]@{ AgName = 'AG2'; ReplicaServerName = 'NODE3'; ListenerName = 'LSN2' }
			)
			Mock Invoke-sqmLogging { }
			Mock Invoke-DbaQuery {
				$script:queries.Add([string]$Query)
				if ($Query -match 'availability_replicas') { return $script:replicaRows }
				if ($Query -match 'ProductMajorVersion') { return [PSCustomObject]@{ MajorVersion = 16 } }
				if ($Query -match 'RoleExists') { return [PSCustomObject]@{ RoleExists = 0; LoginExists = 0; IsMember = 0 } }
			}
		}
	}

	It 'Listener: nur die Replikate seiner Gruppe' {
		InModuleScope sqmSQLTool {
			@(Resolve-sqmDiscoveryReplicaInstance -SqlInstance 'LSN1') | Should -Be @('NODE1', 'NODE2')
			@(Resolve-sqmDiscoveryReplicaInstance -SqlInstance 'lsn2.corp.local') | Should -Be @('NODE1', 'NODE3')
		}
	}

	It 'Knoten: alle Gruppen der Instanz, der angegebene Name bleibt erhalten' {
		InModuleScope sqmSQLTool {
			@(Resolve-sqmDiscoveryReplicaInstance -SqlInstance 'NODE2.corp.local') | Should -Be @('NODE1', 'NODE2.corp.local', 'NODE3')
		}
	}

	It '-SingleNode, kein HADR und Abfragefehler liefern die Instanz unveraendert' {
		InModuleScope sqmSQLTool {
			@(Resolve-sqmDiscoveryReplicaInstance -SqlInstance 'LSN1' -SingleNode) | Should -Be @('LSN1')
			$script:replicaRows = @()
			@(Resolve-sqmDiscoveryReplicaInstance -SqlInstance 'SQL01') | Should -Be @('SQL01')
			Mock Invoke-DbaQuery { throw 'nicht erreichbar' }
			@(Resolve-sqmDiscoveryReplicaInstance -SqlInstance 'SQL01') | Should -Be @('SQL01')
		}
	}

	It 'Install ueber den Listener richtet beide Knoten ein, WMI je Knoten' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmDiscoveryPolicyBlocker { $null }
			Mock Set-sqmDiscoveryWmiAccess { [PSCustomObject]@{ Status = 'OK'; Message = 'ok' } }
			Mock Test-sqmDiscoveryAccess { [PSCustomObject]@{ Status = 'OK'; DiscoveryLevel = 'Full'; MeetsRequirement = $true; Findings = @() } }
			$r = @(Install-sqmDiscoveryRole -SqlInstance 'LSN1' -LoginName 'CORP\svc_snow')
			$r.SqlInstance | Should -Be @('NODE1', 'NODE2')
			Should -Invoke Set-sqmDiscoveryWmiAccess -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'NODE1' }
			Should -Invoke Set-sqmDiscoveryWmiAccess -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'NODE2' }
			Should -Invoke Test-sqmDiscoveryAccess -Times 2 -Exactly -ParameterFilter { $SingleNode }
		}
	}

	It 'Install -SingleNode bleibt bei der angegebenen Instanz' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmDiscoveryPolicyBlocker { $null }
			Mock Set-sqmDiscoveryWmiAccess { [PSCustomObject]@{ Status = 'OK'; Message = 'ok' } }
			Mock Test-sqmDiscoveryAccess { [PSCustomObject]@{ Status = 'OK'; DiscoveryLevel = 'Full'; MeetsRequirement = $true; Findings = @() } }
			$r = @(Install-sqmDiscoveryRole -SqlInstance 'NODE1' -LoginName 'CORP\svc_snow' -SingleNode)
			$r.Count | Should -Be 1
			$r[0].SqlInstance | Should -Be 'NODE1'
		}
	}

	It 'Set-sqmDiscoveryWmiAccess -SqlInstance behandelt die Hosts aller Replikate' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmDiscoveryAccountSid { [PSCustomObject]@{ Sid = [System.Security.Principal.SecurityIdentifier]'S-1-5-21-1-2-3-1001'; Binary = [byte[]](1, 2, 3) } }
			Mock Open-sqmDiscoveryCimSession { $null }
			Mock Get-sqmDiscoveryWmiState {
				[PSCustomObject]@{ ComputerName = 'x'; DcomMember = $true; RemoteRegistryState = 'Stopped'; RemoteRegistryStart = 'Disabled'; Namespaces = @(); Ok = $true }
			}
			$r = @(Set-sqmDiscoveryWmiAccess -Account 'CORP\svc_snow' -SqlInstance 'LSN1')
			$r.ComputerName | Should -Be @('NODE1', 'NODE2')
		}
	}

	It 'Test-sqmDiscoveryAccess ueber den Listener prueft beide Knoten' {
		InModuleScope sqmSQLTool -Parameters @{ Out = $script:TestDir } {
			$r = @(Test-sqmDiscoveryAccess -SqlInstance 'LSN1' -LoginName 'CORP\svc_snow' -OutputPath $Out -NoOpen -ContinueOnError)
			$r.SqlInstance | Should -Be @('NODE1', 'NODE2')
		}
	}
}

Describe 'Rollennamen je Produkt aus der Konfiguration' {
	It 'Standard: SNOWDISCO, Qualis_Scan, SCOM_HealthService' {
		InModuleScope sqmSQLTool {
			$p = @(Get-sqmDiscoveryProductList)
			($p | Where-Object Product -eq 'ServiceNow').RoleName | Should -Be 'SNOWDISCO'
			($p | Where-Object Product -eq 'Qualys').RoleName | Should -Be 'Qualis_Scan'
			($p | Where-Object Product -eq 'SCOM').RoleName | Should -Be 'SCOM_HealthService'
		}
	}

	It 'ein Wert aus der Konfiguration ersetzt den Standard, leer faellt auf den Standard zurueck' {
		InModuleScope sqmSQLTool {
			$old = $script:sqmModuleConfig['DiscoveryRoleNameSCOM']
			try
			{
				$script:sqmModuleConfig['DiscoveryRoleNameSCOM'] = 'MeinScom'
				(Get-sqmDiscoveryDefinition -Product SCOM).RoleName | Should -Be 'MeinScom'
				$script:sqmModuleConfig['DiscoveryRoleNameSCOM'] = ' '
				(Get-sqmDiscoveryDefinition -Product SCOM).RoleName | Should -Be 'SCOM_HealthService'
			}
			finally { $script:sqmModuleConfig['DiscoveryRoleNameSCOM'] = $old }
		}
	}

	It 'Set-sqmConfig kennt die drei Parameter, die Konfiguration die drei Schluessel' {
		InModuleScope sqmSQLTool {
			$params = (Get-Command Set-sqmConfig).Parameters.Keys
			$params | Should -Contain 'DiscoveryRoleNameServiceNow'
			$params | Should -Contain 'DiscoveryRoleNameQualys'
			$params | Should -Contain 'DiscoveryRoleNameSCOM'
			$script:sqmModuleConfig.Keys | Should -Contain 'DiscoveryRoleNameServiceNow'
		}
	}
}

Describe 'Modul-Update erstellt kein Backup mehr' {
	It 'Copy-sqmModuleFiles, Update-sqmFromGitHub und Update-sqmModule haben keinen -Backup-Parameter' {
		InModuleScope sqmSQLTool {
			foreach ($name in 'Copy-sqmModuleFiles', 'Update-sqmFromGitHub', 'Update-sqmModule')
			{
				(Get-Command $name).Parameters.Keys | Should -Not -Contain 'Backup'
			}
		}
	}

	It 'Copy-sqmModuleFiles legt keinen Sicherungsordner an' {
		InModuleScope sqmSQLTool {
			$src = Join-Path ([IO.Path]::GetTempPath()) "sqmcopy_src_$(Get-Random)"
			$dst = Join-Path ([IO.Path]::GetTempPath()) "sqmcopy_dst_$(Get-Random)"
			New-Item -ItemType Directory -Path $src, $dst -Force | Out-Null
			Set-Content -Path (Join-Path $src 'a.txt') -Value 'neu'
			$before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'sqmSQLTool_Backup_*' -ErrorAction SilentlyContinue).Count
			try
			{
				Copy-sqmModuleFiles -SourcePath $src -ModulePath $dst
				(Get-Content (Join-Path $dst 'a.txt')) | Should -Be 'neu'
				@(Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'sqmSQLTool_Backup_*' -ErrorAction SilentlyContinue).Count | Should -Be $before
			}
			finally { Remove-Item $src, $dst -Recurse -Force -ErrorAction SilentlyContinue }
		}
	}
}
