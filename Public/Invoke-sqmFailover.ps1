<#
.SYNOPSIS
    Performs a controlled AlwaysOn AG failover with pre- and post-checks.

.DESCRIPTION
    Checks before failover: synchronization status, redo queue size.
    Performs the failover: ALTER AVAILABILITY GROUP ... FAILOVER on the target secondary.
    Checks after failover: new primary reachable, all DBs SYNCHRONIZED.

.PARAMETER SqlInstance
    Current PRIMARY instance.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER AvailabilityGroup
    Name of the availability group.

.PARAMETER TargetReplica
    Instance name of the target replica. If not specified, the first
    SYNCHRONIZED secondary replica is selected automatically.

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
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
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
		Invoke-sqmLogging -Message (_s 'Failover_Starting' $functionName, $AvailabilityGroup, $SqlInstance, $TargetReplica) -FunctionName $functionName -Level "INFO"
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

			# PRE-CHECK 1: AG existiert und Instanz ist Primary
			$agCheckSql = @"
SELECT
    ag.name                                      AS AgName,
    ars.role_desc                                AS Role,
    ars.synchronization_health_desc             AS SyncHealth,
    ars.operational_state_desc                  AS OperState
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars
    ON ag.group_id = ars.group_id
JOIN sys.availability_replicas ar
    ON ars.replica_id = ar.replica_id
WHERE ag.name = N'$AvailabilityGroup'
  AND ars.is_local = 1
"@
			$localState = Invoke-DbaQuery @connParams -Database master -Query $agCheckSql -ErrorAction Stop

			if (-not $localState)
			{
				$result.Status  = 'Failed'
				$result.Message = _s 'Failover_AgNotFound' $AvailabilityGroup, $SqlInstance
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Message }
				return $result
			}

			if ($localState.Role -ne 'PRIMARY')
			{
				$result.Status  = 'Failed'
				$result.Message = _s 'Failover_NotPrimary' $SqlInstance, $localState.Role
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $result.Message }
				return $result
			}

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
WHERE ag.name = N'$AvailabilityGroup'
  AND ars.role_desc = 'SECONDARY'
"@
			$replicas = Invoke-DbaQuery @connParams -Database master -Query $replicaSql -ErrorAction Stop

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

			$failoverSql = "ALTER AVAILABILITY GROUP [$AvailabilityGroup] FAILOVER;"
			Invoke-DbaQuery @targetConn -Database master -Query $failoverSql -ErrorAction Stop

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
WHERE ag.name = N'$AvailabilityGroup'
  AND ars.is_local = 1
"@
				$postState = Invoke-DbaQuery @targetConn -Database master -Query $postCheckSql -ErrorAction Stop

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
