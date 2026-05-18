<#
.SYNOPSIS
    Retrieves information about a Windows Failover Cluster: cluster name, nodes and roles including IP addresses.

.DESCRIPTION
    This function queries a Windows Failover Cluster and returns an object containing the cluster name,
    a list of nodes, and a list of roles (cluster groups).
    For each role, the associated IP address resources are also provided.
    By default, the core cluster group ("Cluster Group") and all storage groups ("Available Storage")
    are excluded from the role list.

    If the required PowerShell module 'FailoverClusters' is not available, an attempt is made to
    install the RSAT clustering tools automatically (Windows Server only, administrator rights required).

.PARAMETER ClusterName
    The name of the cluster to query. If not specified, the function attempts to determine
    the local cluster (only meaningful on a cluster node).

.PARAMETER IncludeCoreGroup
    Switch to include the core cluster group ("Cluster Group") in the roles list.
    Storage groups are always excluded.

.PARAMETER NoAutoInstall
    Suppresses the automatic installation of RSAT clustering tools if the module is missing.

.PARAMETER EnableException
    When set, errors are thrown as exceptions (by default an error object is returned).

.OUTPUTS
    PSCustomObject with the following properties:
    - Success      : $true on success, $false on error
    - ErrorMessage : Error description when Success = $false, otherwise $null
    - ClusterName  : Name of the cluster
    - Nodes        : Array of node objects (Name, State)
    - Roles        : Array of role objects (Name, State, OwnerNode, IPAddresses)

.EXAMPLE
    $info = Get-sqmClusterInfo -ClusterName "MYCLUSTER"
    if (-not $info.Success) { Write-Error $info.ErrorMessage; return }
    $info.ClusterName
    $info.Nodes | Format-Table
    $info.Roles | Where-Object OwnerNode -eq "Node1" | Select Name, IPAddresses

.EXAMPLE
    Get-sqmClusterInfo -IncludeCoreGroup

    Queries the local cluster and returns all roles including the core group.

.NOTES
    Requires administrator rights for automatic installation of RSAT tools.
    The function uses Invoke-sqmLogging internally for diagnostic messages.
