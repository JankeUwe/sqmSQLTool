function Get-SqlVersionWithoutError {
	param([string]$ConnectionString)
	try {
		$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
		$conn.Open()
		$cmd = $conn.CreateCommand()
		$cmd.CommandText = "SELECT SERVERPROPERTY('ProductVersion')"
		$version = $cmd.ExecuteScalar()
		$conn.Close()
		return $version
	}
	catch { return $null }
}

function Sync-sqmLoginsToAlwaysOn
{
	param (
		[string]$SqlInstance = $env:COMPUTERNAME,
		[string]$AvailabilityGroupName,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[switch]$Force = $true,
		[switch]$BackupLogins = $true,
		[int]$BackupRetentionDays = 0
	)

	# Load module
	if (-not (Get-Module -ListAvailable -Name dbatools)) {
		throw "dbatools-Modul nicht gefunden."
	}
	Import-Module dbatools -Force -ErrorAction Stop

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()

	# Connect with TrustServerCertificate (handles both SQL 2019 and 2022+)
	$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -TrustServerCertificate -ErrorAction Stop

	try
	{
		# Resolve AG
		$allAgs = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
			-Query "SELECT name FROM sys.availability_groups ORDER BY name ASC" -ErrorAction Stop

		if (-not $allAgs)
		{
			throw "Keine Availability Groups auf $SqlInstance gefunden."
		}

		if ([string]::IsNullOrWhiteSpace($AvailabilityGroupName))
		{
			$AvailabilityGroupName = if ($allAgs -is [System.Collections.Generic.List[PSCustomObject]]) { $allAgs[0].name } else { $allAgs.name }
		}
		else
		{
			if (-not ($allAgs | Where-Object { $_.name -eq $AvailabilityGroupName }))
			{
				throw "AG '$AvailabilityGroupName' nicht gefunden."
			}
		}

		# Get replicas
		$query = @"
SELECT
    ar.replica_server_name,
    drs.role_desc
FROM sys.availability_replicas ar
INNER JOIN sys.dm_hadr_availability_replica_states drs
    ON ar.replica_id = drs.replica_id
WHERE ar.group_id IN (
    SELECT group_id FROM sys.availability_groups
    WHERE name = N'$AvailabilityGroupName'
)
ORDER BY drs.role ASC
"@

		$replicas = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $query -ErrorAction Stop

		$primaryReplica = $replicas | Where-Object { $_.role_desc -eq 'PRIMARY' }
		$secondaryReplicas = $replicas | Where-Object { $_.role_desc -eq 'SECONDARY' }

		if (-not $primaryReplica)
		{
			throw "Keine Primary Replica gefunden."
		}

		Write-Output "Primary: $($primaryReplica.replica_server_name) | Secondaries: $($secondaryReplicas.Count)"

		# Process each secondary
		foreach ($secondary in $secondaryReplicas)
		{
			$secondaryName = $secondary.replica_server_name

			try
			{
				Write-Output "[$secondaryName] Beginne Sync..."

				# SafeForceMode: Get sysadmin logins
				$sysAdminLogins = @()
				try
				{
					$query = "SELECT name FROM sys.server_principals WHERE (is_srvrolemember('sysadmin', name) = 1 OR sid = 0x01) AND name NOT LIKE '##%'"
					$sysAdminLogins = @((Invoke-DbaQuery -SqlInstance $secondaryName -SqlCredential $SqlCredential -Query $query).name)
				}
				catch
				{
					$sysAdminLogins = @('sa')
				}

				# Get Agent account
				$agentAccount = $null
				try
				{
					$agentAccount = (Get-DbaAgentServiceAccount -SqlInstance $secondaryName -SqlCredential $SqlCredential).ServiceAccount
				}
				catch { }

				# Build safe exclusion list
				$safeExclude = @('dbo') + $sysAdminLogins
				if ($agentAccount) { $safeExclude += $agentAccount }
				$safeExclude += @('NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*', '##MS_*')

				# Copy logins
				$copyParams = @{
					Source                  = $primaryReplica.replica_server_name
					Destination             = $secondaryName
					SourceCredential        = $SqlCredential
					DestinationCredential   = $SqlCredential
					ErrorAction             = 'Stop'
				}

				if ($Force)
				{
					$copyParams.Force = $true
					$copyParams.ExcludeLogin = $safeExclude
				}

				Write-Output "[$secondaryName] Copy-sqmLogins..."
				$copyResult = Copy-sqmLogins @copyParams

				$loginsCount = if ($copyResult.Logins) { @($copyResult.Logins).Count } else { 0 }
				$orphansRepaired = if ($copyResult.OrphansRepaired) { @($copyResult.OrphansRepaired).Count } else { 0 }

				Write-Output "[$secondaryName] OK: $loginsCount Logins, $orphansRepaired Orphans"

				$results.Add([PSCustomObject]@{
					AvailabilityGroup = $AvailabilityGroupName
					SecondaryReplica  = $secondaryName
					Status            = 'Success'
					LoginsCount       = $loginsCount
					OrphansRepaired   = $orphansRepaired
					Timestamp         = Get-Date
				})
			}
			catch
			{
				$errMsg = $_.Exception.Message
				Write-Output "[$secondaryName] FEHLER: $errMsg"

				$results.Add([PSCustomObject]@{
					AvailabilityGroup = $AvailabilityGroupName
					SecondaryReplica  = $secondaryName
					Status            = 'Failed'
					LoginsCount       = 0
					OrphansRepaired   = 0
					Error             = $errMsg
					Timestamp         = Get-Date
				})
			}
		}
	}
	catch
	{
		$errMsg = $_.Exception.Message
		Write-Output "FEHLER: $errMsg"
		throw
	}

	return $results
}

Sync-sqmLoginsToAlwaysOn -Confirm:$false -ErrorAction Stop

exit $LASTEXITCODE
