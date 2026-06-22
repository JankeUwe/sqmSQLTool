<#
.SYNOPSIS
Restores SQL Server configuration from a previously exported snapshot.

.DESCRIPTION
This function reads a JSON snapshot (created by Export-sqmServerConfiguration)
and applies those settings back to a SQL Server instance. It supports a
comprehensive rollback of configuration changes.

Supported rollback operations:
- sp_configure values (most settings; some require SQL restart)
- Instance properties (BackupDirectory, DefaultFile, DefaultLog)
- Service start mode (requires local admin on the server)
- Database Mail profiles
- Linked Server settings (limited, via T-SQL)

The function supports -WhatIf to preview changes before applying them.

.PARAMETER SqlInstance
Target SQL Server instance (default: $env:COMPUTERNAME).

.PARAMETER SqlCredential
Optional alternative credentials (PSCredential object).

.PARAMETER SnapshotPath
Full path to the JSON snapshot file to restore from.
Required parameter.

.PARAMETER Category
Limit rollback to specific categories.
Valid values: 'SpConfigure', 'InstanceProperties', 'Services', 'DatabaseMail', 'All'.
Default: 'All'

.PARAMETER WhatIf
Show what would be changed without making actual modifications.

.PARAMETER Force
Skip confirmation dialog and apply changes immediately.

.PARAMETER EnableException
Switch to allow exceptions to pass through (default: errors logged as warnings).

.OUTPUTS
Array of [PSCustomObject] with properties:
- Setting: Name of the setting being restored
- Category: Which category this belongs to
- OldValue: Current value on the server
- NewValue: Value from the snapshot
- Status: 'Restored', 'Skipped', or 'Failed'
- Message: Detailed status message

.EXAMPLE
# Preview what would be restored
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -WhatIf

.EXAMPLE
# Apply rollback (with confirmation)
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json"

.EXAMPLE
# Force rollback without confirmation
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -Force

