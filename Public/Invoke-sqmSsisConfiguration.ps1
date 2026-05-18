<#
.SYNOPSIS
    Configures SQL Server Integration Services (SSIS) fully automatically.
    Supports standalone and AlwaysOn AG environments, local and remote.

.DESCRIPTION
    Performs a complete initial or re-configuration of SSIS:
    1. SSIS service (service account + startup type)
    2. SSISDB catalog (incl. CLR activation, properties)
    3. AlwaysOn AG integration (SSISDB into AG, DMK restore, disable cleanup job, sp_ssis_startup)
    4. Create catalog folders and environments

    Connection modes: Local (direct) / Remote (dbatools + WinRM for service).

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the SQL connection.

.PARAMETER AgName
    Name of the AlwaysOn Availability Group (optional).

.PARAMETER AgListener
    AG listener name (automatically determined if not specified).

.PARAMETER AgNodes
    Explicit list of all AG nodes (optional).

.PARAMETER CatalogPassword
    Password for the SSISDB catalog (SecureString, required).

.PARAMETER CatalogFolder
    Array of catalog folder names (e.g. @('ETL','Staging')).

.PARAMETER CatalogFolderDescription
    Description for the folders (default: 'Created by MSSQLTools').

.PARAMETER Environments
    Array of environment names (created in each CatalogFolder).

.PARAMETER SsisServiceAccount
    Service account for the SSIS service (e.g. 'DOMAIN\svc_ssis').

.PARAMETER SsisServiceAccountPassword
    Password for the service account (SecureString).

.PARAMETER SsisServiceStartupType
    Startup type of the SSIS service (Automatic, Manual, Disabled; default: Automatic).

.PARAMETER RetentionPeriod
    Retention period for SSISDB logs in days (default: 365).

.PARAMETER LoggingLevel
    Logging level (0=None, 1=Basic, 2=Performance, 3=Verbose; default: 1).

.PARAMETER MaxConcurrentExecutables
    Maximum concurrent executions (default: -1 = unlimited).

.PARAMETER SkipService
    Skip service configuration.

.PARAMETER SkipCatalog
    Skip catalog creation/configuration.

.PARAMETER SkipAg
    Skip AG integration (even if -AgName is specified).

.PARAMETER SkipFolders
    Skip folder/environment creation.

.PARAMETER WinRmCredential
    Credentials for WinRM (remote service configuration, optional).

.PARAMETER OutputPath
    Output directory for the configuration report.
    Default: Get-sqmDefaultOutputPath.

.PARAMETER ContinueOnError
    Continue with the next step on error (rarely used).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before critical changes.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    $pwd = Read-Host "SSISDB-Kennwort" -AsSecureString
    Invoke-sqmSsisConfiguration -SqlInstance "SQL01" -CatalogPassword $pwd

