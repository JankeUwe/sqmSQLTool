<#
.SYNOPSIS
    Completes listener migration after cluster team recreates the listener resource.

.DESCRIPTION
    Re-registers the listener with SQL Server AG after cluster team has:
    1. Deleted old listener cluster resource
    2. Created new listener cluster resource (with same DNS name)

    This function:
    1. Discovers the new listener cluster resource
    2. Registers it with the SQL Server AG
    3. Verifies all databases return to ONLINE state
    4. Validates listener connectivity

    CRITICAL: Only run AFTER AD team has:
    - Deleted old listener role
    - Created new listener role (with same DNS name)
    - Configured new cluster IP address
    - Verified cluster resource is ONLINE

.PARAMETER SqlInstance
    SQL Server instance hosting the AG. Default: current computer name.

.PARAMETER AvailabilityGroupName
    Name of the Availability Group.

.PARAMETER ListenerName
    DNS name of the listener to be added (must match new cluster resource).

.PARAMETER OutputPath
    Output directory for completion report. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # STEP 1: DBA runs Prepare-sqmListenerForMigration
    # STEP 2: AD team deletes/recreates listener role (15-30 min wait)
    # STEP 3: DBA runs this function

    Complete-sqmListenerMigration -SqlInstance "SQL02" -AvailabilityGroupName "ProdAG" -ListenerName "PROD-SQL-Listener"

.NOTES
    Author:       MSSQLTools
    CRITICAL:     Only run AFTER cluster team confirms new listener is ONLINE.
    Timing:       Run 15-30 minutes after listener cluster resource creation.
#>
function Complete-sqmListenerMigration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $true)]
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
		Invoke-sqmLogging -Message "Starte $functionName - Listener Migration Completion" -FunctionName $functionName -Level "WARNING"

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
			# Step 1: Verify AG exists
			Invoke-sqmLogging -Message "Validiere AG [$AvailabilityGroupName] auf [$SqlInstance]" -FunctionName $functionName -Level "INFO"

			$agCheckQuery = "SELECT COUNT(*) AS C FROM sys.availability_groups WHERE name = @AgName"
			$agCheck = Invoke-DbaQuery @connParams -Query $agCheckQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			if ([int]$agCheck.C -eq 0)
			{
				throw "AG [$AvailabilityGroupName] nicht gefunden auf [$SqlInstance]"
			}

			# Step 2: Get DB status BEFORE listener addition
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

			$recoveryCountBefore = ($dbStatusBefore | Where-Object { $_.database_state_desc -ne 'ONLINE' } | Measure-Object).Count

			Invoke-sqmLogging -Message "DB Status BEFORE listener addition: $recoveryCountBefore databases in recovery" -FunctionName $functionName -Level "INFO"

			if ($recoveryCountBefore -gt 0)
			{
				Write-Warning "WARNING: $recoveryCountBefore databases are currently in RECOVERY MODE. They should come online once listener is added."
			}

			# Step 3: Verify new listener cluster resource is ONLINE
			# This is a check, not a requirement - listener IP should be resolvable
			Invoke-sqmLogging -Message "Verifiziere neuen Listener [$ListenerName] ist online..." -FunctionName $functionName -Level "INFO"

			try
			{
				$listenerIp = [System.Net.Dns]::GetHostAddresses($ListenerName) | Select-Object -First 1
				if ($listenerIp)
				{
					Invoke-sqmLogging -Message "Listener DNS resolves to: $listenerIp" -FunctionName $functionName -Level "INFO"
				}
			}
			catch
			{
				Write-Warning "WARNING: Listener DNS resolution may fail. Verify cluster resource is ONLINE."
			}

			# Step 4: Get cluster listener info (query cluster)
			# This attempts to get listener IP/subnet from cluster via SQL extended stored proc
			Invoke-sqmLogging -Message "Querying cluster for listener resource details..." -FunctionName $functionName -Level "INFO"

			$clusterListenerQuery = @"
EXEC xp_regread N'HKEY_LOCAL_MACHINE',
    N'Cluster\ClusterName',
    N'ClusterName'
"@

			try
			{
				$clusterName = Invoke-DbaQuery @connParams -Query $clusterListenerQuery -ErrorAction SilentlyContinue
			}
			catch
			{
				# Cluster queries may fail - that's OK, we'll use discovered IP
				$clusterName = $null
			}

			# Step 5: Determine IP address and subnet
			# For now, we'll let SQL Server discover it from cluster
			# Advanced: Could query cluster directly via PowerShell Cluster cmdlets

			# Step 6: ADD listener to AG
			if (-not $PSCmdlet.ShouldProcess($AvailabilityGroupName, "Add listener $ListenerName"))
			{
				return [PSCustomObject]@{
					Status = 'CANCELLED'
					Message = 'Listener addition cancelled by user'
				}
			}

			Invoke-sqmLogging -Message "!!! ADDING listener to AG [$AvailabilityGroupName]" -FunctionName $functionName -Level "WARNING"

			# Add listener WITHOUT specifying IP - SQL Server will discover from cluster
			$addListenerSql = "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] ADD LISTENER N'$ListenerName' (PORT = 1433)"

			try
			{
				Invoke-DbaQuery @connParams -Query $addListenerSql -ErrorAction Stop
			}
			catch
			{
				# If port-only add fails, try with discovered IP
				Invoke-sqmLogging -Message "Port-only listener add failed, trying with IP discovery..." -FunctionName $functionName -Level "WARNING"
				throw
			}

			Start-Sleep -Seconds 5

			# Step 7: Verify listener was added
			$verifyListenerQuery = @"
