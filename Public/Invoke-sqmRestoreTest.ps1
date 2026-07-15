<#
.SYNOPSIS
Performs an auditable restore test: restores a database under a test name and documents success,
data volume, throughput and duration as TXT and HTML report.

.DESCRIPTION
Restores a backup into a NEW test database (never over the original) and measures the restore.
Intended as evidence for recurring restore-test obligations ("Nachweis Restore-Test"): the report
documents whether the restore succeeded, how much data was restored, how long it took and which
throughput was achieved.

This function deliberately does NOT handle AlwaysOn. A restore test creates a throwaway copy; such
a copy must never be joined to an availability group. Use Invoke-sqmRestoreDatabase for productive,
AG-aware restores.

Determining the backup: -BackupFile is optional. Without it the newest FULL backup is looked up,
first from the msdb backup history (Get-DbaDbBackupHistory), and if that yields nothing, by
scanning the backup directory on the instance. This is what makes a recurring restore test work
with Ola Hallengren: Ola timestamps every backup file, so a fixed path would break after the next
backup run. The msdb history is preferred because it reports the path SQL Server actually wrote -
independent of Ola's @DirectoryStructure/@FileName, which are configurable and often deviate from
the default. The scan exists for the cases msdb cannot answer: Ola's own sp_delete_backuphistory
job purges the history, and a test running on a different instance than the backup has no history
at all. Use -IncludeChain to restore the full chain instead of just the newest full backup.

Which backup was used, and how it was found, is recorded in the evidence (BackupSource:
BackupHistory, DirectoryScan or Parameter) - an auditor must be able to see which backup the
measurement refers to.

Safety model - a restore test must never destroy existing data:

1. The target database name must start with "RestoreTest_" (see -TestDatabaseName). Any other name
   is rejected before a connection is even opened. This makes every test database recognisable as
   disposable, both for this function and for whoever looks at the instance later.
2. The target name must differ from the source database name.
3. If the target database already exists, the run aborts - UNLESS -AllowReplaceExistingTestDatabase
   is given explicitly. Only then (and only for a "RestoreTest_"-prefixed name) is the restore
   performed WITH REPLACE.
4. If the target does not exist, the restore runs WITHOUT REPLACE, so SQL Server itself refuses to
   overwrite anything should the name unexpectedly be taken.
5. Physical files are renamed after the test database (-ReplaceDbNameInFile), so the restore can
   never write over the source database's data files.

The test database is KEPT by default, because customers frequently want to run their own checks
against the restored copy. Use -RemoveTestDatabase to drop it once the measurement is done. The
drop is itself guarded by the "RestoreTest_" prefix.

Duration and throughput are measured as wall-clock time around the restore call, not taken from
dbatools' DatabaseRestoreTime: that value is only accurate to whole seconds and would report a
grossly inflated throughput for short restores. The SQL-reported value is still carried in the
result object as SqlReportedRestoreTime for reference.

Data volume is reported as BackupSize (the logical size of the backup), formatted automatically as
MB/GB/TB depending on magnitude. For compressed backups CompressedBackupSize (the physically read
bytes) is reported alongside it, since the two differ substantially and the distinction matters
when the throughput figure is questioned.

.PARAMETER SqlInstance
SQL Server instance to restore on. Default: current computer name.

.PARAMETER SqlCredential
Alternative credentials for the target instance.

.PARAMETER BackupFile
Path(s) to the backup file(s), readable by the target instance. Accepts a single .bak, a striped
set, or a full chain (Full + Diff + Logs) - dbatools determines the correct restore order itself.

