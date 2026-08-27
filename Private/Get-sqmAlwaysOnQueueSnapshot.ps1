<#
.SYNOPSIS
    Reads the raw redo queue / send queue snapshot for all Always On replicas and databases
    on an instance.

.DESCRIPTION
    Shared by Get-sqmAlwaysOnHealthReport (file-based report) and Get-sqmAlwaysOnQueueStatus
    (lightweight, no file I/O - used by pollers). Extracted so the DMV query and the
    threshold/status scoring only exist once.

    Queries sys.dm_hadr_database_replica_states per replica/database and classifies each row:
        - OverallStatus = 'Critical' when the database isn't synchronized/connected or is suspended
        - OverallStatus = 'Warning'  when redo (on a secondary) or send queue exceeds the threshold
        - OverallStatus = 'OK'       otherwise

    Returns an empty array (not an error) when the instance has no availability groups.

.PARAMETER SqlInstance
    SQL Server instance to query.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER MaxRedoQueueMB
    Warning threshold for the redo queue in MB. Default: 100.

.PARAMETER MaxSendQueueMB
    Warning threshold for the send queue in MB. Default: 50.

.PARAMETER EnableException
    Throw exceptions immediately instead of relying on dbatools warnings.

.NOTES
    Private helper - not exported. Requires VIEW SERVER STATE on the target instance.
#>
function Get-sqmAlwaysOnQueueSnapshot
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$MaxRedoQueueMB = 100,
		[Parameter(Mandatory = $false)]
		[int]$MaxSendQueueMB = 50,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$ags = Get-DbaAvailabilityGroup @connParams -EnableException:$EnableException
	if (-not $ags)
	{
		Invoke-sqmLogging -Message "[$SqlInstance] Keine Verfuegbarkeitsgruppen vorhanden." -FunctionName $functionName -Level "INFO"
		return @()
	}

	$dmvQuery = @"
SELECT
    ag.name                           AS AgName,
    ar.replica_server_name            AS ReplicaName,
    ar.availability_mode_desc         AS AvailabilityMode,
    ar.failover_mode_desc             AS FailoverMode,
    ars.role_desc                     AS Role,
    ars.connected_state_desc          AS ConnectionState,
    ars.synchronization_health_desc   AS SyncHealth,
    DB_NAME(adbrs.database_id)         AS DatabaseName,
    adbrs.synchronization_state_desc  AS DbSyncState,
    adbrs.synchronization_health_desc AS DbSyncHealth,
    adbrs.redo_queue_size             AS RedoQueueKB,
    adbrs.log_send_queue_size         AS SendQueueKB,
    adbrs.redo_rate                   AS RedoRateKBs,
    adbrs.log_send_rate               AS SendRateKBs,
    adbrs.is_suspended                AS IsSuspended
FROM sys.availability_groups              ag
JOIN sys.availability_replicas            ar    ON ar.group_id    = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states adbrs ON adbrs.replica_id = ar.replica_id
ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name, DB_NAME(adbrs.database_id);
"@
	$dmvRows = Invoke-DbaQuery @connParams -Query $dmvQuery -EnableException:$EnableException

	$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
	foreach ($row in $dmvRows)
	{
		if (-not $row.DatabaseName) { continue } # replica row without a database - skip

		# NULL-safe: a disconnected secondary reports NULL for queue sizes.
		$redoMB = [math]::Round([double]($row.RedoQueueKB -as [long]) / 1024, 1)
		$sendMB = [math]::Round([double]($row.SendQueueKB -as [long]) / 1024, 1)

		$queueStatus = if ($row.Role -ne 'PRIMARY' -and $redoMB -gt $MaxRedoQueueMB) { 'Warning' }
		elseif ($sendMB -gt $MaxSendQueueMB) { 'Warning' }
		else { 'OK' }

		$syncOk = ($row.DbSyncState -in @('SYNCHRONIZED', 'SYNCHRONIZING')) -and
		$row.ConnectionState -eq 'CONNECTED' -and
		-not $row.IsSuspended

		$overallStatus = if (-not $syncOk) { 'Critical' }
		elseif ($queueStatus -eq 'Warning') { 'Warning' }
		else { 'OK' }

		$rows.Add([PSCustomObject]@{
				SqlInstance	    = $SqlInstance
				AgName		    = $row.AgName
				ReplicaName	    = $row.ReplicaName
				Role		    = $row.Role
				AvailabilityMode = $row.AvailabilityMode
				ConnectionState = $row.ConnectionState
				SyncHealth	    = $row.SyncHealth
				DatabaseName    = $row.DatabaseName
				DbSyncState	    = $row.DbSyncState
				IsSuspended	    = $row.IsSuspended
				RedoQueueMB	    = $redoMB
				SendQueueMB	    = $sendMB
				RedoRateKBs	    = $row.RedoRateKBs
				SendRateKBs	    = $row.SendRateKBs
				OverallStatus   = $overallStatus
			})
	}

	return $rows.ToArray()
}
