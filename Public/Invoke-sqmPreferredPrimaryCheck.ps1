<#
.SYNOPSIS
    Checks whether a defined replica currently holds the PRIMARY role of an availability group
    and fails the AG back to it when that is safe. Built to run unattended as a SQL Agent job.

.DESCRIPTION
    After a patch weekend the AG usually sits on whichever node happened to be rebooted last.
    Where a specific node has to be the primary (license/hardware/backup or monitoring reasons),
    this function is the watchdog: it compares the current primary against -PreferredReplica and,
    if they differ, performs a controlled failover back - but only when every safety check passes.

    Safety checks (all must pass, otherwise NOTHING happens and the result says why):
        - the preferred replica is a member of the AG and currently SECONDARY
        - it runs in SYNCHRONOUS_COMMIT mode (a manual failover to an async replica would lose
          data - such a replica is never failed over to automatically)
        - all AG databases are joined on it (count matches sys.availability_databases_cluster),
          SYNCHRONIZED, ONLINE and not suspended
        - its redo queue is at or below -MaxRedoQueueMB
        - SQL Server on it has been up for at least -MinTargetUptimeMinutes (a node that just
          came back from a reboot may still be mid-patch and reboot again)
        - the current primary has held its role for at least -MinRoleAgeMinutes (anti-flapping,
          keeps the watchdog out of an ongoing patch/failover sequence)
        - the current time is inside -AllowedDay / -AllowedTimeStart..-AllowedTimeEnd, if given
          (e.g. "never switch back during the patch weekend, only Mon-Fri 06:00-20:00")

    The failover itself is delegated to Invoke-sqmFailover, so the pre-/post-checks and the
    plain "ALTER AVAILABILITY GROUP ... FAILOVER" (manual, never forced) behave identically to a
    failover triggered by hand.

    Nothing is changed when the preferred replica is already primary - the normal case for
    nearly every run.

.PARAMETER SqlInstance
    Any replica of the AG used to read the current state (default: local computer). The function
    resolves the current primary itself, so it does not matter whether this instance is currently
    primary or secondary.

.PARAMETER SqlCredential
    PSCredential for all connections (state instance, current primary, preferred replica).

.PARAMETER AvailabilityGroup
    Name of the availability group to watch.

.PARAMETER PreferredReplica
    Instance name of the replica that should hold the PRIMARY role, as it appears in
    sys.availability_replicas.replica_server_name (e.g. 'SQL01' or 'SQL01\INST2'). A host name
    with a DNS suffix is matched against the catalog name as well.

.PARAMETER MaxRedoQueueMB
    Maximum redo queue on the preferred replica in MB. Above that no failover is performed.
    Default: 50 MB.

.PARAMETER MinRoleAgeMinutes
    Minimum time the current primary must already have held its role before a switch back is
    allowed. Default: 15 minutes. 0 disables the check.
    Read from current_configuration_commit_start_time_utc - an approximation (any configuration
    commit refreshes it), which can only delay a switch back, never trigger a wrong one.

.PARAMETER MinTargetUptimeMinutes
    Minimum uptime of the SQL Server service on the preferred replica. Default: 15 minutes.
    0 disables the check.

.PARAMETER AllowedDay
    Weekdays on which a switch back is allowed (e.g. Monday, Tuesday). Default: all days.

.PARAMETER AllowedTimeStart
    Start of the daily time window in which a switch back is allowed, "HH:mm". Only together
    with -AllowedTimeEnd. A window may cross midnight ('22:00' .. '04:00').

.PARAMETER AllowedTimeEnd
    End of the daily time window, "HH:mm". Only together with -AllowedTimeStart.

.PARAMETER WaitAfterFailoverSeconds
    Wait time before the post-check of the failover. Passed to Invoke-sqmFailover. Default: 30.

.PARAMETER CheckOnly
    Only check and report, never fail over. Use this to watch the watchdog for a few weeks
    before letting it act.

.PARAMETER FailOnBlocked
    Return an error (failed Agent job step) when a failover would be needed but a safety check
    blocked it. Default: this is logged as a WARNING and reported in the result object only, so
    a patch weekend does not turn every run red.

