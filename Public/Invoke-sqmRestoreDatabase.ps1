<#
.SYNOPSIS
Restores a database from a backup file, with support for single-server and AlwaysOn environments.

.DESCRIPTION
The function performs a controlled database restore. It automatically detects whether the target
database belongs to an AlwaysOn availability group and removes it from the AG if so (including
deletion on secondary replicas). By default, once the restore completes, the database is
automatically re-added to the AG (Add-DbaAgDatabase with SeedingMode Automatic), which also
reseeds the secondaries - use -NoRejoinAvailabilityGroup to leave it standalone instead. Database
users are exported before the restore (for later recovery). Optionally a backup of the original
database can be created. After the restore, users are recovered, orphaned users are repaired,
non-existent Windows logins are removed, and the database owner is set to the SA account
(regardless of its name).

The function can also restore a sequence of backups (Full + Diff + Logs) using the `-BackupFiles`
parameter, which accepts a list of backup files in the correct order (Full, then Diff, then Logs).

Before user export and before the restore, the configured PBM policy (DefaultPolicy) is
temporarily disabled to avoid restrictions during user creation. It is re-enabled after completion.

If the database is in use, it is automatically set to single-user mode after the user export
(and switched back to multi-user after the restore) - single-user is applied only after the
export, not before, since Export-DbaUser needs its own connection to the database and would
otherwise fail with "database is already open and can only have one user at a time". If the
database is already found in SINGLE_USER or RESTRICTED_USER mode when the function starts
(e.g. left over from a previous interrupted restore), it is immediately reset to MULTI_USER
(disconnecting whatever session was holding that one connection slot) before anything else runs -
otherwise every step needing its own connection, starting with Export-DbaUser, would fail the
same way.

AG-membership is normally auto-detected at the start of the run. If a previous run already
removed the database from the AG but failed before rejoining it (or crashed/was interrupted), a
retry would no longer auto-detect it as an AG database and would silently skip secondary cleanup
and rejoin/reseed entirely - a database restore for an AG database must never end up outside the
AG without a clear signal. Use `-AvailabilityGroupName` to force AG-aware handling regardless of
current live membership. Every rejoin attempt (success and failure) is additionally written to
the Windows Application Event Log (source "sqmAlwaysOn", same source as
Repair-sqmAlwaysOnDatabases) so a failed reseed is visible to monitoring even if the returned
result objects are never inspected.

Policy: every database on an AG-capable instance must end up on AlwaysOn - this applies even if
the database was NOT an AG member before the restore. If the database isn't currently in any AG
and `-AvailabilityGroupName` wasn't given, the instance's Availability Groups are checked: with
exactly one AG, the restored database is automatically added to it (with seeding); with zero AGs
there is nothing to join and it stays standalone; with more than one AG the run aborts, since it
would be ambiguous which AG should receive the database - `-AvailabilityGroupName` must be given
explicitly in that case. Use `-KeepAlwaysOn` to opt out of this auto-join for a database that
should genuinely stay standalone (e.g. a scratch/test restore), or `-NoRejoinAvailabilityGroup` to
still do the detection/logging but skip the actual join.

The rejoin itself runs in a `finally` block once the restore has actually completed, so it is
attempted even if a later, non-critical post-restore cleanup step (user re-import, orphan-user
repair, stale Windows-login removal, owner assignment) throws - including with -EnableException.
A database that was an AG member at the start of the run will never be left un-rejoined just
because one of those cleanup steps failed.

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
Optional. If the database is currently part of an AG, it is not removed from the AG - and since a
restore is not possible while still an AG member, the run aborts instead (only useful if the
database is actually already outside the AG despite -KeepAlwaysOn being set). If the database is
NOT currently an AG member, this switch instead opts it out of the automatic single-AG auto-join
described under AvailabilityGroupName below, leaving it standalone on purpose.

.PARAMETER AvailabilityGroupName
Optional: Explicitly declares which AG the database belongs to (or should end up in after the
restore), instead of relying solely on live AG-membership/instance detection at the start of the
run. Use this when the database was already removed from the AG by a previous, incompletely
finished run (so it is no longer auto-detected as an AG member), when restoring a brand-new
database straight into an existing AG, or when the instance has more than one AG (auto-detection
only works when there is exactly one). When set, the restore is always treated as AG-aware:
secondaries are cleaned up and the database is rejoined (with seeding) at the end, exactly as if
live detection had found it - regardless of whether the database is currently an AG member.

