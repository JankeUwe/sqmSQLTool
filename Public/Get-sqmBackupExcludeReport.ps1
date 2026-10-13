<#
.SYNOPSIS
    Report of the backup exclusion table master.dbo.sqm_BackupExclude: what is excluded, why,
    by whom and since when, plus the databases the table does not know.

.DESCRIPTION
    Reads master.dbo.sqm_BackupExclude and, if present, master.dbo.sqm_BackupExclude_History and
    combines them with sys.databases and the msdb backup history. One row per database:

      Excluded    IsActive = 0 AND IsOrphaned = 0 - skipped by the backup jobs with
                  -UseExcludeTable (New-sqmOlaUsrDbBackupJob, New-sqmBackupMaintenanceJob)
      Active      IsActive = 1 - backed up (the default for newly discovered databases)
      Orphaned    IsOrphaned = 1 - database no longer exists, the row is kept
      NotInTable  database exists but has no row yet - backed up; the next
                  Sync-sqmBackupExcludeTable run or the DDL trigger adds it

    "Excluded by / since" comes from the history table (the last change of IsActive to 0).
    The columns ExcludedBy/ExcludedAt of sqm_BackupExclude only record when the row was inserted,
    usually by the sync job or the DDL trigger, not when someone excluded the database. Without
    history table the report says so instead of showing a wrong date.

    Hints per excluded database:
      - no reason entered
      - FULL/BULK_LOGGED recovery: nobody backs up its log, so the log is never truncated and
        grows until the disk is full (switch to SIMPLE or back up the log otherwise)
      - excluded, but a regular full backup exists after the exclusion (someone backs it up anyway)

    Results are saved as TXT, CSV and HTML. With -IncludeHistory the change log of the last
    -HistoryDays days is added to the report and the result object.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER Status
    Which rows to report: All (default), Excluded, Active, Orphaned, NotInTable.

.PARAMETER IncludeHistory
    Add the change log (sqm_BackupExclude_History) of the last -HistoryDays days.

.PARAMETER HistoryDays
    Days of change log for -IncludeHistory. Default: 90.

.PARAMETER OutputPath
    Output directory for the report files. Default: 'BackupExclude' subfolder of the configured
    output path.

.PARAMETER NoOpen
    Do not open the HTML report.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmBackupExcludeReport -SqlInstance "SQL01"

.EXAMPLE
    # Only the excluded databases, with change log of the last 180 days
    Get-sqmBackupExcludeReport -SqlInstance "SQL01" -Status Excluded -IncludeHistory -HistoryDays 180

.EXAMPLE
    # All AG replicas: the table is propagated, the report shows whether they agree
    Get-sqmBackupExcludeReport -SqlInstance "SQLNODE1", "SQLNODE2" -Status Excluded -NoOpen

.NOTES
    Author:        MSSQLTools
    Prerequisites: dbatools; SELECT on master.dbo.sqm_BackupExclude(_History), read on msdb.dbo.backupset.
    Read-only, changes nothing. Editing: Show-sqmBackupExcludeForm.
#>
function Get-sqmBackupExcludeReport
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateSet('All', 'Excluded', 'Active', 'Orphaned', 'NotInTable')]
		[string]$Status = 'All',
		[Parameter(Mandatory = $false)]
		[switch]$IncludeHistory,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 3650)]
		[int]$HistoryDays = 90,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'BackupExclude'),
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
		Invoke-sqmLogging -Message "Starte $functionName (Status=$Status, IncludeHistory=$IncludeHistory)" -FunctionName $functionName -Level "INFO"

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
		function _Str
		{
			param ($Value)
			if ($null -eq $Value -or $Value -is [DBNull]) { return '' }
			return [string]$Value
		}
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			$historyRows = @()

			try
			{
				$probe = Invoke-DbaQuery @connParams -Database master -EnableException -Query @"
SELECT CAST(CASE WHEN OBJECT_ID(N'master.dbo.sqm_BackupExclude', N'U') IS NULL THEN 0 ELSE 1 END AS int) AS HasTable,
       CAST(CASE WHEN OBJECT_ID(N'master.dbo.sqm_BackupExclude_History', N'U') IS NULL THEN 0 ELSE 1 END AS int) AS HasHistory,
       CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.server_triggers WHERE name LIKE N'%sqm[_]BackupExclude%') THEN 1 ELSE 0 END AS int) AS HasDdlTrigger;
