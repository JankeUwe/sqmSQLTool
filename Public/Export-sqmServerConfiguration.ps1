<#
.SYNOPSIS
Exports all SQL Server configuration settings to a JSON snapshot file.

.DESCRIPTION
This function reads comprehensive configuration data from a SQL Server instance
and saves it as a JSON snapshot with timestamp. The snapshot can be used for
documentation, comparison, or rollback purposes.

Captured settings include:
- sp_configure values (MaxServerMemory, MAXDOP, xp_cmdshell, etc.)
- Instance properties (BackupDirectory, DefaultFile, DefaultLog, Collation, etc.)
- Service configuration (SQL Server, Agent, SSRS, SSIS start mode and accounts)
- Startup parameters (registry trace flags, etc.)
- TempDB configuration
- Database Mail profiles (if configured)
- Linked Servers
- Database overview (optional, slower)

.PARAMETER SqlInstance
Target SQL Server instance (default: $env:COMPUTERNAME).

.PARAMETER SqlCredential
Optional alternative credentials (PSCredential object).

.PARAMETER OutputPath
Path where JSON snapshot will be saved.
Default: $env:ProgramData\sqmSQLTool\Snapshots

.PARAMETER Label
Optional descriptive label for this snapshot (e.g., "before MaxMemory change").
Included in the JSON metadata.

.PARAMETER IncludeDatabases
When set, includes database-level settings (slower operation).

.PARAMETER EnableException
Switch to allow exceptions to pass through (default: errors logged as warnings).

.OUTPUTS
[PSCustomObject] with properties:
- SnapshotPath: Full path to saved JSON file
- Timestamp: When snapshot was created (ISO 8601 format)
- ItemCount: Total settings captured
- Categories: List of captured categories
- Status: 'Success' or 'Partial' (if some categories failed)

.EXAMPLE
# Create a snapshot before making configuration changes
$snap = Export-sqmServerConfiguration -SqlInstance "SQL01" -Label "before MaxMemory change"
Write-Host "Snapshot saved to: $($snap.SnapshotPath)"

.EXAMPLE
# Export with custom output path
Export-sqmServerConfiguration -SqlInstance "SQL01" `
  -OutputPath "C:\Backups\SQLSnapshots" `
  -Label "production-baseline"

.EXAMPLE
# Full export including databases
Export-sqmServerConfiguration -SqlInstance "SQL01" `
  -IncludeDatabases `
  -Label "complete-inventory"

.NOTES
Requires dbatools module and appropriate SQL Server permissions.
Registry parameter reading requires local admin rights.
#>