OPTIONAL: omit it and the newest full backup is determined automatically - see DESCRIPTION. For
Ola Hallengren environments always omit it; every Ola backup carries a timestamp in its name, so a
fixed path is stale after the next backup run (and possibly already deleted by Ola's @CleanupTime).

.PARAMETER IncludeChain
Restore the whole chain needed to reach the most recent point in time (last full + last diff + the
log backups after it) instead of just the newest full backup. Only works via the msdb history: the
LSN relationship between backups cannot be read off file names, so the directory-scan fallback can
only ever return a full backup.

.PARAMETER BackupRootPath
Root directory for the directory-scan fallback. Default: module configuration "BackupDirectory",
otherwise the instance's default backup directory. Ignored when -BackupFile is given or when the
msdb history already answered.

.PARAMETER DatabaseName
Name of the source database as it appears in the backup. Used for the default test name and for
the report.

.PARAMETER TestDatabaseName
Optional: name of the test database. Must start with "RestoreTest_".
Default: "RestoreTest_<DatabaseName>_<yyyyMMdd_HHmm>".

.PARAMETER DataFilePath
Optional: target directory for the data files (.mdf/.ndf). Default: instance default data path.

.PARAMETER LogFilePath
Optional: target directory for the log file (.ldf). Default: instance default log path.

.PARAMETER RemoveTestDatabase
Optional: drops the test database after the measurement. By default the test database is kept so
it can be inspected or tested against.

.PARAMETER AllowReplaceExistingTestDatabase
Optional: allows an EXISTING test database to be overwritten. Only ever applies to names starting
with "RestoreTest_"; a non-test database is never overwritten regardless of this switch.

.PARAMETER OutputPath
Directory for the TXT/HTML reports. Default: the "RestoreTest" subfolder of the module's configured
output path (Get-sqmDefaultOutputPath), i.e. C:\System\WinSrvLog\MSSQL\RestoreTest by default.
Restore-test evidence accumulates over years, so it gets its own subfolder instead of mixing into
the general report directory. The directory is created if it does not exist.

.PARAMETER RetentionMonths
Number of months restore-test evidence is kept in -OutputPath. Older TXT/HTML reports are deleted
after the current report has been written. Default: the module configuration key
"RestoreTestRetentionMonths" (12 months out of the box); 0 disables the cleanup and keeps evidence
forever.

Only files matching this function's own report naming pattern ("RestoreTest_*.txt"/"RestoreTest_*.html")
are ever considered, so pointing -OutputPath at a shared directory cannot delete unrelated files.

.PARAMETER OutputHtml
Also write an HTML report (default: $true).

.PARAMETER NoOpen
Do not open the report automatically after creation.

.PARAMETER EnableException
Throw exceptions instead of returning a failure result object.

.EXAMPLE
# Ola environment: newest full backup is determined automatically (msdb, scan as fallback).
# This is the normal case - test database is kept for further checks.
Invoke-sqmRestoreTest -SqlInstance "SQL01" -DatabaseName "Kunde"

.EXAMPLE
# Restore the whole chain (last full + diff + subsequent logs) instead of just the full backup
Invoke-sqmRestoreTest -SqlInstance "SQL01" -DatabaseName "Kunde" -IncludeChain

.EXAMPLE
# Explicit backup file (no lookup)
Invoke-sqmRestoreTest -SqlInstance "SQL01" -BackupFile "D:\Backup\Kunde_Full.bak" -DatabaseName "Kunde"

.EXAMPLE
# Restore test with cleanup, report to a share, no auto-open (e.g. from an Agent job)
Invoke-sqmRestoreTest -SqlInstance "SQL01" -BackupFile "D:\Backup\Kunde_Full.bak" -DatabaseName "Kunde" `
    -RemoveTestDatabase -OutputPath "\\srv\Nachweise" -NoOpen

.EXAMPLE
# Restore test over a full chain, files onto a dedicated test volume
Invoke-sqmRestoreTest -SqlInstance "SQL01" -DatabaseName "Kunde" `
    -BackupFile @("D:\Backup\Full.bak", "D:\Backup\Diff.bak", "D:\Backup\Log1.trn") `
    -DataFilePath "T:\RestoreTest" -LogFilePath "T:\RestoreTest"

.EXAMPLE
# Repeat a test into the same test database (allowed - name carries the RestoreTest_ prefix)
Invoke-sqmRestoreTest -SqlInstance "SQL01" -BackupFile "D:\Backup\Kunde_Full.bak" -DatabaseName "Kunde" `
    -TestDatabaseName "RestoreTest_Kunde_Woche27" -AllowReplaceExistingTestDatabase

.NOTES
Requires dbatools, Invoke-sqmLogging, Get-sqmConfig.
No AlwaysOn handling by design - see DESCRIPTION.
#>
function Invoke-sqmRestoreTest
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$BackupFile,
		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeChain,
		[Parameter(Mandatory = $false)]
		[string]$BackupRootPath,
		[Parameter(Mandatory = $false)]
		[string]$TestDatabaseName,
		[Parameter(Mandatory = $false)]
		[string]$DataFilePath,
		[Parameter(Mandatory = $false)]
		[string]$LogFilePath,
		[Parameter(Mandatory = $false)]
		[switch]$RemoveTestDatabase,
		[Parameter(Mandatory = $false)]
		[switch]$AllowReplaceExistingTestDatabase,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'RestoreTest'),
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1200)]
		[int]$RetentionMonths = -1,
		[Parameter(Mandatory = $false)]
		[switch]$OutputHtml = $true,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# Namenskonvention fuer Test-Datenbanken. Der Praefix ist die tragende Sicherheitsgrenze
		# dieser Funktion: nur Datenbanken mit diesem Praefix duerfen ueberschrieben oder geloescht
		# werden. Bewusst als Konstante und NICHT ueber Get-sqmConfig konfigurierbar - eine
		# verstellbare Einstellung waere ein verstellbarer Schutz.
		$restoreTestPrefix = 'RestoreTest_'

		# Aufbewahrung: Parameter schlaegt Konfiguration schlaegt Default (12 Monate).
		# Der Sentinel -1 steht fuer "nicht angegeben" - Defaultwerte im param-Block werden von
		# ValidateRange nicht geprueft, ein explizites -RetentionMonths -1 dagegen schon.
		if (-not $PSBoundParameters.ContainsKey('RetentionMonths'))
		{
			$cfgRetention = Get-sqmConfig -Key 'RestoreTestRetentionMonths' 3>$null
			$RetentionMonths = if ($null -ne $cfgRetention -and $cfgRetention -match '^\d+$') { [int]$cfgRetention } else { 12 }
		}

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
	}

	process
	{
		$startTime = Get-Date

		# --- Zielname bestimmen -------------------------------------------------------------
		if ([string]::IsNullOrWhiteSpace($TestDatabaseName))
		{
			$TestDatabaseName = "$restoreTestPrefix${DatabaseName}_$(Get-Date -Format 'yyyyMMdd_HHmm')"
		}

		# --- Guard 1: Praefix ---------------------------------------------------------------
		# Ein Restore-Test darf ausschliesslich in eine als Wegwerf-Kopie erkennbare Datenbank
		# schreiben. Alles andere wird abgelehnt, bevor ueberhaupt eine Verbindung aufgebaut wird.
		if (-not $TestDatabaseName.StartsWith($restoreTestPrefix, [System.StringComparison]::OrdinalIgnoreCase))
		{
			$errMsg = "Zieldatenbank '$TestDatabaseName' beginnt nicht mit '$restoreTestPrefix'. " +
					  "Ein Restore-Test schreibt ausschliesslich in Datenbanken mit diesem Praefix, " +
					  "damit produktive Datenbanken nicht ueberschrieben werden koennen."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw $errMsg }
			return [PSCustomObject]@{
				SqlInstance = $SqlInstance; SourceDatabase = $DatabaseName; TestDatabase = $TestDatabaseName
				Success = $false; Status = 'Rejected'; Message = $errMsg
			}
		}

		# --- Guard 2: Zielname darf nicht die Quelle sein -----------------------------------
		# Greift, wenn die Quelldatenbank selbst schon 'RestoreTest_...' heisst (Test eines Tests).
		if ($TestDatabaseName -eq $DatabaseName)
		{
			$errMsg = "Zieldatenbank '$TestDatabaseName' ist identisch mit der Quelldatenbank. " +
					  "Ein Restore-Test darf die Quelle nicht ueberschreiben."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw $errMsg }
			return [PSCustomObject]@{
				SqlInstance = $SqlInstance; SourceDatabase = $DatabaseName; TestDatabase = $TestDatabaseName
				Success = $false; Status = 'Rejected'; Message = $errMsg
			}
		}

		try
		{
			Invoke-sqmLogging -Message "Starte $functionName auf '$SqlInstance': '$DatabaseName' -> '$TestDatabaseName'" `
				-FunctionName $functionName -Level "INFO"

			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop

			# --- Guard 3: existiert das Ziel bereits? --------------------------------------
			$existingDb = Get-DbaDatabase -SqlInstance $server -Database $TestDatabaseName -ErrorAction SilentlyContinue
			$useReplace = $false

			if ($existingDb)
			{
				if (-not $AllowReplaceExistingTestDatabase)
				{
					$errMsg = "Zieldatenbank '$TestDatabaseName' existiert bereits auf '$SqlInstance'. " +
							  "Abbruch ohne Aenderung. Mit -AllowReplaceExistingTestDatabase wird sie ueberschrieben, " +
							  "oder einen anderen -TestDatabaseName waehlen."
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $errMsg }
					return [PSCustomObject]@{
						SqlInstance = $server.Name; SourceDatabase = $DatabaseName; TestDatabase = $TestDatabaseName
						Success = $false; Status = 'Aborted'; Message = $errMsg
					}
				}

				# Nur hier - vorhandene Test-DB + ausdrueckliche Freigabe - wird REPLACE gesetzt.
				# Der Praefix ist an dieser Stelle bereits durch Guard 1 sichergestellt.
				$useReplace = $true
				Invoke-sqmLogging -Message "Zieldatenbank '$TestDatabaseName' existiert und wird auf ausdrueckliche Anforderung ueberschrieben (WITH REPLACE)." `
					-FunctionName $functionName -Level "WARNING"
			}

			# --- Backupdatei(en) bestimmen -------------------------------------------------
			# Ohne -BackupFile wird die Sicherung selbst ermittelt. Das ist der Normalfall fuer
			# Ola-Umgebungen: dort traegt jede Sicherung einen Zeitstempel im Namen, ein fest
			# angegebener Pfad waere nach dem naechsten Backup-Lauf veraltet (und mit Olas
			# @CleanupTime womoeglich schon geloescht).
			$backupSource = 'Parameter'
			$sourceInfo = $null
			if (-not $BackupFile -or $BackupFile.Count -eq 0)
			{
				$discovered = Get-sqmRestoreTestBackupSource -Server $server -DatabaseName $DatabaseName `
					-IncludeChain:$IncludeChain -BackupRootPath $BackupRootPath -FunctionName $functionName
				$BackupFile = $discovered.Files
				$backupSource = $discovered.Source
				$sourceInfo = $discovered.Message
			}

			# --- Restore ausfuehren --------------------------------------------------------
			$restoreParams = @{
				SqlInstance		   = $server
				Path			   = $BackupFile
				DatabaseName	   = $TestDatabaseName
				ReplaceDbNameInFile = $true   # physische Dateinamen auf den Testnamen umschreiben
				WithReplace		   = $useReplace
				ErrorAction		   = 'Stop'
			}
			if ($DataFilePath) { $restoreParams['DestinationDataDirectory'] = $DataFilePath }
			if ($LogFilePath)  { $restoreParams['DestinationLogDirectory']  = $LogFilePath }

			$restoreAction = "Restore-Test '$DatabaseName' -> '$TestDatabaseName'"
			if ($useReplace) { $restoreAction += " (WITH REPLACE)" }

			if (-not $PSCmdlet.ShouldProcess($SqlInstance, $restoreAction))
			{
				return [PSCustomObject]@{
					SqlInstance = $server.Name; SourceDatabase = $DatabaseName; TestDatabase = $TestDatabaseName
					Success = $false; Status = 'Skipped'; Message = 'WhatIf - Restore-Test uebersprungen.'
				}
			}

			Invoke-sqmLogging -Message $restoreAction -FunctionName $functionName -Level "INFO"

			# Wall-Clock-Messung: dbatools' DatabaseRestoreTime hat nur Sekundenaufloesung und
			# liefert bei kurzen Restores einen stark ueberhoehten Durchsatz.
			$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
			$restoreResult = Restore-DbaDatabase @restoreParams
			$stopwatch.Stop()

			$endTime = Get-Date
			$durationSeconds = $stopwatch.Elapsed.TotalSeconds

			# --- Kennzahlen einsammeln -----------------------------------------------------
			# Bei mehreren Backupdateien (Kette/Stripes) liefert Restore-DbaDatabase ein Objekt
			# je Datei - Groessen summieren, Erfolg nur wenn ALLE Teile erfolgreich waren.
			$resultRows = @($restoreResult)
			$restoreComplete = ($resultRows.Count -gt 0) -and
							   (@($resultRows | Where-Object { -not $_.RestoreComplete }).Count -eq 0)

			$backupSizeBytes = 0L
			$compressedSizeBytes = 0L
			foreach ($row in $resultRows)
			{
				$backupSizeBytes	 += ConvertTo-sqmSizeBytes $row.BackupSize
				$compressedSizeBytes += ConvertTo-sqmSizeBytes $row.CompressedBackupSize
			}

			# Fallback auf den Backup-Header, wenn das Restore-Ergebnis keine Groesse hergibt.
			# "0 B" in einem Nachweis ist wertlos - dann lieber die Zahl aus dem Header holen.
			$sizeSource = 'RestoreResult'
			if ($backupSizeBytes -le 0)
			{
				Invoke-sqmLogging -Message "Restore-Ergebnis lieferte keine verwertbare Backupgroesse - lese RESTORE HEADERONLY." `
					-FunctionName $functionName -Level "WARNING"
				$hdr = Get-sqmBackupHeaderSize -Server $server -Files $BackupFile -SqlCredential $SqlCredential -FunctionName $functionName
				if ($hdr.BackupSizeBytes -gt 0)
				{
					$backupSizeBytes	 = $hdr.BackupSizeBytes
					$compressedSizeBytes = $hdr.CompressedBackupSizeBytes
					$sizeSource		     = 'BackupHeader'
					Invoke-sqmLogging -Message "Backupgroesse aus dem Header ermittelt: $(Format-sqmFileSize -Bytes $backupSizeBytes) ueber $($hdr.SetCount) Sicherungssatz/-saetze." `
						-FunctionName $functionName -Level "INFO"
				}
				else
				{
					$sizeSource = 'Unknown'
					Invoke-sqmLogging -Message "Backupgroesse konnte nicht ermittelt werden - Datenmenge und Durchsatz werden im Nachweis als 'nicht ermittelbar' ausgewiesen." `
						-FunctionName $functionName -Level "ERROR"
				}
			}

			# Durchsatz auf Basis der BackupSize (logische Datenmenge).
			$throughputBytesPerSecond = 0L
			if ($durationSeconds -gt 0)
			{
				$throughputBytesPerSecond = [long]($backupSizeBytes / $durationSeconds)
			}

			$sqlReportedTime = ($resultRows | Select-Object -First 1).DatabaseRestoreTime
			$restoredFilesCount = ($resultRows | Measure-Object -Property RestoredFilesCount -Sum).Sum

			if ($restoreComplete)
			{
				Invoke-sqmLogging -Message ("Restore-Test erfolgreich: '$TestDatabaseName', {0} in {1:N2}s ({2}/s)." -f `
						(Format-sqmFileSize -Bytes $backupSizeBytes), $durationSeconds, (Format-sqmFileSize -Bytes $throughputBytesPerSecond)) `
					-FunctionName $functionName -Level "INFO"
			}
			else
			{
				Invoke-sqmLogging -Message "Restore-Test NICHT erfolgreich: '$TestDatabaseName'." `
					-FunctionName $functionName -Level "ERROR"
			}

			# --- Test-Datenbank optional wegraeumen ----------------------------------------
			# Default ist bewusst "stehen lassen" - Kunden testen haeufig gegen die Kopie weiter.
			$testDbRemoved = $false
			if ($RemoveTestDatabase -and $restoreComplete)
			{
				# Doppelte Absicherung: der Drop prueft den Praefix erneut, unabhaengig davon
				# was oben passiert ist. Ein DROP darf niemals eine Nicht-Test-DB treffen.
				if (-not $TestDatabaseName.StartsWith($restoreTestPrefix, [System.StringComparison]::OrdinalIgnoreCase))
				{
					Invoke-sqmLogging -Message "Abbruch des Aufraeumens: '$TestDatabaseName' hat nicht den Praefix '$restoreTestPrefix'." `
						-FunctionName $functionName -Level "ERROR"
				}
				elseif ($PSCmdlet.ShouldProcess($SqlInstance, "Test-Datenbank '$TestDatabaseName' entfernen"))
				{
					try
					{
						$null = Remove-DbaDatabase -SqlInstance $server -Database $TestDatabaseName -Confirm:$false -ErrorAction Stop
						$testDbRemoved = $true
						Invoke-sqmLogging -Message "Test-Datenbank '$TestDatabaseName' entfernt." -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						Invoke-sqmLogging -Message "Test-Datenbank '$TestDatabaseName' konnte nicht entfernt werden: $($_.Exception.Message)" `
							-FunctionName $functionName -Level "WARNING"
					}
				}
			}

			# --- Ergebnisobjekt ------------------------------------------------------------
			$result = [PSCustomObject]@{
				ComputerName			 = $server.ComputerName
				InstanceName			 = $server.ServiceName
				SqlInstance				 = $server.Name
				SourceDatabase			 = $DatabaseName
				TestDatabase			 = $TestDatabaseName
				Success					 = $restoreComplete
				Status					 = if ($restoreComplete) { 'Success' } else { 'Failed' }
				BackupFile				 = ($BackupFile -join ', ')
				BackupFilesCount		 = $BackupFile.Count
				BackupSource			 = $backupSource
				BackupSourceInfo		 = $sourceInfo
				BackupSizeBytes			 = $backupSizeBytes
				BackupSize				 = if ($backupSizeBytes -gt 0) { Format-sqmFileSize -Bytes $backupSizeBytes } else { 'nicht ermittelbar' }
				CompressedBackupSizeBytes = $compressedSizeBytes
				CompressedBackupSize	 = if ($compressedSizeBytes -gt 0) { Format-sqmFileSize -Bytes $compressedSizeBytes } else { 'nicht ermittelbar' }
				SizeSource				 = $sizeSource
				DurationSeconds			 = [math]::Round($durationSeconds, 2)
				Duration				 = Format-sqmTimeSpan -Seconds ([int][math]::Round($durationSeconds))
				SqlReportedRestoreTime	 = $sqlReportedTime
				ThroughputBytesPerSecond = $throughputBytesPerSecond
				Throughput				 = if ($throughputBytesPerSecond -gt 0) { "$(Format-sqmFileSize -Bytes $throughputBytesPerSecond)/s" } else { 'nicht ermittelbar' }
				RestoredFilesCount		 = $restoredFilesCount
				TestDatabaseRemoved		 = $testDbRemoved
				RetentionMonths			 = $RetentionMonths
				RemovedReports			 = 0
				StartTime				 = $startTime
				EndTime					 = $endTime
				Message					 = if ($restoreComplete) { 'Restore-Test erfolgreich abgeschlossen.' } else { 'Restore-Test fehlgeschlagen.' }
				TxtReport				 = $null
				HtmlReport				 = $null
			}

			# --- Nachweis schreiben (TXT + HTML) -------------------------------------------
			$reportFiles = Write-sqmRestoreTestReport -Result $result -OutputPath $OutputPath -OutputHtml:$OutputHtml -FunctionName $functionName
			$result.TxtReport  = $reportFiles.TxtFile
			$result.HtmlReport = $reportFiles.HtmlFile

			# --- Aufbewahrung: alte Nachweise entfernen ------------------------------------
			# Bewusst NACH dem Schreiben des aktuellen Nachweises: schlaegt das Aufraeumen fehl,
			# ist der neue Nachweis trotzdem bereits sicher auf Platte.
			$result.RemovedReports = Remove-sqmRestoreTestReportHistory -OutputPath $OutputPath `
				-RetentionMonths $RetentionMonths -FunctionName $functionName

			Invoke-sqmOpenReport -HtmlFile $reportFiles.HtmlFile -TxtFile $reportFiles.TxtFile -NoOpen:$NoOpen

			return $result
		}
		catch
		{
			$errMsg = "Fehler beim Restore-Test '$DatabaseName' -> '$TestDatabaseName': $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return [PSCustomObject]@{
				SqlInstance = $SqlInstance; SourceDatabase = $DatabaseName; TestDatabase = $TestDatabaseName
				Success = $false; Status = 'Failed'; Message = $errMsg
			}
		}
	}
}

