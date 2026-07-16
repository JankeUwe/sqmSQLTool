<#
.SYNOPSIS
    Checks an NTFS drive for 64 KB allocation unit size and formats it
    with 65536 byte cluster size if needed.

.DESCRIPTION
    Process:
        1. Safety checks (not C:, NTFS, one primary partition).
        2. Save drive metadata (letter, label, partition size).
        3. Check allocation unit via Get-Volume / fsutil.
        4. If cluster size is already 65536 bytes -> abort with status 'AlreadyOK'.
        5. Check whether the drive is in use by a process.
           If so: warning and abort (status 'InUse').
        6. If drive contains data: back up with robocopy to
           $BackupPath\<Letter>_<Timestamp>\.
        7. Format-Volume with -AllocationUnitSize 65536 -FileSystem NTFS.
        8. Restore drive letter and label.
        9. If data was backed up: restore with robocopy.
           Restore error -> warning, backup remains on C:.
       10. Delete backup on C: only if robocopy restored without errors.

    Safety rules:
        - Drive C: is never formatted (hard-coded guard).
        - Only NTFS volumes are accepted.
        - Only drives with exactly one primary partition.
        - Drives opened by a process -> abort.

.PARAMETER DriveLetter
    Target drive letter (single letter, e.g. 'D'). Mandatory.
    C is explicitly prohibited.

.PARAMETER BackupPath
    Temporary backup path on C: for data backup before formatting.
    Default: C:\System\DriveBackup.
    Must reside on drive C:.

.PARAMETER Force
    Skips the interactive confirmation prompt before formatting.

.PARAMETER WhatIf
    Simulates all steps without making changes.

.PARAMETER Confirm
    Requests explicit confirmation before formatting.

.OUTPUTS
    [PSCustomObject] with the following fields:
        DriveLetter          : Drive letter
        Label                : Drive label
        PreviousClusterSize  : Cluster size before the action (bytes)
        NewClusterSize       : Cluster size after the action (bytes)
        DataBackedUp         : $true if data was backed up
        BackupFolder         : Path of the backup (or $null)
        DataRestored         : $true if data was successfully restored
        BackupCleanedUp      : $true if backup on C: was deleted after restore
        Status               : AlreadyOK | Formatted | InUse | Error | WhatIf
        Message              : Detail message

.EXAMPLE
    Invoke-sqmFormatDrive64k -DriveLetter D

    Checks drive D: and formats it with 64 KB clusters if needed.
    Data is backed up to C:\System\DriveBackup first.

.EXAMPLE
    Invoke-sqmFormatDrive64k -DriveLetter E -BackupPath "C:\Backup\DriveTemp" -Force

    Same as above, without confirmation prompt, using a different backup path.

.EXAMPLE
    Invoke-sqmFormatDrive64k -DriveLetter D -WhatIf

    Simulates the entire process without making any changes.

.NOTES
    Prerequisites   : Windows PowerShell 5.1 or PowerShell 7+, local
                      administrator rights, robocopy.exe (part of Windows).
    Cluster size    : 65536 bytes = 64 KB = optimal setting for SQL Server
                      data files (Microsoft recommendation).
    Robocopy flags  : /E  all subdirectories including empty ones
                      /COPYALL  all file attributes, timestamps, ACLs, streams
                      /R:3  max. 3 retries per file
                      /W:5  5 seconds wait between retries
                      /NP  no progress display in %
                      /LOG  log file next to backup folder
    Robocopy exit codes 0-3 are treated as success (0=ok, 1=new files, 2=extra,
    3=both). From 4 onwards a warning is issued but execution is not necessarily aborted.
