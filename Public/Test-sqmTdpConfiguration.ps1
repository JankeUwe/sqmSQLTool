<#
.SYNOPSIS
    Checks the configuration and the logs of the TDP (IBM Spectrum Protect for SQL) backup
    solution without any SQL Server access and gives a fix hint for every problem found.

.DESCRIPTION
    File-only variant of Test-sqmTdpBackup for situations where there is no SQL access (no
    login, instance down, only file access to the server). It reads everything from the TDP
    directory, locally or through the administrative share of a remote computer:

      Configuration   BackupPlan.json (exists, valid JSON, no unreplaced <placeholders>,
                      valid English day names, at least one FULL day, databases selected,
                      no duplicates), tdpsqlc.exe, dsm.opt (TCPServeraddress present),
                      tdpsql.cfg, TdpBackup.config, the CMD wrapper Backup_TdpFull.cmd (passes
                      the exit code on, finds Backup-TdpFull.ps1), the log directory.
      Logs            The newest wrapper logs (Backup_TdpFull_*.log): ended with FAILED, or
                      unfinished (neither COMPLETED nor FAILED). The per-database TDP logs
                      (backup_FULL_*/backup_DIFF_*) and tdpsql.log (LOGFile in tdpsql.cfg):
                      ANSxxxxE/S, ACNxxxxE/S and ACOxxxxE/S messages of the last days, with a
                      hint for the common ones. Warning for E, Critical for S messages.
      TSM server      With -TestTsmServer: TCP connect to TCPServeraddress/TCPPort from
                      dsm.opt (local computer only).

    Not covered, because it needs SQL Server: SQL Agent job and schedule, tracking tables,
    backup age in msdb, plan against existing databases. Use Test-sqmTdpBackup for those.

    Severity: Critical (backup cannot work), Warning (needs attention), Info (does not change
    the overall status). Results are saved as TXT, CSV and HTML.

.PARAMETER ComputerName
    Computer that runs the TDP client. Default: local computer. Remote computers are read
    through the administrative share (\\<computer>\C$), the running user needs read access.

.PARAMETER TdpDir
    TDP installation directory on that computer.
    Default: C:\Program Files\Tivoli\TSM\TDPSql

.PARAMETER ConfigPath
    Path of BackupPlan.json on that computer. Default: <TdpDir>\BackupPlan.json

.PARAMETER LogFilesToScan
    Number of newest wrapper logs / per-database logs that are scanned. Default: 5.

.PARAMETER LogDays
    Only messages of the last N days count. Default: 7.

.PARAMETER TestTsmServer
    Test the TCP connection to the TSM server named in dsm.opt (local computer only).

.PARAMETER OutputPath
    Output directory for the report files. Default: 'TdpConfiguration' subfolder of the
    configured output path.

.PARAMETER NoOpen
    Do not open the HTML report.

.PARAMETER NoReport
    Do not write report files, only return the result object.

.PARAMETER AdditionalFinding
    Findings the caller already collected (Test-sqmTdpBackup passes its "SQL Server not reachable"
    finding when it falls back to this file-only check). They are merged into the result and report.

.PARAMETER ContinueOnError
    Continue with the next computer on error.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Test-sqmTdpConfiguration

.EXAMPLE
    # Remote server, only what needs attention
    (Test-sqmTdpConfiguration -ComputerName SQL01 -NoReport).Findings | Where-Object Severity -ne 'Info'

.EXAMPLE
    Test-sqmTdpConfiguration -TdpDir 'D:\Tivoli\TDPSql' -TestTsmServer

.NOTES
    Author:        MSSQLTools
    Prerequisites: Read access to the TDP directory (local or administrative share). No SQL
                   Server access and no dbatools needed.
