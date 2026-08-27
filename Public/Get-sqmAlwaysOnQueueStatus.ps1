<#
.SYNOPSIS
    Returns the current redo queue / send queue status for all Always On availability groups
    on an instance - no files written.

.DESCRIPTION
    Lightweight counterpart to Get-sqmAlwaysOnHealthReport: same underlying DMV query and
    threshold scoring (via the shared private helper Get-sqmAlwaysOnQueueSnapshot), but returns
    the row objects directly instead of writing TXT/CSV/HTML report files. Intended for callers
    that poll on a schedule (e.g. a central-poller collector) where writing report files on every
    run would just accumulate disk clutter.

    Returns one row per replica/database with RedoQueueMB, SendQueueMB and an OverallStatus
    (OK/Warning/Critical). An instance without any availability groups returns an empty array,
    not an error.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER MaxRedoQueueMB
    Warning threshold for the redo queue in MB. Default: 100.

.PARAMETER MaxSendQueueMB
    Warning threshold for the send queue in MB. Default: 50.

.PARAMETER EnableException
    Throw exceptions immediately (otherwise dbatools connection issues surface as warnings).

.EXAMPLE
    Get-sqmAlwaysOnQueueStatus

.EXAMPLE
    Get-sqmAlwaysOnQueueStatus -SqlInstance "SQL01" -MaxRedoQueueMB 200 | Where-Object OverallStatus -ne 'OK'

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools, Invoke-sqmLogging
    Requires VIEW SERVER STATE on the target instance.
#>
function Get-sqmAlwaysOnQueueStatus
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$MaxRedoQueueMB = 100,
		[Parameter(Mandatory = $false)]
		[int]$MaxSendQueueMB = 50,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			try
			{
				Get-sqmAlwaysOnQueueSnapshot -SqlInstance $instance -SqlCredential $SqlCredential `
					-MaxRedoQueueMB $MaxRedoQueueMB -MaxSendQueueMB $MaxSendQueueMB -EnableException:$EnableException
			}
			catch
			{
				$errMsg = "[$instance] Fehler beim Lesen des AlwaysOn-Queue-Status: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				Write-Error $errMsg
			}
		}
	}
}
