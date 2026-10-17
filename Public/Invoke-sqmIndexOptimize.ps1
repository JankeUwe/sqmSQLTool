<#
.SYNOPSIS
    Reorganizes or rebuilds fragmented indexes with sensible defaults (thresholds, ONLINE where
    possible, low-priority waits, time limit).

.DESCRIPTION
    Index maintenance without Ola Hallengren's IndexOptimize, with the same proven defaults:

    - Only indexes with at least -MinPageCount pages (1000 = approx. 8 MB) are considered; smaller
      indexes are read from memory anyway and their fragmentation is irrelevant.
    - Fragmentation < -FragmentationLow (5 %)         : nothing
      -FragmentationLow to < -FragmentationHigh (30 %) : REORGANIZE (online, interruptible)
      >= -FragmentationHigh                             : REBUILD, ONLINE where possible
    - -Online Auto: ONLINE = ON on Enterprise/Developer/Evaluation and Azure, else offline.
      ONLINE rebuilds wait at low priority (WAIT_AT_LOW_PRIORITY, -LowPriorityWaitMinutes 1,
      ABORT_AFTER_WAIT = SELF) so they never block the application; if the lock is not granted,
      the index is reported as 'Failed' and the run continues.
    - Without ONLINE (Standard edition, XML/spatial indexes) a rebuild runs offline only when
      -AllowOfflineRebuild is $true (default); with $false a REORGANIZE is done instead.
    - REORGANIZE is impossible with ALLOW_PAGE_LOCKS = OFF; such indexes are rebuilt.
    - Partitioned indexes are processed per partition (REBUILD/REORGANIZE PARTITION = n).
    - Columnstore indexes: REORGANIZE when the share of deleted rows in compressed row groups
      reaches -ColumnstoreDeletedPercent (20 %).
    - Heaps, disabled, hypothetical and memory-optimized indexes are not touched (a rebuild would
      re-enable a disabled index).
    - Read-only databases and AG secondaries are skipped.
    - -TimeLimitMinutes stops starting new commands after the maintenance window; the rest is
      returned as 'NotStarted'.
    - -UpdateStatistics afterwards runs Invoke-sqmUpdateStatistics (adaptive defaults) on the same
      databases. REORGANIZE does not update statistics; rebuilt indexes get FULLSCAN statistics
      and are skipped there automatically (no changes since).

    Fragmentation is read with sys.dm_db_index_physical_stats in LIMITED mode, and only for
    indexes that sys.dm_db_partition_stats shows at or above -MinPageCount, so small indexes cost
    nothing. LIMITED still reads the non-leaf pages of large indexes; on very large databases
    expect a read load in the order of 1 % of the index size.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name or wildcard pattern. System databases are excluded unless named explicitly.
    Default: '*' (all user databases).

.PARAMETER Table
    Table name or wildcard pattern. Default: '*'.

.PARAMETER FragmentationLow
    From this fragmentation (%) an index is reorganized. Default: 5.

.PARAMETER FragmentationHigh
    From this fragmentation (%) an index is rebuilt. Default: 30.

.PARAMETER MinPageCount
    Minimum index size in pages (8 KB). Default: 1000.

.PARAMETER Online
    Auto (default): ONLINE where the edition allows it. On: always ONLINE (fails on Standard).
    Off: never ONLINE.

.PARAMETER AllowOfflineRebuild
    Allow offline rebuilds if ONLINE is not possible. $false: REORGANIZE instead. Default: $true.

.PARAMETER LowPriorityWaitMinutes
    MAX_DURATION for WAIT_AT_LOW_PRIORITY on ONLINE rebuilds (SQL Server 2014+). 0 = normal
    lock wait. Default: 1.

.PARAMETER MaxDop
    MAXDOP for rebuilds. 0 = server setting. Default: 0.

.PARAMETER SortInTempdb
    SORT_IN_TEMPDB = ON for rebuilds (less space in the user database, more in tempdb).

.PARAMETER FillFactor
    FILLFACTOR for rebuilds of whole indexes (1-100). 0 = keep the existing value. Default: 0.

.PARAMETER ColumnstoreDeletedPercent
    Columnstore: REORGANIZE from this share of deleted rows (%). Default: 20.

.PARAMETER PartitionLevel
    Process partitioned indexes per partition. Default: $true.

.PARAMETER TimeLimitMinutes
    Do not start further commands after this many minutes. 0 = no limit. Default: 0.

.PARAMETER UpdateStatistics
    Afterwards run Invoke-sqmUpdateStatistics on the processed databases.

