<#
.SYNOPSIS
    Finds unused, duplicate and overlapping indexes, heaps and disabled or hypothetical indexes
    in one or more databases.

.DESCRIPTION
    Complements Get-sqmMissingIndexes (what is missing) and Get-sqmIndexFragmentation (state of
    existing indexes) with the question: which existing indexes cost more than they bring?

    Findings:
      Unused        Nonclustered, non-unique index without a single read (seek/scan/lookup) since
                    the last SQL Server restart, but maintained on every write (user_updates).
      Duplicate     Same key columns (order, direction) and same filter as another index on the
                    same table. The index kept is the clustered / primary key / unique one, else
                    the one with the lower index_id.
      Overlapping   Key columns are the leading part of another index's keys (same filter).
                    The wider index can serve the same seeks; check the INCLUDE columns before
                    dropping (Detail says whether they are covered).
      Heap          Table without clustered index (row count, size, reads, nonclustered count).
      Disabled      Disabled index (still occupies the metadata, no data, not used).
      Hypothetical  Leftover from the Database Engine Tuning Advisor.

    For Unused, Duplicate, Overlapping and Hypothetical a DROP INDEX statement is returned.
    The report writes them into a .sql file, all commented out: nothing is executed.

    IMPORTANT: Usage counters (sys.dm_db_index_usage_stats) start at zero after every restart,
    failover, database offline/online or detach. An index used only by the month-end or year-end
    run looks unused for weeks. MinUptimeDays guards against short uptimes; always check with
    the application owner before dropping anything.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name(s), wildcards allowed. Default: all online user databases.

.PARAMETER Finding
    Restrict the output to these findings. Default: all.

.PARAMETER MinUptimeDays
    If the instance runs for fewer days, 'Unused' is still reported but flagged as unreliable
    and a warning is written. Default: 7.

.PARAMETER MinSizeMB
    Ignore Unused/Duplicate/Overlapping/Heap findings below this size. Default: 0.

.PARAMETER OutputPath
    Directory for the CSV/HTML report and the DROP script. Default: <OutputPath config>\IndexUsageReport.

.PARAMETER NoReport
    Do not write files (objects are still returned).

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmIndexUsageReport -SqlInstance "SQL01"

.EXAMPLE
    # Only duplicates and overlaps in the shop databases
    Get-sqmIndexUsageReport -SqlInstance "SQL01" -Database "Shop*" -Finding Duplicate, Overlapping

.EXAMPLE
    # Large unused indexes as a list
    Get-sqmIndexUsageReport -SqlInstance "SQL01" -Finding Unused -MinSizeMB 500 -NoReport |
        Sort-Object SizeMB -Descending | Format-Table DatabaseName, TableName, IndexName, SizeMB, Writes

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE and VIEW DATABASE STATE / access to each database.
    Read-only: the function never changes an index.
    Inspired by sp_BlitzIndex (Brent Ozar, First Responder Kit), built from the DMVs directly.
