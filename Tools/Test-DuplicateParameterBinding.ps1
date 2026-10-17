<#
.SYNOPSIS
    Findet doppelte Parameterbindungen (Splat-Hashtable + gleichnamiger expliziter Parameter).

.DESCRIPTION
    Sucht das Muster, das Windows PowerShell 5.1 mit einer ParameterBindingException
    (ParameterAlreadyBound) abbricht, waehrend PowerShell 7 es stillschweigend toleriert
    (der explizite Wert gewinnt):

        $connParams = @{ SqlInstance = $s; Database = $db; ErrorAction = 'Stop' }
        Invoke-DbaQuery @connParams -Database 'master'               # <- Crash unter 5.1
        Invoke-DbaQuery @connParams -ErrorAction SilentlyContinue    # <- Crash unter 5.1

    Weil die Entwicklung ueblicherweise unter PS 7 laeuft, die Module aber PowerShellVersion 5.1
    deklarieren und dort ausgeliefert werden, faellt so ein Fehler erst beim Kunden auf. Ein
    reiner Import-Test findet ihn nicht, da er erst zur Aufrufzeit auftritt.

    Geprueft wird jeder Schluessel der Splat-Hashtable, nicht nur Common Parameter. Die
    Schluessel werden pro Funktion in Textreihenfolge bis zum Aufruf verfolgt:
      - Hashtable-Literale         $p = @{ Database = $db }   /  $p = [ordered]@{ ... }
      - Index-/Member-Zuweisungen  $p['Database'] = 'x'       /  $p.Database = 'x'
      - Methoden                   $p.Add('Database', 'x')    /  $p.Remove('Database')  /  $p.Clear()
      - Kopien                     $q = $p.Clone()            /  $q = $p
      - Ergaenzung                 $p += @{ Database = 'x' }
    Eine Neuzuweisung oder ein Clear() ersetzt die bisherigen Schluessel nur, wenn sie auf dem
    Weg zum Aufruf sicher ausgefuehrt wird (nicht in if/switch/Schleife/catch/Scriptblock);
    sonst werden die Schluessel vereinigt. Ein Remove() vor dem Aufruf entfernt den Schluessel
    immer (lieber ein uebersehener Treffer als ein Fehlalarm). Zuweisungen im if-Zweig gelten
    nicht fuer Aufrufe im else-Zweig derselben Anweisung.

    Abkuerzungen und Aliase:
      - Common Parameter: Aliase (-ea, -wa, -ev, ...) und eindeutige Praefixe (-ErrorAct).
      - Funktionen, die im geprueften Verzeichnis definiert sind: deren param()-Block samt
        [Alias()] wird ausgewertet, eindeutige Praefixe werden aufgeloest.
      - Fremde Befehle (z. B. dbatools): nur exakter Namensvergleich, weil ohne Parameterliste
        nicht entscheidbar ist, ob -Query die Abkuerzung von QueryTimeout oder ein eigener
        Parameter ist.

.PARAMETER Root
    Wurzelverzeichnis der Pruefung. Standard ist das uebergeordnete Verzeichnis dieses Skripts,
    also das Repository-Wurzelverzeichnis.

.PARAMETER ExcludeDirectory
    Verzeichnisnamen, die uebersprungen werden. Standard: .git, bin, obj, node_modules.

.PARAMETER Quiet
    Unterdrueckt die Ausgabe. Nur der Exit-Code zaehlt.

.PARAMETER PassThru
    Gibt die Treffer zusaetzlich als Objekte aus (File, Line, Command, Parameter, Explicit, Splat).

.OUTPUTS
    Exit-Code 0 = sauber, 1 = mindestens ein Treffer.

.NOTES
    Autor : Uwe Janke - powershelldba.de
    Anlass: sqmDataTransfer 0.1.17.1 (Common Parameter -ErrorAction) und sqmSQLTool 1.9.178.0
            (@connParams mit Database + explizites -Database 'master' in den Zertifikatsfunktionen).
