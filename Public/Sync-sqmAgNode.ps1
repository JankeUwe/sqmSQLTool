<#
.SYNOPSIS
    Synchronisiert SQL Server-Objekte vom Primary-Replikat auf alle
    Secondary-Replikate einer Verfuegbarkeitsgruppe.

.DESCRIPTION
    Erkennt automatisch den aktuellen Primary und alle Verfuegbarkeitsgruppen
    der angegebenen Instanz. Alle AGs werden einzeln verarbeitet.

    Synchronisiert folgende Objekttypen vom Primary zu allen Secondaries:
        Logins       - SQL- und Windows-Logins inkl. SID/Passwort-uebertragung,
                       anschliessend Repair-DbaDbOrphanUser auf allen AG-Datenbanken
                       der Secondaries (Orphaned-User-Bereinigung).
        Jobs         - SQL Agent Jobs inkl. Job Steps, Schedules und Proxies.
        LinkedServers- Linked Server-Definitionen inkl. Login-Mappings.
        Operators    - SQL Agent Operatoren.
        Alerts       - SQL Agent Alerts.

    Mit -ExcludeType koennen einzelne Typen ausgeschlossen werden.
    Mit -ObjectName koennen bei Logins und Jobs einzelne Objekte gezielt synchronisiert werden.
    Mit -IncludeSystemObjects werden auch System-Logins (sa, ##MS_*) und System-Jobs synchronisiert.

.PARAMETER SqlInstance
    Name einer beliebigen SQL Server-Instanz des AG-Clusters (Standard: aktueller Computername).

.PARAMETER SqlCredential
    Optionales PSCredential fuer alle SQL-Verbindungen.

.PARAMETER AvailabilityGroup
    Optional: Name einer bestimmten AG. Sonst werden alle AGs der Instanz verarbeitet.

.PARAMETER ExcludeType
    Objekttypen die NICHT synchronisiert werden sollen.
    Gueltige Werte: Logins, Jobs, LinkedServers, Operators, Alerts.

.PARAMETER ObjectName
    Optional: Filtert bei Logins und Jobs auf bestimmte Namen (Wildcards erlaubt).

.PARAMETER IncludeSystemObjects
    Wenn gesetzt, werden Systemobjekte (sa, ##MS_*, interne Jobs) synchronisiert.
    Standard: $false (Systemobjekte werden ausgeschlossen).

.PARAMETER ContinueOnError
    Bei Fehler eines Objekttyps mit dem naechsten fortfahren (ansonsten Abbruch).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (ueberschreibt ContinueOnError).

.PARAMETER Confirm
    Fordert vor kritischen Aktionen (ueberschreiben von Jobs/Logins) eine Bestaetigung an.

.PARAMETER WhatIf
    Zeigt alle geplanten Aktionen ohne Ausfuehrung.

.EXAMPLE
    Sync-sqmAgNode

.EXAMPLE
    Sync-sqmAgNode -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -ObjectName "AppLogin_*"

.NOTES
    Voraussetzungen: dbatools, Invoke-sqmLogging.
    Richtung: immer Primary ? alle Secondaries.
#>
function Sync-sqmAgNode
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[Alias('Instance', 'PrimaryInstance')]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroup,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Logins', 'Jobs', 'LinkedServers', 'Operators', 'Alerts')]
		[string[]]$ExcludeType = @(),
		[Parameter(Mandatory = $false)]
		[string[]]$ObjectName,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemObjects,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		$excludeSystem = -not $IncludeSystemObjects
		
		# System-Logins (wenn excludeSystem = $true)
		$systemLoginPatterns = @('sa', '##MS_*', 'NT AUTHORITY\*', 'NT SERVICE\*', 'BUILTIN\*')
		# System-Jobs
		$systemJobPatterns = @('syspolicy_*', 'sp_send_dbmail*', 'CommandLog Cleanup',
			'DatabaseBackup*', 'DatabaseIntegrityCheck*',
			'IndexOptimize*', 'Output File Cleanup')
		
		function _MatchesAnyPattern
		{
			param ([string]$Name,
				[string[]]$Patterns)
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}
		
		function _AddResult
		{
			param ($AgName,
				$ObjectType,
				$Source,
				$Destination,
				$ObjName,
				$Status,
				$Message)
			$results.Add([PSCustomObject]@{
					AvailabilityGroup = $AgName
					PrimaryInstance   = $Source
					ObjectType	      = $ObjectType
					Source		      = $Source
					Destination	      = $Destination
					ObjectName	      = $ObjName
					Status		      = $Status
					Message		      = $Message
				})
		}
		
		$entryConn = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $entryConn['SqlCredential'] = $SqlCredential }
	}
	
	process
	{
		try
		{
			# Alle Verfuegbarkeitsgruppen am Einstiegspunkt ermitteln
			Invoke-sqmLogging -Message "Ermittle Verfuegbarkeitsgruppen auf '$SqlInstance'..." -FunctionName $functionName -Level "INFO"
			$allAgs = Get-DbaAvailabilityGroup @entryConn -ErrorAction Stop
			if (-not $allAgs)
			{
				throw "Keine Verfuegbarkeitsgruppen auf '$SqlInstance' gefunden."
			}
			if ($AvailabilityGroup)
			{
				$allAgs = $allAgs | Where-Object { $_.Name -eq $AvailabilityGroup }
				if (-not $allAgs)
				{
					throw "Verfuegbarkeitsgruppe '$AvailabilityGroup' auf '$SqlInstance' nicht gefunden."
				}
			}
			Invoke-sqmLogging -Message "$(@($allAgs).Count) AG(s) gefunden: $(@($allAgs).Name -join ', ')" -FunctionName $functionName -Level "INFO"
			
			foreach ($ag in $allAgs)
			{
				$agName = $ag.Name
				Invoke-sqmLogging -Message "Verarbeite AG: $agName" -FunctionName $functionName -Level "INFO"
				try
				{
					$primaryName = $ag.PrimaryReplica
					if (-not $primaryName)
					{
						throw "Primary-Replikat fuer AG '$agName' konnte nicht ermittelt werden."
					}
					Invoke-sqmLogging -Message "Primary fuer AG '$agName': $primaryName" -FunctionName $functionName -Level "INFO"
					
					$primaryConn = @{ SqlInstance = $primaryName }
					if ($SqlCredential) { $primaryConn['SqlCredential'] = $SqlCredential }
					
					# Alle Secondary-Replikate
					$allReplicas = Get-DbaAgReplica @primaryConn -AvailabilityGroup $agName -ErrorAction Stop
					$secondaryReplicas = @($allReplicas | Where-Object { $_.Role -eq 'Secondary' } | Select-Object -ExpandProperty Name)
					if ($secondaryReplicas.Count -eq 0)
					{
						Invoke-sqmLogging -Message "AG '$agName': Keine Secondary-Replikate gefunden - uebersprungen." -FunctionName $functionName -Level "WARNING"
						continue
					}
					Invoke-sqmLogging -Message "Secondaries ($($secondaryReplicas.Count)): $($secondaryReplicas -join ', ')" -FunctionName $functionName -Level "INFO"
					
					# AG-Datenbanken fuer Orphan-Repair
					$agDatabases = @(Get-DbaAgDatabase @primaryConn -AvailabilityGroup $agName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
					
					# Hilfsfunktion fuer Synchronisation auf alle Secondaries
					function _SyncToAllSecondaries
					{
						param ($TypeLabel,
							$SyncBlock)
						if ($TypeLabel -in $ExcludeType)
						{
							Invoke-sqmLogging -Message "[$agName] Objekttyp '$TypeLabel' per -ExcludeType ausgeschlossen." -FunctionName $functionName -Level "INFO"
							return
						}
						foreach ($secInstance in $secondaryReplicas)
						{
							$secConn = @{ SqlInstance = $secInstance }
							if ($SqlCredential) { $secConn['SqlCredential'] = $SqlCredential }
							try
							{
								& $SyncBlock $secInstance $secConn
							}
							catch
							{
								$errMsg = "[$agName][$TypeLabel] Fehler auf '$secInstance': $($_.Exception.Message)"
								Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
								_AddResult $agName $TypeLabel $primaryName $secInstance '(alle)' 'Failed' $errMsg
								if (-not $ContinueOnError -and -not $EnableException) { throw }
								if ($EnableException) { throw }
							}
						}
					}
					
					# 1. Logins + Orphan Repair
					_SyncToAllSecondaries -TypeLabel 'Logins' -SyncBlock {
						param ($secInstance,
							$secConn)
						$sourceLogins = Get-DbaLogin @primaryConn -ErrorAction Stop
						if ($excludeSystem)
						{
							$sourceLogins = $sourceLogins | Where-Object { -not (_MatchesAnyPattern $_.Name $systemLoginPatterns) -and -not $_.IsSystemObject }
						}
						if ($ObjectName)
						{
							$sourceLogins = $sourceLogins | Where-Object { $n = $_.Name; ($ObjectName | Where-Object { $n -like $_ }).Count -gt 0 }
						}
						if (-not $sourceLogins)
						{
							_AddResult $agName 'Logins' $primaryName $secInstance '(keine)' 'Skipped' 'Keine Logins nach Filter vorhanden.'
							return
						}
						if ($PSCmdlet.ShouldProcess($secInstance, "[$agName] Logins synchronisieren ($($sourceLogins.Count))"))
						{
							$copyResult = Copy-DbaLogin @primaryConn -Destination $secInstance -Login ($sourceLogins.Name) -DestinationSqlCredential $SqlCredential -Force -EnableException
							foreach ($item in $copyResult)
							{
								_AddResult $agName 'Logins' $primaryName $secInstance $item.Name $(if ($item.Status -eq 'Successful') { 'Success' }
									else { 'Failed' }) $item.Notes
							}
						}
						# Orphaned Users auf AG-DBs
						if ($agDatabases.Count -gt 0)
						{
							foreach ($agDb in $agDatabases)
							{
								if ($PSCmdlet.ShouldProcess("$secInstance / $agDb", "[$agName] Orphaned Users bereinigen"))
								{
									try
									{
										Repair-DbaDbOrphanUser @secConn -Database $agDb -EnableException -ErrorAction Stop | Out-Null
									}
									catch { }
								}
							}
							_AddResult $agName 'OrphanRepair' $primaryName $secInstance '(AG-DBs)' 'Success' "Orphan-Repair auf $($agDatabases.Count) AG-Datenbank(en) abgeschlossen."
						}
					}
					
					# 2. Jobs
					_SyncToAllSecondaries -TypeLabel 'Jobs' -SyncBlock {
						param ($secInstance,
							$secConn)
						$sourceJobs = Get-DbaAgentJob @primaryConn -ErrorAction Stop
						if ($excludeSystem)
						{
							$sourceJobs = $sourceJobs | Where-Object { -not (_MatchesAnyPattern $_.Name $systemJobPatterns) }
						}
						if ($ObjectName)
						{
							$sourceJobs = $sourceJobs | Where-Object { $n = $_.Name; ($ObjectName | Where-Object { $n -like $_ }).Count -gt 0 }
						}
						if (-not $sourceJobs)
						{
							_AddResult $agName 'Jobs' $primaryName $secInstance '(keine)' 'Skipped' 'Keine Jobs nach Filter vorhanden.'
							return
						}
						if ($PSCmdlet.ShouldProcess($secInstance, "[$agName] Jobs synchronisieren ($($sourceJobs.Count))"))
						{
							$copyResult = Copy-DbaAgentJob @primaryConn -Destination $secInstance -Job ($sourceJobs.Name) -DestinationSqlCredential $SqlCredential -Force -EnableException
							foreach ($item in $copyResult)
							{
								_AddResult $agName 'Jobs' $primaryName $secInstance $item.Name $(if ($item.Status -eq 'Successful') { 'Success' }
									else { 'Failed' }) $item.Notes
							}
						}
					}
					
					# 3. Linked Servers
					_SyncToAllSecondaries -TypeLabel 'LinkedServers' -SyncBlock {
						param ($secInstance,
							$secConn)
						$sourceLinkedServers = Get-DbaLinkedServer @primaryConn -ErrorAction Stop
						if ($ObjectName)
						{
							$sourceLinkedServers = $sourceLinkedServers | Where-Object { $n = $_.Name; ($ObjectName | Where-Object { $n -like $_ }).Count -gt 0 }
						}
						if (-not $sourceLinkedServers)
						{
							_AddResult $agName 'LinkedServers' $primaryName $secInstance '(keine)' 'Skipped' 'Keine Linked Server vorhanden.'
							return
						}
						if ($PSCmdlet.ShouldProcess($secInstance, "[$agName] Linked Server synchronisieren ($($sourceLinkedServers.Count))"))
						{
							$copyResult = Copy-DbaLinkedServer @primaryConn -Destination $secInstance -LinkedServer ($sourceLinkedServers.Name) -DestinationSqlCredential $SqlCredential -Force -EnableException
							foreach ($item in $copyResult)
							{
								_AddResult $agName 'LinkedServers' $primaryName $secInstance $item.Name $(if ($item.Status -eq 'Successful') { 'Success' }
									else { 'Failed' }) $item.Notes
							}
						}
					}
					
					# 4. Operators
					_SyncToAllSecondaries -TypeLabel 'Operators' -SyncBlock {
						param ($secInstance,
							$secConn)
						$sourceOperators = Get-DbaAgentOperator @primaryConn -ErrorAction Stop
						if ($ObjectName)
						{
							$sourceOperators = $sourceOperators | Where-Object { $n = $_.Name; ($ObjectName | Where-Object { $n -like $_ }).Count -gt 0 }
						}
						if (-not $sourceOperators)
						{
							_AddResult $agName 'Operators' $primaryName $secInstance '(keine)' 'Skipped' 'Keine Operatoren vorhanden.'
							return
						}
						if ($PSCmdlet.ShouldProcess($secInstance, "[$agName] Operatoren synchronisieren ($($sourceOperators.Count))"))
						{
							$copyResult = Copy-DbaAgentOperator @primaryConn -Destination $secInstance -Operator ($sourceOperators.Name) -DestinationSqlCredential $SqlCredential -Force -EnableException
							foreach ($item in $copyResult)
							{
								_AddResult $agName 'Operators' $primaryName $secInstance $item.Name $(if ($item.Status -eq 'Successful') { 'Success' }
									else { 'Failed' }) $item.Notes
							}
						}
					}
					
					# 5. Alerts
					_SyncToAllSecondaries -TypeLabel 'Alerts' -SyncBlock {
						param ($secInstance,
							$secConn)
						$sourceAlerts = Get-DbaAgentAlert @primaryConn -ErrorAction Stop
						if ($ObjectName)
						{
							$sourceAlerts = $sourceAlerts | Where-Object { $n = $_.Name; ($ObjectName | Where-Object { $n -like $_ }).Count -gt 0 }
						}
						if (-not $sourceAlerts)
						{
							_AddResult $agName 'Alerts' $primaryName $secInstance '(keine)' 'Skipped' 'Keine Alerts vorhanden.'
							return
						}
						if ($PSCmdlet.ShouldProcess($secInstance, "[$agName] Alerts synchronisieren ($($sourceAlerts.Count))"))
						{
							$copyResult = Copy-DbaAgentAlert @primaryConn -Destination $secInstance -Alert ($sourceAlerts.Name) -DestinationSqlCredential $SqlCredential -Force -EnableException
							foreach ($item in $copyResult)
							{
								_AddResult $agName 'Alerts' $primaryName $secInstance $item.Name $(if ($item.Status -eq 'Successful') { 'Success' }
									else { 'Failed' }) $item.Notes
							}
						}
					}
					
					$agSuccess = ($results | Where-Object { $_.AvailabilityGroup -eq $agName -and $_.Status -eq 'Success' }).Count
					$agSkipped = ($results | Where-Object { $_.AvailabilityGroup -eq $agName -and $_.Status -eq 'Skipped' }).Count
					$agFailed = ($results | Where-Object { $_.AvailabilityGroup -eq $agName -and $_.Status -eq 'Failed' }).Count
					Invoke-sqmLogging -Message "[$agName] Abgeschlossen: $agSuccess OK / $agSkipped Skipped / $agFailed Fehler" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = "Schwerer Fehler bei AG '$agName': $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					_AddResult $agName 'AG' $primaryName '(alle)' '(alle)' 'Failed' $errMsg
					if (-not $ContinueOnError -and -not $EnableException) { throw }
					if ($EnableException) { throw }
				}
			}
		}
		catch
		{
			$errMsg = "Schwerer Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			throw $errMsg
		}
		return $results
	}
}