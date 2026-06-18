<#
.SYNOPSIS
    Enables Service Broker on all nodes of an AlwaysOn Availability Group with automatic failover orchestration.

.DESCRIPTION
    Orchestrates the complete workflow to enable Service Broker on all nodes of an AlwaysOn AG:
    1. Identifies the current Primary replica
    2. Iterates through each replica:
       - Fails over to that replica (makes it Primary)
       - Waits for failover completion and health confirmation
       - Executes Enable-sqmServiceBroker on the new Primary
       - Validates Service Broker status
    3. Fails back to the original Primary
    4. Generates a comprehensive log report

    This ensures:
    - Service Broker is enabled on ALL databases (via SET ENABLE_BROKER on Primary, replicated to Secondaries)
    - SSBEndpoint exists on EVERY physical server (via CREATE ENDPOINT on each node as Primary)
    - Minimal downtime (only brief failovers, not extended outages)

.PARAMETER SqlInstances
    Array of SQL Server instances in the AlwaysOn AG (e.g. @("SQL01","SQL02","SQL03")).
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
    Warning:      This function performs multiple failovers. Plan for brief availability interruptions.
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

		# Validate prerequisites
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools module not found."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		if ($SqlInstances.Count -lt 2)
		{
			$errMsg = "At least 2 SQL instances required for AlwaysOn."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starting $functionName for AG: $AvailabilityGroupName, DB: $DatabaseName, Instances: $($SqlInstances -join ', ')" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# Create output directory
			if (-not (Test-Path $OutputPath))
			{
				$null = New-Item -ItemType Directory -Path $OutputPath -Force
			}

			# Initialize log
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

			# Step 1: Connect to first instance and identify current Primary
			$logContent.Add("STEP 1: Identify Current Primary") | Out-Null
			$logContent.Add("-" * 100) | Out-Null
			Invoke-sqmLogging -Message "Connecting to $($SqlInstances[0]) to identify current Primary..." -FunctionName $functionName -Level "INFO"

			$server = Connect-DbaInstance -SqlInstance $SqlInstances[0] -SqlCredential $SqlCredential -ErrorAction Stop
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
			if (-not $replicaStates)
			{
				throw "Could not find AG '$AvailabilityGroupName' on $($SqlInstances[0])"
			}

			$currentPrimary = ($replicaStates | Where-Object { $_.role_desc -eq 'PRIMARY' }).replica_server_name
			$logContent.Add("  Current Primary: $currentPrimary") | Out-Null
			$logContent.Add("  Replicas:") | Out-Null
			foreach ($replica in $replicaStates)
			{
				$logContent.Add("    - $($replica.replica_server_name) ($($replica.role_desc))") | Out-Null
			}
			$logContent.Add("") | Out-Null

			Invoke-sqmLogging -Message "Current Primary: $currentPrimary" -FunctionName $functionName -Level "INFO"

			# Confirmation
			if (-not ($Force -or $PSCmdlet.ShouldProcess("AG $AvailabilityGroupName", "Enable Service Broker on all nodes with failover orchestration")))
			{
				$logContent.Add("ABORTED: User cancelled operation") | Out-Null
				Invoke-sqmLogging -Message "Operation cancelled by user" -FunctionName $functionName -Level "WARN"
				$logContent -join "`n" | Out-File -FilePath $logFile -Encoding UTF8 -Force
				return $null
			}

			# Step 2: Process each instance
			$logContent.Add("STEP 2: Failover and Enable Service Broker on Each Node") | Out-Null
			$logContent.Add("-" * 100) | Out-Null

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()

			foreach ($instance in $SqlInstances)
			{
				$logContent.Add("") | Out-Null
				$logContent.Add("Processing: $instance") | Out-Null
				$logContent.Add("~" * 100) | Out-Null

				try
				{
					# Step 2a: Failover to this instance
					$logContent.Add("  2a. Initiating failover to $instance...") | Out-Null
					Invoke-sqmLogging -Message "Initiating failover to $instance..." -FunctionName $functionName -Level "INFO"

					Invoke-DbaAgFailover -SqlInstance $instance -AvailabilityGroup $AvailabilityGroupName -ErrorAction Stop | Out-Null
					$logContent.Add("    Status: Failover initiated") | Out-Null

					# Wait for failover to complete
					$logContent.Add("  Waiting $WaitBetweenFailovers seconds for failover completion and health checks...") | Out-Null
					Start-Sleep -Seconds $WaitBetweenFailovers

					# Verify new Primary
					$server = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential -ErrorAction Stop
					$verifyQuery = @"
SELECT role_desc FROM sys.dm_hadr_availability_replica_states
WHERE replica_id = (SELECT replica_id FROM sys.availability_replicas WHERE replica_server_name = @@SERVERNAME)
"@
					$role = $server.Query($verifyQuery)[0].role_desc
					$logContent.Add("    Verified: $instance is now $role") | Out-Null

					if ($role -ne 'PRIMARY')
					{
						throw "Failover verification failed: $instance is $role, not PRIMARY"
					}

					Invoke-sqmLogging -Message "Failover to $instance completed successfully" -FunctionName $functionName -Level "INFO"

					# Step 2b: Enable Service Broker
					$logContent.Add("  2b. Running Enable-sqmServiceBroker on $instance...") | Out-Null
					Invoke-sqmLogging -Message "Enabling Service Broker on $instance..." -FunctionName $functionName -Level "INFO"

					$sbResult = Enable-sqmServiceBroker -SqlInstance $instance -DatabaseName $DatabaseName -SqlCredential $SqlCredential -Force -OutputPath $OutputPath -ErrorAction Stop

					$logContent.Add("    Status: $($sbResult.Status)") | Out-Null
					$logContent.Add("    Broker Enabled: $($sbResult.BrokerEnabled)") | Out-Null
					$logContent.Add("    Log: $($sbResult.LogPath)") | Out-Null

					if ($sbResult.Status -eq 'SUCCESS')
					{
						Invoke-sqmLogging -Message "Service Broker successfully enabled on $instance" -FunctionName $functionName -Level "INFO"
					}
					else
					{
						throw "Service Broker enable returned status: $($sbResult.Status)"
					}

					# Track result
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

			# Step 3: Failover back to original Primary
			$logContent.Add("") | Out-Null
			$logContent.Add("STEP 3: Failback to Original Primary") | Out-Null
			$logContent.Add("-" * 100) | Out-Null

			try
			{
				$logContent.Add("  Initiating failover back to $currentPrimary...") | Out-Null
				Invoke-sqmLogging -Message "Failing back to original Primary: $currentPrimary" -FunctionName $functionName -Level "INFO"

				Invoke-DbaAgFailover -SqlInstance $currentPrimary -AvailabilityGroup $AvailabilityGroupName -ErrorAction Stop | Out-Null
				$logContent.Add("  Failover initiated") | Out-Null

				Start-Sleep -Seconds $WaitBetweenFailovers
				$logContent.Add("  Failback completed") | Out-Null
				Invoke-sqmLogging -Message "Failback to $currentPrimary completed" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errorMsg = $_
				$logContent.Add("  Status: FAILED - $errorMsg") | Out-Null
				Invoke-sqmLogging -Message "Failback failed: $errorMsg" -FunctionName $functionName -Level "ERROR"

				if ($EnableException)
				{
					throw
				}
				elseif (-not $ContinueOnError)
				{
					throw
				}
			}

			# Step 4: Final Verification
			$logContent.Add("") | Out-Null
			$logContent.Add("STEP 4: Final Verification") | Out-Null
			$logContent.Add("-" * 100) | Out-Null

			try
			{
				$server = Connect-DbaInstance -SqlInstance $SqlInstances[0] -SqlCredential $SqlCredential -ErrorAction Stop
				$finalQuery = @"
SELECT
    ar.replica_server_name,
    ars.role_desc,
    d.is_broker_enabled
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
JOIN sys.databases d ON d.name = '$DatabaseName'
WHERE ag.name = '$AvailabilityGroupName'
ORDER BY ars.role_desc DESC, ar.replica_server_name
"@

				$finalState = $server.Query($finalQuery)
				$brokerEnabledCount = ($finalState | Where-Object { $_.is_broker_enabled -eq 1 }).Count

				$logContent.Add("  Final Broker Status (Database Level):") | Out-Null
				$logContent.Add("    Enabled on $brokerEnabledCount/$($SqlInstances.Count) replicas (should be 1 - on Primary only)") | Out-Null
				$logContent.Add("  Replica States:") | Out-Null
				foreach ($replica in $finalState)
				{
					$brokerStatus = if ($replica.is_broker_enabled) { "ENABLED" } else { "DISABLED" }
					$logContent.Add("    - $($replica.replica_server_name) ($($replica.role_desc)): Broker $brokerStatus") | Out-Null
				}

				# Verify endpoints on all instances
				$logContent.Add("") | Out-Null
				$logContent.Add("  Endpoint Status (Server Level):") | Out-Null

				foreach ($instance in $SqlInstances)
				{
					try
					{
						$epServer = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential -ErrorAction Stop
						$epQuery = "SELECT COUNT(*) as cnt FROM sys.service_broker_endpoints WHERE name = 'SSBEndpoint'"
						$epResult = $epServer.Query($epQuery)
						$epExists = $epResult.cnt -gt 0
						$epStatus = if ($epExists) { "EXISTS" } else { "MISSING" }
						$logContent.Add("    - $instance : Endpoint $epStatus") | Out-Null
					}
					catch
					{
						$logContent.Add("    - $instance : ERROR - Could not verify endpoint") | Out-Null
					}
				}
			}
			catch
			{
				$logContent.Add("  Verification failed: $_") | Out-Null
			}

			# Footer
			$logContent.Add("") | Out-Null
			$logContent.Add("=" * 100) | Out-Null
			$successCount = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
			$logContent.Add("Summary: $successCount/$($SqlInstances.Count) nodes processed successfully") | Out-Null
			$logContent.Add("Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null

			# Write log
			$logContent -join "`n" | Out-File -FilePath $logFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "Log file created: $logFile" -FunctionName $functionName -Level "INFO"

			# Return result object
			$result = [PSCustomObject]@{
				AvailabilityGroup     = $AvailabilityGroupName
				DatabaseName          = $DatabaseName
				OriginalPrimary       = $currentPrimary
				InstanceResults       = $results
				SuccessfulInstances   = $successCount
				TotalInstances        = $SqlInstances.Count
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
