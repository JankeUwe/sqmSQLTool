<#
.SYNOPSIS
    Backup control: checks per database whether the last Full/Diff/Log backups are recent enough,
    honouring the exclusions in master.dbo.sqm_BackupExclude.

.DESCRIPTION
    Evaluates the backup history in msdb against thresholds and reports one status per database:

      OK        All required backups are within the thresholds.
      Warning   Log backup overdue, or no full backup yet but the database is younger than
                -MaxFullAgeHours (the next run should pick it up).
      Critical  No full backup and the database is older than -MaxFullAgeHours, or the newest
                full/diff is older than the threshold.
      Excluded  Marked IsActive = 0 AND IsOrphaned = 0 in master.dbo.sqm_BackupExclude - the same
                condition the backup jobs of New-sqmOlaUsrDbBackupJob / New-sqmBackupMaintenanceJob
                use with -UseExcludeTable. Not an alarm; reason, excluded by and since are listed.
      Skipped   Not checkable here: offline, restoring, not-readable AG secondary without
                reachable primary, ...

    Databases created after the last backup run are flagged (NewSinceLastBackup). "Last backup
    run" = the newest regular (non-COPY_ONLY) full backup of any user database on the instance
    that is not excluded via sqm_BackupExclude (-ExcludeDatabase does not shift it). Such a
    database gets Warning while it is younger than -MaxFullAgeHours and Critical after that.
    All ages are computed against the server clock (GETDATE()), not the client's.

    Only backups taken after the database's create_date count. A database that was dropped and
    recreated or restored under the same name otherwise inherits the backup history of its
    predecessor; this is reported as "only backups of an earlier version".

    COPY_ONLY full backups do not count (they do not form a restore chain); they are listed
    separately.

    AlwaysOn: our backup jobs back up AG databases only on the primary, so the msdb of a secondary
    has no history for them. For AG databases whose local replica is not primary, the backup
    history is read from the current primary replica (same credentials). If the primary cannot
    be reached, the database is reported as Skipped with a note.

    Results are saved as TXT, CSV and HTML.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential, also used for the connection to an AG primary.

.PARAMETER MaxFullAgeHours
    Maximum age of the newest full OR differential backup. Default: 26 (daily full plus margin).

.PARAMETER MaxFullOnlyAgeDays
    Maximum age of the newest full backup alone, relevant when diffs run in between.
    Default: 8 (weekly full plus margin).

.PARAMETER MaxLogAgeMinutes
    Maximum age of the newest log backup for databases in FULL/BULK_LOGGED recovery.
    Default: 60. 0 = do not check log backups.

.PARAMETER ExcludeDatabase
    Databases not to check at all. Wildcards allowed. Independent of sqm_BackupExclude.

.PARAMETER IgnoreExcludeTable
    Ignore master.dbo.sqm_BackupExclude and evaluate excluded databases like all others.

.PARAMETER IncludeSystemDatabases
    Also check master, model and msdb. Default: user databases only.

.PARAMETER OutputPath
    Output directory for the report files. Default: 'BackupStatus' subfolder of the configured
    output path.

.PARAMETER NoOpen
    Do not open the HTML report.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Test-sqmBackupStatus -SqlInstance "SQL01"

.EXAMPLE
    # Weekly full, daily diff, log every 15 minutes
    Test-sqmBackupStatus -SqlInstance "SQL01" -MaxFullOnlyAgeDays 8 -MaxFullAgeHours 26 -MaxLogAgeMinutes 30

.EXAMPLE
    # Only the problem cases
    (Test-sqmBackupStatus -SqlInstance "SQL01" -NoOpen).DetailRows | Where-Object Status -in 'Warning','Critical'

.NOTES
    Author:        MSSQLTools
    Prerequisites: dbatools; read access to msdb.dbo.backupset and sys.databases, VIEW SERVER
                   STATE for the AG role lookup.
    The msdb history is scanned once per instance (one GROUP BY over backupset).
