<#
.SYNOPSIS
    Shrinkt die Transaktions-Logdatei (LDF) einer oder mehrerer Datenbanken.

.DESCRIPTION
    Fuehrt DBCC SHRINKFILE auf die Log-Datei(en) aus. Berechnet die Zielgroesse
    aus einem Prozentsatz der aktuellen Groesse (ShrinkTargetPercent) mit einem
    unteren Schwellwert (MinTargetMB). Beruecksichtigt Always On AGs (leitet
    automatisch zum Primary um). Systemdatenbanken und Offline-Datenbanken
    werden uebersprungen.

    Wichtige Hinweise:
    - Shrink kann nur bis zum aeltesten aktiven VLF verkleinern.
    - Im FULL Recovery Modell ist vorher ein Log-Backup sinnvoll.
    - Haeufiges Shrinken fragmentiert die VLFs.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername). Bei AG-Mitglied
    wird automatisch zum Primary umgeleitet.

.PARAMETER SqlCredential
    Optionales PSCredential fuer die Verbindung.

.PARAMETER Database
    Name(n) der Zieldatenbank(en) (Wildcards erlaubt). Ohne Angabe werden alle
    Benutzerdatenbanken verarbeitet (entspricht -All).

.PARAMETER All
    Verarbeitet alle Benutzerdatenbanken (exkl. Systemdatenbanken, nur Online).
    Wird auch implizit verwendet, wenn weder -Database noch -All angegeben wird.

.PARAMETER ShrinkTargetPercent
    Zielgroesse in Prozent der aktuellen Log-Groesse (1-99). Standard: 10.

.PARAMETER MinTargetMB
    Minimale Zielgroesse in MB (Standard: 64 MB).

.PARAMETER ContinueOnError
    Bei Fehler mit naechster Datenbank fortfahren.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (ueberschreibt ContinueOnError).

.PARAMETER Confirm
    Fordert Bestaetigung vor dem Shrink an. Standardmaessig deaktiviert.

.PARAMETER WhatIf
    Zeigt, was passieren wuerde, ohne den Shrink auszufuehren.

.EXAMPLE
    Invoke-sqmLogShrink -Database "MyDB" -ShrinkTargetPercent 20

.EXAMPLE
    Invoke-sqmLogShrink -SqlInstance "SQL01" -All -WhatIf

