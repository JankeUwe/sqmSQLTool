<#
.SYNOPSIS
Checks all AlwaysOn databases for problems and repairs them (Remove -> Cleanup -> Add).

.DESCRIPTION
- Determines all databases in all Availability Groups.
- Checks whether a database is problematic (synchronization status not 'HEALTHY' or 'SYNCHRONIZED').
- Ensures that Automatic Seeding is enabled on all replicas (calls Invoke-sqmSqlAlwaysOnAutoseeding).
- On problems: removes database from AG, deletes it from all secondaries, re-adds it with AutoSeed.
- Each repair is recorded in the event log (via Invoke-sqmLogging and Windows Event Log).
- Automatically creates the event log source "sqmAlwaysOn" if it does not exist.

.PARAMETER SqlInstance
Primary SQL instance (default: computer name).

.PARAMETER SqlCredential
Credentials.

.PARAMETER Force
Also repair databases that are considered healthy (e.g. to force a refresh).

.PARAMETER EnableException
Propagate exceptions immediately.

.PARAMETER WhatIf
Test only.

.EXAMPLE
Automatically repairs all problematic AG databases.
Repair-sqmAlwaysOnDatabases

.EXAMPLE
Forces repair of all AG databases (including healthy ones).
Repair-sqmAlwaysOnDatabases -Force

