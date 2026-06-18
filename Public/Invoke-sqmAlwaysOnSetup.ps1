<#
.SYNOPSIS
    End-to-end CLI AlwaysOn setup: reads the WSFC, creates the Availability Group and synchronises logins.

.DESCRIPTION
    Headless orchestration wrapper around New-sqmAvailabilityGroup. Replaces the GUI of AlwaysOnSetup.ps1.

    Flow:
      1. Discover the Windows Server Failover Cluster (Get-Cluster / Get-ClusterNode) and, if not
         explicitly given, the listener role (name / IP / port from the cluster network-name resource).
      2. Discover the SQL Server engine instance + service account on each cluster node (WMI).
      3. Test connectivity: Windows auth (Kerberos) is preferred. If -SqlCredential is supplied it is
         used directly. If Windows auth fails on any node and no credential was given, the function
         stops with a clear message (the GUI tool created a temporary SQL login here - in headless
         mode you pass -SqlCredential instead, or fix the SPNs first).
      4. (Optional) Back up the current cluster settings to a text file before making changes.
      5. Create the AG via New-sqmAvailabilityGroup (HADR, endpoints, AG, secondaries, listener).
      6. Post-creation: Sync-sqmLoginsToAlwaysOn (logins to all secondaries) and
         Invoke-sqmSqlAlwaysOnAutoseeding (ensure SEEDING_MODE = AUTOMATIC on all replicas).
      7. (Optional) Generate an SPN request file for the AD team (setspn commands for the service
         account covering each node and the listener).

    This wrapper requires the FailoverClusters module on the executing node (run on a cluster member).

.PARAMETER AvailabilityGroupName
    Name of the AG to create. Default: the discovered listener (cluster role) name.

.PARAMETER Database
    Database(s) to seed into the AG (created on the primary, RECOVERY FULL, auto-seeded).

.PARAMETER PrimaryReplica
    Override the primary replica instance. Default: the SQL instance on the first cluster node.

.PARAMETER ListenerName / ListenerIPAddress / ListenerPort / ListenerSubnetMask
    Override the listener discovered from the cluster. When the cluster has no usable listener role,
    these must be supplied to create a listener (otherwise the listener step is skipped).

.PARAMETER EndpointPort
    Database-mirroring endpoint port. Default: 5022.

.PARAMETER FailoverMode
    'Automatic' (sync + automatic failover) or 'Manual' (async). Default: 'Automatic'.

.PARAMETER BackupPreference
    'Primary' / 'Secondary' / 'PreferSecondary' / 'None'. Default: 'Primary'.

.PARAMETER ServiceAccount
    SQL service account for the endpoint CONNECT grant. Default: discovered from the SQL service.

.PARAMETER SqlCredential
    PSCredential for SQL authentication on all replicas (use when Kerberos SPNs are missing). Omit
    for Windows authentication.

.PARAMETER BackupClusterSettings
    Write a cluster-settings backup file before changes. Default: $true.

.PARAMETER GenerateSpnReport
    Write an SPN request file for the AD team. Default: $true.

.PARAMETER OutputPath
    Directory for the cluster-settings backup and SPN report. Default: configured output path
    (Get-sqmDefaultOutputPath), i.e. C:\System\WinSrvLog\MSSQL unless overridden.

.PARAMETER SkipLoginSync
    Skip the post-creation Sync-sqmLoginsToAlwaysOn step.

.PARAMETER EnableException
    Throw on error instead of logging and returning a failed result.

.EXAMPLE
    Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb

    Reads the local cluster, creates ProdAG across all nodes using the discovered listener and
    service account, then syncs logins and enables automatic seeding.

