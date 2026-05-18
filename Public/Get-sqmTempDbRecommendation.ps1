<#
.SYNOPSIS
    Analyzes the TempDB configuration and provides optimization recommendations.

.DESCRIPTION
    Checks the number and size of TempDB files, autogrow settings and the path.
    Recommends file count (matching CPU core count, max 8), equal sizes, MB-based autogrow,
    and separate drives where possible.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER OutputPath
    Optional CSV export path.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmTempDbRecommendation -SqlInstance "SQL01"
#>
function Get-sqmTempDbRecommendation
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
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
	}
	
	process
	{
		try
		{
			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
			$tempdb = $server.Databases['tempdb']
			$cpuCount = $server.Processors
			$idealFileCount = [Math]::Min($cpuCount, 8)
			
			$files = $tempdb.FileGroups[0].Files
			$fileCount = $files.Count
			$fileSizeMB = $files | ForEach-Object { [math]::Round($_.Size / 1024, 2) }
			$fileGrowth = $files.ForEach('Growth') | ForEach-Object { ($_ / 1024) } # in MB
			$growthTypes = $files.ForEach('GrowthType')
			$paths = $files.ForEach('FileName') | ForEach-Object { Split-Path $_ -Parent }
			
			# Bewertung
			$status = 'OK'
			$messages = [System.Collections.Generic.List[string]]::new()
			if ($fileCount -ne $idealFileCount)
			{
				$status = 'Warning'
				$messages.Add("Anzahl TempDB-Dateien: $fileCount (empfohlen $idealFileCount).")
			}
			$sizeDifferences = ($fileSizeMB | Select-Object -Unique).Count -gt 1
			if ($sizeDifferences)
			{
				$status = 'Warning'
				$messages.Add("TempDB-Dateien haben unterschiedliche Groessen: $($fileSizeMB -join ', ') MB.")
			}
			$hasPercent = $growthTypes -contains 'Percent'
			if ($hasPercent)
			{
				$status = 'Warning'
				$messages.Add("Autogrow in Prozent wird verwendet (MB empfohlen).")
			}
			$hasLargeGrow = $fileGrowth -gt 1024
			if ($hasLargeGrow)
			{
				$status = 'Warning'
				$messages.Add("Autogrow-Schrittweite >1024 MB: $($fileGrowth -join ', ') MB.")
			}
			$uniquePaths = $paths | Select-Object -Unique
			if ($uniquePaths.Count -eq 1)
			{
				$messages.Add("Alle TempDB-Dateien liegen auf demselben Laufwerk ($($uniquePaths[0])) - fuer optimale Leistung separate Laufwerke empfehlenswert.")
				if ($status -eq 'OK') { $status = 'Info' }
			}
			if ($messages.Count -eq 0) { $messages.Add("TempDB-Konfiguration ist optimal.") }
			
			$result = [PSCustomObject]@{
				SqlInstance	     = $SqlInstance
				Status		     = $status
				FileCount	     = $fileCount
				RecommendedCount = $idealFileCount
				FileSizesMB	     = $fileSizeMB
				GrowthMB		 = $fileGrowth
				Paths		     = $paths
				Recommendations  = ($messages -join ' ')
			}
			
			if ($OutputPath) { $result | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Force }
			return $result
		}
		catch
		{
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return $null
		}
	}
}