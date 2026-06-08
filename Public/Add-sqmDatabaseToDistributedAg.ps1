<#
.SYNOPSIS
    Adds a database to a Distributed AlwaysOn Availability Group.

.DESCRIPTION
    Performs the following steps:
    1. Creates full backup of source database
    2. Backs up transaction log
    3. Restores database to secondary cluster
    4. Joins database to secondary AG
    5. Adds database to Distributed AG
    6. Monitors synchronization

    Requires:
    - Source database on primary AG
    - Secondary AG already configured
    - Distributed AG relationship established

.PARAMETER SqlInstance
    Primary SQL Server instance. Default: current computer name.

.PARAMETER AvailabilityGroupName
    Name of the Distributed AG.

.PARAMETER DatabaseName
    Name of the database to add.

.PARAMETER SecondaryInstance
    Secondary SQL Server instance where database will be restored.

.PARAMETER BackupPath
    Path for full and log backups. Default: C:\Backups

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Add-sqmDatabaseToDistributedAg -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -DatabaseName "MyDb" -SecondaryInstance "DR-SQL01"

.NOTES
    Author:       MSSQLTools
    Requires:     dbatools, sufficient backup storage
#>
function Add-sqmDatabaseToDistributedAg
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,
		[Parameter(Mandatory = $true)]
		[string]$SecondaryInstance,
		[Parameter(Mandatory = $false)]
		[string]$BackupPath = "C:\Backups",
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName fuer DB=$DatabaseName zu AG=$AvailabilityGroupName" -FunctionName $functionName -Level "INFO"

		if (-not (Test-Path $BackupPath))
		{
			New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
		}
	}

	process
	{
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$stepResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

		try
		{
			# Step 1: Verify database exists on primary
			$dbExistsQuery = "SELECT COUNT(*) AS C FROM sys.databases WHERE name = @DbName"
			$dbRow = Invoke-DbaQuery @connParams -Query $dbExistsQuery -SqlParameters @{ DbName = $DatabaseName } -ErrorAction Stop

			if ([int]$dbRow.C -eq 0)
			{
				throw "Datenbank '$DatabaseName' existiert nicht auf [$SqlInstance]"
			}

			$stepResults.Add([PSCustomObject]@{ Step = 'Verify DB'; Status = 'OK'; Details = "Database exists" })

			# Step 2: Create full backup
			Invoke-sqmLogging -Message "[$DatabaseName] Erstelle Full Backup..." -FunctionName $functionName -Level "INFO"

			$backupFile = Join-Path -Path $BackupPath -ChildPath "$DatabaseName-$(Get-Date -Format 'yyyyMMdd-HHmm').bak"

			$backupSql = @"
BACKUP DATABASE [$DatabaseName] TO DISK = @Path
WITH COMPRESSION, INIT, NAME = 'Full Backup $DatabaseName',
     DESCRIPTION = 'Distributed AG Add DB Backup'
"@
			Invoke-DbaQuery @connParams -Query $backupSql -SqlParameters @{ Path = $backupFile } -ErrorAction Stop

			$stepResults.Add([PSCustomObject]@{ Step = 'Full Backup'; Status = 'OK'; Details = "Backup file: $backupFile" })

			# Step 3: Create log backup
			Invoke-sqmLogging -Message "[$DatabaseName] Erstelle Log Backup..." -FunctionName $functionName -Level "INFO"

			$logBackupFile = Join-Path -Path $BackupPath -ChildPath "$DatabaseName-$(Get-Date -Format 'yyyyMMdd-HHmm').trn"

			$logBackupSql = @"
BACKUP LOG [$DatabaseName] TO DISK = @Path
WITH COMPRESSION, INIT, NAME = 'Log Backup $DatabaseName'
"@
			Invoke-DbaQuery @connParams -Query $logBackupSql -SqlParameters @{ Path = $logBackupFile } -ErrorAction Stop

			$stepResults.Add([PSCustomObject]@{ Step = 'Log Backup'; Status = 'OK'; Details = "Log file: $logBackupFile" })

			# Step 4: Restore database on secondary instance
			Invoke-sqmLogging -Message "[$SecondaryInstance] Restore database $DatabaseName ..." -FunctionName $functionName -Level "INFO"

			$secondaryConnParams = @{ SqlInstance = $SecondaryInstance }
			if ($SqlCredential) { $secondaryConnParams['SqlCredential'] = $SqlCredential }

			try
			{
				# Set to NORECOVERY for log restore
				$restoreSql = @"
RESTORE DATABASE [$DatabaseName] FROM DISK = @BackupPath
    WITH NORECOVERY, REPLACE
"@
				Invoke-DbaQuery @secondaryConnParams -Query $restoreSql -SqlParameters @{ BackupPath = $backupFile } -ErrorAction Stop

				# Restore log
				$restoreLogSql = @"
RESTORE LOG [$DatabaseName] FROM DISK = @BackupPath
    WITH NORECOVERY
"@
				Invoke-DbaQuery @secondaryConnParams -Query $restoreLogSql -SqlParameters @{ BackupPath = $logBackupFile } -ErrorAction Stop

				$stepResults.Add([PSCustomObject]@{ Step = 'Restore DB'; Status = 'OK'; Details = "Database restored to secondary" })
			}
			catch
			{
				$stepResults.Add([PSCustomObject]@{ Step = 'Restore DB'; Status = 'FAIL'; Details = $_.Exception.Message })
				throw
			}

			# Step 5: Join database to AG
			Invoke-sqmLogging -Message "[$AvailabilityGroupName] Join database to AG..." -FunctionName $functionName -Level "INFO"

			$joinSql = @"
ALTER DATABASE [$DatabaseName] SET HADR AVAILABILITY GROUP = [$AvailabilityGroupName]
"@
			Invoke-DbaQuery @secondaryConnParams -Query $joinSql -ErrorAction Stop

			$stepResults.Add([PSCustomObject]@{ Step = 'Join to AG'; Status = 'OK'; Details = "Database joined to AG" })

			# Step 6: Monitor synchronization
			Start-Sleep -Seconds 5

			$syncCheckQuery = @"
SELECT
    ag.name,
    DB_NAME(adbrs.database_id) AS DatabaseName,
    adbrs.synchronization_state_desc,
    adbrs.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states adbrs
    ON adbrs.group_id = ag.group_id
WHERE ag.name = @AgName AND DB_NAME(adbrs.database_id) = @DbName
"@
			$syncStatus = Invoke-DbaQuery @secondaryConnParams -Query $syncCheckQuery -SqlParameters @{ AgName = $AvailabilityGroupName; DbName = $DatabaseName } -ErrorAction Stop

			if ($syncStatus)
			{
				$syncState = $syncStatus.synchronization_state_desc
				$syncHealth = $syncStatus.synchronization_health_desc
				$stepResults.Add([PSCustomObject]@{ Step = 'Sync Check'; Status = 'OK'; Details = "State=$syncState, Health=$syncHealth" })
			}

			Invoke-sqmLogging -Message "[$DatabaseName] erfolgreich zu Distributed AG hinzugefuegt" -FunctionName $functionName -Level "INFO"

			return [PSCustomObject]@{
				Status = 'SUCCESS'
				DatabaseName = $DatabaseName
				AvailabilityGroup = $AvailabilityGroupName
				SecondaryInstance = $SecondaryInstance
				Timestamp = $timestamp
				BackupFile = $backupFile
				LogBackupFile = $logBackupFile
				Steps = $stepResults
			}
		}
		catch
		{
			$errMsg = "Fehler beim Hinzufuegen von DB zu Distributed AG: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException) { throw }

			return [PSCustomObject]@{
				Status = 'FAILED'
				DatabaseName = $DatabaseName
				AvailabilityGroup = $AvailabilityGroupName
				Error = $errMsg
				Steps = $stepResults
			}
		}
	}
}
