<#
.SYNOPSIS
    Ermittelt, warum das Transaktionsprotokoll einer Datenbank aktive VLFs hat bzw. nicht
    verkleinert werden kann, und warum es viele VLFs hat.

.DESCRIPTION
    Wird von Invoke-sqmLogShrink vor und nach dem Shrink aufgerufen. Liest nur Metadaten
    (sys.databases, sys.database_files, sys.dm_db_log_space_usage, sys.dm_db_log_info bzw.
    DBCC LOGINFO, sys.dm_tran_*, sys.dm_hadr_database_replica_states, msdb.dbo.backupset) und
    kostet daher praktisch nichts.

    Zwei getrennte Fragen werden beantwortet:

    1. Warum ist das Log aktiv / warum kann der Shrink nicht weiter verkleinern?
       - log_reuse_wait_desc (LOG_BACKUP, ACTIVE_TRANSACTION, AVAILABILITY_REPLICA, REPLICATION,
         CHECKPOINT, ACTIVE_BACKUP_OR_RESTORE, ...) mit Detail: offene Transaktion (Session, Login,
         Host, Programm, seit wann), letztes Log-Backup, nachhinkendes AG-Replikat,
         Replikation/CDC.
       - Position des letzten aktiven VLF: DBCC SHRINKFILE kann eine Log-Datei nur bis zum Ende
         des letzten aktiven VLF verkleinern. Liegt es am Dateiende, bringt ein Shrink nichts,
         auch wenn log_reuse_wait_desc NOTHING meldet (Log muss erst "umlaufen").

    2. Warum gibt es so viele VLFs?
       - prozentuales Wachstum, kleiner fester Zuwachs, viele sehr kleine VLFs (Spuren frueherer
         kleiner Zuwachse bzw. Shrink/Grow-Zyklen) - mit Empfehlung fuer Zielgroesse und Autogrowth.

.PARAMETER ConnParams
    Hashtable mit SqlInstance (und optional SqlCredential) fuer Invoke-DbaQuery.

.PARAMETER Database
    Name der Datenbank.

.OUTPUTS
    PSCustomObject mit LogReuseWait, Cause, Recommendation, VlfCount, ActiveVlfCount,
    VlfStatus, VlfCause, VlfRecommendation, Files (je Log-Datei: LogicalName, Size_MB,
    ActiveEnd_MB, VlfCount, Growth) und Details.
#>
function Get-sqmLogReuseDiagnosis
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[hashtable]$ConnParams,
		[Parameter(Mandatory = $true)]
		[string]$Database
	)

	$functionName = $MyInvocation.MyCommand.Name
	$details = [System.Collections.Generic.List[string]]::new()

	# ---- Grunddaten: Wartegrund, Recovery Model, Log-Auslastung, Log-Dateien ----
	$baseQuery = @"
SET NOCOUNT ON;
SELECT d.log_reuse_wait_desc AS LogReuseWait, d.recovery_model_desc AS RecoveryModel,
       d.is_published AS IsPublished, d.is_cdc_enabled AS IsCdcEnabled,
       CAST(ls.total_log_size_in_bytes / 1048576.0 AS decimal(19,2)) AS LogSize_MB,
       CAST(ls.used_log_space_in_percent AS decimal(9,2)) AS LogUsed_Pct
FROM sys.databases d
CROSS JOIN sys.dm_db_log_space_usage ls
WHERE d.database_id = DB_ID();
"@
	$fileQuery = @"
SET NOCOUNT ON;
SELECT file_id AS FileId, name AS LogicalName,
       CAST(size * 8 / 1024.0 AS decimal(19,2)) AS Size_MB,
       is_percent_growth AS IsPercentGrowth,
       CASE WHEN is_percent_growth = 1 THEN growth ELSE CAST(growth * 8 / 1024 AS int) END AS Growth,
       max_size AS MaxSize