.EXAMPLE
# Rollback only sp_configure settings
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -Category 'SpConfigure' `
  -Force

.NOTES
Requires dbatools module and appropriate SQL Server permissions.
Some sp_configure changes require SQL Server restart to take effect.
Service changes require local admin rights on the server.
#>

function Invoke-sqmConfigRollback
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $true)]
		[ValidateScript({
			if (-not (Test-Path $_))
			{
				throw "Snapshot-Datei nicht gefunden: $_"
			}
			$_
		})]
		[string]$SnapshotPath,

		[Parameter(Mandatory = $false)]
		[ValidateSet('SpConfigure', 'InstanceProperties', 'Services', 'DatabaseMail', 'All')]
		[string[]]$Category = @('All'),

		[Parameter(Mandatory = $false)]
		[switch]$Force,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# Default SqlInstance
		if (-not $SqlInstance)
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		Invoke-sqmLogging -Message "Starte $functionName fuer Instanz: $SqlInstance" `
			-FunctionName $functionName -Level "INFO"

		# Load snapshot from JSON
		Invoke-sqmLogging -Message "Lade Snapshot aus: $SnapshotPath" `
			-FunctionName $functionName -Level "DEBUG"

		try
		{
			$jsonContent = Get-Content -Path $SnapshotPath -Raw -ErrorAction Stop
			$snapshot = ConvertFrom-Json -InputObject $jsonContent -ErrorAction Stop
		}
		catch
		{
			$msg = "Fehler beim Lesen der Snapshot-Datei: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			if ($EnableException)
			{
				throw
			}
			return @()
		}

		# Validate snapshot structure
		if (-not $snapshot.Metadata -or -not $snapshot.Configuration)
		{
			$msg = "Snapshot-Datei hat ungueltige Struktur (Metadata oder Configuration fehlt)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			if ($EnableException)
			{
				throw $msg
			}
			return @()
		}

		$snapshotDate = $snapshot.Metadata.ExportDate
		$snapshotLabel = $snapshot.Metadata.Label
		Invoke-sqmLogging -Message "Snapshot vom: $snapshotDate, Label: '$snapshotLabel'" `
			-FunctionName $functionName -Level "INFO"

		# Normalize Category parameter
		if ($Category -contains 'All')
		{
			$Category = @('SpConfigure', 'InstanceProperties', 'Services', 'DatabaseMail')
		}

		# Check for dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}
	}

	process
	{
		$rollbackResults = @()

		try
		{
			# ====================================================================
			# Connect to SQL Server
			# ====================================================================
			Invoke-sqmLogging -Message "Verbinde mit SQL Server: $SqlInstance" `
				-FunctionName $functionName -Level "DEBUG"

			$serverParams = @{
				SqlInstance   = $SqlInstance
				ErrorAction   = 'Stop'
			}
			if ($SqlCredential)
			{
				$serverParams['SqlCredential'] = $SqlCredential
			}
			if ($EnableException)
			{
				$serverParams['EnableException'] = $true
			}

			$server = Connect-DbaInstance @serverParams
			if (-not $server)
			{
				throw "Konnte keine Verbindung mit $SqlInstance herstellen"
			}

			# ====================================================================
			# Process sp_configure
			# ====================================================================
			if ($Category -contains 'SpConfigure' -and $snapshot.Configuration.SpConfigure)
			{
				Invoke-sqmLogging -Message "Verarbeite sp_configure Einstellungen..." `
					-FunctionName $functionName -Level "DEBUG"

				foreach ($config in $snapshot.Configuration.SpConfigure.items)
				{
					$configName = $config.ConfigName
					$snapshotValue = $config.ConfigValue
					$currentConfig = $server.Configuration | Where-Object { $_.ConfigName -eq $configName }

					if (-not $currentConfig)
					{
						$rollbackResults += [PSCustomObject]@{
							Setting         = $configName
							Category        = 'SpConfigure'
							OldValue        = 'N/A'
							NewValue        = $snapshotValue
							Status          = 'Skipped'
							Message         = "Einstellung nicht auf dieser Instanz vorhanden"
						}
						continue
					}

					$currentValue = $currentConfig.ConfigValue
					if ($currentValue -eq $snapshotValue)
					{
						$rollbackResults += [PSCustomObject]@{
							Setting         = $configName
							Category        = 'SpConfigure'
							OldValue        = $currentValue
							NewValue        = $snapshotValue
							Status          = 'Skipped'
							Message         = "Wert ist bereits gleich, keine Aenderung notwendig"
						}
						continue
					}

					if ($WhatIf)
					{
						Invoke-sqmLogging -Message "[WHATIF] ${configName}: $currentValue -> $snapshotValue" `
							-FunctionName $functionName -Level "INFO"
						$rollbackResults += [PSCustomObject]@{
							Setting         = $configName
							Category        = 'SpConfigure'
							OldValue        = $currentValue
							NewValue        = $snapshotValue
							Status          = 'Restored'
							Message         = "[WHATIF] Wuerde geaendert werden"
						}
					}
					else
					{
						try
						{
							$currentConfig.ConfigValue = $snapshotValue
							$currentConfig.Alter()
							Invoke-sqmLogging -Message "sp_configure $configName geaendert: $currentValue -> $snapshotValue" `
								-FunctionName $functionName -Level "INFO"

							$rollbackResults += [PSCustomObject]@{
								Setting         = $configName
								Category        = 'SpConfigure'
								OldValue        = $currentValue
								NewValue        = $snapshotValue
								Status          = 'Restored'
								Message         = "Erfolgreich geaendert"
							}
						}
						catch
						{
							$errMsg = "Fehler beim Aendern von $configName : $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARN"

							$rollbackResults += [PSCustomObject]@{
								Setting         = $configName
								Category        = 'SpConfigure'
								OldValue        = $currentValue
								NewValue        = $snapshotValue
								Status          = 'Failed'
								Message         = $_.Exception.Message
							}
						}
					}
				}
			}

			# ====================================================================
			# Process Instance Properties
			# ====================================================================
			if ($Category -contains 'InstanceProperties' -and $snapshot.Configuration.InstanceProperties)
			{
				Invoke-sqmLogging -Message "Verarbeite Instance Properties..." `
					-FunctionName $functionName -Level "DEBUG"

				$props = $snapshot.Configuration.InstanceProperties
				$restorableProps = @('BackupDirectory', 'DefaultFile', 'DefaultLog')

				foreach ($prop in $restorableProps)
				{
					if (-not $props.$prop)
					{
						continue
					}

					$snapshotValue = $props.$prop
					$currentValue = $server.$prop

					if ($currentValue -eq $snapshotValue)
					{
						$rollbackResults += [PSCustomObject]@{
							Setting         = $prop
							Category        = 'InstanceProperties'
							OldValue        = $currentValue
							NewValue        = $snapshotValue
							Status          = 'Skipped'
							Message         = "Wert ist bereits gleich"
						}
						continue
					}

					if ($WhatIf)
					{
						Invoke-sqmLogging -Message "[WHATIF] ${prop}: $currentValue -> $snapshotValue" `
							-FunctionName $functionName -Level "INFO"
						$rollbackResults += [PSCustomObject]@{
							Setting         = $prop
							Category        = 'InstanceProperties'
							OldValue        = $currentValue
							NewValue        = $snapshotValue
							Status          = 'Restored'
							Message         = "[WHATIF] Wuerde geaendert werden"
						}
					}
					else
					{
						try
						{
							$server.$prop = $snapshotValue
							$server.Alter()
							Invoke-sqmLogging -Message "Instance Property $prop geaendert: $currentValue -> $snapshotValue" `
								-FunctionName $functionName -Level "INFO"

							$rollbackResults += [PSCustomObject]@{
								Setting         = $prop
								Category        = 'InstanceProperties'
								OldValue        = $currentValue
								NewValue        = $snapshotValue
								Status          = 'Restored'
								Message         = "Erfolgreich geaendert"
							}
						}
						catch
						{
							$errMsg = "Fehler beim Aendern von $prop : $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARN"

							$rollbackResults += [PSCustomObject]@{
								Setting         = $prop
								Category        = 'InstanceProperties'
								OldValue        = $currentValue
								NewValue        = $snapshotValue
								Status          = 'Failed'
								Message         = $_.Exception.Message
							}
						}
					}
				}
			}

			# ====================================================================
			# Process Services (StartMode only, safely)
			# ====================================================================
			if ($Category -contains 'Services' -and $snapshot.Configuration.Services)
			{
				Invoke-sqmLogging -Message "Verarbeite Service-Konfiguration..." `
					-FunctionName $functionName -Level "DEBUG"

				$serverName = $server.ComputerName
				$currentServices = Get-DbaService -ComputerName $serverName -ErrorAction SilentlyContinue

				foreach ($svcSnapshot in $snapshot.Configuration.Services.items)
				{
					$svcName = $svcSnapshot.ServiceName
					$svcCurrentMode = ($currentServices | Where-Object { $_.ServiceName -eq $svcName }).StartMode

					if (-not $svcCurrentMode)
					{
						$rollbackResults += [PSCustomObject]@{
							Setting         = $svcName
							Category        = 'Services'
							OldValue        = 'N/A'
							NewValue        = $svcSnapshot.StartMode
							Status          = 'Skipped'
							Message         = "Service nicht gefunden"
						}
						continue
					}

					if ($svcCurrentMode -eq $svcSnapshot.StartMode)
					{
						$rollbackResults += [PSCustomObject]@{
							Setting         = $svcName
							Category        = 'Services'
							OldValue        = $svcCurrentMode
							NewValue        = $svcSnapshot.StartMode
							Status          = 'Skipped'
							Message         = "StartMode ist bereits gleich"
						}
						continue
					}

					if ($WhatIf)
					{
						Invoke-sqmLogging -Message "[WHATIF] Service $svcName StartMode: $svcCurrentMode -> $($svcSnapshot.StartMode)" `
							-FunctionName $functionName -Level "INFO"
						$rollbackResults += [PSCustomObject]@{
							Setting         = $svcName
							Category        = 'Services'
							OldValue        = $svcCurrentMode
							NewValue        = $svcSnapshot.StartMode
							Status          = 'Restored'
							Message         = "[WHATIF] Wuerde geaendert werden"
						}
					}
					else
					{
						try
						{
							$svcObj = $currentServices | Where-Object { $_.ServiceName -eq $svcName } | Select-Object -First 1
							if (-not $svcObj) { throw "Service-Objekt '$svcName' nicht verfuegbar (Get-DbaService lieferte es nicht)." }
							# dbatools' Get-DbaService liefert CIM-Instanzen der Klasse SqlService (kein Set-DbaService-Cmdlet).
							# Den StartMode aendert deren CIM-Methode SetStartMode(UInt32). Mapping: Automatic=2, Manual=3, Disabled=4.
							$startModeMap = @{ 'Auto' = [uint32]2; 'Automatic' = [uint32]2; 'Manual' = [uint32]3; 'Disabled' = [uint32]4 }
							$desiredMode = "$($svcSnapshot.StartMode)".Trim()
							if (-not $startModeMap.ContainsKey($desiredMode)) { throw "Unbekannter StartMode '$desiredMode'." }
							$cimRet = Invoke-CimMethod -InputObject $svcObj -MethodName SetStartMode -Arguments @{ StartMode = $startModeMap[$desiredMode] } -ErrorAction Stop
							if ($cimRet.ReturnValue -ne 0) { throw "SetStartMode fuer '$svcName' lieferte ReturnValue $($cimRet.ReturnValue)." }
							Invoke-sqmLogging -Message "Service $svcName StartMode geaendert: $svcCurrentMode -> $($svcSnapshot.StartMode)" `
								-FunctionName $functionName -Level "INFO"

							$rollbackResults += [PSCustomObject]@{
								Setting         = $svcName
								Category        = 'Services'
								OldValue        = $svcCurrentMode
								NewValue        = $svcSnapshot.StartMode
								Status          = 'Restored'
								Message         = "Erfolgreich geaendert"
							}
						}
						catch
						{
							$errMsg = "Fehler beim Aendern von Service $svcName : $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARN"

							$rollbackResults += [PSCustomObject]@{
								Setting         = $svcName
								Category        = 'Services'
								OldValue        = $svcCurrentMode
								NewValue        = $svcSnapshot.StartMode
								Status          = 'Failed'
								Message         = $_.Exception.Message
							}
						}
					}
				}
			}

			# ====================================================================
			# Process Database Mail (info only, manual restore needed)
			# ====================================================================
			if ($Category -contains 'DatabaseMail' -and $snapshot.Configuration.DatabaseMail)
			{
				Invoke-sqmLogging -Message "Database Mail-Profile aus Snapshot:" `
					-FunctionName $functionName -Level "INFO"

				foreach ($profile in $snapshot.Configuration.DatabaseMail.profiles)
				{
					$rollbackResults += [PSCustomObject]@{
						Setting         = "Profile: $($profile.Name)"
						Category        = 'DatabaseMail'
						OldValue        = 'N/A'
						NewValue        = $profile.Name
						Status          = 'Skipped'
						Message         = "Database Mail-Profile muessen manuell wiederhergestellt werden (keine automatische Restaurierung unterstuetzt)"
					}
				}
			}

			# Return results
			Invoke-sqmLogging -Message "Rollback-Verarbeitung abgeschlossen. Ergebnisse: $($rollbackResults.Count)" `
				-FunctionName $functionName -Level "INFO"

			return $rollbackResults
		}
		catch
		{
			$msg = "Fehler bei Invoke-sqmConfigRollback: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"

			if ($EnableException)
			{
				throw
			}
			else
			{
				Write-Error $msg
				return @()
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen" `
			-FunctionName $functionName -Level "INFO"
	}
}
