<#
.SYNOPSIS
    Creates an AutoGrowth configuration report for all database files on a SQL Server instance.

.DESCRIPTION
    Analyzes all data and log files of the accessible databases and evaluates their AutoGrowth settings.
    Returns warnings for percent-based growth, growth values that are too small or too large, and
    unbounded log files.

    Results are additionally saved as TXT and HTML report in -OutputPath. The function still
    returns the flat array of per-file result objects (unchanged, so existing callers such as
    Get-sqmFileGrowthHistory keep working).

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

.PARAMETER OutputPath
    Output directory for the TXT/HTML report files. Default: 'AutoGrowthReports' subfolder
    under the configured default output path (see Get-sqmDefaultOutputPath).

.PARAMETER NoOpen
    Suppresses automatically opening the generated report (HTML has priority over TXT).

.PARAMETER NoReport
    Skips writing the TXT/HTML report files entirely (only the object array is returned).
    Used internally by functions such as Get-sqmFileGrowthHistory that consume this
    function purely as a data source and write their own report.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmAutoGrowthReport -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmAutoGrowthReport -SqlInstance "SQL01" -Detailed -IncludeSystem

.EXAMPLE
    Get-sqmAutoGrowthReport -SqlInstance "SQL01" -OutputPath "D:\Reports" -NoOpen

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Default output path: <Get-sqmDefaultOutputPath>\AutoGrowthReports
#>
function Get-sqmAutoGrowthReport
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
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
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'AutoGrowthReports'),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
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
		if ($results -and -not $NoReport -and $PSCmdlet.ShouldProcess($SqlInstance, "Erstelle AutoGrowth-Bericht in $OutputPath"))
		{
			try
			{
				if (-not (Test-Path $OutputPath))
				{
					New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
					Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
				}

				$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$txtFile = Join-Path $OutputPath "AutoGrowthReport_${safeInst}_${datestamp}.txt"
				$htmlFile = Join-Path $OutputPath "AutoGrowthReport_${safeInst}_${datestamp}.html"

				$cntWarn = ($results | Where-Object Status -eq 'Warning').Count
				$cntInfo = ($results | Where-Object Status -eq 'Info').Count
				$sorted = $results | Sort-Object @{ Expression = { switch ($_.Status) { 'Warning' { 0 } 'Info' { 1 } default { 2 } } } }, DatabaseName, FileName

				# TXT-Bericht
				$reference = Get-sqmReportReference
				$lines = [System.Collections.Generic.List[string]]::new()
				$lines.Add("# ================================================================")
				$lines.Add("# sqmSQLTool - AutoGrowth Report")
				$lines.Add("# $reference")
				$lines.Add("# Instanz   : $SqlInstance")
				$lines.Add("# Erstellt  : $timestamp")
				$lines.Add("# Warning: $cntWarn | Info: $cntInfo | Dateien gesamt: $($results.Count)")
				$lines.Add("# ================================================================")
				$lines.Add("")
				$lines.Add(("{0,-8} {1,-25} {2,-6} {3,-30} {4,-8} {5,-10} {6,-10} {7,-10} {8}" -f
						'Status', 'Datenbank', 'Typ', 'Datei', 'Growth', 'Wert', 'AktGroesseMB', 'MaxMB', 'Bewertung'))
				$lines.Add(("-" * 130))
				foreach ($e in $sorted)
				{
					$lines.Add(("{0,-8} {1,-25} {2,-6} {3,-30} {4,-8} {5,-10} {6,-10} {7,-10} {8}" -f
							$e.Status, $e.DatabaseName, $e.FileType, $e.FileName, $e.GrowthType, $e.GrowthValue, $e.CurrentSizeMB, $e.MaxSizeMB, $e.Assessment))
				}
				$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

				# HTML-Bericht (farbcodiert nach Status)
				$rowsHtml = ''
				foreach ($e in $sorted)
				{
					$cls = switch ($e.Status) { 'Warning' { 'warn' } 'Info' { 'warn' } default { 'ok' } }
					$dbEnc = [string]$e.DatabaseName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
					$fileEnc = [string]$e.FileName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
					$assessEnc = [string]$e.Assessment -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
					$rowsHtml += "<tr><td class='$cls'>$($e.Status)</td><td>$dbEnc</td><td>$($e.FileType)</td><td>$fileEnc</td><td>$($e.GrowthType)</td><td>$($e.GrowthValue)</td><td>$($e.CurrentSizeMB)</td><td>$($e.MaxSizeMB)</td><td>$assessEnc</td></tr>`n"
				}
				$bodyHtml = @"
<table>
<thead><tr><th>Status</th><th>Datenbank</th><th>Typ</th><th>Datei</th><th>Growth</th><th>Wert</th><th>Akt. Groesse MB</th><th>Max MB</th><th>Bewertung</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<p style="color:#94a8c0;font-size:12px;">Warning: $cntWarn &nbsp;|&nbsp; Info: $cntInfo &nbsp;|&nbsp; Dateien gesamt: $($results.Count)</p>
"@
				$html = ConvertTo-sqmHtmlReport -Title "AutoGrowth Report - $SqlInstance" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

				Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

				Invoke-sqmLogging -Message "AutoGrowth-Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "Berichtsdateien konnten nicht erstellt werden: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARNING"
				if ($EnableException) { throw }
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Dateien analysiert." -FunctionName $functionName -Level "INFO"
		return $results
	}
}