#>
[CmdletBinding()]
param(
	[string]$Root,
	[string[]]$ExcludeDirectory = @('.git', 'bin', 'obj', 'node_modules'),
	[switch]$Quiet,
	[switch]$PassThru
)

if (-not $Root)
{
	$Root = Split-Path -Parent $PSScriptRoot
}
$Root = (Resolve-Path -Path $Root).ProviderPath

# Common Parameter, die PowerShell an jedes Advanced Function bindet, mit ihren festen Aliasen.
$commonParameters = @(
	@{ Name = 'ErrorAction'; Aliases = @('ea') },
	@{ Name = 'WarningAction'; Aliases = @('wa') },
	@{ Name = 'InformationAction'; Aliases = @('infa') },
	@{ Name = 'Verbose'; Aliases = @('vb') },
	@{ Name = 'Debug'; Aliases = @('db') },
	@{ Name = 'ErrorVariable'; Aliases = @('ev') },
	@{ Name = 'WarningVariable'; Aliases = @('wv') },
	@{ Name = 'InformationVariable'; Aliases = @('iv') },
	@{ Name = 'OutVariable'; Aliases = @('ov') },
	@{ Name = 'OutBuffer'; Aliases = @('ob') },
	@{ Name = 'PipelineVariable'; Aliases = @('pv') },
	@{ Name = 'WhatIf'; Aliases = @('wi') },
	@{ Name = 'Confirm'; Aliases = @('cf') }
)

function Get-AstAncestorList
{
	param($Node)
	$list = New-Object System.Collections.Generic.List[object]
	while ($Node)
	{
		$list.Add($Node)
		$Node = $Node.Parent
	}
	, $list
}

function Get-AstFunctionScope
{
	# Naechste umschliessende Funktion, sonst die Datei. Variablen anderer Funktionen sind getrennt.
	param($Node)
	$current = $Node.Parent
	while ($current)
	{
		if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $current }
		if (-not $current.Parent) { return $current }
		$current = $current.Parent
	}
	$Node
}

function Get-AstCommonAncestorInfo
{
	# Liefert den niedrigsten gemeinsamen Vorfahren und je das Kind darunter auf beiden Seiten.
	param($First, $Second)
	$firstChain = Get-AstAncestorList -Node $First
	$secondChain = Get-AstAncestorList -Node $Second
	for ($i = 0; $i -lt $secondChain.Count; $i++)
	{
		$index = -1
		for ($j = 0; $j -lt $firstChain.Count; $j++)
		{
			if ([object]::ReferenceEquals($firstChain[$j], $secondChain[$i])) { $index = $j; break }
		}
		if ($index -ge 0)
		{
			$firstChild = $null
			$secondChild = $null
			if ($index -gt 0) { $firstChild = $firstChain[$index - 1] }
			if ($i -gt 0) { $secondChild = $secondChain[$i - 1] }
			return [pscustomobject]@{
				Ancestor    = $secondChain[$i]
				FirstChain  = $firstChain
				FirstIndex  = $index
				FirstChild  = $firstChild
				SecondChild = $secondChild
			}
		}
	}
	$null
}

function Test-AstMutuallyExclusive
{
	# $true, wenn beide Knoten in verschiedenen Zweigen derselben if-/switch-Anweisung liegen.
	param($First, $Second)
	$info = Get-AstCommonAncestorInfo -First $First -Second $Second
	if (-not $info) { return $false }
	if (-not ($info.Ancestor -is [System.Management.Automation.Language.IfStatementAst] -or
			$info.Ancestor -is [System.Management.Automation.Language.SwitchStatementAst])) { return $false }
	($info.FirstChild -is [System.Management.Automation.Language.StatementBlockAst]) -and
	($info.SecondChild -is [System.Management.Automation.Language.StatementBlockAst]) -and
	-not [object]::ReferenceEquals($info.FirstChild, $info.SecondChild)
}

