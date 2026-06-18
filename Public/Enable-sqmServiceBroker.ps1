<#
.SYNOPSIS
    Enables Service Broker on a specified database and creates SSB endpoint.

.DESCRIPTION
    Performs the following operations:
    1. Sets database to SINGLE_USER mode with ROLLBACK IMMEDIATE (forces user disconnections)
    2. Enables Service Broker (SET ENABLE_BROKER)
    3. Returns database to MULTI_USER mode
    4. Creates SSBEndpoint on port 4022 with WINDOWS authentication (if not exists)
    5. Grants CONNECT permission to PUBLIC

    This function is designed for both single-instance and AlwaysOn configurations.
    For AlwaysOn, the endpoint is created server-wide and applies to all replicas.

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER DatabaseName
    Name of the database to enable Service Broker on. Required.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER Force
    Skip confirmation prompt and proceed directly.

.PARAMETER OutputPath
    Output directory for log file. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER ContinueOnError
    Continue on error (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.EXAMPLE
    Enable-sqmServiceBroker -DatabaseName "OperationsManager"

.EXAMPLE
    Enable-sqmServiceBroker -SqlInstance "SQL01" -DatabaseName "OperationsManager" -Force

.NOTES
    Author:       sqmSQLTool
    Prerequisites: dbatools, sysadmin permissions
    Warning:      SINGLE_USER mode disconnects all active users. This is intentional and required.
#>
function Enable-sqmServiceBroker
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
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

		Invoke-sqmLogging -Message "Starte $functionName für Datenbank: $DatabaseName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# Verbindung herstellen
			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop

			# Ausgabeverzeichnis erstellen
			if (-not (Test-Path $OutputPath))
			{
				$null = New-Item -ItemType Directory -Path $OutputPath -Force
			}

			# Log-Datei
			$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
			$cleanServerName = $server.Name -replace '\\', '-'
			$logFile = Join-Path $OutputPath ("ServiceBrokerEnable_" + $cleanServerName + "_" + $timestamp + ".txt")
			$logContent = [System.Collections.Generic.List[string]]::new()

			$logContent.Add("Service Broker Enable Log") | Out-Null
			$logContent.Add("=" * 80) | Out-Null
			$logContent.Add("Server:       $($server.Name)") | Out-Null
			$logContent.Add("Database:     $DatabaseName") | Out-Null
			$logContent.Add("Started:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
			$logContent.Add("") | Out-Null

			# Bestätigung
			if ($Force -or $PSCmdlet.ShouldProcess("$DatabaseName on $SqlInstance", "Enable Service Broker"))
			{
				$logContent.Add("STEP 1: Set database to SINGLE_USER mode with ROLLBACK IMMEDIATE") | Out-Null
				Invoke-sqmLogging -Message "Setze $DatabaseName auf SINGLE_USER mit ROLLBACK IMMEDIATE..." -FunctionName $functionName -Level "INFO"

				try
				{
					$server.Query("ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE", "master")
					$logContent.Add("  Status: OK - Database set to SINGLE_USER") | Out-Null
					Invoke-sqmLogging -Message "  OK - Database set to SINGLE_USER" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = "Fehler beim Setzen auf SINGLE_USER: $_"
					$logContent.Add("  Status: FAILED - $errMsg") | Out-Null
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					throw
				}

				$logContent.Add("") | Out-Null
				$logContent.Add("STEP 2: Enable Service Broker") | Out-Null
				Invoke-sqmLogging -Message "Aktiviere Service Broker auf $DatabaseName..." -FunctionName $functionName -Level "INFO"

				try
				{
					$server.Query("ALTER DATABASE [$DatabaseName] SET ENABLE_BROKER", "master")
					$logContent.Add("  Status: OK - Service Broker enabled") | Out-Null
					Invoke-sqmLogging -Message "  OK - Service Broker enabled" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = "Fehler beim Aktivieren von Service Broker: $_"
					$logContent.Add("  Status: FAILED - $errMsg") | Out-Null
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					# Zurück zu MULTI_USER vor Fehler
					try
					{
						$server.Query("ALTER DATABASE [$DatabaseName] SET MULTI_USER", "master")
						$logContent.Add("  Rollback: Database set to MULTI_USER") | Out-Null
					}
					catch { }
					throw
				}

				$logContent.Add("") | Out-Null
				$logContent.Add("STEP 3: Set database back to MULTI_USER") | Out-Null
				Invoke-sqmLogging -Message "Setze $DatabaseName zurück auf MULTI_USER..." -FunctionName $functionName -Level "INFO"

				try
				{
					$server.Query("ALTER DATABASE [$DatabaseName] SET MULTI_USER", "master")
					$logContent.Add("  Status: OK - Database set to MULTI_USER") | Out-Null
					Invoke-sqmLogging -Message "  OK - Database set to MULTI_USER" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = "Fehler beim Setzen auf MULTI_USER: $_"
					$logContent.Add("  Status: FAILED - $errMsg") | Out-Null
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					throw
				}

				# Kurze Pause damit DB wieder online kommt
				Start-Sleep -Milliseconds 500

				$logContent.Add("") | Out-Null
				$logContent.Add("STEP 4: Create SSB Endpoint (if not exists)") | Out-Null
				Invoke-sqmLogging -Message "Prüfe/erstelle SSBEndpoint auf Port 4022..." -FunctionName $functionName -Level "INFO"

				try
				{
					# Prüfe ob Endpoint schon existiert
					$endpointExists = $server.Query(@"
SELECT COUNT(*) as cnt FROM sys.service_broker_endpoints WHERE name = 'SSBEndpoint'
"@)

					if ($endpointExists.cnt -gt 0)
					{
						$logContent.Add("  Status: OK - SSBEndpoint already exists") | Out-Null
						Invoke-sqmLogging -Message "  SSBEndpoint existiert bereits" -FunctionName $functionName -Level "INFO"
					}
					else
					{
						$createEndpointSql = @"
CREATE ENDPOINT [SSBEndpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 4022, LISTENER_IP = ALL)
    FOR SERVICE_BROKER (AUTHENTICATION = WINDOWS)
"@
						$server.Query($createEndpointSql, "master")
						$logContent.Add("  Status: OK - SSBEndpoint created on port 4022") | Out-Null
						Invoke-sqmLogging -Message "  SSBEndpoint erstellt auf Port 4022" -FunctionName $functionName -Level "INFO"
					}
				}
				catch
				{
					$errMsg = "Fehler beim Erstellen des Endpoints: $_"
					$logContent.Add("  Status: FAILED - $errMsg") | Out-Null
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARN"
					# Nicht fatal - fortsetzbar
				}

				$logContent.Add("") | Out-Null
				$logContent.Add("STEP 5: Grant CONNECT permission to PUBLIC") | Out-Null
				Invoke-sqmLogging -Message "Gewähre CONNECT-Berechtigung auf SSBEndpoint..." -FunctionName $functionName -Level "INFO"

				try
				{
					$server.Query("GRANT CONNECT ON ENDPOINT::[SSBEndpoint] TO [PUBLIC]", "master")
					$logContent.Add("  Status: OK - CONNECT permission granted to PUBLIC") | Out-Null
					Invoke-sqmLogging -Message "  CONNECT-Berechtigung gewährt" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = "Fehler beim Gewähren der Berechtigung: $_"
					$logContent.Add("  Status: FAILED - $errMsg") | Out-Null
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARN"
				}

				# Verifikation
				$logContent.Add("") | Out-Null
				$logContent.Add("VERIFICATION") | Out-Null
				$logContent.Add("-" * 80) | Out-Null

				$verifyQuery = "SELECT is_broker_enabled FROM sys.databases WHERE name = '$DatabaseName'"
				$verifyResult = $server.Query($verifyQuery)
				$brokerEnabled = $verifyResult.is_broker_enabled -eq 1

				$logContent.Add("Service Broker Status: $(if ($brokerEnabled) { 'ENABLED' } else { 'DISABLED' })") | Out-Null
				Invoke-sqmLogging -Message "Service Broker Status: $(if ($brokerEnabled) { 'ENABLED' } else { 'DISABLED' })" -FunctionName $functionName -Level "INFO"

				$logContent.Add("") | Out-Null
				$logContent.Add("=" * 80) | Out-Null
				$logContent.Add("Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
				$logContent.Add("Status: $(if ($brokerEnabled) { 'SUCCESS' } else { 'PARTIAL' })") | Out-Null

				# Log-Datei schreiben
				$logContent -join "`n" | Out-File -FilePath $logFile -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "Log-Datei erstellt: $logFile" -FunctionName $functionName -Level "INFO"

				# Return
				$result = [PSCustomObject]@{
					ComputerName         = $server.Name
					DatabaseName         = $DatabaseName
					BrokerEnabled        = $brokerEnabled
					LogPath              = $logFile
					Timestamp            = $timestamp
					Status               = if ($brokerEnabled) { "SUCCESS" } else { "PARTIAL" }
				}

				return $result
			}
			else
			{
				Invoke-sqmLogging -Message "Abgebrochen durch Benutzer" -FunctionName $functionName -Level "WARN"
				return $null
			}
		}
		catch
		{
			$errMsg = "Fehler in $functionName`:`n$_"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException)
			{
				throw
			}
			elseif (-not $ContinueOnError)
			{
				throw
			}
		}
	}
}

