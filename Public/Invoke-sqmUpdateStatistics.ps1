<#
.SYNOPSIS
    Updates statistics in one or more databases.

.DESCRIPTION
    Executes UPDATE STATISTICS with configurable options (scan percentage, only modified statistics, etc.).
    Can be restricted to specific databases, tables, or statistics.

    Note: dbatools has no Update statistics cmdlet, so this runs UPDATE STATISTICS directly via
    Invoke-DbaQuery. The set of statistics to touch is determined from sys.stats /
    sys.dm_db_stats_properties so -OnlyModified, -Index and the Table/Statistics filters work
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
    Percentage of rows used for the update (0 = FULLSCAN). Default: 0.

.PARAMETER OnlyModified
    Only update statistics that have changed since the last update (modification_counter > 0). Default: $true.

.PARAMETER Index
    Also update statistics backed by an index. When $false, only column statistics are updated. Default: $true.

.PARAMETER WhatIf
    Shows which statistics would be affected.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 10

.NOTES
    Uses dbatools (Get-DbaDatabase, Invoke-DbaQuery). Requires sysadmin/db_owner on the targets.
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
        [int]$SamplePercent = 0,
        [Parameter(Mandatory = $false)]
        [bool]$OnlyModified = $true,
        [Parameter(Mandatory = $false)]
        [bool]$Index = $true,
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

        Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Database='$Database', Table='$Table', Statistics='$Statistics', SamplePercent=$SamplePercent, OnlyModified=$OnlyModified, Index=$Index)" -FunctionName $functionName -Level "INFO"
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

            # WITH-Klausel: FULLSCAN oder SAMPLE n PERCENT
            $withClause = if ($SamplePercent -le 0) { 'FULLSCAN' } else { "SAMPLE $SamplePercent PERCENT" }

            foreach ($db in $targetDbs) {
                $dbName = $db.Name

                # Zu aktualisierende Statistiken serverseitig ermitteln.
                # auto_created/user_created = Spaltenstatistiken; alles andere (index-gestuetzt) nur wenn -Index.
                $selectQuery = @"
SELECT sch.name AS SchemaName, t.name AS TableName, s.name AS StatName,
       CASE WHEN i.object_id IS NOT NULL THEN 1 ELSE 0 END AS IsIndexStat,
       sp.modification_counter AS ModCounter
FROM sys.stats s
JOIN sys.objects t  ON s.object_id = t.object_id AND t.type = 'U' AND t.is_ms_shipped = 0
JOIN sys.schemas sch ON t.schema_id = sch.schema_id
LEFT JOIN sys.indexes i ON i.object_id = s.object_id AND i.name = s.name
OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE t.name LIKE @table AND s.name LIKE @stat
"@
                $stats = @(Invoke-DbaQuery @connParams -Database $dbName -Query $selectQuery -SqlParameter @{ table = $tableLike; stat = $statLike })

                foreach ($st in $stats) {
                    if (-not $Index -and $st.IsIndexStat -eq 1) { continue }
                    if ($OnlyModified -and (($st.ModCounter -eq $null) -or ($st.ModCounter -le 0))) { continue }

                    $tableEsc = "[$($st.SchemaName -replace '\]', ']]')].[$($st.TableName -replace '\]', ']]')]"
                    $statEsc  = "[$($st.StatName -replace '\]', ']]')]"
                    $updateQuery = "UPDATE STATISTICS $tableEsc ($statEsc) WITH $withClause"
                    $target = "$dbName : $($st.SchemaName).$($st.TableName).$($st.StatName)"

                    if ($PSCmdlet.ShouldProcess($target, "UPDATE STATISTICS WITH $withClause")) {
                        try {
                            Invoke-DbaQuery @connParams -Database $dbName -Query $updateQuery | Out-Null
                            [PSCustomObject]@{
                                SqlInstance = $SqlInstance
                                Database    = $dbName
                                Table       = "$($st.SchemaName).$($st.TableName)"
                                Statistic   = $st.StatName
                                Status      = 'Success'
                                Message     = "Updated WITH $withClause"
                            }
                        }
                        catch {
                            $errMsg = "Fehler bei UPDATE STATISTICS ($target): $($_.Exception.Message)"
                            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                            if ($EnableException) { throw }
                            [PSCustomObject]@{
                                SqlInstance = $SqlInstance
                                Database    = $dbName
                                Table       = "$($st.SchemaName).$($st.TableName)"
                                Statistic   = $st.StatName
                                Status      = 'Failed'
                                Message     = $errMsg
                            }
                        }
                    }
                }
            }
        }
        catch {
            Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw }
        }
    }
}
