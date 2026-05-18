<#
.SYNOPSIS
Restores a database from a backup file, with support for single-server and AlwaysOn environments.

.DESCRIPTION
The function performs a controlled database restore. It automatically detects whether the target
database belongs to an AlwaysOn availability group and removes it from the AG if so (including
deletion on secondary replicas). Database users are exported before the restore (for later
recovery). Optionally a backup of the original database can be created. After the restore,
users are recovered, orphaned users are repaired, non-existent Windows logins are removed,
and the database owner is set to the SA account (regardless of its name).

The function can also restore a sequence of backups (Full + Diff + Logs) using the `-BackupFiles`
parameter, which accepts a list of backup files in the correct order (Full, then Diff, then Logs).

Before user export and before the restore, the configured PBM policy (DefaultPolicy) is
temporarily disabled to avoid restrictions during user creation. It is re-enabled after completion.

If the database is in use before the restore, it is automatically set to single-user mode
(and switched back to multi-user after the restore).

.PARAMETER SqlInstance
Target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). Default: current computer name.

.PARAMETER SqlCredential
Alternative credentials for the target instance.

.PARAMETER BackupFile
Path to the full backup file (.bak). Can also be an array for striped backups.
For sequential restore (Full + Diff + Logs) use `-BackupFiles`.

.PARAMETER BackupFiles
Array of backup files in order: Full, then Diff (optional), then Logs (optional).
Example: @("C:\Backup\Full.bak", "C:\Backup\Diff.bak", "C:\Backup\Log1.trn", "C:\Backup\Log2.trn").
Can be used instead of `-BackupFile`.

.PARAMETER DatabaseName
Name of the database to restore (as it appears in the backup file). Required to determine file names.

.PARAMETER NewDatabaseName
Optional: New name for the database after the restore. If specified, logical file names are
adjusted accordingly (physical files use the new name as base).

.PARAMETER NewDatabaseFilePath
Optional: Target directory for database files (.mdf, .ndf). If not specified, the default
directory of the target instance is used (BackupDirectory or DefaultFile).

.PARAMETER NewLogFilePath
Optional: Target directory for the log file (.ldf). If not specified, the default directory
of the target instance is used.

.PARAMETER BackupBeforeRestore
Optional: Creates a full backup of the existing database before the restore (if present).
The backup is stored in the default backup directory named "DatabaseName_preRestore_YYYYMMDD_HHmmss.bak".

.PARAMETER NoUserExport
Optional: Skips export of database users (users are always exported by default).
The export file is stored temporarily in the %TEMP% directory.

.PARAMETER KeepAlwaysOn
Optional: If the database is part of an AG, it is not removed from the AG.
Note: Restoring an AG database is only possible after removing it from the AG.
Use this parameter only if the database is already outside the AG.

.PARAMETER WithNoRecovery
Optional: Performs the restore with NORECOVERY so the database remains in restoring state
(for additional log backups). By default RECOVERY is used (database online).

.PARAMETER ContinueWithNoRecovery
Optional: When set, the last restore is also performed with NORECOVERY (e.g. when
additional backups are to be applied manually).

.PARAMETER ForceSingleUser
Forces the database into single-user mode before the restore (even if no active connections
are detected). By default only switches when there are active connections.

.PARAMETER RejoinAvailabilityGroup
When set and the database was part of an AG, it is automatically re-added to the AG after
the restore (Add-DbaAgDatabase with SeedingMode Automatic). Requires Automatic Seeding on the AG.
Without this parameter, the database remains outside the AG after the restore.

.PARAMETER EnableException
Switch to allow exceptions to pass through (by default errors are logged and returned as objects).

.PARAMETER Confirm
Request confirmation before critical actions (removing from AG, restore).

.PARAMETER WhatIf
Shows what would happen without making changes.

.EXAMPLE
# Simple restore of a full backup file
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\AdventureWorks.bak" -DatabaseName "AdventureWorks"

.EXAMPLE
# Restore with Full + Diff + Logs
$backupSequence = @(
    "D:\Backup\AdventureWorks_Full.bak",
    "D:\Backup\AdventureWorks_Diff.bak",
    "D:\Backup\AdventureWorks_Log1.trn",
    "D:\Backup\AdventureWorks_Log2.trn"
)
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFiles $backupSequence -DatabaseName "AdventureWorks"