.PARAMETER EnableException
    Throw exceptions immediately instead of writing an error and returning a result object.

.EXAMPLE
    Invoke-sqmPreferredPrimaryCheck -AvailabilityGroup 'AG_Prod' -PreferredReplica 'SQL01' -WhatIf

    Shows whether a switch back would happen right now, without touching anything.

.EXAMPLE
    Invoke-sqmPreferredPrimaryCheck -AvailabilityGroup 'AG_Prod' -PreferredReplica 'SQL01' -CheckOnly

    Full check including all safety gates, reported only - never fails over.

.EXAMPLE
    Invoke-sqmPreferredPrimaryCheck -AvailabilityGroup 'AG_Prod' -PreferredReplica 'SQL01' -AllowedDay Monday,Tuesday,Wednesday,Thursday,Friday -AllowedTimeStart '06:00' -AllowedTimeEnd '20:00'

    Switches back only during the week and only inside working hours - the patch weekend is
    left alone.

.NOTES
    Requires: dbatools, Invoke-sqmFailover, Invoke-sqmLogging (same module).
    Needs VIEW SERVER STATE on all replicas and ALTER AVAILABILITY GROUP on the preferred replica.
    Deploy as a recurring Agent job with New-sqmPreferredPrimaryJob.
    Performs a MANUAL failover only. If the current primary cannot be reached, nothing happens -
    a forced failover (potential data loss) is never automated here.
#>
function Invoke-sqmPreferredPrimaryCheck
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroup,
		[Parameter(Mandatory = $true)]
		[string]$PreferredReplica,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 99999)]
		[int]$MaxRedoQueueMB = 50,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$MinRoleAgeMinutes = 15,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$MinTargetUptimeMinutes = 15,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
		[string[]]$AllowedDay,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
		[string]$AllowedTimeStart,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
		[string]$AllowedTimeEnd,
		[Parameter(Mandatory = $false)]
		[ValidateRange(5, 300)]
		[int]$WaitAfterFailoverSeconds = 30,
		[Parameter(Mandatory = $false)]
		[switch]$CheckOnly,
		[Parameter(Mandatory = $false)]
		[switch]$FailOnBlocked,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Zeitfenster nur als Paar sinnvoll - eine halbe Angabe waere stillschweigend wirkungslos.
		if (($AllowedTimeStart -and -not $AllowedTimeEnd) -or ($AllowedTimeEnd -and -not $AllowedTimeStart))
		{
			$errMsg = "-AllowedTimeStart und -AllowedTimeEnd koennen nur gemeinsam verwendet werden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starte $functionName fuer AG '$AvailabilityGroup' (bevorzugtes Replikat '$PreferredReplica', Status-Instanz '$SqlInstance')." -FunctionName $functionName -Level "INFO"
	}

	process
	{
		$checks = [System.Collections.Generic.List[PSCustomObject]]::new()

		$result = [PSCustomObject]@{
			SqlInstance	      = $SqlInstance
			AvailabilityGroup = $AvailabilityGroup
			PreferredReplica  = $PreferredReplica
			CurrentPrimary    = $null
			NewPrimary	      = $null
			Action		      = 'None'
			Status		      = 'Unknown'
			Reason		      = ''
			Checks		      = $checks
			Timestamp	      = Get-Date
		}

		try
		{
			$agEscaped = $AvailabilityGroup -replace "'", "''"

			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			# ------------------------------------------------------------------
			# 1. Replikatliste aus den Katalogsichten - die sind auf JEDEM Replikat vollstaendig
			#    (im Gegensatz zu den DMV-Spalten, die fuer nicht-lokale Replikate NULL bleiben).
			# ------------------------------------------------------------------
			$replicaSql = @"
SELECT
    ar.replica_server_name        AS ReplicaServer,
    ar.availability_mode_desc     AS AvailabilityMode,
    ar.failover_mode_desc         AS FailoverMode
FROM sys.availability_groups   ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
WHERE ag.name = N'$agEscaped'
"@
			$replicas = @(Invoke-DbaQuery @connParams -Database master -Query $replicaSql -EnableException)

			if ($replicas.Count -eq 0)
			{
				$result.Status = 'Failed'
				$result.Reason = "Verfuegbarkeitsgruppe '$AvailabilityGroup' auf '$SqlInstance' nicht gefunden."
				Invoke-sqmLogging -Message $result.Reason -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Reason }
				Write-Error $result.Reason
				return $result
			}

			# Bevorzugtes Replikat auf den Katalognamen aufloesen. Ein Tippfehler wuerde sonst
			# stillschweigend dazu fuehren, dass NIE zurueckgeschwenkt wird - deshalb harter Fehler.
			$targetReplica = $replicas | Where-Object { $_.ReplicaServer -ieq $PreferredReplica } | Select-Object -First 1
			if (-not $targetReplica)
			{
				# Toleranz fuer FQDN-Schreibweise: Hostanteil ohne DNS-Suffix vergleichen.
				$prefHost = (($PreferredReplica -split '\\')[0] -split '\.')[0]
				$prefInst = if ($PreferredReplica -match '\\') { ($PreferredReplica -split '\\')[1] } else { $null }
				$targetReplica = $replicas | Where-Object {
					$catHost = (($_.ReplicaServer -split '\\')[0] -split '\.')[0]
					$catInst = if ($_.ReplicaServer -match '\\') { ($_.ReplicaServer -split '\\')[1] } else { $null }
					($catHost -ieq $prefHost) -and ($catInst -ieq $prefInst)
				} | Select-Object -First 1
			}

			if (-not $targetReplica)
			{
				$known = ($replicas | ForEach-Object { $_.ReplicaServer }) -join ', '
				$result.Status = 'Failed'
				$result.Reason = "'$PreferredReplica' ist kein Replikat der AG '$AvailabilityGroup'. Vorhanden: $known"
				Invoke-sqmLogging -Message $result.Reason -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Reason }
				Write-Error $result.Reason
				return $result
			}

			$preferredName = [string]$targetReplica.ReplicaServer
			$result.PreferredReplica = $preferredName

			# ------------------------------------------------------------------
			# 2. Aktuelles Primaerreplikat bestimmen. primary_replica ist von jedem Replikat aus
			#    lesbar - anders als role_desc, das fuer entfernte Replikate leer bleiben kann.
			# ------------------------------------------------------------------
			$stateSql = @"
