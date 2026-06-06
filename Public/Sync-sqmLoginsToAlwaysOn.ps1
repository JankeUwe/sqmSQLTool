<#
.SYNOPSIS
    Synchronizes logins from the primary replica to all secondary replicas in an AlwaysOn Availability Group.

.DESCRIPTION
    Automatically detects the primary and all secondary replicas in an AlwaysOn Availability Group,
    then copies logins from the primary to each secondary.

    Process:
    1. Detect primary replica in the AG (is_primary_replica = 1)
    2. Enumerate all secondary replicas
    3. For each secondary:
       - Connect and validate
       - Copy logins from primary via Copy-sqmLogins
       - Repair orphaned users (automatic)
       - Log result (Success/Failed/Skipped)
    4. Return summary with per-replica status

    Authentication:
    - All replicas use the same credentials (SqlCredential or SourceCredential/DestinationCredential)
    - If replicas are on different domains: use -SqlCredential with cross-domain account

    Error handling:
    - Replica connection failure: Logged as 'Failed', process continues to next replica
    - Login copy failure: Logged with error details, does not block other replicas
    - Orphan repair failure: Logged, does not block result return

    Logins excluded by default:
    - System logins (sa, ##MS_*, NT SERVICE\*, BUILTIN\*) - use -IncludeSystemLogins to include

.PARAMETER SqlInstance
    The SQL Server instance hosting the primary replica. Default: $env:COMPUTERNAME

.PARAMETER AvailabilityGroupName
    Name of the Availability Group. If not specified, the first AG found on the instance is used.

.PARAMETER SqlCredential
    PSCredential for all replicas (source and destination).

.PARAMETER SourceCredential
    PSCredential specifically for the primary replica (overrides -SqlCredential for source).

.PARAMETER DestinationCredential
    PSCredential for the secondary replicas (overrides -SqlCredential for destinations).

.PARAMETER Login
    Filters the copy operation to these login names (wildcards allowed).
    Without specification, all logins (after ExcludeLogin filter) are copied.

.PARAMETER ExcludeLogin
    Logins that should not be copied (wildcards allowed).
    Example: 'AppLogin_*', 'OldUser'.

.PARAMETER IncludeSystemLogins
    When set, system logins are also copied. Default: $false.

.PARAMETER AdjustAuthMode
    When set, automatically adjust target replica authentication mode to match primary if needed.

.PARAMETER RestartServiceIfRequired
    When set, restart the SQL Server service on secondary replicas if auth mode was changed.

.PARAMETER DisablePolicy
    Disable SQL Server policies on secondaries during the copy (default: $true).

.PARAMETER SkipSecondaryServers
    Comma-separated list of secondary instance names to skip (for maintenance).
    Example: 'SQL02', 'SQL03'

.PARAMETER EnableException
    Throw exceptions immediately instead of returning error status.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"
    Syncs all logins from primary to all secondaries in ProdAG.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -IncludeSystemLogins
    Includes system logins in the sync.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -ExcludeLogin "TempUser_*"
    Skips logins matching the pattern.

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Copy-sqmLogins, Get-sqmConfig
    Needs: sysadmin on all replicas
    Orphaned users are automatically repaired on all databases on each secondary.
#>
function Sync-sqmLoginsToAlwaysOn
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$Login,

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[switch]$AdjustAuthMode,

		[Parameter(Mandatory = $false)]
		[switch]$RestartServiceIfRequired,

		[Parameter(Mandatory = $false)]
		[switch]$DisablePolicy = $true,

		[Parameter(Mandatory = $false)]
		[string[]]$SkipSecondaryServers,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		# Resolve credentials
		$srcCred = if ($SourceCredential) { $SourceCredential } else { $SqlCredential }
		$dstCred = if ($DestinationCredential) { $DestinationCredential } else { $SqlCredential }

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		try
		{
			# -------------------------------------------------------------------
			# 1. Get primary replica and list of secondaries
			# -------------------------------------------------------------------
			$query = @"
SELECT
    ar.replica_server_name,
    ar.availability_mode_desc,
    drs.is_primary_replica,
    drs.role_desc
FROM sys.availability_replicas ar
INNER JOIN sys.dm_hadr_availability_replica_states drs
    ON ar.replica_id = drs.replica_id
WHERE ar.group_id IN (
    SELECT group_id FROM sys.availability_groups
    WHERE name = ISNULL(N'$AvailabilityGroupName', (SELECT TOP 1 name FROM sys.availability_groups))
)
ORDER BY drs.is_primary_replica DESC
"@

			$replicas = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $srcCred -Query $query -ErrorAction Stop

			if (-not $replicas)
			{
				throw "Keine Availability Group oder Replicas gefunden auf $SqlInstance"
			}

			$primaryReplica = $replicas | Where-Object { $_.is_primary_replica -eq 1 }
			$secondaryReplicas = $replicas | Where-Object { $_.is_primary_replica -eq 0 }

			if (-not $primaryReplica)
			{
				throw "Keine Primary Replica gefunden. Instanz ist nicht Primary in dieser AG."
			}

			$agName = if ($AvailabilityGroupName) { $AvailabilityGroupName } else { $replicas[0].name }

			Invoke-sqmLogging -Message "Primary Replica: $($primaryReplica.replica_server_name) | Secondary Replicas: $($secondaryReplicas.Count)" `
							  -FunctionName $functionName -Level 'INFO'

			if (-not $secondaryReplicas)
			{
				Invoke-sqmLogging -Message "Keine Secondary Replicas gefunden. AG hat nur 1 Replica." -FunctionName $functionName -Level 'WARNING'
			}

			# -------------------------------------------------------------------
			# 2. Copy logins to each secondary
			# -------------------------------------------------------------------
			foreach ($secondary in $secondaryReplicas)
			{
				$secondaryName = $secondary.replica_server_name
				$secondaryRole  = $secondary.role_desc

				# Skip if in skip list
				if ($SkipSecondaryServers -contains $secondaryName)
				{
					Invoke-sqmLogging -Message "[$secondaryName] Übersprungen (in SkipSecondaryServers)" -FunctionName $functionName -Level 'VERBOSE'
					$results.Add([PSCustomObject]@{
						AvailabilityGroup = $agName
						PrimaryReplica    = $primaryReplica.replica_server_name
						SecondaryReplica  = $secondaryName
						SecondaryRole     = $secondaryRole
						Status            = 'Skipped'
						LoginsCount       = 0
						OrphansRepaired   = 0
						Error             = 'In SkipSecondaryServers list'
						Timestamp         = Get-Date
					})
					continue
				}

				if (-not $PSCmdlet.ShouldProcess($secondaryName, "Kopiere Logins von Primary"))
				{
					Invoke-sqmLogging -Message "[$secondaryName] Übersprungen (WhatIf)" -FunctionName $functionName -Level 'VERBOSE'
					continue
				}

				try
				{
					Invoke-sqmLogging -Message "[$secondaryName] Beginne Login-Synchronisierung..." -FunctionName $functionName -Level 'INFO'

					# Copy logins using Copy-sqmLogins
					$copyParams = @{
						Source                  = $primaryReplica.replica_server_name
						Destination             = $secondaryName
						SourceCredential        = $srcCred
						DestinationCredential   = $dstCred
						Login                   = $Login
						ExcludeLogin            = $ExcludeLogin
						IncludeSystemLogins     = $IncludeSystemLogins
						AdjustAuthMode          = $AdjustAuthMode
						RestartServiceIfRequired = $RestartServiceIfRequired
						DisablePolicy           = $DisablePolicy
						ErrorAction             = 'Stop'
					}

					$copyResult = Copy-sqmLogins @copyParams

					# Count logins
					$loginsCount = if ($copyResult.Logins) { @($copyResult.Logins).Count } else { 0 }
					$orphansRepaired = if ($copyResult.OrphansRepaired) { @($copyResult.OrphansRepaired).Count } else { 0 }

					Invoke-sqmLogging -Message "[$secondaryName] Erfolgreich: $loginsCount Logins kopiert, $orphansRepaired Orphans repariert" `
									  -FunctionName $functionName -Level 'INFO'

					$results.Add([PSCustomObject]@{
						AvailabilityGroup = $agName
						PrimaryReplica    = $primaryReplica.replica_server_name
						SecondaryReplica  = $secondaryName
						SecondaryRole     = $secondaryRole
						Status            = 'Success'
						LoginsCount       = $loginsCount
						OrphansRepaired   = $orphansRepaired
						Error             = $null
						Timestamp         = Get-Date
					})
				}
				catch
				{
					$errMsg = $_.Exception.Message
					Invoke-sqmLogging -Message "[$secondaryName] Fehler: $errMsg" -FunctionName $functionName -Level 'ERROR'

					$results.Add([PSCustomObject]@{
						AvailabilityGroup = $agName
						PrimaryReplica    = $primaryReplica.replica_server_name
						SecondaryReplica  = $secondaryName
						SecondaryRole     = $secondaryRole
						Status            = 'Failed'
						LoginsCount       = 0
						OrphansRepaired   = 0
						Error             = $errMsg
						Timestamp         = Get-Date
					})

					if ($EnableException) { throw }
				}
			}
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler in $functionName: $errMsg" -FunctionName $functionName -Level 'ERROR'

			if ($EnableException) { throw }

			$results.Add([PSCustomObject]@{
				AvailabilityGroup = $AvailabilityGroupName
				PrimaryReplica    = $SqlInstance
				SecondaryReplica  = '(all)'
				SecondaryRole     = 'Unknown'
				Status            = 'Failed'
				LoginsCount       = 0
				OrphansRepaired   = 0
				Error             = $errMsg
				Timestamp         = Get-Date
			})
		}
	}

	end
	{
		$successCount = @($results | Where-Object Status -eq 'Success').Count
		$failedCount  = @($results | Where-Object Status -eq 'Failed').Count
		$skippedCount = @($results | Where-Object Status -eq 'Skipped').Count
		$totalLogins  = ($results | Measure-Object -Property LoginsCount -Sum).Sum
		$totalOrphans = ($results | Measure-Object -Property OrphansRepaired -Sum).Sum

		Invoke-sqmLogging -Message "$functionName abgeschlossen. Success: $successCount | Failed: $failedCount | Skipped: $skippedCount | Logins: $totalLogins | Orphans: $totalOrphans" `
						  -FunctionName $functionName -Level 'INFO'

		return $results
	}
}
