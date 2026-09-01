<#
.SYNOPSIS
    Lists the collations a SQL Server instance actually supports.

.DESCRIPTION
    Queries sys.fn_helpcollations() on the target instance and returns the collation names
    (optionally filtered by a wildcard pattern). The set of valid collations depends on the SQL
    Server version/edition, so this is deliberately queried live from the instance rather than
    hard-coded - a static list would go stale and could offer collations the target does not
    actually support (or miss newer ones).

    Primarily used to discover/validate a value for -NewCollation of Invoke-sqmCollationChange,
    and to feed the collation picker in Show-sqmToolGui.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Filter
    Wildcard pattern to restrict the result (e.g. 'Latin1_General*', '*_CI_AS'). Default: '*'.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmSupportedCollations -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmSupportedCollations -SqlInstance "SQL01" -Filter "German*"

.NOTES
    Requires: dbatools
#>
function Get-sqmSupportedCollations
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$Filter = '*',
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
	{
		$SqlInstance = $env:COMPUTERNAME
	}
	if (-not (Get-Module -ListAvailable -Name dbatools))
	{
		$errMsg = "dbatools-Modul nicht gefunden."
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		throw $errMsg
	}

	try
	{
		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$rows = Invoke-DbaQuery @connParams -Query "SELECT name, description FROM sys.fn_helpcollations() ORDER BY name" -EnableException

		$filtered = $rows | Where-Object { $_.name -like $Filter }

		return $filtered | ForEach-Object {
			[PSCustomObject]@{
				SqlInstance = $SqlInstance
				Name	    = $_.name
				Description = $_.description
			}
		}
	}
	catch
	{
		$errMsg = "Collations konnten nicht ermittelt werden: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw }
		Write-Error $errMsg
	}
}
