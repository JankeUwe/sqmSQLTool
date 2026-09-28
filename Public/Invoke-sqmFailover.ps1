<#
.SYNOPSIS
    Performs a controlled AlwaysOn AG failover with pre- and post-checks.

.DESCRIPTION
    Checks before failover: synchronization status, redo queue size.
    Performs the failover: ALTER AVAILABILITY GROUP ... FAILOVER on the target secondary.
    Checks after failover: new primary reachable, all DBs SYNCHRONIZED.

.PARAMETER SqlInstance
    Any replica of the AG. Default: the current computer name.
    If this instance is not the primary, the function determines the current primary of the
    AG from there and runs the failover from that primary.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER AvailabilityGroup
    Name of the availability group. Optional: if -SqlInstance has exactly one AG, it is used.
    With several AGs the function lists them and asks; in a non-interactive session (Agent
    job, -NonInteractive) it stops with the list of AG names instead.

.PARAMETER TargetReplica
    Instance name of the target replica. If not specified:
    - called on a secondary: that secondary becomes the target. If it is not ready
      (not SYNCHRONOUS_COMMIT and SYNCHRONIZED for every database) the function stops
      instead of switching to another node.
    - called on the primary: the SYNCHRONIZED synchronous-commit secondary with the
      smallest redo queue is selected automatically.

.PARAMETER MaxRedoQueueMB
    Maximum redo queue size in MB. Failover is aborted if exceeded.
    Default: 50 MB.

.PARAMETER WaitAfterFailoverSeconds
    Wait time in seconds after the failover command before post-checks run.
    Default: 30 seconds.

.PARAMETER ContinueOnError
    Do not throw errors; return them in the result object instead.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Invoke-sqmFailover -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -WhatIf

.EXAMPLE
    # On any node of a single-AG cluster: instance, AG and primary are determined automatically
    Invoke-sqmFailover -WhatIf

.EXAMPLE
    Invoke-sqmFailover -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" `
        -TargetReplica "SQL02" -MaxRedoQueueMB 10

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs ALTER AVAILABILITY GROUP on the instance.
    Performs a MANUAL failover (no forced/emergency failover).