function Test-AstUnconditionalBefore
{
	# $true, wenn $Node auf jedem Weg zu $Target ausgefuehrt wird (keine Bedingung/Schleife dazwischen).
	param($Node, $Target)
	$info = Get-AstCommonAncestorInfo -First $Node -Second $Target
	if (-not $info) { return $false }
	for ($k = 1; $k -lt $info.FirstIndex; $k++)
	{
		$step = $info.FirstChain[$k]
		if ($step -is [System.Management.Automation.Language.IfStatementAst] -or
			$step -is [System.Management.Automation.Language.SwitchStatementAst] -or
			$step -is [System.Management.Automation.Language.LoopStatementAst] -or
			$step -is [System.Management.Automation.Language.CatchClauseAst] -or
			$step -is [System.Management.Automation.Language.TrapStatementAst] -or
			$step -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
			$step -is [System.Management.Automation.Language.BinaryExpressionAst])
		{
			return $false
		}
	}
	$true
}

function Get-UnwrappedExpression
{
	param($Node)
	if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.Expression }
	while ($true)
	{
		if ($Node -is [System.Management.Automation.Language.AttributedExpressionAst]) { $Node = $Node.Child; continue }
		if ($Node -is [System.Management.Automation.Language.ParenExpressionAst] -and
			$Node.Pipeline -is [System.Management.Automation.Language.PipelineAst] -and
			$Node.Pipeline.PipelineElements.Count -eq 1)
		{
			$Node = $Node.Pipeline.PipelineElements[0]
			if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.Expression }
			continue
		}
		break
	}
	$Node
}

function Get-HashtableLiteralKey
{
	param($Hashtable)
	foreach ($pair in $Hashtable.KeyValuePairs)
	{
		if ($pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst])
		{
			$pair.Item1.Value
		}
	}
}

function Get-SplatKeyAt
{
	# Schluessel der Variable $VariableName unmittelbar vor $Position (gleiche Funktion).
	param([object[]]$Events, [string]$VariableName, $Position, [int]$Depth = 0)

	$keys = New-Object System.Collections.Generic.List[string]
	if ($Depth -gt 10) { return , $keys }

	$scope = Get-AstFunctionScope -Node $Position
	$offset = $Position.Extent.StartOffset

	foreach ($change in $Events)
	{
		if ($change.Variable -ne $VariableName) { continue }
		if ($change.Offset -gt $offset) { continue }
		if (-not [object]::ReferenceEquals($change.Scope, $scope)) { continue }
		if (Test-AstMutuallyExclusive -First $change.Node -Second $Position) { continue }

		switch ($change.Kind)
		{
			'Reset'
			{
				if (Test-AstUnconditionalBefore -Node $change.Node -Target $Position) { $keys.Clear() }
				$newKeys = $change.Keys
				if ($change.CopyFrom)
				{
					$newKeys = Get-SplatKeyAt -Events $Events -VariableName $change.CopyFrom -Position $change.Node -Depth ($Depth + 1)
				}
				foreach ($key in $newKeys)
				{
					if (-not ($keys | Where-Object { $_ -eq $key })) { $keys.Add($key) }
				}
			}
			'Add'
			{
				foreach ($key in $change.Keys)
				{
					if (-not ($keys | Where-Object { $_ -eq $key })) { $keys.Add($key) }
				}
			}
			'Remove'
			{
				foreach ($key in $change.Keys)
				{
					for ($r = $keys.Count - 1; $r -ge 0; $r--)
					{
						if ($keys[$r] -eq $key) { $keys.RemoveAt($r) }
					}
				}
			}
			'Clear'
			{
				if (Test-AstUnconditionalBefore -Node $change.Node -Target $Position) { $keys.Clear() }
			}
		}
	}
	, $keys
}

