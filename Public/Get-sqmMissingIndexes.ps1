<#
.SYNOPSIS
    Ermittelt fehlende Indexempfehlungen aus dem SQL Server DMV-Cache.

.DESCRIPTION
    Liest sys.dm_db_missing_index_details, sys.dm_db_missing_index_groups und
    sys.dm_db_missing_index_group_stats aus und berechnet pro fehlendem Index
    einen Impact-Score (nach Microsoft-Formel) sowie ein fertiges CREATE INDEX-Statement.

    Pro Empfehlung werden ausgegeben:
      - Datenbank, Schema, Tabelle
      - Equality- und Inequality-Spalten, Include-Spalten
      - Impact-Score (0-100, berechnet aus seeks/scans/lookups ? avg_user_cost ? avg_user_impact)
      - Anzahl seeks, scans, lookups seit letztem SQL Server-Neustart
      - Letzter Seek-Zeitpunkt
      - Fertiges CREATE INDEX-Statement mit vorgeschlagenem Indexnamen

    WICHTIG: Die DMV-Daten sind volatil (Reset bei SQL Server-Neustart, Failover,
    und bei bestimmten Plan-Cache-Ereignissen). Empfehlungen immer mit dem DBA
    pruefen bevor Indizes erstellt werden - besonders auf hoch ausgelasteten Systemen.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER Database
    Datenbankname(n) filtern. Wildcards erlaubt. Standard: alle Benutzerdatenbanken.

.PARAMETER MinImpactScore
    Nur Empfehlungen mit Impact-Score >= diesem Wert ausgeben. Standard: 10.

.PARAMETER MinSeeks
    Nur Empfehlungen mit mindestens dieser Anzahl Seeks/Scans ausgeben. Standard: 50.

.PARAMETER Top
    Maximal diese Anzahl Empfehlungen zurueckgeben (nach Impact-Score sortiert). Standard: 50.

.PARAMETER OutputPath
    Wenn angegeben, wird eine CSV-Datei mit den Empfehlungen und CREATE-Statements
    in dieses Verzeichnis geschrieben.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Get-sqmMissingIndexes -SqlInstance "SQL01"

.EXAMPLE
    # Nur sehr impactreiche Empfehlungen
    Get-sqmMissingIndexes -SqlInstance "SQL01" -MinImpactScore 50 -MinSeeks 500

.EXAMPLE
    # Top 10 ausgeben und als CSV speichern
    Get-sqmMissingIndexes -SqlInstance "SQL01" -Top 10 -OutputPath "D:\Reports"

.EXAMPLE
    # CREATE INDEX-Statements direkt ausgeben
    Get-sqmMissingIndexes -SqlInstance "SQL01" -MinImpactScore 30 |
        Select-Object DatabaseName, TableName, ImpactScore, CreateIndexStatement |
        Format-List

.NOTES
    Erfordert: dbatools, Invoke-sqmLogging
    Benoetigt VIEW SERVER STATE auf der Instanz.
    DMV-Daten werden bei SQL Server-Neustart oder Failover zurueckgesetzt.
    Vorgeschlagene Indexnamen enthalten Datum und Spaltenkuerzel - vor Einsatz
    auf Namenskonventionen pruefen und ggf. anpassen.
    Impact-Score-Formel: seeks ? avg_cost ? avg_impact + scans ? avg_cost ? avg_impact
#>
function Get-sqmMissingIndexes
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
		[double]$MinImpactScore = 10,
		[Parameter(Mandatory = $false)]
		[long]$MinSeeks = 50,
		[Parameter(Mandatory = $false)]
		[int]$Top = 50,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
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
		
		Invoke-sqmLogging -Message ("Starte " + $functionName + " auf " + $SqlInstance) -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database	  = 'master'
			}
			
			# -------------------------------------------------------------------
			# Abfrage: fehlende Indizes mit Impact-Score
			# -------------------------------------------------------------------
			$query = @"
SELECT TOP $Top
    DB_NAME(mid.database_id)                         AS DatabaseName,
    OBJECT_SCHEMA_NAME(mid.object_id, mid.database_id) AS SchemaName,
    OBJECT_NAME(mid.object_id, mid.database_id)      AS TableName,
    mid.equality_columns                             AS EqualityColumns,
    mid.inequality_columns                           AS InequalityColumns,
    mid.included_columns                             AS IncludedColumns,
    migs.user_seeks                                  AS UserSeeks,
    migs.user_scans                                  AS UserScans,
    migs.last_user_seek                              AS LastUserSeek,
    migs.avg_total_user_cost                         AS AvgUserCost,
    migs.avg_user_impact                             AS AvgUserImpact,
    -- Impact-Score nach Microsoft-Empfehlung
    ROUND(
        (migs.user_seeks + migs.user_scans)
        * migs.avg_total_user_cost
        * (migs.avg_user_impact / 100.0),
        2
    )                                                AS ImpactScore,
    mid.object_id                                    AS ObjectId,
    mid.database_id                                  AS DatabaseId,
    mid.index_handle                                 AS IndexHandle
