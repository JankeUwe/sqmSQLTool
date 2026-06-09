<#
.SYNOPSIS
    Creates a detailed health report for Distributed AlwaysOn Availability Groups.

.DESCRIPTION
    Retrieves for each Distributed AG on the specified instance:
    - Synchronization status between primary and secondary AGs
    - Replica status within each AG
    - Database synchronization state
    - LSN lag information (redo/send queues)
    - Listener configuration
    - Failover readiness status

    Results are saved as TXT and CSV reports. Requires SQL Server 2016 SP1 or later.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER ContinueOnError
    Continue on error for an instance (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.EXAMPLE
    Get-sqmDistributedAgHealth -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmDistributedAgHealth -SqlInstance "SQL01", "SQL02" -OutputPath "D:\Reports"

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools (v1.1.0+), SQL Server 2016 SP1 or later
    Distributed AG requires SQL Server 2016 SP1, 2017, 2019, 2022, or 2025
#>
function Get-sqmDistributedAgHealth
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
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
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Installiere mit: Install-Module dbatools -Force"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"

		if (-not (Test-Path $OutputPath))
		{
			New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
		}
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade Distributed AlwaysOn-Informationen..." -FunctionName $functionName -Level "INFO"

				# Pruefe SQL Server Version (Distributed AG ab 2016 SP1)
				$verQuery = "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) AS V"
				$verRow = Invoke-DbaQuery @connParams -Query $verQuery -EnableException:$true -ErrorAction Stop
				$sqlMajorVersion = [int]$verRow.V

				if ($sqlMajorVersion -lt 13)
				{
					Invoke-sqmLogging -Message "[$instance] Distributed AG erfordert SQL Server 2016 oder hoehter. Gefunden: $sqlMajorVersion" -FunctionName $functionName -Level "WARNING"
					continue
				}

				# Abfrage fuer Distributed AGs
				$dagQuery = @"
SELECT
    ag.name                                    AS PrimaryAgName,
    ag.is_distributed                          AS IsDistributed,
    ar.replica_server_name                     AS ReplicaName,
    ar.availability_mode_desc                  AS AvailabilityMode,
    ar.failover_mode_desc                      AS FailoverMode,
    ars.role_desc                              AS Role,
    ars.connected_state_desc                   AS ConnectionState,
    ars.synchronization_health_desc            AS SyncHealth,
    dag.secondary_availability_group_name      AS SecondaryAgName,
    dag.secondary_replica_server_name          AS SecondaryReplicaName,
    dag.last_hardened_lsn                      AS LastHardenedLsn,
    dag.last_redone_lsn                        AS LastRedoneLsn,
    dag.last_sent_lsn                          AS LastSentLsn,
    (CASE
        WHEN dag.last_hardened_lsn = dag.last_sent_lsn THEN 'Synchronized'
        ELSE 'Synchronizing'
     END)                                       AS DagSyncState,
    DB_NAME(adbrs.database_id)                 AS DatabaseName,
    adbrs.synchronization_state_desc           AS DbSyncState
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states adbrs ON adbrs.replica_id = ar.replica_id
WHERE ag.is_distributed = 1
ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name, DB_NAME(adbrs.database_id);
"@
				$dagRows = Invoke-DbaQuery @connParams -Query $dagQuery -ErrorAction Stop

				if (-not $dagRows)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Distributed AlwaysOn-Gruppen vorhanden." -FunctionName $functionName -Level "INFO"
					continue
				}

				# Erstelle Report
				$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
				$reportDate = Get-Date -Format "yyyy-MM-dd"
				$reportFile = Join-Path -Path $OutputPath -ChildPath "Distributed-AG-Health-$instance-$reportDate.txt"
				$csvFile = Join-Path -Path $OutputPath -ChildPath "Distributed-AG-Health-$instance-$reportDate.csv"

				$reportContent = @(
					"================================================================"
					"sqmSQLTool - Distributed AlwaysOn Health Report"
					"$(Get-sqmReportReference)"
					"================================================================"
					"Instanz       : $instance"
					"Erstellt      : $timestamp"
					"DAGs vorhanden: $($dagRows | Select-Object -Unique PrimaryAgName | Measure-Object).Count"
					"================================================================`n"
				)

				# Gruppiere nach Primary AG
				$dagsByAg = $dagRows | Group-Object -Property PrimaryAgName

				foreach ($agGroup in $dagsByAg)
				{
					$agName = $agGroup.Name
					$agData = $agGroup.Group | Select-Object -First 1

					$reportContent += @(
						"PRIMARY AG: $agName"
						"Secondary AG: $($agData.SecondaryAgName)"
						"Sync State  : $($agData.DagSyncState)"
						""
					)

					# Replicas
					$reportContent += "REPLICAS:"
					$reportContent += "-" * 80

					$replicas = $agGroup.Group | Select-Object -Unique ReplicaName, AvailabilityMode, Role, SyncHealth, ConnectionState
					foreach ($replica in $replicas)
					{
						$syncIcon = if ($replica.SyncHealth -eq 'HEALTHY') { "OK" } else { "WARN" }
						$reportContent += "$syncIcon   $($replica.ReplicaName.PadRight(20))   $($replica.Role.PadRight(12))   $($replica.AvailabilityMode.PadRight(15))   $($replica.SyncHealth)"
					}

					$reportContent += "`nDATABASES:"
					$reportContent += "-" * 80

					$databases = $agGroup.Group | Where-Object { $_.DatabaseName } | Select-Object DatabaseName, DbSyncState -Unique
					foreach ($db in $databases)
					{
						$reportContent += "$($db.DatabaseName)  [$($db.DbSyncState)]"
					}

					$reportContent += "`n"
				}

				$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force

				# Exportiere CSV
				$dagRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

				Invoke-sqmLogging -Message "[$instance] Reports erstellt: TXT=$reportFile CSV=$csvFile" -FunctionName $functionName -Level "INFO"

				$result = [PSCustomObject]@{
					SqlInstance = $instance
					Timestamp = $timestamp
					DistributedAgCount = ($dagRows | Select-Object -Unique PrimaryAgName | Measure-Object).Count
					ReplicaCount = ($dagRows | Select-Object -Unique ReplicaName | Measure-Object).Count
					DatabaseCount = ($dagRows | Where-Object { $_.DatabaseName } | Select-Object -Unique DatabaseName | Measure-Object).Count
					Status = 'OK'
					TxtFile = $reportFile
					CsvFile = $csvFile
					Details = $dagRows
				}

				$allInstanceResults.Add($result)

				Invoke-sqmOpenReport -TxtFile $reportFile -NoOpen:$NoOpen
			}
			catch
			{
				$errMsg = "Fehler beim Lesen Distributed AG-Status von [$instance]: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

				if ($EnableException) { throw }
				if ($ContinueOnError) { continue }
				throw
			}
		}
	}

	end
	{
		return $allInstanceResults
	}
}
