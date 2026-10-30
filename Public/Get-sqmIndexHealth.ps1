<#
.SYNOPSIS
    Reports the state of all indexes (size, fragmentation, fill factor, disabled) and what
    Invoke-sqmIndexOptimize would do with each of them.

.DESCRIPTION
    Read-only counterpart of Invoke-sqmIndexOptimize: same thresholds, same rules, no changes.
    Run it before a maintenance window to see what is due, or afterwards to verify the result.

    Per index (per partition for partitioned indexes):
      Rows, PageCount, SizeMB, FragmentationPercent (rowstore: avg_fragmentation_in_percent;
      columnstore: share of deleted rows in compressed row groups), FillFactor, IsDisabled and the
      reads/writes since the last restart (Reads = seeks + scans + lookups, Updates).

    Status:
      Ok            below -FragmentationLow
      Reorganize    from -FragmentationLow (5 %)
      Rebuild       from -FragmentationHigh (30 %)
      Small         below -MinPageCount pages - fragmentation not measured, not relevant
      Disabled      disabled index (Invoke-sqmIndexOptimize does not touch it)
      NotMeasured   -SkipFragmentation was used

    Columnstore indexes are 'Reorganize' from -ColumnstoreDeletedPercent (20 %) deleted rows.
    Heaps, hypothetical and memory-optimized indexes are not listed. Unused, duplicate and
    overlapping indexes: see Get-sqmIndexUsageReport.

    Fragmentation is read with sys.dm_db_index_physical_stats in LIMITED mode and only for indexes
    at or above -MinPageCount pages (about 1 % of the index size as read load). -SkipFragmentation
    returns size, fill factor and usage only, from metadata, and is cheap even on very large
    databases. Works on read-only databases and AG secondaries.

    -Summary returns one row per database instead: number of indexes, size, how many need
    REORGANIZE/REBUILD, the page-weighted average fragmentation.

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
    From this fragmentation (%) an index counts as 'Reorganize'. Default: 5.

.PARAMETER FragmentationHigh
    From this fragmentation (%) an index counts as 'Rebuild'. Default: 30.

.PARAMETER MinPageCount
    Minimum index size in pages (8 KB) for the fragmentation measurement. Default: 1000.

.PARAMETER ColumnstoreDeletedPercent
    Columnstore: 'Reorganize' from this share of deleted rows (%). Default: 20.

.PARAMETER SkipFragmentation
    Do not measure fragmentation (metadata only, fast).

.PARAMETER OnlyProblems
    Only indexes with Status Reorganize or Rebuild.

.PARAMETER Summary
    One row per database instead of one row per index.

.PARAMETER OutputPath
    Directory for reports (CSV + HTML). Default: <OutputPath config>\IndexHealth.
    Pass '' to skip the files.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # What would the next index maintenance do?
    Get-sqmIndexHealth -SqlInstance 'SQL01' -OnlyProblems -OutputPath '' |
        Format-Table Database, Table, Index, PageCount, FragmentationPercent, Status

.EXAMPLE
    # One line per database
    Get-sqmIndexHealth -SqlInstance 'SQL01' -Summary -OutputPath ''

.EXAMPLE
    # Fast overview without reading the index pages
    Get-sqmIndexHealth -Database 'SalesDB' -SkipFragmentation -OutputPath ''

.NOTES
    Uses dbatools (Get-DbaDatabase, Invoke-DbaQuery). Requires VIEW DATABASE STATE on the target
    databases. Usage numbers (Reads, Updates) start at zero with every SQL Server restart.
#>
function Get-sqmIndexHealth
{
	[CmdletBinding()]
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
		[ValidateRange(1, 100)]
		[int]$ColumnstoreDeletedPercent = 20,
		[Parameter(Mandatory = $false)]
		[switch]$SkipFragmentation,
		[Parameter(Mandatory = $false)]
		[switch]$OnlyProblems,
		[Parameter(Mandatory = $false)]
		[switch]$Summary,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'IndexHealth'),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
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
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Database='$Database', Table='$Table', Low=$FragmentationLow%, High=$FragmentationHigh%, MinPages=$MinPageCount, SkipFragmentation=$SkipFragmentation)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$dbParams = $connParams.Clone()
			if ($Database -notmatch '[\*\?]') { $dbParams['Database'] = $Database } else { $dbParams['ExcludeSystem'] = $true }
			$targetDbs = @(Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible -and $_.Name -like $Database -and $_.Name -ne 'tempdb' })
			if ($targetDbs.Count -eq 0)
			{
				Invoke-sqmLogging -Message "Keine passenden Datenbanken fuer Muster '$Database' gefunden." -FunctionName $functionName -Level "WARNING"
				return
			}

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			$dbIndex = 0
			foreach ($db in $targetDbs)
			{
				$dbName = $db.Name
				$dbIndex++
				Write-Progress -Activity $functionName -Status "Datenbank $dbIndex/$($targetDbs.Count): $dbName" -PercentComplete ([int](100 * ($dbIndex - 1) / $targetDbs.Count))

				# ---- Bestand: alle Indizes je Partition aus Metadaten ----
				$inventoryQuery = @"
SET NOCOUNT ON;
SELECT sch.name AS SchemaName, o.name AS TableName, i.name AS IndexName, i.index_id AS IndexId,
       i.type AS IndexType, i.type_desc AS IndexTypeDesc, i.is_disabled AS IsDisabled, i.fill_factor AS [FillFactor],
       ps.partition_number AS PartitionNumber,
       (SELECT COUNT(*) FROM sys.partitions p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) AS PartitionCount,
       ps.row_count AS [Rows], ps.used_page_count AS [PageCount],
       ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) AS Reads,
       ISNULL(us.user_updates, 0) AS Updates
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
JOIN sys.dm_db_partition_stats ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
WHERE i.index_id > 0 AND i.type IN (1, 2, 3, 4, 5, 6) AND i.is_hypothetical = 0
  AND ISNULL(OBJECTPROPERTY(o.object_id, 'TableIsMemoryOptimized'), 0) = 0
  AND o.name LIKE @table
