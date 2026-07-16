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
    Optional directory for reports (CSV + HTML). File names are generated.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmTempDbRecommendation -SqlInstance "SQL01"

.EXAMPLE
    # CSV + HTML report
    Get-sqmTempDbRecommendation -SqlInstance "SQL01" -OutputPath "D:\Reports\TempDb"
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
		[switch]$NoOpen,
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
			
			if ($OutputPath)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'
				$ts	      = Get-Date -Format 'yyyyMMdd_HHmmss'

				# Arrays fuer die Dateiausgabe flach machen (sonst "System.Object[]").
				$flat = $result | Select-Object SqlInstance, Status, FileCount, RecommendedCount,
					@{ n = 'FileSizesMB'; e = { $_.FileSizesMB -join ', ' } },
					@{ n = 'GrowthMB'; e = { $_.GrowthMB -join ', ' } },
					@{ n = 'Paths'; e = { ($_.Paths | Select-Object -Unique) -join ', ' } },
					Recommendations

				$csvFile = Join-Path $OutputPath "TempDbRecommendation_${safeInst}_${ts}.csv"
				$flat | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "CSV exportiert nach $csvFile" -FunctionName $functionName -Level "INFO"

				$htmlFile = Join-Path $OutputPath "TempDbRecommendation_${safeInst}_${ts}.html"
				$bodyHtml = ($flat | ConvertTo-Html -Fragment -As List | Out-String)
				ConvertTo-sqmHtmlReport -Title "TempDB Recommendation - $SqlInstance" -Subtitle "Status: $status  |  $fileCount von $idealFileCount empfohlenen Dateien" -BodyHtml $bodyHtml |
				Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmLogging -Message "HTML-Report gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}
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