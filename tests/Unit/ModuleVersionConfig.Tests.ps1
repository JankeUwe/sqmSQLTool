#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests: eine alte ModuleVersion in config.json darf die installierte Version nicht ueberdecken.

.DESCRIPTION
    Aeltere Set-sqmConfig-Staende haben die komplette Konfiguration in die config.json geschrieben,
    auch ModuleVersion. Der Import legte diesen Wert ueber die Manifest-Version, das Modul hielt sich
    fuer veraltet und bot bei jedem Start ein Update an, das nie half (auch direkt nach Install.cmd).
#>

BeforeAll {
	. "$PSScriptRoot\..\TestHelpers.ps1"
	$script:oldAppData = $env:APPDATA
	$env:APPDATA = Join-Path $TestDrive 'appdata'
	New-Item -ItemType Directory -Path (Join-Path $env:APPDATA 'MSSQLTools') -Force | Out-Null
	'{"ModuleVersion":"1.0.0.0","Language":"en-US"}' | Set-Content (Join-Path $env:APPDATA 'MSSQLTools\config.json')
	Import-sqmTestModule
}

AfterAll {
	$env:APPDATA = $script:oldAppData
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'ModuleVersion aus config.json' {
	It 'wird ignoriert, die Version kommt aus dem Manifest' {
		$manifest = (Import-PowerShellDataFile (Join-Path $script:ModuleRoot 'sqmSQLTool.psd1')).ModuleVersion
		InModuleScope sqmSQLTool -Parameters @{ Expected = $manifest } {
			$script:sqmModuleConfig['ModuleVersion'] | Should -Be $Expected
		}
	}

	It 'uebernimmt andere Schluessel aus config.json weiterhin' {
		InModuleScope sqmSQLTool {
			$script:sqmModuleConfig['Language'] | Should -Be 'en-US'
		}
	}
}