.EXAMPLE
    Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb `
        -SqlCredential (Get-Credential sa) -WhatIf

    Dry-run using SQL authentication; shows the planned actions without changing anything.

.NOTES
    Requires: FailoverClusters, dbatools, New-sqmAvailabilityGroup, Sync-sqmLoginsToAlwaysOn,
    Invoke-sqmSqlAlwaysOnAutoseeding, Invoke-sqmLogging. Run as local admin on a cluster node with
    sysadmin on all replicas. Tested: Windows Server 2022 / SQL Server 2022, up to 3 nodes.
#>
function Invoke-sqmAlwaysOnSetup
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[string[]]$Database,

		[Parameter(Mandatory = $false)]
		[string]$PrimaryReplica,

		[Parameter(Mandatory = $false)]
		[string]$ListenerName,

		[Parameter(Mandatory = $false)]
		[string[]]$ListenerIPAddress,

		[Parameter(Mandatory = $false)]
		[int]$ListenerPort,

		[Parameter(Mandatory = $false)]
		[string]$ListenerSubnetMask = '255.255.255.0',

		[Parameter(Mandatory = $false)]
		[int]$EndpointPort = 5022,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Automatic', 'Manual')]
		[string]$FailoverMode = 'Automatic',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Primary', 'Secondary', 'PreferSecondary', 'None')]
		[string]$BackupPreference = 'Primary',

		[Parameter(Mandatory = $false)]
		[string]$ServiceAccount,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[bool]$BackupClusterSettings = $true,

		[Parameter(Mandatory = $false)]
		[bool]$GenerateSpnReport = $true,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),

		[Parameter(Mandatory = $false)]
		[switch]$SkipLoginSync,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName" -FunctionName $functionName -Level 'INFO'

		foreach ($mod in @('FailoverClusters', 'dbatools'))
		{
			if (-not (Get-Module -ListAvailable -Name $mod))
			{
				$errMsg = "Modul '$mod' nicht gefunden - $functionName kann nicht ausgefuehrt werden."
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
				throw $errMsg
			}
		}
		Import-Module FailoverClusters -ErrorAction SilentlyContinue

		$result = [PSCustomObject]@{
			ClusterName       = $null
			Nodes             = @()
			PrimaryReplica    = $null
			SecondaryReplicas = @()
			AvailabilityGroup = $AvailabilityGroupName
			Listener          = $null
			Status            = 'Pending'
			AgResult          = $null
			LoginSyncResult   = $null
			SeedingResult     = $null
			ClusterSettingsFile = $null
			SpnReportFile     = $null
			Error             = $null
			Timestamp         = Get-Date
		}
	}

	process
	{
		try
		{
			# ------------------------------------------------------------
			# 1. WSFC + Nodes + Listener-Rolle einlesen
			# ------------------------------------------------------------
			$cluster = Get-Cluster -ErrorAction Stop
			$result.ClusterName = $cluster.Name.Trim()
			Invoke-sqmLogging -Message "Cluster gefunden: $($result.ClusterName)" -FunctionName $functionName -Level 'INFO'

			$nodes = @(Get-ClusterNode -ErrorAction Stop | Select-Object -ExpandProperty Name | ForEach-Object { $_.Trim() })
			$result.Nodes = $nodes
			Invoke-sqmLogging -Message "Nodes: $($nodes -join ', ')" -FunctionName $functionName -Level 'INFO'

			# Listener aus Cluster-Rolle (sofern nicht per Parameter vorgegeben)
			$discListenerName = $ListenerName
			$discListenerIP   = $ListenerIPAddress
			$discListenerPort = if ($ListenerPort -gt 0) { $ListenerPort } else { 0 }
			if (-not $discListenerName)
			{
				try
				{
					foreach ($role in (Get-ClusterGroup -ErrorAction SilentlyContinue))
					{
						$roleName = $role.Name.Trim()
						$netRes = Get-ClusterResource -ErrorAction SilentlyContinue |
							Where-Object { $_.OwnerGroup -eq $roleName -and $_.ResourceType -like '*Network Name*' } | Select-Object -First 1
						if (-not $netRes) { continue }
						$discListenerName = (Get-ClusterParameter -InputObject $netRes -Name Name -ErrorAction SilentlyContinue).Value
						if (-not $discListenerName) { $discListenerName = $roleName }
						$ipRes = Get-ClusterResource -ErrorAction SilentlyContinue |
							Where-Object { $_.OwnerGroup -eq $roleName -and $_.ResourceType -like '*IP Address*' } | Select-Object -First 1
						if ($ipRes)
						{
							if (-not $discListenerIP)
							{
								$ip = (Get-ClusterParameter -InputObject $ipRes -Name Address -ErrorAction SilentlyContinue).Value
								if ($ip) { $discListenerIP = @($ip) }
							}
							if ($discListenerPort -le 0)
							{
								$probe = (Get-ClusterParameter -InputObject $ipRes -Name ProbePort -ErrorAction SilentlyContinue).Value
								if ($probe -and [int]$probe -gt 0) { $discListenerPort = [int]$probe }
							}
						}
						break
					}
				}
				catch { Invoke-sqmLogging -Message "Listener-Erkennung unvollstaendig: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING' }
			}
			if ($discListenerPort -le 0) { $discListenerPort = 1433 }

			# ------------------------------------------------------------
			# 2. SQL-Instanz + Dienstkonto je Node (WMI)
			# ------------------------------------------------------------
			$sqlInstances = @()
			$discServiceAccount = $ServiceAccount
			foreach ($node in $nodes)
			{
				try
				{
					$svc = Get-WmiObject -ComputerName $node -Class Win32_Service `
						-Filter "Name='MSSQLSERVER' OR Name LIKE 'MSSQL$%'" -ErrorAction SilentlyContinue |
						Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' } | Select-Object -First 1
					if ($svc)
					{
						$instName = if ($svc.Name -eq 'MSSQLSERVER') { $node } else { "$node\$($svc.Name -replace '^MSSQL\$','')" }
						$sqlInstances += $instName
						if (-not $discServiceAccount) { $discServiceAccount = $svc.StartName }
						Invoke-sqmLogging -Message "${node}: Instanz '$instName' | Konto: $($svc.StartName)" -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						$sqlInstances += $node
						Invoke-sqmLogging -Message "${node}: Kein SQL-Engine-Dienst gefunden - verwende Hostname als Instanz." -FunctionName $functionName -Level 'WARNING'
					}
				}
				catch
				{
					$sqlInstances += $node
					Invoke-sqmLogging -Message "${node}: SQL-Info nicht lesbar - $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}
			$sqlInstances = $sqlInstances | Where-Object { $_ } | Select-Object -Unique

			$primary = if ($PrimaryReplica) { $PrimaryReplica } else { $sqlInstances[0] }
			$secondaries = @($sqlInstances | Where-Object { $_ -ne $primary })
			$result.PrimaryReplica = $primary
			$result.SecondaryReplicas = $secondaries

			# Map Instanz -> Host-FQDN fuer Endpoint-URL
			$hostMap = @{ }
			foreach ($inst in $sqlInstances) { $hostMap[$inst] = ($inst -split '\\')[0] }

			if (-not $AvailabilityGroupName)
			{
				$AvailabilityGroupName = $discListenerName
				$result.AvailabilityGroup = $AvailabilityGroupName
			}
			if (-not $AvailabilityGroupName)
			{
				throw "Kein AG-Name angegeben und keine Listener-Rolle im Cluster gefunden. Bitte -AvailabilityGroupName setzen."
			}

			# ------------------------------------------------------------
			# 3. Konnektivitaet pruefen (Windows-Auth bevorzugt)
			# ------------------------------------------------------------
			$failedNodes = @()
			foreach ($inst in $sqlInstances)
			{
				try
				{
					$conn = Connect-DbaInstance -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop
					$conn.ConnectionContext.Disconnect()
					Invoke-sqmLogging -Message "Auth '$inst': OK" -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					$failedNodes += $inst
					Invoke-sqmLogging -Message "Auth '$inst': fehlgeschlagen - $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}
			if ($failedNodes.Count -gt 0)
			{
				$msg = "Verbindung auf folgenden Nodes fehlgeschlagen: $($failedNodes -join ', '). " +
				       "Bitte SPNs korrigieren oder -SqlCredential (SQL-Auth) angeben. Setup abgebrochen."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				throw $msg
			}

			# ------------------------------------------------------------
			# 4. Cluster-Settings sichern (optional)
			# ------------------------------------------------------------
			if ($BackupClusterSettings -and -not $WhatIfPreference)
			{
				try
				{
					if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
					$settingsFile = Join-Path $OutputPath ("AlwaysOn_ClusterSettings_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add(('=' * 72))
					$lines.Add('AlwaysOn Setup - Cluster Settings Backup')
					$lines.Add('Created : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
					$lines.Add(('=' * 72))
					$lines.Add("Cluster        : $($result.ClusterName)")
					$lines.Add("AG-Name        : $AvailabilityGroupName")
					$lines.Add("Primary        : $primary")
					$lines.Add("Secondaries    : $($secondaries -join ', ')")
					$lines.Add("Listener       : $discListenerName  ($($discListenerIP -join ', '):$discListenerPort)")
					$lines.Add("Endpoint-Port  : $EndpointPort")
					$lines.Add("Failover-Mode  : $FailoverMode")
					$lines.Add("Backup-Pref.   : $BackupPreference")
					$lines.Add("Service-Konto  : $discServiceAccount")
					$lines.Add('')
					$lines.Add('Cluster Groups (WSFC):')
					try { Get-ClusterGroup | ForEach-Object { $lines.Add("  $($_.Name.Trim()) | $($_.State) | Owner: $($_.OwnerNode.ToString().Trim())") } } catch { $lines.Add("  (not readable: $($_.Exception.Message))") }
					$lines.Add('')
					$lines.Add('Cluster Nodes:')
					try { Get-ClusterNode | ForEach-Object { $lines.Add("  $($_.Name.Trim()) | $($_.State)") } } catch { $lines.Add("  (not readable: $($_.Exception.Message))") }
					$lines | Set-Content -LiteralPath $settingsFile -Encoding UTF8
					$result.ClusterSettingsFile = $settingsFile
					Invoke-sqmLogging -Message "Cluster-Settings gesichert: $settingsFile" -FunctionName $functionName -Level 'INFO'
				}
				catch { Invoke-sqmLogging -Message "Cluster-Settings konnten nicht gesichert werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING' }
			}

			# ------------------------------------------------------------
			# 5. AG erstellen
			# ------------------------------------------------------------
			$agParams = @{
				SqlInstance              = $primary
				SecondaryReplica         = $secondaries
				AvailabilityGroupName    = $AvailabilityGroupName
				ReplicaHostMap           = $hostMap
				EndpointPort             = $EndpointPort
				FailoverMode             = $FailoverMode
				BackupPreference         = $BackupPreference
				SeedingMode              = 'Automatic'
				CleanupOrphanedWsfcGroup = $true
				SqlCredential            = $SqlCredential
				ErrorAction              = 'Stop'
			}
			if ($Database) { $agParams.Database = $Database }
			if ($discServiceAccount) { $agParams.ServiceAccount = $discServiceAccount }
			if ($discListenerName -and $discListenerIP)
			{
				$agParams.ListenerName       = $discListenerName
				$agParams.ListenerIPAddress  = $discListenerIP
				$agParams.ListenerSubnetMask = $ListenerSubnetMask
				$agParams.ListenerPort       = $discListenerPort
				$result.Listener = $discListenerName
			}
			if ($EnableException) { $agParams.EnableException = $true }

			if ($PSCmdlet.ShouldProcess($AvailabilityGroupName, "AlwaysOn-AG ueber $($sqlInstances.Count) Replikate erstellen"))
			{
				$result.AgResult = New-sqmAvailabilityGroup @agParams
			}
			else
			{
				# -WhatIf: New-sqmAvailabilityGroup mit -WhatIf aufrufen, damit der Plan sichtbar wird
				$result.AgResult = New-sqmAvailabilityGroup @agParams -WhatIf
			}

			# ------------------------------------------------------------
			# 6. Logins synchronisieren + Autoseeding sicherstellen
			# ------------------------------------------------------------
			if (-not $WhatIfPreference)
			{
				if (-not $SkipLoginSync -and $secondaries.Count -gt 0)
				{
					try
					{
						$result.LoginSyncResult = Sync-sqmLoginsToAlwaysOn -SqlInstance $primary `
							-AvailabilityGroupName $AvailabilityGroupName -SqlCredential $SqlCredential
						Invoke-sqmLogging -Message "Login-Synchronisierung abgeschlossen." -FunctionName $functionName -Level 'INFO'
					}
					catch { Invoke-sqmLogging -Message "Login-Sync fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING' }
				}
				try
				{
					$result.SeedingResult = Invoke-sqmSqlAlwaysOnAutoseeding -SqlInstance $primary `
						-AvailabilityGroup $AvailabilityGroupName -SqlCredential $SqlCredential
					Invoke-sqmLogging -Message "Autoseeding sichergestellt." -FunctionName $functionName -Level 'INFO'
				}
				catch { Invoke-sqmLogging -Message "Autoseeding-Konfiguration fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING' }
			}

			# ------------------------------------------------------------
			# 7. SPN-Report fuer AD-Team (optional)
			# ------------------------------------------------------------
			if ($GenerateSpnReport -and $discServiceAccount -and -not $WhatIfPreference)
			{
				try
				{
					$dnsSuffix = ''
					try { $dnsSuffix = ([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()).DomainName } catch { }
					$targets = [System.Collections.Generic.List[string]]::new()
					foreach ($node in $nodes)
					{
						$h = $node.ToLower()
						$targets.Add("MSSQLSvc/${h}:1433")
						if ($dnsSuffix) { $targets.Add("MSSQLSvc/${h}.${dnsSuffix}:1433") }
					}
					if ($discListenerName)
					{
						$ln = $discListenerName.ToLower()
						$targets.Add("MSSQLSvc/${ln}:$discListenerPort")
						if ($dnsSuffix) { $targets.Add("MSSQLSvc/${ln}.${dnsSuffix}:$discListenerPort") }
					}
					if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
					$spnFile = Join-Path $OutputPath ("AlwaysOn_SPN_ADTeam_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
					$adLines = [System.Collections.Generic.List[string]]::new()
					$adLines.Add(('=' * 72))
					$adLines.Add('SPN request for SQL Server AlwaysOn')
					$adLines.Add('Created : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
					$adLines.Add('Cluster : ' + $result.ClusterName)
					$adLines.Add('AG-Name : ' + $AvailabilityGroupName)
					$adLines.Add('Account : ' + $discServiceAccount)
					$adLines.Add(('=' * 72))
					$adLines.Add('Run as domain admin (one command per line):')
					$adLines.Add(('-' * 72))
					foreach ($t in $targets) { $adLines.Add("setspn -S $t $discServiceAccount") }
					$adLines.Add(('-' * 72))
					$adLines.Add('Verify afterwards:')
					$adLines.Add("  setspn -L $discServiceAccount")
					$adLines | Set-Content -LiteralPath $spnFile -Encoding UTF8
					$result.SpnReportFile = $spnFile
					Invoke-sqmLogging -Message "SPN-Anforderungsdatei gespeichert: $spnFile" -FunctionName $functionName -Level 'INFO'
				}
				catch { Invoke-sqmLogging -Message "SPN-Report konnte nicht erstellt werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING' }
			}

			if ($WhatIfPreference) { $result.Status = 'WhatIf' }
			elseif ($result.AgResult -and $result.AgResult.Status -in @('Success', 'WhatIf')) { $result.Status = 'Success' }
			elseif ($result.AgResult) { $result.Status = $result.AgResult.Status }
			else { $result.Status = 'Success' }
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
