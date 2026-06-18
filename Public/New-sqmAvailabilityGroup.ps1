<#
.SYNOPSIS
    Creates an AlwaysOn Availability Group on an existing Windows Server Failover Cluster (WSFC).

.DESCRIPTION
    Headless port of the AlwaysOnSetup.ps1 automation (no GUI). Drives the complete AG creation
    purely from parameters using dbatools (Invoke-DbaQuery / Connect-DbaInstance) and raw T-SQL.

    Process (each step is idempotent and skips work that is already in place):
      1. Enable HADR on every replica (sp_configure 'hadr enabled', 1) and restart the SQL service
         where HADR was not yet active (HADR requires a service restart to take effect).
      2. Create the database-mirroring endpoint (default 'HADR_Endpoint') on every replica.
      3. (Optional) Create the service-account login and GRANT CONNECT ON ENDPOINT so the replicas
         can authenticate to each other (Windows auth / Kerberos). Falls back to the UPN form for
         cross-domain accounts; on failure it logs that certificate auth must be configured manually.
      4. (Optional) Create the seed database(s) on the primary, set RECOVERY FULL.
      5. (Optional) Clean up an orphaned WSFC group left over from a failed previous attempt.
      6. CREATE AVAILABILITY GROUP on the primary (CLUSTER_TYPE = WSFC, SEEDING_MODE = AUTOMATIC),
         then JOIN + GRANT CREATE ANY DATABASE on each secondary, and MODIFY REPLICA to pin the
         configured failover/availability mode.
      7. (Optional) Add the listener (ADD LISTENER ... WITH IP ((ip, mask)), PORT = ...).

    Authentication strategy: pass -SqlCredential for SQL authentication (e.g. when Kerberos SPNs are
    missing), otherwise the current Windows identity is used on all replicas. This function does NOT
    create temporary logins or request SPNs - that orchestration lives in Invoke-sqmAlwaysOnSetup.

.PARAMETER SqlInstance
    The primary replica instance (e.g. "SQL01" or "SQL01\INST"). Default: $env:COMPUTERNAME.

.PARAMETER SecondaryReplica
    One or more secondary replica instance names. Together with -SqlInstance these form the AG
    (max. 3 replicas total, matching the tested topology).

.PARAMETER AvailabilityGroupName
    Name of the Availability Group to create (mandatory).

.PARAMETER Database
    One or more databases to seed into the AG. Created on the primary if missing and set to
    RECOVERY FULL. If omitted, the AG is created empty (databases can be added later with
    Add-sqmDatabaseToAG).

