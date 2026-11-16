#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmTsmConfiguration: INCLEXCL-Auswertung (mehrfach, relativ, fehlend) und Report.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
	$script:TestDir = New-TempTestDirectory
	$script:Ie = Join-Path $script:TestDir 'ie_dsm.opt'
	Set-Content -Path $script:Ie -Encoding UTF8 -Value @(
		'* Kommentar'
		'EXCLUDE "S:\Mit Leerzeichen\*"'
		'EXCLUDE.DIR S:\tmp'
		'INCLUDE S:\Img\* MC_TEST_CLASS'
		'EXCLUDE *:\...\*.ldf'
	)
	$script:Opt = Join-Path $script:TestDir 'dsm.opt'
	Set-Content -Path $script:Opt -Encoding UTF8 -Value @(
		'NODENAME TESTNODE'
		'TCPSERVERADDRESS tsm.example.test'
		'PASSWORD geheim123'
		'INCLEXCL ie_dsm.opt'
		'INCLEXCL "C:\gibt\es\nicht\ie_missing.opt"'
	)
	$script:Out = Join-Path $script:TestDir 'out'
}

AfterAll {
	Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-sqmTsmConfiguration' {
	BeforeAll {
		$script:r = Get-sqmTsmConfiguration -DsmOptPath $script:Opt -OutputPath $script:Out -NoOpen
	}

	It 'folgt allen INCLEXCL-Optionen, nicht nur der letzten' {
		@($script:r.InclExclFiles).Count | Should -Be 2
	}
	It 'loest relative INCLEXCL-Namen gegen das Verzeichnis der Optionsdatei auf' {
		@($script:r.InclExclFiles | Where-Object Found).Path | Should -Be $script:Ie
	}
	It 'meldet eine fehlende Include-Datei als Found=false statt abzubrechen' {
		$script:r.Success | Should -BeTrue
		@($script:r.InclExclFiles | Where-Object { -not $_.Found }).Count | Should -Be 1
	}
	It 'liest Regeln inkl. Anfuehrungszeichen, Subtyp und Managementklasse' {
		$rules = @($script:r.InclExclRules)
		$rules.Count | Should -Be 4
		($rules | Where-Object Pattern -eq 'S:\Mit Leerzeichen\*').Action | Should -Be 'EXCLUDE'
		($rules | Where-Object Type -eq 'EXCLUDE.DIR').Pattern | Should -Be 'S:\tmp'
		($rules | Where-Object Action -eq 'INCLUDE').ManagementClass | Should -Be 'MC_TEST_CLASS'
	}
	It 'erzeugt einen HTML-Report ohne Klartext-Kennwort' {
		Test-Path $script:r.ReportFile | Should -BeTrue
		$html = Get-Content -Path $script:r.ReportFile -Raw
		$html | Should -Match 'tsm.example.test'
		$html | Should -Not -Match 'geheim123'
	}
	It '-NoReport erzeugt keine Datei' {
		$n = Get-sqmTsmConfiguration -DsmOptPath $script:Opt -NoReport
		$n.ReportFile | Should -BeNullOrEmpty
	}
}
