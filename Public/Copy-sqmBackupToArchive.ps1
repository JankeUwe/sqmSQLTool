<#
.SYNOPSIS
    Kopiert die letzten Full-Backups eines Monats oder Jahres (Monats-/Jahresendbackups) in ein Archivverzeichnis.

.DESCRIPTION
    Sucht in der Backup-Historie (msdb) je Datenbank das letzte Full-Backup des abgeschlossenen Monats oder Jahres und
    kopiert alle zugehoerigen Dateien (bei gestripten Backups alle Stripes) nach -Destination. Ablage:
        Monat: <Destination>\<JJJJ>\<JJJJ-MM>\<Datenbank>\
        Jahr : <Destination>\<JJJJ>\<Datenbank>\

    Always On: Backups eines AG liegen je nach Backup-Praeferenz auf wechselnden Knoten, und jede msdb kennt nur ihre eigenen
    Backups. Die Funktion liest deshalb die Historie ALLER Replikate (aus sys.availability_replicas, ohne -AvailabilityGroupName
    alle AGs der Instanz), nimmt je Datenbank das juengste Full-Backup des Zeitraums, gleich auf welchem Knoten es lag, und holt die
    Dateien ueber die Admin-Freigabe (\\<Knoten>\<Laufwerk>$\<Pfad>) des Knotens, der sie geschrieben hat. Ohne AG wird nur die
    angegebene Instanz verwendet. Ist ein Replikat nicht erreichbar, bricht die Funktion ab, statt aus unvollstaendiger Historie ein
    aelteres Backup zu waehlen. Als taeglicher Job laeuft sie einfach beim naechsten Mal erneut.

    Der Zeitraum ist der zuletzt ABGESCHLOSSENE Monat bzw. das letzte abgeschlossene Jahr, bezogen auf -ReferenceDate (Standard:
    heute). Am 3. Dezember ist das also der November (-Period Month) bzw. das Vorjahr (-Period Year). Kopiert wird je Datei per
    robocopy mit /XO ohne /MIR und /PURGE: bereits vorhandene Dateien werden uebersprungen, im Archiv wird nie etwas geloescht oder
    ueberschrieben. Mehrfaches Ausfuehren ist harmlos; die Aufbewahrung des Archivs ist nicht Teil der Funktion.

    Nur Backups auf Datentraegern (Dateien) werden kopiert. Liegt das Backup auf Band, TSM/VDI oder in einer URL, steht die
    Datenbank mit Status Skipped und Begruendung im Ergebnis. Datenbanken ohne Full-Backup im Zeitraum stehen mit Status
    NoBackup im Ergebnis, damit eine Luecke im Archiv auffaellt; das gilt fuer Online-Benutzerdatenbanken der -SqlInstance.

.PARAMETER SqlInstance
    Instanz, von der die Replikate ermittelt werden (bei AG: ein beliebiges Replikat). Standard: lokaler Computername.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung fuer alle Verbindungen.

.PARAMETER Destination
    Archivverzeichnis (lokal oder UNC), z. B. '\\fileserver\sqlarchiv'. Wird angelegt, falls es fehlt.

.PARAMETER Period
    'Month' (Monatsende) oder 'Year' (Jahresende).

.PARAMETER ReferenceDate
    Bezugsdatum, aus dem der abgeschlossene Zeitraum folgt. Standard: heute. Fuer einen aelteren Zeitraum ein Datum im Folgemonat
    bzw. Folgejahr angeben.

.PARAMETER Database
    Nur diese Datenbanken. Ohne Angabe: alle Benutzerdatenbanken mit Full-Backup im Zeitraum.

.PARAMETER ExcludeDatabase
    Diese Datenbanken auslassen.

.PARAMETER IncludeSystemDatabases
    Auch master, model, msdb mitnehmen. Standard: nur Benutzerdatenbanken.

.PARAMETER AvailabilityGroupName
    Nur die Replikate dieser Availability Group verwenden. Ohne Angabe: alle AGs der Instanz.

.PARAMETER EnableException
    Nach der Verarbeitung aller Datenbanken eine Ausnahme werfen, wenn eine Kopie fehlgeschlagen ist, und sofort bei einem nicht
    erreichbaren Replikat. Im Agent-Job automatisch gesetzt.

