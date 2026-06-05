<#
.SYNOPSIS
Adds one or more databases to an Always On availability group (AutoSeed).

.DESCRIPTION
- Checks whether the database is already in an AG.
- Sets recovery mode to Full (if necessary).
- Drops existing databases on all secondary replicas.
- Adds the database to the AG using Automatic Seeding.
- With -All, databases are added sequentially to avoid load spikes.

.PARAMETER SqlInstance
Primary SQL instance (default: computer name).

.PARAMETER SqlCredential
Credentials.

.PARAMETER AvailabilityGroup
Name of the target availability group (mandatory).

.PARAMETER Database
Name or array of databases. Ignored when -All is set.

.PARAMETER All
Add all user databases that are not yet in an AG.

.PARAMETER EnableException
Allow exceptions to pass through.

.PARAMETER Confirm
Request confirmation.

.PARAMETER WhatIf
Test only (no changes).

.EXAMPLE
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -Database "SalesDB"

.EXAMPLE
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -All

.NOTES
Requires Automatic Seeding on all replicas (can be enabled separately with Invoke-sqmSqlAlwaysOnAutoseeding).
#>
function Add-sqmDatabaseToAG
	
{
	[CmdletBinding(DefaultParameterSetName = 'Specific', SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroup,
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
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance, AG: $AvailabilityGroup" -FunctionName $functionName -Level "INFO"
		$results = @()
	}
	
	process
	{
		try
		{
			# Verfuegbarkeitsgruppe validieren und sekundaere Replikate ermitteln
			$ag = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $AvailabilityGroup -ErrorAction Stop
			if (-not $ag) { throw "AG '$AvailabilityGroup' nicht gefunden." }
			$replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $AvailabilityGroup
			$secondaryInstances = $replicas | Where-Object { $_.Role -eq 'Secondary' } | Select-Object -ExpandProperty Name
			
			# Datenbanken ermitteln
			$dbParams = @{ SqlInstance = $SqlInstance; SqlCredential = $SqlCredential; ExcludeSystem = $true; ErrorAction = 'Stop' }
			if ($EnableException) { $dbParams.EnableException = $true }
			
			if ($All)
			{
				$allDbs = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
				$databases = @()
				foreach ($db in $allDbs)
				{
					$inAG = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $db.Name -ErrorAction SilentlyContinue
					if (-not $inAG) { $databases += $db }
				}
				Invoke-sqmLogging -Message "$($databases.Count) Datenbanken wurden fuer Hinzufuegung ausgewaehlt." -FunctionName $functionName -Level "INFO"
			}
			elseif ($Database)
			{
				$dbParams.Database = $Database
				$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
				$missing = $Database | Where-Object { $_ -notin ($databases.Name) }
				if ($missing)
				{
					$msg = "Nicht gefunden: $($missing -join ', ')"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $missing -join ','; Status = "NotFound"; Message = $msg }
				}
			}
			else { throw "Weder -All noch -Database angegeben." }
			
			if (-not $databases)
			{
				Invoke-sqmLogging -Message "Keine Datenbanken zum Hinzufuegen." -FunctionName $functionName -Level "WARNING"
				return
			}
			
			# Sequentiell verarbeiten (bei -All wichtig fuer Last)
			$counter = 0
			foreach ($db in $databases)
			{
				$counter++
				$dbName = $db.Name
				Invoke-sqmLogging -Message "Verarbeite Datenbank $counter von $($databases.Count): $dbName" -FunctionName $functionName -Level "INFO"
				
				# Pruefung ob bereits in AG (sicherheitshalber)
				$existingAg = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName -ErrorAction SilentlyContinue
				if ($existingAg)
				{
					$msg = "Datenbank '$dbName' ist bereits in AG '$($existingAg.AvailabilityGroupName)'. ueberspringe."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "AlreadyInAG"; Message = $msg }
					continue
				}
				
				# Recovery-Modus auf Full setzen
				if ($db.RecoveryModel -ne 'Full')
				{
					$setRecoveryAction = "Setze Recovery-Modus fuer '$dbName' auf Full"
					if ($PSCmdlet.ShouldProcess($dbName, $setRecoveryAction))
					{
						try
						{
							Invoke-sqmLogging -Message $setRecoveryAction -FunctionName $functionName -Level "INFO"
							Set-DbaDbRecoveryModel -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName -RecoveryModel Full -ErrorAction Stop
						}
						catch
						{
							$errMsg = "Fehler beim Setzen des Recovery-Modus: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "SetRecoveryFailed"; Message = $errMsg }
							continue
						}
					}
					else
					{
						$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "RecoverySkipped"; Message = "WhatIf: Recovery-Modus nicht geaendert." }
						continue
					}
				}
				
				# Vorhandene Datenbank auf Secondaries loeschen
				foreach ($secondary in $secondaryInstances)
				{
					$secDb = Get-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -ErrorAction SilentlyContinue
					if ($secDb)
					{
						$dropAction = "Loesche vorhandene Datenbank '$dbName' auf Secondary '$secondary'"
						if ($PSCmdlet.ShouldProcess($dbName, $dropAction))
						{
							try
							{
								Invoke-sqmLogging -Message $dropAction -FunctionName $functionName -Level "INFO"
								Remove-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -Confirm:$false -ErrorAction Stop
							}
							catch
							{
								$errMsg = "Fehler beim Loeschen auf '$secondary': $($_.Exception.Message)"
								Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
								if ($EnableException) { throw }
								$results += [PSCustomObject]@{ SqlInstance = $secondary; DatabaseName = $dbName; Status = "DropOnSecondaryFailed"; Message = $errMsg }
								# Nicht abbrechen, versuchen trotzdem hinzuzufuegen?
							}
						}
						else
						{
							$results += [PSCustomObject]@{ SqlInstance = $secondary; DatabaseName = $dbName; Status = "DropSkipped"; Message = "WhatIf: Loeschen uebersprungen." }
						}
					}
				}
				
				# Zur AG hinzufuegen (mit Automatic Seeding)
				$addAction = "Fuege Datenbank '$dbName' zur AG '$AvailabilityGroup' hinzu (AutoSeed)"
				if ($PSCmdlet.ShouldProcess($dbName, $addAction))
				{
					try
					{
						Invoke-sqmLogging -Message $addAction -FunctionName $functionName -Level "INFO"
						Add-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $AvailabilityGroup -Database $dbName -SeedingMode Automatic -ErrorAction Stop
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Status	     = "Success"
							Message	     = "Erfolgreich zur AG hinzugefuegt."
						}
					}
					catch
					{
						$errMsg = "Fehler beim Hinzufuegen: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "AddFailed"; Message = $errMsg }
					}
				}
				else
				{
					$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "AddSkipped"; Message = "WhatIf: Hinzufuegen uebersprungen." }
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
