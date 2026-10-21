<#
.SYNOPSIS
    Qualitaets-Gate fuer sqmSQLTool: feste Untergrenzen plus Ratsche gegen Verschlechterung.

.DESCRIPTION
    Misst eine feste Liste von Kennzahlen und vergleicht sie mit Tools\quality-baseline.json.
    Die Regeln dahinter stehen in CONSTRAINTS.md im Modulstamm.

    Zwei Arten von Kennzahlen:
      - Floor:   muss 0 sein. Laesst sich nicht ueber die Baseline lockern.
      - Ratchet: darf nicht schlechter werden als die Baseline. Verbesserungen schreibt
                 -UpdateBaseline zurueck (die Ratsche rastet ein). Eine Verschlechterung geht
                 nur mit -AcceptRegression und -Reason und landet als Ausnahme in der Baseline.

    Zusaetzlich wird die Baseline gegen den Stand in -CompareRef (Standard HEAD) geprueft.
    Wurde ein Wert dort gelockert, ohne dass eine passende Ausnahme eingetragen ist, schlaegt
    das Gate fehl. Lockern soll laut sein, Verschaerfen leise.

    Gedacht fuer Windows PowerShell 5.1 (die Zielplattform des Moduls): Parse- und AST-Pruefungen
    laufen mit dem 5.1-Parser, PS7-only Syntax wie ?? oder ?. faellt dadurch als Parse-Fehler auf.
    Unter pwsh wird ein Hinweis ausgegeben und die Parse-Pruefung in powershell.exe nachgeholt.

.PARAMETER Pester
    Fuehrt zusaetzlich die Pester-Suite (unter pwsh, Pester 5+) mit Code Coverage aus und misst
    PesterFailed und CoveragePercent. Dauert mehrere Minuten.

.PARAMETER UpdateBaseline
    Schreibt verbesserte Ratchet-Werte in die Baseline. Lockert nie.

.PARAMETER AcceptRegression
    Name einer Ratchet-Kennzahl, deren schlechterer Wert bewusst akzeptiert wird. Nur mit -Reason.

.PARAMETER Reason
    Begruendung fuer -AcceptRegression. Wird mit Datum in die Baseline geschrieben.

.PARAMETER ExpiresOn
    Ablaufdatum der Ausnahme (yyyy-MM-dd). Standard: heute + 90 Tage.