function Resolve-BoundParameterName
{
	# Bildet einen geschriebenen Parameternamen (Abkuerzung, Alias) auf den echten Namen ab.
	param([string]$Name, [object[]]$Candidates)

	foreach ($candidate in $Candidates)
	{
		if ($candidate.Name -eq $Name) { return $candidate.Name }
	}
	foreach ($candidate in $Candidates)
	{
		if ($candidate.Aliases -contains $Name) { return $candidate.Name }
	}
	if ($Name.Length -lt 2) { return $Name }

	$prefixMatches = @($Candidates | Where-Object {
			$candidateName = $_.Name
			($candidateName -like "$Name*") -or ($_.Aliases | Where-Object { $_ -like "$Name*" })
		} | ForEach-Object { $_.Name } | Select-Object -Unique)

	if ($prefixMatches.Count -eq 1)
	{
		# Bei fremden Befehlen kennen wir nur die Common Parameter. Ein Praefix wie -Ver koennte
		# dort ebenso ein eigener Parameter (-Version) sein - trotzdem wie bisher als Common werten.
		return $prefixMatches[0]
	}
	$Name
}

$files = Get-ChildItem -Path $Root -Recurse -Include '*.ps1', '*.psm1' -File |
Where-Object {
	$relative = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
	$segments = $relative -split '[\\/]'
	-not ($segments | Where-Object { $ExcludeDirectory -contains $_ })
}

# 1. Alle Dateien parsen und die Parameterlisten der hier definierten Funktionen sammeln.
$parsed = @()
$knownFunctions = @{ }

foreach ($file in $files)
{
	$parseErrors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
	if (-not $ast) { continue }
	$parsed += [pscustomobject]@{ File = $file; Ast = $ast }

	$definitions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
	foreach ($definition in $definitions)
	{
		$parameterAsts = @()
		if ($definition.Body.ParamBlock) { $parameterAsts = $definition.Body.ParamBlock.Parameters }
		elseif ($definition.Parameters) { $parameterAsts = $definition.Parameters }

		$parameterList = @()
		foreach ($parameterAst in $parameterAsts)
		{
			$aliases = @()
			foreach ($attribute in $parameterAst.Attributes)
			{
				if ($attribute -is [System.Management.Automation.Language.AttributeAst] -and $attribute.TypeName.Name -eq 'Alias')
				{
					foreach ($argument in $attribute.PositionalArguments)
					{
						$argument.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
						ForEach-Object { $aliases += $_.Value }
					}
				}
			}
			$parameterList += @{ Name = $parameterAst.Name.VariablePath.UserPath; Aliases = $aliases }
		}
		$knownFunctions[$definition.Name.ToLowerInvariant()] = $parameterList
	}
}

$findings = @()