.PARAMETER ReplicaHostMap
    Optional hashtable mapping replica instance name -> host FQDN used in the endpoint URL
    (TCP://<host>:<port>). When a replica is not present in the map the host part of the instance
    name (before the backslash) is used.

.PARAMETER EndpointName
    Name of the database-mirroring endpoint. Default: 'HADR_Endpoint'.

.PARAMETER EndpointPort
    TCP port of the database-mirroring endpoint. Default: 5022.

.PARAMETER FailoverMode
    'Automatic' (synchronous-commit + automatic failover) or 'Manual' (asynchronous-commit +
    manual failover). Default: 'Automatic'. Drives AVAILABILITY_MODE unless -AvailabilityMode is set.

.PARAMETER AvailabilityMode
    Optional explicit override: 'SynchronousCommit' or 'AsynchronousCommit'. When omitted it is
    derived from -FailoverMode (Automatic -> SynchronousCommit, Manual -> AsynchronousCommit).

.PARAMETER BackupPreference
    AUTOMATED_BACKUP_PREFERENCE: 'Primary', 'Secondary', 'PreferSecondary' or 'None'. Default: 'Primary'.

.PARAMETER SeedingMode
    'Automatic' (automatic seeding, no manual backup/restore) or 'Manual'. Default: 'Automatic'.

.PARAMETER ListenerName
    Optional AG listener (network) name. When set together with -ListenerIPAddress and -ListenerPort
    the listener is created after the AG.

.PARAMETER ListenerIPAddress
    One or more static IPv4 addresses for the listener.

.PARAMETER ListenerSubnetMask
    Subnet mask for the listener IP(s). Default: '255.255.255.0'.

.PARAMETER ListenerPort
    TCP port of the listener. Default: 1433.

.PARAMETER ServiceAccount
    SQL Server service account (DOMAIN\User or UPN). When supplied the login is created on each
    replica (if missing) and granted CONNECT on the endpoint.

.PARAMETER RestartService
    Restart the SQL Server service on a replica after enabling HADR. Default: $true. HADR only takes
    effect after a restart, so disabling this requires you to restart the services yourself.

.PARAMETER CleanupOrphanedWsfcGroup
    When set, an orphaned WSFC group named like the AG (a remnant of a failed previous attempt, with
    no matching SQL AG) is removed before CREATE AVAILABILITY GROUP. Requires the FailoverClusters
    module on the executing node.

.PARAMETER SqlCredential
    PSCredential for SQL authentication on all replicas. Omit for Windows authentication.

.PARAMETER EnableException
    Throw on error instead of logging a warning and returning a failed result object.

.EXAMPLE
    New-sqmAvailabilityGroup -SqlInstance SQL01 -SecondaryReplica SQL02 `
        -AvailabilityGroupName ProdAG -Database AppDb `
        -ListenerName ProdAGL -ListenerIPAddress 10.0.0.50 -ListenerPort 1433 `
        -ServiceAccount 'CONTOSO\svcSql'

    Creates a two-node synchronous AG with automatic seeding and a listener.

.EXAMPLE
    New-sqmAvailabilityGroup -SqlInstance SQL01 -SecondaryReplica SQL02,SQL03 `
        -AvailabilityGroupName ProdAG -FailoverMode Manual -BackupPreference PreferSecondary -WhatIf

    Dry-run of a three-node asynchronous AG; no changes are made.

.NOTES
    Requires: dbatools (Invoke-DbaQuery, Connect-DbaInstance), Invoke-sqmLogging. Run as a user with
    sysadmin on all replicas and local admin on the cluster nodes. Tested topology: Windows Server
    2022 / SQL Server 2022, up to 3 nodes. Ported from AlwaysOnSetup.ps1.
#>
function New-sqmAvailabilityGroup
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[string[]]$SecondaryReplica,

		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[string[]]$Database,

		[Parameter(Mandatory = $false)]
		[hashtable]$ReplicaHostMap = @{ },

		[Parameter(Mandatory = $false)]
		[string]$EndpointName = 'HADR_Endpoint',

		[Parameter(Mandatory = $false)]
		[int]$EndpointPort = 5022,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Automatic', 'Manual')]
		[string]$FailoverMode = 'Automatic',

		[Parameter(Mandatory = $false)]
		[ValidateSet('SynchronousCommit', 'AsynchronousCommit')]
		[string]$AvailabilityMode,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Primary', 'Secondary', 'PreferSecondary', 'None')]
		[string]$BackupPreference = 'Primary',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Automatic', 'Manual')]
		[string]$SeedingMode = 'Automatic',

		[Parameter(Mandatory = $false)]
		[string]$ListenerName,

		[Parameter(Mandatory = $false)]
		[string[]]$ListenerIPAddress,

		[Parameter(Mandatory = $false)]
		[string]$ListenerSubnetMask = '255.255.255.0',

		[Parameter(Mandatory = $false)]
		[int]$ListenerPort = 1433,

		[Parameter(Mandatory = $false)]
		[string]$ServiceAccount,

		[Parameter(Mandatory = $false)]
		[bool]$RestartService = $true,

		[Parameter(Mandatory = $false)]
		[switch]$CleanupOrphanedWsfcGroup,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName fuer AG '$AvailabilityGroupName' (Primary: $SqlInstance)" -FunctionName $functionName -Level 'INFO'

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			throw $errMsg
		}

		# Derived T-SQL keywords
		$failMode  = if ($FailoverMode -eq 'Automatic') { 'AUTOMATIC' } else { 'MANUAL' }
		if ($AvailabilityMode)
		{
			$availMode = if ($AvailabilityMode -eq 'SynchronousCommit') { 'SYNCHRONOUS_COMMIT' } else { 'ASYNCHRONOUS_COMMIT' }
		}
		else
		{
			$availMode = if ($FailoverMode -eq 'Automatic') { 'SYNCHRONOUS_COMMIT' } else { 'ASYNCHRONOUS_COMMIT' }
		}
		$seedSql = if ($SeedingMode -eq 'Automatic') { 'AUTOMATIC' } else { 'MANUAL' }
		$backupPref = switch ($BackupPreference)
		{
			'Secondary'       { 'SECONDARY_ONLY' }
			'PreferSecondary' { 'SECONDARY' }
			'None'            { 'NONE' }
			default           { 'PRIMARY' }
		}

		# Original service-account UPN (for the cross-domain CREATE LOGIN fallback)
		$serviceAccountUpn = if ($ServiceAccount -and $ServiceAccount -match '@') { $ServiceAccount } else { $null }

		# All replicas in role order (primary first)
		$allInstances = @($SqlInstance) + @($SecondaryReplica | Where-Object { $_ })
		$allInstances = $allInstances | Where-Object { $_ } | Select-Object -Unique
		$secondaries  = @($allInstances | Where-Object { $_ -ne $SqlInstance })

		# Map instance -> endpoint host (FQDN if provided, else instance host part)
		function Resolve-EndpointHost([string]$instance)
		{
			if ($ReplicaHostMap.ContainsKey($instance) -and $ReplicaHostMap[$instance]) { return $ReplicaHostMap[$instance] }
			return ($instance -split '\\')[0]
		}

		# Find a valid sysadmin login for ENDPOINT AUTHORIZATION (sa may be renamed/disabled)
		function Get-ValidEndpointOwner([string]$instance, [string]$preferred)
		{
			if ($preferred -and $preferred -ne 'sa')
			{
				try
				{
					$r = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential `
						-Query "SELECT name FROM sys.server_principals WHERE name = N'$preferred' AND is_srvrolemember('sysadmin', name) = 1" -ErrorAction SilentlyContinue
					if ($r) { return $preferred }
				}
				catch { }
			}
			try
			{
				$r = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential `
					-Query "SELECT name FROM sys.server_principals WHERE name = N'sa' AND is_srvrolemember('sysadmin', name) = 1" -ErrorAction SilentlyContinue
				if ($r) { return 'sa' }
			}
			catch { }
			try
			{
				$r = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential `
					-Query "SELECT TOP 1 name FROM sys.server_principals WHERE is_srvrolemember('sysadmin', name) = 1 AND name NOT LIKE '##%' ORDER BY name" -ErrorAction SilentlyContinue
				if ($r) { return $r.name }
			}
			catch { }
			return 'sa'
		}

		# Restart the SQL Server service on the host of $instance and wait until it is query-able again.
		function Restart-SqlForHadr([string]$instance)
		{
			$svcName = if ($instance -match '\\') { 'MSSQL$' + ($instance -split '\\')[1] } else { 'MSSQLSERVER' }
			$targetHost = ($instance -split '\\')[0]
			$wmiSvc = Get-WmiObject -ComputerName $targetHost -Class Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
			if (-not $wmiSvc) { return $false }
			$wmiSvc.StopService() | Out-Null
			Start-Sleep -Seconds 5
			$wmiSvc.StartService() | Out-Null
			for ($w = 1; $w -le 24; $w++)
			{
				Start-Sleep -Seconds 5
				try
				{
					$ping = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Query 'SELECT 1 AS ok' -ErrorAction Stop | Select-Object -First 1
					if ($ping.ok -eq 1) { return $true }
				}
				catch { }
			}
			return $false
		}

		$result = [PSCustomObject]@{
			AvailabilityGroup = $AvailabilityGroupName
			PrimaryReplica    = $SqlInstance
			SecondaryReplicas = $secondaries
			Database          = $Database
			Listener          = $ListenerName
			Status            = 'Pending'
			Steps             = [System.Collections.Generic.List[string]]::new()
			Error             = $null
			Timestamp         = Get-Date
		}
		function Add-Step([string]$msg, [string]$level = 'INFO')
		{
			$result.Steps.Add("[$level] $msg")
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level $level
		}
	}

	process
	{
		try
		{
			if ($secondaries.Count -eq 0)
			{
				Add-Step "Keine Secondary-Replikate angegeben - es wird eine Single-Replica-AG erstellt." 'WARNING'
			}

			# UPN -> DOMAIN\user normalisieren (NetBIOS der KONTO-Domaene)
			if ($ServiceAccount -and $ServiceAccount -match '@')
			{
				$upnUser   = $ServiceAccount -replace '@.*$', ''
				$upnSuffix = $ServiceAccount -replace '^[^@]+@', ''
				$netBios   = ''
				try
				{
					$domCtx   = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $upnSuffix)
					$adDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($domCtx)
					$netBios  = $adDomain.GetDirectoryEntry().Properties['name'].Value
					if (-not $netBios) { throw 'leer' }
				}
				catch
				{
					try { $netBios = (Get-ADDomain -Server $upnSuffix -ErrorAction Stop).NetBIOSName }
					catch { $netBios = ($upnSuffix -split '\.')[0].ToUpper() }
				}
				$ServiceAccount = "$netBios\$upnUser"
				Add-Step "UPN konvertiert -> '$ServiceAccount' (NetBIOS: $netBios)"
			}

			# ----------------------------------------------------------------
			# 1. HADR auf allen Replikaten aktivieren
			# ----------------------------------------------------------------
			foreach ($inst in $allInstances)
			{
				try
				{
					$hadr = Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential `
						-Query "SELECT value_in_use FROM sys.configurations WHERE name = 'hadr enabled'" -ErrorAction SilentlyContinue | Select-Object -First 1
					if ($hadr -and $hadr.value_in_use -eq 1)
					{
						Add-Step "${inst}: HADR bereits aktiv - uebersprungen."
						continue
					}
					if ($PSCmdlet.ShouldProcess($inst, "HADR aktivieren (sp_configure 'hadr enabled', 1)"))
					{
						Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop `
							-Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;"
						Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop `
							-Query "EXEC sp_configure 'hadr enabled', 1; RECONFIGURE;"
						if ($RestartService)
						{
							Add-Step "${inst}: HADR aktiviert - Dienst-Neustart ..."
							$ok = Restart-SqlForHadr -instance $inst
							if ($ok) { Add-Step "${inst}: HADR aktiviert, SQL Server bereit." }
							else { Add-Step "${inst}: SQL Server nach Neustart nicht erreichbar." 'WARNING' }
						}
						else
						{
							Add-Step "${inst}: HADR aktiviert (Dienst-Neustart manuell erforderlich)." 'WARNING'
						}
					}
				}
				catch
				{
					Add-Step "${inst}: HADR-Aktivierung fehlgeschlagen - $($_.Exception.Message)" 'ERROR'
					if ($EnableException) { throw }
				}
			}

			# ----------------------------------------------------------------
			# 2. Mirroring-Endpoint anlegen
			# ----------------------------------------------------------------
			foreach ($inst in $allInstances)
			{
				try
				{
					$ep = Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential `
						-Query "SELECT name FROM sys.endpoints WHERE type = 4" -ErrorAction SilentlyContinue | Select-Object -First 1
					if ($ep)
					{
						Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction SilentlyContinue `
							-Query "ALTER ENDPOINT [$($ep.name)] STATE = STARTED;"
						Add-Step "${inst}: Endpoint '$($ep.name)' bereits vorhanden - gestartet."
						continue
					}
					if ($PSCmdlet.ShouldProcess($inst, "Endpoint '$EndpointName' (Port $EndpointPort) erstellen"))
					{
						$epOwner = Get-ValidEndpointOwner -instance $inst -preferred $ServiceAccount
						Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop -Query @"
CREATE ENDPOINT [$EndpointName]
    AUTHORIZATION [$epOwner]
    STATE = STARTED
    AS TCP (LISTENER_PORT = $EndpointPort)
    FOR DATABASE_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
"@
						Add-Step "${inst}: Endpoint '$EndpointName' erstellt und gestartet."
					}
				}
				catch
				{
					Add-Step "${inst}: Endpoint-Fehler - $($_.Exception.Message)" 'ERROR'
					if ($EnableException) { throw }
				}
			}

			# ----------------------------------------------------------------
			# 3. Service-Konto Login + GRANT CONNECT ON ENDPOINT
			# ----------------------------------------------------------------
			if ($ServiceAccount)
			{
				foreach ($inst in $allInstances)
				{
					try
					{
						$loginCheckSql = "SELECT name FROM sys.server_principals WHERE name IN (N'$ServiceAccount'"
						if ($serviceAccountUpn) { $loginCheckSql += ", N'$serviceAccountUpn'" }
						$loginCheckSql += ')'
						$loginCheck = Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -Query $loginCheckSql -ErrorAction SilentlyContinue | Select-Object -First 1
						$actualLogin = if ($loginCheck) { $loginCheck.name } else { $ServiceAccount }

						if (-not $loginCheck -and $PSCmdlet.ShouldProcess($inst, "CREATE LOGIN [$ServiceAccount] FROM WINDOWS"))
						{
							$created = $false
							try
							{
								Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -Query "CREATE LOGIN [$ServiceAccount] FROM WINDOWS" -EnableException:$true
								$actualLogin = $ServiceAccount; $created = $true
								Add-Step "${inst}: Login angelegt (DOMAIN\User)."
							}
							catch
							{
								Add-Step "${inst}: DOMAIN\User nicht aufloesbar ($($_.Exception.Message -replace '\r?\n',' '))" 'WARNING'
							}
							if (-not $created -and $serviceAccountUpn)
							{
								try
								{
									Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -Query "CREATE LOGIN [$serviceAccountUpn] FROM WINDOWS" -EnableException:$true
									$actualLogin = $serviceAccountUpn; $created = $true
									Add-Step "${inst}: Login angelegt (UPN-Format)."
								}
								catch { Add-Step "${inst}: UPN-Format ebenfalls nicht aufloesbar." 'WARNING' }
							}
							if (-not $created)
							{
								Add-Step "${inst}: Windows-Login nicht anlegbar. Endpoint-Authentifizierung per Zertifikat manuell einrichten (CREATE LOGIN + GRANT CONNECT ON ENDPOINT durch AD-Team)." 'WARNING'
								continue
							}
						}
						elseif ($loginCheck)
						{
							Add-Step "${inst}: Login '$actualLogin' bereits vorhanden - uebersprungen."
						}

						$ep = Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential `
							-Query "SELECT name FROM sys.endpoints WHERE type = 4" -ErrorAction SilentlyContinue | Select-Object -First 1
						if ($ep -and $PSCmdlet.ShouldProcess($inst, "GRANT CONNECT ON ENDPOINT TO [$actualLogin]"))
						{
							try
							{
								Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential `
									-Query "GRANT CONNECT ON ENDPOINT::[$($ep.name)] TO [$actualLogin]" -EnableException:$true
								Add-Step "${inst}: CONNECT-Berechtigung gesetzt fuer '$actualLogin'."
							}
							catch { Add-Step "${inst}: GRANT CONNECT fehlgeschlagen - $($_.Exception.Message)" 'ERROR' }
						}
					}
					catch
					{
						Add-Step "${inst}: Fehler bei Endpoint-Berechtigung - $($_.Exception.Message)" 'ERROR'
						if ($EnableException) { throw }
					}
				}
			}

			# ----------------------------------------------------------------
			# 4. Seed-Datenbank(en) auf Primary anlegen + RECOVERY FULL
			# ----------------------------------------------------------------
			foreach ($db in @($Database | Where-Object { $_ }))
			{
				try
				{
					$dbCheck = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
						-Query "SELECT name FROM sys.databases WHERE name = N'$db'" -ErrorAction SilentlyContinue | Select-Object -First 1
					if (-not $dbCheck -and $PSCmdlet.ShouldProcess($SqlInstance, "CREATE DATABASE [$db]"))
					{
						Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop -Query "CREATE DATABASE [$db];"
						Add-Step "Datenbank '$db' auf Primary erstellt."
					}
					elseif ($dbCheck)
					{
						Add-Step "Datenbank '$db' bereits vorhanden."
					}
					if ($PSCmdlet.ShouldProcess($SqlInstance, "ALTER DATABASE [$db] SET RECOVERY FULL"))
					{
						Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop -Query "ALTER DATABASE [$db] SET RECOVERY FULL;"
						Add-Step "Datenbank '$db': Recovery-Modell FULL."
					}
				}
				catch
				{
					Add-Step "Datenbankvorbereitung '$db' fehlgeschlagen - $($_.Exception.Message)" 'ERROR'
					if ($EnableException) { throw }
				}
			}

			# ----------------------------------------------------------------
			# 5. Verwaiste WSFC-Gruppe bereinigen (optional)
			# ----------------------------------------------------------------
			if ($CleanupOrphanedWsfcGroup)
			{
				$agCheck = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
					-Query "SELECT name FROM sys.availability_groups WHERE name = N'$AvailabilityGroupName'" -ErrorAction SilentlyContinue | Select-Object -First 1
				$wsfcGroup = $null
				try { $wsfcGroup = Get-ClusterGroup -Name $AvailabilityGroupName -ErrorAction SilentlyContinue } catch { }
				if ($wsfcGroup -and -not $agCheck -and $PSCmdlet.ShouldProcess($AvailabilityGroupName, "Verwaiste WSFC-Gruppe entfernen"))
				{
					try
					{
						$wsfcGroup | Stop-ClusterGroup -ErrorAction SilentlyContinue | Out-Null
						Start-Sleep -Seconds 2
						Remove-ClusterGroup -Name $AvailabilityGroupName -RemoveResources -Force -ErrorAction Stop
						Add-Step "Verwaiste WSFC-Gruppe '$AvailabilityGroupName' entfernt."
					}
					catch { Add-Step "WSFC-Gruppe konnte nicht entfernt werden: $($_.Exception.Message)" 'WARNING' }
					foreach ($inst in $allInstances)
					{
						$h = ($inst -split '\\')[0]
						try
						{
							Invoke-Command -ComputerName $h -ErrorAction Stop -ScriptBlock {
								$regPath = 'HKLM:\Cluster\HadrAgNameToldMap'
								if (Test-Path $regPath)
								{
									(Get-ItemProperty -Path $regPath).PSObject.Properties |
										Where-Object { $_.Name -notlike 'PS*' -and $_.Name -eq $using:AvailabilityGroupName } |
										ForEach-Object { Remove-ItemProperty -Path $regPath -Name $_.Name -ErrorAction SilentlyContinue }
								}
							}
							Add-Step "Registry HadrAgNameToldMap auf '$h' bereinigt."
						}
						catch { Add-Step "Registry auf '$h' nicht bereinigt: $($_.Exception.Message)" 'WARNING' }
					}
					Start-Sleep -Seconds 3
				}
			}

			# ----------------------------------------------------------------
			# 6. Availability Group anlegen
			# ----------------------------------------------------------------
			$agExists = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
				-Query "SELECT name FROM sys.availability_groups WHERE name = N'$AvailabilityGroupName'" -ErrorAction SilentlyContinue | Select-Object -First 1
			if ($agExists)
			{
				Add-Step "AG '$AvailabilityGroupName' bereits vorhanden - Erstellung uebersprungen." 'WARNING'
			}
			elseif ($PSCmdlet.ShouldProcess($SqlInstance, "CREATE AVAILABILITY GROUP [$AvailabilityGroupName]"))
			{
				$replicaDefs = @()
				foreach ($inst in $allInstances)
				{
					$fqhn = Resolve-EndpointHost -instance $inst
					$replicaDefs += "N'$inst' WITH (ENDPOINT_URL = N'TCP://$($fqhn):$EndpointPort', FAILOVER_MODE = $failMode, AVAILABILITY_MODE = $availMode, SEEDING_MODE = $seedSql, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))"
				}
				$replicaClause = $replicaDefs -join ",`r`n    "
				$dbClause = if (@($Database | Where-Object { $_ }).Count -gt 0)
				{
					"`r`nFOR DATABASE " + (($Database | Where-Object { $_ } | ForEach-Object { "[$_]" }) -join ', ')
				}
				else { '' }

				$createAgSql = @"
CREATE AVAILABILITY GROUP [$AvailabilityGroupName]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = $backupPref,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE,
    CLUSTER_TYPE = WSFC,
    REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0
)$dbClause
REPLICA ON
    $replicaClause;