.NOTES
    Voraussetzungen: dbatools, Invoke-sqmLogging.
    Bei Always On AGs wird automatisch zum Primary umgeleitet.
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
			
			Invoke-sqmLogging -Message "$($targetDatabases.Count) Datenbank(en) zur Verarbeitung." -FunctionName $functionName -Level "INFO"
			
			# ---- 3. Pro Datenbank: Log-Datei shrinken ----
			foreach ($db in $targetDatabases)
			{
				$dbName = $db.Name
				try
				{
					if ($dbName -in $systemDatabases)
					{
						$msg = "Systemdatenbank '$dbName' wird uebersprungen."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
						$results.Add([PSCustomObject]@{
								SqlInstance   = $effectiveInstance
								Database	  = $dbName
								LogFile	      = 'n/a'
								SizeBefore_MB = 0
								TargetSize_MB = 0
								SizeAfter_MB  = 0
								SpaceSaved_MB = 0
								ShrinkPercent = 0
								Status	      = 'Skipped'
								Message	      = $msg
							})
						continue
					}
					
					if ($db.Status -ne 'Normal')
					{
						$msg = "Datenbank '$dbName' ist nicht Online (Status: $($db.Status)). uebersprungen."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
						$results.Add([PSCustomObject]@{
								SqlInstance   = $effectiveInstance
								Database	  = $dbName
								LogFile	      = 'n/a'
								SizeBefore_MB = 0
								TargetSize_MB = 0
								SizeAfter_MB  = 0
								SpaceSaved_MB = 0
								ShrinkPercent = 0
								Status	      = 'Skipped'
								Message	      = $msg
							})
						continue
					}
					
					$logFiles = Get-DbaDbFile @connParams -Database $dbName -ErrorAction Stop |
					Where-Object { $_.TypeDescription -eq 'LOG' }
					
					if (-not $logFiles)
					{
						$msg = "Keine Log-Datei fuer Datenbank '$dbName' gefunden."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
						$results.Add([PSCustomObject]@{
								SqlInstance   = $effectiveInstance
								Database	  = $dbName
								LogFile	      = 'n/a'
								SizeBefore_MB = 0
								TargetSize_MB = 0
								SizeAfter_MB  = 0
								SpaceSaved_MB = 0
								ShrinkPercent = 0
								Status	      = 'Skipped'
								Message	      = $msg
							})
						continue
					}
					
					foreach ($logFile in $logFiles)
					{
						$logFileName = $logFile.LogicalName
						$sizeBefore = [math]::Round($logFile.Size.Megabyte, 2)
						$targetByPct = [math]::Round($sizeBefore * ($ShrinkTargetPercent / 100), 0)
						$targetSizeMB = [math]::Max($targetByPct, $MinTargetMB)
						
						Invoke-sqmLogging -Message "[$dbName / $logFileName] Groesse: ${sizeBefore} MB ? Ziel: ${targetSizeMB} MB ($ShrinkTargetPercent%, Min: ${MinTargetMB} MB)" -FunctionName $functionName -Level "VERBOSE"
						
						if ($targetSizeMB -ge $sizeBefore)
						{
							$msg = "Log-Datei '$logFileName' ist bereits ${sizeBefore} MB - Zielgroesse ${targetSizeMB} MB erreicht oder ueberschritten. Kein Shrink erforderlich."
							Invoke-sqmLogging -Message "[$dbName] $msg" -FunctionName $functionName -Level "VERBOSE"
							$results.Add([PSCustomObject]@{
									SqlInstance   = $effectiveInstance
									Database	  = $dbName
									LogFile	      = $logFileName
									SizeBefore_MB = $sizeBefore
									TargetSize_MB = $targetSizeMB
									SizeAfter_MB  = $sizeBefore
									SpaceSaved_MB = 0
									ShrinkPercent = 0
									Status	      = 'NoChangeNeeded'
									Message	      = $msg
								})
							continue
						}
						
						$actionMsg = "DBCC SHRINKFILE auf '$logFileName' von ${sizeBefore} MB auf ${targetSizeMB} MB"
						if ($PSCmdlet.ShouldProcess("$effectiveInstance / $dbName / $logFileName", $actionMsg))
						{
							try
							{
								$shrinkQuery = "DBCC SHRINKFILE (N'$logFileName', $targetSizeMB) WITH NO_INFOMSGS;"
								Invoke-DbaQuery @connParams -Database $dbName -Query $shrinkQuery -EnableException
								
								$logFileAfter = Get-DbaDbFile @connParams -Database $dbName -ErrorAction Stop |
								Where-Object { $_.LogicalName -eq $logFileName }
								$sizeAfter = [math]::Round($logFileAfter.Size.Megabyte, 2)
								$spaceSaved = [math]::Round($sizeBefore - $sizeAfter, 2)
								$shrinkPct = if ($sizeBefore -gt 0) { [math]::Round((($sizeBefore - $sizeAfter) / $sizeBefore) * 100, 1) }
								else { 0 }
								
								$msg = "SHRINKFILE abgeschlossen: ${sizeBefore} MB ? ${sizeAfter} MB (${spaceSaved} MB / ${shrinkPct}% Reduktion)."
								if ($sizeAfter -gt $targetSizeMB)
								{
									$msg += " Zielgroesse ${targetSizeMB} MB wurde nicht erreicht (aktive VLFs verhindern weitere Verkleinerung)."
								}
								Invoke-sqmLogging -Message "[$dbName / $logFileName] $msg" -FunctionName $functionName -Level "INFO"
								$results.Add([PSCustomObject]@{
										SqlInstance   = $effectiveInstance
										Database	  = $dbName
										LogFile	      = $logFileName
										SizeBefore_MB = $sizeBefore
										TargetSize_MB = $targetSizeMB
										SizeAfter_MB  = $sizeAfter
										SpaceSaved_MB = $spaceSaved
										ShrinkPercent = $shrinkPct
										Status	      = 'Shrunk'
										Message	      = $msg
									})
							}
							catch
							{
								$errMsg = "Fehler beim Shrink: $($_.Exception.Message)"
								Invoke-sqmLogging -Message "[$dbName / $logFileName] $errMsg" -FunctionName $functionName -Level "ERROR"
								if ($EnableException) { throw }
								$results.Add([PSCustomObject]@{
										SqlInstance   = $effectiveInstance
										Database	  = $dbName
										LogFile	      = $logFileName
										SizeBefore_MB = $sizeBefore
										TargetSize_MB = $targetSizeMB
										SizeAfter_MB  = $sizeBefore
										SpaceSaved_MB = 0
										ShrinkPercent = 0
										Status	      = 'Failed'
										Message	      = $errMsg
									})
								if (-not $ContinueOnError) { throw }
							}
						}
						else
						{
							$msg = "WhatIf: Shrink uebersprungen."
							Invoke-sqmLogging -Message "[$dbName / $logFileName] $msg" -FunctionName $functionName -Level "VERBOSE"
							$results.Add([PSCustomObject]@{
									SqlInstance   = $effectiveInstance
									Database	  = $dbName
									LogFile	      = $logFileName
									SizeBefore_MB = $sizeBefore
									TargetSize_MB = $targetSizeMB
									SizeAfter_MB  = $sizeBefore
									SpaceSaved_MB = 0
									ShrinkPercent = 0
									Status	      = 'WhatIfSkipped'
									Message	      = "WhatIf: Shrink wuerde ausgefuehrt werden."
								})
						}
					}
				}
				catch
				{
					$errMsg = "Fehler bei Datenbank '$dbName': $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					$results.Add([PSCustomObject]@{
							SqlInstance   = $effectiveInstance
							Database	  = $dbName
							LogFile	      = 'n/a'
							SizeBefore_MB = 0
							TargetSize_MB = 0
							SizeAfter_MB  = 0
							SpaceSaved_MB = 0
							ShrinkPercent = 0
							Status	      = 'Failed'
							Message	      = $errMsg
						})
					if ($EnableException) { throw }
					if (-not $ContinueOnError) { throw }
				}
			}
			
			$cntShrunk = ($results | Where-Object Status -eq 'Shrunk').Count
			$cntNoChange = ($results | Where-Object Status -eq 'NoChangeNeeded').Count
			$cntSkipped = ($results | Where-Object Status -eq 'Skipped').Count
			$cntFailed = ($results | Where-Object Status -eq 'Failed').Count
			$totalSaved = [math]::Round(($results | Measure-Object SpaceSaved_MB -Sum).Sum, 2)
			Invoke-sqmLogging -Message "$functionName abgeschlossen. Shrunk: $cntShrunk, NoChange: $cntNoChange, Skipped: $cntSkipped, Failed: $cntFailed, Gesamt eingespart: ${totalSaved} MB" -FunctionName $functionName -Level "INFO"
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