"@
				$hasTable = [int]$probe.HasTable -eq 1
				$hasHistory = [int]$probe.HasHistory -eq 1
				$hasDdlTrigger = [int]$probe.HasDdlTrigger -eq 1

				if (-not $hasTable)
				{
					$msg = "[$instance] master.dbo.sqm_BackupExclude existiert nicht - es gibt keine Ausschluesse, alle Datenbanken werden gesichert."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance; Status = 'NoTable'; Message = $msg; TablePresent = $false; HistoryPresent = $false
							DdlTriggerPresent = $hasDdlTrigger; ExcludedCount = 0; ActiveCount = 0; OrphanedCount = 0; NotInTableCount = 0
							DetailRows = @(); History = @(); TxtFile = $null; CsvFile = $null; HtmlFile = $null
						})
					continue
				}

				# Wer/wann wirklich ausgeschlossen hat, steht nur in der History (letzte Aenderung IsActive -> 0).
				# ExcludedBy/ExcludedAt der Haupttabelle = Zeitpunkt des INSERT (Sync-Job, DDL-Trigger).
				$histApply = if ($hasHistory)
				{
					@"
OUTER APPLY (SELECT TOP (1) h.ChangedBy, h.ChangedAt
             FROM master.dbo.sqm_BackupExclude_History h
             WHERE h.DatabaseName = e.DatabaseName AND h.ChangedField = N'IsActive' AND h.NewValue = N'0'
             ORDER BY h.ChangedAt DESC, h.HistoryId DESC) hx
"@
				}
				else { "OUTER APPLY (SELECT CAST(NULL AS sysname) AS ChangedBy, CAST(NULL AS datetime2) AS ChangedAt) hx" }

				$query = @"
SET NOCOUNT ON;
WITH bk AS (
    SELECT b.database_name COLLATE DATABASE_DEFAULT AS DatabaseName,
           MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 0 THEN b.backup_finish_date END) AS LastFull,
           MAX(CASE WHEN b.type = 'L' AND b.is_copy_only = 0 THEN b.backup_finish_date END) AS LastLog
    FROM msdb.dbo.backupset b
    WHERE b.type IN ('D', 'L')
    GROUP BY b.database_name
), sz AS (
    SELECT database_id, CAST(SUM(CAST(size AS bigint)) * 8 / 1024.0 AS decimal(18, 1)) AS SizeMB
    FROM sys.master_files GROUP BY database_id
), src AS (
    SELECT e.DatabaseName COLLATE DATABASE_DEFAULT AS DatabaseName, 1 AS InTable,
           CAST(e.IsActive AS int) AS IsActive, CAST(e.IsOrphaned AS int) AS IsOrphaned, e.Reason,
           e.ExcludedBy AS RowAddedBy, e.ExcludedAt AS RowAddedAt, hx.ChangedBy AS ExcludedBy, hx.ChangedAt AS ExcludedAt
    FROM master.dbo.sqm_BackupExclude e
    $histApply
    UNION ALL
    SELECT d.name COLLATE DATABASE_DEFAULT, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM sys.databases d
    WHERE d.database_id > 4 AND d.source_database_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM master.dbo.sqm_BackupExclude e WHERE e.DatabaseName COLLATE DATABASE_DEFAULT = d.name COLLATE DATABASE_DEFAULT)
)
SELECT s.DatabaseName, s.InTable, s.IsActive, s.IsOrphaned, s.Reason, s.RowAddedBy, s.RowAddedAt, s.ExcludedBy, s.ExcludedAt,
       CAST(CASE WHEN d.database_id IS NULL THEN 0 ELSE 1 END AS int) AS DbExists,
       d.state_desc AS State, d.recovery_model_desc AS RecoveryModel, d.create_date AS CreateDate, sz.SizeMB,
       ag.name AS AgName, bk.LastFull, bk.LastLog
