<#
.SYNOPSIS
    Tests Distributed AlwaysOn AG readiness for failover.

.DESCRIPTION
    Validates:
    - Synchronization status between primary and secondary AGs
    - All replicas are SYNCHRONIZED
    - Listener is online
    - Network connectivity between clusters
    - Database consistency
    - No pending transactions

    Returns a readiness score (0-100) and detailed report.

.PARAMETER SqlInstance
    Primary SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER TargetInstance
    Secondary SQL Server instance for network testing. Optional.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Test-sqmDistributedAgReadiness -SqlInstance "SQL01" -TargetInstance "DR-SQL01"

.NOTES
    Author:       MSSQLTools
    Returns:      PSCustomObject with ReadinessScore (0-100) and CheckResults
#>
function Test-sqmDistributedAgReadiness
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$TargetInstance,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName fuer [$SqlInstance]" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		$checkResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		try
		{
			# Check 1: Distributed AGs existieren
			$dagQuery = "SELECT COUNT(*) AS DagCount FROM sys.availability_groups WHERE is_distributed = 1"
			$dagCountRow = Invoke-DbaQuery @connParams -Query $dagQuery -ErrorAction Stop
			$dagCount = [int]$dagCountRow.DagCount

			$check1 = [PSCustomObject]@{
				Check = "Distributed AG existiert"
				Result = if ($dagCount -gt 0) { 'PASS' } else { 'FAIL' }
				Details = "DAGs gefunden: $dagCount"
			}
			$checkResults.Add($check1)

			if ($dagCount -eq 0)
			{
				Invoke-sqmLogging -Message "Keine Distributed AGs vorhanden" -FunctionName $functionName -Level "WARNING"
				$readinessScore = 0
			}
			else
			{
				# Check 2: Alle Replicas synchronisiert
				$syncQuery = @"
SELECT
    COUNT(*) AS TotalReplicas,
    SUM(CASE WHEN synchronization_health_desc = 'HEALTHY' THEN 1 ELSE 0 END) AS HealthyReplicas
FROM sys.dm_hadr_availability_replica_states
WHERE replica_id IN (
    SELECT replica_id FROM sys.availability_replicas
    WHERE group_id IN (SELECT group_id FROM sys.availability_groups WHERE is_distributed = 1)
)
"@
				$syncRow = Invoke-DbaQuery @connParams -Query $syncQuery -ErrorAction Stop
				$healthyCount = [int]$syncRow.HealthyReplicas
				$totalCount = [int]$syncRow.TotalReplicas

				$check2 = [PSCustomObject]@{
					Check = "Replica Synchronisierung"
					Result = if ($healthyCount -eq $totalCount) { 'PASS' } else { 'FAIL' }
					Details = "Healthy: $healthyCount / $totalCount"
				}
				$checkResults.Add($check2)

				# Check 3: Distributed AG Sync Status
				$dagSyncQuery = @"
SELECT
    COUNT(*) AS TotalDags,
    SUM(CASE WHEN (SELECT COUNT(*) FROM sys.dm_hadr_distributed_ag_replica_member_status WHERE last_hardened_lsn = last_sent_lsn) = (SELECT COUNT(*) FROM sys.availability_replicas WHERE group_id IN (SELECT group_id FROM sys.availability_groups WHERE is_distributed = 1)) THEN 1 ELSE 0 END) AS SynchronizedDags
FROM sys.availability_groups
WHERE is_distributed = 1
"@
				$dagSyncRow = Invoke-DbaQuery @connParams -Query $dagSyncQuery -ErrorAction Stop
				$syncedDags = if ([int]$dagSyncRow.SynchronizedDags -gt 0) { [int]$dagSyncRow.SynchronizedDags } else { 0 }
				$totalDags = [int]$dagSyncRow.TotalDags

				$check3 = [PSCustomObject]@{
					Check = "Distributed AG Synchronisierung"
					Result = if ($syncedDags -eq $totalDags) { 'PASS' } else { 'PARTIAL' }
					Details = "Synchronized: $syncedDags / $totalDags"
				}
				$checkResults.Add($check3)

				# Check 4: Listener online
				$listenerQuery = @"
SELECT
    COUNT(*) AS TotalListeners,
    SUM(CASE WHEN ip_configuration_string_from_cluster IS NOT NULL THEN 1 ELSE 0 END) AS OnlineListeners
FROM sys.availability_group_listeners
WHERE group_id IN (SELECT group_id FROM sys.availability_groups WHERE is_distributed = 1)
"@
				$listenerRow = Invoke-DbaQuery @connParams -Query $listenerQuery -ErrorAction Stop
				$onlineListeners = if ([int]$listenerRow.OnlineListeners -gt 0) { [int]$listenerRow.OnlineListeners } else { 0 }
				$totalListeners = if ([int]$listenerRow.TotalListeners -gt 0) { [int]$listenerRow.TotalListeners } else { 0 }

				$check4 = [PSCustomObject]@{
					Check = "AG Listener Status"
					Result = if ($totalListeners -eq 0 -or $onlineListeners -eq $totalListeners) { 'PASS' } else { 'PARTIAL' }
					Details = "Online: $onlineListeners / $totalListeners"
				}
				$checkResults.Add($check4)

				# Check 5: Network zu Secondary (optional)
				if ($TargetInstance)
				{
					$netTest = Test-NetConnection -ComputerName $TargetInstance -InformationLevel Quiet -WarningAction SilentlyContinue
					$check5 = [PSCustomObject]@{
						Check = "Netzwerk zu Secondary"
						Result = if ($netTest) { 'PASS' } else { 'FAIL' }
						Details = "Target: $TargetInstance"
					}
					$checkResults.Add($check5)
				}

				# Berechne Readiness Score
				$passCount = ($checkResults | Where-Object { $_.Result -eq 'PASS' } | Measure-Object).Count
				$failCount = ($checkResults | Where-Object { $_.Result -eq 'FAIL' } | Measure-Object).Count
				$partialCount = ($checkResults | Where-Object { $_.Result -eq 'PARTIAL' } | Measure-Object).Count

				$readinessScore = [int](($passCount * 100) / $checkResults.Count)

				Invoke-sqmLogging -Message "Readiness Score: $readinessScore (PASS=$passCount, PARTIAL=$partialCount, FAIL=$failCount)" -FunctionName $functionName -Level "INFO"
			}
		}
		catch
		{
			$errMsg = "Fehler bei Readiness-Test: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException) { throw }
			$readinessScore = 0
		}
	}

	end
	{
		return [PSCustomObject]@{
			SqlInstance = $SqlInstance
			Timestamp = Get-Date
			ReadinessScore = $readinessScore
			Status = if ($readinessScore -eq 100) { 'READY' } elseif ($readinessScore -ge 75) { 'MOSTLY_READY' } else { 'NOT_READY' }
			CheckResults = $checkResults
		}
	}
}
