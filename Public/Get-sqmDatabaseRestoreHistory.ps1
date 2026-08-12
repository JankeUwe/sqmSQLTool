<#
.SYNOPSIS
    Lists the last restore date per database on an instance.

.DESCRIPTION
    Lists every database on the instance (same filtering as Get-sqmDatabaseHealth: excludes
    tempdb, system databases unless -IncludeSystemDatabases, and -ExcludeDatabase patterns) next
    to its most recent restore, sourced from msdb.dbo.restorehistory via dbatools'
    Get-DbaDbRestoreHistory -Last.

    A database that has never been restored (the normal case for most production databases) is
    listed explicitly with LastRestoreDate = $null / RestoreType = "(nie restauriert)" rather than
    being silently absent - the whole point of the report is to show every database's status, not
    just the ones with restore history.

    Results are saved as HTML, TXT and CSV files in the specified directory. The function also
    returns an object with the detail data and file paths.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER ExcludeDatabase
    Databases to exclude. Wildcards allowed.

.PARAMETER IncludeSystemDatabases
    Include system databases (except tempdb). Default: $false.

.PARAMETER OutputPath
    Output directory for report files. Default: <OutputPath config>\DatabaseRestoreHistory

.PARAMETER ContinueOnError
    Continue on error for an instance (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before writing files.

.PARAMETER WhatIf
    Shows which files would be created without actually writing them.

.EXAMPLE
    Get-sqmDatabaseRestoreHistory

.EXAMPLE
    Get-sqmDatabaseRestoreHistory -SqlInstance "SQL01" -IncludeSystemDatabases -OutputPath "D:\Reports"

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools, Invoke-sqmLogging
    Quelle fuer restore_type-Codes/Query: Get-DbaDbRestoreHistory (dbatools), das intern gegen
    msdb.dbo.restorehistory/backupset abfragt.
#>
function Get-sqmDatabaseRestoreHistory
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'DatabaseRestoreHistory'),
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"

		function _IsExcluded
		{
			param ([string]$Name,
				[string[]]$Patterns)
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()

			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade Restore-Historie ..." -FunctionName $functionName -Level "INFO"

				# 1. Datenbanken abrufen (exkl. tempdb, Filter nach System/Exclude) - dieselbe Logik
				# wie Get-sqmDatabaseHealth, damit JEDE Datenbank in der Liste auftaucht, auch wenn
				# sie nie restauriert wurde. Get-DbaDbRestoreHistory allein liefert nur Zeilen fuer
				# Datenbanken, die tatsaechlich in msdb.dbo.restorehistory stehen - eine nie
				# restaurierte Produktivdatenbank (der Normalfall) waere sonst einfach nicht in der
				# Ergebnisliste, statt sichtbar als "nie restauriert" gemeldet zu werden.
				$dbParams = @{ SqlInstance = $instance; SqlCredential = $SqlCredential; ErrorAction = 'Stop' }
				if ($EnableException) { $dbParams.EnableException = $true }
				$allDbs = Get-DbaDatabase @dbParams
				$databases = $allDbs | Where-Object {
					$_.Name -ne 'tempdb' -and
					($IncludeSystemDatabases -or -not $_.IsSystemObject) -and
					-not (_IsExcluded $_.Name $ExcludeDatabase)
				}

				if (-not $databases)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Datenbanken gefunden (nach Filterung)." -FunctionName $functionName -Level "WARNING"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Warning'
							Message	    = 'Keine Datenbanken nach Filterung'
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
							HtmlFile    = $null
						})
					continue
				}

				# 2. Letzte Restore-Vorgaenge pro Datenbank (msdb.dbo.restorehistory via dbatools).
				# -EnableException ist zwingend: ohne diesen Parameter meldet dbatools interne
				# Ablehnungen (z.B. fehlende VIEW SERVER STATE/msdb-Rechte) nur als PSFramework-
				# Warning und liefert $null zurueck, OHNE eine Exception zu werfen - -ErrorAction
				# Stop allein faengt das nicht ab (siehe Invoke-sqmRestoreDatabase, Regression
				# 1.9.35.0).
				$restoreHistParams = @{ SqlInstance = $instance; Last = $true; EnableException = $true; ErrorAction = 'Stop' }
				if ($SqlCredential) { $restoreHistParams['SqlCredential'] = $SqlCredential }
				$restoreRows = Get-DbaDbRestoreHistory @restoreHistParams
				$restoreLookup = @{ }
				foreach ($r in $restoreRows) { $restoreLookup[$r.Database] = $r }

				$now = Get-Date

				# 3. Detailzeilen fuer jede Datenbank
				foreach ($db in $databases)
				{
					$dbName = $db.Name
					$hist = $restoreLookup[$dbName]

					$lastRestoreDate = if ($hist) { $hist.Date } else { $null }
					$daysSinceRestore = if ($lastRestoreDate) { [math]::Round(($now - $lastRestoreDate).TotalDays, 0) } else { $null }

					$detailRows.Add([PSCustomObject]@{
							SqlInstance		 = $instance
							Database		 = $dbName
							LastRestoreDate  = $lastRestoreDate
							DaysSinceRestore = $daysSinceRestore
							RestoreType	     = if ($hist) { $hist.RestoreType } else { '(nie restauriert)' }
							RestoredBy		 = if ($hist) { $hist.Username } else { $null }
							SourceFile		 = if ($hist) { $hist.From } else { $null }
						})
				}

				# 4. Berichtsdateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "DatabaseRestoreHistory_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "DatabaseRestoreHistory_${safeInst}_${datestamp}.csv"
				$htmlFile = Join-Path $OutputPath "DatabaseRestoreHistory_${safeInst}_${datestamp}.html"

				# Nie restaurierte Datenbanken zuerst als $null einsortiert (Sort-Object stellt $null
				# ans Ende) - deshalb ueber ein Hilfsfeld sortieren, damit "nie restauriert" statt am
				# Ende ganz oben erscheint (das ist typischerweise die interessantere Information).
				$sortedRows = $detailRows | Sort-Object @{ Expression = { if ($_.LastRestoreDate) { 0 } else { 1 } } }, @{ Expression = 'LastRestoreDate'; Descending = $true }, Database

				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Restore-Historie-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}

					$cntNeverRestored = ($detailRows | Where-Object { -not $_.LastRestoreDate }).Count
					$cntRestored = $detailRows.Count - $cntNeverRestored

					# TXT-Bericht
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - Datenbank Restore-Historie")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# Restauriert: $cntRestored | Nie restauriert: $cntNeverRestored")
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-35} {1,-19} {2,-6} {3,-13} {4}" -f
							'Datenbank', 'Letzter Restore', 'Tage', 'Typ', 'Durchgefuehrt von'))
					$lines.Add(("-" * 110))

					foreach ($e in $sortedRows)
					{
						$dbNameShort = if ($e.Database.Length -gt 35) { $e.Database.Substring(0, 32) + '...' }
						else { $e.Database }
						$lastRestoreText = if ($e.LastRestoreDate) { $e.LastRestoreDate.ToString('yyyy-MM-dd HH:mm') } else { '(nie)' }
						$lines.Add(("{0,-35} {1,-19} {2,-6} {3,-13} {4}" -f
								$dbNameShort, $lastRestoreText, $e.DaysSinceRestore, $e.RestoreType, $e.RestoredBy))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					# CSV-Datei
					$sortedRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# HTML-Bericht
					$rowsHtml = foreach ($e in $sortedRows)
					{
						$sevClass = if ($e.LastRestoreDate) { 'ok' } else { 'warn' }
						$lastRestoreText = if ($e.LastRestoreDate) { $e.LastRestoreDate.ToString('yyyy-MM-dd HH:mm') } else { '(nie restauriert)' }
						"<tr><td class='$sevClass'>$([System.Net.WebUtility]::HtmlEncode($e.Database))</td><td>$lastRestoreText</td><td>$($e.DaysSinceRestore)</td><td>$([System.Net.WebUtility]::HtmlEncode($e.RestoreType))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$e.RestoredBy))</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$e.SourceFile))</td></tr>"
					}
					$bodyHtml = "<p>Restauriert: $cntRestored | Nie restauriert: $cntNeverRestored</p>" +
						"<table><tr><th>Datenbank</th><th>Letzter Restore</th><th>Tage</th><th>Typ</th><th>Durchgefuehrt von</th><th>Quelle</th></tr>" +
						($rowsHtml -join '') + "</table>"
					$html = ConvertTo-sqmHtmlReport -Title "Database Restore History - $instance" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
					$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$instance] Restore-Historie-Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
					$htmlFile = $null
				}

				$result = [PSCustomObject]@{
					SqlInstance = $instance
					Timestamp   = $timestamp
					DetailRows  = $sortedRows
					TxtFile	    = $txtFile
					CsvFile	    = $csvFile
					HtmlFile    = $htmlFile
					Status	    = 'OK'
				}
				$allInstanceResults.Add($result)
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status	    = 'Error'
						Message	    = $errMsg
						DetailRows  = $null
						TxtFile	    = $null
						CsvFile	    = $null
						HtmlFile    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanzen verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}
