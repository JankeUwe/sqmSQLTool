<#
.SYNOPSIS
Entfernt eine oder mehrere Datenbanken aus ihrer Always On-Verfuegbarkeitsgruppe.

.DESCRIPTION
Die Funktion erkennt selbststaendig, in welcher Verfuegbarkeitsgruppe sich die angegebene
Datenbank befindet, entfernt sie daraus und loescht sie anschliessend von allen sekundaeren
Replikaten. Systemdatenbanken werden ignoriert.

Wenn kein SqlInstance-Parameter angegeben wird, wird standardmaessig der aktuelle
Computername ($env:COMPUTERNAME) verwendet.

.PARAMETER SqlInstance
Die primaere SQL Server-Instanz (das primaere Replikat der AG).
Standard: aktueller Computername.

.PARAMETER SqlCredential
Alternative Anmeldeinformationen.

.PARAMETER Database
Name oder Array von Benutzerdatenbanken, die aus ihrer AG entfernt werden sollen.
Wird ignoriert, wenn -All gesetzt ist.

.PARAMETER All
Wenn gesetzt, werden alle Benutzerdatenbanken, die Mitglied einer AG sind, entfernt.

.PARAMETER EnableException
Schalter, um Ausnahmen durchzulassen.

.PARAMETER Confirm
Fordert vor kritischen Aktionen (Entfernen aus AG, Loeschen auf Secondaries) eine Bestaetigung an.

.PARAMETER WhatIf
Zeigt, was passieren wuerde, ohne aenderungen durchzufuehren.

.EXAMPLE
# Einzelne Datenbank aus ihrer AG entfernen
Remove-sqmDatabaseFromAvailabilityGroup -Database "SalesDB"

.EXAMPLE
# Alle AG-Datenbanken entfernen
Remove-sqmDatabaseFromAvailabilityGroup -All

.NOTES
Erfordert dbatools und Invoke-sqmLogging.
#>
function Remove-sqmDatabaseFromAG
{
	[CmdletBinding(DefaultParameterSetName = 'Specific', SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false, ParameterSetName = 'Specific')]
		[string[]]$Database,
		[Parameter(Mandatory = $false, ParameterSetName = 'All')]
		[switch]$All,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
		$results = @()
	}
	
	process
	{
		try
		{
			# Alle Verfuegbarkeitsgruppen abrufen
			$agParams = @{ SqlInstance = $SqlInstance; SqlCredential = $SqlCredential; ErrorAction = 'Stop' }
			if ($EnableException) { $agParams.EnableException = $true }
			$allAGs = Get-DbaAvailabilityGroup @agParams
			if (-not $allAGs)
			{
				Write-Warning "Keine Verfuegbarkeitsgruppen auf $SqlInstance gefunden."
				return
			}
			
			# Zu entfernende Datenbanken ermitteln
			$targetDbs = @()
			if ($All)
			{
				Invoke-sqmLogging -Message "Sammle alle Datenbanken, die in einer AG sind." -FunctionName $functionName -Level "INFO"
				foreach ($ag in $allAGs)
				{
					$agDbs = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $ag.Name -ErrorAction SilentlyContinue
					$targetDbs += $agDbs | Select-Object -ExpandProperty Name
				}
				$targetDbs = $targetDbs | Select-Object -Unique
			}
			elseif ($Database)
			{
				$targetDbs = $Database
			}
			else
			{
				throw "Weder -All noch -Database angegeben."
			}
			
			if (-not $targetDbs)
			{
				Invoke-sqmLogging -Message "Keine Datenbanken zum Entfernen gefunden." -FunctionName $functionName -Level "WARNING"
				return
			}
			
			# Fuer jede Datenbank die zugehoerige AG finden und entfernen
			foreach ($dbName in $targetDbs)
			{
				# AG ermitteln, in der die DB Mitglied ist
				$agDb = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName -ErrorAction SilentlyContinue
				if (-not $agDb)
				{
					$msg = "Datenbank '$dbName' ist in keiner Verfuegbarkeitsgruppe (oder nicht vorhanden)."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = $dbName
						Status	     = "NotInAG"
						Message	     = $msg
					}
					continue
				}
				$agName = $agDb.AvailabilityGroupName
				$secondaryInstances = $agDb | Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential | Where-Object { $_.Role -ne 'Primary' } | Select-Object -ExpandProperty Name
				
				# Entfernen aus AG
				$removeAction = "Datenbank '$dbName' aus AG '$agName' entfernen"
				if ($PSCmdlet.ShouldProcess($dbName, $removeAction))
				{
					try
					{
						Invoke-sqmLogging -Message $removeAction -FunctionName $functionName -Level "INFO"
						Remove-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName -Database $dbName -Confirm:$false -ErrorAction Stop
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Status	     = "RemovedFromAG"
							Message	     = "Erfolgreich aus AG '$agName' entfernt."
						}
					}
					catch
					{
						$errMsg = "Fehler beim Entfernen aus AG: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Status	     = "RemoveFromAGFailed"
							Message	     = $errMsg
						}
						continue
					}
				}
				else
				{
					$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "RemoveSkipped"; Message = "WhatIf: Entfernen aus AG uebersprungen." }
					continue
				}
				
				# Loeschen auf sekundaeren Replikaten
				foreach ($secondary in $secondaryInstances)
				{
					$dropAction = "Datenbank '$dbName' auf sekundaerem Knoten '$secondary' loeschen"
					if ($PSCmdlet.ShouldProcess($dbName, $dropAction))
					{
						try
						{
							Invoke-sqmLogging -Message $dropAction -FunctionName $functionName -Level "INFO"
							Remove-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -Confirm:$false -ErrorAction Stop
							$results += [PSCustomObject]@{
								SqlInstance  = $secondary
								DatabaseName = $dbName
								Status	     = "DroppedOnSecondary"
								Message	     = "Datenbank auf '$secondary' geloescht."
							}
						}
						catch
						{
							$errMsg = "Fehler beim Loeschen auf '$secondary': $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{
								SqlInstance  = $secondary
								DatabaseName = $dbName
								Status	     = "DropOnSecondaryFailed"
								Message	     = $errMsg
							}
						}
					}
					else
					{
						$results += [PSCustomObject]@{ SqlInstance = $secondary; DatabaseName = $dbName; Status = "DropSkipped"; Message = "WhatIf: Loeschen auf $secondary uebersprungen." }
					}
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $null; Status = "GlobalError"; Message = $errMsg }
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
		return $results
	}
}