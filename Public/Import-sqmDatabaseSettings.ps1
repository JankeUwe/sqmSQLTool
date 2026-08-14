<#
.SYNOPSIS
Applies a database "Options" snapshot produced by Export-sqmDatabaseSettings against a target
instance, via ALTER DATABASE.

.DESCRIPTION
Counterpart to Export-sqmDatabaseSettings. Reads the JSON snapshot at -InputPath and, for every
database it contains that also exists on -SqlInstance, compares each captured Options setting
(Get-sqmDatabaseSettingsDefinition) against the live value and applies only the ones that actually
differ - one ALTER DATABASE ... SET statement per changed setting, so a partial failure never blocks
the remaining settings (see -ContinueOnError).

Two of the definitions' properties are respected:
- AlterOption = $null (CollationName, ContainmentDesc, StateDesc, UserAccessDesc) is informational
  only in Get-sqmDatabaseSettingsDefinition and is never applied here, regardless of any switch.
- Exclusive = $true (ReadOnly, ReadCommittedSnapshot, BrokerEnabled) can terminate active
  connections (the ALTER DATABASE needs WITH ROLLBACK IMMEDIATE) and is therefore only applied when
  -IncludeExclusiveOptions is passed; without it, a differing exclusive setting is reported as
  'Skipped' so it stays visible instead of silently vanishing.

.PARAMETER SqlInstance
Target SQL Server instance the snapshot is applied to. Mandatory.

.PARAMETER SqlCredential
Optional alternative credentials (PSCredential object).

.PARAMETER InputPath
Path to the JSON file produced by Export-sqmDatabaseSettings. Mandatory.

.PARAMETER Database
Restricts the import to these database names from the snapshot (wildcards allowed). Without this,
every database in the snapshot that also exists on -SqlInstance is processed.

.PARAMETER ExcludeDatabase
Additional database names to exclude (wildcards allowed).

.PARAMETER IncludeExclusiveOptions
Also applies ReadOnly/ReadCommittedSnapshot/BrokerEnabled changes. These use WITH ROLLBACK
IMMEDIATE and will terminate other active connections to the database - off by default.

.PARAMETER ContinueOnError
Continue with the next setting/database if one fails, instead of aborting the whole run.

.PARAMETER EnableException
Throw exceptions immediately (overrides -ContinueOnError).

.PARAMETER Confirm
Request confirmation before applying changes to a database.

.PARAMETER WhatIf
Shows what would be applied without making changes.

.EXAMPLE
Import-sqmDatabaseSettings -SqlInstance 'SQL01' -InputPath 'C:\Backups\SQLSnapshots\DatabaseSettings_SQL01_20260810_120000.json'

Applies every differing, non-exclusive Options setting for every database in the snapshot.

.EXAMPLE
Import-sqmDatabaseSettings -SqlInstance 'SQL01' -InputPath '.\baseline.json' -Database 'Frontarena' -IncludeExclusiveOptions

Restores 'Frontarena' fully, including ReadOnly/ReadCommittedSnapshot/BrokerEnabled if they differ.

