<#
.SYNOPSIS
    Prepares an AG listener for cluster-level migration without downtime.

.DESCRIPTION
    Removes the listener from the SQL Server AG while keeping databases ONLINE.

    This is CRITICAL preparation before AD/Cluster team deletes/recreates the
    listener cluster resource. Skipping this step causes all databases to enter
    RECOVERY MODE when the cluster resource is deleted.

    Process:
    1. Validates listener exists and is configured correctly
    2. Removes listener from AG (via ALTER AVAILABILITY GROUP ... REMOVE LISTENER)
    3. Verifies all databases remain ONLINE (still in AG, just no listener)
    4. Documents listener configuration for re-creation
    5. Waits for DNS/application timeout
    6. Gives AD team "safe to delete" confirmation

    CRITICAL: Run this BEFORE AD team deletes the listener cluster resource!

.PARAMETER SqlInstance
    SQL Server instance hosting the AG. Default: current computer name.

.PARAMETER AvailabilityGroupName
    Name of the Availability Group.

.PARAMETER ListenerName
    DNS name of the listener to be removed (must exist). Optional if only one listener.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER OutputPath
    Output directory for listener documentation. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # STEP 1: Prepare listener before AD team deletes it
    Prepare-sqmListenerForMigration -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"

    # STEP 2: Wait 15 minutes for DNS/application timeout

    # STEP 3: AD team deletes old listener role and creates new one

    # STEP 4: You run Complete-sqmListenerMigration

.NOTES
    Author:       MSSQLTools
    CRITICAL:     Do NOT skip this step. Run BEFORE cluster team deletes listener.
    Timing:       Requires 15-30 min wait for DNS TTL and app connection timeout.