# Liest eine Groessenangabe aus einem dbatools-Wert als Bytes.
#
# Restore-DbaDatabase liefert BackupSize/CompressedBackupSize normalerweise als
# dbatools-Size-Objekt (…Utility.Size) mit einer .Byte-Eigenschaft. Darauf darf man sich
# aber NICHT verlassen: je nach dbatools-Version/Codepfad steht dort auch mal ein blanker
# Zahlwert oder $null. Ein direktes "[long]$wert.Byte" ergibt dann still 0 - und im Nachweis
# stand "0 B", obwohl der Restore lief. Diese Funktion deckt alle drei Faelle ab.
function ConvertTo-sqmSizeBytes
{
	[CmdletBinding()]
	[OutputType([long])]
	param ([Parameter(Mandatory = $false)] $Value)

	if ($null -eq $Value) { return 0L }

	# 1. dbatools-Size-Objekt
	$byteProp = $Value.PSObject.Properties['Byte']
	if ($byteProp -and $null -ne $byteProp.Value)
	{
		try { return [long]$byteProp.Value } catch { }
	}

	# 2. Blanker Zahlwert (oder etwas, das sich dahin konvertieren laesst)
	try { return [long]$Value } catch { }

	# 3. Letzter Versuch: Zahl aus der Textdarstellung (z. B. "213,08 MB" -> nicht verwertbar,
	#    aber "223429632" schon). Schlaegt das fehl, ist die Groesse schlicht unbekannt.
	$asText = [string]$Value
	$parsed = 0L
	if ([long]::TryParse($asText, [ref]$parsed)) { return $parsed }

	return 0L
}

