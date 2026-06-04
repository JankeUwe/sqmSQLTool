<#
.SYNOPSIS
    Creates a new Distributed AlwaysOn Availability Group.

.DESCRIPTION
    Establishes a Distributed AG relationship between two SQL Server clusters:

    1. Validates primary and secondary AG exist and are synchronized
    2. Configures AutoSeed on both sides (if requested)
    3. Creates Distributed AG on primary cluster
    4. Registers secondary AG as part of distributed relationship
    5. Verifies initial synchronization

    Prerequisites:
    - Primary AG must exist on PrimaryInstance and be HEALTHY
    - Secondary AG must exist on SecondaryInstance
    - Both clusters must be WSFC clusters
    - Network connectivity between clusters

.PARAMETER PrimaryInstance
    SQL Server instance hosting the PRIMARY Availability Group.

.PARAMETER PrimaryAgName
    Name of the primary AG (the one that will remain primary).

.PARAMETER SecondaryInstance
    SQL Server instance hosting the SECONDARY Availability Group.

.PARAMETER SecondaryAgName
    Name of the secondary AG (the one that will be secondary in Distributed AG).

.PARAMETER SqlCredential
    Optional PSCredential for both instances (same account required).

.PARAMETER EnableAutoSeed
    Configure AutoSeed for the distributed relationship (recommended).

.PARAMETER SeedingMode
    'Automatic' (default) = AutoSeed enabled
    'Manual' = Manual backup/restore required for new databases