.PARAMETER WhatIf
    Shows which indexes would be reorganized/rebuilt and the command.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Sensible defaults for all user databases
    Invoke-sqmIndexOptimize -SqlInstance 'SQL01'

.EXAMPLE
    # Maintenance window of 2 hours, statistics afterwards
    Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -TimeLimitMinutes 120 -UpdateStatistics

.EXAMPLE
    # Show only, what would be done
    Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -Database 'SalesDB' -WhatIf |
        Format-Table Table, Index, Partition, PageCount, FragmentationPercent, Action

.EXAMPLE
    # Standard edition during business hours: never lock a table offline
    Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -AllowOfflineRebuild $false

.NOTES
    Uses dbatools (Get-DbaDatabase, Invoke-DbaQuery). Requires db_owner (ALTER on the tables) and
    VIEW DATABASE STATE on the target databases.
    Output per index/partition: Database, Table, Index, IndexType, Partition, PageCount,
    FragmentationPercent, Action, Status (Success, Failed, WhatIf, NotStarted), Duration_s,
    Command, Message.
    For Ola Hallengren's IndexOptimize as an Agent job see New-sqmOlaMaintenanceJobs.
#>
function Invoke-sqmIndexOptimize
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$Database = '*',
		[Parameter(Mandatory = $false)]
		[string]$Table = '*',
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 100)]
		[int]$FragmentationLow = 5,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$FragmentationHigh = 30,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, [int]::MaxValue)]
		[int]$MinPageCount = 1000,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Auto', 'On', 'Off')]
		[string]$Online = 'Auto',
		[Parameter(Mandatory = $false)]
		[bool]$AllowOfflineRebuild = $true,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 600)]
		[int]$LowPriorityWaitMinutes = 1,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 64)]
		[int]$MaxDop = 0,
		[Parameter(Mandatory = $false)]
		[switch]$SortInTempdb,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 100)]
		[int]$FillFactor = 0,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$ColumnstoreDeletedPercent = 20,
		[Parameter(Mandatory = $false)]
		[bool]$PartitionLevel = $true,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$TimeLimitMinutes = 0,
		[Parameter(Mandatory = $false)]
		[switch]$UpdateStatistics,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $script:dbatoolsAvailable -and -not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
		}
		if ($FragmentationLow -ge $FragmentationHigh)
		{
			throw "FragmentationLow ($FragmentationLow) muss kleiner als FragmentationHigh ($FragmentationHigh) sein."
		}

		$tableLike = ($Table -replace '\*', '%') -replace '\?', '_'
		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
		$started = [System.Diagnostics.Stopwatch]::StartNew()
		$processedDbs = [System.Collections.Generic.List[string]]::new()

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Database='$Database', Table='$Table', Low=$FragmentationLow%, High=$FragmentationHigh%, MinPages=$MinPageCount, Online=$Online, AllowOffline=$AllowOfflineRebuild, LowPrio=$LowPriorityWaitMinutes min, MaxDop=$MaxDop, SortInTempdb=$SortInTempdb, FillFactor=$FillFactor, TimeLimit=$TimeLimitMinutes min)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# ---- Edition/Version: ONLINE moeglich? WAIT_AT_LOW_PRIORITY ab 2014 (12) ----
			$srv = @(Invoke-DbaQuery @connParams -Database master -Query "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int) AS EngineEdition, CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion, CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition")[0]
			$major = [int]$srv.MajorVersion
			$editionOnline = ([int]$srv.EngineEdition -in 3, 5, 8)
			$useOnline = switch ($Online) { 'On' { $true } 'Off' { $false } default { $editionOnline } }
			if ($Online -eq 'Auto' -and -not $editionOnline)
			{
				Invoke-sqmLogging -Message "Edition '$($srv.Edition)' unterstuetzt kein ONLINE-Rebuild - Rebuilds laufen $(if ($AllowOfflineRebuild) { 'offline (Tabelle gesperrt)' } else { 'nicht, stattdessen REORGANIZE' })." -FunctionName $functionName -Level "WARNING"
			}

			$dbParams = $connParams.Clone()
			if ($Database -notmatch '[\*\?]') { $dbParams['Database'] = $Database } else { $dbParams['ExcludeSystem'] = $true }
			$targetDbs = @(Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible -and $_.Name -like $Database -and $_.Name -ne 'tempdb' })
			if ($targetDbs.Count -eq 0)
			{
				Invoke-sqmLogging -Message "Keine passenden Datenbanken fuer Muster '$Database' gefunden." -FunctionName $functionName -Level "WARNING"
				return
			}

			foreach ($db in $targetDbs)
			{
				$dbName = $db.Name
				$upd = @(Invoke-DbaQuery @connParams -Database $dbName -Query "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS nvarchar(20)) AS Updateability")[0].Updateability
				if ($upd -ne 'READ_WRITE')
				{
					Invoke-sqmLogging -Message "[$dbName] nicht beschreibbar (Updateability=$upd, z. B. READ_ONLY oder AG-Secondary) - uebersprungen." -FunctionName $functionName -Level "WARNING"
					continue
				}

				# ---- Rowstore: Fragmentierung nur fuer Indizes >= MinPageCount lesen ----
				$rowQuery = @"
SET NOCOUNT ON;
SELECT sch.name AS SchemaName, o.name AS TableName, i.name AS IndexName, i.index_id AS IndexId,
       i.type AS IndexType, i.type_desc AS IndexTypeDesc, i.allow_page_locks AS AllowPageLocks,
       ps.partition_number AS PartitionNumber, pc.PartitionCount,
       ips.page_count AS [PageCount],
       CAST(ips.avg_fragmentation_in_percent AS decimal(9,2)) AS FragmentationPercent
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
JOIN sys.dm_db_partition_stats ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
CROSS APPLY (SELECT COUNT(*) AS PartitionCount FROM sys.partitions p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) pc
CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), i.object_id, i.index_id, ps.partition_number, 'LIMITED') ips
WHERE i.index_id > 0 AND i.type IN (1, 2, 3, 4) AND i.is_disabled = 0 AND i.is_hypothetical = 0
  AND ISNULL(OBJECTPROPERTY(o.object_id, 'TableIsMemoryOptimized'), 0) = 0
  AND ps.used_page_count >= @minPages AND o.name LIKE @table
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA' AND ips.index_level = 0
  AND ips.avg_fragmentation_in_percent >= @low
