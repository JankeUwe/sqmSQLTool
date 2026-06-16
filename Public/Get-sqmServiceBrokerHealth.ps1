<#
.SYNOPSIS
    Creates a health report for SQL Server Service Broker configuration and status.

.DESCRIPTION
    Retrieves Service Broker information from a SQL Server instance:
    - Service Broker status (enabled/disabled per database)
    - Endpoints on port 4022 (SSBEndpoint)
    - Queue status and message counts
    - Undeliverable messages in transmission queue
    - Service pairs and their contracts
    - Replica status (if AlwaysOn AG is configured)

    Results are saved as a TXT report in the specified directory.
    The function automatically detects single-instance or AlwaysOn configurations.

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER ContinueOnError
    Continue on error (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.EXAMPLE
    Get-sqmServiceBrokerHealth

.EXAMPLE
    Get-sqmServiceBrokerHealth -SqlInstance "SQL01" -OutputPath "D:\Reports"

.NOTES
    Author:       sqmSQLTool
    Prerequisites: dbatools
    Default output path: C:\System\WinSrvLog\MSSQL
#>
function Get-sqmServiceBrokerHealth
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
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

		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# Verbindung herstellen
			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop

			# Ausgabeverzeichnis erstellen falls nicht vorhanden
			if (-not (Test-Path $OutputPath))
			{
				$null = New-Item -ItemType Directory -Path $OutputPath -Force
				Invoke-sqmLogging -Message "Verzeichnis erstellt: $OutputPath" -FunctionName $functionName -Level "INFO"
			}

			# Report-Metadaten
			$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
			$reportFile = Join-Path $OutputPath "ServiceBrokerHealth_$($server.Name)_$timestamp.txt"
			$reportContent = [System.Collections.Generic.List[string]]::new()

			# Header
			$reportContent.Add("=" * 80) | Out-Null
			$reportContent.Add("SQL Server Service Broker Health Report") | Out-Null
			$reportContent.Add("=" * 80) | Out-Null
			$reportContent.Add("Server:      $($server.Name)") | Out-Null
			$reportContent.Add("Generated:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
			$reportContent.Add("") | Out-Null

			# 1. AlwaysOn Auto-Detect
			$agQuery = "SELECT COUNT(*) as AGCount FROM sys.availability_groups"
			$agResult = $server.Query($agQuery)
			$isAlwaysOn = $agResult.AGCount -gt 0
			$reportContent.Add("Configuration: $(if ($isAlwaysOn) { 'AlwaysOn Availability Group' } else { 'Single System' })") | Out-Null
			$reportContent.Add("") | Out-Null

			# 2. Broker Endpoints
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Broker Endpoints") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$epQuery = @"
SELECT
    name,
    state_desc,
    protocol_desc,
    port,
    authentication_desc
FROM sys.service_broker_endpoints
ORDER BY name
"@

			$endpoints = $server.Query($epQuery)
			if ($endpoints)
			{
				foreach ($ep in $endpoints)
				{
					$reportContent.Add("  Endpoint:        $($ep.name)") | Out-Null
					$reportContent.Add("  State:           $($ep.state_desc)") | Out-Null
					$reportContent.Add("  Port:            $($ep.port)") | Out-Null
					$reportContent.Add("  Authentication:  $($ep.authentication_desc)") | Out-Null
					$reportContent.Add("") | Out-Null
				}
			}
			else
			{
				$reportContent.Add("  No Service Broker endpoints found on port 4022") | Out-Null
				$reportContent.Add("") | Out-Null
			}

			# 3. Broker Status per Database
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Broker Status per Database") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$brokerQuery = @"
SELECT
    name,
    is_broker_enabled,
    state_desc
FROM sys.databases
WHERE state_desc = 'ONLINE'
ORDER BY name
"@

			$brokerDbs = $server.Query($brokerQuery)
			$enabledCount = ($brokerDbs | Where-Object { $_.is_broker_enabled -eq 1 }).Count
			$disabledCount = ($brokerDbs | Where-Object { $_.is_broker_enabled -eq 0 }).Count

			$reportContent.Add("  Enabled:  $enabledCount") | Out-Null
			$reportContent.Add("  Disabled: $disabledCount") | Out-Null
			$reportContent.Add("") | Out-Null

			foreach ($db in $brokerDbs)
			{
				$status = if ($db.is_broker_enabled) { "ENABLED" } else { "DISABLED" }
				$reportContent.Add("  $($db.name): $status") | Out-Null
			}
			$reportContent.Add("") | Out-Null

			# 4. Service Queues und Message Counts
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Queues and Message Status") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$queueQuery = @"
SELECT
    DB_NAME() as DatabaseName,
    name,
    is_enqueue_enabled,
    is_dequeue_enabled,
    is_retention_enabled,
    (SELECT COUNT(*) FROM sys.service_queue_internal_table WHERE queue_id = sq.object_id) as MessageCount
FROM sys.service_queues sq
WHERE database_id = DB_ID()
ORDER BY name
"@

			foreach ($db in $brokerDbs | Where-Object { $_.is_broker_enabled -eq 1 })
			{
				$queues = $server.Query($queueQuery, $db.name)
				if ($queues)
				{
					$reportContent.Add("  Database: $($db.name)") | Out-Null
					foreach ($q in $queues)
					{
						$reportContent.Add("    Queue:       $($q.name)") | Out-Null
						$reportContent.Add("    Messages:    $($q.MessageCount)") | Out-Null
						$reportContent.Add("    Enqueue:     $(if ($q.is_enqueue_enabled) { 'ON' } else { 'OFF' })") | Out-Null
						$reportContent.Add("    Dequeue:     $(if ($q.is_dequeue_enabled) { 'ON' } else { 'OFF' })") | Out-Null
						$reportContent.Add("") | Out-Null
					}
				}
			}

			# 5. Undeliverable Messages
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Undeliverable Messages (Transmission Queue)") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$undeliverableQuery = @"
SELECT
    COUNT(*) as UndeliverableCount,
    DB_NAME() as DatabaseName
FROM sys.transmission_queue
WHERE database_id = DB_ID()
GROUP BY database_id
"@

			$undeliverable = $server.Query($undeliverableQuery)
			if ($undeliverable -and $undeliverable.UndeliverableCount -gt 0)
			{
				foreach ($u in $undeliverable)
				{
					$reportContent.Add("  Database: $($u.DatabaseName)") | Out-Null
					$reportContent.Add("  Count:    $($u.UndeliverableCount) messages") | Out-Null
					$reportContent.Add("") | Out-Null
				}
			}
			else
			{
				$reportContent.Add("  No undeliverable messages found") | Out-Null
				$reportContent.Add("") | Out-Null
			}

			# 6. Service Pairs and Contracts
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Pairs and Contracts") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$serviceQuery = @"
SELECT
    DB_NAME() as DatabaseName,
    s.name as ServiceName,
    sc.name as ContractName
FROM sys.services s
LEFT JOIN sys.service_contract_usages scu ON s.service_id = scu.service_id
LEFT JOIN sys.service_contracts sc ON scu.service_contract_id = sc.service_contract_id
WHERE s.database_id = DB_ID()
ORDER BY s.name
"@

			foreach ($db in $brokerDbs | Where-Object { $_.is_broker_enabled -eq 1 })
			{
				$services = $server.Query($serviceQuery, $db.name)
				if ($services)
				{
					$reportContent.Add("  Database: $($db.name)") | Out-Null
					foreach ($svc in $services)
					{
						$contract = if ($svc.ContractName) { $svc.ContractName } else { "N/A" }
						$reportContent.Add("    Service:  $($svc.ServiceName)") | Out-Null
						$reportContent.Add("    Contract: $contract") | Out-Null
						$reportContent.Add("") | Out-Null
					}
				}
			}

			# 7. AlwaysOn Replica Status (falls AG vorhanden)
			if ($isAlwaysOn)
			{
				$reportContent.Add("-" * 80) | Out-Null
				$reportContent.Add("AlwaysOn Replica Status") | Out-Null
				$reportContent.Add("-" * 80) | Out-Null

				$replicaQuery = @"
SELECT
    ag.name as AGName,
    ar.replica_server_name,
    ar.availability_mode_desc,
    ars.role_desc,
    ars.operational_state_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
ORDER BY ag.name, ar.replica_server_name
"@

				$replicas = $server.Query($replicaQuery)
				if ($replicas)
				{
					foreach ($r in $replicas)
					{
						$reportContent.Add("  AG:       $($r.AGName)") | Out-Null
						$reportContent.Add("  Replica:  $($r.replica_server_name)") | Out-Null
						$reportContent.Add("  Role:     $($r.role_desc)") | Out-Null
						$reportContent.Add("  State:    $($r.operational_state_desc)") | Out-Null
						$reportContent.Add("") | Out-Null
					}
				}
			}

			# Footer
			$reportContent.Add("=" * 80) | Out-Null
			$reportContent.Add("End of Report") | Out-Null

			# Report schreiben
			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "Report erstellt: $reportFile" -FunctionName $functionName -Level "INFO"

			# Return
			$result = [PSCustomObject]@{
				ComputerName = $server.Name
				ReportPath   = $reportFile
				Timestamp    = $timestamp
				IsAlwaysOn   = $isAlwaysOn
			}

			if (-not $NoOpen)
			{
				try
				{
					& notepad.exe $reportFile
				}
				catch
				{
					Invoke-sqmLogging -Message "Konnte Report nicht öffnen: $_" -FunctionName $functionName -Level "WARN"
				}
			}

			return $result
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

