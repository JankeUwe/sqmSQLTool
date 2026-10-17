<#
.SYNOPSIS
    Pester-Tests fuer Tools/Test-DuplicateParameterBinding.ps1.

.DESCRIPTION
    Jeder Fall schreibt ein kleines Fixture-Skript nach TestDrive und laesst den Checker darueber
    laufen. Die Fixtures stehen hier nur als Here-Strings, damit der Checker beim Lauf ueber das
    Repository selbst keine Treffer in dieser Datei meldet.
#>

BeforeAll {
	$script:Checker = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Test-DuplicateParameterBinding.ps1'
	$script:FixtureCount = 0

	function Invoke-DuplicateBindingCheck
	{
		param([string]$Code)
		$script:FixtureCount++
		$folder = Join-Path $TestDrive "case$($script:FixtureCount)"
		$null = New-Item -ItemType Directory -Path $folder -Force
		Set-Content -Path (Join-Path $folder 'Fixture.ps1') -Value $Code -Encoding UTF8
		$findings = @(& $script:Checker -Root $folder -Quiet -PassThru)
		[pscustomobject]@{ ExitCode = $LASTEXITCODE; Findings = $findings }
	}
}

Describe 'Test-DuplicateParameterBinding' {

	Context 'Nicht-Common-Parameter (sqmSQLTool 1.9.178.0)' {

		It 'Findet @connParams mit Database plus explizites -Database' {
			$result = Invoke-DuplicateBindingCheck @'
function Install-Something {
	$connParams = @{
		SqlInstance   = $SqlInstance
		SqlCredential = $SqlCredential
		Database      = $Database
	}
	Invoke-DbaQuery @connParams -Query 'SELECT 1' -ErrorAction Stop
	Invoke-DbaQuery @connParams -Database 'master' -Query 'SELECT 1' -ErrorAction Stop
}
'@
			$result.ExitCode | Should -Be 1
			$result.Findings.Count | Should -Be 1
			$result.Findings[0].Parameter | Should -Be 'Database'
			$result.Findings[0].Line | Should -Be 8
			$result.Findings[0].Splat | Should -Be '@connParams'
		}

		It 'Akzeptiert die Korrektur mit Clone und ueberschriebenem Schluessel' {
			$result = Invoke-DuplicateBindingCheck @'
function Install-Something {
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	$masterParams = $connParams.Clone()
	$masterParams['Database'] = 'master'
	Invoke-DbaQuery @masterParams -Query 'SELECT 1'
}
'@
			$result.ExitCode | Should -Be 0
			$result.Findings.Count | Should -Be 0
		}

		It 'Findet Schluessel aus nachtraeglicher Index-, Member- und Add-Zuweisung' {
			$result = Invoke-DuplicateBindingCheck @'
function Test-It {
	$a = @{ SqlInstance = $s }
	$a['Database'] = $db
	Invoke-DbaQuery @a -Database 'master'
	$b = @{ SqlInstance = $s }
	$b.Database = $db
	Invoke-DbaQuery @b -Database 'master'
	$c = @{ SqlInstance = $s }
	$c.Add('Database', $db)
	Invoke-DbaQuery @c -Database 'master'
	$d = @{ SqlInstance = $s }
	$d += @{ Database = $db }
	Invoke-DbaQuery @d -Database 'master'
}
'@
			$result.Findings.Count | Should -Be 4
		}

		It 'Uebernimmt die Schluessel einer Kopie (Clone und Zuweisung)' {
			$result = Invoke-DuplicateBindingCheck @'
function Test-It {
	$p = [ordered]@{ SqlInstance = $s; Database = $db }
	$q = $p.Clone()
	$r = $p
	Invoke-DbaQuery @q -Database 'master'
	Invoke-DbaQuery @r -Database 'master'
}
'@
			$result.Findings.Count | Should -Be 2
		}

		It 'Ignoriert Schluessel, die vor dem Aufruf entfernt werden' {
			$result = Invoke-DuplicateBindingCheck @'
function Test-It {
	$p = @{ SqlInstance = $s; Database = $db }
	if ($PSBoundParameters.ContainsKey('Database')) { [void]$p.Remove('Database') }
	Invoke-DbaQuery @p -Database 'master'
}
'@
			$result.Findings.Count | Should -Be 0
		}

		It 'Ignoriert Schluessel, die erst nach dem Aufruf hinzukommen' {
			$result = Invoke-DuplicateBindingCheck @'
function Test-It {
	$p = @{ SqlInstance = $s }
	Invoke-DbaQuery @p -Database 'master'
	$p['Database'] = $db
}
'@
			$result.Findings.Count | Should -Be 0
		}

		It 'Ignoriert eine unbedingt ueberschriebene Hashtable und .Clear()' {
			$result = Invoke-DuplicateBindingCheck @'
function Test-It {
	$p = @{ SqlInstance = $s; Database = $db }
	$p = @{ SqlInstance = $s }
	Invoke-DbaQuery @p -Database 'master'
	$q = @{ Database = $db }
	$q.Clear()
	Invoke-DbaQuery @q -Database 'master'
}
'@
			$result.Findings.Count | Should -Be 0
		}

		It 'Trennt gleichnamige Variablen verschiedener Funktionen' {
			$result = Invoke-DuplicateBindingCheck @'
function First-Thing {
	$p = @{ SqlInstance = $s; Database = $db }
	Invoke-DbaQuery @p -Query 'SELECT 1'
}
function Second-Thing {
	$p = @{ SqlInstance = $s }
	Invoke-DbaQuery @p -Database 'master'
}
'@
			$result.Findings.Count | Should -Be 0
		}

		It 'Wertet bedingte Zuweisungen als moeglich, aber nicht im Nachbarzweig' {
			$result = Invoke-DuplicateBindingCheck @'
function Test-It {
	$p = @{ SqlInstance = $s }
	if ($db) { $p.Database = $db }
	Invoke-DbaQuery @p -Database 'master'

	if ($x) {
		$q = @{ SqlInstance = $s; Database = $db }
	}
	else {
		$q = @{ SqlInstance = $s }
		Invoke-DbaQuery @q -Database 'master'
	}
}
'@
			$result.Findings.Count | Should -Be 1
			$result.Findings[0].Line | Should -Be 4
		}
	}

	Context 'Abkuerzungen und Aliase' {

		It 'Findet Common Parameter ueber Alias und Praefix' {
			$result = Invoke-DuplicateBindingCheck @'
$p = @{ Path = 'C:\'; ErrorAction = 'Stop' }
Get-Item @p -ea SilentlyContinue
Get-Item @p -ErrorAct SilentlyContinue
'@
			$result.Findings.Count | Should -Be 2
			$result.Findings | ForEach-Object { $_.Parameter | Should -Be 'ErrorAction' }
		}

		It 'Wertet bei fremden Befehlen keinen Praefix aus (-Query neben QueryTimeout)' {
			$result = Invoke-DuplicateBindingCheck @'
$p = @{ SqlInstance = $s; QueryTimeout = 60 }
Invoke-DbaQuery @p -Query 'SELECT 1'
'@
			$result.Findings.Count | Should -Be 0
		}

		It 'Loest Praefix und Alias bei Funktionen aus dem geprueften Verzeichnis auf' {
			$result = Invoke-DuplicateBindingCheck @'
function Get-Thing {
	[CmdletBinding()]
	param(
		[Alias('DbName')]
		[string]$DatabaseName,
		[string]$Database
	)
}
$p = @{ DatabaseName = 'a' }
Get-Thing @p -DatabaseN 'b'
Get-Thing @p -DbName 'b'
Get-Thing @p -Database 'b'
'@
			$result.Findings.Count | Should -Be 2
			$result.Findings | ForEach-Object { $_.Parameter | Should -Be 'DatabaseName' }
		}
	}

	Context 'Verhalten unter Windows PowerShell 5.1' {

		It 'Bestaetigt, dass 5.1 das gefundene Muster wirklich ablehnt und die Korrektur annimmt' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
			$script51 = Join-Path $TestDrive 'Ps51Check.ps1'
			Set-Content -Path $script51 -Encoding UTF8 -Value @'
function Invoke-Probe { [CmdletBinding()] param($SqlInstance, $Database) $Database }
$connParams = @{ SqlInstance = 'x'; Database = 'userdb' }
try { Invoke-Probe @connParams -Database 'master' -ErrorAction Stop; 'DUPLICATE:accepted' }
catch { 'DUPLICATE:' + $_.FullyQualifiedErrorId }
$masterParams = $connParams.Clone()
$masterParams['Database'] = 'master'
'FIXED:' + (Invoke-Probe @masterParams)
'@
			$output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script51
			$output | Should -Contain 'FIXED:master'
			($output | Where-Object { $_ -like 'DUPLICATE:*' }) | Should -BeLike 'DUPLICATE:ParameterAlreadyBound*'
		}
	}
}