foreach ($entry in $parsed)
{
	$file = $entry.File
	$ast = $entry.Ast

	# 2. Ereignisse sammeln, die die Schluessel einer Hashtable-Variable veraendern.
	$events = New-Object System.Collections.Generic.List[object]

	$assignments = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
	foreach ($assignment in $assignments)
	{
		$left = $assignment.Left
		while ($left -is [System.Management.Automation.Language.AttributedExpressionAst]) { $left = $left.Child }

		$change = $null

		if ($left -is [System.Management.Automation.Language.VariableExpressionAst])
		{
			$variableName = $left.VariablePath.UserPath.ToLowerInvariant()
			$right = Get-UnwrappedExpression -Node $assignment.Right
			$operator = $assignment.Operator.ToString()

			if ($operator -eq 'Equals')
			{
				$change = @{ Variable = $variableName; Kind = 'Reset'; Keys = @(); CopyFrom = $null }
				if ($right -is [System.Management.Automation.Language.HashtableAst])
				{
					$change.Keys = @(Get-HashtableLiteralKey -Hashtable $right)
				}
				elseif ($right -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
					$right.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
					$right.Member.Value -eq 'Clone' -and
					$right.Expression -is [System.Management.Automation.Language.VariableExpressionAst])
				{
					$change.CopyFrom = $right.Expression.VariablePath.UserPath.ToLowerInvariant()
				}
				elseif ($right -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $right.Splatted)
				{
					$change.CopyFrom = $right.VariablePath.UserPath.ToLowerInvariant()
				}
			}
			elseif ($operator -eq 'PlusEquals' -and $right -is [System.Management.Automation.Language.HashtableAst])
			{
				$change = @{ Variable = $variableName; Kind = 'Add'; Keys = @(Get-HashtableLiteralKey -Hashtable $right) }
			}
		}
		elseif ($left -is [System.Management.Automation.Language.IndexExpressionAst] -and
			$left.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
			$left.Index -is [System.Management.Automation.Language.StringConstantExpressionAst])
		{
			$change = @{ Variable = $left.Target.VariablePath.UserPath.ToLowerInvariant(); Kind = 'Add'; Keys = @($left.Index.Value) }
		}
		elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and
			$left.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
			$left.Member -is [System.Management.Automation.Language.StringConstantExpressionAst])
		{
			$change = @{ Variable = $left.Expression.VariablePath.UserPath.ToLowerInvariant(); Kind = 'Add'; Keys = @($left.Member.Value) }
		}

		if ($change)
		{
			$change.Node = $assignment
			$change.Offset = $assignment.Extent.EndOffset
			$change.Scope = Get-AstFunctionScope -Node $assignment
			$events.Add([pscustomobject]$change)
		}
	}

	$invocations = $ast.FindAll({
			$args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
			$args[0].Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
			$args[0].Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
			@('Add', 'Remove', 'Clear') -contains $args[0].Member.Value
		}, $true)
	foreach ($invocation in $invocations)
	{
		$kind = $invocation.Member.Value
		$keys = @()
		if ($kind -ne 'Clear')
		{
			if (-not $invocation.Arguments -or $invocation.Arguments[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
			$keys = @($invocation.Arguments[0].Value)
		}
		$events.Add([pscustomobject]@{
				Variable = $invocation.Expression.VariablePath.UserPath.ToLowerInvariant()
				Kind     = $kind
				Keys     = $keys
				CopyFrom = $null
				Node     = $invocation
				Offset   = $invocation.Extent.EndOffset
				Scope    = Get-AstFunctionScope -Node $invocation
			})
	}

	if ($events.Count -eq 0) { continue }
	$sortedEvents = @($events | Sort-Object Offset)
	$trackedVariables = @($sortedEvents | ForEach-Object { $_.Variable } | Select-Object -Unique)

	# 3. Aufrufe finden, die so eine Variable splatten UND einen ihrer Schluessel explizit setzen.
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

		$commandName = $command.GetCommandName()
		$candidates = $commonParameters
		if ($commandName -and $knownFunctions.ContainsKey($commandName.ToLowerInvariant()))
		{
			$candidates = @($knownFunctions[$commandName.ToLowerInvariant()]) + $commonParameters
		}

		foreach ($variableName in $splattedVariables)
		{
			if ($trackedVariables -notcontains $variableName) { continue }

			$keys = Get-SplatKeyAt -Events $sortedEvents -VariableName $variableName -Position $command
			foreach ($key in $keys)
			{
				$resolvedKey = Resolve-BoundParameterName -Name $key -Candidates $candidates
				foreach ($explicit in $explicitParameters)
				{
					$resolvedExplicit = Resolve-BoundParameterName -Name $explicit -Candidates $candidates
					if ($resolvedKey -eq $resolvedExplicit)
					{
						$findings += [pscustomobject]@{
							File      = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
							Line      = $command.Extent.StartLineNumber
							Command   = $commandName
							Parameter = $resolvedKey
							Explicit  = '-' + $explicit
							Splat     = '@' + $variableName
						}
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
		Write-Host "Behebung: den Schluessel vor dem Aufruf aus einer Kopie der Splat-Hashtable entfernen" -ForegroundColor Yellow
		Write-Host "bzw. dort ueberschreiben (`$p = `$connParams.Clone(); `$p['Database'] = 'master')," -ForegroundColor Yellow
		Write-Host "oder den expliziten Parameter weglassen." -ForegroundColor Yellow
		Write-Host ""
	}
	if ($PassThru) { $findings | Sort-Object File, Line }
	exit 1
}

if (-not $Quiet)
{
	Write-Host "Keine doppelten Parameterbindungen in '$Root' ($($files.Count) Datei(en) geprueft)." -ForegroundColor Green
}
exit 0