#>
function Get-sqmClusterInfo
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ClusterName,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeCoreGroup,
		[Parameter(Mandatory = $false)]
		[switch]$NoAutoInstall,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	$functionName = $MyInvocation.MyCommand.Name
	
	# Hilfsfunktion fuer einheitliche Fehler-Rueckgabe
	function New-ErrorResult
	{
		param ([string]$Message)
		[PSCustomObject]@{
			Success	     = $false
			ErrorMessage = $Message
			ClusterName  = $null
			Nodes	     = $null
			Roles	     = $null
		}
	}
	
	# Pruefen, ob das FailoverClusters-Modul verfuegbar ist
	$moduleAvailable = $true
	try
	{
		$null = Get-Module -ListAvailable -Name FailoverClusters -ErrorAction Stop
	}
	catch
	{
		$moduleAvailable = $false
	}
	
	# Falls Modul fehlt und AutoInstall nicht unterdrueckt wurde, versuchen zu installieren
	if (-not $moduleAvailable -and -not $NoAutoInstall)
	{
		Invoke-sqmLogging -Message "Modul 'FailoverClusters' nicht gefunden. Versuche RSAT-Clustering-Tools zu installieren..." -FunctionName $functionName -Level "INFO"
		try
		{
			# Pruefen, ob das Feature RSAT-Clustering-PowerShell verfuegbar ist (Windows Server)
			$feature = Get-WindowsFeature -Name RSAT-Clustering-PowerShell -ErrorAction SilentlyContinue
			if ($feature -and $feature.Installed -eq $false)
			{
				# Installation durchfuehren (benoetigt Adminrechte)
				Invoke-sqmLogging -Message "Installiere Windows-Feature 'RSAT-Clustering-PowerShell'..." -FunctionName $functionName -Level "INFO"
				$installResult = Install-WindowsFeature -Name RSAT-Clustering-PowerShell -IncludeManagementTools -ErrorAction Stop
				if ($installResult.Success -eq $false)
				{
					throw "Installation von 'RSAT-Clustering-PowerShell' fehlgeschlagen."
				}
				Invoke-sqmLogging -Message "Feature 'RSAT-Clustering-PowerShell' erfolgreich installiert." -FunctionName $functionName -Level "INFO"
			}
			else
			{
				# Versuche mit Add-WindowsCapability fuer Windows 10/11 (Client)
				$capability = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'Rsat.Clustering*' -and $_.State -eq 'NotPresent' }
				if ($capability)
				{
					Invoke-sqmLogging -Message "Installiere Windows Capability 'Rsat.Clustering'..." -FunctionName $functionName -Level "INFO"
					Add-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop
					Invoke-sqmLogging -Message "Capability 'Rsat.Clustering' erfolgreich installiert." -FunctionName $functionName -Level "INFO"
				}
				else
				{
					throw "Kein installierbares RSAT-Clustering-Paket gefunden. Bitte installieren Sie die RSAT-Tools manuell."
				}
			}
			# Nach erfolgreicher Installation: Modul neu laden
			Import-Module -Name FailoverClusters -Force -ErrorAction Stop
			Invoke-sqmLogging -Message "Modul 'FailoverClusters' erfolgreich geladen." -FunctionName $functionName -Level "INFO"
			$moduleAvailable = $true
		}
		catch
		{
			$errMsg = "Fehler bei automatischer Installation der RSAT-Clustering-Tools: $_"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw $errMsg }
			return New-ErrorResult $errMsg
		}
	}
	
	# Falls Modul immer noch nicht verfuegbar (und keine AutoInstall oder Fehler)
	if (-not $moduleAvailable)
	{
		$errMsg = "Das PowerShell-Modul 'FailoverClusters' ist nicht verfuegbar. Bitte installieren Sie die RSAT-Clustering-Tools."
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $errMsg }
		return New-ErrorResult $errMsg
	}
	
	# Modul importieren (falls noch nicht geladen)
	try
	{
		Import-Module -Name FailoverClusters -ErrorAction Stop
	}
	catch
	{
		$errMsg = "Fehler beim Importieren des Moduls 'FailoverClusters': $_"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $errMsg }
		return New-ErrorResult $errMsg
	}
	
	# Parameter fuer Get-Cluster vorbereiten
	$clusterParams = @{ }
	if ($ClusterName)
	{
		$clusterParams['Name'] = $ClusterName
	}
	
	# Cluster-Objekt abrufen
	$cluster = $null
	try
	{
		$cluster = Get-Cluster @clusterParams -ErrorAction Stop
	}
	catch
	{
		$errMsg = "Fehler beim Abrufen des Clusters: $_"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $errMsg }
		return New-ErrorResult $errMsg
	}
	
	if (-not $cluster)
	{
		$errMsg = "Es wurde kein Cluster gefunden. Stellen Sie sicher, dass das Skript auf einem Clusterknoten ausgefuehrt wird oder geben Sie einen gueltigen Clusternamen an."
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARNING"
		if ($EnableException) { throw $errMsg }
		return New-ErrorResult $errMsg
	}
	
	$clusterNameValue = $cluster.Name
	
	# Knoten (Nodes) abrufen
	$nodes = $null
	try
	{
		$nodes = Get-ClusterNode -Cluster $cluster -ErrorAction Stop | ForEach-Object {
			[PSCustomObject]@{
				Name = $_.Name
				State = $_.State
			}
		}
	}
	catch
	{
		$errMsg = "Fehler beim Abrufen der Clusterknoten: $_"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $errMsg }
		return New-ErrorResult $errMsg
	}
	
	# Rollen (Cluster Groups) abrufen
	$groups = $null
	try
	{
		$groups = Get-ClusterGroup -Cluster $cluster -ErrorAction Stop
	}
	catch
	{
		$errMsg = "Fehler beim Abrufen der Clustergruppen: $_"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $errMsg }
		return New-ErrorResult $errMsg
	}
	
	# Cluster-Ressourcen abrufen (einmalig)
	$allResources = $null
	try
	{
		$allResources = Get-ClusterResource -Cluster $cluster -ErrorAction Stop
	}
	catch
	{
		$errMsg = "Fehler beim Abrufen der Clusterressourcen: $_"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $errMsg }
		return New-ErrorResult $errMsg
	}
	
	# Rollen filtern und mit IP-Adressen anreichern
	$roles = foreach ($group in $groups)
	{
		if ($group.GroupType -eq 'AvailableStorage') { continue }
		if (-not $IncludeCoreGroup -and $group.Name -match '^Cluster Group$') { continue }
		
		$ipResources = $allResources | Where-Object {
			$_.OwnerGroup -eq $group.Name -and $_.ResourceType -eq 'IP Address'
		}
		
		$ipAddresses = foreach ($ipRes in $ipResources)
		{
			$addrParam = $null
			try
			{
				$addrParam = $ipRes | Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue
			}
			catch { }
			if ($addrParam -and $addrParam.Value)
			{
				$addrParam.Value
			}
			else
			{
				$ipRes.Address
			}
		}
		
		[PSCustomObject]@{
			Name = $group.Name
			State = $group.State
			OwnerNode = $group.OwnerNode
			IPAddresses = @($ipAddresses)
		}
	}
	
	# Erfolgs-Rueckgabe
	Invoke-sqmLogging -Message "Cluster-Info erfolgreich abgerufen: $clusterNameValue, $($nodes.Count) Knoten, $($roles.Count) Rollen" -FunctionName $functionName -Level "INFO"
	[PSCustomObject]@{
		Success	     = $true
		ErrorMessage = $null
		ClusterName  = $clusterNameValue
		Nodes	     = $nodes
		Roles	     = $roles
	}
}