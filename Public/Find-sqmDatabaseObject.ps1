<#
.SYNOPSIS
    Searches all (or selected) databases on an instance for an object name.

.DESCRIPTION
    Searches user databases for tables, views, procedures, functions, triggers, synonyms.
    Returns the location (database, schema, object type, name). Can filter by SQL text (full definition).

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER ObjectName
    Name of the object to search for, or wildcard (e.g. '*customer*').

.PARAMETER ObjectType
    Restrict to type: 'TABLE', 'VIEW', 'PROCEDURE', 'FUNCTION', 'TRIGGER', 'SYNONYM'.
    Multiple values possible as array.

.PARAMETER Database
    Databases to search (wildcard, default: all user databases).

.PARAMETER IncludeSystem
    Include system databases. Default: $false.

.PARAMETER SearchDefinition
    If $true, the object text (definition) is also searched for <ObjectName> (slower).

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "sp_GetOrders"

.EXAMPLE
    Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "*log*" -ObjectType "TABLE","VIEW" -Database "Sales*"

.NOTES
    Uses sys.objects and sys.sql_modules (for definition).
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