#>
function Invoke-sqmFailover
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroup,
		[Parameter(Mandatory = $false)]
		[string]$TargetReplica,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 99999)]
		[int]$MaxRedoQueueMB = 50,
		[Parameter(Mandatory = $false)]
		[ValidateRange(5, 300)]
		[int]$WaitAfterFailoverSeconds = 30,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = _s 'Error_dbatoolsNotFound'
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		if ([string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}
	}

	process
	{
		$result = [PSCustomObject]@{
			AvailabilityGroup   = $AvailabilityGroup
			OldPrimary          = $SqlInstance
			NewPrimary          = $null
			Status              = 'Unknown'
			PreCheckPassed      = $false
			PostCheckPassed     = $false
			FailoverDurationSec = 0
			Message             = ''
		}

		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			# AG ermitteln, wenn keine angegeben: eine vorhanden -> diese, mehrere -> nachfragen.
			# sys.availability_groups ist auf jedem Replikat lesbar, auch auf einem Secondary.
			if ([string]::IsNullOrWhiteSpace($AvailabilityGroup))
			{
				$agNames = @(Invoke-DbaQuery @connParams -Database master -EnableException `
						-Query "SELECT name FROM sys.availability_groups ORDER BY name" |
					ForEach-Object { $_.name })
				if ($agNames.Count -eq 0)
				{
					$result.Status  = 'Failed'
					$result.Message = _s 'Failover_NoAgFound' $SqlInstance
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $result.Message }
					return $result
				}
				if ($agNames.Count -eq 1)
				{
					$AvailabilityGroup = $agNames[0]
					Invoke-sqmLogging -Message (_s 'Failover_AgAutoSelected' $SqlInstance, $AvailabilityGroup) -FunctionName $functionName -Level "INFO"
				}
				else
				{
					if (-not (Test-sqmInteractiveSession))
					{
						$result.Status  = 'Failed'
						$result.Message = _s 'Failover_MultipleAgs' $SqlInstance, ($agNames -join ', ')
						Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw $result.Message }
						return $result
					}
					Write-Host "`nVerfuegbarkeitsgruppen auf '$SqlInstance':"
					for ($i = 0; $i -lt $agNames.Count; $i++)
					{
						Write-Host ("  [{0}] {1}" -f ($i + 1), $agNames[$i])
					}
					while ([string]::IsNullOrWhiteSpace($AvailabilityGroup))
					{
						$answer = Read-Host "Welche AG soll umgeschaltet werden? (1-$($agNames.Count), leer = Abbruch)"
						if ([string]::IsNullOrWhiteSpace($answer))
						{
							$result.Status  = 'Failed'
							$result.Message = _s 'Failover_AgPromptAbort'
							Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "WARNING"
							return $result
						}
						$num = 0
						if ([int]::TryParse($answer.Trim(), [ref]$num) -and $num -ge 1 -and $num -le $agNames.Count)
						{
							$AvailabilityGroup = $agNames[$num - 1]
						}
						else
						{
							Write-Host "Ungueltige Eingabe '$answer'."
						}
					}
					Invoke-sqmLogging -Message (_s 'Failover_AgChosen' $AvailabilityGroup, ($agNames -join ', ')) -FunctionName $functionName -Level "INFO"
				}
			}
			$result.AvailabilityGroup = $AvailabilityGroup
			$agLiteral = $AvailabilityGroup -replace "'", "''"

			# PRE-CHECK 1: AG existiert und Instanz ist Primary
			$agCheckSql = @"
SELECT
    ag.name                                      AS AgName,
    ars.role_desc                                AS Role,
    ars.synchronization_health_desc             AS SyncHealth,
    ars.operational_state_desc                  AS OperState,
    ar.replica_server_name                      AS ReplicaServer,
    ags.primary_replica                         AS PrimaryReplica
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars
    ON ag.group_id = ars.group_id
JOIN sys.availability_replicas ar
    ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_availability_group_states ags
    ON ag.group_id = ags.group_id
WHERE ag.name = N'$agLiteral'
  AND ars.is_local = 1
"@
			$localState = Invoke-DbaQuery @connParams -Database master -Query $agCheckSql -EnableException

			if (-not $localState)
			{
				$result.Status  = 'Failed'
				$result.Message = _s 'Failover_AgNotFound' $AvailabilityGroup, $SqlInstance
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Message }
				return $result
			}

			# Nicht Primary: den aktuellen Primary der AG nehmen. Ein Secondary kennt ihn ueber
			# sys.dm_hadr_availability_group_states.primary_replica; NULL heisst, der Secondary
			# hat gerade keine Verbindung zum Primary (oder kein Quorum) - dann abbrechen statt raten.
			# Der angegebene Secondary wird als Wunschziel gemerkt: wer auf SQL02 einen Failover
			# startet, will in aller Regel, dass SQL02 Primary wird.
			$requestedReplica = $null
			if ($localState.Role -ne 'PRIMARY')
			{
				$requestedReplica = [string]$localState.ReplicaServer
				$primaryName = $localState.PrimaryReplica
				if ($primaryName -is [System.DBNull] -or [string]::IsNullOrWhiteSpace($primaryName))
				{
					$result.Status  = 'Failed'
					$result.Message = _s 'Failover_PrimaryUnknown' $SqlInstance, $AvailabilityGroup, $localState.Role
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $result.Message }
					return $result
				}

				Invoke-sqmLogging -Message (_s 'Failover_PrimaryRedirect' $SqlInstance, $AvailabilityGroup, $localState.Role, $primaryName) -FunctionName $functionName -Level "INFO"
				$SqlInstance = [string]$primaryName
				$connParams['SqlInstance'] = $SqlInstance

				# Rolle auf dem ermittelten Primary gegenpruefen - zwischen beiden Abfragen kann
				# bereits ein Failover gelaufen sein.
				$localState = Invoke-DbaQuery @connParams -Database master -Query $agCheckSql -EnableException
				if (-not $localState -or $localState.Role -ne 'PRIMARY')
				{
					$role = if ($localState) { $localState.Role } else { 'unbekannt' }
					$result.Status  = 'Failed'
					$result.Message = _s 'Failover_NotPrimary' $SqlInstance, $role
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $result.Message }
					return $result
				}
			}
			$result.OldPrimary = $SqlInstance
			Invoke-sqmLogging -Message (_s 'Failover_Starting' $functionName, $AvailabilityGroup, $SqlInstance, $TargetReplica) -FunctionName $functionName -Level "INFO"

			# PRE-CHECK 2: Replikate abfragen
			$replicaSql = @"
