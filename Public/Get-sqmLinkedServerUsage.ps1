<#
.SYNOPSIS
    Analyzes which database objects (procedures, functions, views, triggers, SQL Agent jobs) access linked servers.

.DESCRIPTION
    Searches the definitions of all user databases for references to linked servers.
    Shows the referenced linked server, the object and the database. Optionally includes dependent jobs.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER LinkedServer
    Name of the linked server (or wildcard). Default: all.

.PARAMETER IncludeJobs
    Also checks SQL Agent job steps for T-SQL using the linked server.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmLinkedServerUsage -SqlInstance "SQL01" -LinkedServer "PROD_SRV"

.NOTES
    Searches sys.sql_modules and sys.syscomments using LIKE '%LinkedServer%'.
#>
function Get-sqmLinkedServerUsage
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$LinkedServer = '*',
		[Parameter(Mandatory = $false)]
		[switch]$IncludeJobs,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		$likePattern = $LinkedServer -replace '\*', '%'
	}
	
	process
	{
		try
		{
			$dbList = Get-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ExcludeSystem -ErrorAction Stop
			$query = @"
SELECT DISTINCT
    DB_NAME() AS DatabaseName,
    SCHEMA_NAME(o.schema_id) AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType,
    m.definition
FROM sys.sql_modules m
JOIN sys.objects o ON m.object_id = o.object_id
WHERE m.definition LIKE '%$likePattern%'
"@
			foreach ($db in $dbList)
			{
				try
				{
					$rows = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $db.Name -Query $query -ErrorAction Stop
					foreach ($row in $rows)
					{
						$results.Add([PSCustomObject]@{
								SqlInstance = $SqlInstance
								Database    = $row.DatabaseName
								Schema	    = $row.SchemaName
								ObjectName  = $row.ObjectName
								ObjectType  = $row.ObjectType
								LinkedServer = $LinkedServer
							})
					}
				}
				catch { if ($EnableException) { throw } }
			}
			if ($IncludeJobs)
			{
				$jobs = Get-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
				$jobStepQuery = "SELECT job_id, step_name, command FROM msdb.dbo.sysjobsteps WHERE command LIKE '%$likePattern%'"
				$jobSteps = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database msdb -Query $jobStepQuery -ErrorAction Stop
				$jobMap = @{ }
				$jobs | ForEach-Object { $jobMap[$_.Id] = $_.Name }
				foreach ($step in $jobSteps)
				{
					$results.Add([PSCustomObject]@{
							SqlInstance = $SqlInstance
							Database    = "msdb"
							Schema	    = "dbo"
							ObjectName  = $jobMap[$step.job_id]
							ObjectType  = "JOBSTEP"
							LinkedServer = $LinkedServer
						})
				}
			}
			return $results
		}
		catch
		{
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return $null
		}
	}
}