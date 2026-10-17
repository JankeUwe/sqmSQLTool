<#
.SYNOPSIS
    Shrinks the transaction log file (LDF) of one or more databases and reports why the log
    has active VLFs or cannot shrink further, and why it has many VLFs.

.DESCRIPTION
    Executes DBCC SHRINKFILE on the log file(s). Calculates the target size
    as a percentage of the current size (ShrinkTargetPercent) with a
    lower threshold (MinTargetMB). Handles Always On AGs (automatically
    redirects to the primary). System databases and offline databases are skipped.

    Before (and after) the shrink every database is analysed (metadata only, no scans):

    - Why the log is active / cannot be reused: log_reuse_wait_desc with details, e.g.
      LOG_BACKUP (last log backup), ACTIVE_TRANSACTION (session, login, host, program, open
      since), AVAILABILITY_REPLICA (lagging or suspended secondary with queue sizes),
      REPLICATION (log reader / CDC), CHECKPOINT, ACTIVE_BACKUP_OR_RESTORE.
    - Where the last active VLF sits: DBCC SHRINKFILE can only shrink up to the end of the last
      active VLF. If it sits at the end of the file, the shrink is skipped (Status 'Blocked')
      and the reason is reported, even when log_reuse_wait_desc says NOTHING.
    - Why there are many VLFs (>= 300 Warning, >= 1000 Critical): percent growth, small fixed
      growth, many VLFs below 1 MB (earlier small growths or shrink/grow cycles), with a
      recommendation for target size and autogrowth.

    Cause and recommendation are written to the log (WARNING) and returned in the result
    (columns LogReuseWait, Cause, Recommendation, VlfCount, VlfStatus, VlfCause, ...).
    With -AnalyzeOnly nothing is shrunk, only the analysis is returned.

    Important notes:
    - Shrink can only reduce to the oldest active VLF.
    - In FULL recovery model, a log backup beforehand is advisable.
    - Frequent shrinking fragments VLFs.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name). For AG members,
    automatically redirected to the primary.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER Database
    Target database name(s) (wildcards allowed). Without specification, all
    user databases are processed (equivalent to -All).

.PARAMETER All
    Processes all user databases (excl. system databases, online only).
    Also used implicitly when neither -Database nor -All is specified.

.PARAMETER ShrinkTargetPercent
    Target size as a percentage of the current log size (1-99). Default: 10.

.PARAMETER MinTargetMB
    Minimum target size in MB (default: 64 MB).

.PARAMETER AnalyzeOnly
    Only analyse (log reuse wait, active VLFs, VLF count and cause), do not shrink.
    Status of the result rows: 'Analyzed'.

.PARAMETER ContinueOnError
    Continue with the next database on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before shrinking. Disabled by default.

.PARAMETER WhatIf
    Shows what would happen without executing the shrink.

.EXAMPLE
    Invoke-sqmLogShrink -Database "MyDB" -ShrinkTargetPercent 20

.EXAMPLE
    Invoke-sqmLogShrink -SqlInstance "SQL01" -All -WhatIf

.EXAMPLE
    # Why does the log not shrink, why so many VLFs? (no shrink)
    Invoke-sqmLogShrink -SqlInstance "SQL01" -AnalyzeOnly |
        Format-List Database, LogReuseWait, Cause, Recommendation, VlfCount, VlfStatus, VlfCause, VlfRecommendation

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging.
    For Always On AGs, automatically redirected to the primary.
    The analysis needs VIEW SERVER STATE (open transactions, AG queues) and read access to
    msdb.dbo.backupset; missing parts are skipped with a VERBOSE message.
    Status values: Shrunk, NoChangeNeeded, Blocked, Analyzed, WhatIfSkipped, Skipped, Failed.
