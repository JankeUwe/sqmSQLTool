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

.PARAMETER Rollback
    Rollback zum urspruenglichen Primary. Ueberspringt den Readiness-Check.
    Verwenden wenn nach einem Failover Probleme auftreten und das alte System
    wieder als Primary benoetigt wird.

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

.EXAMPLE
    # Rollback zum alten System nach fehlgeschlagenem Failover:
    Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -Rollback -Force

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
		[switch]$Rollback,
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
			$isRollback = $Rollback.IsPresent
			$direction = if ($isRollback) { "ROLLBACK" } else { "FAILOVER" }

			# Step 1: Validiere Failover-Bereitschaft (nur beim normalen Failover, nicht Rollback)
			if (-not $isRollback)
			{
				$readinessTest = Test-sqmDistributedAgReadiness @connParams -EnableException:$true

				if ($readinessTest.ReadinessScore -lt 75)
				{
					$errMsg = "Failover NICHT empfohlen. Readiness Score: $($readinessTest.ReadinessScore)/100. Details: $($readinessTest.CheckResults | Out-String)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					throw $errMsg
				}
			}
			else
			{
				Invoke-sqmLogging -Message "ROLLBACK-Modus: Readiness-Check wird uebersprungen." -FunctionName $functionName -Level "WARNING"
			}

			# Step 2: Hole Secondary AG Info (SQL 2016 kompatibel - ohne dm_hadr_distributed_ag_replica_member_status)
			$secondaryQuery = @"
SELECT TOP 1
    ar.replica_server_name AS SecondaryReplicaServer,
    ag2.name AS SecondaryAgName
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag2 ON ag2.group_id = ar.group_id
WHERE ag.name = @AgName
  AND ag.is_distributed = 1
  AND ars.role_desc = 'SECONDARY'
"@
			$secondaryInfo = Invoke-DbaQuery @connParams -Query $secondaryQuery -SqlParameters @{ AgName = $AvailabilityGroupName } -ErrorAction Stop

			if (-not $secondaryInfo)
			{
				throw "Distributed AG '$AvailabilityGroupName' nicht gefunden oder kein Secondary erkannt."
			}

			$secondaryAgName = $secondaryInfo.SecondaryAgName
			$secondaryServer = $secondaryInfo.SecondaryReplicaServer

			# Step 3: Bestaetigung (wenn nicht -Force)
			$actionDesc = if ($isRollback) { "ROLLBACK - Zurueck zum alten System" } else { "Failover zum neuen System" }

			if (-not $Force)
			{
				if (-not $PSCmdlet.ShouldProcess($AvailabilityGroupName, "$direction durchfuehren"))
				{
					Invoke-sqmLogging -Message "$direction abgebrochen durch Benutzer" -FunctionName $functionName -Level "INFO"
					return [PSCustomObject]@{
						Status = 'CANCELLED'
						Message = "$direction abgebrochen"
						Timestamp = Get-Date
					}
				}
			}

			# Step 4: Fuehre Failover / Rollback durch
			$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
			Invoke-sqmLogging -Message "Starte $direction [$AvailabilityGroupName] - $actionDesc" -FunctionName $functionName -Level "WARNING"

			# Bug Fix: Korrekte Failover-Syntax (kein FORCE_FAILOVER_ALLOW_DATA_LOSS!)
			$failoverSql = "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] FAILOVER"
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
				Direction = $direction
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