FROM sys.dm_db_missing_index_details   mid
INNER JOIN sys.dm_db_missing_index_groups      mig  ON mid.index_group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_group_stats migs ON mig.index_group_handle = migs.group_handle
WHERE DB_NAME(mid.database_id) NOT IN ('master','model','msdb','tempdb')
  AND (migs.user_seeks + migs.user_scans) >= $MinSeeks
  AND ROUND(
        (migs.user_seeks + migs.user_scans)
        * migs.avg_total_user_cost
        * (migs.avg_user_impact / 100.0), 2
      ) >= $MinImpactScore
ORDER BY ImpactScore DESC
"@
			
			$rawData = Invoke-DbaQuery @connParams -Query $query -ErrorAction Stop
			
			$results = [System.Collections.Generic.List[PSCustomObject]]::new()
			
			foreach ($row in $rawData)
			{
				# Datenbank-Filter anwenden (PS-seitig, da DMV-Abfrage DB_NAME liefert)
				if ($Database.Count -gt 0)
				{
					$match = $false
					foreach ($pattern in $Database)
					{
						if ($row.DatabaseName -like $pattern) { $match = $true; break }
					}
					if (-not $match) { continue }
				}
				
				# CREATE INDEX-Statement generieren
				$createStmt = Build-sqmCreateIndexStatement `
															-DatabaseName $row.DatabaseName `
															-SchemaName $row.SchemaName `
															-TableName $row.TableName `
															-EqualityCols $row.EqualityColumns `
															-InequalityCols $row.InequalityColumns `
															-IncludedCols $row.IncludedColumns
				
				$results.Add([PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = $row.DatabaseName
						SchemaName   = $row.SchemaName
						TableName    = $row.TableName
						EqualityColumns = $row.EqualityColumns
						InequalityColumns = $row.InequalityColumns
						IncludedColumns = $row.IncludedColumns
						ImpactScore  = $row.ImpactScore
						UserSeeks    = $row.UserSeeks
						UserScans    = $row.UserScans
						LastUserSeek = $row.LastUserSeek
						AvgUserCost  = [math]::Round($row.AvgUserCost, 4)
						AvgUserImpact = [math]::Round($row.AvgUserImpact, 2)
						CreateIndexStatement = $createStmt
					})
			}
			
			# Optional: CSV-Ausgabe
			if ($OutputPath -and $results.Count -gt 0)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				
				$safeInst = $SqlInstance -replace '\\', '_'
				$stamp = Get-Date -Format 'yyyyMMdd_HHmsqm'
				$csvFile = Join-Path $OutputPath ("MissingIndexes_" + $safeInst + "_" + $stamp + ".csv")
				
				$results | Select-Object SqlInstance, DatabaseName, SchemaName, TableName,
										 ImpactScore, UserSeeks, UserScans, LastUserSeek,
										 EqualityColumns, InequalityColumns, IncludedColumns,
										 CreateIndexStatement |
				Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				
				Copy-sqmToCentralPath -Path @($csvFile)
				Invoke-sqmLogging -Message ("CSV gespeichert: " + $csvFile) -FunctionName $functionName -Level "INFO"
			}
			
			$msg = $results.Count.ToString() + " fehlende Index-Empfehlung(en) gefunden (MinImpact=" + $MinImpactScore + ", MinSeeks=" + $MinSeeks + ")."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
			
			return $results
		}
		catch
		{
			$errMsg = "Fehler beim Abrufen fehlender Indizes: " + $_.Exception.Message
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

# ---------------------------------------------------------------------------
# Private Hilfsfunktion: CREATE INDEX-Statement generieren
# ---------------------------------------------------------------------------
function Build-sqmCreateIndexStatement
{
	param (
		[string]$DatabaseName,
		[string]$SchemaName,
		[string]$TableName,
		[string]$EqualityCols,
		[string]$InequalityCols,
		[string]$IncludedCols
	)
	
	# Alle Key-Spalten zusammenfuehren (Equality zuerst, dann Inequality)
	$keyCols = @()
	if ($EqualityCols) { $keyCols += $EqualityCols -split ',' | ForEach-Object { $_.Trim() } }
	if ($InequalityCols) { $keyCols += $InequalityCols -split ',' | ForEach-Object { $_.Trim() } }
	
	# Indexname aus Spaltenkuerzeln bauen (max. 128 Zeichen)
	$colShort = ($keyCols | ForEach-Object {
			($_ -replace '[\[\]\s]', '') -replace '^(.{1,8}).*$', '$1'
		}) -join '_'
	$stamp = Get-Date -Format 'yyyyMMdd'
	$idxName = "IX_" + $TableName + "_" + $colShort + "_" + $stamp
	if ($idxName.Length -gt 128) { $idxName = $idxName.Substring(0, 128) }
	
	$keyColStr = ($keyCols | ForEach-Object { $_ }) -join ", "
	$includeClause = ""
	if ($IncludedCols)
	{
		$includeCleaned = ($IncludedCols -split ',' | ForEach-Object { $_.Trim() }) -join ", "
		$includeClause = "`r`nINCLUDE (" + $includeCleaned + ")"
	}
	
	$stmt = "USE [" + $DatabaseName + "];" + "`r`n"
	$stmt += "CREATE NONCLUSTERED INDEX [" + $idxName + "]" + "`r`n"
	$stmt += "ON [" + $SchemaName + "].[" + $TableName + "] (" + $keyColStr + ")"
	$stmt += $includeClause + ";"
	
	return $stmt
}