.PARAMETER CustomerTermsFile
    Datei mit Kundennamen/Codenamen, die nicht im oeffentlichen Repo stehen duerfen (eine Zeile
    je Begriff als Regex-Fragment, Gross-/Kleinschreibung zaehlt, # fuer Kommentare). Liegt bewusst AUSSERHALB des Repos, sonst stuende die Liste
    selbst oeffentlich. Fehlt die Datei, wird die Pruefung uebersprungen.

.PARAMETER CompareRef
    Git-Referenz, gegen die die Baseline auf Lockerung geprueft wird. Leer = keine Pruefung.

.PARAMETER Detail
    Anzahl Fundstellen, die je Kennzahl ausgegeben werden. Standard 15.

.EXAMPLE
    powershell.exe -NoProfile -File .\Tools\Test-QualityGate.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\Tools\Test-QualityGate.ps1 -Pester -UpdateBaseline

.EXAMPLE
    .\Tools\Test-QualityGate.ps1 -AcceptRegression EmptyCatch -Reason 'Best-effort Cleanup in Remove-sqmX, Fehler bewusst ignoriert'
#>
[CmdletBinding()]
param(
	[switch]$Pester,
	[switch]$UpdateBaseline,
	[string]$AcceptRegression,
	[string]$Reason,
	[string]$ExpiresOn,
	[string]$CustomerTermsFile = (Join-Path $env:USERPROFILE '.claude\skills\sqm-quality-gate\customer-terms.txt'),
	[string]$CompareRef = 'HEAD',
	[int]$Detail = 15
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $PSScriptRoot 'quality-baseline.json'
$baselineRelPath = 'Tools/quality-baseline.json'

if ($AcceptRegression -and -not $Reason)
{
	throw '-AcceptRegression braucht -Reason.'
}

# --------------------------------------------------------------------------------------------
# Kennzahlen: Name, Art, Richtung, Beschreibung
# --------------------------------------------------------------------------------------------
$metricDefinitions = @(
	@{ Name = 'ParseErrors51'; Kind = 'Floor'; Higher = $false; Text = 'Parse-Fehler unter Windows PowerShell 5.1 (inkl. PS7-only Syntax)' }
	@{ Name = 'KeywordAsCommand'; Kind = 'Floor'; Higher = $false; Text = '(if ...) / return if ...: Schluesselwort als Befehlsname, knallt erst zur Laufzeit' }
	@{ Name = 'DuplicateParameterBinding'; Kind = 'Floor'; Higher = $false; Text = 'Splat + gleicher Parameter explizit (ParameterAlreadyBound unter 5.1)' }
	@{ Name = 'PssaErrors'; Kind = 'Floor'; Higher = $false; Text = 'PSScriptAnalyzer Severity Error' }
	@{ Name = 'ManifestExportDrift'; Kind = 'Floor'; Higher = $false; Text = 'Public-Funktion nicht in FunctionsToExport oder Export ohne Definition' }
	@{ Name = 'CustomerTerms'; Kind = 'Floor'; Higher = $false; Text = 'Kundennamen aus customer-terms.txt im oeffentlichen Repo' }
	@{ Name = 'BomMissing'; Kind = 'Floor'; Higher = $false; Text = 'PowerShell-Dateien ohne UTF-8 BOM' }
	@{ Name = 'UnscopedParameterSetMix'; Kind = 'Floor'; Higher = $false; Text = 'Parameter mit benanntem Set UND unscoped [Parameter()]' }
	@{ Name = 'PssaWarnings'; Kind = 'Ratchet'; Higher = $false; Text = 'PSScriptAnalyzer Severity Warning' }
	@{ Name = 'EmptyCatch'; Kind = 'Ratchet'; Higher = $false; Text = 'Leere catch-Bloecke (verschluckte Fehler)' }
	@{ Name = 'SuppressMessage'; Kind = 'Ratchet'; Higher = $false; Text = 'SuppressMessageAttribute (stummgeschaltete Analyzer-Regeln)' }
	@{ Name = 'WmiCmdlets'; Kind = 'Ratchet'; Higher = $false; Text = 'Get-WmiObject & Co. (gibt es unter PS 7 nicht)' }
	@{ Name = 'PublicWithoutTest'; Kind = 'Ratchet'; Higher = $false; Text = 'Public-Funktionen, die in tests\ nirgends vorkommen' }
	@{ Name = 'BareShouldThrow'; Kind = 'Ratchet'; Higher = $false; Text = 'Should -Throw ohne -ExpectedMessage/-ExceptionType/-ErrorId' }
	@{ Name = 'SkippedTests'; Kind = 'Ratchet'; Higher = $false; Text = 'It -Skip / Set-ItResult -Skipped/-Inconclusive' }
	@{ Name = 'PesterFailed'; Kind = 'Floor'; Higher = $false; Text = 'Fehlgeschlagene Pester-Tests (nur mit -Pester)' }
	@{ Name = 'CoveragePercent'; Kind = 'Ratchet'; Higher = $true; Text = 'Code Coverage Public\ in Prozent (nur mit -Pester)' }
)

$results = @{}
$findings = @{}
function Add-GateResult
{
	param([string]$Name, [double]$Value, $Items)
	$results[$Name] = $Value
	$findings[$Name] = @($Items)
}

# --------------------------------------------------------------------------------------------
# Dateien: getrackt + neue, nicht ignorierte (git ls-files), ohne Vendor-/Werkzeugordner
# --------------------------------------------------------------------------------------------
Push-Location $root
try
{
	$allFiles = @(git ls-files --cached --others --exclude-standard) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}
finally
{
	Pop-Location
}
$psFiles = @($allFiles | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' -and $_ -notmatch '^(\.claude|bin)/' } |
	ForEach-Object { Join-Path $root $_ })
$sourceFiles = @($psFiles | Where-Object { $_.Substring($root.Length + 1) -match '^(Public|Private)\\|^sqmSQLTool\.psm1$' })
$testFiles = @($psFiles | Where-Object { $_.Substring($root.Length + 1) -match '^tests\\' })

function Get-RelPath
{
	param([string]$Path)
	$Path.Substring($root.Length + 1)
}

# --------------------------------------------------------------------------------------------
# Parsen (einmal, Ergebnis fuer alle AST-Pruefungen)
# --------------------------------------------------------------------------------------------
$asts = @{}
$parseItems = New-Object System.Collections.Generic.List[string]
foreach ($file in $psFiles)
{
	$tokens = $null
	$errors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
	$asts[$file] = $ast
	foreach ($e in $errors)
	{
		$parseItems.Add(('{0}:{1}  {2}' -f (Get-RelPath $file), $e.Extent.StartLineNumber, $e.Message))
	}
}

if ($PSVersionTable.PSVersion.Major -ge 6)
{
	Write-Warning 'Laeuft unter pwsh. Parse-Pruefung wird zusaetzlich in powershell.exe (5.1) ausgefuehrt.'
	$listFile = [System.IO.Path]::GetTempFileName()
	$checkFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.ps1')
	try
	{
		[System.IO.File]::WriteAllLines($listFile, [string[]]$psFiles)
		$checkScript = @'
param($ListFile)
foreach ($f in [System.IO.File]::ReadAllLines($ListFile))
{
	$t = $null; $e = $null
	$null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)
	foreach ($x in $e) { '{0}:{1}  {2}' -f $f, $x.Extent.StartLineNumber, $x.Message }
}
'@
		[System.IO.File]::WriteAllText($checkFile, $checkScript, (New-Object System.Text.UTF8Encoding($true)))
		$parseItems.Clear()
		foreach ($line in @(powershell.exe -NoProfile -NonInteractive -File $checkFile -ListFile $listFile))
		{
			if ($line) { $parseItems.Add($line.Replace($root + '\', '')) }
		}
	}
	finally
	{
		Remove-Item -LiteralPath $listFile, $checkFile -ErrorAction SilentlyContinue
	}
}
Add-GateResult 'ParseErrors51' $parseItems.Count $parseItems

function Find-GateAst
{
	param([string[]]$Files, [scriptblock]$Predicate)
	foreach ($file in $Files)
	{
		foreach ($node in $asts[$file].FindAll($Predicate, $true))
		{
			[pscustomobject]@{ File = (Get-RelPath $file); Line = $node.Extent.StartLineNumber; Node = $node }
		}
	}
}

function Format-GateHit
{
	param($Hit, [string]$Text)
	'{0}:{1}  {2}' -f $Hit.File, $Hit.Line, $Text
}

# --------------------------------------------------------------------------------------------
# AST-Pruefungen
# --------------------------------------------------------------------------------------------
$keywords = @('if', 'else', 'elseif', 'while', 'switch', 'try', 'catch', 'finally', 'do', 'until', 'foreach', 'for')
$hits = @(Find-GateAst $psFiles { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $keywords })
Add-GateResult 'KeywordAsCommand' $hits.Count ($hits | ForEach-Object { Format-GateHit $_ ("'" + $_.Node.GetCommandName() + "' als Befehl, `$(...) oder if-Anweisung verwenden") })

$hits = @(Find-GateAst $sourceFiles { param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] -and $n.Body.Statements.Count -eq 0 })
Add-GateResult 'EmptyCatch' $hits.Count ($hits | ForEach-Object { Format-GateHit $_ 'leerer catch-Block' })

$hits = @(Find-GateAst $psFiles { param($n) $n -is [System.Management.Automation.Language.AttributeAst] -and $n.TypeName.Name -match '(^|\.)SuppressMessage(Attribute)?$' })
Add-GateResult 'SuppressMessage' $hits.Count ($hits | ForEach-Object { Format-GateHit $_ $_.Node.Extent.Text })

$wmi = @('Get-WmiObject', 'gwmi', 'Invoke-WmiMethod', 'iwmi', 'Set-WmiInstance', 'swmi', 'Remove-WmiObject', 'rwmi', 'Register-WmiEvent')
$hits = @(Find-GateAst $sourceFiles { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $wmi })
Add-GateResult 'WmiCmdlets' $hits.Count ($hits | ForEach-Object { Format-GateHit $_ ($_.Node.GetCommandName() + ' -> Get-CimInstance') })

$hits = @(Find-GateAst $sourceFiles {
		param($n)
		if ($n -isnot [System.Management.Automation.Language.ParameterAst]) { return $false }
		$paramAttrs = @($n.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -in @('Parameter', 'System.Management.Automation.ParameterAttribute') })
		if ($paramAttrs.Count -lt 2) { return $false }
		$scoped = @($paramAttrs | Where-Object { @($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'ParameterSetName' }).Count -gt 0 })
		$scoped.Count -gt 0 -and $scoped.Count -lt $paramAttrs.Count
	})
Add-GateResult 'UnscopedParameterSetMix' $hits.Count ($hits | ForEach-Object { Format-GateHit $_ ($_.Node.Name.Extent.Text + ' hat benanntes Set und unscoped [Parameter()]') })

$hits = @(Find-GateAst $testFiles {
		param($n)
		if ($n -isnot [System.Management.Automation.Language.CommandAst] -or $n.GetCommandName() -ne 'Should') { return $false }
		$names = @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
		($names -contains 'Throw') -and -not ($names -contains 'Not') -and -not (@($names | Where-Object { $_ -in @('ExpectedMessage', 'ExceptionType', 'ErrorId') }).Count)
	})
Add-GateResult 'BareShouldThrow' $hits.Count ($hits | ForEach-Object { Format-GateHit $_ 'Should -Throw ohne -ExpectedMessage' })

$hits = @(Find-GateAst $testFiles {
		param($n)
		if ($n -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
		$cmd = $n.GetCommandName()
		$params = @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
		if ($cmd -in @('It', 'Describe', 'Context'))
		{
			return @($params | Where-Object { $_.ParameterName -eq 'Skip' -and (-not $_.Argument -or $_.Argument.Extent.Text -ne '$false') }).Count -gt 0
		}
		$cmd -eq 'Set-ItResult' -and @($params | Where-Object { $_.ParameterName -in @('Skipped', 'Inconclusive', 'Pending') }).Count -gt 0
	})
Add-GateResult 'SkippedTests' $hits.Count ($hits | ForEach-Object { Format-GateHit $_ $_.Node.Extent.Text.Split("`n")[0].Trim() })

# --------------------------------------------------------------------------------------------
# BOM
# --------------------------------------------------------------------------------------------
$items = @(foreach ($file in $psFiles)
	{
		$b = [System.IO.File]::ReadAllBytes($file)
		if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { Get-RelPath $file }
	})
Add-GateResult 'BomMissing' $items.Count $items

# --------------------------------------------------------------------------------------------
# Manifest-Exporte und Public-Funktionen ohne Test
# --------------------------------------------------------------------------------------------
# Public\<Verb-Noun>.ps1 definiert die Funktion <Verb-Noun>; weitere Funktionen in der Datei sind
# lokale Helfer. Dateien ohne Verb-Noun-Namen (category-map.ps1, nlp-synonyms.ps1) sind Daten.
$publicFiles = @($sourceFiles | Where-Object { $_.Substring($root.Length + 1) -match '^Public\\' })
$commandFiles = @($publicFiles | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) -cmatch '^[A-Z][a-z]+-\w+$' })
# Einige exportierte Funktionen liegen in Private\ oder in der psm1 (Get-sqmSaLogin, Update-sqmModule).
$definedFunctions = @(Find-GateAst $sourceFiles { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] } |
	ForEach-Object { $_.Node.Name } | Sort-Object -Unique)