#>
function Get-sqmIndexUsageReport
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[ValidateSet('Unused', 'Duplicate', 'Overlapping', 'Heap', 'Disabled', 'Hypothetical')]
		[string[]]$Finding = @('Unused', 'Duplicate', 'Overlapping', 'Heap', 'Disabled', 'Hypothetical'),
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 3650)]
		[int]$MinUptimeDays = 7,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10000000)]
		[double]$MinSizeMB = 0,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'IndexUsageReport'),
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		# Alle Indizes einer Datenbank mit Schluessel-/Include-Spalten, Nutzung und Groesse.
		# FOR XML PATH statt STRING_AGG, damit es auch auf SQL Server 2016 laeuft.
		$indexQuery = @"
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT
    s.name                     AS SchemaName,
    t.name                     AS TableName,
    i.name                     AS IndexName,
    i.index_id                 AS IndexId,
    i.type                     AS IndexType,
    i.type_desc                AS IndexTypeDesc,
    i.is_primary_key           AS IsPrimaryKey,
    i.is_unique                AS IsUnique,
    i.is_unique_constraint     AS IsUniqueConstraint,
    i.is_disabled              AS IsDisabled,
    i.is_hypothetical          AS IsHypothetical,
    ISNULL(i.filter_definition, N'') AS FilterDefinition,
    ISNULL(STUFF((
        SELECT N', ' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
        FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
          AND ic.is_included_column = 0 AND ic.key_ordinal > 0
        ORDER BY ic.key_ordinal
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'') AS KeyColumns,
    ISNULL(STUFF((
        SELECT N', ' + QUOTENAME(c.name)
        FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
          AND ic.is_included_column = 1
        ORDER BY c.name
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'') AS IncludeColumns,
    ISNULL(us.user_seeks, 0)   AS UserSeeks,
    ISNULL(us.user_scans, 0)   AS UserScans,
    ISNULL(us.user_lookups, 0) AS UserLookups,
    ISNULL(us.user_updates, 0) AS UserUpdates,
    (SELECT MAX(v) FROM (VALUES (us.last_user_seek), (us.last_user_scan), (us.last_user_lookup)) x(v)) AS LastUserRead,
    ISNULL(ps.RowCnt, 0)       AS RowCnt,
    ISNULL(ps.SizeMB, 0)       AS SizeMB,
    (SELECT COUNT(*) FROM sys.indexes n WHERE n.object_id = i.object_id AND n.index_id > 1) AS NonclusteredCount
FROM sys.indexes i
JOIN sys.tables  t ON t.object_id = i.object_id AND t.is_ms_shipped = 0
JOIN sys.schemas s ON s.schema_id = t.schema_id
LEFT JOIN sys.dm_db_index_usage_stats us
       ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
OUTER APPLY (
    SELECT SUM(p.row_count) AS RowCnt, CAST(SUM(p.used_page_count) * 8 / 1024.0 AS decimal(18,2)) AS SizeMB
    FROM sys.dm_db_partition_stats p
    WHERE p.object_id = i.object_id AND p.index_id = i.index_id
) ps
ORDER BY s.name, t.name, i.index_id;
"@

		Invoke-sqmLogging -Message ("Starte " + $functionName + " auf " + $SqlInstance) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance; SqlCredential = $SqlCredential }

			# -------------------------------------------------------------------
			# 1. Laufzeit der Instanz (Nutzungszaehler starten beim Neustart bei 0)
			# -------------------------------------------------------------------
			$startTime = (Invoke-DbaQuery @connParams -Database master -Query "SELECT sqlserver_start_time AS t FROM sys.dm_os_sys_info" -EnableException).t
			$uptimeDays = [math]::Round(((Get-Date) - [datetime]$startTime).TotalDays, 1)
			$usageReliable = $uptimeDays -ge $MinUptimeDays
			if (-not $usageReliable -and $Finding -contains 'Unused')
			{
				$msg = "Instanz laeuft erst seit $uptimeDays Tag(en) (seit $startTime). 'Unused' ist unzuverlaessig, die Nutzungszaehler beginnen beim Neustart bei 0."
				Write-Warning $msg
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
			}

			# -------------------------------------------------------------------
			# 2. Datenbanken bestimmen (online, Benutzer-DBs, Filter)
			# -------------------------------------------------------------------
			$dbRows = Invoke-DbaQuery @connParams -Database master -EnableException -Query @"
SELECT d.name
FROM sys.databases d
WHERE d.database_id > 4 AND d.state = 0 AND HAS_DBACCESS(d.name) = 1
  AND d.name NOT IN (N'ReportServer', N'ReportServerTempDB', N'SSISDB', N'distribution')
ORDER BY d.name
"@
			$dbNames = @($dbRows | ForEach-Object { $_.name })
			if ($Database.Count -gt 0)
			{
				# Bei expliziter Angabe auch ReportServer/SSISDB zulassen
				$allRows = Invoke-DbaQuery @connParams -Database master -EnableException -Query "SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1"
				$dbNames = @($allRows | ForEach-Object { $_.name } | Where-Object {
					$n = $_
					@($Database | Where-Object { $n -like $_ }).Count -gt 0
				})
			}
			if ($dbNames.Count -eq 0)
			{
				$msg = "Keine passende, erreichbare Benutzerdatenbank gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				Write-Warning $msg
				return
			}

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()

			$newFinding = {
				param ($db, $ix, [string]$kind, [string]$detail, [string]$related, [bool]$withDrop)
				$drop = $null
				if ($withDrop -and $ix.IndexName -isnot [DBNull])
				{
					$drop = "DROP INDEX [" + ($ix.IndexName -replace '\]', ']]') + "] ON [" + ($db -replace '\]', ']]') + "].[" + ($ix.SchemaName -replace '\]', ']]') + "].[" + ($ix.TableName -replace '\]', ']]') + "];"
				}
				[PSCustomObject]@{
					SqlInstance    = $SqlInstance
					DatabaseName   = $db
					SchemaName     = $ix.SchemaName
					TableName      = $ix.TableName
					IndexName      = if ($ix.IndexName -is [DBNull]) { '(heap)' } else { $ix.IndexName }
					IndexType      = $ix.IndexTypeDesc
					Finding        = $kind
					Detail         = $detail
					RelatedIndex   = $related
					KeyColumns     = $ix.KeyColumns
					IncludeColumns = $ix.IncludeColumns
					Filter         = $ix.FilterDefinition
					Reads          = [long]$ix.UserSeeks + [long]$ix.UserScans + [long]$ix.UserLookups
					Writes         = [long]$ix.UserUpdates
					LastUserRead   = if ($ix.LastUserRead -is [DBNull]) { $null } else { $ix.LastUserRead }
					Rows           = [long]$ix.RowCnt
					SizeMB         = [double]$ix.SizeMB
					UptimeDays     = $uptimeDays
					DropStatement  = $drop
				}
			}

			# -------------------------------------------------------------------
			# 3. Je Datenbank auswerten
			# -------------------------------------------------------------------
			foreach ($db in $dbNames)
			{
				try
				{
					$idx = @(Invoke-DbaQuery @connParams -Database $db -Query $indexQuery -QueryTimeout 600 -EnableException)
				}
				catch
				{
					$msg = "[$db] Indexdaten konnten nicht gelesen werden: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					Write-Warning $msg
					continue
				}

				foreach ($tableGroup in ($idx | Group-Object -Property SchemaName, TableName))
				{
					$rows = @($tableGroup.Group)

					# Heap
					foreach ($h in @($rows | Where-Object { [int]$_.IndexId -eq 0 }))
					{
						if ($Finding -contains 'Heap' -and [double]$h.SizeMB -ge $MinSizeMB)
						{
							$results.Add((& $newFinding $db $h 'Heap' "Tabelle ohne Clustered Index, $($h.NonclusteredCount) Nonclustered-Index(e)." $null $false))
						}
					}

					# Disabled / Hypothetical
					foreach ($x in @($rows | Where-Object { [int]$_.IndexId -gt 0 }))
					{
						if ([bool]$x.IsHypothetical -and $Finding -contains 'Hypothetical')
						{
							$results.Add((& $newFinding $db $x 'Hypothetical' 'Hypothetischer Index (Tuning-Advisor-Rest), belegt nur Metadaten.' $null $true))
						}
						elseif ([bool]$x.IsDisabled -and $Finding -contains 'Disabled')
						{
							$results.Add((& $newFinding $db $x 'Disabled' 'Deaktivierter Index: keine Daten, wird nicht genutzt. Entweder REBUILD oder DROP.' $null $false))
						}
					}

					# Kandidaten fuer Vergleiche: aktive Rowstore-Indizes mit Schluesselspalten
					$active = @($rows | Where-Object {
						[int]$_.IndexId -gt 0 -and -not [bool]$_.IsDisabled -and -not [bool]$_.IsHypothetical -and
						[int]$_.IndexType -in 1, 2 -and $_.KeyColumns
					})

					# Unused
					if ($Finding -contains 'Unused')
					{
						foreach ($u in @($active | Where-Object {
							[int]$_.IndexType -eq 2 -and -not [bool]$_.IsUnique -and -not [bool]$_.IsPrimaryKey -and -not [bool]$_.IsUniqueConstraint -and
							([long]$_.UserSeeks + [long]$_.UserScans + [long]$_.UserLookups) -eq 0 -and [double]$_.SizeMB -ge $MinSizeMB
						}))
						{
							$d = "Kein Lesezugriff seit Neustart ($uptimeDays Tage), $($u.UserUpdates) Schreibvorgaenge."
							if (-not $usageReliable) { $d += " UNZUVERLAESSIG: Laufzeit unter $MinUptimeDays Tagen." }
							$results.Add((& $newFinding $db $u 'Unused' $d $null $true))
						}
					}

					# Duplicate: gleiche Schluessel + gleicher Filter. Laeuft immer, damit Duplikate auch
					# bei -Finding Overlapping nicht nochmal als Ueberlappung erscheinen.
					$dupFlagged = @{}
					foreach ($grp in ($active | Group-Object -Property KeyColumns, FilterDefinition | Where-Object Count -gt 1))
					{
						# Behalten: Clustered > PK > Unique > kleinste index_id
						$ordered = @($grp.Group | Sort-Object `
							@{ Expression = { [int]$_.IndexType -eq 1 }; Descending = $true },
							@{ Expression = { [bool]$_.IsPrimaryKey }; Descending = $true },
							@{ Expression = { [bool]$_.IsUnique }; Descending = $true },
							@{ Expression = { [int]$_.IndexId }; Descending = $false })
						$keep = $ordered[0]
						foreach ($dup in ($ordered | Select-Object -Skip 1))
						{
							$inclNote = if ($dup.IncludeColumns -eq $keep.IncludeColumns) { 'Includes identisch.' } else { "Includes abweichend ('$($dup.IncludeColumns)' vs. '$($keep.IncludeColumns)'), vor dem Loeschen zusammenfuehren." }
							$canDrop = -not ([bool]$dup.IsPrimaryKey -or [bool]$dup.IsUniqueConstraint -or [int]$dup.IndexType -eq 1)
							$dupFlagged[[int]$dup.IndexId] = $true
							if ($Finding -contains 'Duplicate' -and [double]$dup.SizeMB -ge $MinSizeMB)
							{
								$results.Add((& $newFinding $db $dup 'Duplicate' "Gleiche Schluesselspalten wie [$($keep.IndexName)]. $inclNote" $keep.IndexName $canDrop))
							}
						}
					}

					# Overlapping: Schluessel sind Praefix eines breiteren Index (gleicher Filter)
					if ($Finding -contains 'Overlapping')
					{
						foreach ($a in @($active | Where-Object { [int]$_.IndexType -eq 2 -and -not [bool]$_.IsUnique -and -not $dupFlagged.ContainsKey([int]$_.IndexId) }))
						{
							$aKeys = @($a.KeyColumns -split ', ')
							$wider = @($active | Where-Object {
								[int]$_.IndexId -ne [int]$a.IndexId -and $_.FilterDefinition -eq $a.FilterDefinition -and
								@($_.KeyColumns -split ', ').Count -gt $aKeys.Count -and
								((@($_.KeyColumns -split ', ') | Select-Object -First $aKeys.Count) -join ', ') -eq $a.KeyColumns
							} | Sort-Object { @($_.KeyColumns -split ', ').Count })
							if ($wider.Count -eq 0 -or [double]$a.SizeMB -lt $MinSizeMB) { continue }
							$b = $wider[0]
							$bCols = @($b.KeyColumns -split ', ' | ForEach-Object { $_ -replace ' DESC$', '' }) + @(if ($b.IncludeColumns) { $b.IncludeColumns -split ', ' })
							$missing = @(if ($a.IncludeColumns) { $a.IncludeColumns -split ', ' | Where-Object { $_ -notin $bCols } })
							$cov = if ($missing.Count -eq 0) { "Alle Include-Spalten sind in [$($b.IndexName)] enthalten." } else { "Nicht abgedeckt: $($missing -join ', ') - erst in [$($b.IndexName)] aufnehmen." }
							$results.Add((& $newFinding $db $a 'Overlapping' "Schluessel sind der Anfang von [$($b.IndexName)] ($($b.KeyColumns)). $cov" $b.IndexName $true))
						}
					}
				}
			}

			# -------------------------------------------------------------------
			# 4. Report: CSV, HTML, DROP-Skript (auskommentiert)
			# -------------------------------------------------------------------
			if (-not $NoReport -and $results.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:*?"<>|,]', '_'
				$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

				$csvFile = Join-Path $OutputPath ("IndexUsageReport_" + $safeInst + "_" + $stamp + ".csv")
				$results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				$files = @($csvFile)

				$drops = @($results | Where-Object DropStatement)
				if ($drops.Count -gt 0)
				{
					$sqlFile = Join-Path $OutputPath ("IndexUsageReport_" + $safeInst + "_" + $stamp + "_DropCandidates.sql")
					$lines = @(
						"-- sqmSQLTool Get-sqmIndexUsageReport - Kandidaten zum Loeschen, $SqlInstance, $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
						"-- Instanzlaufzeit: $uptimeDays Tage (Nutzungszaehler seit $startTime).",
						"-- ALLES AUSKOMMENTIERT. Vor dem Loeschen mit dem Anwendungsverantwortlichen klaeren",
						"-- (Monats-/Jahresabschluss!) und das CREATE-Skript des Index sichern.",
						""
					)
					foreach ($d in $drops)
					{
						$lines += "-- [$($d.Finding)] $($d.Detail) ($($d.SizeMB) MB, Reads $($d.Reads), Writes $($d.Writes))"
						$lines += "-- $($d.DropStatement)"
						$lines += ""
					}
					[System.IO.File]::WriteAllLines($sqlFile, $lines, (New-Object System.Text.UTF8Encoding($true)))
					$files += $sqlFile
				}

				$enc = { param ($s) ([string]$s) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
				$sb = New-Object System.Text.StringBuilder
				$relCls = if ($usageReliable) { 'ok' } else { 'crit' }
				[void]$sb.Append("<p>Datenbanken: $($dbNames.Count). Instanzlaufzeit: <span class='$relCls'>$uptimeDays Tage</span> (Nutzungszaehler seit $startTime). Nichts wurde geaendert; DROP-Vorschlaege stehen auskommentiert in der .sql-Datei.</p>")
				$summary = $results | Group-Object Finding | ForEach-Object { "<tr><td>$($_.Name)</td><td class='num'>$($_.Count)</td><td class='num'>$([math]::Round(($_.Group | Measure-Object SizeMB -Sum).Sum, 1))</td></tr>" }
				[void]$sb.Append("<h2>Uebersicht</h2><table><tr><th>Befund</th><th class='num'>Anzahl</th><th class='num'>Groesse MB</th></tr>$($summary -join '')</table>")
				foreach ($kind in @('Unused', 'Duplicate', 'Overlapping', 'Heap', 'Disabled', 'Hypothetical'))
				{
					$k = @($results | Where-Object Finding -eq $kind | Sort-Object SizeMB -Descending)
					if ($k.Count -eq 0) { continue }
					[void]$sb.Append("<h2>$kind ($($k.Count))</h2><table><tr><th>Datenbank</th><th>Tabelle</th><th>Index</th><th>Schluessel</th><th>Includes</th><th class='num'>MB</th><th class='num'>Reads</th><th class='num'>Writes</th><th>Detail</th></tr>")
					foreach ($r in $k)
					{
						[void]$sb.Append("<tr><td>$(& $enc $r.DatabaseName)</td><td>$(& $enc ($r.SchemaName + '.' + $r.TableName))</td><td>$(& $enc $r.IndexName)</td><td>$(& $enc $r.KeyColumns)</td><td>$(& $enc $r.IncludeColumns)</td><td class='num'>$($r.SizeMB)</td><td class='num'>$($r.Reads)</td><td class='num'>$($r.Writes)</td><td>$(& $enc $r.Detail)</td></tr>")
					}
					[void]$sb.Append('</table>')
				}
				$htmlFile = Join-Path $OutputPath ("IndexUsageReport_" + $safeInst + "_" + $stamp + ".html")
				$html = ConvertTo-sqmHtmlReport -Title "Index Usage - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $sb.ToString()
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				$files += $htmlFile

				Copy-sqmToCentralPath -Path $files
				Invoke-sqmLogging -Message ("Report gespeichert: " + $htmlFile) -FunctionName $functionName -Level "INFO"
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}

			$sumText = ($results | Group-Object Finding | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
			Invoke-sqmLogging -Message "$($dbNames.Count) Datenbank(en) geprueft, $($results.Count) Befund(e): $sumText" -FunctionName $functionName -Level "INFO"
			return $results
		}
		catch
		{
			$errMsg = "Fehler bei der Index-Auswertung: " + $_.Exception.Message
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}

	end
	{
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen.") -FunctionName $functionName -Level "INFO"
	}
}