SELECT
    ags.primary_replica                AS PrimaryReplica,
    ags.synchronization_health_desc    AS AgSyncHealth,
    ags.primary_recovery_health_desc   AS PrimaryRecoveryHealth
FROM sys.availability_groups                  ag
JOIN sys.dm_hadr_availability_group_states   ags ON ags.group_id = ag.group_id
WHERE ag.name = N'$agEscaped'
"@
			$agState = Invoke-DbaQuery @connParams -Database master -Query $stateSql -EnableException | Select-Object -First 1

			$currentPrimary = if ($agState) { [string]$agState.PrimaryReplica } else { '' }
			$result.CurrentPrimary = $currentPrimary

			if ([string]::IsNullOrWhiteSpace($currentPrimary))
			{
				$noPrimaryMsg = "Kein Primaerreplikat ermittelbar (AG vermutlich im Zustand RESOLVING)."
				$checks.Add([PSCustomObject]@{ Name = 'PrimaryKnown'; Passed = $false; Detail = $noPrimaryMsg })
				$result.Status = 'Blocked'
				$result.Reason = $noPrimaryMsg
				Invoke-sqmLogging -Message "[$AvailabilityGroup] $noPrimaryMsg" -FunctionName $functionName -Level "WARNING"
				if ($FailOnBlocked)
				{
					if ($EnableException) { throw $result.Reason }
					Write-Error $result.Reason
				}
				return $result
			}

			# ------------------------------------------------------------------
			# 3. Normalfall: schon richtig. Kein Zugriff auf weitere Instanzen noetig.
			# ------------------------------------------------------------------
			if ($currentPrimary -ieq $preferredName)
			{
				$checks.Add([PSCustomObject]@{ Name = 'PreferredIsPrimary'; Passed = $true; Detail = "'$preferredName' ist Primaerreplikat." })
				$result.Status = 'AlreadyPrimary'
				$result.Reason = "'$preferredName' ist bereits Primaerreplikat - keine Aktion noetig."
				Invoke-sqmLogging -Message "[$AvailabilityGroup] $($result.Reason)" -FunctionName $functionName -Level "INFO"
				return $result
			}

			$checks.Add([PSCustomObject]@{ Name = 'PreferredIsPrimary'; Passed = $false; Detail = "Primaerreplikat ist '$currentPrimary', bevorzugt waere '$preferredName'." })
			Invoke-sqmLogging -Message "[$AvailabilityGroup] Primaerreplikat ist '$currentPrimary' statt '$preferredName' - pruefe Schwenkbedingungen." -FunctionName $functionName -Level "INFO"

			# ------------------------------------------------------------------
			# 4. Zeitfenster. Bewusst als erste Bedingung: liegt der Lauf ausserhalb, muessen die
			#    anderen Replikate gar nicht erst angefasst werden.
			# ------------------------------------------------------------------
			$now = Get-Date

			if ($AllowedDay)
			{
				$dayOk = $AllowedDay -contains $now.DayOfWeek.ToString()
				$checks.Add([PSCustomObject]@{
						Name   = 'AllowedDay'
						Passed = $dayOk
						Detail = "Heute ist $($now.DayOfWeek), erlaubt: $($AllowedDay -join ', ')"
					})
			}

			if ($AllowedTimeStart)
			{
				$startMin = ([int]$AllowedTimeStart.Substring(0, 2) * 60) + [int]$AllowedTimeStart.Substring(3, 2)
				$endMin = ([int]$AllowedTimeEnd.Substring(0, 2) * 60) + [int]$AllowedTimeEnd.Substring(3, 2)
				$nowMin = ($now.Hour * 60) + $now.Minute

				# Fenster ueber Mitternacht ('22:00'..'04:00') ist ein ODER statt eines UND.
				$timeOk = if ($startMin -le $endMin) { ($nowMin -ge $startMin) -and ($nowMin -lt $endMin) }
				else { ($nowMin -ge $startMin) -or ($nowMin -lt $endMin) }

				$checks.Add([PSCustomObject]@{
						Name   = 'AllowedTimeWindow'
						Passed = $timeOk
						Detail = "Jetzt $($now.ToString('HH:mm')), erlaubtes Fenster $AllowedTimeStart-$AllowedTimeEnd"
					})
			}

			# ------------------------------------------------------------------
			# 5. Zustand des bevorzugten Replikats - aus SEINER lokalen Sicht (is_local = 1),
			#    weil operational_state/redo_queue fuer entfernte Replikate nicht gefuellt sind.
			# ------------------------------------------------------------------
			$targetConn = @{ SqlInstance = $preferredName }
			if ($SqlCredential) { $targetConn['SqlCredential'] = $SqlCredential }

			$targetStateSql = @"