.NOTES
Prerequisites : dbatools, Invoke-sqmLogging, Get-sqmDatabaseSettingsDefinition
Counterpart   : Export-sqmDatabaseSettings (produces the file consumed here).
#>
function Import-sqmDatabaseSettings
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string]$InputPath,
		[Parameter(Mandatory = $false)]
		[string[]]$Database,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeExclusiveOptions,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$definitions = @(Get-sqmDatabaseSettingsDefinition | Where-Object { $_.AlterOption -or $_.ValueKind -like 'BitAs*' })

		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		function _AddResult([string]$DbName, [string]$Setting, [string]$Status, [string]$Message, $OldValue = $null, $NewValue = $null)
		{
			$results.Add([PSCustomObject]@{
					SqlInstance  = $SqlInstance
					DatabaseName = $DbName
					Setting	     = $Setting
					OldValue     = $OldValue
					NewValue     = $NewValue
					Status	     = $Status
					Message	     = $Message
					Timestamp    = (Get-Date)
				})
		}

		function _MatchesAnyPattern([string]$Name, [string[]]$Patterns)
		{
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}

		function _SqlIdent([string]$s) { $s -replace '\]', ']]' }

		# Baut den ALTER DATABASE ... SET Klausel-Text (ohne "ALTER DATABASE [x] SET ") fuer eine
		# einzelne Einstellung. Bei 'String' wird der Wert auf [A-Z_]+ validiert, bevor er in T-SQL
		# eingesetzt wird (Werte kommen aus einer Snapshot-Datei - potenziell externer Input).
		function _BuildAlterClause($Definition, $RawValue)
		{
			switch ($Definition.ValueKind)
			{
				'Bit' { return "$($Definition.AlterOption) $(if ([bool]$RawValue) { 'ON' } else { 'OFF' })" }
				'Int' { return "$($Definition.AlterOption) $([int]$RawValue)" }
				'IntSeconds' { return "$($Definition.AlterOption) $([int]$RawValue) SECONDS" }
				'String'
				{
					$val = "$RawValue"
					if ($val -notmatch '^[A-Z_]+$') { throw "Unerwarteter Wert '$val' fuer $($Definition.Key) - abgelehnt (erwartet nur Grossbuchstaben/Unterstrich)." }
					return "$($Definition.AlterOption) $val"
				}
				'BitAsLocalGlobal' { return "$($Definition.AlterOption) $(if ([bool]$RawValue) { 'LOCAL' } else { 'GLOBAL' })" }
				'BitAsForcedSimple' { return "$($Definition.AlterOption) $(if ([bool]$RawValue) { 'FORCED' } else { 'SIMPLE' })" }
				'BitAsReadOnlyReadWrite' { return $(if ([bool]$RawValue) { 'READ_ONLY' } else { 'READ_WRITE' }) }
				'BitAsBrokerEnableDisable' { return $(if ([bool]$RawValue) { 'ENABLE_BROKER' } else { 'DISABLE_BROKER' }) }
				default { throw "Unbekannter ValueKind '$($Definition.ValueKind)' fuer $($Definition.Key)." }
			}
		}

		function _NormalizedEqual($Definition, $CurrentValue, $DesiredValue)
		{
			if ($Definition.ValueKind -in @('Bit', 'BitAsLocalGlobal', 'BitAsForcedSimple', 'BitAsReadOnlyReadWrite', 'BitAsBrokerEnableDisable'))
			{
				return ([bool]$CurrentValue) -eq ([bool]$DesiredValue)
			}
			return "$CurrentValue" -eq "$DesiredValue"
		}
	}

	process
	{
		try
		{
			# ---- 0. Snapshot lesen und nach -Database/-ExcludeDatabase filtern ----
			$snapshot = Get-Content -Path $InputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
			if (-not $snapshot.Databases)
			{
				$msg = "'$InputPath' enthaelt keine 'Databases'-Sektion - kein gueltiger Export-sqmDatabaseSettings Snapshot."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw $msg }
				Write-Error $msg
				return $results
			}

			$fileDatabases = @($snapshot.Databases)
			if ($Database) { $fileDatabases = @($fileDatabases | Where-Object { $n = $_.DatabaseName; ($Database | Where-Object { $n -like $_ }).Count -gt 0 }) }
			if ($ExcludeDatabase) { $fileDatabases = @($fileDatabases | Where-Object { -not (_MatchesAnyPattern $_.DatabaseName $ExcludeDatabase) }) }

			if ($fileDatabases.Count -eq 0)
			{
				$msg = "Keine Datenbanken aus '$InputPath' nach Filter-Anwendung uebrig."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
				Write-Warning $msg
				_AddResult '(Datei)' '(alle)' 'Skipped' $msg
				return $results
			}
			Invoke-sqmLogging -Message "$($fileDatabases.Count) Datenbank(en) aus '$InputPath' fuer Import ausgewaehlt." -FunctionName $functionName -Level 'INFO'

			# ---- 1. Verbinden und aktuelle Settings der betroffenen Datenbanken auf dem Ziel lesen ----
			$null = Connect-DbaInstance @connParams
			$selectCols = ($definitions | ForEach-Object { "[$($_.SqlColumn)] AS [$($_.Key)]" }) -join ",`r`n    "
			$dbNameList = ($fileDatabases.DatabaseName | ForEach-Object { "N'$($_ -replace "'", "''")'" }) -join ', '
			$liveQuery = @"
SELECT
    name AS DatabaseName,
    $selectCols
FROM sys.databases
WHERE name IN ($dbNameList)
"@
			$liveRows = @(Invoke-DbaQuery @connParams -Query $liveQuery -EnableException -As PSObject)
			$liveByName = @{ }
			foreach ($row in $liveRows) { $liveByName[$row.DatabaseName] = $row }

			# ---- 2. Pro Datenbank: differierende Settings ermitteln und anwenden ----
			foreach ($fileDb in $fileDatabases)
			{
				$dbName = $fileDb.DatabaseName
				$liveRow = $liveByName[$dbName]
				if (-not $liveRow)
				{
					_AddResult $dbName '(alle)' 'Skipped' "Datenbank '$dbName' existiert nicht auf '$SqlInstance'."
					continue
				}

				$pendingChanges = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($def in $definitions)
				{
					$desiredValue = $fileDb.Settings.($def.Key)
					$currentValue = $liveRow.($def.Key)
					if (_NormalizedEqual $def $currentValue $desiredValue)
					{
						_AddResult $dbName $def.Key 'Skipped' 'Bereits auf Zielwert - keine Aenderung.' $currentValue $desiredValue
						continue
					}
					if ($def.Exclusive -and -not $IncludeExclusiveOptions)
					{
						_AddResult $dbName $def.Key 'Skipped' 'Exclusive-Einstellung - nicht angewendet ohne -IncludeExclusiveOptions (koennte Verbindungen trennen).' $currentValue $desiredValue
						continue
					}
					try
					{
						$clause = _BuildAlterClause $def $desiredValue
						$pendingChanges.Add([PSCustomObject]@{ Definition = $def; Clause = $clause; OldValue = $currentValue; NewValue = $desiredValue })
					}
					catch
					{
						_AddResult $dbName $def.Key 'Failed' "Klausel konnte nicht gebaut werden: $($_.Exception.Message)" $currentValue $desiredValue
					}
				}

				if ($pendingChanges.Count -eq 0) { continue }

				$applyAction = "$($pendingChanges.Count) Options-Einstellung(en) fuer Datenbank '$dbName' auf '$SqlInstance' anwenden"
				if (-not $PSCmdlet.ShouldProcess($SqlInstance, $applyAction))
				{
					foreach ($change in $pendingChanges) { _AddResult $dbName $change.Definition.Key 'WhatIf' "WhatIf: SET $($change.Clause)" $change.OldValue $change.NewValue }
					continue
				}

				$dbIdent = _SqlIdent $dbName
				foreach ($change in $pendingChanges)
				{
					$rollbackSuffix = if ($change.Definition.Exclusive) { ' WITH ROLLBACK IMMEDIATE' } else { '' }
					if ($change.Definition.Exclusive)
					{
						Invoke-sqmLogging -Message "Exclusive-Aenderung '$($change.Clause)' fuer '$dbName' trennt aktive Verbindungen (WITH ROLLBACK IMMEDIATE)." `
										  -FunctionName $functionName -Level 'WARNING'
					}
					try
					{
						$query = "ALTER DATABASE [$dbIdent] SET $($change.Clause)$rollbackSuffix;"
						$null = Invoke-DbaQuery @connParams -Database master -Query $query -EnableException
						Invoke-sqmLogging -Message "'$dbName': $($change.Definition.Key) $($change.OldValue) -> $($change.NewValue) (SET $($change.Clause))." `
										  -FunctionName $functionName -Level 'INFO'
						_AddResult $dbName $change.Definition.Key 'Success' 'Angewendet.' $change.OldValue $change.NewValue
					}
					catch
					{
						$errMsg = "'$dbName' / $($change.Definition.Key) fehlgeschlagen: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
						_AddResult $dbName $change.Definition.Key 'Failed' $errMsg $change.OldValue $change.NewValue
						if (-not $ContinueOnError -and $EnableException) { throw }
					}
				}
			}
		}
		catch
		{
			$errMsg = "Fehler in Import-sqmDatabaseSettings: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			_AddResult '(alle)' '(alle)' 'Failed' $errMsg
			if ($EnableException) { throw }
		}
	}

	end
	{
		$successCount = @($results | Where-Object Status -eq 'Success').Count
		$failCount = @($results | Where-Object Status -eq 'Failed').Count
		$skipCount = @($results | Where-Object Status -eq 'Skipped').Count
		$summaryMsg = "Import-sqmDatabaseSettings abgeschlossen - Erfolg: $successCount | Fehler: $failCount | Uebersprungen: $skipCount"
		Invoke-sqmLogging -Message $summaryMsg -FunctionName $functionName -Level 'INFO'
		Write-Host $summaryMsg -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' }
			else { 'Green' })
		return $results
	}
}
