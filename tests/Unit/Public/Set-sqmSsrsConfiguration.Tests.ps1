#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Set-sqmSsrsConfiguration (v1.9.201.0): Instanz-Autoerkennung (SSRS 2017+ heisst
    RS_SSRS, Power BI Report Server RS_PBIRS), WMI-Instanzaufruf per -InputObject, URL-Aufteilung in
    virtuelles Verzeichnis und ReserveURL, richtige WMI-Parameternamen und SQL-Anmeldung fuer
    Invoke-DbaQuery. Die Parameternamen sind live gegen Power BI Report Server 15.0 und SSRS 2022
    gemessen (Get-CimClass, MSReportServer_ConfigurationSetting).
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
	$script:TestDir = New-TempTestDirectory

	function global:Set-SsrsConfigMocks
	{
		param ([string[]]$Instances = @('RS_PBIRS'))
		$global:SsrsCfgCalls = [System.Collections.Generic.List[object]]::new()
		$global:SsrsCfgInstances = $Instances
		$global:SsrsCfgDbaCred = $null
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Write-Host { }
		Mock -ModuleName sqmSQLTool Get-CimInstance {
			if ($ClassName -eq '__NAMESPACE')
			{
				if ($Namespace -match '\\ReportServer$') { return @($global:SsrsCfgInstances | ForEach-Object { [PSCustomObject]@{ Name = $_ } }) }
				return @([PSCustomObject]@{ Name = 'V15' })
			}
			# Invoke-CimMethod -InputObject verlangt ein echtes CimInstance
			New-CimInstance -ClassName 'MSReportServer_ConfigurationSetting' -Namespace 'root/test' -ClientOnly -Property @{
				InstanceName = 'PBIRS'; IsSharePointIntegrated = $false; WindowsServiceIdentityActual = 'NT SERVICE\PowerBIReportServer'; Marker = 'cfg'
			}
		}
		Mock -ModuleName sqmSQLTool Invoke-CimMethod {
			$global:SsrsCfgCalls.Add([PSCustomObject]@{ Method = $MethodName; Args = $Arguments; InputObject = $InputObject; ClassName = $ClassName })
			[PSCustomObject]@{ HRESULT = 0; Script = 'SELECT 1'; Error = $null }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
			$global:SsrsCfgDbaCred = $SqlCredential
			$null
		}
	}
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	Remove-Item function:\Set-SsrsConfigMocks -ErrorAction SilentlyContinue
	$global:SsrsCfgCalls = $null; $global:SsrsCfgInstances = $null; $global:SsrsCfgDbaCred = $null
	$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Set-sqmSsrsConfiguration' {
	It 'wirft bei mehreren Instanzen ohne -InstanceName und nennt sie' {
		Set-SsrsConfigMocks -Instances @('RS_SSRS', 'RS_PBIRS')
		{ Set-sqmSsrsConfiguration -SkipDatabase -SkipUrls -SkipServiceAccount -SkipEncryptionKeyBackup -EnableException -OutputPath $script:TestDir } |
			Should -Throw -ExpectedMessage '*Mehrere Instanzen gefunden (RS_SSRS, RS_PBIRS)*'
	}

	It 'ruft WMI-Methoden als Instanzmethode auf, URLs ohne Pfad, Verzeichnis separat' {
		Set-SsrsConfigMocks
		$cred = New-Object System.Management.Automation.PSCredential('sa', (ConvertTo-SecureString 'x' -AsPlainText -Force))
		$r = Set-sqmSsrsConfiguration -InstanceName PBIRS -DatabaseServer 'sql01' -DatabaseAuthType SQL -DatabaseCredential $cred `
			-ReportServerUrl 'http://+:8081/ReportServer' -ReportsUrl 'http://+:8081/Reports' `
			-SkipServiceAccount -SkipEncryptionKeyBackup -EnableException -OutputPath $script:TestDir
		$r.OverallStatus | Should -Be 'Success'
		$calls = $global:SsrsCfgCalls
		@($calls | Where-Object { $_.ClassName }).Count | Should -Be 0
		@($calls | Where-Object { $_.InputObject.Marker -ne 'cfg' }).Count | Should -Be 0

		$reserve = @($calls | Where-Object Method -eq 'ReserveURL')
		$reserve.Count | Should -Be 2
		@($reserve | ForEach-Object { $_.Args.UrlString } | Select-Object -Unique) | Should -Be @('http://+:8081')
		$vdirs = @($calls | Where-Object Method -eq 'SetVirtualDirectory')
		@($vdirs | ForEach-Object { "$($_.Args.Application)=$($_.Args.VirtualDirectory)" }) |
			Should -Be @('ReportServerWebService=ReportServer', 'ReportServerWebApp=Reports')
	}

	It 'nutzt die echten WMI-Parameternamen und die SQL-Anmeldung' {
		Set-SsrsConfigMocks
		$cred = New-Object System.Management.Automation.PSCredential('sa', (ConvertTo-SecureString 'x' -AsPlainText -Force))
		$null = Set-sqmSsrsConfiguration -InstanceName RS_PBIRS -DatabaseServer 'sql01' -DatabaseAuthType SQL -DatabaseCredential $cred `
			-SkipUrls -SkipServiceAccount -SkipEncryptionKeyBackup -EnableException -OutputPath $script:TestDir
		$create = $global:SsrsCfgCalls | Where-Object Method -eq 'GenerateDatabaseCreationScript'
		$create.Args.ContainsKey('IsSharePointMode') | Should -BeTrue
		$rights = $global:SsrsCfgCalls | Where-Object Method -eq 'GenerateDatabaseRightsScript'
		$rights.Args.UserName | Should -Be 'sa'
		$rights.Args.IsWindowsUser | Should -BeFalse
		$conn = $global:SsrsCfgCalls | Where-Object Method -eq 'SetDatabaseConnection'
		$conn.Args.CredentialsType | Should -Be 1
		$conn.Args.ContainsKey('Encrypt') | Should -BeTrue
		$global:SsrsCfgDbaCred.UserName | Should -Be 'sa'
	}

	It 'ergaenzt kurze Instanznamen um RS_' {
		Set-SsrsConfigMocks -Instances @('RS_PBIRS', 'RS_SSRS')
		$r = Set-sqmSsrsConfiguration -InstanceName PBIRS -SkipDatabase -SkipUrls -SkipServiceAccount -SkipEncryptionKeyBackup -EnableException -OutputPath $script:TestDir
		$r.SsrsVersion | Should -Be 'V15'
		Should -Invoke -ModuleName sqmSQLTool Get-CimInstance -ParameterFilter { $Namespace -eq 'root\Microsoft\SqlServer\ReportServer\RS_PBIRS' } -Times 1 -Exactly
	}
}
