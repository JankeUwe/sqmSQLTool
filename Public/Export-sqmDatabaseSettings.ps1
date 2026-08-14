<#
.SYNOPSIS
Exports the per-database "Options" settings (as shown on the Options page of SSMS' Database
Properties dialog) for one or more databases to a JSON snapshot file.

.DESCRIPTION
Reads every database-level option covered by Get-sqmDatabaseSettingsDefinition (Recovery Model,
Compatibility Level, Page Verify, the ANSI/ARITHABORT/AUTO_* toggles, Trustworthy, Delayed
Durability, Target Recovery Time, Read-Only, Read-Committed-Snapshot, Broker-Enabled, ...) directly
from sys.databases - one query covers every selected database, no need to connect into each
database individually. Counterpart is Import-sqmDatabaseSettings, which re-applies the snapshot via
ALTER DATABASE.

System databases (master/model/msdb/tempdb) are excluded by default since their Options rarely need
restoring and some options do not apply to them - use -IncludeSystemDatabases to capture them too.

.PARAMETER SqlInstance
Source SQL Server instance. Mandatory.

.PARAMETER SqlCredential
Optional alternative credentials (PSCredential object).

.PARAMETER Database
Restricts the export to these database names (wildcards allowed). Without this, every database is
exported (subject to -IncludeSystemDatabases and -ExcludeDatabase).

.PARAMETER ExcludeDatabase
Additional database names to exclude (wildcards allowed).

.PARAMETER IncludeSystemDatabases
When set, master/model/msdb/tempdb are included in the export.

.PARAMETER OutputPath
Either a full file path, or an existing/creatable directory - in the latter case the file is named
"DatabaseSettings_<SqlInstance>_<yyyyMMddHHmmss>.json" inside it. Mandatory. An HTML report with the
same base name (.html) is written alongside it - a customer-presentable summary of every captured
database and setting, opened automatically unless -NoOpen is passed.

.PARAMETER NoOpen
Suppresses automatically opening the generated HTML report after the export completes.

.PARAMETER EnableException
Throw exceptions immediately instead of returning a Failed result object.

.PARAMETER Confirm
Request confirmation before writing the output file.

.PARAMETER WhatIf
Shows what would be written without creating the file.

.EXAMPLE
Export-sqmDatabaseSettings -SqlInstance 'SQL01' -OutputPath 'C:\Backups\SQLSnapshots'

Exports the Options settings of every user database on SQL01 to an auto-named file.

.EXAMPLE
Export-sqmDatabaseSettings -SqlInstance 'SQL01' -Database 'Frontarena' -OutputPath 'C:\Backups\Frontarena_Options.json'

Exports only the 'Frontarena' database's settings to the given file.

