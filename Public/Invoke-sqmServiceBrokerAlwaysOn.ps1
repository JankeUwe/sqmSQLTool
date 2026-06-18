<#
.SYNOPSIS
    Enables Service Broker on all nodes of an AlwaysOn Availability Group with automatic failover orchestration.

.DESCRIPTION
    Orchestrates the complete workflow to enable Service Broker on all nodes of an AlwaysOn AG.
    Supports two modes:

    MODE 1 (AG with database): Automatic failover orchestration
    1. Identifies the current Primary replica
    2. Iterates through each replica:
       - Fails over to that replica (makes it Primary)
       - Executes Enable-sqmServiceBroker on the new Primary
       - Validates Service Broker status
    3. Fails back to the original Primary

    MODE 2 (Database removed from AG / Broker already enabled): Direct endpoint creation
    - Creates SSBEndpoint on all instances independently
    - No failovers required
    - Useful when: database was removed from AG after Enable-Broker

    This ensures:
    - Service Broker is enabled on ALL databases (via SET ENABLE_BROKER on Primary, replicated to Secondaries)
    - SSBEndpoint exists on EVERY physical server (via CREATE ENDPOINT on each node)
    - Minimal downtime (only brief failovers if AG is present, none if Broker already enabled)

.PARAMETER SqlInstances
    Array of SQL Server instances (e.g. @("SQL01","SQL02","SQL03")).
    Must be at least 2 instances. Required.

.PARAMETER AvailabilityGroupName
    Name of the Availability Group. Required.

.PARAMETER DatabaseName
    Name of the database to enable Service Broker on. Required.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER Force
    Skip confirmation prompt and proceed directly.

.PARAMETER OutputPath
    Output directory for log file. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER WaitBetweenFailovers
    Wait time (seconds) after each failover to allow health checks. Default: 15 seconds.

