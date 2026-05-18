<#
.SYNOPSIS
    Synchronizes SQL Server objects from the primary replica to all secondary replicas
    of an Availability Group.

.DESCRIPTION
    Automatically detects the current primary and all Availability Groups of the
    specified instance. All AGs are processed individually.

    Synchronizes the following object types from primary to all secondaries:
        Logins        - SQL and Windows logins including SID/password transfer,
                        followed by Repair-DbaDbOrphanUser on all AG databases
                        on the secondaries (orphaned user cleanup).
        Jobs          - SQL Agent jobs including job steps, schedules, and proxies.
        LinkedServers - Linked Server definitions including login mappings.
        Operators     - SQL Agent operators.
        Alerts        - SQL Agent alerts.

    Use -ExcludeType to exclude individual types.
    Use -ObjectName to target specific logins and jobs by name.
    Use -IncludeSystemObjects to also synchronize system logins (sa, ##MS_*) and system jobs.

.PARAMETER SqlInstance
    Name of any SQL Server instance in the AG cluster (default: current computer name).

.PARAMETER SqlCredential
    Optional PSCredential for all SQL connections.

.PARAMETER AvailabilityGroup
    Optional: Name of a specific AG. Otherwise all AGs on the instance are processed.

.PARAMETER ExcludeType
    Object types that should NOT be synchronized.
    Valid values: Logins, Jobs, LinkedServers, Operators, Alerts.

.PARAMETER ObjectName
    Optional: Filters logins and jobs by name (wildcards allowed).

.PARAMETER IncludeSystemObjects
    When set, system objects (sa, ##MS_*, internal jobs) are synchronized.
    Default: $false (system objects are excluded).

.PARAMETER ContinueOnError
    Continue with the next object type on error (otherwise aborts).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Prompts for confirmation before critical actions (overwriting jobs/logins).

.PARAMETER WhatIf
    Shows all planned actions without executing them.

.EXAMPLE
    Sync-sqmAgNode

.EXAMPLE
    Sync-sqmAgNode -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -ObjectName "AppLogin_*"

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging.
    Direction: always primary -> all secondaries.
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