Policy note: even without this parameter, a database that is not currently in any AG will still
be added to the instance's AG automatically if the instance has exactly one - restoring a
database is not allowed to silently leave it standalone on an AG-capable instance. Use
-KeepAlwaysOn to opt out of that auto-join deliberately.

.PARAMETER WithNoRecovery
Optional: Performs the restore with NORECOVERY so the database remains in restoring state
(for additional log backups). By default RECOVERY is used (database online).

.PARAMETER ContinueWithNoRecovery
Optional: When set, the last restore is also performed with NORECOVERY (e.g. when
additional backups are to be applied manually).

.PARAMETER ForceSingleUser
Forces the database into single-user mode before the restore (even if no active connections
are detected). By default only switches when there are active connections.

.PARAMETER NoRejoinAvailabilityGroup
Optional: Whenever the function has determined the database should be AG-managed (it was already
an AG member, -AvailabilityGroupName was given, or the instance's single AG was auto-detected), it
is by default automatically (re-)added to that AG afterwards (Add-DbaAgDatabase with SeedingMode
Automatic, which also seeds the secondaries). Use this switch to suppress just the actual join/
rejoin while still doing the rest (secondary cleanup etc.), leaving the database outside the AG
after the restore.

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

.EXAMPLE
# Retry after a previous run already removed the database from the AG but did not get to
# rejoin it (crash, network blip, etc.) - the database is no longer auto-detected as an AG
# member, so force it explicitly to guarantee the secondaries get reseeded.
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\Arena.bak" -DatabaseName "Arena" -AvailabilityGroupName "AG_Prod"

.EXAMPLE
# "NewApp" was never an AG member. SQL01 has exactly one AG, so it is auto-detected and the
# restored database is automatically joined to it (with seeding) - no extra parameter needed.
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\NewApp.bak" -DatabaseName "NewApp"

.EXAMPLE
# Same as above, but this restore is a deliberate standalone scratch copy that must NOT join
# the instance's AG.
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\NewApp.bak" -DatabaseName "NewApp_scratch" -KeepAlwaysOn

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
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $false)]
		[switch]$WithNoRecovery,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueWithNoRecovery,
		[Parameter(Mandatory = $false)]
		[switch]$ForceSingleUser,
		[Parameter(Mandatory = $false)]
		[switch]$NoRejoinAvailabilityGroup,
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

		# Eventlog-Quelle fuer AG-relevante Aktionen (dieselbe Quelle wie Repair-sqmAlwaysOnDatabases,
		# damit Restore- und Repair-Vorgaenge im selben Event-Log-Kanal auftauchen). Ein fehlgeschlagenes
		# Rejoin/AutoSeed nach einem Restore ist eine kritische Betriebsstoerung und darf nicht nur im
		# sqmSQLTool-Log verschwinden, sondern muss ueber das Eventlog (Monitoring/Alerting) sichtbar sein.
		$agEventLogSource = "sqmAlwaysOn"
		if (-not [System.Diagnostics.EventLog]::SourceExists($agEventLogSource))
		{
			try { New-EventLog -LogName Application -Source $agEventLogSource -ErrorAction Stop }
			catch { Write-Verbose "Eventlog-Quelle '$agEventLogSource' konnte nicht erstellt werden: $($_.Exception.Message)" }
		}

		$results = @()
		$tempDir = [System.IO.Path]::GetTempPath()
		$userExportFile = Join-Path $tempDir "UserExport_${DatabaseName}_$(Get-Date -Format 'yyyyMMddHHmmss').sql"
		$isAGDatabase = $false
		$availabilityGroup = $null
		$primaryInstance = $null
		$secondaryInstances = @()
		$wasSingleUser = $false
		$originalDbStatus = $null
		$restoreSucceeded = $false
		# Sicherer Default, falls die Funktion vor Schritt 5 abbricht (z.B. Fehler bei AG-Entfernen)
		# und $wasSingleUser bereits true ist (z.B. durch die Bereits-Single-User-Normalisierung in
		# Schritt 1) - der finally-Block braucht fuer den MULTI_USER-Revert einen gueltigen Namen,
		# nicht $null. Schritt 5 ueberschreibt dies bei Bedarf mit $NewDatabaseName.
		$finalDbName = $DatabaseName

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

				# Datenbank kann bereits VOR diesem Aufruf in SINGLE_USER/RESTRICTED_USER stehen (z.B.
				# Rest eines vorherigen, abgebrochenen Restores oder manuell durch einen DBA gesetzt).
				# In dem Fall haelt eine fremde Session bereits den einzigen verfuegbaren Connection-Slot
				# - jeder eigene Connect (allen voran Export-DbaUser in Schritt 3, das eine eigene
				# SMO-Verbindung braucht) wuerde dann sofort mit "database is already open and can only
				# have one user at a time" fehlschlagen, noch bevor unser eigener Single-User-Schritt
				# (Schritt 3b) ueberhaupt drankommt. Deshalb hier sofort auf MULTI_USER zuruecksetzen
				# (WITH ROLLBACK IMMEDIATE wirft die fremde Session raus) - $wasSingleUser wird bereits
				# hier gesetzt, damit die Datenbank am Ende garantiert wieder MULTI_USER ist, auch wenn
				# Schritt 3b selbst keinen Grund mehr sieht, aktiv zu werden.
				$originalDbStatus = $targetDb.UserAccess
				if ($originalDbStatus -ne [Microsoft.SqlServer.Management.Smo.DatabaseUserAccess]::Multiple)
				{
					$normalizeAction = "Datenbank '$DatabaseName' ist bereits im Modus '$originalDbStatus' - setze auf MULTI_USER zurueck (fremde Session wird getrennt)"
					Invoke-sqmLogging -Message $normalizeAction -FunctionName $functionName -Level "WARNING"
					if ($PSCmdlet.ShouldProcess($DatabaseName, $normalizeAction))
					{
						try
						{
							Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master `
								-Query "ALTER DATABASE [$DatabaseName] SET MULTI_USER WITH ROLLBACK IMMEDIATE;" -ErrorAction Stop
							$wasSingleUser = $true
							$targetDb.Refresh()
							Invoke-sqmLogging -Message "Datenbank '$DatabaseName' auf MULTI_USER zurueckgesetzt." -FunctionName $functionName -Level "INFO"
							$results += [PSCustomObject]@{ Action = "NormalizeToMultiUser"; Status = "Success"; Message = "War '$originalDbStatus', auf MULTI_USER zurueckgesetzt." }
						}
						catch
						{
							$errMsg = "Fehler beim Zuruecksetzen auf MULTI_USER: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{ Action = "NormalizeToMultiUser"; Status = "Failed"; Message = $errMsg }
							return
						}
					}
					else
					{
						$results += [PSCustomObject]@{ Action = "NormalizeToMultiUser"; Status = "Skipped"; Message = "WhatIf - Zuruecksetzen uebersprungen." }
					}
				}

				# Aktive Verbindungen hier nur ermitteln (fuer spaeteren Single-User-Schritt) - NICHT
				# schon jetzt in Single-User versetzen, das muss erst NACH dem User-Export (Schritt 3)
				# passieren (siehe dort).
				$activeConnections = $targetDb.ActiveConnections
			}
			else
			{
				Invoke-sqmLogging -Message "Datenbank '$DatabaseName' existiert nicht auf $SqlInstance." -FunctionName $functionName -Level "INFO"
			}

			# Pruefen, ob die Datenbank in einer AG ist. Laeuft UNABHAENGIG von $dbExists: eine
			# Datenbank, die unter diesem Namen auf der Instanz noch nie existiert hat (Erst-Restore
			# einer neuen Anwendung), muss der Richtlinie "alle Datenbanken muessen in AlwaysOn sein"
			# genauso unterliegen wie eine bereits vorhandene, standalone Datenbank.
			# WICHTIG: Get-DbaAvailabilityGroup hat KEINEN -Database-Parameter. Ein -Database loest einen
			# terminierenden Parameter-Binding-Fehler aus, den -ErrorAction SilentlyContinue NICHT abfaengt.
			# Daher Mitgliedschaft ueber Get-DbaAgDatabase pruefen und das AG-Objekt (mit .Name) anschliessend
			# ueber den AG-Namen nachladen.
			$agDbCheck = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $DatabaseName -ErrorAction SilentlyContinue
			if ($agDbCheck)
			{
				$isAGDatabase = $true
				$agName = ($agDbCheck | Select-Object -First 1).AvailabilityGroup
				if ($AvailabilityGroupName -and $AvailabilityGroupName -ne $agName)
				{
					Invoke-sqmLogging -Message "Hinweis: -AvailabilityGroupName '$AvailabilityGroupName' weicht von der live erkannten AG '$agName' ab - verwende die live erkannte AG." -FunctionName $functionName -Level "WARNING"
				}
				$availabilityGroup = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $agName -ErrorAction SilentlyContinue
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
			elseif ($AvailabilityGroupName)
			{
				# Datenbank ist AKTUELL kein AG-Mitglied (z.B. weil ein vorheriger, unvollstaendig
				# abgeschlossener Lauf sie bereits aus der AG entfernt hat), aber der Aufrufer hat
				# explizit angegeben, dass sie zur AG gehoert/gehoeren soll. Ohne diesen Parameter
				# wuerde die Funktion die AG-Zugehoerigkeit hier NICHT mehr erkennen und den Rest
				# des Laufs (Secondary-Cleanup, Rejoin/Reseed am Ende) stillschweigend ueberspringen -
				# genau das darf bei einer AG-Datenbank nie passieren.
				$availabilityGroup = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $AvailabilityGroupName -ErrorAction SilentlyContinue
				if (-not $availabilityGroup)
				{
					throw "Availability Group '$AvailabilityGroupName' wurde auf '$SqlInstance' nicht gefunden."
				}
				$isAGDatabase = $true
				Invoke-sqmLogging -Message "Datenbank ist aktuell KEIN Mitglied der AG '$AvailabilityGroupName' (vermutlich bereits entfernt), wird aber laut -AvailabilityGroupName als AG-Datenbank behandelt: Secondary-Cleanup und Rejoin/Reseed werden trotzdem durchgefuehrt." -FunctionName $functionName -Level "WARNING"
			}
			elseif (-not $KeepAlwaysOn)
			{
				# Datenbank ist aktuell in KEINER AG (existierte evtl. noch nie unter diesem Namen)
				# und der Aufrufer hat keine AG explizit angegeben. Unternehmensrichtlinie: JEDE
				# Datenbank auf einer Instanz mit AG muss in AlwaysOn sein - ein Restore darf niemals
				# stillschweigend eine standalone Datenbank zuruecklassen, wenn die Instanz eine AG
				# hat (das gilt auch fuer den allerersten Restore einer neuen Anwendung). Hat die
				# Instanz genau EINE AG, wird diese automatisch verwendet. Bei 0 AGs gibt es nichts
				# beizutreten (z.B. Non-Cluster-Instanz) - bleibt standalone. Bei 2+ AGs ist die
				# Zuordnung nicht eindeutig - Abbruch, -AvailabilityGroupName muss explizit angegeben
				# werden.
				$instanceAgs = @(Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction SilentlyContinue)
				if ($instanceAgs.Count -eq 1)
				{
					$availabilityGroup = $instanceAgs[0]
					$isAGDatabase = $true
					Invoke-sqmLogging -Message "Datenbank ist aktuell in keiner AG, Instanz hat aber genau eine AG '$($availabilityGroup.Name)' - wird nach dem Restore automatisch dieser AG hinzugefuegt (Richtlinie: alle Datenbanken muessen in AlwaysOn sein)." -FunctionName $functionName -Level "WARNING"
				}
				elseif ($instanceAgs.Count -gt 1)
				{
					$agNames = ($instanceAgs | Select-Object -ExpandProperty Name) -join ', '
					Invoke-sqmLogging -Message "Datenbank ist in keiner AG und Instanz '$SqlInstance' hat mehrere AGs ($agNames) - nicht eindeutig, welche AG die Datenbank erhalten soll." -FunctionName $functionName -Level "ERROR"
					throw "Instanz '$SqlInstance' hat mehrere Availability Groups ($agNames). Bitte -AvailabilityGroupName explizit angeben."
				}
				else
				{
					Invoke-sqmLogging -Message "Datenbank ist in keiner AG und Instanz '$SqlInstance' hat keine Availability Group - Datenbank bleibt standalone." -FunctionName $functionName -Level "INFO"
				}
			}

			# ---- 2. Optional: Backup der vorhandenen Datenbank ----
			if ($BackupBeforeRestore -and $dbExists -and -not $isAGDatabase)
			{
				$backupFileName = "${DatabaseName}_preRestore_$(Get-Date -Format 'yyyyMMdd_HHmsqm').bak"
				$backupFileFull = Join-Path (Get-DbaDefaultPath -SqlInstance $SqlInstance -SqlCredential $SqlCredential).Backup $backupFileName
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
						return
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
						Export-DbaUser -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $DatabaseName -FilePath $userExportFile -ErrorAction Stop
						Invoke-sqmLogging -Message "User-Export erfolgreich." -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{ Action = "UserExport"; Status = "Success"; Message = "Exportdatei: $userExportFile" }
					}
					catch
					{
						$errMsg = "Fehler beim Export der User: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ Action = "UserExport"; Status = "Failed"; Message = $errMsg }
						return
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "UserExport"; Status = "Skipped"; Message = "WhatIf - User-Export uebersprungen." }
				}
			}

			# ---- 3b. Datenbank in Single-User-Modus versetzen, falls noetig ----
			# WICHTIG: Muss NACH dem User-Export (Schritt 3) laufen, nicht davor. Export-DbaUser
			# oeffnet fuer das Scripting der Objekt-/Berechtigungs-DDL eine eigene SMO-Verbindung zur
			# Datenbank; laeuft die Datenbank zu diesem Zeitpunkt schon in SINGLE_USER, schlaegt dieser
			# zweite Connect mit "Database '<db>' is already open and can only have one user at a
			# time" fehl (Export-DbaUser faengt den Fehler intern ab und meldet ihn nur als WARNING,
			# der Export bricht dann aber unvollstaendig/leer ab).
			if ($dbExists -and ($activeConnections -gt 0 -or $ForceSingleUser))
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
						return
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "SetSingleUser"; Status = "Skipped"; Message = "WhatIf - Single-User uebersprungen." }
				}
			}
			elseif ($dbExists)
			{
				Invoke-sqmLogging -Message "Datenbank '$DatabaseName' hat keine aktiven Verbindungen." -FunctionName $functionName -Level "INFO"
			}

			# ---- 4. Wenn AlwaysOn: Datenbank aus der AG entfernen (primaer) und von sekundaeren Replikaten loeschen ----
			if ($isAGDatabase -and -not $KeepAlwaysOn)
			{
				$replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $availabilityGroup.Name -ErrorAction Stop
				$primaryReplica = $replicas | Where-Object { $_.Role -eq 'Primary' } | Select-Object -First 1
				$secondaryReplicas = $replicas | Where-Object { $_.Role -eq 'Secondary' }
				$secondaryInstances = $secondaryReplicas | Select-Object -ExpandProperty Name

				# WICHTIG: Wenn $primaryReplica nicht ermittelt werden konnte (z.B. Role-Werte aus
				# Get-DbaAgReplica passen aus irgendeinem Grund nicht zu 'Primary', AG gerade im
				# Failover), darf $primaryInstance NIEMALS $null werden - das fuehrt spaeter (u.a. im
				# Rejoin-Schritt im finally-Block) zu "Cannot bind parameter 'SqlInstance' because it
				# is null". Fallback auf die verbundene Instanz, mit deutlicher Warnung im Log.
				if (-not $primaryReplica -or -not $primaryReplica.Name)
				{
					Invoke-sqmLogging -Message "Primaere Replica der AG '$($availabilityGroup.Name)' konnte nicht eindeutig ermittelt werden (Role='Primary' nicht gefunden) - falle zurueck auf verbundene Instanz '$SqlInstance'. Falls das nicht die tatsaechliche Primary ist, schlagen nachfolgende AG-Schreiboperationen mit einer aussagekraeftigen Fehlermeldung fehl." -FunctionName $functionName -Level "WARNING"
					$primaryInstance = $SqlInstance
				}
				elseif ($primaryReplica.Name -ne $SqlInstance)
				{
					Invoke-sqmLogging -Message "Aktuelle Instanz ist nicht primaer. Verbinde mit primaerer Instanz $($primaryReplica.Name) fuer AG-Operationen." -FunctionName $functionName -Level "INFO"
					$primaryInstance = $primaryReplica.Name
				}
				else
				{
					$primaryInstance = $SqlInstance
				}
				
				if (-not $agDbCheck)
				{
					# Ueber -AvailabilityGroupName erzwungen: Datenbank ist bereits kein AG-Mitglied mehr
					# (z.B. Rest eines vorherigen, abgebrochenen Laufs) - nichts zu entfernen, aber
					# Secondary-Cleanup und Rejoin/Reseed unten laufen trotzdem weiter.
					Invoke-sqmLogging -Message "Datenbank ist aktuell kein AG-Mitglied mehr - AG-Entfernen wird uebersprungen." -FunctionName $functionName -Level "INFO"
					$results += [PSCustomObject]@{ Action = "RemoveFromAG"; Status = "NotNeeded"; Message = "Datenbank war zu Laufbeginn bereits kein AG-Mitglied mehr." }
				}
				else
				{
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
							Write-EventLog -LogName Application -Source $agEventLogSource -EventId 9010 -EntryType Error `
								-Message "Invoke-sqmRestoreDatabase: Entfernen von '$DatabaseName' aus AG '$($availabilityGroup.Name)' auf '$primaryInstance' fehlgeschlagen: $errMsg" -ErrorAction SilentlyContinue
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{ Action = "RemoveFromAG"; Status = "Failed"; Message = $errMsg }
							return
						}
					}
					else
					{
						$results += [PSCustomObject]@{ Action = "RemoveFromAG"; Status = "Skipped"; Message = "WhatIf - Entfernen aus AG uebersprungen." }
					}
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
					DatabaseName  = $finalDbName
					WithReplace   = $true
					NoRecovery    = (-not $useRecovery)
					ErrorAction   = 'Stop'
				}
				# Hinweis: Restore-DbaDatabase kennt KEINE Parameter -NewDatabaseName/-DatabaseFilePath/-LogFilePath.
				# Der Zielname (auch ein neuer) wird ueber -DatabaseName ($finalDbName) gesetzt; die physischen
				# Datei-Namen/-Pfade regelt das weiter unten aufgebaute -FileMapping (nutzt NewDatabaseFilePath/
				# NewLogFilePath als Zielverzeichnisse). Damit sind Umbenennen + Verschieben versionsstabil abgedeckt.
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
						return
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "RestoreStep"; File = $file; Step = $restoreCount; Status = "Skipped"; Message = "WhatIf - Restore uebersprungen." }
					return
				}
			}

			# Ab hier ist die Datenbank tatsaechlich wiederhergestellt. Der AG-Rejoin (siehe finally-
			# Block) darf danach durch nichts mehr verhindert werden - auch nicht durch einen mit
			# -EnableException durchgereichten Fehler in einem der folgenden (nicht-kritischen)
			# Aufraeumschritte 6-9.
			$restoreSucceeded = $true

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
			
			# AG-Rejoin (Schritt 10) laeuft NICHT mehr hier, sondern im finally-Block weiter unten -
			# damit er garantiert ausgefuehrt wird, auch wenn einer der nachfolgenden (nicht-kritischen)
			# Aufraeumschritte 6-9 mit -EnableException eine Ausnahme durchreicht. Siehe dort.

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
			# ---- 10. Datenbank wieder in die AG aufnehmen (inkl. Seeding der Secondaries) ----
			# Laeuft bewusst im finally-Block: sobald der Restore selbst erfolgreich war
			# ($restoreSucceeded), MUSS der Rejoin versucht werden - auch wenn einer der
			# nachfolgenden (nicht-kritischen) Aufraeumschritte 6-9 mit -EnableException eine
			# Ausnahme durchgereicht hat. finally laeuft in PowerShell garantiert, selbst wenn im
			# try/catch ein throw weitergereicht wurde. War $restoreSucceeded nie true (Restore
			# selbst fehlgeschlagen/uebersprungen), wird hier bewusst NICHT versucht, eine
			# moeglicherweise kaputte/nicht vorhandene Datenbank in die AG aufzunehmen.
			#
			# Standardverhalten: eine Datenbank, die aus einer AG entfernt wurde, wird nach dem
			# Restore automatisch wieder aufgenommen, damit die Secondaries per Automatic Seeding
			# neu versorgt werden - sonst bleiben sie nach einem AG-Restore ohne diese Datenbank
			# zurueck. Mit -NoRejoinAvailabilityGroup kann das explizit unterdrueckt werden (z.B. um
			# den Restore erst zu verifizieren, bevor die AG manuell wieder aufgebaut wird).
			Invoke-sqmLogging -Message "AG-Status vor Rejoin-Entscheidung: IsAGDatabase=$isAGDatabase, RestoreSucceeded=$restoreSucceeded, KeepAlwaysOn=$($KeepAlwaysOn.IsPresent), NoRejoinAvailabilityGroup=$($NoRejoinAvailabilityGroup.IsPresent), AvailabilityGroup='$($availabilityGroup.Name)'." -FunctionName $functionName -Level "INFO"

			if ($isAGDatabase -and $restoreSucceeded -and -not $KeepAlwaysOn -and $NoRejoinAvailabilityGroup)
			{
				$skipMsg = "Datenbank '$finalDbName' war Teil der AG '$($availabilityGroup.Name)', wird wegen -NoRejoinAvailabilityGroup NICHT wieder aufgenommen - Secondaries bleiben ohne diese Datenbank zurueck."
				Invoke-sqmLogging -Message $skipMsg -FunctionName $functionName -Level "WARNING"
				$results += [PSCustomObject]@{ Action = "RejoinAG"; Status = "SkippedByRequest"; Message = $skipMsg }
			}

			if ($isAGDatabase -and $restoreSucceeded -and -not $KeepAlwaysOn -and -not $NoRejoinAvailabilityGroup)
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
						Write-EventLog -LogName Application -Source $agEventLogSource -EventId 9011 -EntryType Information `
							-Message "Invoke-sqmRestoreDatabase: '$finalDbName' nach Restore wieder in AG '$($availabilityGroup.Name)' aufgenommen (Automatic Seeding der Secondaries gestartet)." -ErrorAction SilentlyContinue
						$results += [PSCustomObject]@{ Action = "RejoinAG"; Status = "Success"; Message = "Datenbank in AG '$($availabilityGroup.Name)' aufgenommen (Automatic Seeding)." }
					}
					catch
					{
						$errMsg = "Fehler beim Wiedereinfuegen in die AG: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						# Diese Meldung geht IMMER ins Eventlog (unabhaengig von -EnableException) - eine
						# nach dem Restore ausserhalb der AG zuruecktbleibende Datenbank (Secondaries ohne
						# Daten) ist eine kritische Betriebsstoerung und darf nicht nur im sqmSQLTool-Log
						# verschwinden, wenn niemand $results manuell prueft.
						Write-EventLog -LogName Application -Source $agEventLogSource -EventId 9012 -EntryType Error `
							-Message "Invoke-sqmRestoreDatabase: '$finalDbName' konnte nach dem Restore NICHT wieder in AG '$($availabilityGroup.Name)' aufgenommen werden - Secondaries erhalten diese Datenbank NICHT automatisch. Fehler: $errMsg" -ErrorAction SilentlyContinue
						# Bewusst KEIN erneutes throw hier, selbst mit -EnableException: dies laeuft im
						# finally-Block, ein throw hier wuerde eine evtl. bereits laufende Exception-
						# Weiterleitung aus dem try/catch ueberschreiben/verschlucken. Fehlschlag ist im
						# Eventlog und in $results sichtbar.
						$results += [PSCustomObject]@{ Action = "RejoinAG"; Status = "Failed"; Message = $errMsg }
					}
				}
				else
				{
					$results += [PSCustomObject]@{ Action = "RejoinAG"; Status = "Skipped"; Message = "WhatIf - AG-Wiedereinfuegen uebersprungen." }
				}
			}

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