"@
				$createAgSql = ($createAgSql -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join "`r`n"
				try
				{
					Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $createAgSql -ErrorAction Stop
					Add-Step "AG '$AvailabilityGroupName' auf Primary angelegt."
				}
				catch
				{
					Add-Step "AG-Erstellung fehlgeschlagen - $($_.Exception.Message)" 'ERROR'
					if ($EnableException) { throw }
				}

				# Secondaries beitreten + Autoseed genehmigen
				foreach ($sec in $secondaries)
				{
					if (-not $PSCmdlet.ShouldProcess($sec, "ALTER AVAILABILITY GROUP JOIN + GRANT CREATE ANY DATABASE")) { continue }
					try
					{
						Invoke-DbaQuery -SqlInstance $sec -SqlCredential $SqlCredential -ErrorAction Stop `
							-Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] JOIN; ALTER AVAILABILITY GROUP [$AvailabilityGroupName] GRANT CREATE ANY DATABASE;"
						Add-Step "${sec}: AG beigetreten, Autoseed genehmigt."
					}
					catch { Add-Step "${sec}: Beitritt fehlgeschlagen - $($_.Exception.Message)" 'ERROR' }
				}

				# Failover-Modus explizit auf Secondary pinnen (JOIN kann den Modus zuruecksetzen)
				foreach ($sec in $secondaries)
				{
					try
					{
						Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop `
							-Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] MODIFY REPLICA ON N'$sec' WITH (FAILOVER_MODE = $failMode, AVAILABILITY_MODE = $availMode);"
						Add-Step "${sec}: Failover-Modus '$failMode' gesetzt."
					}
					catch { Add-Step "${sec}: MODIFY REPLICA fehlgeschlagen (nicht kritisch) - $($_.Exception.Message)" 'WARNING' }
				}
			}

			# ----------------------------------------------------------------
			# 7. Listener konfigurieren
			# ----------------------------------------------------------------
			if ($ListenerName -and $ListenerIPAddress -and $ListenerIPAddress.Count -gt 0)
			{
				# Warten bis die AG sichtbar ist (Seeding/DMV-Latenz nach Dienst-Neustart)
				$agVisible = $false
				for ($attempt = 1; $attempt -le 6; $attempt++)
				{
					$c = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
						-Query "SELECT COUNT(*) AS n FROM sys.availability_groups WHERE name = N'$AvailabilityGroupName'" -ErrorAction SilentlyContinue | Select-Object -First 1
					if ($c -and $c.n -eq 1) { $agVisible = $true; break }
					Add-Step "AG noch nicht sichtbar - warte 10s (Versuch $attempt/6) ..."
					Start-Sleep -Seconds 10
				}
				if (-not $agVisible)
				{
					Add-Step "AG nach 60s nicht sichtbar - Listener-Schritt uebersprungen." 'WARNING'
				}
				else
				{
					$lsnExists = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
						-Query "SELECT COUNT(*) AS n FROM sys.availability_group_listeners l JOIN sys.availability_groups ag ON ag.group_id = l.group_id WHERE ag.name = N'$AvailabilityGroupName'" -ErrorAction SilentlyContinue | Select-Object -First 1
					if ($lsnExists -and $lsnExists.n -eq 1)
					{
						Add-Step "Listener bereits vorhanden - uebersprungen."
					}
					elseif ($PSCmdlet.ShouldProcess($SqlInstance, "ADD LISTENER [$ListenerName] PORT $ListenerPort"))
					{
						$ipClause = (($ListenerIPAddress | ForEach-Object { "(N'$_', N'$ListenerSubnetMask')" }) -join ', ')
						try
						{
							Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop `
								-Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] ADD LISTENER N'$ListenerName' (WITH IP ($ipClause), PORT = $ListenerPort);"
							Add-Step "Listener '$ListenerName' ($($ListenerIPAddress -join ', '):$ListenerPort) erstellt."
						}
						catch
						{
							Add-Step "Listener-Anlage fehlgeschlagen - $($_.Exception.Message)" 'ERROR'
							if ($EnableException) { throw }
						}
					}
				}
			}

			# ----------------------------------------------------------------
			# Abschlussstatus
			# ----------------------------------------------------------------
			if (-not $WhatIfPreference)
			{
				Start-Sleep -Seconds 3
				try
				{
					$agStatus = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction SilentlyContinue -Query @"
SELECT ag.name, ags.primary_replica, ags.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
WHERE ag.name = N'$AvailabilityGroupName'
"@ | Select-Object -First 1
					if ($agStatus)
					{
						Add-Step "AG '$($agStatus.name)' | Sync: $($agStatus.synchronization_health_desc) | Primary: $($agStatus.primary_replica)"
					}
					else
					{
						Add-Step "AG-Status noch nicht abfragbar - Seeding laeuft moeglicherweise noch." 'WARNING'
					}
				}
				catch { Add-Step "Status-Abfrage fehlgeschlagen - $($_.Exception.Message)" 'WARNING' }
			}

			$hasError = @($result.Steps | Where-Object { $_ -like '`[ERROR`]*' }).Count -gt 0
			$result.Status = if ($WhatIfPreference) { 'WhatIf' } elseif ($hasError) { 'CompletedWithErrors' } else { 'Success' }
		}
		catch
		{
			$result.Status = 'Failed'
			$result.Error  = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler in ${functionName}: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. Status: $($result.Status)" -FunctionName $functionName -Level 'INFO'
		return $result
	}
}