# Liest die Backupgroesse direkt aus dem Backup-Header (RESTORE HEADERONLY).
#
# Fallback, wenn das Restore-Ergebnis keine verwertbare Groesse hergibt. Der Header liefert
# BackupSize/CompressedBackupSize als schlichtes Int64 und ist damit unabhaengig davon, wie
# dbatools die Werte gerade typisiert.
#
# Wichtig: bei einem gestripten Backup liefert JEDE Stripe-Datei denselben Backup-Satz mit
# derselben Gesamtgroesse zurueck - stumpfes Summieren wuerde die Datenmenge vervielfachen.
# Deshalb wird ueber BackupSetGUID entdupliziert: Stripes teilen sich eine GUID, die Saetze
# einer Kette (Full/Diff/Log) haben verschiedene.
function Get-sqmBackupHeaderSize
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)] $Server,
		[Parameter(Mandatory = $true)] [string[]]$Files,
		[Parameter(Mandatory = $false)] $SqlCredential,
		[Parameter(Mandatory = $false)] [string]$FunctionName = 'Invoke-sqmRestoreTest'
	)

	$sets = @{}
	foreach ($file in $Files)
	{
		try
		{
			$safe = $file.Replace("'", "''")
			$rows = @(Invoke-DbaQuery -SqlInstance $Server -SqlCredential $SqlCredential -Database 'master' `
					-Query "RESTORE HEADERONLY FROM DISK = N'$safe'" -As PSObject -ErrorAction Stop)
			foreach ($row in $rows)
			{
				$key = if ($row.BackupSetGUID) { [string]$row.BackupSetGUID } else { "$file|$($row.Position)" }
				if (-not $sets.ContainsKey($key))
				{
					$sets[$key] = [PSCustomObject]@{
						Backup	   = ConvertTo-sqmSizeBytes $row.BackupSize
						Compressed = ConvertTo-sqmSizeBytes $row.CompressedBackupSize
					}
				}
			}
		}
		catch
		{
			Invoke-sqmLogging -Message "RESTORE HEADERONLY fuer '$file' fehlgeschlagen: $($_.Exception.Message)" `
				-FunctionName $FunctionName -Level "WARNING"
		}
	}

	$total = 0L; $comp = 0L
	foreach ($s in $sets.Values) { $total += $s.Backup; $comp += $s.Compressed }
	return [PSCustomObject]@{ BackupSizeBytes = $total; CompressedBackupSizeBytes = $comp; SetCount = $sets.Count }
}

