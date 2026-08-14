<#
.SYNOPSIS
Applies a JSON snapshot produced by Export-sqmServerConfiguration against a target SQL Server
instance.

.DESCRIPTION
Counterpart to Export-sqmServerConfiguration. Reads the snapshot at -InputPath and re-applies
whichever captured settings can actually be changed on a live, already-installed instance. Not
every captured category is restorable - the current value on -SqlInstance is always compared
against the desired value from the file first, so only settings that actually differ are touched,
and every attempted item gets its own result row (Success/Skipped/Failed/WhatIf), the same
granularity Import-sqmDatabaseLogins uses for logins.

Per category (see -IncludeCategory):
- SpConfigure: every sp_configure value from the snapshot is applied via Set-DbaSpConfigure
  (which itself enables 'show advanced options' when required). This is the main, safe-to-restore
  category and the reason this function exists.
- InstanceProperties: only BackupDirectory/DefaultFile/DefaultLog are actually settable (via
  Set-DbaDefaultPath) - everything else in this category (Edition, Collation, LoginMode,
  IsClustered, ...) is server/installation-level and cannot be changed by restoring a snapshot;
  those are reported as 'Informational' rows, not attempted.
- TempDb: file Size/Growth are re-applied via ALTER DATABASE tempdb MODIFY FILE, matched by
  LogicalName. Only grows a file (SQL Server itself rejects shrinking a file via MODIFY FILE) and
  is skipped per-file if the snapshot's size/growth values cannot be parsed.