FROM src s
LEFT JOIN sys.databases d ON d.name COLLATE DATABASE_DEFAULT = s.DatabaseName
LEFT JOIN sz ON sz.database_id = d.database_id
LEFT JOIN sys.availability_replicas ar ON ar.replica_id = d.replica_id
LEFT JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN bk ON bk.DatabaseName = s.DatabaseName
ORDER BY s.DatabaseName;
"@
				$rows = @(Invoke-DbaQuery @connParams -Database master -Query $query -EnableException)

				foreach ($r in $rows)
				{
					$inTable = [int]$r.InTable -eq 1
					$rowStatus = if (-not $inTable) { 'NotInTable' }
					elseif ([int]$r.IsOrphaned -eq 1) { 'Orphaned' }
					elseif ([int]$r.IsActive -eq 0) { 'Excluded' }
					else { 'Active' }

					$created = _ToDate $r.CreateDate
					$lastFull = _ToDate $r.LastFull
					$lastLog = _ToDate $r.LastLog
					# Historie einer gleichnamigen Vorgaengerin nicht mitzaehlen
					if ($created -and $lastFull -and $lastFull -lt $created) { $lastFull = $null }
					if ($created -and $lastLog -and $lastLog -lt $created) { $lastLog = $null }
					$excludedAt = _ToDate $r.ExcludedAt
					$recovery = _Str $r.RecoveryModel
					$reason = _Str $r.Reason

					$hints = [System.Collections.Generic.List[string]]::new()
					if ($rowStatus -eq 'Excluded')
					{
						if (-not $reason.Trim()) { $hints.Add('Kein Grund eingetragen') }
						if ($recovery -in 'FULL', 'BULK_LOGGED')
						{
							$hints.Add("Recovery ${recovery}: ohne Log-Backups wird das Log nie geleert und waechst bis die Platte voll ist - auf SIMPLE umstellen oder Log anderweitig sichern")
						}
						if (-not $hasHistory) { $hints.Add('Ausschlusszeitpunkt unbekannt (keine History-Tabelle)') }
						elseif (-not $excludedAt) { $hints.Add('Ausschlusszeitpunkt unbekannt (vor Einrichtung der History ausgeschlossen)') }
						if ($excludedAt -and $lastFull -and $lastFull -gt $excludedAt) { $hints.Add("Trotz Ausschluss gesichert: Full am $(_Fmt $lastFull)") }
						if ([int]$r.DbExists -eq 0) { $hints.Add('Datenbank existiert nicht (Sync-Lauf steht aus)') }
					}
					elseif ($rowStatus -eq 'NotInTable')
					{
						$hints.Add($(if ($hasDdlTrigger) { 'Noch nicht erfasst - wird gesichert' } else { 'Noch nicht erfasst - wird gesichert; kein DDL-Trigger, erst der naechste Sync-Lauf traegt sie ein' }))
					}
					elseif ($rowStatus -eq 'Orphaned')
					{
						$hints.Add('Datenbank existiert nicht mehr, Zeile bleibt erhalten')
					}

					$detailRows.Add([PSCustomObject]@{
							SqlInstance       = $instance
							Database          = [string]$r.DatabaseName
							Status            = $rowStatus
							Reason            = $reason
							ExcludedBy        = if ($rowStatus -eq 'Excluded') { _Str $r.ExcludedBy } else { '' }
							ExcludedAt        = if ($rowStatus -eq 'Excluded') { _Fmt $excludedAt } else { '' }
							RowAddedBy        = _Str $r.RowAddedBy
							RowAddedAt        = _Fmt (_ToDate $r.RowAddedAt)
							DatabaseExists    = [int]$r.DbExists -eq 1
							State             = _Str $r.State
							RecoveryModel     = $recovery
							SizeMB            = if ($r.SizeMB -is [DBNull] -or $null -eq $r.SizeMB) { $null } else { [double]$r.SizeMB }
							AvailabilityGroup = _Str $r.AgName
							LastFullBackup    = _Fmt $lastFull
							LastLogBackup     = _Fmt $lastLog
							Hints             = ($hints -join '; ')
						})
				}

				if ($IncludeHistory -and $hasHistory)
				{
					$historyRows = @(Invoke-DbaQuery @connParams -Database master -EnableException -Query @"
SELECT DatabaseName, ChangedField, OldValue, NewValue, ChangedBy, ChangedAt
FROM master.dbo.sqm_BackupExclude_History
WHERE ChangedAt >= DATEADD(DAY, -$HistoryDays, SYSDATETIME())
ORDER BY ChangedAt DESC, HistoryId DESC;
"@ | ForEach-Object {
							# $_ ist im switch der Switch-Wert, nicht die Zeile - deshalb $h
							$h = $_
							$what = switch ("$($h.ChangedField)|$($h.NewValue)")
							{
								'IsActive|0' { 'ausgeschlossen' }
								'IsActive|1' { if ($h.OldValue -is [DBNull]) { 'neu erfasst (wird gesichert)' } else { 'wieder gesichert' } }
								'IsOrphaned|1' { 'verwaist (Datenbank geloescht)' }
								'IsOrphaned|0' { if ($h.OldValue -is [DBNull]) { '' } else { 'Datenbank wieder vorhanden' } }
								default { "$($h.ChangedField): $(_Str $h.OldValue) -> $(_Str $h.NewValue)" }
							}
							if ($what)
							{
								[PSCustomObject]@{ ChangedAt = _Fmt (_ToDate $h.ChangedAt); Database = [string]$h.DatabaseName; Change = $what; ChangedBy = _Str $h.ChangedBy }
							}
						})
				}

				$cnt = @{ }
				foreach ($s in 'Excluded', 'Active', 'Orphaned', 'NotInTable') { $cnt[$s] = @($detailRows | Where-Object Status -eq $s).Count }
				$reportRows = if ($Status -eq 'All') { @($detailRows) } else { @($detailRows | Where-Object Status -eq $Status) }
				$sorted = @($reportRows | Sort-Object @{ e = { switch ($_.Status) { 'Excluded' { 0 } 'NotInTable' { 1 } 'Orphaned' { 2 } default { 3 } } } }, Database)
				$hintCount = @($sorted | Where-Object { $_.Status -eq 'Excluded' -and $_.Hints }).Count

				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$fileStamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
				$txtFile = Join-Path $OutputPath "BackupExclude_${safeInst}_$fileStamp.txt"
				$csvFile = Join-Path $OutputPath "BackupExclude_${safeInst}_$fileStamp.csv"
				$htmlFile = Join-Path $OutputPath "BackupExclude_${safeInst}_$fileStamp.html"
				$infra = "History-Tabelle: $(if ($hasHistory) { 'ja' } else { 'nein' }) | DDL-Trigger: $(if ($hasDdlTrigger) { 'ja' } else { 'nein' })"
				$counts = "Excluded: $($cnt.Excluded) | Active: $($cnt.Active) | Orphaned: $($cnt.Orphaned) | NotInTable: $($cnt.NotInTable)"

				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Backup-Exclude-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null }

					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - Backup-Ausschlussliste (master.dbo.sqm_BackupExclude)")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz  : $instance")
					$lines.Add("# Erstellt : $timestamp")
					$lines.Add("# Filter   : $Status")
					$lines.Add("# $counts")
					$lines.Add("# $infra")
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-35} {1,-10} {2,-11} {3,-16} {4,-20} {5}" -f 'Datenbank', 'Status', 'Recovery', 'Ausgeschl. am', 'Ausgeschl. von', 'Grund / Hinweise'))
					$lines.Add(("-" * 150))
					foreach ($e in $sorted)
					{
						$n = if ($e.Database.Length -gt 35) { $e.Database.Substring(0, 32) + '...' } else { $e.Database }
						$txt = @($e.Reason, $e.Hints) | Where-Object { $_ }
						$lines.Add(("{0,-35} {1,-10} {2,-11} {3,-16} {4,-20} {5}" -f $n, $e.Status, $e.RecoveryModel, $e.ExcludedAt, $e.ExcludedBy, ($txt -join ' | ')))
					}
					if ($IncludeHistory)
					{
						$lines.Add("")
						$lines.Add("# Aenderungen der letzten $HistoryDays Tage")
						if (-not $hasHistory) { $lines.Add("(keine History-Tabelle vorhanden)") }
						elseif ($historyRows.Count -eq 0) { $lines.Add("(keine Aenderungen)") }
						foreach ($h in $historyRows) { $lines.Add(("{0,-16} {1,-35} {2,-32} {3}" -f $h.ChangedAt, $h.Database, $h.Change, $h.ChangedBy)) }
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					$sorted | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Delimiter ';' -Force

					$enc = { param ($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
					$rowsHtml = foreach ($e in $sorted)
					{
						$cls = switch ($e.Status) { 'Excluded' { 'warn' } 'Active' { 'ok' } default { '' } }
						$hintCls = if ($e.Status -eq 'Excluded' -and $e.Hints) { " class='warn'" } else { '' }
						$size = if ($null -ne $e.SizeMB) { '{0:N1}' -f $e.SizeMB } else { '' }
						"<tr><td class='$cls'>$($e.Status)</td><td>$(& $enc $e.Database)</td><td>$(& $enc $e.Reason)</td><td>$($e.ExcludedAt)</td><td>$(& $enc $e.ExcludedBy)</td><td>$($e.RecoveryModel)</td><td class='num'>$size</td><td>$(& $enc $e.AvailabilityGroup)</td><td>$($e.LastFullBackup)</td><td>$($e.LastLogBackup)</td><td$hintCls>$(& $enc $e.Hints)</td></tr>"
					}
					$bodyHtml = "<p>Filter: $Status<br>$counts<br>$infra</p>"
					if ($hintCount -gt 0) { $bodyHtml += "<p class='warn'>$hintCount ausgeschlossene Datenbank(en) mit Hinweis - siehe letzte Spalte.</p>" }
					$bodyHtml += "<table><tr><th>Status</th><th>Datenbank</th><th>Grund</th><th>Ausgeschlossen am</th><th>Ausgeschlossen von</th><th>Recovery</th><th class='num'>SizeMB</th><th>AG</th><th>Letztes Full</th><th>Letztes Log</th><th>Hinweise</th></tr>" + ($rowsHtml -join '') + "</table>"
					if ($IncludeHistory)
					{
						$bodyHtml += "<h2>Aenderungen der letzten $HistoryDays Tage</h2>"
						if (-not $hasHistory) { $bodyHtml += "<p>Keine History-Tabelle vorhanden.</p>" }
						elseif ($historyRows.Count -eq 0) { $bodyHtml += "<p>Keine Aenderungen.</p>" }
						else
						{
							$bodyHtml += "<table><tr><th>Zeitpunkt</th><th>Datenbank</th><th>Aenderung</th><th>Von</th></tr>" + (($historyRows | ForEach-Object { "<tr><td>$($_.ChangedAt)</td><td>$(& $enc $_.Database)</td><td>$(& $enc $_.Change)</td><td>$(& $enc $_.ChangedBy)</td></tr>" }) -join '') + "</table>"
						}
					}
					ConvertTo-sqmHtmlReport -Title "Backup-Ausschlussliste - $instance" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
				}
				else
				{
					$txtFile = $null; $csvFile = $null; $htmlFile = $null
				}

				Invoke-sqmLogging -Message "[$instance] Backup-Ausschlussliste: $counts; $hintCount Ausschluss/Ausschluesse mit Hinweis" -FunctionName $functionName -Level "INFO"

				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance       = $instance
						Status            = 'OK'
						Timestamp         = $timestamp
						TablePresent      = $true
						HistoryPresent    = $hasHistory
						DdlTriggerPresent = $hasDdlTrigger
						ExcludedCount     = $cnt.Excluded
						ActiveCount       = $cnt.Active
						OrphanedCount     = $cnt.Orphaned
						NotInTableCount   = $cnt.NotInTable
						DetailRows        = $sorted
						History           = $historyRows
						TxtFile           = $txtFile
						CsvFile           = $csvFile
						HtmlFile          = $htmlFile
					})
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance; Status = 'Error'; Message = $errMsg
						DetailRows = $null; History = $null; TxtFile = $null; CsvFile = $null; HtmlFile = $null
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
