function Get-SqlVersionWithoutError {
	param([string]$ConnectionString)
	try {
		$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
		$conn.Open()
		$cmd = $conn.CreateCommand()
		$cmd.CommandText = "SELECT SERVERPROPERTY('ProductVersion')"
		$version = $cmd.ExecuteScalar()
		$conn.Close()
		return $version
	}
	catch { return $null }
}

function Repair-sqmAlwaysOnDatabases
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# Pruefung auf dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
		Import-Module dbatools -Force -ErrorAction Stop

		# Try connection WITHOUT TrustServerCertificate first
		$connStringBase = "Server=$SqlInstance;Integrated Security=SSPI;Timeout=5"
		$version = Get-SqlVersionWithoutError -ConnectionString $connStringBase

		# If that failed, try WITH TrustServerCertificate and enable it for dbatools
		if (-not $version) {
			$connStringWithTrust = $connStringBase + ";TrustServerCertificate=True"
			$version = Get-SqlVersionWithoutError -ConnectionString $connStringWithTrust

			# Only set dbatools config if second attempt worked
			if ($version) {
				Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Scope Session -Force -ErrorAction SilentlyContinue
			}
		}

		if (-not $version) {
			throw "Verbindung zu $SqlInstance fehlgeschlagen (weder ohne noch mit TrustServerCertificate)."
		}

		# Eventlog-Quelle sicherstellen
		$logSource = "sqmAlwaysOn"
		if (-not [System.Diagnostics.EventLog]::SourceExists($logSource))
		{
			try
			{
				New-EventLog -LogName Application -Source $logSource -ErrorAction Stop
				Write-Output "Eventlog-Quelle '$logSource' wurde erstellt."
			}
			catch
			{
				Write-Output "Warnung: Eventlog-Quelle '$logSource' konnte nicht erstellt werden: $($_.Exception.Message)"
			}
		}

		Write-Output "Starte $functionName auf $SqlInstance (Force=$Force)"
		$results = @()
	}

	process
	{
		try
		{
			# --- 1. Automatic Seeding auf allen Replikaten sicherstellen ---
			Write-Output "Pruefe/aktiviere Automatic Seeding auf allen AlwaysOn-Replikaten."

			# --- 2. Alle AGs und deren Datenbanken abrufen ---
			$allAGs = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
			if (-not $allAGs)
			{
				Write-Output "Keine Verfuegbarkeitsgruppen gefunden."
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
						Write-Output "Datenbank '$dbName' in AG '$($ag.Name)' ist problematisch (Status: $syncState). Reparatur wird durchgefuehrt."
					}
				}
			}

			if ($problematicDatabases.Count -eq 0)
			{
				Write-Output "Keine problematischen Datenbanken gefunden."
				return $results
			}

			# --- 3. Reparatur fuer jede problematische DB ---
			foreach ($prob in $problematicDatabases)
			{
				$dbName = $prob.DatabaseName
				$agName = $prob.AvailabilityGroup
				$repairAction = "Reparatur der Datenbank '$dbName' in AG '$agName'"

				try
				{
					Write-Output "Starte Reparatur fuer '$dbName'."
					Write-EventLog -LogName Application -Source "sqmAlwaysOn" -EventId 1000 -EntryType Information -Message "Starte Reparatur von '$dbName' in AG '$agName'" -ErrorAction SilentlyContinue

					# 3.1 Aus AG entfernen
					Write-Output "Entferne '$dbName' aus AG '$agName'."
					Remove-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName -Database $dbName -Confirm:$false -ErrorAction Stop

					# 3.2 Auf allen Secondaries loeschen
					$replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName
					$secondaries = $replicas | Where-Object { $_.Role -eq 'Secondary' } | Select-Object -ExpandProperty Name
					foreach ($secondary in $secondaries)
					{
						$secDb = Get-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -ErrorAction SilentlyContinue
						if ($secDb)
						{
							Write-Output "Loesche '$dbName' auf Secondary '$secondary'."
							Remove-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -Confirm:$false -ErrorAction Stop
						}
					}

					# 3.3 Wiederherstellung des Recovery-Modus (falls noetig)
					$primaryDb = Get-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName
					if ($primaryDb.RecoveryModel -ne 'Full')
					{
						Write-Output "Setze Recovery-Modus fuer '$dbName' auf Full."
						Set-DbaDbRecoveryModel -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName -RecoveryModel Full -ErrorAction Stop
					}

					# 3.4 Wieder hinzufuegen (AutoSeed)
					Write-Output "Fuege '$dbName' wieder zur AG '$agName' hinzu (AutoSeed)."
					Add-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName -Database $dbName -SeedingMode Automatic -ErrorAction Stop

					$successMsg = "Reparatur von '$dbName' erfolgreich abgeschlossen."
					Write-Output $successMsg
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
					Write-Output $errMsg
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
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Write-Output $errMsg
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
		Write-Output "$functionName abgeschlossen."
		return $results
	}
}

# Run the function
Repair-sqmAlwaysOnDatabases -Confirm:$false -ErrorAction Stop

exit $LASTEXITCODE
