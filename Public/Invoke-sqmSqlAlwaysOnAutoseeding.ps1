<#
.SYNOPSIS
Aktiviert Automatic Seeding auf allen Replikaten einer Always On-Verfuegbarkeitsgruppe.

.DESCRIPTION
Diese Funktion konfiguriert den Seeding-Modus aller Replikate einer oder mehrerer
Verfuegbarkeitsgruppen auf "Automatic". Mit dem Schalter -All werden zwingend alle
Verfuegbarkeitsgruppen auf der Instanz bearbeitet.

Wenn kein SqlInstance-Parameter angegeben wird, wird standardmaessig der aktuelle
Computername ($env:COMPUTERNAME) verwendet. Diese Regel gilt fuer alle zukuenftigen
Versionen.

.PARAMETER SqlInstance
Die Ziel-SQL Server-Instanz (z.B. "localhost", "SQL01\INSTANCE"). 
Wenn nicht angegeben, wird der aktuelle Computername verwendet.

.PARAMETER SqlCredential
Alternative Anmeldeinformationen (PSCredential). Wenn nicht angegeben, wird
Windows-Authentifizierung verwendet.

.PARAMETER AvailabilityGroup
Name der Verfuegbarkeitsgruppe(n). Wird ignoriert, wenn -All gesetzt ist.

.PARAMETER All
Wenn gesetzt, werden alle Verfuegbarkeitsgruppen auf der Instanz verarbeitet.

.PARAMETER EnableException
Schalter, um Ausnahmen durchzulassen (standardmaessig werden Fehler als Warnung
protokolliert).

.EXAMPLE
# Verwendet den aktuellen Computernamen als Standard
Invoke-sqmSqlAlwaysOnAutoseeding

.EXAMPLE
# Explizite Angabe einer Instanz
Invoke-sqmSqlAlwaysOnAutoseeding -SqlInstance "SQL01\INSTANCE"

.EXAMPLE
# Alle Gruppen auf dem aktuellen Computer
Invoke-sqmSqlAlwaysOnAutoseeding -All

.NOTES
Erfordert dbatools-Modul und eine vorhandene Funktion Invoke-sqmLogging.
Default fuer SqlInstance: $env:COMPUTERNAME (gilt fuer alle zukuenftigen Versionen).
#>