SELECT
    ars.role_desc                      AS Role,
    ars.operational_state_desc         AS OperState,
    ars.connected_state_desc           AS ConnState,
    ars.synchronization_health_desc    AS SyncHealth,
    ar.availability_mode_desc          AS AvailMode,
    ar.failover_mode_desc              AS FailoverMode,
    si.sqlserver_start_time            AS SqlStartTime
FROM sys.availability_groups                     ag
JOIN sys.availability_replicas                   ar  ON ar.group_id    = ag.group_id
JOIN sys.dm_hadr_availability_replica_states     ars ON ars.replica_id = ar.replica_id
CROSS JOIN sys.dm_os_sys_info                    si
WHERE ag.name = N'$agEscaped'
  AND ars.is_local = 1
"@
			$targetState = Invoke-DbaQuery @targetConn -Database master -Query $targetStateSql -EnableException | Select-Object -First 1

			if (-not $targetState)
			{
				$result.Status = 'Failed'
				$result.Reason = "Zustand von '$preferredName' nicht lesbar - Replikat gehoert dort nicht zur AG '$AvailabilityGroup'."
				Invoke-sqmLogging -Message $result.Reason -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Reason }
				Write-Error $result.Reason
				return $result
			}

			$checks.Add([PSCustomObject]@{
					Name   = 'TargetIsSecondary'
					Passed = ([string]$targetState.Role -eq 'SECONDARY')
					Detail = "Rolle auf '$preferredName': $($targetState.Role)"
				})

			# Ein manueller Failover auf ein asynchrones Replikat ist nur als FORCED moeglich und
			# damit potenziell datenverlustbehaftet - das wird hier nie automatisiert.
			$checks.Add([PSCustomObject]@{
					Name   = 'TargetSynchronousCommit'
					Passed = ([string]$targetState.AvailMode -eq 'SYNCHRONOUS_COMMIT')
					Detail = "Availability Mode: $($targetState.AvailMode)"
				})

			$checks.Add([PSCustomObject]@{
					Name   = 'TargetHealthy'
					Passed = (([string]$targetState.SyncHealth -eq 'HEALTHY') -and
						([string]$targetState.OperState -in @('ONLINE', '')) -and
						([string]$targetState.ConnState -in @('CONNECTED', '')))
					Detail = "SyncHealth=$($targetState.SyncHealth), OperState=$($targetState.OperState), ConnState=$($targetState.ConnState)"
				})

			if ($MinTargetUptimeMinutes -gt 0)
			{
				$uptimeMin = [math]::Round(((Get-Date) - [datetime]$targetState.SqlStartTime).TotalMinutes, 1)
				$checks.Add([PSCustomObject]@{
						Name   = 'TargetUptime'
						Passed = ($uptimeMin -ge $MinTargetUptimeMinutes)
						Detail = "SQL Server auf '$preferredName' laeuft seit $uptimeMin Min (mindestens $MinTargetUptimeMinutes verlangt)"
					})
			}

			# ------------------------------------------------------------------
			# 6. Datenbanken auf dem bevorzugten Replikat. AgDbCount aus der Cluster-Katalogsicht
			#    deckt den klassischen Patchwochenend-Fall ab: eine Datenbank ist gar nicht
			#    wieder gejoint - dann taucht sie in dm_hadr_database_replica_states nicht auf.
			# ------------------------------------------------------------------
			$targetDbSql = @"
