<#
.SYNOPSIS
Removes one or more databases from their Always On Availability Group.

.DESCRIPTION
The function automatically detects which Availability Group the specified database
belongs to, removes it from the group, and then deletes it from all secondary replicas.
System databases are ignored.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default.

.PARAMETER SqlInstance
The primary SQL Server instance (the primary replica of the AG).
Default: current computer name.

.PARAMETER SqlCredential
Alternative credentials.

.PARAMETER Database
Name or array of user databases to remove from their AG.
Ignored when -All is set.

.PARAMETER All
When set, all user databases that are members of an AG are removed.

.PARAMETER EnableException
Switch to propagate exceptions immediately.

.PARAMETER Confirm
Prompts for confirmation before critical actions (remove from AG, delete on secondaries).

.PARAMETER WhatIf
Shows what would happen without making any changes.

.EXAMPLE
# Remove a single database from its AG
Remove-sqmDatabaseFromAG -Database "SalesDB"

.EXAMPLE
# Remove all AG databases
Remove-sqmDatabaseFromAG -All

.NOTES
Requires dbatools and Invoke-sqmLogging.
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
				$secondaryInstances = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential | Where-Object { $_.AvailabilityGroupName -eq $agName -and $_.Role -ne 'Primary' } | Select-Object -ExpandProperty Name
				
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