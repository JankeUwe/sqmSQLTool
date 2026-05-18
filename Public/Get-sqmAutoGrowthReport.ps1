<#
.SYNOPSIS
    Creates an AutoGrowth configuration report for all database files on a SQL Server instance.

.DESCRIPTION
    Analyzes all data and log files of the accessible databases and evaluates their AutoGrowth settings.
    Returns warnings for percent-based growth, growth values that are too small or too large, and
    unbounded log files.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Restrict to specific databases (array of names).

.PARAMETER IncludeSystem
    Include system databases. Default: $false.

.PARAMETER Detailed
    When set, additional file properties (physical path) are included in the output.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmAutoGrowthReport -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmAutoGrowthReport -SqlInstance "SQL01" -Detailed -IncludeSystem

.NOTES
    Requires: dbatools, Invoke-sqmLogging
#>
function Get-sqmAutoGrowthReport
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystem,
		[Parameter(Mandatory = $false)]
		[switch]$Detailed,
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
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
		$results = @()
	}
	
	process
	{
		try
		{
			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
			
			$dbParams = @{
				SqlInstance = $server
				ErrorAction = 'Stop'
			}
			if (-not $IncludeSystem) { $dbParams.ExcludeSystem = $true }
			if ($Database) { $dbParams.Database = $Database }
			
			$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
			
			if (-not $databases)
			{
				$msg = "Keine Datenbanken gefunden (oder keine zugaenglich)."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				return
			}
			
			foreach ($db in $databases)
			{
				$dbName = $db.Name
				foreach ($fileGroup in $db.FileGroups)
				{
					foreach ($file in $fileGroup.Files)
					{
						$growthType = if ($file.GrowthType -eq 'KB') { 'MB' }
						else { 'Percent' }
						$growthValue = if ($growthType -eq 'MB') { $file.Growth / 1024 }
						else { $file.Growth }
						$currentSizeMB = [math]::Round($file.Size / 1024, 2)
						$maxSizeMB = if ($file.MaxSize -eq -1) { -1 }
						else { [math]::Round($file.MaxSize / 1024, 2) }
						
						# Bewertung
						$assessment = @()
						$status = "OK"
						if ($growthType -eq 'Percent')
						{
							$assessment += "Prozent-Wachstum (besser in MB)"
							$status = "Warning"
						}
						if ($growthType -eq 'MB')
						{
							if ($growthValue -lt 64)
							{
								$assessment += "Wachstum zu klein ($growthValue MB) - kann zu vielen Autogrow-Events fuehren"
								$status = "Warning"
							}
							elseif ($growthValue -gt 1024)
							{
								$assessment += "Wachstum sehr gross ($growthValue MB) - kann zu langen Wartezeiten fuehren"
								if ($status -ne "Warning") { $status = "Info" }
							}
						}
						if ($file.Type -eq 'Log' -and $maxSizeMB -eq -1)
						{
							$assessment += "Log-Datei unbegrenzt - kann zu vollem Laufwerk fuehren"
							$status = "Warning"
						}
						$message = if ($assessment) { $assessment -join "; " }
						else { "OK - Best Practice" }
						
						# Objekt dynamisch erstellen je nach Detailed
						if ($Detailed)
						{
							$result = [PSCustomObject]@{
								Server	     = $SqlInstance
								DatabaseName = $dbName
								FileType	 = if ($file.Type -eq 'Rows') { 'Data' } else { 'Log' }
								FileName	 = $file.Name
								PhysicalName = $file.FileName
								GrowthType   = $growthType
								GrowthValue  = $growthValue
								CurrentSizeMB = $currentSizeMB
								MaxSizeMB    = if ($maxSizeMB -eq -1) { 'Unlimited' } else { $maxSizeMB }
								Status	     = $status
								Assessment   = $message
							}
						}
						else
						{
							$result = [PSCustomObject]@{
								Server	     = $SqlInstance
								DatabaseName = $dbName
								FileType	 = if ($file.Type -eq 'Rows') { 'Data' } else { 'Log' }
								FileName	 = $file.Name
								GrowthType   = $growthType
								GrowthValue  = $growthValue
								CurrentSizeMB = $currentSizeMB
								MaxSizeMB    = if ($maxSizeMB -eq -1) { 'Unlimited' } else { $maxSizeMB }
								Status	     = $status
								Assessment   = $message
							}
						}
						$results += $result
					}
				}
			}
		}
		catch
		{
			$errMsg = "Fehler beim Erstellen des Berichts: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Dateien analysiert." -FunctionName $functionName -Level "INFO"
		return $results
	}
}