<#
.SYNOPSIS
    Updates statistics in one or more databases with adaptive defaults (threshold, sample size).

.DESCRIPTION
    Executes UPDATE STATISTICS only where it pays off and with a sample size that fits the table.
    Can be restricted to specific databases, tables, or statistics.

    Defaults (no parameters needed):

    - Which statistics: only those with enough changes since the last update
      (-ModificationThreshold Dynamic). A statistic is updated when
          modification_counter >= MIN( SQRT(1000 * rows), rows * ModificationPercent / 100 )
      i.e. 10 % for small tables and the SQL Server 2016+ dynamic threshold SQRT(1000 * rows)
      for large ones (100 M rows: from 316,228 changes = 0.3 %). Statistics with at least one
      change that are older than -MaxAgeDays (30) are updated as well (ascending keys).
    - Sample size: FULLSCAN up to -FullScanRowLimit rows (1,000,000); above that a sample of about
      the same number of rows, at least 1 % (10 M rows: 10 %, 100 M rows: 1 %). A persisted sample
      rate (PERSIST_SAMPLE_PERCENT) is honoured.
    - NORECOMPUTE on a statistic is kept (a plain UPDATE STATISTICS would remove it).
    - Read-only databases and AG secondaries are skipped, as are temporary statistics of readable
      secondaries.

    -SamplePercent switches to a fixed sample for all statistics (0 = FULLSCAN, previous behaviour).
    -ModificationThreshold Any updates every statistic with at least one change (previous behaviour).

    Note: dbatools has no Update statistics cmdlet, so this runs UPDATE STATISTICS directly via
    Invoke-DbaQuery. The set of statistics to touch is determined from sys.stats /
    sys.dm_db_stats_properties so the threshold, -Index and the Table/Statistics filters work
    server-side before anything is updated.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name or wildcard pattern (PowerShell wildcards, e.g. '*' or 'Sales*'). System databases
    are excluded unless named explicitly. Default: '*' (all user databases).

.PARAMETER Table
    Table name or wildcard pattern. Default: '*'.

.PARAMETER Statistics
    Statistic name or wildcard pattern. Default: '*'.

.PARAMETER SamplePercent
    Fixed sample for all statistics: 0 = FULLSCAN, 1-100 = SAMPLE n PERCENT.
    Without this parameter the sample is chosen per statistic (see -FullScanRowLimit).

.PARAMETER FullScanRowLimit
    Adaptive sample: statistics on up to this many rows are updated WITH FULLSCAN, larger ones
    with a sample of about this many rows (at least 1 %). Default: 1000000.

.PARAMETER OnlyModified
    Only update statistics that have changed since the last update. Default: $true.
    $false updates every matching statistic regardless of changes.

.PARAMETER ModificationThreshold
    Dynamic (default): changes must reach MIN(SQRT(1000 * rows), rows * ModificationPercent / 100).
    Any: at least one change (previous behaviour).

.PARAMETER ModificationPercent
    Percentage part of the dynamic threshold (relevant for small tables). Default: 10.

.PARAMETER MaxAgeDays
    Statistics with at least one change that were last updated more than this many days ago are
    updated even below the threshold. 0 = off. Default: 30.

.PARAMETER Index
    Also update statistics backed by an index. When $false, only column statistics are updated. Default: $true.

.PARAMETER TimeLimitMinutes
    Do not start further updates after this many minutes (maintenance window). The remaining
    statistics are returned with Status 'NotStarted'. 0 = no limit. Default: 0.

.PARAMETER WhatIf
    Shows which statistics would be affected.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Adaptive defaults for all user databases
    Invoke-sqmUpdateStatistics -SqlInstance 'SQL01'

.EXAMPLE
    # Only show what would be updated, with the chosen sample
    Invoke-sqmUpdateStatistics -SqlInstance 'SQL01' -Database 'SalesDB' -WhatIf

.EXAMPLE
    Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 10

.EXAMPLE
    # Previous behaviour: every changed statistic WITH FULLSCAN
    Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 0 -ModificationThreshold Any

.NOTES
    Uses dbatools (Get-DbaDatabase, Invoke-DbaQuery). Requires sysadmin/db_owner on the targets.
    Output per statistic: Rows, Modifications, LastUpdated, Option (FULLSCAN / SAMPLE n PERCENT),
    Reason, Status (Success, Failed, WhatIf, NotStarted), Duration_s.
