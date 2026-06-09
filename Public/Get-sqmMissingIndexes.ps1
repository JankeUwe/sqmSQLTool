<#
.SYNOPSIS
    Retrieves missing index recommendations from the SQL Server DMV cache.

.DESCRIPTION
    Reads sys.dm_db_missing_index_details, sys.dm_db_missing_index_groups and
    sys.dm_db_missing_index_group_stats and calculates an impact score
    (using the Microsoft formula) and a ready-to-use CREATE INDEX statement per missing index.

    Per recommendation the following is returned:
      - Database, schema, table
      - Equality and inequality columns, include columns
      - Impact score (0-100, calculated from seeks/scans/lookups * avg_user_cost * avg_user_impact)
      - Number of seeks, scans, lookups since last SQL Server restart
      - Last seek timestamp
      - Ready-to-use CREATE INDEX statement with suggested index name

    IMPORTANT: DMV data is volatile (reset on SQL Server restart, failover,
    and certain plan cache events). Always review recommendations with the DBA
    before creating indexes - especially on heavily loaded systems.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Filter by database name(s). Wildcards allowed. Default: all user databases.

.PARAMETER MinImpactScore
    Return only recommendations with impact score >= this value. Default: 10.

.PARAMETER MinSeeks
    Return only recommendations with at least this number of seeks/scans. Default: 50.

.PARAMETER Top
    Return at most this number of recommendations (sorted by impact score). Default: 50.

.PARAMETER OutputPath
    If specified, a CSV file with the recommendations and CREATE statements
    is written to this directory.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmMissingIndexes -SqlInstance "SQL01"

.EXAMPLE
    # Only high-impact recommendations
    Get-sqmMissingIndexes -SqlInstance "SQL01" -MinImpactScore 50 -MinSeeks 500

.EXAMPLE
    # Show top 10 and save as CSV
    Get-sqmMissingIndexes -SqlInstance "SQL01" -Top 10 -OutputPath "D:\Reports"

.EXAMPLE
    # Output CREATE INDEX statements directly
    Get-sqmMissingIndexes -SqlInstance "SQL01" -MinImpactScore 30 |
        Select-Object DatabaseName, TableName, ImpactScore, CreateIndexStatement |
        Format-List

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE on the instance.
    DMV data is reset on SQL Server restart or failover.
    Suggested index names contain date and column abbreviations - review naming conventions
    and adjust as needed before deployment.
    Impact score formula: seeks * avg_cost * avg_impact + scans * avg_cost * avg_impact
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
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
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
				$createStmt = New-sqmCreateIndexStatement `
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

				$htmlFile = Join-Path $OutputPath ("MissingIndexes_" + $safeInst + "_" + $stamp + ".html")
				$bodyHtml = ($results | Select-Object SqlInstance, DatabaseName, SchemaName, TableName,
											 ImpactScore, UserSeeks, UserScans, LastUserSeek,
											 EqualityColumns, InequalityColumns, IncludedColumns |
							 ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "Missing Indexes - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
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
function New-sqmCreateIndexStatement
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

# Backward compatibility: old name "Build-sqmCreateIndexStatement" -> new name "New-sqmCreateIndexStatement"
Set-Alias -Name 'Build-sqmCreateIndexStatement' -Value 'New-sqmCreateIndexStatement' -Force