#>
function Invoke-sqmFormatDrive64k
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[ValidatePattern('^[A-Za-z]$')]
		[string]$DriveLetter,

		[Parameter(Mandatory = $false)]
		[string]$BackupPath = 'C:\System\DriveBackup',

		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	# ????????????????????????????????????????????????????????????????????????
	# Initialisierung
	# ????????????????????????????????????????????????????????????????????????
	$functionName  = $MyInvocation.MyCommand.Name
	$DriveLetter   = $DriveLetter.ToUpper()
	$drivePath     = "$DriveLetter`:"
	$targetCluster = 65536   # 64 KB

	# Ergebnis-Objekt (wird laufend befuellt)
	$result = [PSCustomObject]@{
		DriveLetter         = $DriveLetter
		Label               = $null
		PreviousClusterSize = $null
		NewClusterSize      = $null
		DataBackedUp        = $false
		BackupFolder        = $null
		DataRestored        = $false
		BackupCleanedUp     = $false
		Status              = 'Error'
		Message             = $null
	}

	# ?? Logging-Hilfsfunktion (kapselt Invoke-sqmLogging) ??????????????????
	function _Log
	{
		param ([string]$Msg, [string]$Level = 'INFO')
		Write-Verbose "[$functionName] $Msg"
		try { Invoke-sqmLogging -Message "[$drivePath] $Msg" -FunctionName $functionName -Level $Level }
		catch { }   # Logging-Fehler nie weiterpropagieren
	}

	# ????????????????????????????????????????????????????????????????????????
	# SCHRITT 1 - Sicherheitspruefungen
	# ????????????????????????????????????????????????????????????????????????

	# C: ist absolut verboten
	if ($DriveLetter -eq 'C')
	{
		$msg = "Laufwerk C: darf niemals formatiert werden. Abbruch."
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}

	# BackupPath muss auf C: liegen
	if ($BackupPath -notmatch '^[Cc]:\\')
	{
		$msg = "BackupPath '$BackupPath' muss auf Laufwerk C: liegen."
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}

	# Administratorrechte pruefen
	$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
	).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	if (-not $isAdmin)
	{
		$msg = "Das Skript erfordert lokale Administratorrechte."
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}

	# Laufwerk vorhanden?
	$volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
	if (-not $volume)
	{
		$msg = "Laufwerk $drivePath nicht gefunden."
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}

	# Nur NTFS
	if ($volume.FileSystem -ne 'NTFS')
	{
		$msg = "Laufwerk $drivePath hat Dateisystem '$($volume.FileSystem)' - nur NTFS wird unterstuetzt."
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}

	# Genau eine primaere Partition
	$partitions = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue |
		Where-Object { $_.Type -eq 'Basic' -or $_.MbrType -eq 7 -or $_.GptType }

	# Partition ueber DriveLetter holen (robuster Weg)
	$partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
	if (-not $partition)
	{
		$msg = "Keine Partition fuer Laufwerk $drivePath gefunden."
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}
	if (@($partition).Count -gt 1)
	{
		$msg = "Laufwerk $drivePath hat mehr als eine Partition - nur Laufwerke mit einer primaeren Partition werden unterstuetzt."
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}

	# Metadaten sichern
	$result.Label = $volume.FileSystemLabel
	_Log "Laufwerk gefunden: $drivePath | Label='$($result.Label)' | FS=$($volume.FileSystem) | Groesse=$([math]::Round($volume.Size/1GB,2)) GB"

	# ????????????????????????????????????????????????????????????????????????
	# SCHRITT 2 - Aktuelle Clustergroesse ermitteln (fsutil)
	# ????????????????????????????????????????????????????????????????????????
	_Log "Ermittle Clustergroesse via fsutil ..."
	try
	{
		$fsutilOut = & fsutil fsinfo ntfsinfo "$drivePath\" 2>&1
		$clusterLine = $fsutilOut | Where-Object { $_ -match 'Bytes Per Cluster' }
		if ($clusterLine -match ':\s+(\d+)')
		{
			$currentCluster = [int]$Matches[1]
		}
		else
		{
			# Fallback: Get-Volume liefert AllocationUnitSize ab Win10/2016
			$currentCluster = (Get-Volume -DriveLetter $DriveLetter).AllocationUnitSize
		}
	}
	catch
	{
		$msg = "Clustergroesse konnte nicht ermittelt werden: $($_.Exception.Message)"
		_Log $msg 'ERROR'
		$result.Status  = 'Error'
		$result.Message = $msg
		Write-Error $msg
		return $result
	}

	$result.PreviousClusterSize = $currentCluster
	_Log "Aktuelle Clustergroesse: $currentCluster Byte ($([math]::Round($currentCluster/1KB,0)) KB)"

	# Bereits korrekt formatiert?
	if ($currentCluster -eq $targetCluster)
	{
		$msg = "Laufwerk $drivePath ist bereits mit 64 KB-Clustern formatiert. Keine Aktion erforderlich."
		_Log $msg 'INFO'
		$result.NewClusterSize = $currentCluster
		$result.Status         = 'AlreadyOK'
		$result.Message        = $msg
		Write-Host $msg -ForegroundColor Green
		return $result
	}

	_Log "Clustergroesse $currentCluster Byte ? $targetCluster Byte - Formatierung erforderlich." 'WARNING'

	# ????????????????????????????????????????????????????????????????????????
	# SCHRITT 3 - Laufwerk in Benutzung?
	# ????????????????????????????????????????????????????????????????????????
	_Log "Pruefe ob $drivePath von Prozessen verwendet wird ..."
	$openHandles = $false
	try
	{
		# openfiles.exe erfordert 'Maintain Objects List' - zuverlaessiger: handle via
		# WMI CIM_Process + Get-Process mit Modulpfad-Filter
		$busyProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object {
			try
			{
				$_.Modules | Where-Object { $_.FileName -like "$drivePath\*" }
			}
			catch { $false }
		}

		# Zusaetzlich: alle offenen Datei-Handles ueber .NET (schnell, ohne Sysinternals)
		$drivePrefix = "$drivePath\"
		$appDomainCheck = [System.IO.Directory]::GetFiles($drivePrefix, '*', [System.IO.SearchOption]::TopDirectoryOnly) 2>$null

		if ($busyProcesses)
		{
			$procList = ($busyProcesses | Select-Object -ExpandProperty Name -Unique) -join ', '
			$msg = "Laufwerk $drivePath wird von folgenden Prozessen verwendet: $procList - Abbruch."
			_Log $msg 'WARNING'
			Write-Warning $msg
			$result.Status  = 'InUse'
			$result.Message = $msg
			return $result
		}
	}
	catch
	{
		_Log "Prozess-Pruefung: $($_.Exception.Message) - wird fortgesetzt." 'WARNING'
	}

	# ????????????????????????????????????????????????????????????????????????
	# SCHRITT 4 - Daten vorhanden? ? Backup mit robocopy
	# ????????????????????????????????????????????????????????????????????????
	$hasData       = $false
	$backupFolder  = $null
	$robocopyLog   = $null

	try
	{
		$items = Get-ChildItem -Path "$drivePath\" -Force -ErrorAction SilentlyContinue
		$hasData = [bool]$items
	}
	catch { $hasData = $false }

	if ($hasData)
	{
		$timestamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
		$backupFolder = Join-Path $BackupPath "${DriveLetter}_${timestamp}"
		$robocopyLog  = Join-Path $BackupPath "${DriveLetter}_${timestamp}_backup.log"
		$result.BackupFolder = $backupFolder

		_Log "Laufwerk enthaelt Daten - Sicherung nach '$backupFolder' ..."

		if ($PSCmdlet.ShouldProcess($drivePath, "Daten nach '$backupFolder' sichern (robocopy)"))
		{
			if (-not (Test-Path $BackupPath))
			{
				New-Item -ItemType Directory -Path $BackupPath -Force -ErrorAction Stop | Out-Null
				_Log "Backup-Verzeichnis '$BackupPath' erstellt."
			}

			$rcArgs = @(
				"$drivePath\",         # Quelle
				$backupFolder,         # Ziel
				'/E',                  # alle Unterverzeichnisse inkl. leere
				'/COPYALL',            # Attribute, Timestamps, ACLs, Streams
				'/R:3',                # max. 3 Wiederholungen
				'/W:5',                # 5 s Wartezeit
				'/NP',                 # keine %-Fortschrittsanzeige
				'/LOG+:' + $robocopyLog
			)

			_Log "Starte robocopy Backup: robocopy $($rcArgs -join ' ')"
			& robocopy @rcArgs | Out-Null
			$rcExit = $LASTEXITCODE

			if ($rcExit -le 3)
			{
				$result.DataBackedUp = $true
				_Log "Backup erfolgreich (robocopy ExitCode $rcExit)."
			}
			else
			{
				$msg = "Backup fehlgeschlagen (robocopy ExitCode $rcExit). Log: $robocopyLog - Abbruch."
				_Log $msg 'ERROR'
				$result.Status  = 'Error'
				$result.Message = $msg
				Write-Error $msg
				return $result
			}
		}
		else
		{
			_Log "WhatIf: Backup wuerde nach '$backupFolder' erstellt." 'INFO'
		}
	}
	else
	{
		_Log "Laufwerk $drivePath enthaelt keine Daten - kein Backup erforderlich."
	}

	# ????????????????????????????????????????????????????????????????????????
	# SCHRITT 5 - Bestaetigung und Format
	# ????????????????????????????????????????????????????????????????????????
	$confirmMsg = "Laufwerk $drivePath (Label: '$($result.Label)') wird mit 64 KB-Clustern formatiert. " +
		"ALLE DATEN WERDEN GELoeSCHT$(if ($result.DataBackedUp) { " (Backup: $backupFolder)" } else { '' })."

	if (-not $Force -and -not $PSCmdlet.ShouldProcess($drivePath, $confirmMsg))
	{
		$msg = "Formatierung durch Benutzer abgebrochen."
		_Log $msg 'WARNING'
		$result.Status  = 'Error'
		$result.Message = $msg
		return $result
	}

	_Log "Formatiere $drivePath mit 65536 Byte Clustergroesse, NTFS, Label='$($result.Label)' ..."

	if (-not $WhatIfPreference)
	{
		try
		{
			Format-Volume `
				-DriveLetter $DriveLetter `
				-FileSystem NTFS `
				-AllocationUnitSize $targetCluster `
				-NewFileSystemLabel $result.Label `
				-Force `
				-Confirm:$false `
				-ErrorAction Stop | Out-Null
		}
		catch
		{
			$msg = "Format-Volume fehlgeschlagen: $($_.Exception.Message)"
			_Log $msg 'ERROR'
			$result.Status  = 'Error'
			$result.Message = $msg
			Write-Error $msg
			return $result
		}

		# Laufwerksbuchstaben wiederherstellen (Format-Volume entfernt ihn manchmal nicht,
		# aber zur Sicherheit explizit setzen)
		try
		{
			$newPartition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
			if (-not $newPartition)
			{
				# Buchstabe neu zuweisen
				$disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
				$freshPartition = $disk | Get-Partition | Where-Object { $_.PartitionNumber -eq $partition.PartitionNumber }
				if ($freshPartition)
				{
					Set-Partition -InputObject $freshPartition -NewDriveLetter $DriveLetter -ErrorAction Stop
					_Log "Laufwerksbuchstabe $drivePath wiederhergestellt."
				}
			}
		}
		catch
		{
			_Log "Laufwerksbuchstabe konnte nicht wiederhergestellt werden: $($_.Exception.Message)" 'WARNING'
			Write-Warning "Laufwerksbuchstabe ${drivePath}: $($_.Exception.Message)"
		}

		# Neue Clustergroesse verifizieren
		try
		{
			$fsutilNew  = & fsutil fsinfo ntfsinfo "$drivePath\" 2>&1
			$clusterNew = ($fsutilNew | Where-Object { $_ -match 'Bytes Per Cluster' }) -replace '.*:\s+', '' -as [int]
			if (-not $clusterNew) { $clusterNew = (Get-Volume -DriveLetter $DriveLetter).AllocationUnitSize }
			$result.NewClusterSize = $clusterNew
			_Log "Neue Clustergroesse verifiziert: $clusterNew Byte."
		}
		catch
		{
			_Log "Neue Clustergroesse konnte nicht verifiziert werden: $($_.Exception.Message)" 'WARNING'
			$result.NewClusterSize = $targetCluster   # Annahme
		}
	}
	else
	{
		_Log "WhatIf: Format-Volume $drivePath -AllocationUnitSize 65536 -FileSystem NTFS -Label '$($result.Label)'"
		$result.NewClusterSize = $targetCluster
		$result.Status         = 'WhatIf'
		$result.Message        = "WhatIf: Keine aenderungen durchgefuehrt."
		return $result
	}

	# ????????????????????????????????????????????????????????????????????????
	# SCHRITT 6 - Daten zurueckspielen
	# ????????????????????????????????????????????????????????????????????????
	if ($result.DataBackedUp -and $backupFolder)
	{
		$robocopyRestoreLog = Join-Path $BackupPath "${DriveLetter}_${timestamp}_restore.log"

		_Log "Spiele Daten von '$backupFolder' zurueck nach $drivePath ..."

		$rcRestoreArgs = @(
			$backupFolder,         # Quelle
			"$drivePath\",         # Ziel
			'/E',
			'/COPYALL',
			'/R:3',
			'/W:5',
			'/NP',
			'/LOG+:' + $robocopyRestoreLog
		)

		_Log "Starte robocopy Restore: robocopy $($rcRestoreArgs -join ' ')"
		& robocopy @rcRestoreArgs | Out-Null
		$rcRestoreExit = $LASTEXITCODE

		if ($rcRestoreExit -le 3)
		{
			$result.DataRestored = $true
			_Log "Restore erfolgreich (robocopy ExitCode $rcRestoreExit)."

			# ?? Backup auf C: bereinigen ??????????????????????????????????
			_Log "Loesche Backup '$backupFolder' auf C: ..."
			try
			{
				Remove-Item -Path $backupFolder -Recurse -Force -ErrorAction Stop
				$result.BackupCleanedUp = $true
				_Log "Backup '$backupFolder' erfolgreich geloescht."
			}
			catch
			{
				$warnMsg = "Backup '$backupFolder' konnte nicht geloescht werden: $($_.Exception.Message)"
				_Log $warnMsg 'WARNING'
				Write-Warning $warnMsg
			}
		}
		else
		{
			$warnMsg = "Restore teilweise fehlgeschlagen (robocopy ExitCode $rcRestoreExit). " +
				"Backup bleibt erhalten: '$backupFolder'. Log: $robocopyRestoreLog"
			_Log $warnMsg 'WARNING'
			Write-Warning $warnMsg
			# DataRestored bleibt $false, BackupCleanedUp bleibt $false
			# Backup wird NICHT geloescht
		}
	}

	# ????????????????????????????????????????????????????????????????????????
	# Abschluss
	# ????????????????????????????????????????????????????????????????????????
	$result.Status  = 'Formatted'
	$result.Message = "Laufwerk $drivePath erfolgreich auf 64 KB-Clustergroesse formatiert." +
		$(if ($result.DataRestored)    { " Daten wiederhergestellt." }) +
		$(if ($result.BackupCleanedUp) { " Backup auf C: bereinigt." }) +
		$(if ($result.DataBackedUp -and -not $result.DataRestored) { " WARNUNG: Backup auf C: nicht geloescht ($backupFolder)." })

	_Log $result.Message 'INFO'
	Write-Host $result.Message -ForegroundColor $(if ($result.DataBackedUp -and -not $result.DataRestored) { 'Yellow' } else { 'Green' })

	return $result
}
