function Get-sqmProviderInventoryReplicaHost
{
	<#
	.SYNOPSIS
	    Liefert die Hosts der AlwaysOn-Partnerreplikate, die noch nicht gescannt wurden.
	.DESCRIPTION
	    Liest aus den Scan-Ergebnissen der Instanzen (high_availability.availability_replicas) die
	    Namen der Replikate. Das lokale Replikat (is_local = 1) und Hosts aus -ExcludeHost werden
	    uebersprungen. Der Host ist der Teil vor dem Backslash ("SQL02\INST1" -> "SQL02"), der
	    Vergleich laeuft ohne Domain-Suffix und ohne Gross-/Kleinschreibung. Ergebnis: ein Objekt je
	    Host mit host und replicas (die Replikatnamen auf diesem Host), in der Reihenfolge des Auftretens.
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[object[]]$Instance,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeHost
	)

	$skip = @{ }
	foreach ($e in @($ExcludeHost)) { if ($e) { $skip[$e.Split('\')[0].Split('.')[0].ToUpperInvariant()] = $true } }

	$order = New-Object System.Collections.ArrayList
	$byHost = @{ }
	foreach ($i in @($Instance))
	{
		if (-not $i) { continue }
		$ha = $i.high_availability
		if (-not $ha) { continue }
		foreach ($r in @($ha.availability_replicas))
		{
			if (-not $r -or -not $r.replica_server_name) { continue }
			if ($r.is_local -eq $true -or "$($r.is_local)" -eq '1') { continue }
			$name = [string]$r.replica_server_name
			$hostName = $name.Split('\')[0]
			$key = $hostName.Split('.')[0].ToUpperInvariant()
			if ($skip.ContainsKey($key)) { continue }
			if (-not $byHost.ContainsKey($key))
			{
				$byHost[$key] = [pscustomobject]@{ host = $hostName; replicas = (New-Object System.Collections.ArrayList) }
				[void]$order.Add($key)
			}
			if (-not ($byHost[$key].replicas -contains $name)) { [void]$byHost[$key].replicas.Add($name) }
		}
	}
	foreach ($k in $order) { [pscustomobject]@{ host = $byHost[$k].host; replicas = @($byHost[$k].replicas) } }
}