#>
function Invoke-sqmUpdateStatistics {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
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
        [ValidateRange(0, 100)]
        [int]$SamplePercent,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1000, [long]::MaxValue)]
        [long]$FullScanRowLimit = 1000000,
        [Parameter(Mandatory = $false)]
        [bool]$OnlyModified = $true,
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
        [ValidateRange(0, 10080)]
        [int]$TimeLimitMinutes = 0,
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin {
        $functionName = $MyInvocation.MyCommand.Name
        if (-not $script:dbatoolsAvailable -and -not (Get-Module -ListAvailable -Name dbatools)) {
            throw "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
        }

        # PowerShell-Wildcards (* ?) -> SQL LIKE (% _)
        $tableLike = ($Table     -replace '\*', '%') -replace '\?', '_'
        $statLike  = ($Statistics -replace '\*', '%') -replace '\?', '_'

        $connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
        if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

        $fixedSample = $PSBoundParameters.ContainsKey('SamplePercent')
        $sampleText = if ($fixedSample) { if ($SamplePercent -eq 0) { 'FULLSCAN' } else { "SAMPLE $SamplePercent PERCENT" } } else { "adaptiv (FULLSCAN bis $FullScanRowLimit Zeilen)" }
        $started = [System.Diagnostics.Stopwatch]::StartNew()

        Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Database='$Database', Table='$Table', Statistics='$Statistics', Sample=$sampleText, OnlyModified=$OnlyModified, Threshold=$ModificationThreshold/$ModificationPercent%, MaxAgeDays=$MaxAgeDays, Index=$Index, TimeLimit=$TimeLimitMinutes min)" -FunctionName $functionName -Level "INFO"
    }

    process {
        try {
            # Zieldatenbanken aufloesen. System-DBs nur wenn explizit benannt (kein Wildcard, kein '*').
            $dbParams = $connParams.Clone()
            if ($Database -notmatch '[\*\?]') { $dbParams['Database'] = $Database } else { $dbParams['ExcludeSystem'] = $true }
            $targetDbs = @(Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible -and $_.Name -like $Database })

            if ($targetDbs.Count -eq 0) {
                Invoke-sqmLogging -Message "Keine passenden Datenbanken fuer Muster '$Database' gefunden." -FunctionName $functionName -Level "WARNING"
                return
            }

            foreach ($db in $targetDbs) {
                $dbName = $db.Name

                # Nur beschreibbare Datenbanken (READ_ONLY und AG-Secondaries ueberspringen)
                $upd = @(Invoke-DbaQuery @connParams -Database $dbName -Query "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS nvarchar(20)) AS Updateability")[0].Updateability
                if ($upd -ne 'READ_WRITE') {
                    Invoke-sqmLogging -Message "[$dbName] nicht beschreibbar (Updateability=$upd, z. B. READ_ONLY oder AG-Secondary) - uebersprungen." -FunctionName $functionName -Level "WARNING"
                    continue
                }

                # persisted_sample_percent gibt es erst ab 2016 SP1 CU4
                $hasPersisted = @(Invoke-DbaQuery @connParams -Database $dbName -Query "SELECT COUNT(*) AS N FROM sys.all_columns WHERE object_id = OBJECT_ID('sys.dm_db_stats_properties') AND name = 'persisted_sample_percent'")[0].N -gt 0
                $persistedCol = if ($hasPersisted) { 'sp.persisted_sample_percent' } else { 'CAST(NULL AS float)' }

                # Zu aktualisierende Statistiken serverseitig ermitteln.
                # auto_created/user_created = Spaltenstatistiken; alles andere (index-gestuetzt) nur wenn -Index.
                $selectQuery = @"
SET NOCOUNT ON;
SELECT sch.name AS SchemaName, t.name AS TableName, s.name AS StatName,
       CASE WHEN i.object_id IS NOT NULL THEN 1 ELSE 0 END AS IsIndexStat,
       s.no_recompute AS NoRecompute,
       sp.rows AS [Rows], sp.modification_counter AS ModCounter, sp.last_updated AS LastUpdated,
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
                $stats = @(Invoke-DbaQuery @connParams -Database $dbName -Query $selectQuery -SqlParameter @{ table = $tableLike; stat = $statLike })

                $selected = 0
                foreach ($st in $stats) {
                    if (-not $Index -and $st.IsIndexStat -eq 1) { continue }

                    $rows = if ($st.Rows -is [DBNull] -or $null -eq $st.Rows) { 0 } else { [long]$st.Rows }
                    $mod = if ($st.ModCounter -is [DBNull] -or $null -eq $st.ModCounter) { $null } else { [long]$st.ModCounter }
                    $ageDays = if ($st.AgeDays -is [DBNull] -or $null -eq $st.AgeDays) { $null } else { [int]$st.AgeDays }

                    # Auswahl: Schwelle erreicht?
                    $reason = 'All'
                    if ($OnlyModified) {
                        if ($null -eq $mod -or $mod -le 0) { continue }
                        if ($ModificationThreshold -eq 'Any') {
                            $reason = "Modified ($mod)"
                        }
                        else {
                            $threshold = [math]::Max(1, [math]::Ceiling([math]::Min([math]::Sqrt(1000.0 * $rows), $rows * $ModificationPercent / 100.0)))
                            if ($mod -ge $threshold) {
                                $reason = "Threshold ($mod >= $threshold)"
                            }
                            elseif ($MaxAgeDays -gt 0 -and $null -ne $ageDays -and $ageDays -gt $MaxAgeDays) {
                                $reason = "Age ($ageDays d > $MaxAgeDays d, $mod changes)"
                            }
                            else { continue }
                        }
                    }
                    $selected++

                    # Stichprobe: fest, persistiert oder adaptiv
                    $persisted = if ($st.PersistedSamplePercent -is [DBNull] -or $null -eq $st.PersistedSamplePercent) { 0 } else { [double]$st.PersistedSamplePercent }
                    $withClause = if ($fixedSample) {
                        if ($SamplePercent -eq 0) { 'FULLSCAN' } else { "SAMPLE $SamplePercent PERCENT" }
                    }
                    elseif ($persisted -gt 0) {
                        "SAMPLE $([math]::Min(100, [math]::Ceiling($persisted))) PERCENT, PERSIST_SAMPLE_PERCENT = ON"
                    }
                    elseif ($rows -le $FullScanRowLimit) {
                        'FULLSCAN'
                    }
                    else {
                        "SAMPLE $([math]::Max(1, [math]::Ceiling(100.0 * $FullScanRowLimit / $rows))) PERCENT"
                    }
                    if ($st.NoRecompute -eq $true -or $st.NoRecompute -eq 1) { $withClause += ', NORECOMPUTE' }

                    $tableEsc = "[$($st.SchemaName -replace '\]', ']]')].[$($st.TableName -replace '\]', ']]')]"
                    $statEsc  = "[$($st.StatName -replace '\]', ']]')]"
                    $updateQuery = "UPDATE STATISTICS $tableEsc ($statEsc) WITH $withClause"
                    $target = "$dbName : $($st.SchemaName).$($st.TableName).$($st.StatName)"

                    $row = [ordered]@{
                        SqlInstance   = $SqlInstance
                        Database      = $dbName
                        Table         = "$($st.SchemaName).$($st.TableName)"
                        Statistic     = $st.StatName
                        Rows          = $rows
                        Modifications = $mod
                        LastUpdated   = $(if ($st.LastUpdated -is [DBNull]) { $null } else { $st.LastUpdated })
                        Option        = $withClause
                        Reason        = $reason
                        Status        = $null
                        Duration_s    = 0
                        Message       = $null
                    }

                    if ($TimeLimitMinutes -gt 0 -and $started.Elapsed.TotalMinutes -ge $TimeLimitMinutes) {
                        $row.Status = 'NotStarted'
                        $row.Message = "Zeitlimit $TimeLimitMinutes min erreicht."
                        [PSCustomObject]$row
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess($target, "UPDATE STATISTICS WITH $withClause")) {
                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        try {
                            Invoke-DbaQuery @connParams -Database $dbName -Query $updateQuery -QueryTimeout 86400 -EnableException | Out-Null
                            $row.Status = 'Success'
                            $row.Message = "Updated WITH $withClause"
                        }
                        catch {
                            $errMsg = "Fehler bei UPDATE STATISTICS ($target): $($_.Exception.Message)"
                            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                            if ($EnableException) { throw }
                            $row.Status = 'Failed'
                            $row.Message = $errMsg
                        }
                        $row.Duration_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                        [PSCustomObject]$row
                    }
                    else {
                        $row.Status = 'WhatIf'
                        $row.Message = "WhatIf: $updateQuery"
                        [PSCustomObject]$row
                    }
                }
                Invoke-sqmLogging -Message "[$dbName] $($stats.Count) Statistik(en) geprueft, $selected ausgewaehlt." -FunctionName $functionName -Level "INFO"
            }
        }
        catch {
            Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw }
        }
    }
}