function Invoke-sqmSqlAlwaysOnAutoseeding
{
	[CmdletBinding(DefaultParameterSetName = 'Specific', SupportsShouldProcess = $true)]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false, ParameterSetName = 'Specific')]
		[string[]]$AvailabilityGroup,
		[Parameter(Mandatory = $false, ParameterSetName = 'All')]
		[switch]$All,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		
		# Default fuer SqlInstance: aktueller Computername
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}
		
		# Pruefung auf dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		if ($All)
		{
			Invoke-sqmLogging -Message "Parameter -All erkannt: Es werden ALLE Verfuegbarkeitsgruppen auf $SqlInstance verarbeitet." -FunctionName $functionName -Level "INFO"
		}
		
		Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance" -FunctionName $functionName -Level "INFO"
		
		# Ergebnisliste fuer Rueckgabe
		$results = @()
	}
	
	process
	{
		try
		{
			# Verfuegbarkeitsgruppen abrufen - abhaengig von -All
			$agParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				ErrorAction   = 'Stop'
			}
			if ($EnableException) { $agParams.EnableException = $true }
			
			if (-not $All -and $AvailabilityGroup)
			{
				$agParams.AvailabilityGroup = $AvailabilityGroup
				Invoke-sqmLogging -Message "Filtere nach angegebenen Gruppen: $($AvailabilityGroup -join ', ')" -FunctionName $functionName -Level "DEBUG"
			}
			elseif ($All)
			{
				Invoke-sqmLogging -Message "Rufe ALLE Verfuegbarkeitsgruppen ab (Parameter -All aktiv)." -FunctionName $functionName -Level "DEBUG"
			}
			else
			{
				Invoke-sqmLogging -Message "Keine Filterung - verarbeite alle Gruppen." -FunctionName $functionName -Level "DEBUG"
			}
			
			$availabilityGroups = Get-DbaAvailabilityGroup @agParams
			
			if (-not $availabilityGroups)
			{
				$msg = "Keine Verfuegbarkeitsgruppen auf $SqlInstance gefunden (oder Filter ergab keine Treffer)."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				$results += [PSCustomObject]@{
					SqlInstance	      = $SqlInstance
					AvailabilityGroup = $null
					ReplicaName	      = $null
					SeedingMode	      = $null
					Status		      = "NoGroupsFound"
					Message		      = $msg
				}
				return $results
			}
			
			foreach ($ag in $availabilityGroups)
			{
				Invoke-sqmLogging -Message "Verarbeite Verfuegbarkeitsgruppe: $($ag.Name)" -FunctionName $functionName -Level "INFO"
				
				$replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $ag.Name -EnableException:$EnableException
				if (-not $replicas)
				{
					$msg = "Keine Replikate fuer Gruppe $($ag.Name) gefunden."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{
						SqlInstance	      = $SqlInstance
						AvailabilityGroup = $ag.Name
						ReplicaName	      = $null
						SeedingMode	      = $null
						Status		      = "NoReplicasFound"
						Message		      = $msg
					}
					continue
				}
				
				foreach ($replica in $replicas)
				{
					$replicaName = $replica.Name
					$currentMode = $replica.SeedingMode
					
					if ($currentMode -eq 'Automatic')
					{
						$msg = "Replikat $replicaName hat bereits Automatic Seeding. ueberspringe."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "VERBOSE"
						$results += [PSCustomObject]@{
							SqlInstance	      = $SqlInstance
							AvailabilityGroup = $ag.Name
							ReplicaName	      = $replicaName
							SeedingMode	      = $currentMode
							Status		      = "AlreadyAutomatic"
							Message		      = $msg
						}
						continue
					}
					
					$setParams = @{
						SqlInstance	      = $SqlInstance
						SqlCredential	  = $SqlCredential
						AvailabilityGroup = $ag.Name
						Replica		      = $replicaName
						SeedingMode	      = 'Automatic'
						ErrorAction	      = 'Stop'
					}
					if ($EnableException) { $setParams.EnableException = $true }
					
					$actionMsg = "Setze SeedingMode fuer Replikat $replicaName auf 'Automatic'"
					if ($PSCmdlet.ShouldProcess($replicaName, $actionMsg))
					{
						try
						{
							Invoke-sqmLogging -Message $actionMsg -FunctionName $functionName -Level "INFO"
							Set-DbaAgReplica @setParams
							$successMsg = "Automatic Seeding fuer $replicaName erfolgreich aktiviert."
							Invoke-sqmLogging -Message $successMsg -FunctionName $functionName -Level "INFO"
							$results += [PSCustomObject]@{
								SqlInstance	      = $SqlInstance
								AvailabilityGroup = $ag.Name
								ReplicaName	      = $replicaName
								SeedingMode	      = 'Automatic'
								Status		      = "Success"
								Message		      = $successMsg
							}
						}
						catch
						{
							$errMsg = "Fehler beim Aktivieren fuer $replicaName : $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{
								SqlInstance	      = $SqlInstance
								AvailabilityGroup = $ag.Name
								ReplicaName	      = $replicaName
								SeedingMode	      = $currentMode
								Status		      = "Failed"
								Message		      = $errMsg
							}
						}
					}
					else
					{
						$skipMsg = "WhatIf: aenderung an $replicaName uebersprungen."
						Invoke-sqmLogging -Message $skipMsg -FunctionName $functionName -Level "VERBOSE"
						$results += [PSCustomObject]@{
							SqlInstance	      = $SqlInstance
							AvailabilityGroup = $ag.Name
							ReplicaName	      = $replicaName
							SeedingMode	      = $currentMode
							Status		      = "WhatIfSkipped"
							Message		      = $skipMsg
						}
					}
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{
				SqlInstance	      = $SqlInstance
				AvailabilityGroup = $null
				ReplicaName	      = $null
				SeedingMode	      = $null
				Status		      = "GlobalError"
				Message		      = $errMsg
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Objekte zurueckgegeben." -FunctionName $functionName -Level "INFO"
		return $results
	}
}