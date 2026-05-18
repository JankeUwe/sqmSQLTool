<#
.SYNOPSIS
Enables Automatic Seeding on all replicas of an Always On Availability Group.

.DESCRIPTION
Configures the seeding mode of all replicas of one or more Availability Groups to
"Automatic". Using the -All switch forces processing of all Availability Groups on
the instance.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

.PARAMETER SqlInstance
The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.

.PARAMETER SqlCredential
Alternative credentials (PSCredential). If not specified, Windows authentication is used.

.PARAMETER AvailabilityGroup
Name of the Availability Group(s). Ignored when -All is set.

.PARAMETER All
When set, all Availability Groups on the instance are processed.

.PARAMETER EnableException
Switch to propagate exceptions immediately (by default errors are logged as warnings).

.EXAMPLE
# Uses the current computer name as default
Invoke-sqmSqlAlwaysOnAutoseeding

.EXAMPLE
# Explicit instance specification
Invoke-sqmSqlAlwaysOnAutoseeding -SqlInstance "SQL01\INSTANCE"

.EXAMPLE
# All groups on the current computer
Invoke-sqmSqlAlwaysOnAutoseeding -All

.NOTES
Requires the dbatools module and an existing Invoke-sqmLogging function.
Default for SqlInstance: $env:COMPUTERNAME (applies to all future versions).
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