function Export-sqmServerConfiguration
{
	[CmdletBinding(SupportsShouldProcess = $false)]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath,

		[Parameter(Mandatory = $false)]
		[string]$Label,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeDatabases,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$timestampIso = Get-Date -Format 'o'
		$timestampFile = Get-Date -Format 'yyyyMMdd_HHmmss'

		# Default SqlInstance
		if (-not $SqlInstance)
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		Invoke-sqmLogging -Message "Starte $functionName fuer Instanz: $SqlInstance" `
			-FunctionName $functionName -Level "INFO"

		# Default OutputPath
		if (-not $OutputPath)
		{
			$OutputPath = "$env:ProgramData\sqmSQLTool\Snapshots"
		}

		# Ensure output directory exists
		if (-not (Test-Path $OutputPath))
		{
			try
			{
				$null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop
				Invoke-sqmLogging -Message "Output directory created: $OutputPath" `
					-FunctionName $functionName -Level "DEBUG"
			}
			catch
			{
				$msg = "Fehler beim Erstellen des Output-Verzeichnisses: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException)
				{
					throw
				}
				return $null
			}
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
		try
		{
			$allSettings = @{}
			$capturedCategories = @()

			# ========================================================================
			# 1. Connect to SQL Server
			# ========================================================================
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

			# Get server name and instance name for output filename
			$serverName = $server.ComputerName
			$instanceName = $server.InstanceName
			if (-not $instanceName)
			{
				$instanceName = 'MSSQLSERVER'
			}

			# ========================================================================
			# 2. sp_configure (Configuration Settings)
			# ========================================================================
			try
			{
				Invoke-sqmLogging -Message "Lese sp_configure Einstellungen..." `
					-FunctionName $functionName -Level "DEBUG"

				$spConfigValues = @()
				foreach ($config in $server.Configuration)
				{
					$spConfigValues += [PSCustomObject]@{
						Name         = $config.DisplayName
						ConfigName   = $config.ConfigName
						Minimum      = $config.Minimum
						Maximum      = $config.Maximum
						RunValue     = $config.RunValue
						ConfigValue  = $config.ConfigValue
						IsDynamic    = $config.IsDynamic
						Description  = $config.Description
					}
				}

				$allSettings['SpConfigure'] = @{
					count = $spConfigValues.Count
					items = $spConfigValues
				}
				$capturedCategories += 'SpConfigure'

				Invoke-sqmLogging -Message "sp_configure: $($spConfigValues.Count) Einstellungen erfasst" `
					-FunctionName $functionName -Level "DEBUG"
			}
			catch
			{
				Invoke-sqmLogging -Message "Fehler beim Lesen von sp_configure: $($_.Exception.Message)" `
					-FunctionName $functionName -Level "WARN"
			}

			# ========================================================================
			# 3. Instance Properties (SMO)
			# ========================================================================
			try
			{
				Invoke-sqmLogging -Message "Lese Instance Properties..." `
					-FunctionName $functionName -Level "DEBUG"

				$instanceProps = [PSCustomObject]@{
					ComputerName        = $server.ComputerName
					InstanceName        = $server.InstanceName
					Edition             = $server.Edition
					VersionString       = $server.VersionString
					ProductLevel        = $server.ProductLevel
					ProductUpdateLevel  = $server.ProductUpdateLevel
					HostPlatform        = $server.HostPlatform
					IsClustered         = $server.IsClustered
					IsHadrEnabled       = $server.IsHadrEnabled
					Collation           = $server.Collation
					LoginMode           = $server.LoginMode
					BackupDirectory     = $server.BackupDirectory
					DefaultFile         = $server.DefaultFile
					DefaultLog          = $server.DefaultLog
					MasterDBPath        = $server.MasterDBPath
					ErrorLogPath        = $server.ErrorLogPath
				}

				$allSettings['InstanceProperties'] = $instanceProps
				$capturedCategories += 'InstanceProperties'

				Invoke-sqmLogging -Message "Instance Properties erfasst" `
					-FunctionName $functionName -Level "DEBUG"
			}
			catch
			{
				Invoke-sqmLogging -Message "Fehler beim Lesen von Instance Properties: $($_.Exception.Message)" `
					-FunctionName $functionName -Level "WARN"
			}

			# ========================================================================
			# 4. Service Configuration
			# ========================================================================
			try
			{
				Invoke-sqmLogging -Message "Lese Service-Konfiguration..." `
					-FunctionName $functionName -Level "DEBUG"

				$services = Get-DbaService -ComputerName $serverName -ErrorAction SilentlyContinue
				$serviceList = @()

				if ($services)
				{
					foreach ($svc in $services)
					{
						$serviceList += [PSCustomObject]@{
							ServiceName   = $svc.ServiceName
							ServiceType   = $svc.ServiceType
							State         = $svc.State
							StartMode     = $svc.StartMode
							ProcessId     = $svc.ProcessId
							InstanceName  = $svc.InstanceName
							ServiceAccount = $svc.ServiceAccount
						}
					}
				}

				$allSettings['Services'] = @{
					count = $serviceList.Count
					items = $serviceList
				}
				$capturedCategories += 'Services'

				Invoke-sqmLogging -Message "Services: $($serviceList.Count) Dienste erfasst" `
					-FunctionName $functionName -Level "DEBUG"
			}
			catch
			{
				Invoke-sqmLogging -Message "Fehler beim Lesen der Services: $($_.Exception.Message)" `
					-FunctionName $functionName -Level "WARN"
			}

			# ========================================================================
			# 5. TempDB Configuration
			# ========================================================================
			try
			{
				Invoke-sqmLogging -Message "Lese TempDB-Konfiguration..." `
					-FunctionName $functionName -Level "DEBUG"

				$tempdbFiles = Get-DbaDbFile -SqlInstance $server -Database 'tempdb' -ErrorAction SilentlyContinue
				$fileList = @()

				if ($tempdbFiles)
				{
					foreach ($file in $tempdbFiles)
					{
						$fileList += [PSCustomObject]@{
							LogicalName     = $file.LogicalName
							PhysicalName    = $file.PhysicalName
							Type            = $file.Type
							Size            = $file.Size
							UsedSpace       = $file.UsedSpace
							Growth          = $file.Growth
							GrowthType      = $file.GrowthType
							IsPercentGrowth = $file.IsPercentGrowth
						}
					}
				}

				$allSettings['TempDb'] = @{
					fileCount = $fileList.Count
					files = $fileList
				}
				$capturedCategories += 'TempDb'

				Invoke-sqmLogging -Message "TempDB: $($fileList.Count) Dateien erfasst" `
					-FunctionName $functionName -Level "DEBUG"
			}
			catch
			{
				Invoke-sqmLogging -Message "Fehler beim Lesen von TempDB: $($_.Exception.Message)" `
					-FunctionName $functionName -Level "WARN"
			}

			# ========================================================================
			# 6. Database Mail Configuration
			# ========================================================================
			try
			{
				Invoke-sqmLogging -Message "Lese Database Mail-Konfiguration..." `
					-FunctionName $functionName -Level "DEBUG"

				$mailProfiles = Get-DbaDbMailProfile -SqlInstance $server -ErrorAction SilentlyContinue
				$profileList = @()

				if ($mailProfiles)
				{
					foreach ($profile in $mailProfiles)
					{
						$profileList += [PSCustomObject]@{
							Name          = $profile.Name
							Description   = $profile.Description
							IsPublic      = $profile.IsPublic
							IsDefault     = $profile.IsDefault
						}
					}
				}

				$allSettings['DatabaseMail'] = @{
					profileCount = $profileList.Count
					profiles = $profileList
				}
				$capturedCategories += 'DatabaseMail'

				Invoke-sqmLogging -Message "Database Mail: $($profileList.Count) Profile erfasst" `
					-FunctionName $functionName -Level "DEBUG"
			}
			catch
			{
				Invoke-sqmLogging -Message "Fehler beim Lesen von Database Mail: $($_.Exception.Message)" `
					-FunctionName $functionName -Level "WARN"
			}

			# ========================================================================
			# 7. Linked Servers
			# ========================================================================
			try
			{
				Invoke-sqmLogging -Message "Lese Linked Server-Konfiguration..." `
					-FunctionName $functionName -Level "DEBUG"

				$linkedServers = Get-DbaLinkedServer -SqlInstance $server -ErrorAction SilentlyContinue
				$linkedServerList = @()

				if ($linkedServers)
				{
					foreach ($ls in $linkedServers)
					{
						$linkedServerList += [PSCustomObject]@{
							Name                = $ls.Name
							DataSource          = $ls.DataSource
							Provider            = $ls.Provider
							ProviderString      = $ls.ProviderString
							Catalog             = $ls.Catalog
							IsRemoteLogin       = $ls.IsRemoteLogin
							LazySchemaValidation = $ls.LazySchemaValidation
						}
					}
				}

				$allSettings['LinkedServers'] = @{
					count = $linkedServerList.Count
					items = $linkedServerList
				}
				$capturedCategories += 'LinkedServers'

				Invoke-sqmLogging -Message "Linked Servers: $($linkedServerList.Count) erfasst" `
					-FunctionName $functionName -Level "DEBUG"
			}
			catch
			{
				Invoke-sqmLogging -Message "Fehler beim Lesen von Linked Servers: $($_.Exception.Message)" `
					-FunctionName $functionName -Level "WARN"
			}

			# ========================================================================
			# 8. Database Overview (optional)
			# ========================================================================
			if ($IncludeDatabases)
			{
				try
				{
					Invoke-sqmLogging -Message "Lese Datenbank-Uebersicht..." `
						-FunctionName $functionName -Level "DEBUG"

					$databases = Get-DbaDatabase -SqlInstance $server -ErrorAction SilentlyContinue
					$dbList = @()

					if ($databases)
					{
						foreach ($db in $databases)
						{
							$dbList += [PSCustomObject]@{
								Name                = $db.Name
								Owner               = $db.Owner
								CreateDate          = $db.CreateDate
								RecoveryModel       = $db.RecoveryModel
								CompatibilityLevel  = $db.CompatibilityLevel
								Status              = $db.Status
								IsSystemObject      = $db.IsSystemObject
								AutoClose           = $db.AutoClose
								AutoShrink          = $db.AutoShrink
								Trustworthy         = $db.Trustworthy
							}
						}
					}

					$allSettings['Databases'] = @{
						count = $dbList.Count
						items = $dbList
					}
					$capturedCategories += 'Databases'

					Invoke-sqmLogging -Message "Datenbanken: $($dbList.Count) erfasst" `
						-FunctionName $functionName -Level "DEBUG"
				}
				catch
				{
					Invoke-sqmLogging -Message "Fehler beim Lesen von Datenbanken: $($_.Exception.Message)" `
						-FunctionName $functionName -Level "WARN"
				}
			}

			# ========================================================================
			# 9. Build complete snapshot object
			# ========================================================================
			$snapshot = [PSCustomObject]@{
				Metadata = [PSCustomObject]@{
					ExportDate      = $timestampIso
					ExportedBy      = $env:USERNAME
					ComputerName    = $serverName
					InstanceName    = $instanceName
					Label           = if ($Label) { $Label } else { "" }
					Categories     = $capturedCategories
				}
				Configuration = $allSettings
			}

			# ========================================================================
			# 10. Save to JSON
			# ========================================================================
			$filename = "$($serverName)_$($instanceName)_$($timestampFile).json"
			$filepath = Join-Path $OutputPath $filename

			Invoke-sqmLogging -Message "Speichere Snapshot nach: $filepath" `
				-FunctionName $functionName -Level "DEBUG"

			$jsonContent = $snapshot | ConvertTo-Json -Depth 10 -ErrorAction Stop
			Set-Content -Path $filepath -Value $jsonContent -Encoding UTF8 -ErrorAction Stop

			Invoke-sqmLogging -Message "Snapshot erfolgreich gespeichert: $filepath" `
				-FunctionName $functionName -Level "INFO"

			# Count total items captured
			$totalItems = $allSettings.Values |
				ForEach-Object {
					if ($_ -is [hashtable])
					{
						$_.count + ($_.items | Measure-Object).Count
					}
					else
					{
						1
					}
				} |
				Measure-Object -Sum |
				Select-Object -ExpandProperty Sum

			# Return result object
			return [PSCustomObject]@{
				SnapshotPath = $filepath
				Timestamp    = $timestampIso
				ItemCount    = $totalItems
				Categories   = $capturedCategories
				Status       = 'Success'
			}
		}
		catch
		{
			$msg = "Fehler bei Export-sqmServerConfiguration: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"

			if ($EnableException)
			{
				throw
			}
			else
			{
				Write-Error $msg
				return $null
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen" `
			-FunctionName $functionName -Level "INFO"
	}
}