.EXAMPLE
# Restore with new name and forced Single-User mode
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\OldDB.bak" -DatabaseName "OldDB" -NewDatabaseName "NewDB" -ForceSingleUser

.NOTES
Requires dbatools module, Invoke-sqmLogging, Get-sqmConfig, Set-sqmSqlPolicyState.
The function assumes that the executing login has sysadmin rights on the target instance and all secondary replicas.
#>
function Invoke-sqmRestoreDatabase
{
	[CmdletBinding(DefaultParameterSetName = 'SingleFile', SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true, ParameterSetName = 'SingleFile')]
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string[]]$BackupFile,
		[Parameter(Mandatory = $true, ParameterSetName = 'Sequence')]
		[string[]]$BackupFiles,
		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,
		[Parameter(Mandatory = $false)]
		[string]$NewDatabaseName,
		[Parameter(Mandatory = $false)]
		[string]$NewDatabaseFilePath,
		[Parameter(Mandatory = $false)]
		[string]$NewLogFilePath,
		[Parameter(Mandatory = $false)]
		[switch]$BackupBeforeRestore,
		[Parameter(Mandatory = $false)]
		[switch]$NoUserExport,
		[Parameter(Mandatory = $false)]
		[switch]$KeepAlwaysOn,
		[Parameter(Mandatory = $false)]
		[switch]$WithNoRecovery,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueWithNoRecovery,
		[Parameter(Mandatory = $false)]
		[switch]$ForceSingleUser,
		[Parameter(Mandatory = $false)]
		[switch]$RejoinAvailabilityGroup,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}
		
		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance fuer Datenbank '$DatabaseName'" -FunctionName $functionName -Level "INFO"
		
		$results = @()
		$tempDir = [System.IO.Path]::GetTempPath()
		$userExportFile = Join-Path $tempDir "UserExport_$DatabaseName_$(Get-Date -Format 'yyyyMMddHHmsqm').sql"
		$isAGDatabase = $false
		$availabilityGroup = $null
		$primaryInstance = $null
		$secondaryInstances = @()
		$wasSingleUser = $false
		$originalDbStatus = $null
		
		# Policy-Kontrolle
		$policyName = Get-sqmConfig -Key 'DefaultPolicy' 3>$null
		$policyWasEnabled = $false
		$policyDeactivated = $false
		
		# Bestimme die Liste der Backup-Dateien je nach Parametersatz
		$backupFileList = if ($PSCmdlet.ParameterSetName -eq 'Sequence') { $BackupFiles }
		else { $BackupFile }
	}
	
	process
	{
		try
		{
			# ---- Vorbereitung: Policy temporaer deaktivieren ----
			if (-not [string]::IsNullOrWhiteSpace($policyName))
			{
				try
				{
					$policyObj = Get-DbaPbmPolicy -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Policy $policyName -ErrorAction SilentlyContinue
					if ($policyObj -and $policyObj.Policy.Enabled)
					{
						$policyWasEnabled = $true
						if ($PSCmdlet.ShouldProcess($SqlInstance, "Temporaer Policy '$policyName' deaktivieren fuer Restore-Operation"))
						{
							Invoke-sqmLogging -Message "Deaktiviere Policy '$policyName' temporaer." -FunctionName $functionName -Level "INFO"
							Set-sqmSqlPolicyState -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Policy $policyName -State Disable -EnableException:$EnableException -Confirm:$false
							$policyDeactivated = $true
							$results += [PSCustomObject]@{ Action = "PolicyTemporaryDisable"; Status = "Success"; Message = "Policy '$policyName' deaktiviert." }
						}
						else
						{
							$results += [PSCustomObject]@{ Action = "PolicyTemporaryDisable"; Status = "Skipped"; Message = "WhatIf - Policy-Deaktivierung uebersprungen." }
						}
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Warnung: Konnte Policy '$policyName' nicht pruefen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}
			
			# ---- 1. Zielinstanz und Datenbank-Status ermitteln ----
			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
			$targetDb = $server.Databases[$DatabaseName]
			$dbExists = $targetDb -ne $null
			
			if ($dbExists)
			{
				Invoke-sqmLogging -Message "Datenbank '$DatabaseName' existiert auf $SqlInstance." -FunctionName $functionName -Level "INFO"
				
				# Pruefen, ob die Datenbank in einer AG ist
				$agCheck = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $DatabaseName -ErrorAction SilentlyContinue
				if ($agCheck)
				{
					$isAGDatabase = $true
					$availabilityGroup = $agCheck
					Invoke-sqmLogging -Message "Datenbank ist Mitglied der AG '$($availabilityGroup.Name)'." -FunctionName $functionName -Level "INFO"
					if (-not $KeepAlwaysOn)
					{
						Invoke-sqmLogging -Message "Die Datenbank wird aus der AG entfernt (einschliesslich sekundaerer Replikate)." -FunctionName $functionName -Level "INFO"
					}
					else
					{
						Invoke-sqmLogging -Message "KeepAlwaysOn ist gesetzt - die Datenbank verbleibt in der AG. Ein Restore ist in einer AG nicht moeglich, daher wird der Vorgang abgebrochen." -FunctionName $functionName -Level "ERROR"
						throw "Datenbank ist Teil einer AG und KeepAlwaysOn wurde angegeben. Restore nicht moeglich."
					}
				}
				
				# ---- Datenbank in Single-User-Modus versetzen, falls noetig ----
				$activeConnections = $targetDb.ActiveConnections
				if ($activeConnections -gt 0 -or $ForceSingleUser)
				{
					if ($activeConnections -gt 0)
					{
						Invoke-sqmLogging -Message "Datenbank '$DatabaseName' hat $activeConnections aktive Verbindungen. Setze in Single-User-Modus." -FunctionName $functionName -Level "INFO"
					}
					else
					{
						Invoke-sqmLogging -Message "Erzwinge Single-User-Modus fuer Datenbank '$DatabaseName'." -FunctionName $functionName -Level "INFO"
					}
					$setSingleUserAction = "Setze Datenbank '$DatabaseName' in Single-User-Modus"
					if ($PSCmdlet.ShouldProcess($DatabaseName, $setSingleUserAction))
					{
						try
						{
							$singleUserQuery = "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;"
							Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master -Query $singleUserQuery -ErrorAction Stop
							$wasSingleUser = $true
							Invoke-sqmLogging -Message "Datenbank '$DatabaseName' jetzt im Single-User-Modus." -FunctionName $functionName -Level "INFO"
							$results += [PSCustomObject]@{ Action = "SetSingleUser"; Status = "Success"; Message = "Datenbank in Single-User versetzt." }
						}
						catch
						{
							$errMsg = "Fehler beim Setzen des Single-User-Modus: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{ Action = "SetSingleUser"; Status = "Failed"; Message = $errMsg }
							return $results
						}
					}
					else
					{
						$results += [PSCustomObject]@{ Action = "SetSingleUser"; Status = "Skipped"; Message = "WhatIf - Single-User uebersprungen." }
					}
				}
				else
				{
					Invoke-sqmLogging -Message "Datenbank '$DatabaseName' hat keine aktiven Verbindungen." -FunctionName $functionName -Level "INFO"
				}
			}
			else
			{
				Invoke-sqmLogging -Message "Datenbank '$DatabaseName' existiert nicht auf $SqlInstance." -FunctionName $functionName -Level "INFO"
			}
			
			# ---- 2. Optional: Backup der vorhandenen Datenbank ----
			if ($BackupBeforeRestore -and $dbExists -and -not $isAGDatabase)
			{
				$backupFileName = "${DatabaseName}_preRestore_$(Get-Date -Format 'yyyyMMdd_HHmsqm').bak"
				$backupFileFull = Join-Path (Get-DbaDefaultPath -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Type Backup) $backupFileName
				$backupParams = @{
					SqlInstance   = $SqlInstance
					SqlCredential = $SqlCredential
					Database	  = $DatabaseName
					Path		  = $backupFileFull
					Type		  = 'Full'
					ErrorAction   = 'Stop'
				}
				if ($PSCmdlet.ShouldProcess($DatabaseName, "Backup der Datenbank '$DatabaseName' nach $backupFileFull"))
				{
					try
					{
						Invoke-sqmLogging -Message "Erstelle Backup der vorhandenen Datenbank: $backupFileFull" -FunctionName $functionName -Level "INFO"
						Backup-DbaDatabase @backupParams
						Invoke-sqmLogging -Message "Backup erfolgreich." -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "PreRestoreBackup"; Status = "Success"; Message = "Backup erstellt: $backupFileFull" }
					}
					catch
					{
						$errMsg = "Fehler beim Backup vor dem Restore: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ Action = "PreRestoreBackup"; Status = "Failed"; Message = $errMsg }
						return $results
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "PreRestoreBackup"; Status = "Skipped"; Message = "WhatIf - Backup uebersprungen." }
				}
			}
			
			# ---- 3. Export der Datenbank-User (immer, es sei denn NoUserExport) ----
			if (-not $NoUserExport -and $dbExists)
			{
				if ($PSCmdlet.ShouldProcess($DatabaseName, "Export der Datenbank-User nach $userExportFile"))
				{
					try
					{
						Invoke-sqmLogging -Message "Exportiere User der Datenbank '$DatabaseName' nach $userExportFile" -FunctionName $functionName -Level "INFO"
						Export-DbaUser -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $DatabaseName -Path $userExportFile -Force -ErrorAction Stop
						Invoke-sqmLogging -Message "User-Export erfolgreich." -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "UserExport"; Status = "Success"; Message = "Exportdatei: $userExportFile" }
					}
					catch
					{
						$errMsg = "Fehler beim Export der User: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ Action = "UserExport"; Status = "Failed"; Message = $errMsg }
						return $results
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "UserExport"; Status = "Skipped"; Message = "WhatIf - User-Export uebersprungen." }
				}
			}
			
			# ---- 4. Wenn AlwaysOn: Datenbank aus der AG entfernen (primaer) und von sekundaeren Replikaten loeschen ----
			if ($isAGDatabase -and -not $KeepAlwaysOn)
			{
				$replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $availabilityGroup.Name -ErrorAction Stop
				$primaryReplica = $replicas | Where-Object { $_.Role -eq 'Primary' } | Select-Object -First 1
				$secondaryReplicas = $replicas | Where-Object { $_.Role -eq 'Secondary' }
				$secondaryInstances = $secondaryReplicas | Select-Object -ExpandProperty Name
				
				if ($primaryReplica.Name -ne $SqlInstance)
				{
					Invoke-sqmLogging -Message "Aktuelle Instanz ist nicht primaer. Verbinde mit primaerer Instanz $($primaryReplica.Name) fuer AG-Operationen." -FunctionName $functionName -Level "INFO"
					$primaryInstance = $primaryReplica.Name
				}
				else
				{
					$primaryInstance = $SqlInstance
				}
				
				$removeAgAction = "Entferne Datenbank '$DatabaseName' aus der AG '$($availabilityGroup.Name)'"
				if ($PSCmdlet.ShouldProcess($DatabaseName, $removeAgAction))
				{
					try
					{
						Invoke-sqmLogging -Message $removeAgAction -FunctionName $functionName -Level "INFO"
						Remove-DbaAgDatabase -SqlInstance $primaryInstance -SqlCredential $SqlCredential -AvailabilityGroup $availabilityGroup.Name -Database $DatabaseName -ErrorAction Stop
						Invoke-sqmLogging -Message "Datenbank erfolgreich aus AG entfernt." -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "RemoveFromAG"; Status = "Success"; Message = "Datenbank aus AG entfernt." }
					}
					catch
					{
						$errMsg = "Fehler beim Entfernen aus AG: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ Action = "RemoveFromAG"; Status = "Failed"; Message = $errMsg }
						return $results
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "RemoveFromAG"; Status = "Skipped"; Message = "WhatIf - Entfernen aus AG uebersprungen." }
				}
				
				foreach ($secondary in $secondaryInstances)
				{
					$removeDbAction = "Loesche Datenbank '$DatabaseName' auf sekundaerem Knoten '$secondary'"
					if ($PSCmdlet.ShouldProcess($DatabaseName, $removeDbAction))
					{
						try
						{
							Invoke-sqmLogging -Message $removeDbAction -FunctionName $functionName -Level "INFO"
							$secondaryServer = Connect-DbaInstance -SqlInstance $secondary -SqlCredential $SqlCredential -ErrorAction Stop
							if ($secondaryServer.Databases[$DatabaseName] -and $secondaryServer.Databases[$DatabaseName].IsAccessible)
							{
								Remove-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $DatabaseName -Confirm:$false -ErrorAction Stop
								Invoke-sqmLogging -Message "Datenbank auf '$secondary' geloescht." -FunctionName $functionName -Level "INFO"
								$results += [PSCustomObject]@{ Action = "RemoveFromSecondary"; Target = $secondary; Status = "Success"; Message = "Datenbank auf sekundaerem Knoten geloescht." }
							}
							else
							{
								Invoke-sqmLogging -Message "Datenbank auf '$secondary' nicht vorhanden." -FunctionName $functionName -Level "VERBOSE"
							}
						}
						catch
						{
							$errMsg = "Fehler beim Loeschen auf '$secondary': $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{ Action = "RemoveFromSecondary"; Target = $secondary; Status = "Failed"; Message = $errMsg }
						}
					}
					else
					{
						$results += [PSCustomObject]@{ Action = "RemoveFromSecondary"; Target = $secondary; Status = "Skipped"; Message = "WhatIf - Loeschen uebersprungen." }
					}
				}
			}
			
			# ---- 5. Restore der Datenbank(en) ----
			$finalDbName = if ($NewDatabaseName) { $NewDatabaseName }
			else { $DatabaseName }
			$restoreCount = 0
			$totalFiles = $backupFileList.Count
			
			foreach ($file in $backupFileList)
			{
				$restoreCount++
				$isLast = ($restoreCount -eq $totalFiles)
				$useRecovery = if ($ContinueWithNoRecovery) { $false }
				elseif ($WithNoRecovery) { $false }
				else { $isLast }
				
				$restoreParams = @{
					SqlInstance   = $SqlInstance
					SqlCredential = $SqlCredential
					Path		  = $file
					DatabaseName  = $DatabaseName
					WithReplace   = $true
					NoRecovery    = (-not $useRecovery)
					ErrorAction   = 'Stop'
				}
				if ($NewDatabaseName)
				{
					$restoreParams.NewDatabaseName = $NewDatabaseName
				}
				if ($NewDatabaseFilePath)
				{
					$restoreParams.DatabaseFilePath = $NewDatabaseFilePath
				}
				if ($NewLogFilePath)
				{
					$restoreParams.LogFilePath = $NewLogFilePath
				}
				# Fuer alle ausser den ersten Restore (Full) muss der Datenbankname bereits existieren; fuer Log-Restores ist das wichtig
				# Restore-DbaDatabase kann sequenziell verarbeitet werden.
				
				# Auto-FileMapping: beim ersten Restore (Full) immer FileMapping aus RESTORE FILELISTONLY aufbauen.
				# Das verhindert Pfadkonflikte wenn das Backup bereits vorhandene Dateipfade enthaelt.
				if ($restoreCount -eq 1)
				{
					try
					{
						$safeFilePath = $file.Replace("'", "''")
						$backupFileListing = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
							-Database 'master' `
							-Query "RESTORE FILELISTONLY FROM DISK = N'$safeFilePath'" `
							-ErrorAction Stop

						if ($backupFileListing)
						{
							$defaultPaths = Get-DbaDefaultPath -SqlInstance $SqlInstance -SqlCredential $SqlCredential
							$dataDir = if ($NewDatabaseFilePath) { $NewDatabaseFilePath } else { $defaultPaths.Data }
							$logDir  = if ($NewLogFilePath)      { $NewLogFilePath }      else { $defaultPaths.Log }

							$fileMapping = @{}
							$logIdx = 0
							$datIdx = 0
							foreach ($backupFileEntry in $backupFileListing)
							{
								$ext   = [System.IO.Path]::GetExtension($backupFileEntry.PhysicalName)
								$isLog = ($backupFileEntry.Type -eq 'L')
								$dir   = if ($isLog) { $logDir } else { $dataDir }

								if ($isLog)
								{
									$logIdx++
									$sfx = if ($logIdx -eq 1) { '_log' } else { "_log$logIdx" }
								}
								else
								{
									$datIdx++
									$sfx = if ($datIdx -eq 1) { '' } else { "_$datIdx" }
								}

								$fileMapping[$backupFileEntry.LogicalName] = Join-Path $dir "$finalDbName$sfx$ext"
								Invoke-sqmLogging -Message "FileMapping: '$($backupFileEntry.LogicalName)' -> '$($fileMapping[$backupFileEntry.LogicalName])'" `
									-FunctionName $functionName -Level "INFO"
							}
							$restoreParams['FileMapping'] = $fileMapping
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "Auto-FileMapping fehlgeschlagen (wird uebersprungen): $($_.Exception.Message)" `
							-FunctionName $functionName -Level "WARNING"
					}
				}

				$restoreAction = "Restore von $file ($restoreCount/$totalFiles) fuer Datenbank '$DatabaseName'"
				if ($NewDatabaseName) { $restoreAction += " als '$NewDatabaseName'" }
				if (-not $useRecovery) { $restoreAction += " (NORECOVERY)" }
				
				if ($PSCmdlet.ShouldProcess($DatabaseName, $restoreAction))
				{
					try
					{
						Invoke-sqmLogging -Message $restoreAction -FunctionName $functionName -Level "INFO"
						$restoreResult = Restore-DbaDatabase @restoreParams
						Invoke-sqmLogging -Message "Restore von $file erfolgreich." -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "RestoreStep"; File = $file; Step = $restoreCount; Status = "Success"; Message = "Wiederhergestellt." }
					}
					catch
					{
						$errMsg = "Fehler beim Restore von $file : $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ Action = "RestoreStep"; File = $file; Step = $restoreCount; Status = "Failed"; Message = $errMsg }
						return $results
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "RestoreStep"; File = $file; Step = $restoreCount; Status = "Skipped"; Message = "WhatIf - Restore uebersprungen." }
					return $results
				}
			}
			
			# ---- 6. Nach dem Restore: User wiederherstellen (wenn Export durchgefuehrt) ----
			if (-not $NoUserExport -and (Test-Path $userExportFile))
			{
				$importAction = "Importiere User aus $userExportFile in Datenbank '$finalDbName'"
				if ($PSCmdlet.ShouldProcess($finalDbName, $importAction))
				{
					try
					{
						Invoke-sqmLogging -Message $importAction -FunctionName $functionName -Level "INFO"
						$sql = Get-Content $userExportFile -Raw
						Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $finalDbName -Query $sql -ErrorAction Stop
						Invoke-sqmLogging -Message "User-Import erfolgreich." -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "UserImport"; Status = "Success"; Message = "User aus Export wiederhergestellt." }
					}
					catch
					{
						$errMsg = "Fehler beim Import der User: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ Action = "UserImport"; Status = "Failed"; Message = $errMsg }
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "UserImport"; Status = "Skipped"; Message = "WhatIf - User-Import uebersprungen." }
				}
			}
			
			# ---- 7. Verwaiste User reparieren ----
			$orphanFixAction = "Repariere verwaiste User in Datenbank '$finalDbName'"
			if ($PSCmdlet.ShouldProcess($finalDbName, $orphanFixAction))
			{
				try
				{
					Invoke-sqmLogging -Message $orphanFixAction -FunctionName $functionName -Level "INFO"
					$repairResult = Repair-DbaDbOrphanUser -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $finalDbName -ErrorAction Stop
					$repairedCount = if ($repairResult) { @($repairResult).Count } else { 0 }
					Invoke-sqmLogging -Message "Verwaiste User repariert: $repairedCount." -FunctionName $functionName -Level "INFO"
					$results += [PSCustomObject]@{ Action = "FixOrphans"; Status = "Success"; Message = "Repair-DbaDbOrphanUser: $repairedCount User repariert." }
				}
				catch
				{
					$errMsg = "Fehler bei der Reparatur verwaister User: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
					$results += [PSCustomObject]@{ Action = "FixOrphans"; Status = "Failed"; Message = $errMsg }
				}
			}
			else
			{
				$results += [PSCustomObject]@{ Action = "FixOrphans"; Status = "Skipped"; Message = "WhatIf - Reparatur uebersprungen." }
			}
			
			# ---- 8. Domaenenfremde Accounts entfernen ----
			$removeOrphanLoginsAction = "Entferne nicht mehr existierende Windows-Logins aus Datenbank '$finalDbName'"
			if ($PSCmdlet.ShouldProcess($finalDbName, $removeOrphanLoginsAction))
			{
				try
				{
					Invoke-sqmLogging -Message $removeOrphanLoginsAction -FunctionName $functionName -Level "INFO"
					$query = @"
DECLARE @dbname sysname = DB_NAME();
SELECT dp.name AS UserName
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('U', 'G')
  AND sp.sid IS NULL
  AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
"@
					$missingLogins = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $finalDbName -Query $query -ErrorAction Stop
					foreach ($login in $missingLogins)
					{
						$userName = $login.UserName
						Invoke-sqmLogging -Message "Entferne Windows-User '$userName' (Login existiert nicht mehr)." -FunctionName $functionName -Level "DEBUG"
						$dropQuery = "DROP USER [$userName]"
						Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $finalDbName -Query $dropQuery -ErrorAction SilentlyContinue
					}
					Invoke-sqmLogging -Message "Nicht mehr existierende Windows-Logins wurden entfernt." -FunctionName $functionName -Level "INFO"
					$results += [PSCustomObject]@{ Action = "RemoveOrphanWindowsLogins"; Status = "Success"; Message = "Entfernt: $($missingLogins.Count) User." }
				}
				catch
				{
					$errMsg = "Fehler beim Entfernen nicht existierender Windows-Logins: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
					$results += [PSCustomObject]@{ Action = "RemoveOrphanWindowsLogins"; Status = "Failed"; Message = $errMsg }
				}
			}
			else
			{
				$results += [PSCustomObject]@{ Action = "RemoveOrphanWindowsLogins"; Status = "Skipped"; Message = "WhatIf - Entfernen uebersprungen." }
			}
			
			# ---- 9. 'sa' Konto als Datenbankeigentuemer setzen ----
			$setOwnerAction = "Setze sa-Konto (SID 0x01) als Datenbankeigentuemer fuer '$finalDbName'"
			if ($PSCmdlet.ShouldProcess($finalDbName, $setOwnerAction))
			{
				try
				{
					Invoke-sqmLogging -Message $setOwnerAction -FunctionName $functionName -Level "INFO"
					$saNameRow = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
						-Database 'master' `
						-Query "SELECT name FROM sys.server_principals WHERE sid = 0x01" `
						-ErrorAction Stop
					if (-not $saNameRow -or [string]::IsNullOrWhiteSpace($saNameRow.name))
					{
						throw "sa-Login (SID 0x01) nicht gefunden."
					}
					$saName = $saNameRow.name
					Set-DbaDbOwner -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $finalDbName -TargetLogin $saName -ErrorAction Stop
					Invoke-sqmLogging -Message "Datenbankeigentuemer auf '$saName' gesetzt." -FunctionName $functionName -Level "INFO"
					$results += [PSCustomObject]@{ Action = "SetDbOwner"; Status = "Success"; Message = "Eigentuemer: $saName" }
				}
				catch
				{
					$errMsg = "Fehler beim Setzen des Datenbankeigentuemers: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw }
					$results += [PSCustomObject]@{ Action = "SetDbOwner"; Status = "Failed"; Message = $errMsg }
				}
			}
			else
			{
				$results += [PSCustomObject]@{ Action = "SetDbOwner"; Status = "Skipped"; Message = "WhatIf - Setzen des Eigentuemers uebersprungen." }
			}
			
			# ---- 10. Optional: Datenbank wieder in die AG aufnehmen ----
			if ($RejoinAvailabilityGroup -and $isAGDatabase -and -not $KeepAlwaysOn)
			{
				$rejoinAction = "Fuge Datenbank '$finalDbName' wieder in AG '$($availabilityGroup.Name)' ein"
				if ($PSCmdlet.ShouldProcess($finalDbName, $rejoinAction))
				{
					try
					{
						Invoke-sqmLogging -Message $rejoinAction -FunctionName $functionName -Level "INFO"

						# Pruefe SeedingMode aller Sekundaer-Replikate  - stelle Automatic Seeding sicher
						$agReplicas = Get-DbaAgReplica -SqlInstance $primaryInstance -SqlCredential $SqlCredential `
							-AvailabilityGroup $availabilityGroup.Name -ErrorAction Stop

						foreach ($replica in ($agReplicas | Where-Object { $_.Role -eq 'Secondary' }))
						{
							if ($replica.SeedingMode -ne 'Automatic')
							{
								Invoke-sqmLogging -Message "Replikat '$($replica.Name)': SeedingMode ist '$($replica.SeedingMode)' - stelle auf Automatic um." `
									-FunctionName $functionName -Level "INFO"

								# Primary-Seite: Replikat auf Automatic Seeding umstellen
								Set-DbaAgReplica -SqlInstance $primaryInstance -SqlCredential $SqlCredential `
									-AvailabilityGroup $availabilityGroup.Name `
									-Replica $replica.Name `
									-SeedingMode Automatic -ErrorAction Stop

								# Secondary-Seite: GRANT CREATE ANY DATABASE
								Invoke-DbaQuery -SqlInstance $replica.Name -SqlCredential $SqlCredential `
									-Database master `
									-Query "ALTER AVAILABILITY GROUP [$($availabilityGroup.Name)] GRANT CREATE ANY DATABASE" `
									-ErrorAction SilentlyContinue

								Invoke-sqmLogging -Message "Replikat '$($replica.Name)' auf Automatic Seeding umgestellt." `
									-FunctionName $functionName -Level "INFO"
								$results += [PSCustomObject]@{ Action = "SetAutoSeeding"; Target = $replica.Name; Status = "Success"; Message = "SeedingMode auf Automatic gesetzt." }
							}
							else
							{
								Invoke-sqmLogging -Message "Replikat '$($replica.Name)': SeedingMode ist bereits Automatic." `
									-FunctionName $functionName -Level "INFO"
							}
						}

						# Datenbank zur AG hinzufuegen
						Add-DbaAgDatabase -SqlInstance $primaryInstance -SqlCredential $SqlCredential `
							-AvailabilityGroup $availabilityGroup.Name `
							-Database $finalDbName `
							-SeedingMode Automatic `
							-ErrorAction Stop

						Invoke-sqmLogging -Message "Datenbank '$finalDbName' erfolgreich in AG '$($availabilityGroup.Name)' aufgenommen." `
							-FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "RejoinAG"; Status = "Success"; Message = "Datenbank in AG '$($availabilityGroup.Name)' aufgenommen (Automatic Seeding)." }
					}
					catch
					{
						$errMsg = "Fehler beim Wiedereinfuegen in die AG: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ Action = "RejoinAG"; Status = "Failed"; Message = $errMsg }
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "RejoinAG"; Status = "Skipped"; Message = "WhatIf - AG-Wiedereinfuegen uebersprungen." }
				}
			}

			# Aufraeumen: temporaere Exportdatei loeschen
			if (Test-Path $userExportFile)
			{
				Remove-Item $userExportFile -Force -ErrorAction SilentlyContinue
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{ Action = "GlobalError"; Status = "Failed"; Message = $errMsg }
		}
		finally
		{
			# ---- Datenbank aus Single-User-Modus zuruecknehmen ----
			if ($wasSingleUser)
			{
				$setMultiUserAction = "Setze Datenbank '$finalDbName' zurueck in Multi-User-Modus"
				if ($PSCmdlet.ShouldProcess($finalDbName, $setMultiUserAction))
				{
					try
					{
						$multiUserQuery = "ALTER DATABASE [$finalDbName] SET MULTI_USER;"
						Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master -Query $multiUserQuery -ErrorAction Stop
						Invoke-sqmLogging -Message "Datenbank '$finalDbName' wieder im Multi-User-Modus." -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "SetMultiUser"; Status = "Success"; Message = "Datenbank wieder im Multi-User-Modus." }
					}
					catch
					{
						Invoke-sqmLogging -Message "Fehler beim Zuruecksetzen des Multi-User-Modus: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
						$results += [PSCustomObject]@{ Action = "SetMultiUser"; Status = "Failed"; Message = $_.Exception.Message }
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "SetMultiUser"; Status = "Skipped"; Message = "WhatIf - Multi-User uebersprungen." }
				}
			}
			
			# ---- Policy wiederherstellen ----
			if ($policyWasEnabled -and $policyDeactivated)
			{
				if ($PSCmdlet.ShouldProcess($SqlInstance, "Policy '$policyName' wieder aktivieren"))
				{
					Invoke-sqmLogging -Message "Aktiviere Policy '$policyName' wieder." -FunctionName $functionName -Level "INFO"
					Set-sqmSqlPolicyState -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Policy $policyName -State Enable -EnableException:$EnableException -Confirm:$false
					$results += [PSCustomObject]@{ Action = "PolicyReenable"; Status = "Success"; Message = "Policy '$policyName' wieder aktiviert." }
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "PolicyReenable"; Status = "Skipped"; Message = "WhatIf - Policy-Reaktivierung uebersprungen." }
				}
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Aktionen protokolliert." -FunctionName $functionName -Level "INFO"
		return $results
	}
}