ORDER BY ips.avg_fragmentation_in_percent DESC;
"@
				$candidates = @(Invoke-DbaQuery @connParams -Database $dbName -Query $rowQuery -QueryTimeout 86400 -SqlParameter @{ minPages = $MinPageCount; table = $tableLike; low = $FragmentationLow })

				# ---- Columnstore: Anteil geloeschter Zeilen (ab 2016) ----
				$csCandidates = @()
				$hasCs = @(Invoke-DbaQuery @connParams -Database $dbName -Query "SELECT CASE WHEN OBJECT_ID('sys.dm_db_column_store_row_group_physical_stats') IS NULL THEN 0 ELSE 1 END AS HasCs")[0].HasCs
				if ($hasCs -eq 1)
				{
					$csQuery = @"
SET NOCOUNT ON;
SELECT sch.name AS SchemaName, o.name AS TableName, i.name AS IndexName, i.index_id AS IndexId,
       i.type AS IndexType, i.type_desc AS IndexTypeDesc, rg.partition_number AS PartitionNumber,
       (SELECT COUNT(*) FROM sys.partitions p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) AS PartitionCount,
       SUM(CAST(rg.size_in_bytes AS bigint)) / 8192 AS [PageCount],
       CAST(100.0 * SUM(CAST(rg.deleted_rows AS bigint)) / NULLIF(SUM(CAST(rg.total_rows AS bigint)), 0) AS decimal(9,2)) AS FragmentationPercent
FROM sys.dm_db_column_store_row_group_physical_stats rg
JOIN sys.indexes i ON i.object_id = rg.object_id AND i.index_id = rg.index_id
JOIN sys.objects o ON o.object_id = i.object_id AND o.is_ms_shipped = 0
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
WHERE rg.state_desc = 'COMPRESSED' AND i.is_disabled = 0 AND o.name LIKE @table
GROUP BY sch.name, o.name, i.name, i.index_id, i.type, i.type_desc, rg.partition_number, i.object_id
HAVING 100.0 * SUM(CAST(rg.deleted_rows AS bigint)) / NULLIF(SUM(CAST(rg.total_rows AS bigint)), 0) >= @pct;
"@
					$csCandidates = @(Invoke-DbaQuery @connParams -Database $dbName -Query $csQuery -SqlParameter @{ table = $tableLike; pct = $ColumnstoreDeletedPercent })
				}

				Invoke-sqmLogging -Message "[$dbName] $($candidates.Count) Rowstore-Index(-Partitionen) ab $FragmentationLow% Fragmentierung und $MinPageCount Seiten, $($csCandidates.Count) Columnstore-Index(-Partitionen) ab $ColumnstoreDeletedPercent% geloeschten Zeilen." -FunctionName $functionName -Level "INFO"
				if ($candidates.Count -gt 0 -or $csCandidates.Count -gt 0) { $processedDbs.Add($dbName) }

				# Partitionsweise oder ganzer Index: bei PartitionLevel=$false je Index nur eine Zeile (hoechste Fragmentierung)
				$work = [System.Collections.Generic.List[object]]::new()
				foreach ($set in @(@{ Rows = $candidates; Cs = $false }, @{ Rows = $csCandidates; Cs = $true }))
				{
					$rowsSet = $set.Rows
					if (-not $PartitionLevel)
					{
						$rowsSet = @($rowsSet | Group-Object SchemaName, TableName, IndexName | ForEach-Object { $_.Group | Sort-Object FragmentationPercent -Descending | Select-Object -First 1 })
					}
					foreach ($c in $rowsSet) { $work.Add([PSCustomObject]@{ C = $c; IsColumnstore = $set.Cs }) }
				}

				foreach ($w in $work)
				{
					$c = $w.C
					$frag = [double]$c.FragmentationPercent
					$isPartitioned = $PartitionLevel -and ([int]$c.PartitionCount -gt 1)
					$idxType = [int]$c.IndexType
					$onlineCapable = $useOnline -and ($idxType -in 1, 2) -and (-not $isPartitioned -or $major -ge 12)
					$pageLocks = -not ($c.AllowPageLocks -eq $false -or $c.AllowPageLocks -eq 0)

					# ---- Aktion bestimmen ----
					$action = $null
					if ($w.IsColumnstore)
					{
						$action = 'REORGANIZE'
					}
					elseif ($frag -lt $FragmentationHigh)
					{
						$action = if ($pageLocks) { 'REORGANIZE' } elseif ($onlineCapable) { 'REBUILD ONLINE' } elseif ($AllowOfflineRebuild) { 'REBUILD OFFLINE' } else { $null }
					}
					else
					{
						$action = if ($onlineCapable) { 'REBUILD ONLINE' } elseif ($AllowOfflineRebuild) { 'REBUILD OFFLINE' } elseif ($pageLocks) { 'REORGANIZE' } else { $null }
					}

					$tableEsc = "[$($c.SchemaName -replace '\]', ']]')].[$($c.TableName -replace '\]', ']]')]"
					$indexEsc = "[$($c.IndexName -replace '\]', ']]')]"
					$partClause = if ($isPartitioned) { " PARTITION = $($c.PartitionNumber)" } else { '' }

					$row = [ordered]@{
						SqlInstance		     = $SqlInstance
						Database			 = $dbName
						Table			     = "$($c.SchemaName).$($c.TableName)"
						Index			     = $c.IndexName
						IndexType		     = $c.IndexTypeDesc
						Partition		     = $(if ($isPartitioned) { [int]$c.PartitionNumber } else { $null })
						PageCount		     = [long]$c.PageCount
						FragmentationPercent = $frag
						Action			     = $action
						Status			     = $null
						Duration_s		     = 0
						Command			     = $null
						Message			     = $null
					}

					if (-not $action)
					{
						$row.Status = 'Skipped'
						$row.Message = 'Kein ONLINE-Rebuild moeglich, Offline-Rebuild nicht erlaubt (-AllowOfflineRebuild $false) und REORGANIZE wegen ALLOW_PAGE_LOCKS = OFF unmoeglich.'
						[PSCustomObject]$row
						continue
					}

					# ---- Kommando bauen ----
					$buildRebuild = {
						param ([bool]$AsOnline)
						$opts = [System.Collections.Generic.List[string]]::new()
						if ($AsOnline)
						{
							if ($LowPriorityWaitMinutes -gt 0 -and $major -ge 12) { $opts.Add("ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = $LowPriorityWaitMinutes MINUTES, ABORT_AFTER_WAIT = SELF))") }
							else { $opts.Add('ONLINE = ON') }
						}
						if ($SortInTempdb) { $opts.Add('SORT_IN_TEMPDB = ON') }
						if ($MaxDop -gt 0) { $opts.Add("MAXDOP = $MaxDop") }
						if ($FillFactor -gt 0 -and -not $isPartitioned) { $opts.Add("FILLFACTOR = $FillFactor") }
						$withPart = if ($opts.Count -gt 0) { " WITH ($($opts -join ', '))" } else { '' }
						"ALTER INDEX $indexEsc ON $tableEsc REBUILD$partClause$withPart;"
					}
					$command = switch ($action)
					{
						'REORGANIZE' { if ($w.IsColumnstore) { "ALTER INDEX $indexEsc ON $tableEsc REORGANIZE$partClause;" } else { "ALTER INDEX $indexEsc ON $tableEsc REORGANIZE$partClause WITH (LOB_COMPACTION = ON);" } }
						'REBUILD ONLINE' { & $buildRebuild $true }
						'REBUILD OFFLINE' { & $buildRebuild $false }
					}
					$row.Command = $command
					$target = "$dbName : $($row.Table).$($c.IndexName)$(if ($isPartitioned) { " (Partition $($c.PartitionNumber))" })"

					if ($TimeLimitMinutes -gt 0 -and $started.Elapsed.TotalMinutes -ge $TimeLimitMinutes)
					{
						$row.Status = 'NotStarted'
						$row.Message = "Zeitlimit $TimeLimitMinutes min erreicht."
						[PSCustomObject]$row
						continue
					}

					if (-not $PSCmdlet.ShouldProcess($target, "$action ($frag% fragmentiert, $($c.PageCount) Seiten)"))
					{
						$row.Status = 'WhatIf'
						$row.Message = "WhatIf: $command"
						[PSCustomObject]$row
						continue
					}

					$sw = [System.Diagnostics.Stopwatch]::StartNew()
					try
					{
						Invoke-DbaQuery @connParams -Database $dbName -Query $command -QueryTimeout 86400 -EnableException | Out-Null
						$row.Status = 'Success'
						$row.Message = "$action erfolgreich ($frag% fragmentiert)."
					}
					catch
					{
						$err = $_.Exception.Message
						$lockAbort = $err -match 'Lock request time out|1222|low priority|WAIT_AT_LOW_PRIORITY'
						if ($action -eq 'REBUILD ONLINE' -and -not $lockAbort -and $err -match 'online' -and $AllowOfflineRebuild -and $Online -ne 'On')
						{
							# ONLINE fuer diesen Index nicht moeglich (z. B. Altversion mit LOB-Spalten) -> offline nachholen
							$command = & $buildRebuild $false
							Invoke-sqmLogging -Message "[$target] ONLINE nicht moeglich ($err) - Rebuild offline." -FunctionName $functionName -Level "WARNING"
							try
							{
								Invoke-DbaQuery @connParams -Database $dbName -Query $command -QueryTimeout 86400 -EnableException | Out-Null
								$row.Action = 'REBUILD OFFLINE'
								$row.Command = $command
								$row.Status = 'Success'
								$row.Message = "REBUILD OFFLINE erfolgreich (ONLINE nicht moeglich: $err)."
							}
							catch { $err = $_.Exception.Message }
						}
						if ($row.Status -ne 'Success')
						{
							$errMsg = if ($lockAbort) { "$action abgebrochen: Sperre nicht innerhalb von $LowPriorityWaitMinutes min erhalten (WAIT_AT_LOW_PRIORITY, ABORT_AFTER_WAIT = SELF). $err" } else { "Fehler bei $action ($target): $err" }
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$row.Status = 'Failed'
							$row.Message = $errMsg
						}
					}
					$row.Duration_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
					Invoke-sqmLogging -Message "[$target] $($row.Action): $($row.Status) in $($row.Duration_s) s." -FunctionName $functionName -Level "VERBOSE"
					[PSCustomObject]$row
				}
			}

			# ---- Statistiken im Anschluss ----
			if ($UpdateStatistics -and $processedDbs.Count -gt 0)
			{
				$remaining = if ($TimeLimitMinutes -gt 0) { [math]::Max(0, $TimeLimitMinutes - [math]::Floor($started.Elapsed.TotalMinutes)) } else { 0 }
				if ($TimeLimitMinutes -gt 0 -and $remaining -le 0)
				{
					Invoke-sqmLogging -Message "Zeitlimit erreicht - Statistik-Aktualisierung entfaellt." -FunctionName $functionName -Level "WARNING"
				}
				else
				{
					foreach ($d in $processedDbs)
					{
						$statParams = @{ SqlInstance = $SqlInstance; Database = $d; TimeLimitMinutes = $remaining; WhatIf = $WhatIfPreference }
						if ($SqlCredential) { $statParams['SqlCredential'] = $SqlCredential }
						if ($EnableException) { $statParams['EnableException'] = $true }
						$st = @(Invoke-sqmUpdateStatistics @statParams)
						Invoke-sqmLogging -Message "[$d] Statistiken: $(@($st | Where-Object Status -eq 'Success').Count) aktualisiert, $(@($st | Where-Object Status -eq 'Failed').Count) fehlgeschlagen." -FunctionName $functionName -Level "INFO"
					}
				}
			}
			Invoke-sqmLogging -Message "$functionName abgeschlossen in $([math]::Round($started.Elapsed.TotalMinutes, 1)) min." -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
		}
	}
}