.EXAMPLE
    Copy-sqmBackupToArchive -Destination '\\fileserver\sqlarchiv' -Period Month -WhatIf

    Zeigt, welche Backups des letzten Monats wohin kopiert wuerden.

.EXAMPLE
    Copy-sqmBackupToArchive -Destination '\\fileserver\sqlarchiv' -Period Year -ReferenceDate '2027-01-15'

    Jahresendbackups von 2026.

.EXAMPLE
    # Taeglicher Job nur auf dem Primary: holt das Monatsendbackup, sobald der Monat vorbei ist; weitere Laeufe sind No-Ops
    New-sqmAgentCommandJob -SqlInstance 'SQL01' -JobName 'Archiv_Monatsende' -ScheduleType Daily -ScheduleTime '05:00' -Command @{
        FunctionName = 'Copy-sqmBackupToArchive'
        Parameters   = @{ Destination = '\\fileserver\sqlarchiv'; Period = 'Month' }
        PrimaryOnly  = $true
    }

.OUTPUTS
    [PSCustomObject] je Datenbank: DatabaseName, Period, BackupFinish, SourceReplica, FileCount, TargetPath,
    Status (Copied | UpToDate | WhatIf | NoBackup | Skipped | Failed), Message.

.NOTES
    Uses Invoke-DbaQuery, robocopy.exe. Braucht Leserechte auf msdb jedes Replikats und Lese-/Schreibrechte der Konten auf die
    Admin-Freigaben der Replikate bzw. auf das Archiv (bei Agent-Jobs das Dienstkonto oder der Proxy).