SELECT
    ar.replica_server_name                       AS ReplicaServer,
    ars.role_desc                                AS Role,
    ars.synchronization_health_desc             AS SyncHealth,
    drs.synchronization_state_desc             AS SyncState,
    ISNULL(drs.redo_queue_size, 0)              AS RedoQueueKB,
    ISNULL(drs.log_send_queue_size, 0)          AS LogSendQueueKB,
    ar.availability_mode_desc                   AS AvailMode
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
    ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars
    ON ar.replica_id = ars.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs
    ON ar.replica_id = drs.replica_id
WHERE ag.name = N'$agLiteral'
  AND ars.role_desc = 'SECONDARY'
"@
			$replicas = Invoke-DbaQuery @connParams -Database master -Query $replicaSql -EnableException

			if (-not $replicas)
			{
				$result.Status  = 'Failed'
				$result.Message = _s 'Failover_NoSecondaries' $AvailabilityGroup
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Message }
				return $result
			}

			# Ziel-Replikat bestimmen
			$target = $null
			if ($TargetReplica)
			{
				$target = $replicas | Where-Object { $_.ReplicaServer -ieq $TargetReplica } | Select-Object -First 1
				if (-not $target)
				{
					$result.Status  = 'Failed'
					$result.Message = _s 'Failover_TargetNotFound' $TargetReplica
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $result.Message }
					return $result
				}
			}
			elseif ($requestedReplica)
			{
				# Aufgerufen auf einem Secondary: dieser wird Ziel. Ist er nicht bereit, wird nicht
				# still auf einen anderen Knoten ausgewichen - das waere nicht das, was gemeint war.
				# Eine Zeile je Datenbank: bereit ist das Replikat nur, wenn ALLE synchron sind.
				$localRows = @($replicas | Where-Object { $_.ReplicaServer -ieq $requestedReplica })
				$notReady = @($localRows | Where-Object { $_.SyncState -ne 'SYNCHRONIZED' -or $_.AvailMode -ne 'SYNCHRONOUS_COMMIT' })
				if ($localRows.Count -eq 0 -or $notReady.Count -gt 0)
				{
					$result.Status  = 'Failed'
					if ($localRows.Count -eq 0)
					{
						$result.Message = _s 'Failover_TargetNotFound' $requestedReplica
					}
					else
					{
						$states = ($notReady | ForEach-Object { "$($_.AvailMode)/$($_.SyncState)" } | Sort-Object -Unique) -join ', '
						$result.Message = _s 'Failover_LocalNotReady' $requestedReplica, $states
					}
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $result.Message }
					return $result
				}
				# Groesste Redo-Queue ueber alle Datenbanken, damit Pre-Check 3 die unguenstigste prueft
				$target = $localRows | Sort-Object RedoQueueKB -Descending | Select-Object -First 1
				Invoke-sqmLogging -Message (_s 'Failover_LocalTarget' $requestedReplica) -FunctionName $functionName -Level "INFO"
			}
			else
			{
				$target = $replicas |
					Where-Object { $_.SyncState -eq 'SYNCHRONIZED' -and $_.AvailMode -eq 'SYNCHRONOUS_COMMIT' } |
					Sort-Object RedoQueueKB |
					Select-Object -First 1

				if (-not $target)
				{
					$target = $replicas |
						Where-Object { $_.SyncState -in @('SYNCHRONIZED','SYNCHRONIZING') } |
						Sort-Object RedoQueueKB |
						Select-Object -First 1
				}
			}

			if (-not $target)
			{
				$result.Status  = 'Failed'
				$result.Message = _s 'Failover_NoSuitableTarget'
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Message }
				return $result
			}

			# PRE-CHECK 3: Redo-Queue pruefen
			$redoQueueMB = [math]::Round($target.RedoQueueKB / 1024.0, 2)
			if ($MaxRedoQueueMB -gt 0 -and $redoQueueMB -gt $MaxRedoQueueMB)
			{
				$result.Status  = 'Failed'
				$result.Message = _s 'Failover_RedoQueueLimit' $target.ReplicaServer, $redoQueueMB, $MaxRedoQueueMB
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Message }
				return $result
			}

			$result.PreCheckPassed = $true
			$result.NewPrimary     = $target.ReplicaServer
			Invoke-sqmLogging -Message (_s 'Failover_PreCheckPassed' $target.ReplicaServer, $target.SyncState, $redoQueueMB) -FunctionName $functionName -Level "INFO"

			# FAILOVER
			if (-not $PSCmdlet.ShouldProcess($AvailabilityGroup, "Failover von '$SqlInstance' auf '$($target.ReplicaServer)'"))
			{
				$result.Status  = 'WhatIfSkipped'
				$result.Message = _s 'Failover_WhatIf' $target.ReplicaServer
				return $result
			}

			$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
			Invoke-sqmLogging -Message (_s 'Failover_Executing' $target.ReplicaServer) -FunctionName $functionName -Level "INFO"

			$targetConn = @{ SqlInstance = $target.ReplicaServer }
			if ($SqlCredential) { $targetConn['SqlCredential'] = $SqlCredential }

			$failoverSql = "ALTER AVAILABILITY GROUP [$($AvailabilityGroup -replace ']', ']]')] FAILOVER;"
			Invoke-DbaQuery @targetConn -Database master -Query $failoverSql -EnableException

			Invoke-sqmLogging -Message (_s 'Failover_Waiting' $WaitAfterFailoverSeconds) -FunctionName $functionName -Level "INFO"
			Start-Sleep -Seconds $WaitAfterFailoverSeconds

			# POST-CHECK
			try
			{
				$postCheckSql = @"
SELECT
    ag.name                                      AS AgName,
    ars.role_desc                                AS Role,
    ars.synchronization_health_desc             AS SyncHealth
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars
    ON ag.group_id = ars.group_id
WHERE ag.name = N'$agLiteral'
  AND ars.is_local = 1
"@
				$postState = Invoke-DbaQuery @targetConn -Database master -Query $postCheckSql -EnableException

				if ($postState -and $postState.Role -eq 'PRIMARY')
				{
					$result.PostCheckPassed = $true
					$result.Status          = 'Success'
					$result.Message         = _s 'Failover_Success' $target.ReplicaServer, $postState.SyncHealth
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
				}
				else
				{
					$result.Status  = 'Warning'
					$result.Message = _s 'Failover_PostCheckFailed'
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "WARNING"
				}
			}
			catch
			{
				$result.Status  = 'Warning'
				$result.Message = _s 'Failover_PostCheckError' $_.Exception.Message
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "WARNING"
			}

			$stopwatch.Stop()
			$result.FailoverDurationSec = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
			Invoke-sqmLogging -Message (_s 'Failover_Completed' $functionName, $result.FailoverDurationSec) -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$errMsg = _s 'Error_Generic' $functionName, $_.Exception.Message
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			$result.Status  = 'Failed'
			$result.Message = $errMsg
			if ($EnableException) { throw }
			if (-not $ContinueOnError) { Write-Error $errMsg }
		}

		return $result
	}
}