.EXAMPLE
    $pwd = Read-Host "SSISDB-Kennwort" -AsSecureString
    Invoke-sqmSsisConfiguration -SqlInstance "SQL01" -AgName "AG_SSIS" -CatalogPassword $pwd

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath.
#>
function Invoke-sqmSsisConfiguration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$AgName,
		[Parameter(Mandatory = $false)]
		[string]$AgListener,
		[Parameter(Mandatory = $false)]
		[string[]]$AgNodes,
		[Parameter(Mandatory = $true)]
		[System.Security.SecureString]$CatalogPassword,
		[Parameter(Mandatory = $false)]
		[string[]]$CatalogFolder,
		[Parameter(Mandatory = $false)]
		[string]$CatalogFolderDescription = 'Angelegt von MSSQLTools',
		[Parameter(Mandatory = $false)]
		[string[]]$Environments,
		[Parameter(Mandatory = $false)]
		[string]$SsisServiceAccount,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$SsisServiceAccountPassword,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Automatic', 'Manual', 'Disabled')]
		[string]$SsisServiceStartupType = 'Automatic',
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 3650)]
		[int]$RetentionPeriod = 365,
		[Parameter(Mandatory = $false)]
		[ValidateSet(0, 1, 2, 3)]
		[int]$LoggingLevel = 1,
		[Parameter(Mandatory = $false)]
		[int]$MaxConcurrentExecutables = -1,
		[Parameter(Mandatory = $false)]
		[switch]$SkipService,
		[Parameter(Mandatory = $false)]
		[switch]$SkipCatalog,
		[Parameter(Mandatory = $false)]
		[switch]$SkipAg,
		[Parameter(Mandatory = $false)]
		[switch]$SkipFolders,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$WinRmCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
		
		# Hilfsfunktion: SecureString ? Klartext (fuer T-SQL)
		function _SecureToPlain([System.Security.SecureString]$s)
		{
			if (-not $s) { return '' }
			[System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
				[System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
		}
		
		$result = [PSCustomObject]@{
			SqlInstance    = $SqlInstance
			AgName		   = $AgName
			AgListener	   = $AgListener
			AgNodes	       = $null
			ServiceResult  = 'Skipped'
			CatalogResult  = 'Skipped'
			AgResult	   = 'Skipped'
			FolderResult   = 'Skipped'
			FoldersCreated = @()
			EnvironmentsCreated = @()
			OverallStatus  = 'Unknown'
			Message	       = $null
			ReportPath	   = $null
		}
		
		$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
		$datestamp = Get-Date -Format 'yyyy-MM-dd'
		$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
		$isLocal = ($SqlInstance -split '[\\,]')[0] -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
		$useWinRm = if ($WinRmCredential) { $WinRmCredential }
		else { $SqlCredential }
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
		
		$logMessages = [System.Collections.Generic.List[string]]::new()
		$errorsOccurred = $false
	}
	
	process
	{
		try
		{
			# SQL-Verbindung pruefen
			$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop
			Invoke-sqmLogging -Message "SQL-Verbindung hergestellt: $($sqlSrv.VersionString)" -FunctionName $functionName -Level "INFO"
			
			# SSIS-Version ermitteln
			$sqlMajor = $sqlSrv.VersionMajor
			$ssisSuffix = switch ($sqlMajor)
			{
				16 { '160' } 15 { '150' } 14 { '140' } 13 { '130' } 12 { '120' }
				default { '150' }
			}
			$ssisServiceName = "MsDtsServer$ssisSuffix"
			Invoke-sqmLogging -Message "SSIS-Dienst: $ssisServiceName (SQL Major: $sqlMajor)" -FunctionName $functionName -Level "INFO"
			
			# AG-Metadaten (falls benoetigt)
			$primaryNode = ($SqlInstance -split '\\')[0]
			$allAgNodes = @($primaryNode)
			$effectiveListener = $AgListener
			
			if ($AgName -and -not $SkipAg)
			{
				try
				{
					$agState = Invoke-DbaQuery @connParams -ErrorAction Stop -Query @"
SELECT
    ar.replica_server_name   AS ReplicaServer,
    ags.primary_replica      AS PrimaryReplica,
    agl.dns_name             AS ListenerDns
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
LEFT JOIN sys.availability_group_listeners agl ON ag.group_id = agl.group_id
WHERE ag.name = '$AgName';
"@
					if (-not $agState) { throw "AG '$AgName' nicht gefunden auf '$SqlInstance'." }
					$primaryNode = ($agState | Select-Object -First 1).PrimaryReplica
					$allAgNodes = @($agState.ReplicaServer | Sort-Object -Unique)
					if (-not $effectiveListener) { $effectiveListener = ($agState | Select-Object -First 1).ListenerDns }
					$result.AgListener = $effectiveListener
					$result.AgNodes = $allAgNodes
					# Umleitung zum Primary falls noetig
					if ($primaryNode -and ($SqlInstance -split '\\')[0].ToUpper() -ne $primaryNode.ToUpper())
					{
						Invoke-sqmLogging -Message "Aktuelle Instanz ist nicht Primary - wechsle zu $primaryNode" -FunctionName $functionName -Level "INFO"
						$connParams['SqlInstance'] = if ($SqlInstance -match '\\') { "$primaryNode\$($SqlInstance.Split('\')[1])" }
						else { $primaryNode }
						$result.SqlInstance = $connParams['SqlInstance']
						$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop
					}
					if ($AgNodes) { $allAgNodes = $AgNodes }
					Invoke-sqmLogging -Message "AG '$AgName' | Primary: $primaryNode | Listener: $effectiveListener | Nodes: $($allAgNodes -join ', ')" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					Invoke-sqmLogging -Message "AG-Metadaten-Fehler: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}
			$result.AgNodes = $allAgNodes
			
			# 1. SSIS-Dienst konfigurieren
			if (-not $SkipService -and ($SsisServiceAccount -or $SsisServiceStartupType))
			{
				Invoke-sqmLogging -Message "SSIS-Dienst konfigurieren ..." -FunctionName $functionName -Level "INFO"
				$serviceNodes = if ($AgName -and -not $SkipAg) { $allAgNodes }
				else { @($primaryNode) }
				$serviceErrors = 0
				foreach ($node in $serviceNodes)
				{
					$nodeHost = ($node -split '\\')[0]
					if (-not $PSCmdlet.ShouldProcess($nodeHost, "SSIS-Dienst '$ssisServiceName' konfigurieren"))
					{
						$result.ServiceResult = 'WhatIf'
						continue
					}
					try
					{
						if ($SsisServiceAccount)
						{
							$cimParams = @{ ClassName = 'Win32_Service'; ErrorAction = 'Stop' }
							if ($nodeHost -notin @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.'))
							{
								$cimOpts = New-CimSessionOption -Protocol Wsman
								$cimSession = New-CimSession -ComputerName $nodeHost -SessionOption $cimOpts -Credential $useWinRm -ErrorAction Stop
								$cimParams['CimSession'] = $cimSession
							}
							$svc = Get-CimInstance @cimParams -Filter "Name='$ssisServiceName'"
							if ($svc)
							{
								$pwdPlain = _SecureToPlain $SsisServiceAccountPassword
								Invoke-CimMethod -InputObject $svc -MethodName 'Change' -Arguments @{
									StartName	  = $SsisServiceAccount
									StartPassword = $pwdPlain
								} -ErrorAction Stop
								Invoke-sqmLogging -Message "[$nodeHost] Dienstkonto auf '$SsisServiceAccount' gesetzt" -FunctionName $functionName -Level "INFO"
							}
							else
							{
								Invoke-sqmLogging -Message "[$nodeHost] Dienst '$ssisServiceName' nicht gefunden" -FunctionName $functionName -Level "WARNING"
							}
							if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue }
						}
						# Starttyp setzen
						$svcObj = Get-DbaService -ComputerName $nodeHost -InstanceName ($SqlInstance -split '\\' | Select-Object -Last 1) -Type SSIS -ErrorAction SilentlyContinue | Select-Object -First 1
						if ($svcObj)
						{
							Set-Service -Name $ssisServiceName -StartupType $SsisServiceStartupType -ComputerName $nodeHost -ErrorAction SilentlyContinue
							Invoke-sqmLogging -Message "[$nodeHost] Starttyp: $SsisServiceStartupType" -FunctionName $functionName -Level "INFO"
						}
						if ($SsisServiceStartupType -eq 'Automatic')
						{
							$svcStatus = Get-Service -Name $ssisServiceName -ComputerName $nodeHost -ErrorAction SilentlyContinue
							if ($svcStatus -and $svcStatus.Status -ne 'Running')
							{
								Start-Service -InputObject $svcStatus -ErrorAction SilentlyContinue
								Invoke-sqmLogging -Message "[$nodeHost] Dienst gestartet" -FunctionName $functionName -Level "INFO"
							}
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$nodeHost] Dienst-Fehler: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						$serviceErrors++
					}
				}
				$result.ServiceResult = if ($serviceErrors -eq 0) { 'OK' }
				elseif ($serviceErrors -lt $serviceNodes.Count) { 'PartialOK' }
				else { 'Failed' }
				if ($result.ServiceResult -eq 'Failed') { $errorsOccurred = $true }
			}
			
			# 2. SSISDB-Katalog
			if (-not $SkipCatalog)
			{
				Invoke-sqmLogging -Message "SSISDB-Katalog konfigurieren ..." -FunctionName $functionName -Level "INFO"
				if (-not $PSCmdlet.ShouldProcess($connParams['SqlInstance'], 'SSISDB-Katalog anlegen/konfigurieren'))
				{
					$result.CatalogResult = 'WhatIf'
				}
				else
				{
					try
					{
						# CLR aktivieren
						$clrEnabled = Invoke-DbaQuery @connParams -Query "SELECT value_in_use FROM sys.configurations WHERE name = 'clr enabled';" -ErrorAction Stop
						if ($clrEnabled.value_in_use -ne 1)
						{
							Invoke-sqmLogging -Message "CLR aktivieren ..." -FunctionName $functionName -Level "INFO"
							Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query @"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'clr enabled', 1; RECONFIGURE;
"@
						}
						# SSISDB existiert?
						$ssisDbExists = Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.databases WHERE name = 'SSISDB';" -ErrorAction SilentlyContinue
						if (-not $ssisDbExists)
						{
							$catPwdPlain = _SecureToPlain $CatalogPassword
							Invoke-sqmLogging -Message "Erstelle SSISDB-Katalog ..." -FunctionName $functionName -Level "INFO"
							Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query @"
CREATE DATABASE SSISDB;
EXEC SSISDB.catalog.create_catalog
    @catalog_password = N'$($catPwdPlain -replace "'", "''")',
    @catalog_name     = N'SSISDB';
"@
						}
						# Eigenschaften setzen
						Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query @"
USE SSISDB;
EXEC catalog.configure_catalog @property_name = 'RETENTION_WINDOW', @property_value = $RetentionPeriod;
EXEC catalog.configure_catalog @property_name = 'MAX_PROJECT_VERSIONS', @property_value = 10;
EXEC catalog.configure_catalog @property_name = 'LOGGING_LEVEL', @property_value = $LoggingLevel;
EXEC catalog.configure_catalog @property_name = 'SCHEMA_BUILD', @property_value = 0;
"@
						if ($MaxConcurrentExecutables -ne -1)
						{
							Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query @"
EXEC catalog.configure_catalog @property_name = 'MAX_CONCURRENT_EXECUTABLES', @property_value = $MaxConcurrentExecutables;
"@
						}
						$result.CatalogResult = 'OK'
						Invoke-sqmLogging -Message "Katalog konfiguriert (Retention=$RetentionPeriod, Logging=$LoggingLevel)" -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						Invoke-sqmLogging -Message "Katalog-Fehler: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
						$result.CatalogResult = 'Failed'
						$errorsOccurred = $true
						if (-not $ContinueOnError -or $EnableException) { throw }
					}
				}
			}
			
			# 3. AlwaysOn AG-Integration
			if ($AgName -and -not $SkipAg)
			{
				Invoke-sqmLogging -Message "AlwaysOn AG-Integration ..." -FunctionName $functionName -Level "INFO"
				if (-not $PSCmdlet.ShouldProcess($connParams['SqlInstance'], "SSISDB in AG '$AgName' aufnehmen"))
				{
					$result.AgResult = 'WhatIf'
				}
				else
				{
					try
					{
						# Recovery FULL
						$recModel = Invoke-DbaQuery @connParams -Query "SELECT recovery_model_desc FROM sys.databases WHERE name = 'SSISDB';" -ErrorAction Stop
						if ($recModel.recovery_model_desc -ne 'FULL')
						{
							Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query "ALTER DATABASE SSISDB SET RECOVERY FULL;"
						}
						# Full Backup (fuer Seeding)
						$backupDir = $sqlSrv.BackupDirectory
						$backupFile = Join-Path $backupDir "SSISDB_AgSetup_$(Get-Date -f 'yyyyMMddHHmm').bak"
						Invoke-sqmLogging -Message "Full Backup SSISDB: $backupFile" -FunctionName $functionName -Level "INFO"
						Backup-DbaDatabase @connParams -Database SSISDB -FilePath $backupFile -Type Full -CompressBackup -EnableException -ErrorAction Stop | Out-Null
						# DMK sichern
						$dmkBackupFile = Join-Path $env:TEMP "SSISDB_DMK_$(Get-Date -f 'yyyyMMddHHmm').key"
						$catPwdPlain = _SecureToPlain $CatalogPassword
						Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query @"
USE SSISDB;
BACKUP MASTER KEY TO FILE = N'$($dmkBackupFile -replace "'", "''")'
ENCRYPTION BY PASSWORD = N'$($catPwdPlain -replace "'", "''")';
"@
						# SSISDB in AG aufnehmen
						$inAg = Invoke-DbaQuery @connParams -Query "SELECT d.name FROM sys.dm_hadr_database_replica_states r JOIN sys.databases d ON d.database_id = r.database_id JOIN sys.availability_groups ag ON ag.group_id = r.group_id WHERE d.name = 'SSISDB' AND ag.name = '$AgName';" -ErrorAction SilentlyContinue
						if (-not $inAg)
						{
							Invoke-sqmLogging -Message "Fuege SSISDB zu AG '$AgName' hinzu ..." -FunctionName $functionName -Level "INFO"
							Add-DbaAgDatabase @connParams -AvailabilityGroup $AgName -Database SSISDB -SeedingMode Automatic -EnableException -ErrorAction Stop | Out-Null
						}
						# DMK auf Secondaries wiederherstellen
						$secondaryNodes = $allAgNodes | Where-Object { $_.Split('\')[0].ToUpper() -ne $primaryNode.ToUpper() }
						foreach ($secNode in $secondaryNodes)
						{
							$secInst = if ($secNode -match '\\') { $secNode }
							else { $secNode }
							$secConn = @{ SqlInstance = $secInst }
							if ($SqlCredential) { $secConn['SqlCredential'] = $SqlCredential }
							try
							{
								Invoke-DbaQuery @secConn -EnableException -ErrorAction Stop -Query @"
USE SSISDB;
RESTORE MASTER KEY FROM FILE = N'$($dmkBackupFile -replace "'", "''")'
DECRYPTION BY PASSWORD = N'$($catPwdPlain -replace "'", "''")'
ENCRYPTION BY SERVICE MASTER KEY FORCE;
"@
								Invoke-sqmLogging -Message "DMK auf $secInst wiederhergestellt" -FunctionName $functionName -Level "INFO"
							}
							catch
							{
								Invoke-sqmLogging -Message "DMK-Restore auf $secInst fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							}
						}
						# sp_ssis_startup auf allen Nodes aktivieren
						foreach ($node in $allAgNodes)
						{
							$nodeInst = if ($node -match '\\') { $node }
							elseif ($SqlInstance -match '\\') { "$node\$($SqlInstance.Split('\')[1])" }
							else { $node }
							$nodeConn = @{ SqlInstance = $nodeInst }
							if ($SqlCredential) { $nodeConn['SqlCredential'] = $SqlCredential }
							try
							{
								Invoke-DbaQuery @nodeConn -EnableException -ErrorAction Stop -Query @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.procedures WHERE name = 'sp_ssis_startup' AND schema_id = SCHEMA_ID('dbo'))
    EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_procoption @ProcName = N'sp_ssis_startup', @OptionName = 'startup', @OptionValue = 'on';
"@
								Invoke-sqmLogging -Message "sp_ssis_startup auf $nodeInst aktiviert" -FunctionName $functionName -Level "INFO"
							}
							catch
							{
								Invoke-sqmLogging -Message "sp_ssis_startup auf $nodeInst fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							}
						}
						# SSIS Maintenance Job auf Secondaries deaktivieren
						foreach ($secNode in $secondaryNodes)
						{
							$secInst = if ($secNode -match '\\') { $secNode }
							else { $secNode }
							$secConn = @{ SqlInstance = $secInst }
							if ($SqlCredential) { $secConn['SqlCredential'] = $SqlCredential }
							try
							{
								Invoke-DbaQuery @secConn -EnableException -ErrorAction Stop -Query "UPDATE msdb.dbo.sysjobs SET enabled = 0 WHERE name = 'SSIS Server Maintenance Job';"
								Invoke-sqmLogging -Message "SSIS Maintenance Job auf $secInst deaktiviert" -FunctionName $functionName -Level "INFO"
							}
							catch
							{
								Invoke-sqmLogging -Message "SSIS Maintenance Job auf $secInst fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							}
						}
						# Linked Server fuer Listener anlegen
						if ($effectiveListener)
						{
							foreach ($node in $allAgNodes)
							{
								$nodeInst = if ($node -match '\\') { $node }
								elseif ($SqlInstance -match '\\') { "$node\$($SqlInstance.Split('\')[1])" }
								else { $node }
								$nodeConn = @{ SqlInstance = $nodeInst }
								if ($SqlCredential) { $nodeConn['SqlCredential'] = $SqlCredential }
								try
								{
									Invoke-DbaQuery @nodeConn -EnableException -ErrorAction Stop -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = '$effectiveListener')
BEGIN
    EXEC sp_addlinkedserver @server = N'$effectiveListener', @srvproduct = N'', @provider = N'SQLNCLI', @datasrc = N'$effectiveListener';
    EXEC sp_serveroption @server = N'$effectiveListener', @optname = N'RPC Out', @optvalue = N'True';
END
"@
									Invoke-sqmLogging -Message "Linked Server '$effectiveListener' auf $nodeInst geprueft" -FunctionName $functionName -Level "INFO"
								}
								catch
								{
									Invoke-sqmLogging -Message "Linked Server auf $nodeInst fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
								}
							}
						}
						$result.AgResult = 'OK'
					}
					catch
					{
						Invoke-sqmLogging -Message "AG-Integration fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
						$result.AgResult = 'Failed'
						$errorsOccurred = $true
						if (-not $ContinueOnError -or $EnableException) { throw }
					}
				}
			}
			
			# 4. Ordner und Umgebungen
			if ($CatalogFolder -and -not $SkipFolders)
			{
				Invoke-sqmLogging -Message "Ordner und Umgebungen anlegen ..." -FunctionName $functionName -Level "INFO"
				if (-not $PSCmdlet.ShouldProcess($connParams['SqlInstance'], "Ordner anlegen: $($CatalogFolder -join ', ')"))
				{
					$result.FolderResult = 'WhatIf'
				}
				else
				{
					$createdFolders = [System.Collections.Generic.List[string]]::new()
					$createdEnvs = [System.Collections.Generic.List[string]]::new()
					$folderErrors = 0
					foreach ($folder in $CatalogFolder)
					{
						try
						{
							$exists = Invoke-DbaQuery @connParams -Query "SELECT folder_id FROM SSISDB.catalog.folders WHERE name = N'$($folder -replace "'", "''")';" -ErrorAction Stop
							if (-not $exists)
							{
								Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query @"
EXEC SSISDB.catalog.create_folder
    @folder_name        = N'$($folder -replace "'", "''")',
    @folder_description = N'$($CatalogFolderDescription -replace "'", "''")';
"@
								$createdFolders.Add($folder)
								Invoke-sqmLogging -Message "Ordner '$folder' angelegt" -FunctionName $functionName -Level "INFO"
							}
							else
							{
								Invoke-sqmLogging -Message "Ordner '$folder' bereits vorhanden" -FunctionName $functionName -Level "INFO"
							}
							foreach ($env in $Environments)
							{
								$envExists = Invoke-DbaQuery @connParams -Query "SELECT e.environment_id FROM SSISDB.catalog.environments e JOIN SSISDB.catalog.folders f ON f.folder_id = e.folder_id WHERE f.name = N'$($folder -replace "'", "''")' AND e.name = N'$($env -replace "'", "''")';" -ErrorAction SilentlyContinue
								if (-not $envExists)
								{
									Invoke-DbaQuery @connParams -EnableException -ErrorAction Stop -Query @"
EXEC SSISDB.catalog.create_environment
    @environment_name        = N'$($env -replace "'", "''")',
    @environment_description = N'$env - angelegt von MSSQLTools',
    @folder_name             = N'$($folder -replace "'", "''")';
"@
									$createdEnvs.Add("$folder/$env")
									Invoke-sqmLogging -Message "Umgebung '$env' in Ordner '$folder' angelegt" -FunctionName $functionName -Level "INFO"
								}
							}
						}
						catch
						{
							Invoke-sqmLogging -Message "Fehler bei Ordner '$folder': $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							$folderErrors++
						}
					}
					$result.FoldersCreated = $createdFolders.ToArray()
					$result.EnvironmentsCreated = $createdEnvs.ToArray()
					$result.FolderResult = if ($folderErrors -eq 0) { 'OK' }
					else { 'PartialOK' }
					if ($result.FolderResult -eq 'Failed') { $errorsOccurred = $true }
				}
			}
			
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$errorsOccurred = $true
		}
	}
	
	end
	{
		# Bericht schreiben
		if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
		$reportFile = Join-Path $OutputPath "SsisConfiguration_${safeInst}_${datestamp}.txt"
		$result.ReportPath = $reportFile
		@"
# ================================================================
# MSSQLTools - SSIS Konfigurationsbericht
# Instanz    : $SqlInstance  ($(if ($isLocal) { 'lokal' }
			else { 'remote' }))
# AG         : $(if ($AgName) { $AgName }
			else { '(Standalone)' })
# Listener   : $(if ($effectiveListener) { $effectiveListener }
			else { '(keiner)' })
# AG-Nodes   : $($allAgNodes -join ', ')
# Erstellt   : $timestamp
# ================================================================

Ergebnisse:
  Dienst        : $($result.ServiceResult)
  Katalog       : $($result.CatalogResult)
  AG-Integration: $($result.AgResult)
  Ordner        : $($result.FolderResult)
  Ordner neu    : $($result.FoldersCreated -join ', ')
  Umgebungen    : $($result.EnvironmentsCreated -join ', ')
"@ | Out-File -FilePath $reportFile -Encoding UTF8 -Force
		
		Copy-sqmToCentralPath -Path $reportFile
		
		$result.OverallStatus = if ($errorsOccurred) { 'PartialSuccess' }
		else { 'Success' }
		$result.Message = "Dienst: $($result.ServiceResult) | Katalog: $($result.CatalogResult) | AG: $($result.AgResult) | Ordner: $($result.FolderResult)"
		Invoke-sqmLogging -Message "$functionName abgeschlossen. Status: $($result.OverallStatus)" -FunctionName $functionName -Level "INFO"
		return $result
	}
}