#>
function Test-sqmTdpConfiguration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$ComputerName = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[string]$TdpDir = 'C:\Program Files\Tivoli\TSM\TDPSql',
		[Parameter(Mandatory = $false)]
		[string]$ConfigPath,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 50)]
		[int]$LogFilesToScan = 5,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 365)]
		[int]$LogDays = 7,
		[Parameter(Mandatory = $false)]
		[switch]$TestTsmServer,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'TdpConfiguration'),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
		[Parameter(Mandatory = $false)]
		[object[]]$AdditionalFinding,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		Invoke-sqmLogging -Message "Starte $functionName (TdpDir $TdpDir)" -FunctionName $functionName -Level "INFO"
		if (-not $ConfigPath) { $ConfigPath = Join-Path $TdpDir 'BackupPlan.json' }
	}

	process
	{
		foreach ($computer in $ComputerName)
		{
			try
			{
				$isLocal = ($computer -ieq $env:COMPUTERNAME) -or ($computer -in @('.', 'localhost', '(local)'))
				$hostName = if ($isLocal) { $env:COMPUTERNAME } else { $computer }
				Invoke-sqmLogging -Message "[$hostName] Pruefe TDP-Konfiguration und Logs ..." -FunctionName $functionName -Level "INFO"
				$now = Get-Date

				$fc = Invoke-sqmTdpFileCheck -Instance $hostName -TdpDir $TdpDir -ConfigPath $ConfigPath -HostName $hostName -IsLocal $isLocal -Now $now -LogFilesToScan $LogFilesToScan -TestTsmServer:$TestTsmServer -LogDays $LogDays
				$allFindings = @(@($AdditionalFinding | Where-Object { $_ }) + @($fc.Findings))

				$cnt = @{ }
				foreach ($s in 'Critical', 'Warning', 'Info') { $cnt[$s] = @($allFindings | Where-Object Severity -eq $s).Count }
				$overall = if ($cnt.Critical -gt 0) { 'Critical' } elseif ($cnt.Warning -gt 0) { 'Warning' } else { 'OK' }
				$sevOrder = @{ Critical = 0; Warning = 1; Info = 2 }
				$sorted = @($allFindings | Sort-Object @{ e = { $sevOrder[$_.Severity] } }, Category)

				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$safeHost = $hostName -replace '[\\/:*?"<>|]', '_'
				$fileStamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
				$txtFile = $null; $csvFile = $null; $htmlFile = $null

				if (-not $NoReport -and $PSCmdlet.ShouldProcess($hostName, "Erstelle TDP-Konfigurationsbericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null }
					$txtFile = Join-Path $OutputPath "TdpConfiguration_${safeHost}_$fileStamp.txt"
					$csvFile = Join-Path $OutputPath "TdpConfiguration_${safeHost}_$fileStamp.csv"
					$htmlFile = Join-Path $OutputPath "TdpConfiguration_${safeHost}_$fileStamp.html"

					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - TDP-Konfiguration und Logs")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Computer : $hostName")
					$lines.Add("# Erstellt : $timestamp")
					$lines.Add("# TdpDir   : $TdpDir")
					$lines.Add("# Gesamt   : $overall | Critical: $($cnt.Critical) | Warning: $($cnt.Warning) | Info: $($cnt.Info)")
					$lines.Add("# Nicht geprueft (braucht SQL): Agent-Job, Tracking-Tabellen, Backup-Alter in msdb -> Test-sqmTdpBackup")
					$lines.Add("# ================================================================")
					$lines.Add("")
					foreach ($f in $sorted)
					{
						$lines.Add("[$($f.Severity.ToUpper())] $($f.Category) - $($f.Message)")
						if ($f.Hint) { $lines.Add("        -> $($f.Hint)") }
					}
					if ($sorted.Count -eq 0) { $lines.Add('Keine Befunde.') }
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					$sorted | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Delimiter ';' -Force

					$enc = { param ($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
					$rows = foreach ($f in $sorted)
					{
						$cls = switch ($f.Severity) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { '' } }
						"<tr><td class='$cls'>$($f.Severity)</td><td>$(& $enc $f.Category)</td><td>$(& $enc $f.Message)</td><td>$(& $enc $f.Hint)</td></tr>"
					}
					$body = "<p>Computer: $(& $enc $hostName) | TdpDir: $(& $enc $TdpDir)<br>Gesamt: <b>$overall</b> | Critical: $($cnt.Critical) | Warning: $($cnt.Warning) | Info: $($cnt.Info)</p>"
					$body += "<p>Nicht geprueft (braucht SQL Server): Agent-Job, Tracking-Tabellen, Backup-Alter in msdb. Dafuer Test-sqmTdpBackup verwenden.</p>"
					$body += if ($sorted.Count -gt 0) { "<table><tr><th>Schwere</th><th>Bereich</th><th>Befund</th><th>Hinweis</th></tr>" + ($rows -join '') + "</table>" } else { "<p class='ok'>Keine Befunde.</p>" }
					ConvertTo-sqmHtmlReport -Title "TDP-Konfiguration und Logs - $hostName" -Subtitle "Erstellt: $timestamp" -BodyHtml $body | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
				}

				$lvl = if ($overall -eq 'OK') { 'INFO' } else { 'WARNING' }
				Invoke-sqmLogging -Message "[$hostName] TDP-Konfiguration/Logs: $overall (Critical $($cnt.Critical), Warning $($cnt.Warning), Info $($cnt.Info))" -FunctionName $functionName -Level $lvl

				$allResults.Add([PSCustomObject]@{
						ComputerName  = $hostName
						Timestamp     = $timestamp
						Status        = $overall
						CriticalCount = $cnt.Critical
						WarningCount  = $cnt.Warning
						InfoCount     = $cnt.Info
						Findings      = $sorted
						TxtFile       = $txtFile
						CsvFile       = $csvFile
						HtmlFile      = $htmlFile
					})
			}
			catch
			{
				$errMsg = "Fehler auf '$computer': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						ComputerName = $computer
						Status       = 'Error'
						Message      = $errMsg
						Findings     = $null
						TxtFile      = $null
						CsvFile      = $null
						HtmlFile     = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Computer verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
