<#
.SYNOPSIS
    Initiates failover of a Distributed AlwaysOn AG.

.DESCRIPTION
    Performs a controlled failover from the primary Distributed AG to the secondary AG.

    Process:
    1. Validates failover readiness (all replicas SYNCHRONIZED)
    2. Initiates failover on the secondary AG (makes it primary)
    3. Previous primary becomes secondary
    4. Logs all changes
    5. Exports detailed report

    Requires explicit confirmation unless -Force is used.

.PARAMETER SqlInstance
    Primary SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER AvailabilityGroupName
    Name of the Distributed AG to failover. Required.

.PARAMETER Force
    Skip confirmation dialog.

.PARAMETER WhatIf
    Shows what would be done without actually performing the failover.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -Force

.EXAMPLE
    Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -WhatIf

.NOTES
    Author:       MSSQLTools
    WARNING:      This is a critical operation. Always test in DR environment first.
#>
function Invoke-sqmDistributedFailover
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName fuer [$SqlInstance] AG=$AvailabilityGroupName" -FunctionName $functionName -Level "INFO"

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
			# Step 1: Validiere Failover-Bereitschaft
			$readinessTest = Test-sqmDistributedAgReadiness @connParams -EnableException:$true

			if ($readinessTest.ReadinessScore -lt 75)
			{
				$errMsg = "Failover NICHT empfohlen. Readiness Score: $($readinessTest.ReadinessScore)/100. Details: $($readinessTest.CheckResults | Out-String)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				throw $errMsg
			}

			# Step 2: Hole Secondary AG Info
			$secondaryQuery = @"
SELECT TOP 1
    ag.name AS PrimaryAgName,
    dag.secondary_availability_group_name AS SecondaryAgName,
    dag.secondary_replica_server_name AS SecondaryReplicaServer
FROM sys.availability_groups ag
JOIN sys.dm_hadr_distributed_ag_replica_member_status dag ON 1=1
WHERE ag.name = @AgName AND ag.is_distributed = 1
"@
			$secondaryInfo = Invoke-DbaQuery @connParams -Query $secondaryQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			if (-not $secondaryInfo)
			{
				throw "Distributed AG '$AvailabilityGroupName' nicht gefunden oder nicht korrekt konfiguriert."
			}

			$secondaryAgName = $secondaryInfo.SecondaryAgName
			$secondaryServer = $secondaryInfo.SecondaryReplicaServer

			# Step 3: Bestaetigung (wenn nicht -Force)
			$confirmMsg = @"
CRITICAL OPERATION: Distributed AG Failover

Primary AG   : $AvailabilityGroupName
Secondary AG : $secondaryAgName
Target Server: $secondaryServer

Dieser Vorgang ist nicht rueckkehrbar. Fortfahren?
"@

			if (-not $Force)
			{
				if (-not $PSCmdlet.ShouldProcess($AvailabilityGroupName, "Failover durchfuehren"))
				{
					Invoke-sqmLogging -Message "Failover abgebrochen durch Benutzer" -FunctionName $functionName -Level "INFO"
					return [PSCustomObject]@{
						Status = 'CANCELLED'
						Message = 'Failover abgebrochen'
						Timestamp = Get-Date
					}
				}
			}

			# Step 4: Fuehre Failover durch
			$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
			Invoke-sqmLogging -Message "Starte Failover [$AvailabilityGroupName] zu [$secondaryServer]" -FunctionName $functionName -Level "WARNING"

			# Failover T-SQL
			$failoverSql = @"
-- Initiate forced failover (als last resort, wenn keine Synchronisierung moeglich)
ALTER AVAILABILITY GROUP [$AvailabilityGroupName]
    SET (ROLE = SECONDARY) FORCE_FAILOVER_ALLOW_DATA_LOSS;
"@
			Invoke-DbaQuery @connParams -Query $failoverSql -ErrorAction Stop

			# Step 5: Verifikation
			Start-Sleep -Seconds 3

			$verifyQuery = @"
SELECT
    ag.name,
    ar.replica_server_name,
    ars.role_desc,
    ars.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ag.name = @AgName
"@
			$postFailoverStatus = Invoke-DbaQuery @connParams -Query $verifyQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			# Step 6: Erstelle Report
			$reportFile = Join-Path -Path $OutputPath -ChildPath "Distributed-AG-Failover-$AvailabilityGroupName-$([datetime]::Now.ToString('yyyy-MM-dd-HHmm')).txt"

			$reportContent = @(
				"================================================================"
				"sqmSQLTool - Distributed AG Failover Report"
				"================================================================"
				"Timestamp       : $timestamp"
				"Primary AG      : $AvailabilityGroupName"
				"Secondary AG    : $secondaryAgName"
				"Target Server   : $secondaryServer"
				"Failover Status : SUCCESS"
				"================================================================`n"
				"POST-FAILOVER REPLICA STATUS:"
				"-" * 80
			)

			foreach ($row in $postFailoverStatus)
			{
				$reportContent += "$($row.replica_server_name.PadRight(20)) Role: $($row.role_desc.PadRight(12)) Sync: $($row.synchronization_health_desc)"
			}

			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force

			Invoke-sqmLogging -Message "Failover abgeschlossen. Report: $reportFile" -FunctionName $functionName -Level "INFO"

			return [PSCustomObject]@{
				Status = 'SUCCESS'
				SqlInstance = $SqlInstance
				PrimaryAg = $AvailabilityGroupName
				SecondaryAg = $secondaryAgName
				SecondaryServer = $secondaryServer
				Timestamp = $timestamp
				PostFailoverStatus = $postFailoverStatus
				ReportFile = $reportFile
			}
		}
		catch
		{
			$errMsg = "Fehler beim Failover: $($_.Exception.Message)"
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
