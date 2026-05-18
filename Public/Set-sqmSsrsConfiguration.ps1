function Set-sqmSsrsConfiguration
{
    <#
    .SYNOPSIS
        Configures SQL Server Reporting Services (SSRS) fully automatically.
        Supports local and remote installation as well as AlwaysOn environments.

    .DESCRIPTION
        Performs a complete initial or re-configuration of SSRS.
        Supports Native Mode and SharePoint Integrated Mode (automatic detection).

        Configurable areas (individually disableable):
        - Service account (SetWindowsServiceIdentity)
        - Database (create, grant permissions, set connection)
        - URLs (ReportServer Web Service + Portal, Native Mode only)
        - Encryption key (BackupEncryptionKey)

        For AlwaysOn Availability Groups (AG), the database server is automatically
        detected as a listener; the DB is created on the primary replica and the
        connection is configured to point to the listener.

        Optionally, a Policy-Based Management (PBM) policy (e.g. 'Password Policy')
        can be disabled before database creation and re-enabled after successful configuration.

    .PARAMETER ComputerName
        SSRS server (local or remote). Default: $env:COMPUTERNAME.

    .PARAMETER InstanceName
        SSRS instance name. Default: 'MSSQLSERVER'.

    .PARAMETER DatabaseServer
        SQL Server instance or AG listener for the ReportServer database.
        Default: $ComputerName.

    .PARAMETER DatabaseName
        Name of the ReportServer main database. Default: 'ReportServer'.

    .PARAMETER ReportServerUrl
        URL for the ReportServer Web Service. Default: 'http://+:80/ReportServer'

    .PARAMETER ReportsUrl
        URL for the Reports Manager / Web Portal. Default: 'http://+:80/Reports'

    .PARAMETER ServiceAccount
        Windows service account for SSRS (e.g. 'DOMAIN\user' or 'NT SERVICE\...').

    .PARAMETER ServiceAccountPassword
        Password for -ServiceAccount (SecureString). Not needed for managed service accounts.

    .PARAMETER DatabaseAuthType
        Authentication for the DB connection: 'Windows' (default) or 'SQL'.

    .PARAMETER DatabaseCredential
        PSCredential for SQL authentication (only with -DatabaseAuthType SQL).

    .PARAMETER EncryptionKeyFile
        Path for the encryption key backup (.snk). If not specified, the file is stored
        in OutputPath with the name 'SsrsEncryptionKey_<Instance>_<Date>.snk'.

    .PARAMETER EncryptionKeyPassword
        Password to protect the key file (SecureString). Required when a backup is to be created.

    .PARAMETER PbmPolicyName
        Name of a Policy-Based Management policy (e.g. 'Password Policy') that is
        disabled before database creation and re-enabled after successful configuration.

    .PARAMETER SkipDatabase
        Skip database configuration.

    .PARAMETER SkipUrls
        Skip URL configuration (Native Mode only).

    .PARAMETER SkipServiceAccount
        Skip service account configuration.

    .PARAMETER SkipEncryptionKeyBackup
        Skip encryption key backup.

    .PARAMETER Credential
        PSCredential for the WinRM connection (remote operation only).

    .PARAMETER OutputPath
        Output directory for the configuration report and optionally the key file.
        Default: Get-sqmDefaultOutputPath.

    .PARAMETER ContinueOnError
        Continue with the next step on error (rarely used).

    .PARAMETER EnableException
        Throw exceptions immediately.

    .PARAMETER Confirm
        Request confirmation before execution.

    .PARAMETER WhatIf
        Shows what would happen without making any changes.

    .EXAMPLE
        Set-sqmSsrsConfiguration

    .EXAMPLE
        Set-sqmSsrsConfiguration -ComputerName "SSRS01" -DatabaseServer "AG_Listener" -PbmPolicyName "Password Policy"

    .NOTES
        Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Get-sqmConfig, Set-sqmSqlPolicyState
        WMI namespace: root\Microsoft\SqlServer\ReportServer\<Instance>\v<Version>\Admin
    #>
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$InstanceName = 'MSSQLSERVER',
		[Parameter(Mandatory = $false)]
		[string]$DatabaseServer,
		[Parameter(Mandatory = $false)]
		[string]$DatabaseName = 'ReportServer',
		[Parameter(Mandatory = $false)]
		[string]$ReportServerUrl = 'http://+:80/ReportServer',
		[Parameter(Mandatory = $false)]
		[string]$ReportsUrl = 'http://+:80/Reports',
		[Parameter(Mandatory = $false)]
		[string]$ServiceAccount,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$ServiceAccountPassword,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Windows', 'SQL')]
		[string]$DatabaseAuthType = 'Windows',
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DatabaseCredential,
		[Parameter(Mandatory = $false)]
		[string]$EncryptionKeyFile,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$EncryptionKeyPassword,
		[Parameter(Mandatory = $false)]
		[string]$PbmPolicyName,
		[Parameter(Mandatory = $false)]
		[switch]$SkipDatabase,
		[Parameter(Mandatory = $false)]
		[switch]$SkipUrls,
		[Parameter(Mandatory = $false)]
		[switch]$SkipServiceAccount,
		[Parameter(Mandatory = $false)]
		[switch]$SkipEncryptionKeyBackup,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
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
		Invoke-sqmLogging -Message "Starte $functionName auf $ComputerName" -FunctionName $functionName -Level "INFO"
		
		$result = [PSCustomObject]@{
			ComputerName		 = $ComputerName
			InstanceName		 = $InstanceName
			SsrsMode			 = $null
			SsrsVersion		     = $null
			DatabaseServer	     = $DatabaseServer
			IsAgListener		 = $false
			AgPrimaryNode	     = $null
			ServiceAccountResult = 'Skipped'
			DatabaseResult	     = 'Skipped'
			UrlResult		     = 'Skipped'
			EncryptionKeyResult  = 'Skipped'
			OverallStatus	     = 'Unknown'
			Message			     = $null
			ReportPath		     = $null
		}
		if (-not $DatabaseServer) { $result.DatabaseServer = $ComputerName }
		
		$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
		$datestamp = Get-Date -Format 'yyyy-MM-dd'
		$safeComp = $ComputerName -replace '[\\/:*?"<>|]', '_'
		$safeInst = $InstanceName -replace '[\\/:*?"<>|]', '_'
		$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
		
		function _SecureToPlain([System.Security.SecureString]$s)
		{
			if (-not $s) { return '' }
			[System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
				[System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
		}
		
		$logLines = [System.Collections.Generic.List[string]]::new()
		function _Log($msg, $sev = 'INFO')
		{
			$logLines.Add("[$(Get-Date -Format 'HH:mm:ss')] [$sev] $msg")
			switch ($sev)
			{
				'ERROR'   { Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR" }
				'WARNING' { Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING" }
				default   { Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "VERBOSE" }
			}
		}
	}
	
	process
	{
		try
		{
			# CIM-Session
			$cimBase = @{ ErrorAction = 'Stop' }
			$cimSession = $null
			if ($isLocal)
			{
				_Log "Lokaler Betrieb - kein WinRM erforderlich."
			}
			else
			{
				_Log "Remote-Betrieb: Verbinde zu '$ComputerName' via WsMan..."
				$sessionOpts = New-CimSessionOption -Protocol Wsman
				$cimParams = @{ ComputerName = $ComputerName; SessionOption = $sessionOpts }
				if ($Credential) { $cimParams['Credential'] = $Credential }
				$cimSession = New-CimSession @cimParams -ErrorAction Stop
				$cimBase['CimSession'] = $cimSession
				_Log "CIM-Session hergestellt."
			}
			
			# SSRS WMI-Namespace
			$wmiConfig = $null
			$wmiVersion = $null
			$rsNamespace = 'root\Microsoft\SqlServer\ReportServer'
			$instNs = "$rsNamespace\$InstanceName"
			$versionNs = Get-CimInstance @cimBase -Namespace $instNs -ClassName '__NAMESPACE' -ErrorAction Stop |
			Where-Object { $_.Name -like 'v*' } |
			Sort-Object Name -Descending |
			Select-Object -First 1 -ExpandProperty Name
			if (-not $versionNs)
			{
				throw "Kein SSRS-Namespace unter '$instNs' gefunden."
			}
			$wmiVersion = $versionNs
			$adminNs = "$instNs\$versionNs\Admin"
			_Log "WMI-Namespace: $adminNs"
			
			$wmiConfig = Get-CimInstance @cimBase -Namespace $adminNs -ClassName 'MSReportServer_ConfigurationSetting' -ErrorAction Stop |
			Select-Object -First 1
			if (-not $wmiConfig)
			{
				throw "MSReportServer_ConfigurationSetting nicht gefunden."
			}
			
			$isSharePoint = [bool]$wmiConfig.IsSharePointIntegrated
			$result.SsrsMode = if ($isSharePoint) { 'SharePointIntegrated' }
			else { 'NativeMode' }
			$result.SsrsVersion = $wmiVersion
			$result.InstanceName = $wmiConfig.InstanceName
			
			Write-Host "[$ComputerName] SSRS $wmiVersion | $($result.SsrsMode) | Instanz: $($result.InstanceName)" -ForegroundColor Cyan
			_Log "SSRS $wmiVersion | Modus: $($result.SsrsMode) | Dienstkonto: $($wmiConfig.WindowsServiceIdentityActual)"
			
			function _InvokeCim($method, [hashtable]$arguments, $desc)
			{
				_Log "WMI ? $method - $desc"
				$r = Invoke-CimMethod @cimBase -Namespace $adminNs -ClassName 'MSReportServer_ConfigurationSetting' -MethodName $method -Arguments $arguments -ErrorAction Stop
				if ($r.HRESULT -ne 0)
				{
					throw "$method (HRESULT 0x$($r.HRESULT.ToString('X8'))): $($r.Error)"
				}
				return $r
			}
			
			# AG-Listener-Erkennung
			$dbCreateServer = $result.DatabaseServer
			$isAgListener = $false
			$agPrimaryNode = $null
			if (-not $SkipDatabase)
			{
				try
				{
					$listenerCheck = Invoke-DbaQuery -SqlInstance $result.DatabaseServer -ErrorAction SilentlyContinue -Query @"
SELECT ag.name AS AgName, agl.dns_name AS ListenerName, ar.replica_server_name AS PrimaryReplica
FROM sys.availability_group_listeners agl
JOIN sys.availability_groups ag ON ag.group_id = agl.group_id
JOIN sys.dm_hadr_availability_group_states ags ON ags.group_id = ag.group_id
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id AND ar.replica_id = ags.primary_replica
WHERE agl.dns_name = @@SERVERNAME OR UPPER(agl.dns_name) = UPPER('$($result.DatabaseServer.Split('\')[0])')
"@
					if ($listenerCheck)
					{
						$isAgListener = $true
						$agPrimaryNode = $listenerCheck.PrimaryReplica | Select-Object -First 1
						$result.IsAgListener = $true
						$result.AgPrimaryNode = $agPrimaryNode
						$dbCreateServer = if ($result.DatabaseServer -match '\\')
						{
							"$agPrimaryNode\$($result.DatabaseServer.Split('\')[1])"
						}
						else { $agPrimaryNode }
						Write-Host "  ? AG-Listener erkannt: '$($result.DatabaseServer)' ? Primary: '$agPrimaryNode'" -ForegroundColor Cyan
						_Log "AG-Listener '$($result.DatabaseServer)' ? Primary '$agPrimaryNode'. DB-Erstellung auf: '$dbCreateServer'"
					}
				}
				catch
				{
					_Log "AG-Listener-Pruefung: $($_.Exception.Message) (kein Listener - wird als normaler Server behandelt)"
				}
			}
			
			$errorsOccurred = $false
			
			# 1. Dienstkonto
			if ($ServiceAccount -and -not $SkipServiceAccount)
			{
				Write-Host "  [1/4] Dienstkonto konfigurieren: $ServiceAccount" -ForegroundColor Gray
				if ($PSCmdlet.ShouldProcess($ComputerName, "SSRS-Dienstkonto auf '$ServiceAccount' setzen"))
				{
					try
					{
						$useBuiltIn = $ServiceAccount -like 'NT SERVICE\*' -or $ServiceAccount -like 'NT AUTHORITY\*' -or
						$ServiceAccount -in @('LocalSystem', 'LocalService', 'NetworkService')
						$null = _InvokeCim 'SetWindowsServiceIdentity' @{
							UseBuiltInAccount = $useBuiltIn
							Account		      = $ServiceAccount
							Password		  = (_SecureToPlain $ServiceAccountPassword)
						} "Dienstkonto '$ServiceAccount'"
						$result.ServiceAccountResult = 'OK'
						Write-Host "  ? Dienstkonto gesetzt." -ForegroundColor Green
						_Log "Dienstkonto '$ServiceAccount' gesetzt."
						$wmiConfig = Get-CimInstance @cimBase -Namespace $adminNs -ClassName 'MSReportServer_ConfigurationSetting' -ErrorAction SilentlyContinue | Select-Object -First 1
					}
					catch
					{
						_Log "Dienstkonto-Fehler: $($_.Exception.Message)" 'ERROR'
						$result.ServiceAccountResult = 'Failed'
						$errorsOccurred = $true
						if (-not $ContinueOnError -and $EnableException) { throw }
					}
				}
				else { $result.ServiceAccountResult = 'WhatIf' }
			}
			
			# 2. Datenbank (inkl. PBM-Policy Deaktivierung/Reaktivierung)
			if (-not $SkipDatabase)
			{
				$dbServerDisplay = if ($isAgListener) { "$($result.DatabaseServer) (Listener) ? Primary: $agPrimaryNode" }
				else { $result.DatabaseServer }
				Write-Host "  [2/4] Datenbank konfigurieren: $DatabaseName auf $dbServerDisplay" -ForegroundColor Gray
				if ($PSCmdlet.ShouldProcess($ComputerName, "ReportServer-DB '$DatabaseName' konfigurieren"))
				{
					$pbmPolicyWasDisabled = $false
					try
					{
						# --- PBM-Policy deaktivieren (falls angegeben) ---
						if ($PbmPolicyName)
						{
							Write-Host "    Deaktiviere PBM-Policy '$PbmPolicyName' ..." -ForegroundColor Gray
							$policyArgs = @{
								SqlInstance	    = $dbCreateServer
								Policy		    = $PbmPolicyName
								State		    = 'Disable'
								ContinueOnError = $ContinueOnError
								EnableException = $EnableException
							}
							$null = Set-sqmSqlPolicyState @policyArgs
							$pbmPolicyWasDisabled = $true
							Write-Host "    ? Policy deaktiviert." -ForegroundColor Green
							_Log "PBM-Policy '$PbmPolicyName' auf '$dbCreateServer' deaktiviert."
						}
						
						# --- Bestehende DB-Logik ---
						$dbExists = $false
						try
						{
							$dbCheck = Invoke-DbaQuery -SqlInstance $dbCreateServer -Query "SELECT name FROM sys.databases WHERE name = N'$DatabaseName'" -ErrorAction SilentlyContinue
							$dbExists = $null -ne $dbCheck
						}
						catch { $dbExists = $false }
						
						if (-not $dbExists)
						{
							_Log "Datenbank '$DatabaseName' nicht vorhanden auf '$dbCreateServer' - lege an..."
							$genResult = _InvokeCim 'GenerateDatabaseCreationScript' @{
								DatabaseName = $DatabaseName
								Lcid		 = 1033
								IsSharePoint = $isSharePoint
							} "DB-Erstellungs-Skript generieren"
							Invoke-DbaQuery -SqlInstance $dbCreateServer -Query $genResult.Script -EnableException -ErrorAction Stop | Out-Null
							_Log "Datenbank '$DatabaseName' + '${DatabaseName}TempDB' auf '$dbCreateServer' angelegt."
							Write-Host "    Datenbank angelegt auf: $dbCreateServer" -ForegroundColor Gray
						}
						else
						{
							_Log "Datenbank '$DatabaseName' bereits vorhanden auf '$dbCreateServer'."
						}
						
						$isRemoteDb = ($ComputerName.Split('.')[0].ToUpper() -ne $dbCreateServer.Split('\\')[0].Split('.')[0].ToUpper()) -or $isAgListener
						$rightsResult = _InvokeCim 'GenerateDatabaseRightsScript' @{
							DatabaseName = $DatabaseName
							AccountName  = $wmiConfig.WindowsServiceIdentityActual
							IsRemote	 = $isRemoteDb
							IsWindowsAccount = ($DatabaseAuthType -eq 'Windows')
						} "Rechte-Skript generieren"
						if ($rightsResult.Script)
						{
							Invoke-DbaQuery -SqlInstance $dbCreateServer -Query $rightsResult.Script -EnableException -ErrorAction SilentlyContinue | Out-Null
							_Log "DB-Rechte fuer '$($wmiConfig.WindowsServiceIdentityActual)' auf '$dbCreateServer' gesetzt."
							if ($isAgListener)
							{
								_Log "AG-Info: DB-Rechte werden durch Synchronisation auf alle Secondaries repliziert."
								Write-Host "    ?  AG: Rechte werden auf Secondaries synchronisiert." -ForegroundColor Gray
							}
						}
						
						$dbAuthTypeInt = if ($DatabaseAuthType -eq 'SQL') { 1 }
						else { 2 }
						$dbUser = if ($DatabaseAuthType -eq 'SQL' -and $DatabaseCredential) { $DatabaseCredential.UserName }
						else { '' }
						$dbPwd = if ($DatabaseAuthType -eq 'SQL' -and $DatabaseCredential) { _SecureToPlain $DatabaseCredential.Password }
						else { '' }
						
						$null = _InvokeCim 'SetDatabaseConnection' @{
							Server = $result.DatabaseServer
							DatabaseName = $DatabaseName
							CredentialsType = $dbAuthTypeInt
							Username = $dbUser
							Password = $dbPwd
						} "DB-Verbindung konfigurieren (Server: $($result.DatabaseServer))"
						$result.DatabaseResult = 'OK'
						Write-Host "  ? Datenbank konfiguriert." -ForegroundColor Green
						_Log "SetDatabaseConnection: Server=$($result.DatabaseServer) / DB=$DatabaseName / Auth=$DatabaseAuthType"
					}
					catch
					{
						_Log "Datenbank-Fehler: $($_.Exception.Message)" 'ERROR'
						$result.DatabaseResult = 'Failed'
						$errorsOccurred = $true
						if (-not $ContinueOnError -and $EnableException) { throw }
					}
					finally
					{
						# --- PBM-Policy wieder aktivieren (falls zuvor deaktiviert) ---
						if ($pbmPolicyWasDisabled)
						{
							try
							{
								Write-Host "    Reaktiviere PBM-Policy '$PbmPolicyName' ..." -ForegroundColor Gray
								$policyArgs = @{
									SqlInstance	    = $dbCreateServer
									Policy		    = $PbmPolicyName
									State		    = 'Enable'
									ContinueOnError = $ContinueOnError
									EnableException = $EnableException
								}
								$null = Set-sqmSqlPolicyState @policyArgs
								Write-Host "    ? Policy wieder aktiviert." -ForegroundColor Green
								_Log "PBM-Policy '$PbmPolicyName' auf '$dbCreateServer' reaktiviert."
							}
							catch
							{
								_Log "Fehler beim Reaktivieren der Policy: $($_.Exception.Message)" 'WARNING'
								# Kein Throw, um das Hauptresultat nicht zu gefaehrden
							}
						}
					}
				}
				else { $result.DatabaseResult = 'WhatIf' }
			}
			
			# 3. URLs (nur Native Mode)
			if (-not $SkipUrls)
			{
				if ($isSharePoint)
				{
					_Log "SharePoint Integrated Mode - URL-Konfiguration entfaellt." 'WARNING'
					$result.UrlResult = 'NotApplicable'
				}
				else
				{
					Write-Host "  [3/4] URLs konfigurieren..." -ForegroundColor Gray
					if ($PSCmdlet.ShouldProcess($ComputerName, "URLs setzen: $ReportServerUrl | $ReportsUrl"))
					{
						try
						{
							$null = _InvokeCim 'ReserveURL' @{
								Application = 'ReportServerWebService'
								UrlString   = $ReportServerUrl
								Lcid	    = 1033
							} "ReportServerWebService: $ReportServerUrl"
							$reportsApp = if ([int]($wmiVersion -replace 'v', '') -ge 14) { 'ReportServerWebApp' }
							else { 'ReportManager' }
							$null = _InvokeCim 'ReserveURL' @{
								Application = $reportsApp
								UrlString   = $ReportsUrl
								Lcid	    = 1033
							} "${reportsApp}: $ReportsUrl"
							$result.UrlResult = 'OK'
							Write-Host "  ? URLs konfiguriert: $ReportServerUrl | $ReportsUrl" -ForegroundColor Green
							_Log "URLs: $ReportServerUrl + $ReportsUrl ($reportsApp)"
						}
						catch
						{
							_Log "URL-Fehler: $($_.Exception.Message)" 'ERROR'
							$result.UrlResult = 'Failed'
							$errorsOccurred = $true
							if (-not $ContinueOnError -and $EnableException) { throw }
						}
					}
					else { $result.UrlResult = 'WhatIf' }
				}
			}
			
			# 4. Encryption Key Backup
			$effectiveKeyFile = $EncryptionKeyFile
			if (-not $SkipEncryptionKeyBackup -and $EncryptionKeyPassword)
			{
				if (-not $effectiveKeyFile)
				{
					$effectiveKeyFile = Join-Path $OutputPath "SsrsEncryptionKey_${safeInst}_${datestamp}.snk"
					if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				}
				Write-Host "  [4/4] Encryption Key sichern..." -ForegroundColor Gray
				if ($PSCmdlet.ShouldProcess($ComputerName, "Encryption Key sichern nach '$effectiveKeyFile'"))
				{
					try
					{
						$keyResult = _InvokeCim 'BackupEncryptionKey' @{
							Password = (_SecureToPlain $EncryptionKeyPassword)
						} "BackupEncryptionKey"
						$keyDir = Split-Path $effectiveKeyFile -Parent
						if ($keyDir -and -not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
						[System.IO.File]::WriteAllBytes($effectiveKeyFile, $keyResult.KeyFile)
						$result.EncryptionKeyResult = 'OK'
						Write-Host "  ? Key gesichert: $effectiveKeyFile" -ForegroundColor Green
						_Log "Encryption Key gesichert: '$effectiveKeyFile'"
					}
					catch
					{
						_Log "Key-Backup-Fehler: $($_.Exception.Message)" 'ERROR'
						$result.EncryptionKeyResult = 'Failed'
						$errorsOccurred = $true
						if (-not $ContinueOnError -and $EnableException) { throw }
					}
				}
				else { $result.EncryptionKeyResult = 'WhatIf' }
			}
			
			# Bericht schreiben
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			$reportFile = Join-Path $OutputPath "SsrsConfiguration_${safeComp}_${safeInst}_${datestamp}.txt"
			$result.ReportPath = $reportFile
			$agInfo = if ($isAgListener) { "AG-Listener: $($result.DatabaseServer) ? Primary: $agPrimaryNode" }
			else { 'Kein AG-Listener' }
			$lines = @(
				"# ================================================================"
				"# MSSQLTools - SSRS Konfigurationsbericht"
				"# Server     : $ComputerName  ($(if ($isLocal) { 'lokal' }
					else { 'remote' }))"
				"# Instanz    : $InstanceName"
				"# SSRS-Modus : $($result.SsrsMode)  |  Version: $wmiVersion"
				"# DB-Server  : $($result.DatabaseServer)  |  $agInfo"
				"# Erstellt   : $timestamp"
				"# ================================================================"
				""
				"Ergebnisse:"
				"  Dienstkonto     : $($result.ServiceAccountResult)"
				"  Datenbank       : $($result.DatabaseResult)"
				"  URLs            : $($result.UrlResult)"
				"  Encryption Key  : $($result.EncryptionKeyResult)"
				""
				"Detail-Log:"
			) + $logLines
			$lines | Out-File -FilePath $reportFile -Encoding UTF8 -Force
			
			$centralPath = Get-sqmConfig -Key 'CentralPath'
			if ($centralPath)
			{
				$centralFile = Join-Path $centralPath (Split-Path $reportFile -Leaf)
				if (-not (Test-Path $centralPath)) { New-Item -ItemType Directory -Path $centralPath -Force | Out-Null }
				Copy-Item -Path $reportFile -Destination $centralFile -Force -ErrorAction SilentlyContinue
			}
			
			$result.OverallStatus = if ($errorsOccurred) { 'PartialSuccess' }
			else { 'Success' }
			$result.Message = "Dienstkonto: $($result.ServiceAccountResult) | Datenbank: $($result.DatabaseResult) | URLs: $($result.UrlResult) | Key: $($result.EncryptionKeyResult)"
			Write-Host ""
			Write-Host "[$ComputerName] SSRS-Konfiguration: $($result.OverallStatus)" -ForegroundColor $(if ($errorsOccurred) { 'Yellow' }
				else { 'Green' })
			Write-Host "  Bericht: $reportFile" -ForegroundColor Gray
		}
		catch
		{
			$errMsg = "Schwerer Fehler auf $ComputerName : $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$result.OverallStatus = 'Failed'
			$result.Message = $errMsg
		}
		finally
		{
			if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue }
		}
		return $result
	}
}