ORDER BY sch.name, o.name, i.index_id, ps.partition_number;
"@
				$inventory = @(Invoke-DbaQuery @connParams -Database $dbName -Query $inventoryQuery -QueryTimeout 3600 -SqlParameter @{ table = $tableLike } -EnableException)

				# ---- Fragmentierung (Rowstore) und geloeschte Zeilen (Columnstore) ----
				$fragMap = @{ }
				if (-not $SkipFragmentation -and $inventory.Count -gt 0)
				{
					Write-Progress -Activity $functionName -Status "Datenbank $dbIndex/$($targetDbs.Count): $dbName - lese Fragmentierung (LIMITED)" -PercentComplete ([int](100 * ($dbIndex - 1) / $targetDbs.Count))
					$fragQuery = @"
SET NOCOUNT ON;
SELECT sch.name AS SchemaName, o.name AS TableName, i.index_id AS IndexId, ps.partition_number AS PartitionNumber,
       CAST(ips.avg_fragmentation_in_percent AS decimal(9,2)) AS FragmentationPercent
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
JOIN sys.dm_db_partition_stats ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), i.object_id, i.index_id, ps.partition_number, 'LIMITED') ips
WHERE i.index_id > 0 AND i.type IN (1, 2, 3, 4) AND i.is_disabled = 0 AND i.is_hypothetical = 0
  AND ISNULL(OBJECTPROPERTY(o.object_id, 'TableIsMemoryOptimized'), 0) = 0
  AND ps.used_page_count >= @minPages AND o.name LIKE @table
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA' AND ips.index_level = 0;
"@
					foreach ($f in @(Invoke-DbaQuery @connParams -Database $dbName -Query $fragQuery -QueryTimeout 86400 -SqlParameter @{ minPages = $MinPageCount; table = $tableLike } -EnableException))
					{
						$fragMap["$($f.SchemaName).$($f.TableName)|$($f.IndexId)|$($f.PartitionNumber)"] = [double]$f.FragmentationPercent
					}

					$hasCs = @(Invoke-DbaQuery @connParams -Database $dbName -Query "SELECT CASE WHEN OBJECT_ID('sys.dm_db_column_store_row_group_physical_stats') IS NULL THEN 0 ELSE 1 END AS HasCs" -EnableException)[0].HasCs
					if ($hasCs -eq 1 -and @($inventory | Where-Object { [int]$_.IndexType -in 5, 6 }).Count -gt 0)
					{
						$csQuery = @"
SET NOCOUNT ON;
SELECT sch.name AS SchemaName, o.name AS TableName, i.index_id AS IndexId, rg.partition_number AS PartitionNumber,
       CAST(100.0 * SUM(CAST(rg.deleted_rows AS bigint)) / NULLIF(SUM(CAST(rg.total_rows AS bigint)), 0) AS decimal(9,2)) AS FragmentationPercent
FROM sys.dm_db_column_store_row_group_physical_stats rg
JOIN sys.indexes i ON i.object_id = rg.object_id AND i.index_id = rg.index_id
JOIN sys.objects o ON o.object_id = i.object_id AND o.is_ms_shipped = 0
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
WHERE rg.state_desc = 'COMPRESSED' AND i.is_disabled = 0 AND o.name LIKE @table
GROUP BY sch.name, o.name, i.index_id, rg.partition_number;
"@
						foreach ($f in @(Invoke-DbaQuery @connParams -Database $dbName -Query $csQuery -QueryTimeout 86400 -SqlParameter @{ table = $tableLike } -EnableException))
						{
							$v = if ($f.FragmentationPercent -is [DBNull]) { 0.0 } else { [double]$f.FragmentationPercent }
							$fragMap["$($f.SchemaName).$($f.TableName)|$($f.IndexId)|$($f.PartitionNumber)"] = $v
						}
					}
				}

				# ---- Bewertung wie Invoke-sqmIndexOptimize ----
				foreach ($c in $inventory)
				{
					$isColumnstore = [int]$c.IndexType -in 5, 6
					$pages = [long]$c.PageCount
					$isPartitioned = [int]$c.PartitionCount -gt 1
					$key = "$($c.SchemaName).$($c.TableName)|$($c.IndexId)|$($c.PartitionNumber)"
					$frag = $null
					if ($fragMap.ContainsKey($key)) { $frag = $fragMap[$key] }

					$status = if ($c.IsDisabled -eq $true -or $c.IsDisabled -eq 1) { 'Disabled' }
					elseif ($SkipFragmentation) { 'NotMeasured' }
					elseif ($null -eq $frag) { if ($pages -lt $MinPageCount) { 'Small' } else { 'NotMeasured' } }
					elseif ($isColumnstore) { if ($frag -ge $ColumnstoreDeletedPercent) { 'Reorganize' } else { 'Ok' } }
					elseif ($frag -ge $FragmentationHigh) { 'Rebuild' }
					elseif ($frag -ge $FragmentationLow) { 'Reorganize' }
					else { 'Ok' }

					if ($OnlyProblems -and $status -notin 'Reorganize', 'Rebuild') { continue }

					$results.Add([PSCustomObject]@{
							SqlInstance		     = $SqlInstance
							Database			 = $dbName
							Table			     = "$($c.SchemaName).$($c.TableName)"
							Index			     = $c.IndexName
							IndexType		     = $c.IndexTypeDesc
							Partition		     = $(if ($isPartitioned) { [int]$c.PartitionNumber } else { $null })
							Rows			     = [long]$c.Rows
							PageCount		     = $pages
							SizeMB			     = [math]::Round($pages * 8 / 1024, 1)
							FragmentationPercent = $frag
							FillFactor		     = [int]$c.FillFactor
							IsDisabled		     = [bool]($c.IsDisabled -eq $true -or $c.IsDisabled -eq 1)
							Reads			     = [long]$c.Reads
							Updates			     = [long]$c.Updates
							Status			     = $status
						})
				}
			}
			Write-Progress -Activity $functionName -Completed

			$output = if ($Summary)
			{
				@($results | Group-Object Database | ForEach-Object {
						$g = @($_.Group)
						$measured = @($g | Where-Object { $null -ne $_.FragmentationPercent })
						$measuredPages = [double](($measured | Measure-Object PageCount -Sum).Sum)
						[PSCustomObject]@{
							SqlInstance		     = $SqlInstance
							Database			 = $_.Name
							Indexes			     = $g.Count
							SizeMB			     = [math]::Round(($g | Measure-Object SizeMB -Sum).Sum, 1)
							Ok				     = @($g | Where-Object Status -eq 'Ok').Count
							Reorganize		     = @($g | Where-Object Status -eq 'Reorganize').Count
							Rebuild			     = @($g | Where-Object Status -eq 'Rebuild').Count
							Small			     = @($g | Where-Object Status -eq 'Small').Count
							Disabled		     = @($g | Where-Object Status -eq 'Disabled').Count
							AvgFragmentationPercent = $(if ($measuredPages -gt 0) { [math]::Round((($measured | ForEach-Object { $_.FragmentationPercent * $_.PageCount } | Measure-Object -Sum).Sum) / $measuredPages, 2) } else { $null })
							MaxFragmentationPercent = $(if ($measured.Count -gt 0) { ($measured | Measure-Object FragmentationPercent -Maximum).Maximum } else { $null })
						}
					})
			}
			else { @($results | Sort-Object Database, @{ Expression = { if ($null -eq $_.FragmentationPercent) { -1 } else { $_.FragmentationPercent } }; Descending = $true }) }

			Invoke-sqmLogging -Message "$functionName abgeschlossen: $($results.Count) Index(-Partitionen), $(@($results | Where-Object Status -eq 'Rebuild').Count) Rebuild, $(@($results | Where-Object Status -eq 'Reorganize').Count) Reorganize." -FunctionName $functionName -Level "INFO"

			if ($OutputPath -and $output.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'
				$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
				$kind = if ($Summary) { 'IndexHealthSummary' } else { 'IndexHealth' }
				$csvFile = Join-Path $OutputPath "${kind}_${safeInst}_${ts}.csv"
				$output | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				$htmlFile = Join-Path $OutputPath "${kind}_${safeInst}_${ts}.html"
				$bodyHtml = ($output | ConvertTo-Html -Fragment -As Table | Out-String)
				$subtitle = "Instanz: $SqlInstance  |  Datenbank: $Database  |  Reorganize ab $FragmentationLow%, Rebuild ab $FragmentationHigh%  |  $($output.Count) Zeile(n)"
				ConvertTo-sqmHtmlReport -Title "Index Health - $SqlInstance" -Subtitle $subtitle -BodyHtml $bodyHtml |
					Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "Report gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}
			$output
		}
		catch
		{
			Write-Progress -Activity $functionName -Completed
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
		}
	}
}