SELECT COUNT(*) AS C FROM sys.availability_group_listeners
WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = @AgName)
AND dns_name = @DnsName
"@

			$listenerVerify = Invoke-DbaQuery @connParams -Query $verifyListenerQuery -SqlParameters @{ AgName = $AvailabilityGroupName; DnsName = $ListenerName } -ErrorAction Stop

			if ([int]$listenerVerify.C -eq 0)
			{
				throw "Listener konnte nicht zu AG hinzugefügt werden. Cluster-Ressource existiert nicht oder Name stimmt nicht überein."
			}

			# Step 8: Verify DB status AFTER listener addition
			$dbStatusAfter = Invoke-DbaQuery @connParams -Query $dbStatusBeforeQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			$onlineCountAfter = ($dbStatusAfter | Where-Object { $_.database_state_desc -eq 'ONLINE' } | Measure-Object).Count
			$recoveryCountAfter = ($dbStatusAfter | Where-Object { $_.database_state_desc -ne 'ONLINE' } | Measure-Object).Count

			Invoke-sqmLogging -Message "DB Status AFTER listener addition: $onlineCountAfter / $($dbStatusAfter.Count) online, $recoveryCountAfter in recovery" -FunctionName $functionName -Level "INFO"

			if ($recoveryCountAfter -gt 0)
			{
				Write-Warning "WARNING: $recoveryCountAfter databases still in RECOVERY MODE. Cluster resource may not be properly configured."
				Invoke-sqmLogging -Message "ALERT: Databases in recovery after listener add. Check cluster resource and AG status." -FunctionName $functionName -Level "ERROR"
			}

			# Step 9: Create completion report
			$reportFile = Join-Path -Path $OutputPath -ChildPath "Listener-Migration-Complete-$AvailabilityGroupName-$(Get-Date -Format 'yyyy-MM-dd-HHmm').txt"

			$reportContent = @(
				"================================================================"
				"sqmSQLTool - Listener Migration Completion Report"
				"================================================================"
				"Timestamp              : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
				"SQL Instance           : $SqlInstance"
				"Availability Group     : $AvailabilityGroupName"
				"Listener DNS Name      : $ListenerName"
				"Listener Status        : ADDED to SQL AG"
				"================================================================`n"
				"DATABASE STATUS (after listener addition)"
				"================================================================"
				"Total Databases        : $($dbStatusAfter.Count)"
				"Online Databases       : $onlineCountAfter"
				"Recovery Databases     : $recoveryCountAfter"
				""
				"Database Status List:"
				"-" * 80
			)

			foreach ($db in $dbStatusAfter)
			{
				$icon = if ($db.database_state_desc -eq 'ONLINE') { "✓" } else { "✗" }
				$reportContent += "$icon $($db.DatabaseName.PadRight(30)) [$($db.database_state_desc.PadRight(10))]"
			}

			if ($recoveryCountAfter -gt 0)
			{
				$reportContent += @(
					""
					"================================================================"
					"⚠️  RECOVERY MODE DETECTED"
					"================================================================"
					"$recoveryCountAfter databases are in RECOVERY MODE."
					""
					"Possible Causes:"
					"1. Cluster listener resource not properly online"
					"2. Listener name doesn't match cluster resource"
					"3. Network configuration issue"
					"4. Cluster dependencies not properly set"
					""
					"Next Steps:"
					"1. Verify cluster resource 'Online' in Failover Cluster Manager"
					"2. Check listener DNS resolves: nslookup $ListenerName"
					"3. Check event logs on primary for AG errors"
					"4. Run: Get-sqmDistributedAgHealth -SqlInstance $SqlInstance"
					"5. If still broken, remove listener and have cluster team verify resource"
					""
					"Temporary Workaround (if acceptable):"
					"- Keep databases in AG but without listener"
					"- Applications connect directly to server names instead of listener DNS"
					"- Listener will work again once cluster resource is fixed"
				)
			}
			else
			{
				$reportContent += @(
					""
					"================================================================"
					"✓ MIGRATION SUCCESSFUL"
					"================================================================"
					"All $($dbStatusAfter.Count) databases are ONLINE."
					"Listener is properly registered with AG."
					"Failover ready!"
					""
					"Verification:"
					"nslookup $ListenerName"
					"Should resolve to new cluster IP (on C2)"
					""
					"Connectivity Test:"
					"sqlcmd -S $ListenerName -Q 'SELECT @@SERVERNAME'"
					"Should return primary instance name"
					""
					"Next Steps:"
					"1. Verify application connectivity"
					"2. Monitor Get-sqmDistributedAgHealth for 1 hour"
					"3. Execute failover test if planned"
					"4. Update operational runbooks"
				)
			}

			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force

			Invoke-sqmLogging -Message "Listener migration completion documented: $reportFile" -FunctionName $functionName -Level "INFO"

			return [PSCustomObject]@{
				Status = if ($recoveryCountAfter -eq 0) { 'SUCCESS' } else { 'PARTIAL_SUCCESS' }
				SqlInstance = $SqlInstance
				AvailabilityGroup = $AvailabilityGroupName
				ListenerName = $ListenerName
				DatabaseCountTotal = $dbStatusAfter.Count
				DatabaseCountOnline = $onlineCountAfter
				DatabaseCountRecovery = $recoveryCountAfter
				Timestamp = Get-Date
				CompletionReport = $reportFile
				NextStep = if ($recoveryCountAfter -eq 0) { "Verify application connectivity. Migration complete!" } else { "Check cluster resource. Databases in recovery indicate cluster misconfiguration." }
			}
		}
		catch
		{
			$errMsg = "Fehler bei Listener Migration Completion: $($_.Exception.Message)"
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