.PARAMETER ContinueOnError
    Continue on error (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.EXAMPLE
    Invoke-sqmServiceBrokerAlwaysOn -SqlInstances @("SQL01","SQL02","SQL03") -AvailabilityGroupName "MyAG" -DatabaseName "OperationsManager"

.EXAMPLE
    Invoke-sqmServiceBrokerAlwaysOn -SqlInstances @("SQL01","SQL02") -AvailabilityGroupName "MyAG" -DatabaseName "MyDB" -Force -WaitBetweenFailovers 20

.NOTES
    Author:       sqmSQLTool
    Prerequisites: dbatools, sysadmin permissions on all nodes
    Warning:      This function may perform multiple failovers (if AG is present and Broker not enabled). Plan for brief availability interruptions.
    Log Output:   C:\System\WinSrvLog\MSSQL (default)
#>
function Invoke-sqmServiceBrokerAlwaysOn
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string[]]$SqlInstances,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[int]$WaitBetweenFailovers = 15,
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
			$errMsg = "dbatools module not found."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		if ($SqlInstances.Count -lt 2)
		{
			$errMsg = "At least 2 SQL instances required."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starting $functionName for AG: $AvailabilityGroupName, DB: $DatabaseName, Instances: $($SqlInstances -join ', ')" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			if (-not (Test-Path $OutputPath))
			{
				$null = New-Item -ItemType Directory -Path $OutputPath -Force
			}

			$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
			$logFile = Join-Path $OutputPath ("ServiceBrokerAlwaysOn_" + $SqlInstances[0] + "_" + $AvailabilityGroupName + "_" + $timestamp + ".txt")
			$logContent = [System.Collections.Generic.List[string]]::new()

			$logContent.Add("Service Broker AlwaysOn Orchestration Log") | Out-Null
			$logContent.Add("=" * 100) | Out-Null
			$logContent.Add("Availability Group: $AvailabilityGroupName") | Out-Null
			$logContent.Add("Database:           $DatabaseName") | Out-Null
			$logContent.Add("Instances:          $($SqlInstances -join ', ')") | Out-Null
			$logContent.Add("Started:            $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
			$logContent.Add("") | Out-Null

			# Step 1: Connect and check Broker status
			$logContent.Add("STEP 1: Check Service Broker Status") | Out-Null
			$logContent.Add("-" * 100) | Out-Null

			$server = Connect-DbaInstance -SqlInstance $SqlInstances[0] -SqlCredential $SqlCredential -ErrorAction Stop
			$brokerQuery = "SELECT is_broker_enabled FROM sys.databases WHERE name = '$DatabaseName'"
			$brokerStatus = $server.Query($brokerQuery)
			$brokerEnabled = $brokerStatus[0].is_broker_enabled -eq 1

			$logContent.Add("  Service Broker Status: $(if ($brokerEnabled) { 'ENABLED' } else { 'DISABLED' })") | Out-Null
			$logContent.Add("") | Out-Null

			# Step 2: Try to find AG (graceful if not found)
			$logContent.Add("STEP 2: Check AlwaysOn Availability Group") | Out-Null
			$logContent.Add("-" * 100) | Out-Null

			$agExists = $false
			$currentPrimary = $null
			$replicaStates = $null

			try
			{
				$agQuery = @"
SELECT
    ar.replica_server_name,
    ars.role_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$AvailabilityGroupName'
ORDER BY ars.role_desc DESC
"@

				$replicaStates = $server.Query($agQuery)
				if ($replicaStates)
				{
					$agExists = $true
					$currentPrimary = ($replicaStates | Where-Object { $_.role_desc -eq 'PRIMARY' }).replica_server_name
					$logContent.Add("  AG found: $AvailabilityGroupName") | Out-Null
					$logContent.Add("  Current Primary: $currentPrimary") | Out-Null
					foreach ($replica in $replicaStates)
					{
						$logContent.Add("    - $($replica.replica_server_name) ($($replica.role_desc))") | Out-Null
					}
				}
			}
			catch
			{
				$logContent.Add("  AG not found (OK if database was removed from AG)") | Out-Null
			}

			$logContent.Add("") | Out-Null

			# Determine operating mode
			$mode = if ($agExists -and -not $brokerEnabled) { "FAILOVER_MODE" } else { "ENDPOINT_ONLY_MODE" }
			$logContent.Add("Operating Mode: $mode") | Out-Null
			$logContent.Add("") | Out-Null

			# Confirmation
			$actionDesc = switch ($mode)
			{
				"FAILOVER_MODE" { "Enable Service Broker with automatic failover orchestration" }
				"ENDPOINT_ONLY_MODE" { "Create Service Broker endpoints on all instances" }
			}

			if (-not ($Force -or $PSCmdlet.ShouldProcess("$DatabaseName on $($SqlInstances -join ', ')", $actionDesc)))
			{
				$logContent.Add("ABORTED: User cancelled operation") | Out-Null
				$logContent -join "`n" | Out-File -FilePath $logFile -Encoding UTF8 -Force
				return $null
			}

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()

			# Mode: Failover orchestration
			if ($mode -eq "FAILOVER_MODE")
			{
				$logContent.Add("STEP 3: Failover and Enable Service Broker on Each Node") | Out-Null
				$logContent.Add("-" * 100) | Out-Null

				foreach ($instance in $SqlInstances)
				{
					$logContent.Add("") | Out-Null
					$logContent.Add("Processing: $instance") | Out-Null
					$logContent.Add("~" * 100) | Out-Null

					try
					{
						$logContent.Add("  3a. Initiating failover to $instance...") | Out-Null
						Invoke-sqmLogging -Message "Initiating failover to $instance..." -FunctionName $functionName -Level "INFO"

						Invoke-DbaAgFailover -SqlInstance $instance -AvailabilityGroup $AvailabilityGroupName -ErrorAction Stop | Out-Null
						$logContent.Add("    Status: Failover initiated") | Out-Null

						Start-Sleep -Seconds $WaitBetweenFailovers

						$server = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential -ErrorAction Stop
						$verifyQuery = "SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE replica_id = (SELECT replica_id FROM sys.availability_replicas WHERE replica_server_name = @@SERVERNAME)"
						$role = $server.Query($verifyQuery)[0].role_desc
						$logContent.Add("    Verified: $instance is now $role") | Out-Null

						if ($role -ne 'PRIMARY')
						{
							throw "Failover verification failed: $instance is $role, not PRIMARY"
						}

						$logContent.Add("  3b. Running Enable-sqmServiceBroker on $instance...") | Out-Null
						Invoke-sqmLogging -Message "Enabling Service Broker on $instance..." -FunctionName $functionName -Level "INFO"

						$sbResult = Enable-sqmServiceBroker -SqlInstance $instance -DatabaseName $DatabaseName -SqlCredential $SqlCredential -Force -OutputPath $OutputPath -ErrorAction Stop

						$logContent.Add("    Status: $($sbResult.Status)") | Out-Null
						$logContent.Add("    Broker Enabled: $($sbResult.BrokerEnabled)") | Out-Null

						$results.Add([PSCustomObject]@{
							Instance       = $instance
							Role           = $role
							BrokerEnabled  = $sbResult.BrokerEnabled
							Status         = 'SUCCESS'
							ErrorMessage   = $null
						}) | Out-Null

						$logContent.Add("  Result: SUCCESS") | Out-Null
					}
					catch
					{
						$errorMsg = $_
						$logContent.Add("  Result: FAILED") | Out-Null
						$logContent.Add("  Error: $errorMsg") | Out-Null
						Invoke-sqmLogging -Message "Error processing $instance : $errorMsg" -FunctionName $functionName -Level "ERROR"

						$results.Add([PSCustomObject]@{
							Instance       = $instance
							Role           = 'UNKNOWN'
							BrokerEnabled  = $false
							Status         = 'FAILED'
							ErrorMessage   = $errorMsg.ToString()
						}) | Out-Null

						if ($EnableException) { throw }
						elseif (-not $ContinueOnError) { throw }
					}
				}

				# Failback
				$logContent.Add("") | Out-Null
				$logContent.Add("STEP 4: Failback to Original Primary") | Out-Null
				$logContent.Add("-" * 100) | Out-Null

				try
				{
					$logContent.Add("  Initiating failover back to $currentPrimary...") | Out-Null
					Invoke-sqmLogging -Message "Failing back to original Primary: $currentPrimary" -FunctionName $functionName -Level "INFO"

					Invoke-DbaAgFailover -SqlInstance $currentPrimary -AvailabilityGroup $AvailabilityGroupName -ErrorAction Stop | Out-Null
					Start-Sleep -Seconds $WaitBetweenFailovers
					$logContent.Add("  Failback completed") | Out-Null
					Invoke-sqmLogging -Message "Failback to $currentPrimary completed" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errorMsg = $_
					$logContent.Add("  Status: FAILED - $errorMsg") | Out-Null
					Invoke-sqmLogging -Message "Failback failed: $errorMsg" -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
					elseif (-not $ContinueOnError) { throw }
				}
			}

			# Mode: Endpoint-only (no failovers)
			else
			{
				$logContent.Add("STEP 3: Create Service Broker Endpoints on All Instances") | Out-Null
				$logContent.Add("-" * 100) | Out-Null

				foreach ($instance in $SqlInstances)
				{
					$logContent.Add("") | Out-Null
					$logContent.Add("Processing: $instance") | Out-Null
					$logContent.Add("~" * 100) | Out-Null

					try
					{
						$epServer = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential -ErrorAction Stop
						$epQuery = "SELECT COUNT(*) as cnt FROM sys.service_broker_endpoints WHERE name = 'SSBEndpoint'"
						$epResult = $epServer.Query($epQuery)

						if ($epResult[0].cnt -gt 0)
						{
							$logContent.Add("  Endpoint already exists") | Out-Null
							$results.Add([PSCustomObject]@{
								Instance       = $instance
								Role           = 'N/A'
								BrokerEnabled  = $brokerEnabled
								Status         = 'SKIPPED'
								ErrorMessage   = $null
							}) | Out-Null
						}
						else
						{
							$logContent.Add("  Creating SSBEndpoint...") | Out-Null

							$createEndpointSql = @"
CREATE ENDPOINT [SSBEndpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 4022, LISTENER_IP = ALL)
    FOR SERVICE_BROKER (AUTHENTICATION = WINDOWS)
GRANT CONNECT ON ENDPOINT::[SSBEndpoint] TO [PUBLIC]
"@

							$epServer.Query($createEndpointSql, "master")
							$logContent.Add("  Status: Endpoint created successfully") | Out-Null
							Invoke-sqmLogging -Message "Endpoint created on $instance" -FunctionName $functionName -Level "INFO"

							$results.Add([PSCustomObject]@{
								Instance       = $instance
								Role           = 'N/A'
								BrokerEnabled  = $brokerEnabled
								Status         = 'SUCCESS'
								ErrorMessage   = $null
							}) | Out-Null
						}
					}
					catch
					{
						$errorMsg = $_
						$logContent.Add("  Result: FAILED") | Out-Null
						$logContent.Add("  Error: $errorMsg") | Out-Null
						Invoke-sqmLogging -Message "Error creating endpoint on $instance : $errorMsg" -FunctionName $functionName -Level "ERROR"

						$results.Add([PSCustomObject]@{
							Instance       = $instance
							Role           = 'N/A'
							BrokerEnabled  = $brokerEnabled
							Status         = 'FAILED'
							ErrorMessage   = $errorMsg.ToString()
						}) | Out-Null

						if ($EnableException) { throw }
						elseif (-not $ContinueOnError) { throw }
					}
				}
			}

			# Final Summary
			$logContent.Add("") | Out-Null
			$logContent.Add("=" * 100) | Out-Null
			$successCount = ($results | Where-Object { $_.Status -in @('SUCCESS', 'SKIPPED') }).Count
			$logContent.Add("Summary: $successCount/$($SqlInstances.Count) instances processed successfully") | Out-Null
			$logContent.Add("Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null

			$logContent -join "`n" | Out-File -FilePath $logFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "Log file created: $logFile" -FunctionName $functionName -Level "INFO"

			$result = [PSCustomObject]@{
				AvailabilityGroup     = $AvailabilityGroupName
				DatabaseName          = $DatabaseName
				OriginalPrimary       = $currentPrimary
				InstanceResults       = $results
				SuccessfulInstances   = $successCount
				TotalInstances        = $SqlInstances.Count
				OperatingMode         = $mode
				LogPath               = $logFile
				Timestamp             = $timestamp
				OverallStatus         = if ($successCount -eq $SqlInstances.Count) { "SUCCESS" } else { "PARTIAL" }
			}

			return $result
		}
		catch
		{
			$errMsg = "Error in $functionName : $_"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException) { throw }
			elseif (-not $ContinueOnError) { throw }
		}
	}
}
