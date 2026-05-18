<#
.SYNOPSIS
    Analyzes index fragmentation in one or more databases.

.DESCRIPTION
    Returns the fragmentation level (%) for all indexes and recommends an action:
        - 5-30%  -> REORGANIZE
        - >30%   -> REBUILD
    Output can be restricted to specific databases, tables or a minimum fragmentation level.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name or wildcard pattern (e.g. 'Sales*'). Default: all user databases.

.PARAMETER TableName
    Table name or wildcard pattern (e.g. 'Order*'). Default: all tables.

.PARAMETER MinFragmentationPercent
    Show only indexes with fragmentation >= this value. Default: 5.

.PARAMETER PageCountMin
    Show only indexes with at least this page count. Default: 0 (all indexes).

.PARAMETER OutputPath
    Optional CSV export path.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmIndexFragmentation -Database 'AdventureWorks' -MinFragmentationPercent 10

.EXAMPLE
    Get-sqmIndexFragmentation -SqlInstance 'SQL01' -MinFragmentationPercent 30

.NOTES
    Uses sys.dm_db_index_physical_stats (LIMITED mode) via Invoke-DbaQuery.
    Requires dbatools and VIEW DATABASE STATE on the target databases.
#>
function Get-sqmIndexFragmentation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$SqlInstance = $env:COMPUTERNAME,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,
        [Parameter(Mandatory = $false)]
        [string]$Database = '*',
        [Parameter(Mandatory = $false)]
        [string]$TableName = '*',
        [Parameter(Mandatory = $false)]
        [int]$MinFragmentationPercent = 5,
        [Parameter(Mandatory = $false)]
        [int]$PageCountMin = 0,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin {
        $functionName = $MyInvocation.MyCommand.Name
        if (-not $script:dbatoolsAvailable) {
            $errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    process {
        try {
            # Get-DbaDatabase unterstuetzt keine Wildcards im -Database-Parameter.
            # Daher: alle Benutzerdatenbanken laden und anschliessend per -like filtern.
            $allDbs = Get-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
                                      -ExcludeSystem -ErrorAction Stop

            $dbList = if ($Database -eq '*') {
                $allDbs
            } else {
                $allDbs | Where-Object { $_.Name -like $Database }
            }

            if (-not $dbList) {
                Invoke-sqmLogging -Message "Keine Datenbanken auf '$SqlInstance' gefunden (Filter: '$Database')." `
                                  -FunctionName $functionName -Level "WARNING"
                return $results
            }

            # Fragmentierungsdaten kommen aus sys.dm_db_index_physical_stats (DMV),
            # nicht aus SMO-Index-Objekten (Get-DbaDbIndex liefert keine FragPercent/PageCount).
            $query = @"
SELECT
    OBJECT_SCHEMA_NAME(ips.object_id)   AS SchemaName,
    OBJECT_NAME(ips.object_id)          AS TableName,
    i.name                              AS IndexName,
    i.type_desc                         AS IndexType,
    ips.avg_fragmentation_in_percent    AS AvgFragmentationPercent,
    ips.page_count                      AS PageCount
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i
    ON  ips.object_id = i.object_id
    AND ips.index_id  = i.index_id
WHERE ips.index_id > 0
  AND ips.page_count                 >= $PageCountMin
  AND ips.avg_fragmentation_in_percent >= $MinFragmentationPercent
ORDER BY ips.avg_fragmentation_in_percent DESC
"@

            foreach ($db in $dbList) {
                try {
                    $rows = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
                                           -Database $db.Name -Query $query -ErrorAction Stop

                    foreach ($row in $rows) {
                        # Tabellen-Wildcard-Filter (in PowerShell, da Parametername kein SQL-Parameter ist)
                        if ($TableName -ne '*' -and $row.TableName -notlike $TableName) { continue }

                        $frag   = $row.AvgFragmentationPercent
                        $action = if ($frag -lt 30) { 'REORGANIZE' } else { 'REBUILD' }

                        $results.Add([PSCustomObject]@{
                            SqlInstance       = $SqlInstance
                            Database          = $db.Name
                            Schema            = $row.SchemaName
                            TableName         = $row.TableName
                            IndexName         = $row.IndexName
                            IndexType         = $row.IndexType
                            PageCount         = $row.PageCount
                            FragPercent       = [math]::Round($frag, 2)
                            RecommendedAction = $action
                        })
                    }
                }
                catch {
                    Invoke-sqmLogging -Message "Fehler in DB '$($db.Name)': $($_.Exception.Message)" `
                                      -FunctionName $functionName -Level "WARNING"
                    if ($EnableException) { throw }
                }
            }

            if ($OutputPath) {
                $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Force
                Invoke-sqmLogging -Message "CSV exportiert nach $OutputPath" -FunctionName $functionName -Level "INFO"
            }
            return $results
        }
        catch {
            Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw }
            return $null
        }
    }
}
