<#
.SYNOPSIS
    Checks all database collations against the server (instance) collation and reports mismatches.

.DESCRIPTION
    Compares each database's default collation to the SQL Server instance collation. tempdb always
    uses the instance collation and cannot be changed independently, so a database whose collation
    differs from the instance is flagged as a Warning: comparisons/joins between that database's
    char/varchar/nvarchar columns and tempdb objects (temp tables, table variables) or objects in
    another database with a different collation can fail with "Cannot resolve collation conflict",
    unless every query explicitly adds a COLLATE clause.

    Results are additionally saved as TXT and HTML report in -OutputPath. The function still
    returns the flat array of per-database result objects.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Restrict to specific databases (array of names).

.PARAMETER IncludeSystem
    Include system databases. Default: $false.

.PARAMETER OutputPath
    Output directory for the TXT/HTML report files. Default: 'CollationReports' subfolder
    under the configured default output path (see Get-sqmDefaultOutputPath).

.PARAMETER NoOpen
    Suppresses automatically opening the generated report (HTML has priority over TXT).

.PARAMETER NoReport
    Skips writing the TXT/HTML report files entirely (only the object array is returned).

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmDatabaseCollationReport -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmDatabaseCollationReport -SqlInstance "SQL01" -IncludeSystem -OutputPath "D:\Reports"

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Default output path: <Get-sqmDefaultOutputPath>\CollationReports
#>
function Get-sqmDatabaseCollationReport
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
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'CollationReports'),
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
			$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$server = Connect-DbaInstance @connParams
			$serverCollation = $server.Collation

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
				$dbCollation = $db.Collation
				$mismatch = $dbCollation -ne $serverCollation

				$status = if ($mismatch) { 'Warning' } else { 'OK' }
				$message = if ($mismatch)
				{
					"Datenbank-Collation weicht von der Instanz-Collation ab - Vergleiche/Joins gegen tempdb-Objekte (Temp-Tabellen, Tabellenvariablen) " +
					"oder gegen Datenbanken mit anderer Collation koennen mit 'Cannot resolve collation conflict' fehlschlagen, sofern nicht " +
					"jede betroffene Abfrage explizit COLLATE verwendet."
				}
				else { "OK - identisch mit Instanz-Collation" }

				$results += [PSCustomObject]@{
					SqlInstance      = $SqlInstance
					ServerCollation  = $serverCollation
					DatabaseName     = $db.Name
					DatabaseCollation = $dbCollation
					Mismatch	     = $mismatch
					Status		     = $status
					Assessment	     = $message
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
		if ($results -and -not $NoReport -and $PSCmdlet.ShouldProcess($SqlInstance, "Erstelle Collation-Bericht in $OutputPath"))
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
				$txtFile = Join-Path $OutputPath "CollationReport_${safeInst}_${datestamp}.txt"
				$htmlFile = Join-Path $OutputPath "CollationReport_${safeInst}_${datestamp}.html"

				$cntWarn = ($results | Where-Object Status -eq 'Warning').Count
				$serverCollation = $results[0].ServerCollation
				$sorted = $results | Sort-Object @{ Expression = { switch ($_.Status) { 'Warning' { 0 } default { 1 } } } }, DatabaseName

				# TXT-Bericht
				$reference = Get-sqmReportReference
				$lines = [System.Collections.Generic.List[string]]::new()
				$lines.Add("# ================================================================")
				$lines.Add("# sqmSQLTool - Database Collation Report")
				$lines.Add("# $reference")
				$lines.Add("# Instanz          : $SqlInstance")
				$lines.Add("# Instanz-Collation: $serverCollation")
				$lines.Add("# Erstellt         : $timestamp")
				$lines.Add("# Warning: $cntWarn | Datenbanken gesamt: $($results.Count)")
				$lines.Add("# ================================================================")
				$lines.Add("")
				$lines.Add(("{0,-8} {1,-30} {2,-35} {3}" -f 'Status', 'Datenbank', 'DB-Collation', 'Bewertung'))
				$lines.Add(("-" * 130))
				foreach ($e in $sorted)
				{
					$lines.Add(("{0,-8} {1,-30} {2,-35} {3}" -f $e.Status, $e.DatabaseName, $e.DatabaseCollation, $e.Assessment))
				}
				$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

				# HTML-Bericht (farbcodiert nach Status)
				$rowsHtml = ''
				foreach ($e in $sorted)
				{
					$cls = if ($e.Status -eq 'Warning') { 'warn' } else { 'ok' }
					$dbEnc = [string]$e.DatabaseName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
					$colEnc = [string]$e.DatabaseCollation -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
					$assessEnc = [string]$e.Assessment -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
					$rowsHtml += "<tr><td class='$cls'>$($e.Status)</td><td>$dbEnc</td><td>$colEnc</td><td>$assessEnc</td></tr>`n"
				}
				$serverCollEnc = [string]$serverCollation -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
				$bodyHtml = @"
<p>Instanz-Collation: <strong>$serverCollEnc</strong> (auch massgeblich fuer tempdb)</p>
<table>
<thead><tr><th>Status</th><th>Datenbank</th><th>DB-Collation</th><th>Bewertung</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<p style="color:#94a8c0;font-size:12px;">Warning: $cntWarn &nbsp;|&nbsp; Datenbanken gesamt: $($results.Count)</p>
"@
				$html = ConvertTo-sqmHtmlReport -Title "Database Collation Report - $SqlInstance" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

				Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

				Invoke-sqmLogging -Message "Collation-Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "Berichtsdateien konnten nicht erstellt werden: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "WARNING"
				if ($EnableException) { throw }
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Datenbanken geprueft." -FunctionName $functionName -Level "INFO"
		return $results
	}
}