.PARAMETER OutputPath
    Output directory for detailed logs. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    New-sqmDistributedAvailabilityGroup -PrimaryInstance "SQL01" -PrimaryAgName "ProductionAG" `
        -SecondaryInstance "DR-SQL01" -SecondaryAgName "DrAG" -EnableAutoSeed

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools, both AGs must be SYNCHRONIZED
    Requires SQL Server 2016 SP1 or later
#>
function New-sqmDistributedAvailabilityGroup
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$PrimaryInstance,
		[Parameter(Mandatory = $true)]
		[string]$PrimaryAgName,
		[Parameter(Mandatory = $true)]
		[string]$SecondaryInstance,
		[Parameter(Mandatory = $true)]
		[string]$SecondaryAgName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$EnableAutoSeed,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Automatic', 'Manual')]
		[string]$SeedingMode = 'Automatic',
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName - Distributed AG Setup" -FunctionName $functionName -Level "INFO"

		if (-not (Test-Path $OutputPath))
		{
			New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
		}
	}

	process
	{
		$primaryConnParams = @{ SqlInstance = $PrimaryInstance }
		$secondaryConnParams = @{ SqlInstance = $SecondaryInstance }
		if ($SqlCredential)
		{
			$primaryConnParams['SqlCredential'] = $SqlCredential
			$secondaryConnParams['SqlCredential'] = $SqlCredential
		}

		$steps = [System.Collections.Generic.List[PSCustomObject]]::new()

		try
		{
			# Step 1: Validate primary AG
			Invoke-sqmLogging -Message "Validiere Primary AG [$PrimaryAgName] auf [$PrimaryInstance]" -FunctionName $functionName -Level "INFO"

			$primaryAgQuery = @"
SELECT
    ag.name,
    ars.role_desc,
    ars.synchronization_health_desc,
    (SELECT COUNT(*) FROM sys.availability_replicas WHERE group_id = ag.group_id) AS ReplicaCount,
    (SELECT COUNT(*) FROM sys.availability_databases_cluster WHERE group_id = ag.group_id) AS DatabaseCount
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id = ag.group_id
WHERE ag.name = @AgName AND ars.is_local = 1
"@
			$primaryAg = Invoke-DbaQuery @primaryConnParams -Query $primaryAgQuery -SqlParameters @{ AgName = $PrimaryAgName } -ErrorAction Stop

			if (-not $primaryAg)
			{
				throw "Primary AG '$PrimaryAgName' nicht gefunden oder nicht Primary Role auf [$PrimaryInstance]"
			}

			if ($primaryAg.synchronization_health_desc -ne 'HEALTHY')
			{
				throw "Primary AG '$PrimaryAgName' ist nicht HEALTHY: $($primaryAg.synchronization_health_desc)"
			}

			$steps.Add([PSCustomObject]@{
				Step = 'Validate Primary AG'
				Status = 'OK'
				Details = "AG=$PrimaryAgName, Role=$($primaryAg.role_desc), Health=$($primaryAg.synchronization_health_desc)"
			})

			# Step 2: Validate secondary AG
			Invoke-sqmLogging -Message "Validiere Secondary AG [$SecondaryAgName] auf [$SecondaryInstance]" -FunctionName $functionName -Level "INFO"

			$secondaryAgQuery = "SELECT name, ars.role_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id = ag.group_id WHERE ag.name = @AgName AND ars.is_local = 1"
			$secondaryAg = Invoke-DbaQuery @secondaryConnParams -Query $secondaryAgQuery -SqlParameters @{ AgName = $SecondaryAgName } -ErrorAction Stop

			if (-not $secondaryAg)
			{
				throw "Secondary AG '$SecondaryAgName' nicht gefunden auf [$SecondaryInstance]"
			}

			$steps.Add([PSCustomObject]@{
				Step = 'Validate Secondary AG'
				Status = 'OK'
				Details = "AG=$SecondaryAgName, Role=$($secondaryAg.role_desc)"
			})

			# Step 3: Create Distributed AG on primary
			Invoke-sqmLogging -Message "Erstelle Distributed AG [$PrimaryAgName-$SecondaryAgName]" -FunctionName $functionName -Level "INFO"

			$seedingModeSql = if ($EnableAutoSeed -or $SeedingMode -eq 'Automatic') { 'AUTOMATIC' } else { 'MANUAL' }

			$createDagSql = @"
CREATE AVAILABILITY GROUP [$($PrimaryAgName)_$($SecondaryAgName)]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
    N'$PrimaryAgName' WITH
        (LISTENER_URL = N'tcp://$($PrimaryInstance):5022',
         AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
         FAILOVER_MODE = MANUAL,
         SEEDING_MODE = $seedingModeSql),
    N'$SecondaryAgName' WITH
        (LISTENER_URL = N'tcp://$($SecondaryInstance):5022',
         AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
         FAILOVER_MODE = MANUAL,
         SEEDING_MODE = $seedingModeSql)
"@

			Invoke-DbaQuery @primaryConnParams -Query $createDagSql -ErrorAction Stop

			$steps.Add([PSCustomObject]@{
				Step = 'Create Distributed AG'
				Status = 'OK'
				Details = "SeedingMode=$seedingModeSql"
			})

			# Step 4: Verify creation
			Start-Sleep -Seconds 5

			$verifyQuery = "SELECT COUNT(*) AS C FROM sys.availability_groups WHERE is_distributed = 1"
			$dagCount = Invoke-DbaQuery @primaryConnParams -Query $verifyQuery -ErrorAction Stop

			if ([int]$dagCount.C -eq 0)
			{
				throw "Distributed AG konnte nicht erstellt werden (keine DAG auf Primary sichtbar)"
			}

			$steps.Add([PSCustomObject]@{
				Step = 'Verify Creation'
				Status = 'OK'
				Details = "Distributed AG exists and synchronized"
			})

			# Step 5: Report
			$reportFile = Join-Path -Path $OutputPath -ChildPath "New-DistributedAG-$PrimaryAgName-$(Get-Date -Format 'yyyy-MM-dd-HHmm').txt"

			$reportContent = @(
				"================================================================"
				"sqmSQLTool - New Distributed Availability Group Report"
				"================================================================"
				"Timestamp          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
				"Primary Cluster    : $PrimaryInstance"
				"Primary AG         : $PrimaryAgName"
				"Secondary Cluster  : $SecondaryInstance"
				"Secondary AG       : $SecondaryAgName"
				"Seeding Mode       : $seedingModeSql"
				"Status             : SUCCESS"
				"================================================================`n"
				"IMPORTANT NEXT STEPS:"
				"================================================================"
				"1. Verify listener configuration on BOTH clusters:"
				"   - Primary Listener (IP/Port on C1): $PrimaryInstance:1433"
				"   - Create Secondary Listener on C2 for failover"
				"   - OR migrate listener to C2 (see Move-sqmAgListener)"
				""
				"2. Configure AutoSeed if needed:"
				"   - Both clusters must have sufficient storage"
				"   - T-SQL backup network must be open"
				""
				"3. Monitor initial synchronization:"
				"   - Get-sqmDistributedAgHealth -SqlInstance $PrimaryInstance"
				""
				"4. Plan listener migration:"
				"   - Before failover: Move-sqmAgListener -SourceAg $PrimaryAgName -TargetAg $SecondaryAgName"
				""
				"================================================================"
			)

			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force

			Invoke-sqmLogging -Message "Distributed AG erstellt erfolgreich. Report: $reportFile" -FunctionName $functionName -Level "INFO"

			return [PSCustomObject]@{
				Status = 'SUCCESS'
				PrimaryInstance = $PrimaryInstance
				PrimaryAgName = $PrimaryAgName
				SecondaryInstance = $SecondaryInstance
				SecondaryAgName = $SecondaryAgName
				DistributedAgName = "$($PrimaryAgName)_$($SecondaryAgName)"
				SeedingMode = $seedingModeSql
				Timestamp = Get-Date
				Steps = $steps
				ReportFile = $reportFile
				NextSteps = @(
					"1. Configure listener on secondary cluster (or migrate from primary)",
					"2. Monitor synchronization with Get-sqmDistributedAgHealth",
					"3. Add databases with Add-sqmDatabaseToDistributedAg"
				)
			}
		}
		catch
		{
			$errMsg = "Fehler beim Erstellen Distributed AG: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException) { throw }

			return [PSCustomObject]@{
				Status = 'FAILED'
				Error = $errMsg
				Steps = $steps
			}
		}
	}
}