.NOTES
Requires the Invoke-sqmSqlAlwaysOnAutoseeding function.
#>
function Repair-sqmAlwaysOnDatabases
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoReport  # Skip report generation (for job context)
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		
		# Default SqlInstance
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}
		
		# Pruefung auf dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
		
		# Eventlog-Quelle sicherstellen
		$logSource = "sqmAlwaysOn"
		if (-not [System.Diagnostics.EventLog]::SourceExists($logSource))
		{
			try
			{
				New-EventLog -LogName Application -Source $logSource -ErrorAction Stop
				Write-Verbose "Eventlog-Quelle '$logSource' wurde erstellt."
			}
			catch
			{
				Write-Warning "Eventlog-Quelle '$logSource' konnte nicht erstellt werden: $($_.Exception.Message)"
			}
		}
		
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Force=$Force)" -FunctionName $functionName -Level "INFO"
		$results = @()
	}
	
	process
	{
		try
		{
			# --- 1. Automatic Seeding auf allen Replikaten sicherstellen ---
			Invoke-sqmLogging -Message "Pruefe/aktiviere Automatic Seeding auf allen AlwaysOn-Replikaten." -FunctionName $functionName -Level "INFO"
			$seedingParams = @{
				SqlInstance	    = $SqlInstance
				SqlCredential   = $SqlCredential
				All			    = $true
				EnableException = $EnableException
			}
			# Rufe vorhandene Funktion auf (sie setzt Seeding auf Automatic fuer alle AGs)
			$seedingResults = Invoke-sqmSqlAlwaysOnAutoseeding @seedingParams
			# Protokolliere Ergebnisse (optional)
			$seedingResults | ForEach-Object {
				Invoke-sqmLogging -Message "Automatic Seeding fuer Replikat $($_.ReplicaName): $($_.Status)" -FunctionName $functionName -Level "DEBUG"
			}
			
			# --- 2. Alle AGs und deren Datenbanken abrufen ---
			$allAGs = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
			if (-not $allAGs)
			{
				Invoke-sqmLogging -Message "Keine Verfuegbarkeitsgruppen gefunden." -FunctionName $functionName -Level "WARNING"
				return
			}
			
			$problematicDatabases = @()
			foreach ($ag in $allAGs)
			{
				$agDbs = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $ag.Name
				foreach ($agDb in $agDbs)
				{
					$dbName = $agDb.Name
					$syncState = $agDb.SynchronizationState
					$isHealthy = ($syncState -eq 'HEALTHY' -or $syncState -eq 'SYNCHRONIZED')
					if (-not $isHealthy -or $Force)
					{
						$problematicDatabases += [PSCustomObject]@{
							AvailabilityGroup = $ag.Name
							DatabaseName	  = $dbName
							CurrentState	  = $syncState
							ForceRepair	      = $Force
						}
						Invoke-sqmLogging -Message "Datenbank '$dbName' in AG '$($ag.Name)' ist problematisch (Status: $syncState). Reparatur wird durchgefuehrt." -FunctionName $functionName -Level "WARNING"
					}
				}
			}
			
			if ($problematicDatabases.Count -eq 0)
			{
				Invoke-sqmLogging -Message "Keine problematischen Datenbanken gefunden." -FunctionName $functionName -Level "INFO"
				return $results
			}
			
			# --- 3. Reparatur fuer jede problematische DB ---
			foreach ($prob in $problematicDatabases)
			{
				$dbName = $prob.DatabaseName
				$agName = $prob.AvailabilityGroup
				$repairAction = "Reparatur der Datenbank '$dbName' in AG '$agName'"
				if ($PSCmdlet.ShouldProcess($dbName, $repairAction))
				{
					try
					{
						Invoke-sqmLogging -Message "Starte Reparatur fuer '$dbName'." -FunctionName $functionName -Level "INFO"
						Write-EventLog -LogName Application -Source "sqmAlwaysOn" -EventId 1000 -EntryType Information -Message "Starte Reparatur von '$dbName' in AG '$agName'" -ErrorAction SilentlyContinue
						
						# 3.1 Aus AG entfernen
						Invoke-sqmLogging -Message "Entferne '$dbName' aus AG '$agName'." -FunctionName $functionName -Level "INFO"
						Remove-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName -Database $dbName -Confirm:$false -ErrorAction Stop
						
						# 3.2 Auf allen Secondaries loeschen
						$replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName
						$secondaries = $replicas | Where-Object { $_.Role -eq 'Secondary' } | Select-Object -ExpandProperty Name
						foreach ($secondary in $secondaries)
						{
							$secDb = Get-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -ErrorAction SilentlyContinue
							if ($secDb)
							{
								Invoke-sqmLogging -Message "Loesche '$dbName' auf Secondary '$secondary'." -FunctionName $functionName -Level "INFO"
								Remove-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -Confirm:$false -ErrorAction Stop
							}
						}
						
						# 3.3 Wiederherstellung des Recovery-Modus (falls noetig)
						$primaryDb = Get-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName
						if ($primaryDb.RecoveryModel -ne 'Full')
						{
							Invoke-sqmLogging -Message "Setze Recovery-Modus fuer '$dbName' auf Full." -FunctionName $functionName -Level "INFO"
							Set-DbaDbRecoveryModel -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName -RecoveryModel Full -ErrorAction Stop
						}
						
						# 3.4 Wieder hinzufuegen (AutoSeed)
						Invoke-sqmLogging -Message "Fuege '$dbName' wieder zur AG '$agName' hinzu (AutoSeed)." -FunctionName $functionName -Level "INFO"
						Add-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName -Database $dbName -SeedingMode Automatic -ErrorAction Stop
						
						$successMsg = "Reparatur von '$dbName' erfolgreich abgeschlossen."
						Invoke-sqmLogging -Message $successMsg -FunctionName $functionName -Level "INFO"
						Write-EventLog -LogName Application -Source "sqmAlwaysOn" -EventId 1001 -EntryType Information -Message $successMsg -ErrorAction SilentlyContinue
						
						$results += [PSCustomObject]@{
							SqlInstance	      = $SqlInstance
							DatabaseName	  = $dbName
							AvailabilityGroup = $agName
							Status		      = "RepairSuccess"
							Message		      = $successMsg
						}
					}
					catch
					{
						$errMsg = "Reparatur fehlgeschlagen: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						Write-EventLog -LogName Application -Source "sqmAlwaysOn" -EventId 1002 -EntryType Error -Message $errMsg -ErrorAction SilentlyContinue
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{
							SqlInstance	      = $SqlInstance
							DatabaseName	  = $dbName
							AvailabilityGroup = $agName
							Status		      = "RepairFailed"
							Message		      = $errMsg
						}
					}
				}
				else
				{
					$results += [PSCustomObject]@{
						SqlInstance	      = $SqlInstance
						DatabaseName	  = $dbName
						AvailabilityGroup = $agName
						Status		      = "RepairSkipped"
						Message		      = "WhatIf: Reparatur uebersprungen."
					}
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			Write-EventLog -LogName Application -Source "sqmAlwaysOn" -EventId 1003 -EntryType Error -Message $errMsg -ErrorAction SilentlyContinue
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{
				SqlInstance	      = $SqlInstance
				DatabaseName	  = $null
				AvailabilityGroup = $null
				Status		      = "GlobalError"
				Message		      = $errMsg
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
		return $results
	}
}