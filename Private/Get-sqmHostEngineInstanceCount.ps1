<#
.SYNOPSIS
    Counts the SQL Server Database Engine instances installed on a host.

.DESCRIPTION
    Test-sqmMaxMemory/Set-sqmMaxMemory recommend "max server memory" as a percentage of the
    host's TOTAL physical RAM - correct for a single instance, but on a host running several
    Engine instances side by side, applying that same percentage to EACH instance massively
    over-commits RAM (e.g. two instances both configured for 90% of RAM = 180% total). This
    helper finds how many Engine instances actually share the box, so the RAM budget can be
    split between them instead.

    Tries dbatools' Get-DbaService first (works for local and remote hosts via CIM/WinRM).
    Falls back to a local Get-Service scan (MSSQLSERVER / MSSQL$<name>) when the target is the
    local machine and Get-DbaService is unavailable or fails (e.g. WinRM blocked on a locked-
    down production host). Filters strictly to Engine services - SQL Server Agent
    (SQLAgent$.../SQLSERVERAGENT) and Analysis Services (MSOLAP$...) use different name
    patterns and are not counted.

.PARAMETER SqlInstance
    SQL Server instance (SERVER or SERVER\INSTANCE). Only the host part is used.

.OUTPUTS
    [int] Number of Engine instances found. Returns 1 if detection fails entirely, so callers
    fall back to today's single-instance behaviour rather than an unproven assumption.
#>
function Get-sqmHostEngineInstanceCount
{
	[CmdletBinding()]
	[OutputType([int])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance
	)

	$computerName = (($SqlInstance -split '\\')[0] -split ',')[0]
	$isLocalHost = $computerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.', [System.Net.Dns]::GetHostName())

	try
	{
		$svc = Get-DbaService -ComputerName $computerName -Type Engine -ErrorAction Stop
		$count = @($svc | Select-Object -ExpandProperty InstanceName -Unique).Count
		if ($count -gt 0) { return $count }
	}
	catch { }

	if ($isLocalHost)
	{
		$local = @(Get-Service -Name 'MSSQLSERVER', 'MSSQL$*' -ErrorAction SilentlyContinue)
		if ($local.Count -gt 0) { return $local.Count }
	}

	return 1
}