#>
function Test-sqmBackupStatus
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 8760)]
		[int]$MaxFullAgeHours = 26,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 365)]
		[int]$MaxFullOnlyAgeDays = 8,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$MaxLogAgeMinutes = 60,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IgnoreExcludeTable,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'BackupStatus'),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		Invoke-sqmLogging -Message "Starte $functionName (Full/Diff max ${MaxFullAgeHours}h, Full max ${MaxFullOnlyAgeDays}d, Log max ${MaxLogAgeMinutes}min)" -FunctionName $functionName -Level "INFO"

		# Eine Abfrage je Instanz: Datenbanken + AG-Rolle + letzte Sicherungen. backupset wird nur
		# einmal per GROUP BY gelesen statt je Datenbank und Typ. Gezaehlt werden nur Sicherungen
		# ab create_date - eine gleichnamige, geloeschte oder per Restore ersetzte Vorgaengerin
		# vererbt sonst ihre Historie (LastFullBeforeCreate zeigt, dass es so eine gab).
		$backupQuery = @"
SET NOCOUNT ON;
WITH bk AS (
    SELECT d.database_id,
        MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 0 AND b.backup_finish_date >= d.create_date THEN b.backup_finish_date END) AS LastFull,
        MAX(CASE WHEN b.type = 'I' AND b.backup_finish_date >= d.create_date THEN b.backup_finish_date END) AS LastDiff,
        MAX(CASE WHEN b.type = 'L' AND b.is_copy_only = 0 AND b.backup_finish_date >= d.create_date THEN b.backup_finish_date END) AS LastLog,
        MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 1 AND b.backup_finish_date >= d.create_date THEN b.backup_finish_date END) AS LastCopyOnlyFull,
        MAX(CASE WHEN b.type = 'D' AND b.backup_finish_date < d.create_date THEN b.backup_finish_date END) AS LastFullBeforeCreate
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset b
           ON b.database_name COLLATE DATABASE_DEFAULT = d.name COLLATE DATABASE_DEFAULT
          AND b.type IN ('D', 'I', 'L')
    GROUP BY d.database_id
)
SELECT d.name                  AS DatabaseName,
       d.database_id           AS DatabaseId,
       d.create_date           AS CreateDate,
       d.state_desc            AS State,
       d.recovery_model_desc   AS RecoveryModel,
       CAST(d.is_read_only AS int)  AS IsReadOnly,
       CAST(d.is_in_standby AS int) AS IsStandby,
       ag.name                 AS AgName,
       ars.role_desc           AS LocalRole,
       ags.primary_replica     AS PrimaryReplica,
       bk.LastFull, bk.LastDiff, bk.LastLog, bk.LastCopyOnlyFull, bk.LastFullBeforeCreate,
       GETDATE()               AS ServerNow
FROM sys.databases d
JOIN bk ON bk.database_id = d.database_id
LEFT JOIN sys.availability_replicas ar ON ar.replica_id = d.replica_id
LEFT JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = d.replica_id AND ars.is_local = 1
LEFT JOIN sys.dm_hadr_availability_group_states ags ON ags.group_id = ar.group_id
WHERE d.database_id <> 2
  AND d.source_database_id IS NULL;