FROM sys.database_files WHERE type = 1;
"@
	$base = @(Invoke-DbaQuery @ConnParams -Database $Database -Query $baseQuery -EnableException)[0]
	$files = @(Invoke-DbaQuery @ConnParams -Database $Database -Query $fileQuery -EnableException)

	# ---- VLFs: sys.dm_db_log_info (ab 2016 SP2), sonst DBCC LOGINFO ----
	$vlfs = @()
	$hasLogInfo = @(Invoke-DbaQuery @ConnParams -Database $Database -Query "SELECT CASE WHEN OBJECT_ID('sys.dm_db_log_info') IS NULL THEN 0 ELSE 1 END AS HasLogInfo" -EnableException)[0].HasLogInfo
	if ($hasLogInfo -eq 1)
	{
		$vlfs = @(Invoke-DbaQuery @ConnParams -Database $Database -EnableException -Query @"
SET NOCOUNT ON;
SELECT file_id AS FileId, CAST(vlf_begin_offset AS bigint) AS BeginOffset,
       CAST(vlf_size_mb AS float) AS Size_MB, CAST(vlf_active AS int) AS IsActive
FROM sys.dm_db_log_info(DB_ID());
"@)
	}
	else
	{
		$vlfs = @(Invoke-DbaQuery @ConnParams -Database $Database -Query 'DBCC LOGINFO WITH NO_INFOMSGS;' -EnableException | ForEach-Object {
				[PSCustomObject]@{
					FileId	    = [int]$_.FileId
					BeginOffset = [long]$_.StartOffset
					Size_MB	    = [double]$_.FileSize / 1MB
					IsActive    = $(if ([int]$_.Status -eq 2) { 1 } else { 0 })
				}
			})
	}

	$fileInfo = foreach ($f in $files)
	{
		$fv = @($vlfs | Where-Object { $_.FileId -eq $f.FileId })
		$active = @($fv | Where-Object { $_.IsActive -eq 1 })
		$activeEnd = 0
		foreach ($v in $active)
		{
			$end = ($v.BeginOffset / 1MB) + $v.Size_MB
			if ($end -gt $activeEnd) { $activeEnd = $end }
		}
		[PSCustomObject]@{
			FileId		    = [int]$f.FileId
			LogicalName	    = $f.LogicalName
			Size_MB		    = [double]$f.Size_MB
			ActiveEnd_MB    = [math]::Ceiling($activeEnd)
			VlfCount	    = $fv.Count
			ActiveVlfCount  = $active.Count
			IsPercentGrowth = [bool]$f.IsPercentGrowth
			Growth		    = [int]$f.Growth
			GrowthText	    = $(if ($f.IsPercentGrowth) { "$($f.Growth) %" } elseif ([int]$f.Growth -eq 0) { 'kein Autogrowth' } else { "$($f.Growth) MB" })
		}
	}
	$fileInfo = @($fileInfo)

	$vlfCount = $vlfs.Count
	$activeVlfCount = @($vlfs | Where-Object { $_.IsActive -eq 1 }).Count
	$logReuseWait = [string]$base.LogReuseWait
	$recoveryModel = [string]$base.RecoveryModel

	# ---- Aelteste offene Transaktion: haelt den aktiven Teil fest, egal welchen Wartegrund SQL Server meldet ----
	$oldestTranText = $null
	try
	{
		$tran = @(Invoke-DbaQuery @ConnParams -Database $Database -EnableException -Query @"
SET NOCOUNT ON;
SELECT TOP (1) st.session_id AS SessionId, s.login_name AS LoginName, s.host_name AS HostName,
       s.program_name AS ProgramName, s.status AS SessionStatus,
       dt.database_transaction_begin_time AS BeginTime,
       DATEDIFF(MINUTE, dt.database_transaction_begin_time, GETDATE()) AS AgeMinutes,
       CAST(dt.database_transaction_log_bytes_used / 1048576.0 AS decimal(19,2)) AS LogUsed_MB
FROM sys.dm_tran_database_transactions dt
LEFT JOIN sys.dm_tran_session_transactions st ON st.transaction_id = dt.transaction_id
LEFT JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
WHERE dt.database_id = DB_ID() AND dt.database_transaction_begin_time IS NOT NULL
ORDER BY dt.database_transaction_begin_time;
"@)
		if ($tran.Count -gt 0)
		{
			$t = $tran[0]
			$who = if ($t.SessionId -isnot [DBNull] -and $t.SessionId) { "Session $($t.SessionId) ($($t.LoginName) von $($t.HostName), $($t.ProgramName), Status $($t.SessionStatus))" } else { 'ohne Sitzung (z. B. verteilte/verwaiste Transaktion)' }
			$txt = "Aelteste Transaktion: $who, offen seit $(([datetime]$t.BeginTime).ToString('yyyy-MM-dd HH:mm')) ($($t.AgeMinutes) min), $($t.LogUsed_MB) MB Log."
			$oldestTranText = $txt
			$details.Add($txt)
		}
	}
	catch { Invoke-sqmLogging -Message "[$Database] Offene Transaktion nicht ermittelbar: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE" }

	# ---- Frage 1: Warum ist das Log aktiv? ----
	$cause = $null
	$recommendation = $null
	switch ($logReuseWait)
	{
		'NOTHING'
		{
			$cause = 'Keine Wartebedingung (log_reuse_wait_desc = NOTHING), das Log ist wiederverwendbar.'
		}
		'CHECKPOINT'
		{
			$cause = 'Seit der letzten Log-Kuerzung ist noch kein Checkpoint gelaufen (CHECKPOINT).'
			$recommendation = "In der Datenbank CHECKPOINT ausfuehren und den Shrink wiederholen."
		}
		'OLDEST_PAGE'
		{
			$cause = 'Indirekter Checkpoint: die aelteste schmutzige Seite haelt das Log (OLDEST_PAGE).'
			$recommendation = "CHECKPOINT ausfuehren und den Shrink wiederholen."
		}
		'LOG_BACKUP'
		{
			$lastLog = $null
			try
			{
				$lastLog = @(Invoke-DbaQuery @ConnParams -Database msdb -EnableException -SqlParameter @{ db = $Database } -Query @"
SELECT MAX(backup_finish_date) AS LastLogBackup FROM msdb.dbo.backupset WHERE database_name = @db AND type = 'L';
"@)[0].LastLogBackup
			}
			catch { Invoke-sqmLogging -Message "[$Database] msdb.dbo.backupset nicht lesbar: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE" }
			$lastLogText = if ($lastLog -and $lastLog -isnot [DBNull]) { ([datetime]$lastLog).ToString('yyyy-MM-dd HH:mm') } else { 'nie' }
			$cause = "Das Log wartet auf ein Log-Backup (Recovery Model $recoveryModel). Letztes Log-Backup: $lastLogText."
			$recommendation = "Log-Backup ausfuehren (Invoke-sqmUserDatabaseBackup -Database '$Database' -BackupType LOG) und den Shrink wiederholen; ggf. muss das Log zweimal gesichert werden, damit der aktive Teil an den Dateianfang wandert. Wird kein Point-in-Time-Restore benoetigt, Recovery Model SIMPLE pruefen."
			$details.Add("Letztes Log-Backup: $lastLogText")
		}
		'ACTIVE_TRANSACTION'
		{
			$cause = 'Eine offene Transaktion haelt das Log (ACTIVE_TRANSACTION).'
			$recommendation = 'Die Transaktion abschliessen lassen (COMMIT/ROLLBACK) bzw. die Sitzung pruefen (Get-sqmWhoIsActive, notfalls Stop-sqmSqlProcess) und den Shrink danach wiederholen.'
			if ($oldestTranText) { $cause += " $oldestTranText" }
		}
		'AVAILABILITY_REPLICA'
		{
			$cause = 'Ein AlwaysOn-Secondary hat das Log noch nicht empfangen bzw. wiederhergestellt (AVAILABILITY_REPLICA).'
			$recommendation = 'Zustand der Secondaries pruefen (Get-sqmAlwaysOnQueueStatus): angehaltene Datenbewegung fortsetzen, Netzwerk/Redo-Rueckstand beheben. Erst danach kann das Log gekuerzt werden.'
			try
			{
				$reps = @(Invoke-DbaQuery @ConnParams -Database master -EnableException -SqlParameter @{ db = $Database } -Query @"
SET NOCOUNT ON;
SELECT ar.replica_server_name AS Replica, drs.synchronization_state_desc AS SyncState,
       drs.is_suspended AS IsSuspended, drs.suspend_reason_desc AS SuspendReason,
       drs.log_send_queue_size AS SendQueue_KB, drs.redo_queue_size AS RedoQueue_KB
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE drs.database_id = DB_ID(@db) AND drs.is_local = 0
ORDER BY ISNULL(drs.log_send_queue_size, 0) + ISNULL(drs.redo_queue_size, 0) DESC;
"@)
				foreach ($r in $reps)
				{
					$susp = if ($r.IsSuspended -eq $true -or $r.IsSuspended -eq 1) { ", ANGEHALTEN ($($r.SuspendReason))" } else { '' }
					$details.Add("Replikat $($r.Replica): $($r.SyncState)$susp, Send-Queue $($r.SendQueue_KB) KB, Redo-Queue $($r.RedoQueue_KB) KB")
				}
				if ($reps.Count -gt 0) { $cause += " Groesster Rueckstand: $($details[0])." }
			}
			catch { Invoke-sqmLogging -Message "[$Database] AG-Replikatstatus nicht ermittelbar: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE" }
		}
		'REPLICATION'
		{
			$what = @()
			if ($base.IsPublished -eq $true -or $base.IsPublished -eq 1) { $what += 'Transaktionsreplikation (Log Reader Agent)' }
			if ($base.IsCdcEnabled -eq $true -or $base.IsCdcEnabled -eq 1) { $what += 'Change Data Capture (Capture-Job)' }
			if ($what.Count -eq 0) { $what += 'Replikation/CDC (Datenbank ist nicht mehr als veroeffentlicht markiert - evtl. Reste einer entfernten Replikation)' }
			$cause = "Das Log wurde noch nicht vom Lesedienst verarbeitet: $($what -join ', ') (REPLICATION)."
			$recommendation = 'Log Reader Agent bzw. CDC-Capture-Job pruefen und starten. Sind Replikation/CDC nicht mehr in Gebrauch, Reste entfernen (sp_removedbreplication bzw. sys.sp_cdc_disable_db).'
		}
		'ACTIVE_BACKUP_OR_RESTORE'
		{
			$cause = 'Ein Backup oder Restore laeuft gerade (ACTIVE_BACKUP_OR_RESTORE).'
			$recommendation = 'Ende des laufenden Backups abwarten und den Shrink danach wiederholen.'
		}
		'DATABASE_MIRRORING'
		{
			$cause = 'Database Mirroring: der Spiegel ist angehalten oder hinkt hinterher (DATABASE_MIRRORING).'
			$recommendation = 'Spiegelungssitzung pruefen und fortsetzen.'
		}
		'DATABASE_SNAPSHOT_CREATION'
		{
			$cause = 'Ein Datenbank-Snapshot wird gerade erstellt (z. B. durch DBCC CHECKDB).'
			$recommendation = 'Ende des Snapshots bzw. von DBCC CHECKDB abwarten.'
		}
		'LOG_SCAN'
		{
			$cause = 'Ein Log-Scan laeuft gerade (LOG_SCAN).'
			$recommendation = 'Kurz warten und den Shrink wiederholen.'
		}
		'XTP_CHECKPOINT'
		{
			$cause = 'In-Memory OLTP: es wartet ein XTP-Checkpoint (XTP_CHECKPOINT).'
			$recommendation = 'CHECKPOINT ausfuehren und den Shrink wiederholen.'
		}
		default
		{
			$cause = "log_reuse_wait_desc = $logReuseWait."
			$recommendation = 'Ursache laut SQL-Server-Dokumentation zu log_reuse_wait_desc pruefen und den Shrink danach wiederholen.'
		}
	}

	# Aktiver VLF am Dateiende: Shrink bringt nichts, auch wenn kein Wartegrund gemeldet wird
	foreach ($fi in $fileInfo)
	{
		if ($fi.ActiveVlfCount -gt 0 -and $fi.Size_MB -gt 0 -and $fi.ActiveEnd_MB -ge ($fi.Size_MB - 1))
		{
			$txt = "Log-Datei '$($fi.LogicalName)': der aktive Teil liegt am Dateiende ($($fi.ActiveVlfCount) aktive VLF(s) bis $($fi.ActiveEnd_MB) MB von $($fi.Size_MB) MB) - ein Shrink kann derzeit nichts freigeben."
			$details.Add($txt)
			if ($logReuseWait -eq 'NOTHING')
			{
				$cause = "Kein Wartegrund gemeldet, aber der aktive Teil des Logs liegt am Dateiende ($($fi.ActiveEnd_MB) von $($fi.Size_MB) MB)."
				$recommendation = if ($recoveryModel -eq 'SIMPLE') { 'CHECKPOINT ausfuehren (ggf. mehrfach, bis das Log an den Dateianfang umlaeuft) und den Shrink wiederholen.' } else { 'Log-Backup ausfuehren (ggf. zweimal, bis das Log an den Dateianfang umlaeuft) und den Shrink wiederholen.' }
			}
		}
	}

	# Offene Transaktion bei anderem Wartegrund: log_reuse_wait_desc zeigt nur den Grund des letzten
	# Kuerzungsversuchs (z. B. OLDEST_PAGE direkt nach einem Log-Backup), die Transaktion haelt trotzdem fest
	if ($oldestTranText -and $logReuseWait -ne 'ACTIVE_TRANSACTION')
	{
		$cause += " Zusaetzlich offen: $oldestTranText Solange sie laeuft, kann das Log ab ihrem Beginn nicht gekuerzt werden."
		$tranRec = 'Offene Transaktion abschliessen lassen bzw. Sitzung pruefen (Get-sqmWhoIsActive, notfalls Stop-sqmSqlProcess).'
		$recommendation = if ($recommendation) { "$tranRec $recommendation" } else { $tranRec }
	}

	# ---- Frage 2: Warum gibt es so viele VLFs? ----
	$vlfStatus = if ($vlfCount -ge 1000) { 'Critical' } elseif ($vlfCount -ge 300) { 'Warning' } else { 'OK' }
	$vlfCauses = [System.Collections.Generic.List[string]]::new()
	$vlfRecommendation = $null
	$smallVlfs = @($vlfs | Where-Object { $_.Size_MB -lt 1 }).Count
	foreach ($fi in $fileInfo)
	{
		if ($fi.IsPercentGrowth -and $fi.Growth -gt 0)
		{
			$vlfCauses.Add("Prozentuales Wachstum ($($fi.Growth) %) bei '$($fi.LogicalName)': bei kleiner Ausgangsgroesse entstehen viele kleine Zuwachse und damit viele kleine VLFs.")
		}
		elseif (-not $fi.IsPercentGrowth -and $fi.Growth -gt 0 -and $fi.Growth -lt 64)
		{
			$vlfCauses.Add("Kleiner fester Zuwachs ($($fi.Growth) MB) bei '$($fi.LogicalName)': jedes Wachstum legt 4-8 neue kleine VLFs an.")
		}
	}
	if ($vlfStatus -ne 'OK')
	{
		if ($smallVlfs -gt 0)
		{
			$vlfCauses.Add("$smallVlfs VLF(s) sind kleiner als 1 MB - Spuren vieler kleiner Zuwachse (z. B. aus der model-Vorgabe) oder wiederholter Shrink/Grow-Zyklen.")
		}
		if ($vlfCauses.Count -eq 0)
		{
			$vlfCauses.Add('Die aktuelle Wachstumseinstellung ist unauffaellig; die VLFs stammen vermutlich aus frueheren kleinen Zuwachsen oder Shrink/Grow-Zyklen und bleiben bis zu einem Shrink erhalten.')
		}

		$logSize = [double]$base.LogSize_MB
		$growthRec = if ($logSize -lt 1024) { 256 } elseif ($logSize -lt 65536) { 1024 } else { 8192 }
		$vlfRecommendation = "Viele VLFs verlangsamen Recovery, Restore, AG-Redo und Log-Backups. Abhilfe: Log (nach Log-Backup bzw. CHECKPOINT) so weit wie moeglich shrinken, dann in einem Schritt auf die benoetigte Groesse (bisher $([math]::Round($logSize, 0)) MB) vergroessern und Autogrowth fest auf $growthRec MB stellen (ALTER DATABASE ... MODIFY FILE (NAME = ..., SIZE = ..., FILEGROWTH = $($growthRec)MB))."
	}

	[PSCustomObject]@{
		Database		  = $Database
		RecoveryModel	  = $recoveryModel
		LogReuseWait	  = $logReuseWait
		LogSize_MB	      = [double]$base.LogSize_MB
		LogUsed_Pct	      = [double]$base.LogUsed_Pct
		Cause			  = $cause
		Recommendation    = $recommendation
		VlfCount		  = $vlfCount
		ActiveVlfCount    = $activeVlfCount
		VlfStatus		  = $vlfStatus
		VlfCause		  = $(if ($vlfCauses.Count -gt 0) { $vlfCauses -join ' ' } else { $null })
		VlfRecommendation = $vlfRecommendation
		Files			  = $fileInfo
		Details		      = @($details)
	}
}
