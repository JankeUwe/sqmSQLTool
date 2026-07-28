<#
.SYNOPSIS
    Findet doppelte Parameterbindungen (Splat-Hashtable + gleichnamiger expliziter Parameter).

.DESCRIPTION
    Sucht das Muster, das Windows PowerShell 5.1 mit einer ParameterBindingException
    (ParameterAlreadyBound) abbricht, waehrend PowerShell 7 es stillschweigend toleriert:

        $connParams = @{ SqlInstance = $s; ErrorAction = 'Stop' }
        Invoke-DbaQuery @connParams -Query $q -ErrorAction SilentlyContinue   # <- Crash unter 5.1

    Weil die Entwicklung ueblicherweise unter PS 7 laeuft, die Module aber PowerShellVersion 5.1
    deklarieren und dort ausgeliefert werden, faellt so ein Fehler erst beim Kunden auf. Ein
    reiner Import-Test findet ihn nicht, da er erst zur Aufrufzeit auftritt.

    Geprueft werden alle Common Parameter, nicht nur ErrorAction. Erkannt werden sowohl
    Hashtable-Literale als auch nachtraegliche Index-Zuweisungen ($p['ErrorAction'] = 'Stop').
    Parameter-Abkuerzungen (-ea, -ErrorAct) werden ueber einen Praefix-Vergleich mit erfasst.

.PARAMETER Root
    Wurzelverzeichnis der Pruefung. Standard ist das uebergeordnete Verzeichnis dieses Skripts,
    also das Repository-Wurzelverzeichnis.

.PARAMETER ExcludeDirectory
    Verzeichnisnamen, die uebersprungen werden. Standard: .git, bin, obj, node_modules.

.PARAMETER Quiet
    Unterdrueckt die Ausgabe. Nur der Exit-Code zaehlt.

.OUTPUTS
    Exit-Code 0 = sauber, 1 = mindestens ein Treffer.

.NOTES
    Autor : Uwe Janke - powershelldba.de
    Anlass: sqmDataTransfer 0.1.17.1, wo genau dieses Muster jeden regulaeren Resume-Lauf
            unter Windows PowerShell 5.1 abgebrochen hat.
#>
[CmdletBinding()]
param(
	[string]$Root,
	[string[]]$ExcludeDirectory = @('.git', 'bin', 'obj', 'node_modules'),
	[switch]$Quiet
)

if (-not $Root)
{
	$Root = Split-Path -Parent $PSScriptRoot
}
$Root = (Resolve-Path -Path $Root).ProviderPath

# Common Parameter, die PowerShell an jedes Advanced Function bindet. Genau diese koennen aus
# einer Hashtable und zusaetzlich explizit kommen, ohne dass ein Tippfehler vorliegt.
$commonParameters = @(
	'ErrorAction', 'WarningAction', 'InformationAction', 'Verbose', 'Debug',
	'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
	'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm'
)

$files = Get-ChildItem -Path $Root -Recurse -Include '*.ps1', '*.psm1' -File |
Where-Object {
	$relative = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
	$segments = $relative -split '[\\/]'
	-not ($segments | Where-Object { $ExcludeDirectory -contains $_ })
}

$findings = @()

foreach ($file in $files)
{
	$parseErrors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
	if (-not $ast) { continue }

	# 1. Variablen sammeln, deren Hashtable einen Common Parameter als Schluessel traegt.
	$tainted = @{ }

	$assignments = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)

	foreach ($assignment in $assignments)
	{
		# 1a. $p = @{ ErrorAction = 'Stop' }
		if ($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst])
		{
			$variableName = $assignment.Left.VariablePath.UserPath
			$hashtables = $assignment.Right.FindAll({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $true)

			foreach ($hashtable in $hashtables)
			{
				foreach ($pair in $hashtable.KeyValuePairs)
				{
					$key = $pair.Item1.Extent.Text.Trim("'", '"', ' ')
					if ($commonParameters -contains $key)
					{
						if (-not $tainted.ContainsKey($variableName)) { $tainted[$variableName] = @() }
						if ($tainted[$variableName] -notcontains $key) { $tainted[$variableName] += $key }
					}
				}
			}
		}

		# 1b. $p['ErrorAction'] = 'Stop'
		if ($assignment.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and
			$assignment.Left.Target -is [System.Management.Automation.Language.VariableExpressionAst])
		{
			$variableName = $assignment.Left.Target.VariablePath.UserPath
			$key = $assignment.Left.Index.Extent.Text.Trim("'", '"', ' ')
			if ($commonParameters -contains $key)
			{
				if (-not $tainted.ContainsKey($variableName)) { $tainted[$variableName] = @() }
				if ($tainted[$variableName] -notcontains $key) { $tainted[$variableName] += $key }
			}
		}
	}

	if ($tainted.Count -eq 0) { continue }

	# 2. Aufrufe finden, die so eine Variable splatten UND denselben Parameter explizit setzen.
	$commands = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)

	foreach ($command in $commands)
	{
		$splattedVariables = @()
		$explicitParameters = @()

		foreach ($element in $command.CommandElements)
		{
			if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted)
			{
				$splattedVariables += $element.VariablePath.UserPath
			}
			elseif ($element -is [System.Management.Automation.Language.CommandParameterAst])
			{
				$explicitParameters += $element.ParameterName
			}
		}

		if ($splattedVariables.Count -eq 0 -or $explicitParameters.Count -eq 0) { continue }

		foreach ($variableName in $splattedVariables)
		{
			if (-not $tainted.ContainsKey($variableName)) { continue }

			foreach ($parameter in $tainted[$variableName])
			{
				# Abkuerzungen mit erfassen: -ea, -ErrorAct, ... binden denselben Parameter.
				$matched = $explicitParameters | Where-Object { $_.Length -ge 2 -and $parameter -like "$_*" }
				if ($matched)
				{
					$findings += [pscustomobject]@{
						File      = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
						Line      = $command.Extent.StartLineNumber
						Command   = $command.GetCommandName()
						Parameter = $parameter
						Splat     = '$' + $variableName
					}
				}
			}
		}
	}
}

if ($findings)
{
	if (-not $Quiet)
	{
		Write-Host ""
		Write-Host "Doppelte Parameterbindung gefunden - crasht unter Windows PowerShell 5.1:" -ForegroundColor Red
		$findings | Sort-Object File, Line | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
		Write-Host "Behebung: entweder den Common Parameter aus der Splat-Hashtable entfernen und" -ForegroundColor Yellow
		Write-Host "explizit am Aufruf setzen, oder den expliziten Parameter weglassen." -ForegroundColor Yellow
		Write-Host ""
	}
	exit 1
}

if (-not $Quiet)
{
	Write-Host "Keine doppelten Parameterbindungen in '$Root' ($($files.Count) Datei(en) geprueft)." -ForegroundColor Green
}
exit 0