#>
function Invoke-sqmLogShrink
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[Alias('DatabaseName')]
		[string[]]$Database,
		[Parameter(Mandatory = $false)]
		[switch]$All,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$ShrinkTargetPercent = 10,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, [int]::MaxValue)]
		[int]$MinTargetMB = 64,
		[Parameter(Mandatory = $false)]
		[switch]$AnalyzeOnly,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$systemDatabases = @('master', 'model', 'msdb', 'tempdb', 'distribution')
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		$effectiveInstance = $SqlInstance
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		# Einheitliche Ergebniszeile; $Diag = Get-sqmLogReuseDiagnosis (oder $null), $DiagAfter nach dem Shrink
		function New-sqmLogShrinkResult
		{
			param ([string]$Db, [string]$LogFile = 'n/a', [double]$SizeBefore = 0, [double]$TargetSize = 0, [double]$SizeAfter = 0,
				[double]$SpaceSaved = 0, [double]$ShrinkPercent = 0, [string]$Status, [string]$Message, $Diag, $DiagAfter)
			$fileDiag = if ($Diag -and $LogFile -ne 'n/a') { @($Diag.Files | Where-Object { $_.LogicalName -eq $LogFile })[0] } else { $null }
			$src = if ($DiagAfter) { $DiagAfter } else { $Diag }
			[PSCustomObject]@{
				SqlInstance	      = $effectiveInstance
				Database		  = $Db
				LogFile		      = $LogFile
				SizeBefore_MB	  = $SizeBefore
				TargetSize_MB	  = $TargetSize
				SizeAfter_MB	  = $SizeAfter
				SpaceSaved_MB	  = $SpaceSaved
				ShrinkPercent	  = $ShrinkPercent
				Status		      = $Status
				Message		      = $Message
				RecoveryModel	  = $(if ($Diag) { $Diag.RecoveryModel } else { $null })
				LogReuseWait	  = $(if ($src) { $src.LogReuseWait } else { $null })
				LogUsed_Pct	      = $(if ($src) { $src.LogUsed_Pct } else { $null })
				MinReachable_MB   = $(if ($fileDiag) { $fileDiag.ActiveEnd_MB } else { $null })
				Cause			  = $(if ($src) { $src.Cause } else { $null })
				Recommendation    = $(if ($src) { $src.Recommendation } else { $null })
				VlfCount		  = $(if ($Diag) { $Diag.VlfCount } else { $null })
				VlfCountAfter	  = $(if ($DiagAfter) { $DiagAfter.VlfCount } else { $null })
				ActiveVlfCount    = $(if ($src) { $src.ActiveVlfCount } else { $null })
				VlfStatus		  = $(if ($src) { $src.VlfStatus } else { $null })
				VlfCause		  = $(if ($src) { $src.VlfCause } else { $null })
				VlfRecommendation = $(if ($src) { $src.VlfRecommendation } else { $null })
				Details		      = $(if ($src) { $src.Details -join ' | ' } else { $null })
			}
		}
	}

	process
	{
		try
		{
			# ---- 1. Primary-Validierung bei AGs ----
			Invoke-sqmLogging -Message "Pruefe AG-Mitgliedschaft und Primary-Status von '$SqlInstance' ..." -FunctionName $functionName -Level "INFO"
			$agsOnEntry = Get-DbaAvailabilityGroup @connParams -ErrorAction SilentlyContinue

			if ($agsOnEntry)
			{
				$primaryAgs = @($agsOnEntry | Where-Object { $_.PrimaryReplica -eq $SqlInstance })
				$nonPrimaryAgs = @($agsOnEntry | Where-Object { $_.PrimaryReplica -ne $SqlInstance })

				if ($primaryAgs.Count -eq 0)
				{
					$firstAg = $nonPrimaryAgs[0]
					$effectiveInstance = $firstAg.PrimaryReplica
					if (-not $effectiveInstance)
					{
						throw "Primary-Replikat fuer AG '$($firstAg.Name)' konnte nicht ermittelt werden."
					}
					Invoke-sqmLogging -Message "'$SqlInstance' ist kein Primary. Redirect zu Primary '$effectiveInstance' (AG: '$($firstAg.Name)')." -FunctionName $functionName -Level "WARNING"
					$connParams = @{ SqlInstance = $effectiveInstance }
					if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
				}
				elseif ($nonPrimaryAgs.Count -gt 0)
				{
					Invoke-sqmLogging -Message "'$SqlInstance' ist Primary fuer $($primaryAgs.Count) AG(s), aber Secondary fuer $($nonPrimaryAgs.Count) weitere AG(s). SHRINKFILE wird auf '$SqlInstance' ausgefuehrt." -FunctionName $functionName -Level "WARNING"
				}
				else
				{
					Invoke-sqmLogging -Message "'$SqlInstance' ist Primary fuer alle $($primaryAgs.Count) AG(s)." -FunctionName $functionName -Level "INFO"
				}
			}
			else
			{
				Invoke-sqmLogging -Message "'$SqlInstance' ist kein AG-Mitglied (Standalone)." -FunctionName $functionName -Level "INFO"
			}

			Invoke-sqmLogging -Message "Effektive Instanz fuer SHRINKFILE: '$effectiveInstance'" -FunctionName $functionName -Level "INFO"

			# ---- 2. Zieldatenbanken ermitteln ----
			$allDatabases = Get-DbaDatabase @connParams -ErrorAction Stop
			if (-not $allDatabases)
			{
				throw "Keine Datenbanken auf '$effectiveInstance' gefunden oder Verbindung fehlgeschlagen."
			}

			# Ohne -Database und ohne -All: alle Benutzerdatenbanken (implizites -All)
			$useAll = $All -or (-not $Database -or $Database.Count -eq 0)

			$targetDatabases = if ($useAll)
			{
				$allDatabases | Where-Object { $_.Name -notin $systemDatabases -and $_.Status -eq 'Normal' }
			}
			else
			{
				$resolved = [System.Collections.Generic.List[object]]::new()
				foreach ($pattern in $Database)
				{
					if ($pattern -like '*[*?]*')
					{
						$matched = $allDatabases | Where-Object { $_.Name -like $pattern }
						if (-not $matched)
						{
							Invoke-sqmLogging -Message "Kein Treffer fuer Muster '$pattern' auf '$effectiveInstance'." -FunctionName $functionName -Level "WARNING"
						}
						else
						{
							$matched | ForEach-Object { $resolved.Add($_) }
						}
					}
					else
					{
						$db = $allDatabases | Where-Object { $_.Name -eq $pattern }
						if (-not $db)
						{
							Invoke-sqmLogging -Message "Datenbank '$pattern' nicht auf '$effectiveInstance' gefunden." -FunctionName $functionName -Level "WARNING"
						}
						else
						{
							$resolved.Add($db)
						}
					}
				}
				$resolved | Select-Object -Unique
			}

			if (-not $targetDatabases)
			{
				throw "Keine Zieldatenbanken zur Verarbeitung gefunden."
			}

			Invoke-sqmLogging -Message "$(@($targetDatabases).Count) Datenbank(en) zur Verarbeitung." -FunctionName $functionName -Level "INFO"

			# ---- 3. Pro Datenbank: analysieren, Log-Datei shrinken ----
			foreach ($db in $targetDatabases)
			{
				$dbName = $db.Name
				$diag = $null
				try
				{
					if ($dbName -in $systemDatabases)
					{
						$msg = "Systemdatenbank '$dbName' wird uebersprungen."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
						$results.Add((New-sqmLogShrinkResult -Db $dbName -Status 'Skipped' -Message $msg))
						continue
					}

					if ($db.Status -ne 'Normal')
					{
						$msg = "Datenbank '$dbName' ist nicht Online (Status: $($db.Status)). uebersprungen."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
						$results.Add((New-sqmLogShrinkResult -Db $dbName -Status 'Skipped' -Message $msg))
						continue
					}

					$allFiles = Get-DbaDbFile @connParams -Database $dbName -ErrorAction Stop
					$logFiles = $allFiles | Where-Object { $_.TypeDescription -eq 'LOG' }

					if (-not $logFiles)
					{
						if (-not $allFiles)
						{
							# Get-DbaDbFile liefert fuer diese DB ueberhaupt keine Zeilen (auch keine ROWS-Dateien).
							# Get-DbaDatabase hat die DB zuvor gefunden, d.h. sie existiert - typischerweise fehlende
							# Berechtigung (CONNECT/db_datareader) des verwendeten Logins auf genau dieser Datenbank.
							$msg = "Get-DbaDbFile lieferte keine Daten fuer Datenbank '$dbName' - moeglicherweise fehlt dem verwendeten Login der Zugriff auf diese Datenbank. Log-Datei konnte nicht ermittelt werden."
						}
						else
						{
							$msg = "Keine Log-Datei fuer Datenbank '$dbName' gefunden."
						}
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
						$results.Add((New-sqmLogShrinkResult -Db $dbName -Status 'Skipped' -Message $msg))
						continue
					}

					# ---- Analyse: warum ist das Log aktiv, warum so viele VLFs? ----
					try
					{
						$diag = Get-sqmLogReuseDiagnosis -ConnParams $connParams -Database $dbName
						$lvl = if ($diag.LogReuseWait -ne 'NOTHING' -or $diag.Recommendation) { 'WARNING' } else { 'INFO' }
						Invoke-sqmLogging -Message "[$dbName] Log $($diag.LogSize_MB) MB, $($diag.LogUsed_Pct)% belegt, log_reuse_wait_desc=$($diag.LogReuseWait). $($diag.Cause)$(if ($diag.Recommendation) { " Empfehlung: $($diag.Recommendation)" })" -FunctionName $functionName -Level $lvl
						$vlfLvl = if ($diag.VlfStatus -eq 'OK') { 'INFO' } else { 'WARNING' }
						Invoke-sqmLogging -Message "[$dbName] VLFs: $($diag.VlfCount) (aktiv: $($diag.ActiveVlfCount)), Bewertung $($diag.VlfStatus).$(if ($diag.VlfCause) { " Ursache: $($diag.VlfCause)" })$(if ($diag.VlfRecommendation) { " Empfehlung: $($diag.VlfRecommendation)" })" -FunctionName $functionName -Level $vlfLvl
					}
					catch
					{
						Invoke-sqmLogging -Message "[$dbName] Log-Analyse nicht moeglich: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						if ($EnableException) { throw }
					}

					foreach ($logFile in $logFiles)
					{
						$logFileName = $logFile.LogicalName
						$sizeBefore = [math]::Round($logFile.Size.Megabyte, 2)
						$targetByPct = [math]::Round($sizeBefore * ($ShrinkTargetPercent / 100), 0)
						$targetSizeMB = [math]::Max($targetByPct, $MinTargetMB)
						$fileDiag = if ($diag) { @($diag.Files | Where-Object { $_.LogicalName -eq $logFileName })[0] } else { $null }

						Invoke-sqmLogging -Message "[$dbName / $logFileName] Groesse: ${sizeBefore} MB -> Ziel: ${targetSizeMB} MB ($ShrinkTargetPercent%, Min: ${MinTargetMB} MB)$(if ($fileDiag) { ", erreichbar (Ende letzter aktiver VLF): $($fileDiag.ActiveEnd_MB) MB" })" -FunctionName $functionName -Level "VERBOSE"

						if ($AnalyzeOnly)
						{
							$msg = if ($diag) { "Analyse: $($diag.Cause)" } else { 'Analyse nicht moeglich (siehe Log).' }
							$results.Add((New-sqmLogShrinkResult -Db $dbName -LogFile $logFileName -SizeBefore $sizeBefore -TargetSize $targetSizeMB -SizeAfter $sizeBefore -Status 'Analyzed' -Message $msg -Diag $diag))
							continue
						}

						if ($targetSizeMB -ge $sizeBefore)
						{
							$msg = "Log-Datei '$logFileName' ist bereits ${sizeBefore} MB - Zielgroesse ${targetSizeMB} MB erreicht oder ueberschritten. Kein Shrink erforderlich."
							Invoke-sqmLogging -Message "[$dbName] $msg" -FunctionName $functionName -Level "VERBOSE"
							$results.Add((New-sqmLogShrinkResult -Db $dbName -LogFile $logFileName -SizeBefore $sizeBefore -TargetSize $targetSizeMB -SizeAfter $sizeBefore -Status 'NoChangeNeeded' -Message $msg -Diag $diag))
							continue
						}

						# Aktiver Teil am Dateiende: SHRINKFILE kann nichts freigeben -> nicht ausfuehren, Grund melden
						if ($fileDiag -and $fileDiag.ActiveVlfCount -gt 0 -and $fileDiag.ActiveEnd_MB -ge ($sizeBefore - 1))
						{
							$msg = "Shrink nicht moeglich: der aktive Teil des Logs liegt am Dateiende ($($fileDiag.ActiveEnd_MB) von ${sizeBefore} MB). Ursache: $($diag.Cause)$(if ($diag.Recommendation) { " Empfehlung: $($diag.Recommendation)" })"
							Invoke-sqmLogging -Message "[$dbName / $logFileName] $msg" -FunctionName $functionName -Level "WARNING"
							$results.Add((New-sqmLogShrinkResult -Db $dbName -LogFile $logFileName -SizeBefore $sizeBefore -TargetSize $targetSizeMB -SizeAfter $sizeBefore -Status 'Blocked' -Message $msg -Diag $diag))
							continue
						}

						$actionMsg = "DBCC SHRINKFILE auf '$logFileName' von ${sizeBefore} MB auf ${targetSizeMB} MB"
						if ($PSCmdlet.ShouldProcess("$effectiveInstance / $dbName / $logFileName", $actionMsg))
						{
							try
							{
								$shrinkQuery = "DBCC SHRINKFILE (N'$($logFileName -replace "'", "''")', $targetSizeMB) WITH NO_INFOMSGS;"
								Invoke-DbaQuery @connParams -Database $dbName -Query $shrinkQuery -EnableException

								$logFileAfter = Get-DbaDbFile @connParams -Database $dbName -ErrorAction Stop |
								Where-Object { $_.LogicalName -eq $logFileName }
								$sizeAfter = [math]::Round($logFileAfter.Size.Megabyte, 2)
								$spaceSaved = [math]::Round($sizeBefore - $sizeAfter, 2)
								$shrinkPct = if ($sizeBefore -gt 0) { [math]::Round((($sizeBefore - $sizeAfter) / $sizeBefore) * 100, 1) }
								else { 0 }

								$diagAfter = $null
								try { $diagAfter = Get-sqmLogReuseDiagnosis -ConnParams $connParams -Database $dbName }
								catch { Invoke-sqmLogging -Message "[$dbName] Log-Analyse nach dem Shrink nicht moeglich: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE" }

								$msg = "SHRINKFILE abgeschlossen: ${sizeBefore} MB -> ${sizeAfter} MB (${spaceSaved} MB / ${shrinkPct}% Reduktion)."
								$lvl = 'INFO'
								if ($sizeAfter -gt $targetSizeMB)
								{
									$lvl = 'WARNING'
									if ($diagAfter)
									{
										$msg += " Zielgroesse ${targetSizeMB} MB nicht erreicht. Ursache: $($diagAfter.Cause)$(if ($diagAfter.Recommendation) { " Empfehlung: $($diagAfter.Recommendation)" })"
									}
									else
									{
										$msg += " Zielgroesse ${targetSizeMB} MB wurde nicht erreicht (aktive VLFs verhindern weitere Verkleinerung)."
									}
								}
								if ($diag -and $diagAfter) { $msg += " VLFs: $($diag.VlfCount) -> $($diagAfter.VlfCount)." }
								Invoke-sqmLogging -Message "[$dbName / $logFileName] $msg" -FunctionName $functionName -Level $lvl
								$results.Add((New-sqmLogShrinkResult -Db $dbName -LogFile $logFileName -SizeBefore $sizeBefore -TargetSize $targetSizeMB -SizeAfter $sizeAfter -SpaceSaved $spaceSaved -ShrinkPercent $shrinkPct -Status 'Shrunk' -Message $msg -Diag $diag -DiagAfter $diagAfter))
							}
							catch
							{
								$errMsg = "Fehler beim Shrink: $($_.Exception.Message)"
								Invoke-sqmLogging -Message "[$dbName / $logFileName] $errMsg" -FunctionName $functionName -Level "ERROR"
								if ($EnableException) { throw }
								$results.Add((New-sqmLogShrinkResult -Db $dbName -LogFile $logFileName -SizeBefore $sizeBefore -TargetSize $targetSizeMB -SizeAfter $sizeBefore -Status 'Failed' -Message $errMsg -Diag $diag))
								if (-not $ContinueOnError) { throw }
							}
						}
						else
						{
							$msg = "WhatIf: Shrink uebersprungen."
							Invoke-sqmLogging -Message "[$dbName / $logFileName] $msg" -FunctionName $functionName -Level "VERBOSE"
							$results.Add((New-sqmLogShrinkResult -Db $dbName -LogFile $logFileName -SizeBefore $sizeBefore -TargetSize $targetSizeMB -SizeAfter $sizeBefore -Status 'WhatIfSkipped' -Message "WhatIf: Shrink wuerde ausgefuehrt werden." -Diag $diag))
						}
					}
				}
				catch
				{
					$errMsg = "Fehler bei Datenbank '$dbName': $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					$results.Add((New-sqmLogShrinkResult -Db $dbName -Status 'Failed' -Message $errMsg -Diag $diag))
					if ($EnableException) { throw }
					if (-not $ContinueOnError) { throw }
				}
			}

			$cntShrunk = @($results | Where-Object Status -eq 'Shrunk').Count
			$cntNoChange = @($results | Where-Object Status -eq 'NoChangeNeeded').Count
			$cntBlocked = @($results | Where-Object Status -eq 'Blocked').Count
			$cntAnalyzed = @($results | Where-Object Status -eq 'Analyzed').Count
			$cntSkipped = @($results | Where-Object Status -eq 'Skipped').Count
			$cntFailed = @($results | Where-Object Status -eq 'Failed').Count
			$totalSaved = [math]::Round(($results | Measure-Object SpaceSaved_MB -Sum).Sum, 2)
			Invoke-sqmLogging -Message "$functionName abgeschlossen. Shrunk: $cntShrunk, NoChange: $cntNoChange, Blocked: $cntBlocked, Analyzed: $cntAnalyzed, Skipped: $cntSkipped, Failed: $cntFailed, Gesamt eingespart: ${totalSaved} MB" -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$errMsg = "Schwerer Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			throw $errMsg
		}
	}

	end
	{
		return $results
	}
}