.NOTES
Prerequisites : dbatools, Invoke-sqmLogging, Get-sqmDatabaseSettingsDefinition
Counterpart   : Import-sqmDatabaseSettings (applies the generated file against a target instance).
#>
function Export-sqmDatabaseSettings
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $true)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$definitions = @(Get-sqmDatabaseSettingsDefinition)

		function _MatchesAnyPattern([string]$Name, [string[]]$Patterns)
		{
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}
	}

	process
	{
		try
		{
			Invoke-sqmLogging -Message "Verbinde mit '$SqlInstance'." -FunctionName $functionName -Level 'INFO'
			$server = Connect-DbaInstance @connParams

			# ---- 1. sys.databases in einer Abfrage lesen (deckt alle Kandidaten-Datenbanken ab) ----
			$selectCols = ($definitions | ForEach-Object { "[$($_.SqlColumn)] AS [$($_.Key)]" }) -join ",`r`n    "
			$sysDbQuery = @"
SELECT
    name AS DatabaseName,
    database_id AS DatabaseId,
    $selectCols
FROM sys.databases
ORDER BY name
"@
			$allRows = @(Invoke-DbaQuery @connParams -Query $sysDbQuery -EnableException -As PSObject)

			if (-not $IncludeSystemDatabases)
			{
				$allRows = @($allRows | Where-Object { $_.DatabaseId -gt 4 })
			}
			if ($Database)
			{
				$allRows = @($allRows | Where-Object { $n = $_.DatabaseName; ($Database | Where-Object { $n -like $_ }).Count -gt 0 })
			}
			if ($ExcludeDatabase)
			{
				$allRows = @($allRows | Where-Object { -not (_MatchesAnyPattern $_.DatabaseName $ExcludeDatabase) })
			}

			if ($allRows.Count -eq 0)
			{
				$msg = "Keine Datenbanken nach Filter-Anwendung auf '$SqlInstance' gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
				Write-Warning $msg
				return [PSCustomObject]@{
					SourceInstance = $SqlInstance; OutputFile = $null; DatabaseCount = 0
					Status = 'Skipped'; Message = $msg; Timestamp = Get-Date
				}
			}
			Invoke-sqmLogging -Message "$($allRows.Count) Datenbank(en) auf '$SqlInstance' fuer Export ermittelt." -FunctionName $functionName -Level 'INFO'

			# ---- 2. Pro Datenbank ein Settings-Objekt bauen (Bit -> bool gecastet) ----
			$dbEntries = foreach ($row in $allRows)
			{
				$settings = [ordered]@{ }
				foreach ($def in $definitions)
				{
					$raw = $row.($def.Key)
					$settings[$def.Key] = if ($def.ValueKind -in @('Bit', 'BitAsLocalGlobal', 'BitAsForcedSimple', 'BitAsReadOnlyReadWrite', 'BitAsBrokerEnableDisable')) { [bool]$raw }
					else { $raw }
				}
				[PSCustomObject]@{
					DatabaseName = $row.DatabaseName
					Settings	 = [PSCustomObject]$settings
				}
			}

			# ---- 3. Zielpfad aufloesen (Datei oder Verzeichnis) ----
			$isDirectory = (Test-Path -Path $OutputPath -PathType Container) -or ([string]::IsNullOrEmpty([System.IO.Path]::GetExtension($OutputPath)))
			if ($isDirectory)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = ($SqlInstance -replace '[\\/:*?"<>|]', '_')
				$fileName = "DatabaseSettings_${safeInst}_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
				$finalOutputFile = Join-Path $OutputPath $fileName
			}
			else
			{
				$parentDir = Split-Path -Path $OutputPath -Parent
				if ($parentDir -and -not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
				$finalOutputFile = $OutputPath
			}

			# ---- 4. Snapshot zusammenbauen und schreiben ----
			$snapshot = [PSCustomObject]@{
				Metadata = [PSCustomObject]@{
					ExportDate    = Get-Date -Format 'o'
					ExportedBy    = $env:USERNAME
					SourceInstance = $SqlInstance
					ComputerName  = $server.ComputerName
					DatabaseCount = $dbEntries.Count
				}
				Databases = $dbEntries
			}

			$writeAction = "Options-Einstellungen von $($dbEntries.Count) Datenbank(en) aus '$SqlInstance' nach '$finalOutputFile' exportieren"
			if ($PSCmdlet.ShouldProcess($finalOutputFile, $writeAction))
			{
				$jsonContent = $snapshot | ConvertTo-Json -Depth 6 -ErrorAction Stop
				Set-Content -Path $finalOutputFile -Value $jsonContent -Encoding UTF8 -ErrorAction Stop
				Invoke-sqmLogging -Message "Export geschrieben: $finalOutputFile ($($dbEntries.Count) Datenbank(en))." -FunctionName $functionName -Level 'INFO'
				Write-Host "Export-sqmDatabaseSettings: $($dbEntries.Count) Datenbank(en) nach '$finalOutputFile' geschrieben." -ForegroundColor Green

				# ---- 5. HTML-Bericht bauen (kundenpraesentabel) ----
				function _Enc($s)
				{
					if ($null -eq $s) { return '' }
					return ([string]$s) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
				}

				$summaryRows = ($dbEntries | ForEach-Object {
						$s = $_.Settings
						"<tr><td>$(_Enc $_.DatabaseName)</td><td>$(_Enc $s.RecoveryModel)</td><td>$(_Enc $s.CompatibilityLevel)</td><td>$(_Enc $s.PageVerifyOption)</td><td>$(_Enc $s.CollationName)</td></tr>"
					}) -join "`n"
				$summaryTable = "<table><thead><tr><th>Datenbank</th><th>Recovery Model</th><th>Compat. Level</th><th>Page Verify</th><th>Collation</th></tr></thead><tbody>$summaryRows</tbody></table>"

				$detailSections = ($dbEntries | ForEach-Object {
						$kvRows = ($_.Settings.PSObject.Properties | ForEach-Object { "<tr><td>$(_Enc $_.Name)</td><td>$(_Enc $_.Value)</td></tr>" }) -join "`n"
						"<details><summary style='cursor:pointer;color:#5dade2;padding:6px 0;'>$(_Enc $_.DatabaseName)</summary><table><tbody>$kvRows</tbody></table></details>"
					}) -join "`n"

				$bodyHtml = "<h2 style='color:#5dade2;'>Uebersicht ($($dbEntries.Count) Datenbank(en))</h2>$summaryTable" +
				"<h2 style='color:#5dade2;margin-top:26px;'>Details je Datenbank</h2>$detailSections"

				$htmlFilepath = [System.IO.Path]::ChangeExtension($finalOutputFile, '.html')
				$html = ConvertTo-sqmHtmlReport -Title "Database Settings Report - $SqlInstance" `
												-Subtitle "$($dbEntries.Count) Datenbank(en) | Exportiert: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				Set-Content -Path $htmlFilepath -Value $html -Encoding UTF8 -ErrorAction Stop
				Invoke-sqmLogging -Message "HTML-Bericht gespeichert: $htmlFilepath" -FunctionName $functionName -Level 'INFO'
				Invoke-sqmOpenReport -HtmlFile $htmlFilepath -NoOpen:$NoOpen

				return [PSCustomObject]@{
					SourceInstance = $SqlInstance
					OutputFile	   = $finalOutputFile
					ReportPath	   = $htmlFilepath
					DatabaseCount  = $dbEntries.Count
					Status		   = 'Success'
					Message		   = 'Export erfolgreich.'
					Timestamp	   = Get-Date
				}
			}
			else
			{
				return [PSCustomObject]@{
					SourceInstance = $SqlInstance
					OutputFile	   = $finalOutputFile
					DatabaseCount  = $dbEntries.Count
					Status		   = 'WhatIf'
					Message		   = 'WhatIf - Datei wuerde geschrieben.'
					Timestamp	   = Get-Date
				}
			}
		}
		catch
		{
			$errMsg = "Fehler in Export-sqmDatabaseSettings: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			Write-Error $errMsg
			return [PSCustomObject]@{
				SourceInstance = $SqlInstance; OutputFile = $null; DatabaseCount = 0
				Status = 'Failed'; Message = $errMsg; Timestamp = Get-Date
			}
		}
	}
}
