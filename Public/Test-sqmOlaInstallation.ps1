<#
.SYNOPSIS
    Checks whether Ola Hallengren's Maintenance Solution is installed on a SQL Server instance.

.DESCRIPTION
    Tests for the presence of the stored procedure 'DatabaseBackup' in the 'master' schema.
    Optionally checks whether the 'CommandLog' table and 'DatabaseIntegrityCheck' etc. are also present.

.PARAMETER SqlInstance
    SQL Server instance.

.PARAMETER SqlCredential
    Credentials.

.PARAMETER RequiredSet
    Which components are required at minimum: 'Backup', 'Integrity', 'Index' (Default: 'Backup').

.OUTPUTS
    [PSCustomObject] with IsInstalled, AgentRunning, PresentObjects, Warnings, Message.
#>
function Test-sqmOlaInstallation
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Backup', 'Integrity', 'Index')]
		[string]$RequiredSet = 'Backup'
	)
	$functionName = $MyInvocation.MyCommand.Name
	$result = [PSCustomObject]@{
		IsInstalled    = $false
		AgentRunning   = $false
		PresentObjects = @()
		Warnings	   = @()
		Message	       = $null
	}
	try
	{
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams.SqlCredential = $SqlCredential }
		$server = Connect-DbaInstance @connParams -ErrorAction Stop
		# SQL Agent Status
		$agent = $server.JobServer
		$result.AgentRunning = ($agent -ne $null -and $agent.ServiceStatus -eq 'Running')
		# Pruefen auf Ola-Prozedur
		$query = "SELECT COUNT(*) AS cnt FROM master.sys.objects WHERE name = 'DatabaseBackup' AND type = 'P'"
		$cnt = (Invoke-DbaQuery @connParams -Query $query -ErrorAction Stop).cnt
		if ($cnt -gt 0)
		{
			$result.IsInstalled = $true
			$result.PresentObjects += 'DatabaseBackup'
		}
		# Zusaetzliche Pruefungen (optional)
		if ($RequiredSet -in 'Integrity', 'Index')
		{
			$query = "SELECT COUNT(*) AS cnt FROM master.sys.objects WHERE name = 'DatabaseIntegrityCheck' AND type = 'P'"
			if ((Invoke-DbaQuery @connParams -Query $query).cnt -gt 0) { $result.PresentObjects += 'DatabaseIntegrityCheck' }
		}
		if ($RequiredSet -eq 'Index')
		{
			$query = "SELECT COUNT(*) AS cnt FROM master.sys.objects WHERE name = 'IndexOptimize' AND type = 'P'"
			if ((Invoke-DbaQuery @connParams -Query $query).cnt -gt 0) { $result.PresentObjects += 'IndexOptimize' }
		}
		# Pruefen auf CommandLog Tabelle (wenn vorhanden)
		$query = "SELECT COUNT(*) AS cnt FROM master.sys.tables WHERE name = 'CommandLog'"
		if ((Invoke-DbaQuery @connParams -Query $query).cnt -eq 0)
		{
			$result.Warnings += "Tabelle 'CommandLog' nicht in master - Ola-Logging funktioniert nicht (LogToTable=N)."
		}
		if (-not $result.IsInstalled)
		{
			$result.Message = "Ola Hallengren Maintenance Solution nicht gefunden (keine Prozedur 'DatabaseBackup')."
		}
	}
	catch
	{
		$result.Message = "Fehler bei Pruefung: $($_.Exception.Message)"
		Write-Error $result.Message
	}
	return $result
}