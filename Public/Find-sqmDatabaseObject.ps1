<#
.SYNOPSIS
    Durchsucht alle (oder ausgewaehlte) Datenbanken einer Instanz nach einem Objektnamen.

.DESCRIPTION
    Sucht in Benutzerdatenbanken nach Tabellen, Sichten, Prozeduren, Funktionen, Triggern, Synonymen.
    Liefert Fundort (Datenbank, Schema, Objekttyp, Name). Kann nach SQL-Text (vollstaendige Definition) filtern.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER ObjectName
    Name des gesuchten Objekts oder Wildcard (z.B. '*customer*').

.PARAMETER ObjectType
    Einschraenkung auf Typ: 'TABLE', 'VIEW', 'PROCEDURE', 'FUNCTION', 'TRIGGER', 'SYNONYM'.
    Mehrfach moeglich als Array.

.PARAMETER Database
    Datenbanken durchsuchen (Wildcard, Standard: alle Benutzerdatenbanken).

.PARAMETER IncludeSystem
    Systemdatenbanken einbeziehen. Standard: $false.

.PARAMETER SearchDefinition
    Wenn $true, wird auch der Objekttext (Definition) nach <ObjectName> durchsucht (langsamer).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "sp_GetOrders"

.EXAMPLE
    Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "*log*" -ObjectType "TABLE","VIEW" -Database "Sales*"

.NOTES
    Verwendet sys.objects und sys.sql_modules (fuer Definition).
#>
function Find-sqmDatabaseObject
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$ObjectName,
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$ObjectType,
		[Parameter(Mandatory = $false)]
		[string]$Database = '*',
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystem,
		[Parameter(Mandatory = $false)]
		[switch]$SearchDefinition,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	}

	process
	{
		try
		{
			# Get-DbaDatabase unterstuetzt keine Wildcards im -Database-Parameter.
			# Daher: alle Datenbanken laden und anschliessend per -like filtern.
			$allDbs = Get-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
			                          -ExcludeSystem:(-not $IncludeSystem) -ErrorAction Stop

			$dbList = if ($Database -eq '*')
			{
				$allDbs
			}
			else
			{
				$allDbs | Where-Object { $_.Name -like $Database }
			}

			if (-not $dbList)
			{
				Invoke-sqmLogging -Message "Keine Datenbanken auf '$SqlInstance' gefunden (Filter: '$Database')." `
				                  -FunctionName $functionName -Level "WARNING"
				return $allResults
			}
			$typeFilter = if ($ObjectType) { "AND type_desc IN ('$($ObjectType -join "','")')" }
			else { "" }
			$searchName = $ObjectName -replace "'", "''"
			if ($SearchDefinition)
			{
				$query = @"
SELECT 
    DB_NAME() AS DatabaseName,
    SCHEMA_NAME(schema_id) AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType,
    LEFT(m.definition, 500) AS DefinitionPreview
FROM sys.objects o
LEFT JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.name LIKE '$searchName' OR m.definition LIKE '%$searchName%'
$typeFilter
"@
			}
			else
			{
				$query = @"
SELECT 
    DB_NAME() AS DatabaseName,
    SCHEMA_NAME(schema_id) AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType,
    NULL AS DefinitionPreview
FROM sys.objects o
WHERE o.name LIKE '$searchName'
$typeFilter
"@
			}
			foreach ($db in $dbList)
			{
				try
				{
					$rows = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $db.Name -Query $query -ErrorAction Stop
					foreach ($row in $rows)
					{
						$allResults.Add([PSCustomObject]@{
								SqlInstance = $SqlInstance
								Database    = $row.DatabaseName
								Schema	    = $row.SchemaName
								ObjectName  = $row.ObjectName
								ObjectType  = $row.ObjectType
								DefinitionPreview = $row.DefinitionPreview
							})
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Fehler in DB $($db.Name): $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					if ($EnableException) { throw }
				}
			}
			return $allResults
		}
		catch
		{
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return $null
		}
	}
}