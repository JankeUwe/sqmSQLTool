<#
.SYNOPSIS
    Analysiert die Fragmentierung von Indizes in einer oder mehreren Datenbanken.

.DESCRIPTION
    Liefert fuer alle Indizes den Fragmentierungsgrad (%) und empfiehlt Aktion:
        - 5-30%   ? REORGANIZE
        - >30%    ? REBUILD
    Die Ausgabe kann auf bestimmte Datenbanken, Tabellen oder einen Mindestfragmentierungsgrad beschraenkt werden.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER Database
    Datenbankname oder Wildcard-Muster (z.B. 'Sales*'). Standard: alle Benutzerdatenbanken.

.PARAMETER TableName
    Tabellenname oder Wildcard-Muster (z.B. 'Order*'). Standard: alle Tabellen.

.PARAMETER MinFragmentationPercent
    Nur Indizes mit Fragmentierung >= diesem Wert anzeigen. Standard: 5.

.PARAMETER PageCountMin
    Nur Indizes mit mindestens dieser Seitenzahl anzeigen. Standard: 0 (alle Indizes).

.PARAMETER OutputPath
    Optionaler CSV-Exportpfad.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Get-sqmIndexFragmentation -Database 'AdventureWorks' -MinFragmentationPercent 10

.EXAMPLE
    Get-sqmIndexFragmentation -SqlInstance 'SQL01' -MinFragmentationPercent 30

.NOTES
    Verwendet sys.dm_db_index_physical_stats (LIMITED-Modus) via Invoke-DbaQuery.
    Erfordert dbatools und VIEW DATABASE STATE auf den Zieldatenbanken.
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