# Ermittelt die zu restaurierende(n) Backupdatei(en), wenn -BackupFile nicht angegeben wurde.
#
# Zwei Quellen, in dieser Reihenfolge:
#   1. msdb-Sicherungshistorie (Get-DbaDbBackupHistory). Liefert den Pfad, den SQL Server
#      tatsaechlich geschrieben hat - unabhaengig von Olas @DirectoryStructure/@FileName,
#      die konfigurierbar sind und in der Praxis vom Default abweichen.
#   2. Verzeichnis-Scan als Fallback, falls die Historie nichts hergibt (Olas
#      sp_delete_backuphistory-Job raeumt sie regelmaessig, oder der Test laeuft auf einer
#      anderen Instanz als das Backup).
#
# Der Scan laeuft ueber Get-DbaFile (xp_dirtree auf der Instanz), nicht ueber Get-ChildItem -
# die Backupdateien liegen auf dem Datentraeger der SQL-Instanz, nicht auf dem ausfuehrenden
# Rechner. Get-DbaFile liefert kein Aenderungsdatum, deshalb bestimmt der Zeitstempel IM
# Dateinamen die Reihenfolge. Bei Olas Namensschema (_FULL_yyyyMMdd_HHmmss) ist die
# lexikografische Sortierung identisch mit der chronologischen.
function Get-sqmRestoreTestBackupSource
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		$Server,
		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeChain,
		[Parameter(Mandatory = $false)]
		[string]$BackupRootPath,
		[Parameter(Mandatory = $false)]
		[string]$FunctionName = 'Invoke-sqmRestoreTest'
	)

	# --- 1. msdb-Historie ---------------------------------------------------------------
	try
	{
		$histParams = @{ SqlInstance = $Server; Database = $DatabaseName; ErrorAction = 'Stop' }
		# -Last liefert die komplette, zum juengsten Zeitpunkt noetige Kette (Full + Diff + Logs);
		# -LastFull nur die neueste Vollsicherung.
		if ($IncludeChain) { $histParams['Last'] = $true } else { $histParams['LastFull'] = $true }

		$history = @(Get-DbaDbBackupHistory @histParams)
		if ($history.Count -gt 0)
		{
			# .Path ist ein String[] (gestripte Backups liefern mehrere Dateien je Sicherung).
			$files = @($history | ForEach-Object { $_.Path })
			if ($files.Count -gt 0)
			{
				$typeInfo = ($history | Group-Object Type | ForEach-Object { "$($_.Count)x $($_.Name)" }) -join ', '
				Invoke-sqmLogging -Message "Backup aus msdb-Historie ermittelt ($typeInfo): $($files.Count) Datei(en)." `
					-FunctionName $FunctionName -Level "INFO"
				return [PSCustomObject]@{ Files = $files; Source = 'BackupHistory'; Message = $typeInfo }
			}
		}
		Invoke-sqmLogging -Message "Keine Sicherungshistorie fuer '$DatabaseName' in msdb - versuche Verzeichnis-Scan." `
			-FunctionName $FunctionName -Level "WARNING"
	}
	catch
	{
		Invoke-sqmLogging -Message "msdb-Historie nicht auswertbar ($($_.Exception.Message)) - versuche Verzeichnis-Scan." `
			-FunctionName $FunctionName -Level "WARNING"
	}

	# --- 2. Fallback: Verzeichnis-Scan --------------------------------------------------
	# Nur Vollsicherungen: eine Kette laesst sich ohne Historie nicht verlaesslich
	# rekonstruieren (LSN-Zusammenhang ist am Dateinamen nicht ablesbar).
	if ($IncludeChain)
	{
		Invoke-sqmLogging -Message "Ohne msdb-Historie kann keine Sicherungskette (-IncludeChain) bestimmt werden; der Scan liefert nur die neueste Vollsicherung." `
			-FunctionName $FunctionName -Level "WARNING"
	}

	$root = $BackupRootPath
	if ([string]::IsNullOrWhiteSpace($root)) { $root = Get-sqmConfig -Key 'BackupDirectory' 3>$null }
	if ([string]::IsNullOrWhiteSpace($root))
	{
		try { $root = (Get-DbaDefaultPath -SqlInstance $Server -ErrorAction Stop).Backup } catch { }
	}
	if ([string]::IsNullOrWhiteSpace($root))
	{
		throw "Backupverzeichnis nicht ermittelbar. -BackupFile oder -BackupRootPath angeben."
	}

	Invoke-sqmLogging -Message "Verzeichnis-Scan nach Vollsicherung von '$DatabaseName' unter: $root" `
		-FunctionName $FunctionName -Level "INFO"

	$found = @(Get-DbaFile -SqlInstance $Server -Path $root -Depth 4 -FileType bak -ErrorAction Stop |
		Select-Object -ExpandProperty Filename)

	# Ola-Namensschema: <Server>_<DB>_FULL_<yyyyMMdd>_<HHmmss>[_<n>].bak
	$dbPattern = [regex]::Escape($DatabaseName)
	$rx = "_$dbPattern`_FULL_(?<ts>\d{8}_\d{6})"
	$candidates = $found | Where-Object { $_ -match $rx }

	if (-not $candidates)
	{
		throw "Keine Vollsicherung fuer '$DatabaseName' gefunden (weder in msdb noch unter '$root')."
	}

	# Nach Zeitstempel im Namen gruppieren und die juengste Gruppe nehmen - eine Gruppe
	# kann mehrere Dateien enthalten (gestriptes Backup).
	$newest = $candidates |
		ForEach-Object { [PSCustomObject]@{ File = $_; Stamp = ([regex]::Match($_, $rx)).Groups['ts'].Value } } |
		Group-Object Stamp | Sort-Object Name -Descending | Select-Object -First 1

	$files = @($newest.Group | Select-Object -ExpandProperty File)
	Invoke-sqmLogging -Message "Backup per Verzeichnis-Scan ermittelt (Zeitstempel $($newest.Name)): $($files.Count) Datei(en)." `
		-FunctionName $FunctionName -Level "INFO"

	return [PSCustomObject]@{ Files = $files; Source = 'DirectoryScan'; Message = "Zeitstempel $($newest.Name)" }
}

# Entfernt Restore-Test-Nachweise, die aelter als die Aufbewahrungsfrist sind.
# Loescht ausschliesslich Dateien, die dem eigenen Namensmuster entsprechen - ein -OutputPath
# auf ein gemeinsam genutztes Verzeichnis darf niemals fremde Dateien treffen.
function Remove-sqmRestoreTestReportHistory
{
	[CmdletBinding()]
	[OutputType([int])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$OutputPath,
		[Parameter(Mandatory = $true)]
		[int]$RetentionMonths,
		[Parameter(Mandatory = $false)]
		[string]$FunctionName = 'Invoke-sqmRestoreTest'
	)

	# 0 = unbegrenzt aufbewahren
	if ($RetentionMonths -le 0)
	{
		Invoke-sqmLogging -Message "Aufbewahrung unbegrenzt (RetentionMonths=0) - kein Aufraeumen." `
			-FunctionName $FunctionName -Level "INFO"
		return 0
	}

	$removed = 0
	try
	{
		if (-not (Test-Path $OutputPath)) { return 0 }

		$cutoff = (Get-Date).AddMonths(-$RetentionMonths)

		# Nur das eigene Namensmuster - siehe Funktionskommentar.
		$candidates = Get-ChildItem -Path $OutputPath -File -ErrorAction Stop |
			Where-Object { $_.Name -like 'RestoreTest_*' -and $_.Extension -in @('.txt', '.html') -and $_.LastWriteTime -lt $cutoff }

		foreach ($old in $candidates)
		{
			try
			{
				Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
				$removed++
			}
			catch
			{
				Invoke-sqmLogging -Message "Alter Nachweis '$($old.Name)' konnte nicht entfernt werden: $($_.Exception.Message)" `
					-FunctionName $FunctionName -Level "WARNING"
			}
		}

		if ($removed -gt 0)
		{
			Invoke-sqmLogging -Message "Aufbewahrung $RetentionMonths Monate: $removed Nachweis-Datei(en) vor $($cutoff.ToString('yyyy-MM-dd')) entfernt." `
				-FunctionName $FunctionName -Level "INFO"
		}
	}
	catch
	{
		# Ein fehlgeschlagenes Aufraeumen darf den Restore-Test nicht als fehlgeschlagen dastehen
		# lassen - der Nachweis selbst ist zu diesem Zeitpunkt bereits geschrieben.
		Invoke-sqmLogging -Message "Aufbewahrung konnte nicht angewendet werden: $($_.Exception.Message)" `
			-FunctionName $FunctionName -Level "WARNING"
	}

	return $removed
}

# Schreibt den Nachweis als TXT und (optional) HTML im sqmSQLTool-Standardverfahren.
# Bewusst als separate Hilfsfunktion in derselben Datei - haelt Invoke-sqmRestoreTest lesbar,
# wird aber nicht exportiert (steht nicht in FunctionsToExport der .psd1).
function Write-sqmRestoreTestReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$Result,
		[Parameter(Mandatory = $true)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$OutputHtml,
		[Parameter(Mandatory = $false)]
		[string]$FunctionName = 'Invoke-sqmRestoreTest'
	)

	$txtFile  = $null
	$htmlFile = $null

	try
	{
		if (-not (Test-Path $OutputPath))
		{
			$null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop
			Invoke-sqmLogging -Message "Ausgabeverzeichnis erstellt: $OutputPath" -FunctionName $FunctionName -Level "INFO"
		}

		$safeInst = $Result.SqlInstance -replace '[\\\/:*?"<>|]', '_'
		$datestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
		$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
		$baseName = "RestoreTest_$($Result.SourceDatabase)_${safeInst}_${datestamp}"
		$txtFile  = Join-Path $OutputPath "$baseName.txt"
		$htmlFile = Join-Path $OutputPath "$baseName.html"

		$ergebnis = if ($Result.Success) { 'ERFOLGREICH' } else { 'FEHLGESCHLAGEN' }
		$aufraeumen = if ($Result.TestDatabaseRemoved) { 'Ja - Test-Datenbank entfernt' } else { 'Nein - Test-Datenbank bleibt erhalten' }

		# Sekunden explizit ueber die Kultur formatieren. Die String-Interpolation eines [double]
		# nutzt InvariantCulture (Punkt), waehrend Format-sqmFileSize ueber "{0:N2}" die aktuelle
		# Kultur nutzt (im deutschen Umfeld Komma) - ungeformatiert stuenden im selben Nachweis
		# "228,08 MB" und "2.02 s" nebeneinander.
		$dauerSekunden = "{0:N2}" -f $Result.DurationSeconds

		$aufbewahrung = if ($Result.RetentionMonths -le 0) { 'unbegrenzt' } else { "$($Result.RetentionMonths) Monate" }

		# Komprimierung nicht unterstellen: sind logische und physische Groesse gleich, ist das
		# Backup unkomprimiert - ein "(komprimiert gelesen)" waere dann schlicht falsch, und der
		# Nachweis geht an Auditoren.
		$istKomprimiert = ($Result.CompressedBackupSizeBytes -gt 0) -and
						  ($Result.CompressedBackupSizeBytes -lt $Result.BackupSizeBytes)
		# Ohne ermittelte Groesse darf hier weder "komprimiert" noch "unkomprimiert" behauptet werden.
		$physischNote = if ($Result.BackupSizeBytes -le 0) { 'unbekannt' }
						elseif ($istKomprimiert) { 'komprimiert gelesen' }
						else { 'unkomprimiert' }

		$herkunft = switch ($Result.BackupSource)
		{
			'BackupHistory' { 'msdb-Sicherungshistorie' }
			'DirectoryScan' { 'Verzeichnis-Scan' }
			default		    { 'ausdruecklich angegeben' }
		}
		if ($Result.BackupSourceInfo) { $herkunft += " ($($Result.BackupSourceInfo))" }

		# --- TXT ---------------------------------------------------------------------------
		$lines = [System.Collections.Generic.List[string]]::new()
		$lines.Add("# ================================================================")
		$lines.Add("# sqmSQLTool - Nachweis Restore-Test")
		$lines.Add("# $(Get-sqmReportReference)")
		$lines.Add("# Instanz      : $($Result.SqlInstance)")
		$lines.Add("# Erstellt     : $timestamp")
		$lines.Add("# ================================================================")
		$lines.Add("")
		$lines.Add("Ergebnis            : $ergebnis")
		$lines.Add("Quelldatenbank      : $($Result.SourceDatabase)")
		$lines.Add("Testdatenbank       : $($Result.TestDatabase)")
		$lines.Add("")
		$lines.Add("Datenmenge (Backup) : $($Result.BackupSize)")
		$lines.Add("davon physisch      : $($Result.CompressedBackupSize) ($physischNote)")
		$lines.Add("Dauer               : $($Result.Duration) ($dauerSekunden s)")
		$lines.Add("Datendurchsatz      : $($Result.Throughput)")
		$lines.Add("")
		$lines.Add("Start               : $($Result.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))")
		$lines.Add("Ende                : $($Result.EndTime.ToString('yyyy-MM-dd HH:mm:ss'))")
		$lines.Add("Backupdateien       : $($Result.BackupFilesCount)")
		$lines.Add("Wiederherg. Dateien : $($Result.RestoredFilesCount)")
		$lines.Add("Aufgeraeumt         : $aufraeumen")
		$lines.Add("Aufbewahrung        : $aufbewahrung")
		$lines.Add("")
		$lines.Add("Ermittelt ueber     : $herkunft")
		$lines.Add("Backupquelle        : $($Result.BackupFile)")
		$lines.Add("")
		$lines.Add("Hinweis: Der Datendurchsatz bezieht sich auf die logische Datenmenge (BackupSize)")
		$lines.Add("         und wird als Wall-Clock-Zeit ueber den gesamten Restore gemessen.")
		$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
		Invoke-sqmLogging -Message "TXT-Nachweis erstellt: $txtFile" -FunctionName $FunctionName -Level "INFO"

		# --- HTML --------------------------------------------------------------------------
		if ($OutputHtml)
		{
			$statusClass = if ($Result.Success) { 'ok' } else { 'crit' }
			$enc = { param($s) [string]$s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

			$body = @"
<table>
<tr><th colspan="2">Ergebnis</th></tr>
<tr><td>Status</td><td class="$statusClass"><strong>$ergebnis</strong></td></tr>
<tr><td>Quelldatenbank</td><td>$(& $enc $Result.SourceDatabase)</td></tr>
<tr><td>Testdatenbank</td><td>$(& $enc $Result.TestDatabase)</td></tr>
</table>

<table>
<tr><th colspan="2">Kennzahlen</th></tr>
<tr><td>Datenmenge (Backup)</td><td><strong>$($Result.BackupSize)</strong></td></tr>
<tr><td>davon physisch gelesen</td><td>$($Result.CompressedBackupSize) ($physischNote)</td></tr>
<tr><td>Dauer</td><td><strong>$($Result.Duration)</strong> ($dauerSekunden s)</td></tr>
<tr><td>Datendurchsatz</td><td><strong>$($Result.Throughput)</strong></td></tr>
</table>

<table>
<tr><th colspan="2">Details</th></tr>
<tr><td>Instanz</td><td>$(& $enc $Result.SqlInstance)</td></tr>
<tr><td>Start</td><td>$($Result.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))</td></tr>
<tr><td>Ende</td><td>$($Result.EndTime.ToString('yyyy-MM-dd HH:mm:ss'))</td></tr>
<tr><td>Backupdateien</td><td>$($Result.BackupFilesCount)</td></tr>
<tr><td>Wiederhergestellte Dateien</td><td>$($Result.RestoredFilesCount)</td></tr>
<tr><td>Aufgeraeumt</td><td>$aufraeumen</td></tr>
<tr><td>Aufbewahrung Nachweise</td><td>$aufbewahrung</td></tr>
<tr><td>Backup ermittelt ueber</td><td>$(& $enc $herkunft)</td></tr>
<tr><td>Backupquelle</td><td>$(& $enc $Result.BackupFile)</td></tr>
</table>

<p style="color:#94a8c0;font-size:12px;">
Der Datendurchsatz bezieht sich auf die logische Datenmenge (BackupSize) und wird als
Wall-Clock-Zeit ueber den gesamten Restore gemessen.
</p>
"@
			$subtitle = "$($Result.SourceDatabase) -> $($Result.TestDatabase) | $($Result.SqlInstance) | $timestamp"
			$htmlContent = ConvertTo-sqmHtmlReport -Title "Nachweis Restore-Test" -Subtitle $subtitle -BodyHtml $body
			$htmlContent | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "HTML-Nachweis erstellt: $htmlFile" -FunctionName $FunctionName -Level "INFO"
		}
		else
		{
			$htmlFile = $null
		}
	}
	catch
	{
		# Der Nachweis ist wichtig, aber ein Schreibfehler darf das Messergebnis nicht vernichten -
		# das Ergebnisobjekt wird auch ohne Report zurueckgegeben.
		Invoke-sqmLogging -Message "Nachweis konnte nicht geschrieben werden: $($_.Exception.Message)" `
			-FunctionName $FunctionName -Level "WARNING"
	}

	return [PSCustomObject]@{ TxtFile = $txtFile; HtmlFile = $htmlFile }
}