SELECT
    DB_NAME(drs.database_id)           AS DatabaseName,
    drs.synchronization_state_desc     AS SyncState,
    drs.database_state_desc            AS DbState,
    drs.is_suspended                   AS IsSuspended,
    ISNULL(drs.redo_queue_size, 0)     AS RedoQueueKB,
    (SELECT COUNT(*) FROM sys.availability_databases_cluster adc
      WHERE adc.group_id = ag.group_id) AS AgDbCount
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups             ag  ON ag.group_id = drs.group_id
WHERE ag.name = N'$agEscaped'
  AND drs.is_local = 1
"@
			$targetDbs = @(Invoke-DbaQuery @targetConn -Database master -Query $targetDbSql -EnableException)

			$expectedDbCount = if ($targetDbs.Count -gt 0) { [int]$targetDbs[0].AgDbCount } else { -1 }
			$checks.Add([PSCustomObject]@{
					Name   = 'AllDatabasesJoined'
					Passed = (($targetDbs.Count -gt 0) -and ($targetDbs.Count -eq $expectedDbCount))
					Detail = "$($targetDbs.Count) von $expectedDbCount AG-Datenbanken auf '$preferredName' vorhanden"
				})

			# is_suspended kann NULL sein - ein blosses [bool] darauf waere $true (jedes
			# Nicht-$null-Objekt ist $true) und wuerde eine gesunde Datenbank als suspendiert melden.
			$notSynced = @($targetDbs | Where-Object {
					([string]$_.SyncState -ne 'SYNCHRONIZED') -or
					([string]$_.DbState -ne 'ONLINE') -or
					(($_.IsSuspended -isnot [DBNull]) -and [bool]$_.IsSuspended)
				})
			$checks.Add([PSCustomObject]@{
					Name   = 'AllDatabasesSynchronized'
					Passed = ($notSynced.Count -eq 0)
					Detail = if ($notSynced.Count -eq 0) { "Alle Datenbanken SYNCHRONIZED/ONLINE" }
					else { "Nicht bereit: " + (($notSynced | ForEach-Object { "$($_.DatabaseName) ($($_.SyncState)/$($_.DbState)$(if (($_.IsSuspended -isnot [DBNull]) -and [bool]$_.IsSuspended) { '/suspended' }))" }) -join ', ') }
				})

			$maxRedoMB = if ($targetDbs.Count -gt 0) { [math]::Round((($targetDbs | Measure-Object -Property RedoQueueKB -Maximum).Maximum / 1024.0), 2) }
			else { 0 }
			if ($MaxRedoQueueMB -gt 0)
			{
				$checks.Add([PSCustomObject]@{
						Name   = 'RedoQueue'
						Passed = ($maxRedoMB -le $MaxRedoQueueMB)
						Detail = "Groesste Redo-Queue $maxRedoMB MB (Grenze $MaxRedoQueueMB MB)"
					})
			}

			# ------------------------------------------------------------------
			# 7. Wie lange haelt das aktuelle Primaerreplikat seine Rolle schon? Schuetzt davor,
			#    mitten in eine laufende Patch-/Failover-Sequenz hineinzuschwenken.
			#    current_configuration_commit_start_time_utc ist eine Naeherung (jeder
			#    Konfigurations-Commit setzt sie neu) - sie kann einen Rueckschwenk nur
			#    verzoegern, nie faelschlich ausloesen.
			# ------------------------------------------------------------------
			if ($MinRoleAgeMinutes -gt 0)
			{
				$primaryConn = @{ SqlInstance = $currentPrimary }
				if ($SqlCredential) { $primaryConn['SqlCredential'] = $SqlCredential }

				try
				{
					$roleSql = @"
SELECT
    ars.current_configuration_commit_start_time_utc AS RoleStartUtc
FROM sys.availability_groups                   ag
JOIN sys.dm_hadr_availability_replica_states  ars ON ars.group_id = ag.group_id
WHERE ag.name = N'$agEscaped'
  AND ars.is_local = 1
"@
					$roleRow = Invoke-DbaQuery @primaryConn -Database master -Query $roleSql -EnableException | Select-Object -First 1

					if ($roleRow -and $roleRow.RoleStartUtc -isnot [DBNull] -and $roleRow.RoleStartUtc)
					{
						$roleAgeMin = [math]::Round(((Get-Date).ToUniversalTime() - [datetime]$roleRow.RoleStartUtc).TotalMinutes, 1)
						$checks.Add([PSCustomObject]@{
								Name   = 'PrimaryRoleAge'
								Passed = ($roleAgeMin -ge $MinRoleAgeMinutes)
								Detail = "'$currentPrimary' haelt die Rolle seit $roleAgeMin Min (mindestens $MinRoleAgeMinutes verlangt)"
							})
					}
					else
					{
						$checks.Add([PSCustomObject]@{
								Name   = 'PrimaryRoleAge'
								Passed = $true
								Detail = "Rollenalter nicht ermittelbar - Pruefung uebersprungen"
							})
					}
				}
				catch
				{
					# Nur diese Pruefung faellt aus; die harten Kriterien (Sync-Zustand, Redo-Queue,
					# Uptime) tragen weiter. Der eigentliche Failover braucht das Primaerreplikat
					# ohnehin und wuerde scheitern, falls es nicht erreichbar ist.
					$checks.Add([PSCustomObject]@{
							Name   = 'PrimaryRoleAge'
							Passed = $true
							Detail = "Rollenalter auf '$currentPrimary' nicht abfragbar: $($_.Exception.Message)"
						})
					Invoke-sqmLogging -Message "[$AvailabilityGroup] Rollenalter auf '$currentPrimary' nicht abfragbar: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}

			# ------------------------------------------------------------------
			# 8. Auswerten.
			# ------------------------------------------------------------------
			$blocking = @($checks | Where-Object { -not $_.Passed -and $_.Name -ne 'PreferredIsPrimary' })

			if ($blocking.Count -gt 0)
			{
				$result.Status = 'Blocked'
				$result.Reason = "Schwenk auf '$preferredName' nicht durchgefuehrt: " + (($blocking | ForEach-Object { "$($_.Name) [$($_.Detail)]" }) -join '; ')
				Invoke-sqmLogging -Message "[$AvailabilityGroup] $($result.Reason)" -FunctionName $functionName -Level "WARNING"
				if ($FailOnBlocked)
				{
					if ($EnableException) { throw $result.Reason }
					Write-Error $result.Reason
				}
				return $result
			}

			if ($CheckOnly)
			{
				$result.Status = 'FailoverRequired'
				$result.Reason = "Alle Bedingungen erfuellt - Schwenk von '$currentPrimary' auf '$preferredName' waere moeglich (-CheckOnly: nichts unternommen)."
				Invoke-sqmLogging -Message "[$AvailabilityGroup] $($result.Reason)" -FunctionName $functionName -Level "INFO"
				return $result
			}

			if (-not $PSCmdlet.ShouldProcess($AvailabilityGroup, "Failover von '$currentPrimary' auf bevorzugtes Replikat '$preferredName'"))
			{
				$result.Status = 'FailoverRequired'
				$result.Reason = "Alle Bedingungen erfuellt - Schwenk von '$currentPrimary' auf '$preferredName' uebersprungen (WhatIf/Confirm)."
				return $result
			}

			# ------------------------------------------------------------------
			# 9. Failover ueber Invoke-sqmFailover - damit gelten exakt dieselben Pre-/Post-Checks
			#    wie beim Schwenk von Hand (und es gibt nur EINE Stelle mit ALTER ... FAILOVER).
			# ------------------------------------------------------------------
			$foParams = @{
				SqlInstance			     = $currentPrimary
				AvailabilityGroup	     = $AvailabilityGroup
				TargetReplica		     = $preferredName
				MaxRedoQueueMB		     = $MaxRedoQueueMB
				WaitAfterFailoverSeconds = $WaitAfterFailoverSeconds
				ContinueOnError		     = $true
			}
			if ($SqlCredential) { $foParams['SqlCredential'] = $SqlCredential }

			$result.Action = 'Failover'
			$failover = Invoke-sqmFailover @foParams -Confirm:$false

			switch ([string]$failover.Status)
			{
				'Success' {
					$result.Status = 'FailedOver'
					$result.NewPrimary = $failover.NewPrimary
					$result.Reason = "Schwenk auf '$preferredName' erfolgreich (Dauer $($failover.FailoverDurationSec)s)."
					Invoke-sqmLogging -Message "[$AvailabilityGroup] $($result.Reason)" -FunctionName $functionName -Level "INFO"
				}
				'Warning' {
					$result.Status = 'FailoverUnconfirmed'
					$result.NewPrimary = $failover.NewPrimary
					$result.Reason = "Failover-Kommando abgesetzt, Nachpruefung unklar: $($failover.Message)"
					Invoke-sqmLogging -Message "[$AvailabilityGroup] $($result.Reason)" -FunctionName $functionName -Level "WARNING"
				}
				default {
					$result.Status = 'FailoverFailed'
					$result.Reason = "Schwenk auf '$preferredName' fehlgeschlagen: $($failover.Message)"
					Invoke-sqmLogging -Message "[$AvailabilityGroup] $($result.Reason)" -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $result.Reason }
					Write-Error $result.Reason
				}
			}
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			$result.Status = 'Failed'
			$result.Reason = $errMsg
			if ($EnableException) { throw }
			Write-Error $errMsg
		}

		return $result
	}
}
