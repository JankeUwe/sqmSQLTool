<#
.SYNOPSIS
    Reports the state of all statistics (age, changes since the last update, sample) and which of
    them Invoke-sqmUpdateStatistics would update.

.DESCRIPTION
    Read-only counterpart of Invoke-sqmUpdateStatistics: the same rule decides 'NeedsUpdate'
    (default: changes >= MIN(SQRT(1000 * rows), rows * ModificationPercent / 100), or at least one
    change and older than -MaxAgeDays). Nothing is changed.

    Per statistic:
      Rows, RowsSampled, SamplePercent, Steps (histogram steps), Modifications since the last
      update, ModificationPercent, Threshold (changes needed), LastUpdated, AgeDays,
      NoRecompute (auto update off for this statistic), PersistedSamplePercent, IsFiltered,
      IsIndexStat, NeedsUpdate, Reason.

    Status:
      Ok            nothing to do
      Stale         NeedsUpdate (threshold or age reached)
      NeverUpdated  statistic without data (Invoke-sqmUpdateStatistics skips it)
      NoRecompute   as Ok/Stale, but with NORECOMPUTE: SQL Server never updates it automatically

    The database settings that decide whether SQL Server updates statistics itself (AUTO_UPDATE_STATISTICS,
    ..._ASYNC, AUTO_CREATE_STATISTICS) are part of every row, so a database with auto update off
    shows up directly.

    -Summary returns one row per database: number of statistics, how many are stale, the oldest
    update, the largest number of changes, the database settings.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name or wildcard pattern. System databases are excluded unless named explicitly.
    Default: '*' (all user databases).

.PARAMETER Table
    Table name or wildcard pattern. Default: '*'.

.PARAMETER Statistics
    Statistic name or wildcard pattern. Default: '*'.

.PARAMETER ModificationThreshold
    Dynamic (default): changes must reach MIN(SQRT(1000 * rows), rows * ModificationPercent / 100).
    Any: at least one change.

.PARAMETER ModificationPercent
    Percentage part of the dynamic threshold. Default: 10.

.PARAMETER MaxAgeDays
    Statistics with at least one change that were last updated more than this many days ago count
    as stale. 0 = off. Default: 30.

.PARAMETER Index
    Include statistics backed by an index. $false: column statistics only. Default: $true.

.PARAMETER OnlyProblems
    Only statistics with Status Stale, NeverUpdated or a NoRecompute statistic with changes.

.PARAMETER Summary
    One row per database instead of one row per statistic.

.PARAMETER OutputPath
    Directory for reports (CSV + HTML). Default: <OutputPath config>\StatisticsHealth.
    Pass '' to skip the files.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # What would the next statistics run update?
    Get-sqmStatisticsHealth -SqlInstance 'SQL01' -OnlyProblems -OutputPath '' |
        Format-Table Database, Table, Statistic, Rows, Modifications, AgeDays, Reason

.EXAMPLE
    # One line per database, including the auto-update settings
    Get-sqmStatisticsHealth -SqlInstance 'SQL01' -Summary -OutputPath ''

.NOTES
    Uses dbatools (Get-DbaDatabase, Invoke-DbaQuery) and sys.dm_db_stats_properties. Requires
    VIEW DATABASE STATE / SELECT on the target databases. Temporary statistics of readable
    secondaries are not listed.
#>
function Get-sqmStatisticsHealth
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
		[string]$Statistics = '*',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Dynamic', 'Any')]
		[string]$ModificationThreshold = 'Dynamic',
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int]$ModificationPercent = 10,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 3650)]
		[int]$MaxAgeDays = 30,
		[Parameter(Mandatory = $false)]
		[bool]$Index = $true,
		[Parameter(Mandatory = $false)]
		[switch]$OnlyProblems,
		[Parameter(Mandatory = $false)]
		[switch]$Summary,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'StatisticsHealth'),
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
		$tableLike = ($Table -replace '\*', '%') -replace '\?', '_'
		$statLike = ($Statistics -replace '\*', '%') -replace '\?', '_'
		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Database='$Database', Table='$Table', Statistics='$Statistics', Threshold=$ModificationThreshold/$ModificationPercent%, MaxAgeDays=$MaxAgeDays, Index=$Index)" -FunctionName $functionName -Level "INFO"
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

				# persisted_sample_percent gibt es erst ab 2016 SP1 CU4
				$hasPersisted = @(Invoke-DbaQuery @connParams -Database $dbName -Query "SELECT COUNT(*) AS N FROM sys.all_columns WHERE object_id = OBJECT_ID('sys.dm_db_stats_properties') AND name = 'persisted_sample_percent'" -EnableException)[0].N -gt 0
				$persistedCol = if ($hasPersisted) { 'sp.persisted_sample_percent' } else { 'CAST(NULL AS float)' }

				$dbSettings = @(Invoke-DbaQuery @connParams -Database $dbName -Query "SELECT is_auto_update_stats_on AS AutoUpdate, is_auto_update_stats_async_on AS AutoUpdateAsync, is_auto_create_stats_on AS AutoCreate FROM sys.databases WHERE database_id = DB_ID()" -EnableException)[0]

				$statQuery = @"