#>
function Copy-sqmBackupToArchive
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $true)]
		[string]$Destination,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Month', 'Year')]
		[string]$Period,

		[Parameter(Mandatory = $false)]
		[datetime]$ReferenceDate = (Get-Date),

		[Parameter(Mandatory = $false)]
		[string[]]$Database,

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName (Instanz '$SqlInstance', Zeitraum '$Period', Ziel '$Destination')." -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		try
		{
			if (-not $script:dbatoolsAvailable) { throw "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools" }

			# ------------------------------------------------------------------
			# 1. Zeitraum: der zuletzt abgeschlossene Monat bzw. das letzte abgeschlossene Jahr.
			# ------------------------------------------------------------------
			if ($Period -eq 'Month')
			{
				$periodEnd = [datetime]::new($ReferenceDate.Year, $ReferenceDate.Month, 1)
				$periodStart = $periodEnd.AddMonths(-1)
				$periodLabel = $periodStart.ToString('yyyy-MM')
				$relDir = $periodStart.ToString('yyyy') + '\' + $periodLabel
			}
			else
			{
				$periodEnd = [datetime]::new($ReferenceDate.Year, 1, 1)
				$periodStart = $periodEnd.AddYears(-1)
				$periodLabel = $periodStart.ToString('yyyy')
				$relDir = $periodLabel
			}
			$startSql = $periodStart.ToString('yyyyMMdd HH:mm:ss')
			$endSql = $periodEnd.ToString('yyyyMMdd HH:mm:ss')
			$destRoot = $Destination.TrimEnd('\')

			$connBase = @{}
			if ($SqlCredential) { $connBase['SqlCredential'] = $SqlCredential }

			# ------------------------------------------------------------------
			# 2. Replikate: alle Knoten der AG(s) inklusive des lokalen, sonst nur die Instanz selbst.
			# ------------------------------------------------------------------
			$repQuery = "SELECT DISTINCT ar.replica_server_name AS ReplicaName FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ag.group_id = ar.group_id"
			if ($AvailabilityGroupName) { $repQuery += " WHERE ag.name = N'" + ($AvailabilityGroupName -replace "'", "''") + "'" }
			$replicas = @(Invoke-DbaQuery @connBase -SqlInstance $SqlInstance -Database master -Query $repQuery -As PSObject -EnableException -ErrorAction Stop |
				ForEach-Object { [string]$_.ReplicaName })
			if ($replicas.Count -eq 0) { $replicas = @($SqlInstance) }

			# ------------------------------------------------------------------
			# 3. Backup-Historie jedes Replikats lesen. Ein nicht erreichbares Replikat bricht ab: sein msdb kann genau das
			#    Monatsendbackup enthalten, und ein aelteres Backup waere die falsche Wahl.
			# ------------------------------------------------------------------
			$histQuery = "SELECT bs.database_name AS DatabaseName, bs.backup_set_id AS BackupSetId, bs.backup_finish_date AS BackupFinish, bmf.physical_device_name AS DevicePath, bmf.device_type AS DeviceType FROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id WHERE bs.type = 'D' AND bs.backup_finish_date >= '$startSql' AND bs.backup_finish_date < '$endSql'"

			$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			foreach ($replica in $replicas)
			{
				try
				{
					$rows = @(Invoke-DbaQuery @connBase -SqlInstance $replica -Database msdb -Query $histQuery -As PSObject -EnableException -ErrorAction Stop)
				}
				catch
				{
					throw "Replikat '$replica' nicht lesbar ($($_.Exception.Message)). Abbruch, damit nicht aus unvollstaendiger Historie ein aelteres Backup gewaehlt wird."
				}
				foreach ($row in $rows)
				{
					$allRows.Add([PSCustomObject]@{
						Replica      = $replica
						DatabaseName = [string]$row.DatabaseName
						BackupSetId  = [int]$row.BackupSetId
						BackupFinish = [datetime]$row.BackupFinish
						DevicePath   = [string]$row.DevicePath
						DeviceType   = [int]$row.DeviceType
					})
				}
			}

			# ------------------------------------------------------------------
			# 4. Je Datenbank das juengste Full-Backup ueber alle Replikate waehlen.
			# ------------------------------------------------------------------
			$systemDbs = 'master', 'model', 'msdb'
			$selectedDbs = [System.Collections.Generic.List[string]]::new()
			foreach ($name in @($allRows | ForEach-Object { $_.DatabaseName } | Select-Object -Unique))
			{
				if (-not $IncludeSystemDatabases -and $systemDbs -contains $name) { continue }
				if ($Database -and ($Database -notcontains $name)) { continue }
				if ($ExcludeDatabase -and ($ExcludeDatabase -contains $name)) { continue }
				$selectedDbs.Add($name)
			}

			foreach ($db in ($selectedDbs | Sort-Object))
			{
				$dbRows = @($allRows | Where-Object { $_.DatabaseName -eq $db })
				$latest = $dbRows | Sort-Object -Property BackupFinish -Descending | Select-Object -First 1
				$files = @($dbRows | Where-Object { $_.Replica -eq $latest.Replica -and $_.BackupSetId -eq $latest.BackupSetId })

				$entry = [PSCustomObject]@{
					DatabaseName  = $db
					Period        = $periodLabel
					BackupFinish  = $latest.BackupFinish
					SourceReplica = $latest.Replica
					FileCount     = $files.Count
					TargetPath    = "$destRoot\$relDir\$($db -replace '[\\/:*?"<>|]', '_')"
					Status        = 'Unknown'
					Message       = ''
				}

				# Nur Dateien auf Datentraegern: 2 = Disk, 102 = permanentes Disk-Device.
				$nonDisk = @($files | Where-Object { $_.DeviceType -notin 2, 102 })
				if ($nonDisk.Count -gt 0)
				{
					$entry.Status = 'Skipped'
					$entry.Message = "Backup liegt nicht auf einem Datentraeger (Device-Typ $($nonDisk[0].DeviceType)): '$($nonDisk[0].DevicePath)'."
					Invoke-sqmLogging -Message "${db}: $($entry.Message)" -FunctionName $functionName -Level 'WARNING'
					$results.Add($entry)
					continue
				}

				if (-not $PSCmdlet.ShouldProcess($entry.TargetPath, "Full-Backup von '$db' ($($latest.BackupFinish.ToString('yyyy-MM-dd HH:mm')), $($files.Count) Datei(en)) von '$($latest.Replica)' kopieren"))
				{
					$entry.Status = 'WhatIf'
					$results.Add($entry)
					continue
				}

				# Quelle: Admin-Freigabe des Knotens, der das Backup geschrieben hat (lokal direkt).
				$replicaHost = ($latest.Replica -split '\\')[0]
				$isLocal = ($replicaHost -ieq $env:COMPUTERNAME) -or ($replicaHost -ieq 'localhost') -or ($replicaHost -like "$($env:COMPUTERNAME).*")
				$anyFailed = $false
				$anyCopied = $false
				$failMsg = ''

				foreach ($f in $files)
				{
					$srcFull = $f.DevicePath
					if (-not $isLocal -and $srcFull -match '^[A-Za-z]:\\')
					{
						$srcFull = "\\$replicaHost\" + ($srcFull -replace '^([A-Za-z]):', '$1$')
					}
					$srcDir = Split-Path -Path $srcFull -Parent
					$srcName = Split-Path -Path $srcFull -Leaf

					# /XO: Vorhandenes nicht ueberschreiben; kein /MIR und kein /PURGE: im Archiv wird nie geloescht.
					$robo = Invoke-sqmRobocopy -Arguments @($srcDir, $entry.TargetPath, $srcName, '/XO', '/R:3', '/W:10', '/NP', '/NDL')
					if ($robo.ExitCode -ge 8)
					{
						$anyFailed = $true
						$tail = (@($robo.Output | Where-Object { $_ -match '\S' }) | Select-Object -Last 3) -join ' | '
						$failMsg = "robocopy Exitcode $($robo.ExitCode) fuer '$srcFull'. $tail"
						break
					}
					if ($robo.ExitCode -band 1) { $anyCopied = $true }
				}

				if ($anyFailed)
				{
					$entry.Status = 'Failed'
					$entry.Message = $failMsg
					Invoke-sqmLogging -Message "${db}: $failMsg" -FunctionName $functionName -Level 'ERROR'
				}
				else
				{
					$entry.Status = if ($anyCopied) { 'Copied' } else { 'UpToDate' }
					Invoke-sqmLogging -Message "${db}: $($entry.Status) nach '$($entry.TargetPath)' ($($files.Count) Datei(en), Backup vom $($latest.BackupFinish.ToString('yyyy-MM-dd HH:mm')) auf '$($latest.Replica)')." -FunctionName $functionName -Level 'INFO'
				}
				$results.Add($entry)
			}

			# ------------------------------------------------------------------
			# 5. Luecken sichtbar machen: Online-Benutzerdatenbanken ohne Full-Backup im Zeitraum.
			# ------------------------------------------------------------------
			if (-not $Database)
			{
				$dbQuery = "SELECT name AS DatabaseName FROM sys.databases WHERE state = 0 AND database_id > 4 AND source_database_id IS NULL"
				$dbNames = @(Invoke-DbaQuery @connBase -SqlInstance $SqlInstance -Database master -Query $dbQuery -As PSObject -EnableException -ErrorAction Stop |
					ForEach-Object { [string]$_.DatabaseName })
				foreach ($name in ($dbNames | Sort-Object))
				{
					if ($selectedDbs -contains $name) { continue }
					if ($ExcludeDatabase -and ($ExcludeDatabase -contains $name)) { continue }
					$results.Add([PSCustomObject]@{
						DatabaseName  = $name
						Period        = $periodLabel
						BackupFinish  = $null
						SourceReplica = $null
						FileCount     = 0
						TargetPath    = $null
						Status        = 'NoBackup'
						Message       = "Kein Full-Backup im Zeitraum $periodLabel in der Historie."
					})
					Invoke-sqmLogging -Message "${name}: kein Full-Backup im Zeitraum $periodLabel." -FunctionName $functionName -Level 'WARNING'
				}
			}

			$failed = @($results | Where-Object { $_.Status -eq 'Failed' })
			if ($failed.Count -gt 0)
			{
				$summary = "Archivkopie fehlgeschlagen fuer: " + (($failed | ForEach-Object { $_.DatabaseName }) -join ', ')
				if ($EnableException) { throw $summary }
				Write-Error $summary
			}

			return $results
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $results
		}
	}
}