- Services: only StartMode is re-applied (via the service object's ChangeStartMode() method) -
  ServiceAccount is intentionally never touched here (the snapshot never contained a password).

Never restorable, and always reported as 'Informational'/'Skipped' if present in the snapshot:
DatabaseMail (profiles need SMTP account data the export never captured), LinkedServers (the
password/login mapping is never exported by dbatools), Databases (the per-database overview is a
read-only inventory - use Import-sqmDatabaseSettings for actual per-database Options restore).

.PARAMETER SqlInstance
Target SQL Server instance the snapshot is applied to. Mandatory.

.PARAMETER SqlCredential
Optional alternative credentials (PSCredential object).

.PARAMETER InputPath
Path to the JSON file produced by Export-sqmServerConfiguration. Mandatory.

.PARAMETER IncludeCategory
Restricts which categories are applied. Default: SpConfigure, InstanceProperties, TempDb, Services
(everything that is actually restorable).

.PARAMETER ContinueOnError
Continue with the next item/category if one fails, instead of aborting the whole run.

.PARAMETER EnableException
Throw exceptions immediately (overrides -ContinueOnError).

.PARAMETER Confirm
Request confirmation before applying changes.

.PARAMETER WhatIf
Shows what would be applied without making changes.

.EXAMPLE
Import-sqmServerConfiguration -SqlInstance 'SQL01' -InputPath 'C:\Backups\SQLSnapshots\SQL01_MSSQLSERVER_20260810_120000.json'

Applies every restorable setting from the snapshot back to SQL01.

.EXAMPLE
Import-sqmServerConfiguration -SqlInstance 'SQL01' -InputPath '.\baseline.json' -IncludeCategory SpConfigure -WhatIf

Shows which sp_configure values would change, without applying anything.

.NOTES
Requires dbatools module and appropriate SQL Server permissions.
Counterpart: Export-sqmServerConfiguration (produces the file consumed here).
#>
function Import-sqmServerConfiguration
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
		[ValidateSet('SpConfigure', 'InstanceProperties', 'TempDb', 'Services')]
		[string[]]$IncludeCategory = @('SpConfigure', 'InstanceProperties', 'TempDb', 'Services'),
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

		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		function _AddResult([string]$Category, [string]$Item, [string]$Status, [string]$Message, $OldValue = $null, $NewValue = $null)
		{
			$results.Add([PSCustomObject]@{
					SqlInstance = $SqlInstance
					Category    = $Category
					Item	    = $Item
					OldValue    = $OldValue
					NewValue    = $NewValue
					Status	    = $Status
					Message	    = $Message
					Timestamp   = (Get-Date)
				})
		}

		# Versucht einen dbatools [Size]-artigen Wert (oder, nach JSON-Rundtrip, das daraus
		# entstandene PSCustomObject bzw. einen rohen Zahlen-/String-Wert) als MB-Zahl zu lesen.
		function _TryGetMegabyte($value)
		{
			if ($null -eq $value) { return $null }
			if ($value.PSObject.Properties.Name -contains 'Megabyte') { return [double]$value.Megabyte }
			if ($value -is [double] -or $value -is [int] -or $value -is [long]) { return [double]$value }
			if ($value -is [string] -and $value -match '([\d\.]+)') { return [double]$matches[1] }
			return $null
		}
	}

	process
	{
		try
		{
			# ---- 0. Snapshot lesen ----
			$snapshot = Get-Content -Path $InputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
			if (-not $snapshot.Configuration)
			{
				$msg = "'$InputPath' enthaelt keine 'Configuration'-Sektion - kein gueltiger Export-sqmServerConfiguration Snapshot."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw $msg }
				Write-Error $msg
				return $results
			}
			$config = $snapshot.Configuration
			Invoke-sqmLogging -Message "Snapshot '$InputPath' geladen (Quelle laut Metadaten: '$($snapshot.Metadata.ComputerName)\$($snapshot.Metadata.InstanceName)', exportiert: '$($snapshot.Metadata.ExportDate)')." `
							  -FunctionName $functionName -Level 'INFO'

			Invoke-sqmLogging -Message "Verbinde mit Ziel '$SqlInstance'." -FunctionName $functionName -Level 'INFO'
			$server = Connect-DbaInstance @connParams
			$serverName = $server.ComputerName

			# ========================================================================
			# 1. SpConfigure
			# ========================================================================
			if ('SpConfigure' -in $IncludeCategory -and $config.SpConfigure.items)
			{
				$items = @($config.SpConfigure.items)
				$applyAction = "$($items.Count) sp_configure-Einstellung(en) auf '$SqlInstance' anwenden"
				if ($PSCmdlet.ShouldProcess($SqlInstance, $applyAction))
				{
					# $server.Configuration selbst ist kein Enumerable - die eigentliche Liste der
					# sp_configure-Werte liegt unter .Properties (siehe Export-sqmServerConfiguration).
					$currentConfig = @{ }
					foreach ($c in $server.Configuration.Properties)
					{
						$key = if ($c.ConfigName) { $c.ConfigName } else { $c.DisplayName }
						$currentConfig[$key] = $c.RunValue
					}

					foreach ($item in $items)
					{
						$configName = $item.ConfigName
						$targetValue = $item.RunValue
						$currentValue = $currentConfig[$configName]
						if ($null -eq $configName) { continue }

						if ($currentValue -eq $targetValue)
						{
							_AddResult 'SpConfigure' $configName 'Skipped' 'Bereits auf Zielwert - keine Aenderung.' $currentValue $targetValue
							continue
						}
						try
						{
							$null = Set-DbaSpConfigure -SqlInstance $server -Name $configName -Value $targetValue -EnableException -ErrorAction Stop
							Invoke-sqmLogging -Message "sp_configure '$configName': $currentValue -> $targetValue" -FunctionName $functionName -Level 'INFO'
							_AddResult 'SpConfigure' $configName 'Success' 'Angewendet.' $currentValue $targetValue
						}
						catch
						{
							$errMsg = "sp_configure '$configName' fehlgeschlagen: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
							_AddResult 'SpConfigure' $configName 'Failed' $errMsg $currentValue $targetValue
							if (-not $ContinueOnError -and $EnableException) { throw }
						}
					}
				}
				else
				{
					foreach ($item in $items) { _AddResult 'SpConfigure' $item.ConfigName 'WhatIf' 'WhatIf: Wert wuerde angewendet.' }
				}
			}

			# ========================================================================
			# 2. InstanceProperties (nur Pfade sind tatsaechlich restaurierbar)
			# ========================================================================
			if ('InstanceProperties' -in $IncludeCategory -and $config.InstanceProperties)
			{
				$props = $config.InstanceProperties
				$pathMap = @{ BackupDirectory = 'Backup'; DefaultFile = 'Data'; DefaultLog = 'Log' }
				$informationalProps = @('ComputerName', 'InstanceName', 'Edition', 'VersionString', 'ProductLevel',
					'ProductUpdateLevel', 'HostPlatform', 'IsClustered', 'IsHadrEnabled', 'Collation', 'LoginMode',
					'MasterDBPath', 'ErrorLogPath')

				foreach ($propName in $informationalProps)
				{
					if ($props.PSObject.Properties.Name -contains $propName)
					{
						_AddResult 'InstanceProperties' $propName 'Informational' 'Server-/Installationseigenschaft, wird von Import nicht geaendert.' $null $props.$propName
					}
				}

				foreach ($propName in $pathMap.Keys)
				{
					if (-not ($props.PSObject.Properties.Name -contains $propName) -or [string]::IsNullOrWhiteSpace($props.$propName)) { continue }
					$targetPath = $props.$propName
					$currentPath = $server.$propName
					if ($currentPath -eq $targetPath)
					{
						_AddResult 'InstanceProperties' $propName 'Skipped' 'Bereits auf Zielwert - keine Aenderung.' $currentPath $targetPath
						continue
					}
					$applyAction = "$propName von '$currentPath' auf '$targetPath' setzen"
					if ($PSCmdlet.ShouldProcess($SqlInstance, $applyAction))
					{
						try
						{
							$null = Set-DbaDefaultPath -SqlInstance $server -Type $pathMap[$propName] -Path $targetPath -EnableException -ErrorAction Stop
							Invoke-sqmLogging -Message "$propName : '$currentPath' -> '$targetPath'" -FunctionName $functionName -Level 'INFO'
							_AddResult 'InstanceProperties' $propName 'Success' 'Angewendet (wirkt erst nach Neustart des SQL-Dienstes).' $currentPath $targetPath
						}
						catch
						{
							$errMsg = "$propName fehlgeschlagen: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
							_AddResult 'InstanceProperties' $propName 'Failed' $errMsg $currentPath $targetPath
							if (-not $ContinueOnError -and $EnableException) { throw }
						}
					}
					else
					{
						_AddResult 'InstanceProperties' $propName 'WhatIf' 'WhatIf: Pfad wuerde geaendert.' $currentPath $targetPath
					}
				}
			}

			# ========================================================================
			# 3. TempDb (Size/Growth je Datei, matched by LogicalName; nie verkleinern)
			# ========================================================================
			if ('TempDb' -in $IncludeCategory -and $config.TempDb.files)
			{
				$liveFiles = @(Get-DbaDbFile -SqlInstance $server -Database 'tempdb' -ErrorAction SilentlyContinue)
				foreach ($fileEntry in @($config.TempDb.files))
				{
					$logicalName = $fileEntry.LogicalName
					$liveFile = $liveFiles | Where-Object { $_.LogicalName -eq $logicalName } | Select-Object -First 1
					if (-not $liveFile)
					{
						_AddResult 'TempDb' $logicalName 'Skipped' 'Keine gleichnamige TempDb-Datei auf dem Ziel gefunden.'
						continue
					}

					$targetSizeMb = _TryGetMegabyte $fileEntry.Size
					$currentSizeMb = _TryGetMegabyte $liveFile.Size
					if ($null -eq $targetSizeMb)
					{
						_AddResult 'TempDb' $logicalName 'Skipped' 'Zielgroesse aus Snapshot konnte nicht gelesen werden.'
						continue
					}
					if ($targetSizeMb -le $currentSizeMb)
					{
						_AddResult 'TempDb' $logicalName 'Skipped' "Ziel ($([math]::Round($targetSizeMb))MB) ist nicht groesser als aktuell ($([math]::Round($currentSizeMb))MB) - MODIFY FILE kann nicht verkleinern." $currentSizeMb $targetSizeMb
						continue
					}

					$growthClause = if ($fileEntry.IsPercentGrowth)
					{
						$growthPct = _TryGetMegabyte $fileEntry.Growth
						if ($null -ne $growthPct) { ", FILEGROWTH = $([math]::Round($growthPct))%" } else { '' }
					}
					else
					{
						$growthMb = _TryGetMegabyte $fileEntry.Growth
						if ($null -ne $growthMb -and $growthMb -gt 0) { ", FILEGROWTH = $([math]::Round($growthMb))MB" } else { '' }
					}

					$applyAction = "TempDb-Datei '$logicalName': $([math]::Round($currentSizeMb))MB -> $([math]::Round($targetSizeMb))MB"
					if ($PSCmdlet.ShouldProcess($SqlInstance, $applyAction))
					{
						try
						{
							$query = "ALTER DATABASE tempdb MODIFY FILE (NAME = N'$($logicalName -replace "'", "''")', SIZE = $([math]::Round($targetSizeMb))MB$growthClause);"
							$null = Invoke-DbaQuery @connParams -Database master -Query $query -EnableException
							Invoke-sqmLogging -Message $applyAction -FunctionName $functionName -Level 'INFO'
							_AddResult 'TempDb' $logicalName 'Success' 'Angewendet.' $currentSizeMb $targetSizeMb
						}
						catch
						{
							$errMsg = "TempDb-Datei '$logicalName' fehlgeschlagen: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
							_AddResult 'TempDb' $logicalName 'Failed' $errMsg $currentSizeMb $targetSizeMb
							if (-not $ContinueOnError -and $EnableException) { throw }
						}
					}
					else
					{
						_AddResult 'TempDb' $logicalName 'WhatIf' 'WhatIf: Datei wuerde vergroessert.' $currentSizeMb $targetSizeMb
					}
				}
			}

			# ========================================================================
			# 4. Services (nur StartMode)
			# ========================================================================
			if ('Services' -in $IncludeCategory -and $config.Services.items)
			{
				$liveServices = @(Get-DbaService -ComputerName $serverName -ErrorAction SilentlyContinue)
				foreach ($svcEntry in @($config.Services.items))
				{
					$liveSvc = $liveServices | Where-Object { $_.ServiceName -eq $svcEntry.ServiceName } | Select-Object -First 1
					if (-not $liveSvc)
					{
						_AddResult 'Services' $svcEntry.ServiceName 'Skipped' 'Dienst auf dem Ziel nicht gefunden.'
						continue
					}
					$targetMode = $svcEntry.StartMode
					if ([string]::IsNullOrWhiteSpace($targetMode) -or $liveSvc.StartMode -eq $targetMode)
					{
						_AddResult 'Services' $svcEntry.ServiceName 'Skipped' 'Bereits auf Zielwert - keine Aenderung.' $liveSvc.StartMode $targetMode
						continue
					}
					$applyAction = "Dienst '$($svcEntry.ServiceName)': StartMode $($liveSvc.StartMode) -> $targetMode"
					if ($PSCmdlet.ShouldProcess($SqlInstance, $applyAction))
					{
						try
						{
							$changeResult = $liveSvc.ChangeStartMode($targetMode)
							if ($changeResult -and $changeResult.Success -eq $false)
							{
								throw $changeResult.Message
							}
							Invoke-sqmLogging -Message $applyAction -FunctionName $functionName -Level 'INFO'
							_AddResult 'Services' $svcEntry.ServiceName 'Success' 'Angewendet.' $liveSvc.StartMode $targetMode
						}
						catch
						{
							$errMsg = "Dienst '$($svcEntry.ServiceName)' fehlgeschlagen: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
							_AddResult 'Services' $svcEntry.ServiceName 'Failed' $errMsg $liveSvc.StartMode $targetMode
							if (-not $ContinueOnError -and $EnableException) { throw }
						}
					}
					else
					{
						_AddResult 'Services' $svcEntry.ServiceName 'WhatIf' 'WhatIf: StartMode wuerde geaendert.' $liveSvc.StartMode $targetMode
					}
				}
			}

			# ========================================================================
			# 5. Nicht restaurierbare Kategorien im Snapshot -> nur Hinweis
			# ========================================================================
			foreach ($skippedCategory in @('DatabaseMail', 'LinkedServers', 'Databases'))
			{
				if ($config.$skippedCategory)
				{
					_AddResult $skippedCategory '(alle)' 'Informational' "Kategorie '$skippedCategory' wird von Import-sqmServerConfiguration nicht restauriert (fehlende Daten im Snapshot bzw. eigene Funktion erforderlich)."
				}
			}
		}
		catch
		{
			$errMsg = "Fehler in Import-sqmServerConfiguration: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			_AddResult 'Import' '(alle)' 'Failed' $errMsg
			if ($EnableException) { throw }
		}
	}

	end
	{
		$successCount = @($results | Where-Object Status -eq 'Success').Count
		$failCount = @($results | Where-Object Status -eq 'Failed').Count
		$skipCount = @($results | Where-Object Status -in @('Skipped', 'Informational')).Count
		$summaryMsg = "Import-sqmServerConfiguration abgeschlossen - Erfolg: $successCount | Fehler: $failCount | Uebersprungen/Informativ: $skipCount"
		Invoke-sqmLogging -Message $summaryMsg -FunctionName $functionName -Level 'INFO'
		Write-Host $summaryMsg -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' }
			else { 'Green' })
		return $results
	}
}
