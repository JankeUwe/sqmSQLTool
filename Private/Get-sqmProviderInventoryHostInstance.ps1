function Get-sqmProviderInventoryHostInstance
{
	<#
	.SYNOPSIS
	    Findet alle laufenden SQL-Server-Instanzen (Dienste) eines Hosts, lokal oder remote.
	.DESCRIPTION
	    Liest die Dienstliste per CIM. Remote: CIM-Session ueber WSMan, bei Fehler ueber DCOM, mit der
	    Windows-Identitaet des Aufrufers. Liefert Objekte mit target (Verbindungsziel) und name
	    (Instanzname). Gibt $null zurueck, wenn der Host per CIM nicht abfragbar ist (der Aufrufer
	    verwendet dann den Namen wie angegeben). Gibt ein leeres Array zurueck, wenn der Host
	    abfragbar ist, aber keinen laufenden SQL-Dienst hat (AG-Listener, FCI-Name).
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$HostName
	)

	$short = $HostName.Split('.')[0]
	$isLocal = ($short -ieq $env:COMPUTERNAME) -or ($HostName -in @('.', 'localhost'))
	$rows = $null
	$hostForTarget = $HostName
	$cimSession = $null
	try
	{
		if ($isLocal)
		{
			$rows = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
			$hostForTarget = $env:COMPUTERNAME
		}
		else
		{
			foreach ($proto in @('Wsman', 'Dcom'))
			{
				try
				{
					$opt = New-CimSessionOption -Protocol $proto
					$cimSession = New-CimSession -ComputerName $HostName -SessionOption $opt -OperationTimeoutSec 30 -ErrorAction Stop
					$rows = @(Get-CimInstance -CimSession $cimSession -ClassName Win32_Service -ErrorAction Stop)
					break
				}
				catch
				{
					Write-Verbose "CIM ($proto) zu $HostName fehlgeschlagen: $($_.Exception.Message)"
					if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue; $cimSession = $null }
					$rows = $null
				}
			}
		}
	}
	catch
	{
		Write-Verbose "Dienstliste von $HostName nicht lesbar: $($_.Exception.Message)"
		$rows = $null
	}
	finally { if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue } }
	if ($null -eq $rows) { return $null }

	$found = @()
	foreach ($s in @($rows | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' }))
	{
		if ($s.State -ne 'Running') { Write-Warning "Dienst $($s.Name) auf $HostName ist $($s.State), uebersprungen."; continue }
		if ($s.Name -eq 'MSSQLSERVER') { $found += [pscustomobject]@{ target = $hostForTarget; name = 'MSSQLSERVER' } }
		else { $found += [pscustomobject]@{ target = ($hostForTarget + '\' + $s.Name.Substring(6)); name = $s.Name.Substring(6) } }
	}
	return , $found
}