$manifest = Import-PowerShellDataFile -Path (Join-Path $root 'sqmSQLTool.psd1')
$exported = @($manifest.FunctionsToExport)
$items = @(
	foreach ($file in $commandFiles)
	{
		$name = [System.IO.Path]::GetFileNameWithoutExtension($file)
		if ($definedFunctions -notcontains $name) { "Public\$name.ps1 definiert keine Funktion $name" }
		elseif ($exported -notcontains $name) { "$name steht nicht in FunctionsToExport" }
	}
	$exported | Where-Object { $definedFunctions -notcontains $_ } | ForEach-Object { "$_ exportiert, aber nirgends definiert" }
)
Add-GateResult 'ManifestExportDrift' $items.Count $items

$testText = ($testFiles | ForEach-Object { [System.IO.File]::ReadAllText($_) }) -join "`n"
$items = @($exported | Where-Object { $testText -notmatch ('(?<![\w-])' + [regex]::Escape($_) + '(?![\w-])') })
Add-GateResult 'PublicWithoutTest' $items.Count $items

# --------------------------------------------------------------------------------------------
# Kundennamen (Liste ausserhalb des Repos)
# --------------------------------------------------------------------------------------------
if (Test-Path -LiteralPath $CustomerTermsFile)
{
	$terms = @(Get-Content -LiteralPath $CustomerTermsFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
	$textFiles = @($allFiles | Where-Object { $_ -match '\.(ps1|psm1|psd1|md|txt|html|json|xml|cmd|yml|sql)$' } | ForEach-Object { Join-Path $root $_ })
	$items = New-Object System.Collections.Generic.List[string]
	if ($terms.Count)
	{
		# Zeilen sind Regex-Fragmente, Gross-/Kleinschreibung zaehlt (Kuerzel in Grossbuchstaben
		# sollen nicht auf gleichlautende englische Woerter anschlagen)
		$pattern = '(?<![\w-])(' + ($terms -join '|') + ')(?![\w-])'
		foreach ($file in $textFiles)
		{
			$lineNo = 0
			foreach ($line in [System.IO.File]::ReadAllLines($file))
			{
				$lineNo++
				$m = [regex]::Match($line, $pattern)
				if ($m.Success) { $items.Add(('{0}:{1}  "{2}"' -f (Get-RelPath $file), $lineNo, $m.Value)) }
			}
		}
	}
	Add-GateResult 'CustomerTerms' $items.Count $items
}
else
{
	Write-Warning "Kundennamen-Pruefung uebersprungen: $CustomerTermsFile fehlt."
}

# --------------------------------------------------------------------------------------------
# Externe Pruefungen: Duplicate Binding, PSScriptAnalyzer, Pester
# --------------------------------------------------------------------------------------------
$dupScript = Join-Path $PSScriptRoot 'Test-DuplicateParameterBinding.ps1'
$dup = @(& $dupScript -Root $root -Quiet -PassThru)
$global:LASTEXITCODE = 0
Add-GateResult 'DuplicateParameterBinding' $dup.Count ($dup | ForEach-Object { '{0}:{1}  {2} {3} + {4}' -f $_.File, $_.Line, $_.Command, $_.Splat, $_.Explicit })

if (Get-Module -ListAvailable PSScriptAnalyzer)
{
	$settings = Import-PowerShellDataFile -Path (Join-Path $root 'PSScriptAnalyzerSettings.psd1')
	$settings.Severity = @('Error', 'Warning')
	$pssa = @(foreach ($p in @('Public', 'Private'))
		{
			Invoke-ScriptAnalyzer -Path (Join-Path $root $p) -Recurse -Settings $settings
		}
		Invoke-ScriptAnalyzer -Path (Join-Path $root 'sqmSQLTool.psm1') -Settings $settings)
	$format = { '{0}:{1}  {2}' -f (Get-RelPath $_.ScriptPath), $_.Line, $_.RuleName }
	$err = @($pssa | Where-Object { $_.Severity -eq 'Error' })
	$warn = @($pssa | Where-Object { $_.Severity -eq 'Warning' })
	Add-GateResult 'PssaErrors' $err.Count ($err | ForEach-Object $format)
	Add-GateResult 'PssaWarnings' $warn.Count ($warn | ForEach-Object $format)
}
else
{
	Write-Warning 'PSScriptAnalyzer nicht installiert: PssaErrors/PssaWarnings nicht gemessen.'
}

if ($Pester)
{
	$pesterFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.ps1')
	$pesterScript = @'
param($Root)
$env:MSSQLTOOLS_SKIP_AUTO_UPDATE = '1'
Import-Module Pester -MinimumVersion 5.0
$cfg = . (Join-Path $Root 'tests\pester.config.ps1')
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
$r = Invoke-Pester -Configuration $cfg
$failed = @($r.Failed | ForEach-Object { $_.ExpandedPath })
'GATE-RESULT ' + (@{ Failed = $r.FailedCount; Passed = $r.PassedCount; Coverage = [math]::Round($r.CodeCoverage.CoveragePercent, 2); FailedNames = $failed } | ConvertTo-Json -Compress)
'@
	try
	{
		[System.IO.File]::WriteAllText($pesterFile, $pesterScript, (New-Object System.Text.UTF8Encoding($true)))
		Write-Host 'Pester laeuft (pwsh, mit Coverage) ...'
		# stderr der Tests (absichtliche Write-Error in Fehlerpfad-Tests) nicht durchreichen;
		# unter 5.1 wuerde EAP Stop eine stderr-Zeile eines nativen Befehls als Abbruch werten.
		$ErrorActionPreference = 'Continue'
		$out = @(pwsh -NoProfile -NonInteractive -File $pesterFile -Root $root 2>$null)
		$ErrorActionPreference = 'Stop'
		$line = $out | Where-Object { $_ -like 'GATE-RESULT *' } | Select-Object -Last 1
		if (-not $line) { throw "Pester lieferte kein Ergebnis:`n$($out -join "`n")" }
		$pr = $line.Substring(12) | ConvertFrom-Json
		Add-GateResult 'PesterFailed' $pr.Failed @($pr.FailedNames)
		Add-GateResult 'CoveragePercent' $pr.Coverage @("$($pr.Passed) Tests bestanden")
	}
	finally
	{
		Remove-Item -LiteralPath $pesterFile -ErrorAction SilentlyContinue
	}
}

# --------------------------------------------------------------------------------------------
# Vergleich mit Baseline
# --------------------------------------------------------------------------------------------
function Read-GateBaseline
{
	param([string]$Json)
	$obj = $Json | ConvertFrom-Json
	$metrics = @{}
	foreach ($p in $obj.metrics.PSObject.Properties) { $metrics[$p.Name] = [double]$p.Value }
	@{ Metrics = $metrics; Exceptions = @($obj.exceptions | Where-Object { $_ }) }
}

if (Test-Path -LiteralPath $baselinePath)
{
	$baseline = Read-GateBaseline ([System.IO.File]::ReadAllText($baselinePath))
}
else
{
	Write-Warning "Keine Baseline gefunden. Mit -UpdateBaseline wird $baselineRelPath aus den aktuellen Werten angelegt."
	$baseline = @{ Metrics = @{}; Exceptions = @() }
}

$failed = $false
$rows = foreach ($def in $metricDefinitions)
{
	$name = $def.Name
	$base = if ($baseline.Metrics.ContainsKey($name)) { $baseline.Metrics[$name] } else { $null }
	if (-not $results.ContainsKey($name))
	{
		[pscustomobject]@{ Kennzahl = $name; Art = $def.Kind; Baseline = $base; Aktuell = '-'; Status = 'nicht gemessen' }
		continue
	}
	$cur = $results[$name]
	if ($def.Kind -eq 'Floor')
	{
		$status = if ($cur -eq 0) { 'OK' } else { 'VERLETZT' }
	}
	elseif ($null -eq $base)
	{
		$status = 'neu'
	}
	else
	{
		$worse = if ($def.Higher) { $cur -lt $base } else { $cur -gt $base }
		$better = if ($def.Higher) { $cur -gt $base } else { $cur -lt $base }
		$status = if ($worse) { 'VERSCHLECHTERT' } elseif ($better) { 'verbessert' } else { 'OK' }
	}
	if ($status -in @('VERLETZT', 'VERSCHLECHTERT') -and $name -ne $AcceptRegression) { $failed = $true }
	[pscustomobject]@{ Kennzahl = $name; Art = $def.Kind; Baseline = $base; Aktuell = $cur; Status = $status }
}

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

# Bei Ratchet-Verstoessen nur Fundstellen in Dateien zeigen, die seit CompareRef geaendert wurden;
# die Altlast steht in der Baseline und interessiert hier nicht.
$changedFiles = @()
if ($CompareRef)
{
	Push-Location $root
	try
	{
		$ErrorActionPreference = 'Continue'
		$changedFiles = @(git diff --name-only $CompareRef 2>$null) + @(git ls-files --others --exclude-standard 2>$null) |
			Where-Object { $_ } | ForEach-Object { $_.Replace('/', '\') }
		$global:LASTEXITCODE = 0
	}
	finally
	{
		$ErrorActionPreference = 'Stop'
		Pop-Location
	}
}

foreach ($row in $rows | Where-Object { $_.Status -in @('VERLETZT', 'VERSCHLECHTERT') })
{
	$def = $metricDefinitions | Where-Object { $_.Name -eq $row.Kennzahl }
	Write-Host ("[{0}] {1}: {2}" -f $row.Status, $row.Kennzahl, $def.Text) -ForegroundColor Red
	$list = @($findings[$row.Kennzahl])
	if ($row.Art -eq 'Ratchet' -and $changedFiles.Count)
	{
		$list = @($list | Where-Object { $hitFile = ($_ -split ':\d+\s')[0]; $changedFiles -contains $hitFile })
		Write-Host ("    Fundstellen in seit {0} geaenderten Dateien (die Altlast steht in der Baseline):" -f $CompareRef) -ForegroundColor DarkGray
	}
	$list | Select-Object -First $Detail | ForEach-Object { Write-Host "    $_" }
	if ($list.Count -gt $Detail) { Write-Host ("    ... und {0} weitere" -f ($list.Count - $Detail)) }
}

# --------------------------------------------------------------------------------------------
# Lockerung gegenueber CompareRef erkennen
# --------------------------------------------------------------------------------------------
if ($CompareRef -and (Test-Path -LiteralPath $baselinePath))
{
	Push-Location $root
	try
	{
		# Unter 5.1 wird stderr eines nativen Befehls bei EAP Stop zum Abbruch (z. B. "exists on
		# disk, but not in 'HEAD'" vor dem ersten Commit der Baseline)
		$ErrorActionPreference = 'Continue'
		$refJson = git show "${CompareRef}:$baselineRelPath" 2>$null
		$refOk = $LASTEXITCODE -eq 0
		$global:LASTEXITCODE = 0
	}
	finally
	{
		$ErrorActionPreference = 'Stop'
		Pop-Location
	}
	if ($refOk -and $refJson)
	{
		$refBase = Read-GateBaseline ($refJson -join "`n")
		foreach ($def in $metricDefinitions | Where-Object { $_.Kind -eq 'Ratchet' })
		{
			$n = $def.Name
			if (-not ($refBase.Metrics.ContainsKey($n) -and $baseline.Metrics.ContainsKey($n))) { continue }
			$old = $refBase.Metrics[$n]
			$new = $baseline.Metrics[$n]
			$loosened = if ($def.Higher) { $new -lt $old } else { $new -gt $old }
			if (-not $loosened) { continue }
			$covered = @($baseline.Exceptions | Where-Object { $_.metric -eq $n -and [double]$_.to -eq $new -and [double]$_.from -eq $old })
			if ($covered.Count)
			{
				Write-Host ("[GELOCKERT mit Ausnahme] {0}: {1} -> {2}  ({3})" -f $n, $old, $new, $covered[0].reason) -ForegroundColor Yellow
			}
			else
			{
				Write-Host ("[GELOCKERT ohne Ausnahme] {0}: {1} -> {2} gegenueber {3}" -f $n, $old, $new, $CompareRef) -ForegroundColor Red
				$failed = $true
			}
		}
	}
}

# Abgelaufene Ausnahmen melden (blockiert nicht, soll aber auffallen)
foreach ($ex in $baseline.Exceptions | Where-Object { $_.expires -and ([datetime]$_.expires) -lt (Get-Date).Date })
{
	Write-Host ("[AUSNAHME ABGELAUFEN] {0} seit {1}: {2}" -f $ex.metric, $ex.expires, $ex.reason) -ForegroundColor Yellow
}

# --------------------------------------------------------------------------------------------
# Baseline schreiben
# --------------------------------------------------------------------------------------------
function Write-GateBaseline
{
	param($Metrics, $Exceptions)
	$ordered = [ordered]@{}
	foreach ($def in $metricDefinitions | Where-Object { $_.Kind -eq 'Ratchet' -and $Metrics.ContainsKey($_.Name) }) { $ordered[$def.Name] = $Metrics[$def.Name] }
	# @($List) direkt im Hashtable-Literal wirft unter 5.1 "Die Argumenttypen stimmen nicht ueberein"
	$exceptionArray = @()
	foreach ($ex in $Exceptions) { $exceptionArray += $ex }
	$doc = [ordered]@{
		comment    = 'Ratsche fuer Tools/Test-QualityGate.ps1. Nur ueber das Skript aendern, siehe CONSTRAINTS.md.'
		metrics    = $ordered
		exceptions = $exceptionArray
	}
	$json = $doc | ConvertTo-Json -Depth 5
	[System.IO.File]::WriteAllText($baselinePath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

if ($UpdateBaseline -or $AcceptRegression)
{
	$newMetrics = @{}
	foreach ($k in $baseline.Metrics.Keys) { $newMetrics[$k] = $baseline.Metrics[$k] }
	$exceptions = New-Object System.Collections.Generic.List[object]
	foreach ($ex in $baseline.Exceptions) { $exceptions.Add($ex) }
	$changes = New-Object System.Collections.Generic.List[string]

	foreach ($row in $rows | Where-Object { $_.Art -eq 'Ratchet' -and $_.Status -in @('verbessert', 'neu') })
	{
		if ($UpdateBaseline)
		{
			$newMetrics[$row.Kennzahl] = $row.Aktuell
			$changes.Add(('{0}: {1} -> {2}' -f $row.Kennzahl, $row.Baseline, $row.Aktuell))
		}
	}

	if ($AcceptRegression)
	{
		$row = $rows | Where-Object { $_.Kennzahl -eq $AcceptRegression }
		if (-not $row) { throw "Unbekannte Kennzahl: $AcceptRegression" }
		if ($row.Art -eq 'Floor') { throw "$AcceptRegression ist eine Untergrenze und laesst sich nicht lockern. Fundstellen beheben." }
		if ($row.Status -ne 'VERSCHLECHTERT') { throw "$AcceptRegression ist nicht verschlechtert (Status: $($row.Status))." }
		$expiry = if ($ExpiresOn) { ([datetime]$ExpiresOn).ToString('yyyy-MM-dd') } else { (Get-Date).AddDays(90).ToString('yyyy-MM-dd') }
		$exceptions.Add([ordered]@{ metric = $AcceptRegression; from = $row.Baseline; to = $row.Aktuell; reason = $Reason; date = (Get-Date).ToString('yyyy-MM-dd'); expires = $expiry })
		$newMetrics[$AcceptRegression] = $row.Aktuell
		$changes.Add(('{0}: {1} -> {2} GELOCKERT ({3})' -f $AcceptRegression, $row.Baseline, $row.Aktuell, $Reason))
	}

	if ($changes.Count)
	{
		Write-GateBaseline $newMetrics $exceptions
		Write-Host "Baseline aktualisiert ($baselineRelPath):" -ForegroundColor Cyan
		$changes | ForEach-Object { Write-Host "    $_" }
	}
	else
	{
		Write-Host 'Baseline unveraendert.'
	}
}

if ($failed)
{
	Write-Host 'QUALITY GATE: FEHLGESCHLAGEN' -ForegroundColor Red
	exit 1
}
Write-Host 'QUALITY GATE: OK' -ForegroundColor Green
exit 0