"@

		function _IsExcludedPattern
		{
			param ([string]$Name, [string[]]$Patterns)
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}
		function _ToDate
		{
			param ($Value)
			if ($null -eq $Value -or $Value -is [DBNull]) { return $null }
			return [datetime]$Value
		}
		function _Fmt
		{
			param ($Value)
			if ($null -eq $Value) { return '' }
			return $Value.ToString('yyyy-MM-dd HH:mm')
		}
		function _Worse
		{
			param ([string]$Current, [string]$Level)
			$rank = @{ OK = 0; Warning = 1; Critical = 2 }
			if ($rank[$Level] -gt $rank[$Current]) { return $Level }
			return $Current
		}
		function _MaxDate
		{
			param ($A, $B)
			if ($null -eq $A) { return $B }
			if ($null -eq $B) { return $A }
			if ($A -gt $B) { return $A } else { return $B }
		}
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()

			try
			{
				Invoke-sqmLogging -Message "[$instance] Lese Backup-Historie ..." -FunctionName $functionName -Level "INFO"
				$allRows = @(Invoke-DbaQuery @connParams -Database master -Query $backupQuery -EnableException)
				# Alter immer gegen die Serveruhr rechnen: backupset/create_date sind Serverortszeit,
				# der Client kann in einer anderen Zeitzone laufen (z. B. Linux-Container in UTC).
				$now = if ($allRows.Count -gt 0 -and -not ($allRows[0].ServerNow -is [DBNull])) { [datetime]$allRows[0].ServerNow } else { Get-Date }
				$dbRows = @($allRows | Where-Object {
						($IncludeSystemDatabases -or [int]$_.DatabaseId -gt 4) -and
						-not (_IsExcludedPattern $_.DatabaseName $ExcludeDatabase)
					})

				# Ausschlusstabelle: dieselbe Bedingung wie die Backup-Jobs (IsActive=0 AND IsOrphaned=0).
				# Fehlt die Tabelle, gibt es keine Ausschluesse - gleicher Fallback wie im Job.
				# "Von/seit" aus der History (letzte Aenderung IsActive -> 0): ExcludedBy/ExcludedAt der
				# Haupttabelle halten nur den INSERT fest (Sync-Job, DDL-Trigger), nicht den Ausschluss.
				$excludeLookup = @{ }
				$hasExcludeTable = $false
				if (-not $IgnoreExcludeTable)
				{
					try
					{
						$exRows = @(Invoke-DbaQuery @connParams -Database master -EnableException -Query @"
IF OBJECT_ID(N'master.dbo.sqm_BackupExclude_History', N'U') IS NOT NULL AND OBJECT_ID(N'master.dbo.sqm_BackupExclude', N'U') IS NOT NULL
    EXEC sp_executesql N'
    SELECT e.DatabaseName, e.Reason, hx.ChangedBy AS ExcludedBy, hx.ChangedAt AS ExcludedAt, e.IsActive, e.IsOrphaned
    FROM master.dbo.sqm_BackupExclude e
    OUTER APPLY (SELECT TOP (1) h.ChangedBy, h.ChangedAt FROM master.dbo.sqm_BackupExclude_History h
                 WHERE h.DatabaseName = e.DatabaseName AND h.ChangedField = N''IsActive'' AND h.NewValue = N''0''
                 ORDER BY h.ChangedAt DESC, h.HistoryId DESC) hx;';
ELSE IF OBJECT_ID(N'master.dbo.sqm_BackupExclude', N'U') IS NOT NULL
    SELECT DatabaseName, Reason, CAST(NULL AS sysname) AS ExcludedBy, CAST(NULL AS datetime2) AS ExcludedAt, IsActive, IsOrphaned
    FROM master.dbo.sqm_BackupExclude;
"@)
						if ($exRows.Count -gt 0) { $hasExcludeTable = $true }
						foreach ($r in $exRows)
						{
							if ([int]$r.IsActive -eq 0 -and [int]$r.IsOrphaned -eq 0) { $excludeLookup[$r.DatabaseName] = $r }
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$instance] sqm_BackupExclude nicht lesbar: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
				}

				# AG-Datenbanken, deren lokales Replikat nicht Primary ist: Historie vom Primary holen,
				# denn unsere Jobs sichern AG-Datenbanken nur dort.
				$primaryData = @{ }
				$primaryError = @{ }
				$secondaryDbs = @($dbRows | Where-Object { -not ($_.AgName -is [DBNull]) -and $_.AgName -and [string]$_.LocalRole -ne 'PRIMARY' })
				foreach ($primary in @($secondaryDbs | ForEach-Object { [string]$_.PrimaryReplica } | Where-Object { $_ } | Sort-Object -Unique))
				{
					try
					{
						$pConn = @{ SqlInstance = $primary }
						if ($SqlCredential) { $pConn['SqlCredential'] = $SqlCredential }
						foreach ($r in @(Invoke-DbaQuery @pConn -Database master -Query $backupQuery -EnableException))
						{
							$primaryData["$primary|$($r.DatabaseName)"] = $r
						}
						Invoke-sqmLogging -Message "[$instance] Backup-Historie der AG-Datenbanken vom Primary $primary gelesen." -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						$primaryError[$primary] = $_.Exception.Message
						Invoke-sqmLogging -Message "[$instance] Primary $primary nicht erreichbar: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
				}

				# Pro Datenbank die massgebliche Historie bestimmen (lokal bzw. Primary)
				$work = foreach ($r in $dbRows)
				{
					$isAg = -not ($r.AgName -is [DBNull]) -and [bool]$r.AgName
					$role = if ($isAg) { [string]$r.LocalRole } else { '' }
					$primary = if ($isAg -and -not ($r.PrimaryReplica -is [DBNull])) { [string]$r.PrimaryReplica } else { '' }
					$src = $r
					$source = 'lokal'
					$sourceError = $null
					if ($isAg -and $role -ne 'PRIMARY')
					{
						$pr = if ($primary) { $primaryData["$primary|$($r.DatabaseName)"] } else { $null }
						if ($pr) { $src = $pr; $source = "Primary $primary" }
						elseif ($primary -and $primaryError.ContainsKey($primary)) { $sourceError = "Primary $primary nicht erreichbar: $($primaryError[$primary])" }
						else { $sourceError = 'Primary unbekannt (Rolle RESOLVING oder keine Rechte auf die AG-DMVs)' }
					}
					# Lokale Sicherungen eines Secondary (z. B. aus der Zeit vor 1.9.166.0) zaehlen mit
					$lastFull = _ToDate $src.LastFull
					$lastDiff = _ToDate $src.LastDiff
					$lastLog = _ToDate $src.LastLog
					$lastCopy = _ToDate $src.LastCopyOnlyFull
					if (-not [object]::ReferenceEquals($src, $r))
					{
						$lastFull = _MaxDate $lastFull (_ToDate $r.LastFull)
						$lastDiff = _MaxDate $lastDiff (_ToDate $r.LastDiff)
						$lastLog = _MaxDate $lastLog (_ToDate $r.LastLog)
						$lastCopy = _MaxDate $lastCopy (_ToDate $r.LastCopyOnlyFull)
					}
					[PSCustomObject]@{
						Row = $r; IsAg = $isAg; Role = $role; Source = $source; SourceError = $sourceError
						CreateDate = _ToDate $src.CreateDate
						LastFull = $lastFull; LastDiff = $lastDiff; LastLog = $lastLog; LastCopyOnlyFull = $lastCopy
						LastFullBeforeCreate = _ToDate $src.LastFullBeforeCreate
					}
				}

				# Letzter Backup-Lauf = neuestes regulaeres Full irgendeiner Benutzerdatenbank. Aus ALLEN
				# Benutzerdatenbanken bestimmt, nicht nur den geprueften - -ExcludeDatabase darf den
				# Lauf nicht verschieben.
				$lastRun = $null
				foreach ($r in $allRows)
				{
					if ([int]$r.DatabaseId -gt 4 -and -not $excludeLookup.ContainsKey($r.DatabaseName)) { $lastRun = _MaxDate $lastRun (_ToDate $r.LastFull) }
				}
				foreach ($w in $work)
				{
					if ([int]$w.Row.DatabaseId -gt 4 -and -not $excludeLookup.ContainsKey($w.Row.DatabaseName)) { $lastRun = _MaxDate $lastRun $w.LastFull }
				}

				foreach ($w in $work)
				{
					$r = $w.Row
					$dbName = [string]$r.DatabaseName
					$notes = [System.Collections.Generic.List[string]]::new()
					$status = 'OK'
					$st = 'OK'

					$recovery = [string]$r.RecoveryModel
					$isReadOnly = [int]$r.IsReadOnly -eq 1
					$created = $w.CreateDate
					$newSinceLastBackup = ($null -ne $lastRun -and $null -ne $created -and $created -gt $lastRun -and $null -eq $w.LastFull)
					$fullOrDiff = _MaxDate $w.LastFull $w.LastDiff
					$fullAgeH = if ($w.LastFull) { ($now - $w.LastFull).TotalHours } else { $null }
					$fodAgeH = if ($fullOrDiff) { ($now - $fullOrDiff).TotalHours } else { $null }
					$logAgeMin = $null
					$ex = $excludeLookup[$dbName]

					if ($ex)
					{
						$st = 'Excluded'
						$reason = if ($ex.Reason -is [DBNull] -or -not $ex.Reason) { '(kein Grund angegeben)' } else { [string]$ex.Reason }
						$since = _ToDate $ex.ExcludedAt
						$who = if ($since) { " - von $($ex.ExcludedBy) seit $(_Fmt $since)" } else { ' - Zeitpunkt unbekannt (keine History)' }
						$notes.Add("Ausgeschlossen (sqm_BackupExclude): $reason$who")
					}
					elseif ([string]$r.State -ne 'ONLINE')
					{
						$st = 'Skipped'
						$notes.Add("Datenbank ist $($r.State) - nicht pruefbar")
					}
					elseif ($w.SourceError)
					{
						$st = 'Skipped'
						$notes.Add("AG-Secondary ($($w.Role)): $($w.SourceError) - Backups dort pruefen")
					}
					else
					{
						# Full / Diff
						if ($null -eq $w.LastFull)
						{
							$ageSinceCreateH = if ($created) { ($now - $created).TotalHours } else { [double]::MaxValue }
							if ($newSinceLastBackup)
							{
								$notes.Add("Nach dem letzten Backup-Lauf ($(_Fmt $lastRun)) angelegt am $(_Fmt $created) - noch kein Full-Backup")
							}
							else
							{
								$notes.Add('Kein Full-Backup seit Anlage der Datenbank' + $(if ($created) { " ($(_Fmt $created))" } else { '' }))
							}
							# Juenger als die Full-Grenze: der naechste Lauf soll sie noch erwischen
							if ($ageSinceCreateH -gt $MaxFullAgeHours) { $st = _Worse $st 'Critical' } else { $st = _Worse $st 'Warning' }
							if ($w.LastFullBeforeCreate)
							{
								$notes.Add("Nur Sicherungen einer frueheren Datenbank gleichen Namens vorhanden (letzte $(_Fmt $w.LastFullBeforeCreate)) - neu angelegt oder per Restore ersetzt")
							}
						}
						else
						{
							if ($fodAgeH -gt $MaxFullAgeHours)
							{
								$notes.Add("Letztes Full/Diff vor $([math]::Round($fodAgeH, 1)) h (Grenze $MaxFullAgeHours h)")
								$st = _Worse $st 'Critical'
							}
							if ($fullAgeH -gt ($MaxFullOnlyAgeDays * 24))
							{
								$notes.Add("Letztes Full vor $([math]::Round($fullAgeH / 24, 1)) Tagen (Grenze $MaxFullOnlyAgeDays Tage)")
								$st = _Worse $st 'Critical'
							}
						}
						if ($null -eq $w.LastFull -and $w.LastCopyOnlyFull)
						{
							$notes.Add("Nur COPY_ONLY-Full vorhanden ($(_Fmt $w.LastCopyOnlyFull)) - zaehlt nicht fuer die Wiederherstellungskette")
						}

						# Log
						if ($MaxLogAgeMinutes -gt 0 -and $recovery -in 'FULL', 'BULK_LOGGED' -and -not $isReadOnly -and $w.LastFull)
						{
							$logRef = if ($w.LastLog) { $w.LastLog } else { $w.LastFull }
							$logAgeMin = ($now - $logRef).TotalMinutes
							if ($logAgeMin -gt $MaxLogAgeMinutes)
							{
								if ($w.LastLog) { $notes.Add("Letztes Log-Backup vor $([math]::Round($logAgeMin, 0)) min (Grenze $MaxLogAgeMinutes min)") }
								else { $notes.Add("Kein Log-Backup seit dem Full vor $([math]::Round($logAgeMin, 0)) min (Recovery $recovery)") }
								$st = _Worse $st 'Warning'
							}
							if (-not $w.LastLog) { $logAgeMin = $null }
						}
						if ($isReadOnly) { $notes.Add('READ_ONLY - Log-Backups nicht erforderlich') }
					}
					if ($newSinceLastBackup -and $st -in 'Excluded', 'Skipped')
					{
						$notes.Add("Nach dem letzten Backup-Lauf ($(_Fmt $lastRun)) angelegt am $(_Fmt $created)")
					}
					if ($w.Source -ne 'lokal' -and $st -notin 'Excluded', 'Skipped') { $notes.Add("Historie vom $($w.Source)") }
					$status = $st

					$detailRows.Add([PSCustomObject]@{
							SqlInstance        = $instance
							Database           = $dbName
							Status             = $status
							RecoveryModel      = $recovery
							State              = [string]$r.State
							CreateDate         = _Fmt $created
							NewSinceLastBackup = $newSinceLastBackup
							LastFullBackup     = if ($w.LastFull) { _Fmt $w.LastFull } else { '(keins)' }
							LastDiffBackup     = _Fmt $w.LastDiff
							LastLogBackup      = _Fmt $w.LastLog
							LastCopyOnlyFull   = _Fmt $w.LastCopyOnlyFull
							FullAgeHours       = if ($null -ne $fullAgeH) { [math]::Round($fullAgeH, 1) } else { $null }
							LogAgeMinutes      = if ($null -ne $logAgeMin) { [math]::Round($logAgeMin, 0) } else { $null }
							ExcludedFromBackup = [bool]$ex
							ExcludeReason      = if ($ex -and -not ($ex.Reason -is [DBNull])) { [string]$ex.Reason } else { $null }
							AvailabilityGroup  = if ($w.IsAg) { [string]$r.AgName } else { '' }
							ReplicaRole        = $w.Role
							HistorySource      = $w.Source
							Notes              = ($notes -join '; ')
						})
				}

				$cnt = @{ }
				foreach ($s in 'OK', 'Warning', 'Critical', 'Excluded', 'Skipped') { $cnt[$s] = @($detailRows | Where-Object Status -eq $s).Count }
				$newNames = @($detailRows | Where-Object NewSinceLastBackup | Select-Object -ExpandProperty Database)
				$overall = if ($cnt.Critical -gt 0) { 'Critical' } elseif ($cnt.Warning -gt 0) { 'Warning' } else { 'OK' }

				# Berichte
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$fileStamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
				$txtFile = Join-Path $OutputPath "BackupStatus_${safeInst}_$fileStamp.txt"
				$csvFile = Join-Path $OutputPath "BackupStatus_${safeInst}_$fileStamp.csv"
				$htmlFile = Join-Path $OutputPath "BackupStatus_${safeInst}_$fileStamp.html"
				$sorted = @($detailRows | Sort-Object @{ e = { switch ($_.Status) { 'Critical' { 0 } 'Warning' { 1 } 'Skipped' { 2 } 'OK' { 3 } default { 4 } } } }, Database)
				$exTxt = if ($IgnoreExcludeTable) { 'ignoriert (-IgnoreExcludeTable)' } elseif ($hasExcludeTable) { "$($cnt.Excluded) Datenbank(en) ausgeschlossen" } else { 'nicht vorhanden - keine Ausschluesse' }

				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Backup-Status-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null }

					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - Backup-Kontrolle")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz          : $instance")
					$lines.Add("# Erstellt         : $timestamp")
					$lines.Add("# Grenzen          : Full/Diff $MaxFullAgeHours h | Full $MaxFullOnlyAgeDays Tage | Log $(if ($MaxLogAgeMinutes -gt 0) { "$MaxLogAgeMinutes min" } else { 'nicht geprueft' })")
					$lines.Add("# Letzter Lauf     : $(if ($lastRun) { _Fmt $lastRun } else { '(kein Full-Backup einer Benutzerdatenbank gefunden)' })")
					$lines.Add("# sqm_BackupExclude: $exTxt")
					$lines.Add("# OK: $($cnt.OK) | Warning: $($cnt.Warning) | Critical: $($cnt.Critical) | Excluded: $($cnt.Excluded) | Skipped: $($cnt.Skipped)")
					if ($newNames.Count -gt 0) { $lines.Add("# Nach dem letzten Backup-Lauf angelegt: $($newNames -join ', ')") }
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-35} {1,-9} {2,-12} {3,-16} {4,-16} {5,-16} {6}" -f 'Datenbank', 'Status', 'Recovery', 'Letztes Full', 'Letztes Diff', 'Letztes Log', 'Hinweise'))
					$lines.Add(("-" * 150))
					foreach ($e in $sorted)
					{
						$n = if ($e.Database.Length -gt 35) { $e.Database.Substring(0, 32) + '...' } else { $e.Database }
						$lines.Add(("{0,-35} {1,-9} {2,-12} {3,-16} {4,-16} {5,-16} {6}" -f $n, $e.Status, $e.RecoveryModel, $e.LastFullBackup, $e.LastDiffBackup, $e.LastLogBackup, $e.Notes))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Delimiter ';' -Force

					$enc = { param ($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
					$rowsHtml = foreach ($e in $sorted)
					{
						$cls = switch ($e.Status) { 'Critical' { 'crit' } 'Warning' { 'warn' } 'OK' { 'ok' } default { '' } }
						$newCell = if ($e.NewSinceLastBackup) { 'ja' } else { '' }
						"<tr><td class='$cls'>$($e.Status)</td><td>$(& $enc $e.Database)</td><td>$($e.RecoveryModel)</td><td>$($e.CreateDate)</td><td>$newCell</td><td>$($e.LastFullBackup)</td><td>$($e.LastDiffBackup)</td><td>$($e.LastLogBackup)</td><td>$(& $enc $e.AvailabilityGroup)</td><td>$(& $enc $e.Notes)</td></tr>"
					}
					$summary = "<p>Grenzen: Full/Diff $MaxFullAgeHours h | Full $MaxFullOnlyAgeDays Tage | Log $(if ($MaxLogAgeMinutes -gt 0) { "$MaxLogAgeMinutes min" } else { 'nicht geprueft' })<br>" +
						"Letzter Backup-Lauf: $(if ($lastRun) { _Fmt $lastRun } else { '(keiner gefunden)' }) | sqm_BackupExclude: $(& $enc $exTxt)<br>" +
						"OK: $($cnt.OK) | Warning: $($cnt.Warning) | Critical: $($cnt.Critical) | Excluded: $($cnt.Excluded) | Skipped: $($cnt.Skipped)</p>"
					if ($newNames.Count -gt 0) { $summary += "<p class='warn'>Nach dem letzten Backup-Lauf angelegt: $(& $enc ($newNames -join ', '))</p>" }
					$bodyHtml = $summary + "<table><tr><th>Status</th><th>Datenbank</th><th>Recovery</th><th>Angelegt</th><th>Neu seit Lauf</th><th>Letztes Full</th><th>Letztes Diff</th><th>Letztes Log</th><th>AG</th><th>Hinweise</th></tr>" + ($rowsHtml -join '') + "</table>"
					ConvertTo-sqmHtmlReport -Title "Backup-Kontrolle - $instance" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
				}
				else
				{
					$txtFile = $null; $csvFile = $null; $htmlFile = $null
				}

				$lvl = if ($overall -eq 'OK') { 'INFO' } else { 'WARNING' }
				Invoke-sqmLogging -Message "[$instance] Backup-Kontrolle: OK $($cnt.OK), Warning $($cnt.Warning), Critical $($cnt.Critical), Excluded $($cnt.Excluded), Skipped $($cnt.Skipped)$(if ($newNames.Count -gt 0) { "; neu seit letztem Lauf: $($newNames -join ', ')" })" -FunctionName $functionName -Level $lvl

				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance         = $instance
						Timestamp           = $timestamp
						Status              = $overall
						LastBackupRun       = $lastRun
						ExcludeTablePresent = $hasExcludeTable
						OkCount             = $cnt.OK
						WarningCount        = $cnt.Warning
						CriticalCount       = $cnt.Critical
						ExcludedCount       = $cnt.Excluded
						SkippedCount        = $cnt.Skipped
						NewSinceLastBackup  = $newNames
						DetailRows          = $detailRows
						TxtFile             = $txtFile
						CsvFile             = $csvFile
						HtmlFile            = $htmlFile
					})
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status      = 'Error'
						Message     = $errMsg
						DetailRows  = $null
						TxtFile     = $null
						CsvFile     = $null
						HtmlFile    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanz(en) verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}