SET NOCOUNT ON;
SELECT sch.name AS SchemaName, t.name AS TableName, s.name AS StatName,
       CASE WHEN i.object_id IS NOT NULL THEN 1 ELSE 0 END AS IsIndexStat,
       s.no_recompute AS NoRecompute, s.has_filter AS IsFiltered,
       sp.rows AS [Rows], sp.rows_sampled AS RowsSampled, sp.steps AS Steps,
       sp.modification_counter AS ModCounter, sp.last_updated AS LastUpdated,
       DATEDIFF(DAY, sp.last_updated, GETDATE()) AS AgeDays,
       $persistedCol AS PersistedSamplePercent
FROM sys.stats s
JOIN sys.objects t  ON s.object_id = t.object_id AND t.type = 'U' AND t.is_ms_shipped = 0
JOIN sys.schemas sch ON t.schema_id = sch.schema_id
LEFT JOIN sys.indexes i ON i.object_id = s.object_id AND i.name = s.name
OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE t.name LIKE @table AND s.name LIKE @stat AND s.is_temporary = 0
ORDER BY sp.modification_counter DESC;
"@
				$stats = @(Invoke-DbaQuery @connParams -Database $dbName -Query $statQuery -QueryTimeout 3600 -SqlParameter @{ table = $tableLike; stat = $statLike } -EnableException)

				foreach ($st in $stats)
				{
					if (-not $Index -and $st.IsIndexStat -eq 1) { continue }

					$neverUpdated = ($st.LastUpdated -is [DBNull] -or $null -eq $st.LastUpdated)
					$rows = if ($st.Rows -is [DBNull] -or $null -eq $st.Rows) { 0 } else { [long]$st.Rows }
					$sampled = if ($st.RowsSampled -is [DBNull] -or $null -eq $st.RowsSampled) { $null } else { [long]$st.RowsSampled }
					$mod = if ($st.ModCounter -is [DBNull] -or $null -eq $st.ModCounter) { $null } else { [long]$st.ModCounter }
					$age = if ($st.AgeDays -is [DBNull] -or $null -eq $st.AgeDays) { $null } else { [int]$st.AgeDays }
					$persisted = if ($st.PersistedSamplePercent -is [DBNull] -or $null -eq $st.PersistedSamplePercent) { $null } else { [double]$st.PersistedSamplePercent }
					$noRecompute = ($st.NoRecompute -eq $true -or $st.NoRecompute -eq 1)

					$decision = Get-sqmStatisticsDecision -Rows $rows -Modifications $mod -AgeDays $age -OnlyModified $true -ModificationThreshold $ModificationThreshold -ModificationPercent $ModificationPercent -MaxAgeDays $MaxAgeDays
					$status = if ($neverUpdated) { 'NeverUpdated' }
					elseif ($decision.NeedsUpdate) { 'Stale' }
					elseif ($noRecompute -and $mod -gt 0) { 'NoRecompute' }
					else { 'Ok' }

					if ($OnlyProblems -and $status -notin 'Stale', 'NeverUpdated', 'NoRecompute') { continue }

					$results.Add([PSCustomObject]@{
							SqlInstance		       = $SqlInstance
							Database			   = $dbName
							Table			       = "$($st.SchemaName).$($st.TableName)"
							Statistic			   = $st.StatName
							IsIndexStat		       = [bool]($st.IsIndexStat -eq 1)
							Rows				   = $rows
							RowsSampled		       = $sampled
							SamplePercent		   = $(if ($sampled -and $rows -gt 0) { [math]::Round(100.0 * $sampled / $rows, 1) } else { $null })
							Steps				   = $(if ($st.Steps -is [DBNull] -or $null -eq $st.Steps) { $null } else { [int]$st.Steps })
							Modifications		   = $mod
							ModificationPercent    = $(if ($null -ne $mod -and $rows -gt 0) { [math]::Round(100.0 * $mod / $rows, 2) } else { $null })
							Threshold			   = $decision.Threshold
							LastUpdated		       = $(if ($neverUpdated) { $null } else { $st.LastUpdated })
							AgeDays			       = $age
							NoRecompute		       = $noRecompute
							PersistedSamplePercent = $persisted
							IsFiltered			   = [bool]($st.IsFiltered -eq $true -or $st.IsFiltered -eq 1)
							AutoUpdateStats	       = [bool]($dbSettings.AutoUpdate -eq $true -or $dbSettings.AutoUpdate -eq 1)
							AutoUpdateAsync	       = [bool]($dbSettings.AutoUpdateAsync -eq $true -or $dbSettings.AutoUpdateAsync -eq 1)
							AutoCreateStats	       = [bool]($dbSettings.AutoCreate -eq $true -or $dbSettings.AutoCreate -eq 1)
							NeedsUpdate		       = [bool]($decision.NeedsUpdate -and -not $neverUpdated)
							Reason			       = $(if ($neverUpdated) { 'NeverUpdated (no data; Invoke-sqmUpdateStatistics skips it)' } else { $decision.Reason })
							Status			       = $status
						})
				}
			}
			Write-Progress -Activity $functionName -Completed

			$output = if ($Summary)
			{
				@($results | Group-Object Database | ForEach-Object {
						$g = @($_.Group)
						$first = $g[0]
						$updated = @($g | Where-Object { $null -ne $_.LastUpdated })
						[PSCustomObject]@{
							SqlInstance		 = $SqlInstance
							Database			 = $_.Name
							Statistics		 = $g.Count
							Ok				 = @($g | Where-Object Status -eq 'Ok').Count
							Stale			 = @($g | Where-Object Status -eq 'Stale').Count
							NeverUpdated	 = @($g | Where-Object Status -eq 'NeverUpdated').Count
							NoRecompute		 = @($g | Where-Object NoRecompute).Count
							OldestUpdate	 = $(if ($updated.Count -gt 0) { ($updated | Measure-Object LastUpdated -Minimum).Minimum } else { $null })
							MaxAgeDays		 = $(if ($updated.Count -gt 0) { ($updated | Measure-Object AgeDays -Maximum).Maximum } else { $null })
							MaxModifications = $(if ($g.Count -gt 0) { ($g | Measure-Object Modifications -Maximum).Maximum } else { $null })
							AutoUpdateStats	 = $first.AutoUpdateStats
							AutoUpdateAsync	 = $first.AutoUpdateAsync
							AutoCreateStats	 = $first.AutoCreateStats
						}
					})
			}
			else { @($results | Sort-Object Database, @{ Expression = { if ($null -eq $_.Modifications) { -1 } else { $_.Modifications } }; Descending = $true }) }

			Invoke-sqmLogging -Message "$functionName abgeschlossen: $($results.Count) Statistik(en), $(@($results | Where-Object Status -eq 'Stale').Count) veraltet, $(@($results | Where-Object Status -eq 'NeverUpdated').Count) nie aktualisiert." -FunctionName $functionName -Level "INFO"

			if ($OutputPath -and $output.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'
				$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
				$kind = if ($Summary) { 'StatisticsHealthSummary' } else { 'StatisticsHealth' }
				$csvFile = Join-Path $OutputPath "${kind}_${safeInst}_${ts}.csv"
				$output | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				$htmlFile = Join-Path $OutputPath "${kind}_${safeInst}_${ts}.html"
				$bodyHtml = ($output | ConvertTo-Html -Fragment -As Table | Out-String)
				$subtitle = "Instanz: $SqlInstance  |  Datenbank: $Database  |  Schwelle: $ModificationThreshold, Alter > $MaxAgeDays Tage  |  $($output.Count) Zeile(n)"
				ConvertTo-sqmHtmlReport -Title "Statistics Health - $SqlInstance" -Subtitle $subtitle -BodyHtml $bodyHtml |
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