#>
function Prepare-sqmListenerForMigration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $false)]
		[string]$ListenerName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName - Listener Migration Preparation" -FunctionName $functionName -Level "WARNING"

		if (-not (Test-Path $OutputPath))
		{
			New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
		}
	}

	process
	{
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		try
		{
			# Step 1: Get listener details
			Invoke-sqmLogging -Message "Lade Listener-Informationen von AG [$AvailabilityGroupName]" -FunctionName $functionName -Level "INFO"

			$getListenerQuery = @"
SELECT
    agl.listener_id,
    agl.dns_name,
    agl.ip_configuration_string_from_cluster,
    agliip.ip_address,
    agliip.ip_subnet_mask,
    aglil.port
FROM sys.availability_group_listeners agl
JOIN sys.availability_group_listener_ip_addresses agliip ON agliip.listener_id = agl.listener_id
LEFT JOIN sys.availability_group_listener_ip_port aglil ON aglil.listener_id = agl.listener_id
WHERE agl.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = @AgName)
"@

			$listeners = Invoke-DbaQuery @connParams -Query $getListenerQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			if (-not $listeners)
			{
				throw "Kein Listener auf AG [$AvailabilityGroupName] gefunden. Migration nicht nötig?"
			}

			# Filter by ListenerName if specified
			if ($ListenerName)
			{
				$listener = $listeners | Where-Object { $_.dns_name -eq $ListenerName }
				if (-not $listener)
				{
					throw "Listener '$ListenerName' nicht gefunden auf AG [$AvailabilityGroupName]"
				}
			}
			else
			{
				$listener = $listeners[0]
			}

			$listenerDns = $listener.dns_name
			$listenerIp = $listener.ip_address
			$listenerPort = if ($listener.port) { [int]$listener.port } else { 1433 }

			Invoke-sqmLogging -Message "Found listener: DNS=$listenerDns IP=$listenerIp Port=$listenerPort" -FunctionName $functionName -Level "INFO"

			# Step 2: Get DB status BEFORE removal
			$dbStatusBeforeQuery = @"
SELECT
    DB_NAME(adc.database_id) AS DatabaseName,
    adc.database_state_desc,
    ar.replica_server_name,
    ars.role_desc
FROM sys.availability_databases_cluster adc
JOIN sys.availability_replicas ar ON ar.group_id = adc.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE adc.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = @AgName)
ORDER BY DB_NAME(adc.database_id)
"@

			$dbStatusBefore = Invoke-DbaQuery @connParams -Query $dbStatusBeforeQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			$onlineCount = ($dbStatusBefore | Where-Object { $_.database_state_desc -eq 'ONLINE' } | Measure-Object).Count
			Invoke-sqmLogging -Message "DB Status BEFORE removal: $onlineCount / $($dbStatusBefore.Count) online" -FunctionName $functionName -Level "INFO"

			# Step 3: REMOVE listener from AG
			if (-not $PSCmdlet.ShouldProcess($AvailabilityGroupName, "Remove listener $listenerDns"))
			{
				return [PSCustomObject]@{
					Status = 'CANCELLED'
					Message = 'Listener removal cancelled by user'
				}
			}

			Invoke-sqmLogging -Message "!!! REMOVING listener from AG [$AvailabilityGroupName]" -FunctionName $functionName -Level "WARNING"

			$removeListenerSql = "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] REMOVE LISTENER N'$listenerDns'"
			Invoke-DbaQuery @connParams -Query $removeListenerSql -ErrorAction Stop

			Start-Sleep -Seconds 3

			# Step 4: Verify DB status AFTER removal
			$dbStatusAfter = Invoke-DbaQuery @connParams -Query $dbStatusBeforeQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			$onlineCountAfter = ($dbStatusAfter | Where-Object { $_.database_state_desc -eq 'ONLINE' } | Measure-Object).Count
			$recoveryCount = ($dbStatusAfter | Where-Object { $_.database_state_desc -ne 'ONLINE' } | Measure-Object).Count

			Invoke-sqmLogging -Message "DB Status AFTER removal: $onlineCountAfter / $($dbStatusAfter.Count) online, $recoveryCount in recovery" -FunctionName $functionName -Level "INFO"

			if ($recoveryCount -gt 0)
			{
				throw "CRITICAL: $recoveryCount DBs went into RECOVERY MODE after listener removal! This should not happen. Check cluster state."
			}

			# Step 5: Create documentation for AD team
			$reportFile = Join-Path -Path $OutputPath -ChildPath "Listener-Migration-Prep-$AvailabilityGroupName-$(Get-Date -Format 'yyyy-MM-dd-HHmm').txt"

			$reportContent = @(
				"================================================================"
				"sqmSQLTool - Listener Migration Preparation Report"
				"================================================================"
				"Timestamp              : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
				"SQL Instance           : $SqlInstance"
				"Availability Group     : $AvailabilityGroupName"
				"Listener DNS Name      : $listenerDns"
				"Listener IP (current)  : $listenerIp"
				"Listener Port          : $listenerPort"
				"Listener Status        : REMOVED from SQL AG"
				"================================================================`n"
				"DATABASE STATUS (after listener removal)"
				"================================================================"
				"Total Databases        : $($dbStatusAfter.Count)"
				"Online Databases       : $onlineCountAfter"
				"Recovery Databases     : $recoveryCount"
				""
				"Database List:"
				"-" * 80
			)

			foreach ($db in $dbStatusAfter)
			{
				$reportContent += "$($db.DatabaseName.PadRight(30)) [$($db.database_state_desc.PadRight(10))]"
			}

			$reportContent += @(
				""
				"================================================================"
				"SAFE FOR AD TEAM TO PROCEED"
				"================================================================"
				"✓ Listener removed from SQL AG"
				"✓ All databases remain ONLINE (no listener dependency)"
				"✓ Cluster resource can now be safely deleted/recreated"
				""
				"AD TEAM TASKS (next 15-30 minutes):"
				"1. Delete old listener cluster resource (Failover Cluster Manager)"
				"   - Name: $listenerDns"
				"   - Cluster: C1 (old cluster)"
				""
				"2. Create new listener cluster resource (on new cluster C2)"
				"   - Same DNS name: $listenerDns"
				"   - New IP: [TO BE DETERMINED]"
				"   - Port: $listenerPort"
				""
				"3. Configure IP address in cluster:"
				"   - Subnet mask: $($listener.ip_subnet_mask)"
				"   - Network: [determine correct network for C2]"
				""
				"4. Bring listener online in cluster"
				"   - Resource should be in 'Online' state"
				"   - Verify DNS resolves to new IP"
				""
				"5. NOTIFY DBA WHEN COMPLETE"
				"   - DBA will run: Complete-sqmListenerMigration"
				""
				"================================================================"
				"TIMING: Wait 15-30 minutes for:"
				"================================================================"
				"1. DNS TTL to expire (applications timeout old IP)"
				"2. Application connection pools to refresh"
				"3. New listener cluster resource to stabilize"
				""
				"DO NOT RUSH. Let systems settle for at least 15 minutes."
				"================================================================"
			)

			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force

			Invoke-sqmLogging -Message "Listener preparation complete. AD Team instructions saved to: $reportFile" -FunctionName $functionName -Level "INFO"

			return [PSCustomObject]@{
				Status = 'READY_FOR_AD_TEAM'
				SqlInstance = $SqlInstance
				AvailabilityGroup = $AvailabilityGroupName
				ListenerName = $listenerDns
				ListenerIpOld = $listenerIp
				ListenerPort = $listenerPort
				ListenerSubnet = $listener.ip_subnet_mask
				DatabaseCountTotal = $dbStatusAfter.Count
				DatabaseCountOnline = $onlineCountAfter
				DatabaseCountRecovery = $recoveryCount
				Timestamp = Get-Date
				DocumentationFile = $reportFile
				NextStep = "AD team: Delete old listener role, create new listener role with same name. Then run Complete-sqmListenerMigration"
				WaitTimeMinutes = 15
			}
		}
		catch
		{
			$errMsg = "Fehler bei Listener Migration Preparation: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException) { throw }

			return [PSCustomObject]@{
				Status = 'FAILED'
				Error = $errMsg
				Timestamp = Get-Date
			}
		}
	}
}
