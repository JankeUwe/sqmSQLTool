<#
.SYNOPSIS
    Interne Datei- und Log-Pruefung der TDP-Backup-Loesung (ohne SQL-Zugriff).

.DESCRIPTION
    Gemeinsamer Baustein von Test-sqmTdpBackup und Test-sqmTdpConfiguration. Liest BackupPlan.json,
    prueft TDP-/TSM-Dateien, den Wrapper und wertet Wrapper-, Datenbank- und tdpsql.log aus.
    Gibt die Befunde und die ausgewerteten Planwerte zurueck.
#>
function Invoke-sqmTdpFileCheck
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Instance,
		[Parameter(Mandatory = $true)]
		[string]$TdpDir,
		[Parameter(Mandatory = $true)]
		[string]$ConfigPath,
		[Parameter(Mandatory = $true)]
		[string]$HostName,
		[Parameter(Mandatory = $true)]
		[bool]$IsLocal,
		[Parameter(Mandatory = $true)]
		[datetime]$Now,
		[Parameter(Mandatory = $false)]
		[int]$LogFilesToScan = 5,
		[Parameter(Mandatory = $false)]
		[switch]$TestTsmServer,
		[Parameter(Mandatory = $false)]
		[int]$LogDays = 7
	)

	$instance = $Instance
	$hostName = $HostName
	$isLocal = $IsLocal
	$now = $Now
	$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

			# Bekannte TSM/TDP-Meldungen mit Handlungshinweis (nur gesicherte Zuordnungen)
			$knownCodes = @{
				'ANS1017E' = 'Session rejected: TCP/IP-Verbindung zum TSM-Server fehlgeschlagen - Netzwerk, Firewall, TCPServeraddress/TCPPort in dsm.opt, TSM-Server pruefen.'
				'ANS1025E' = 'Session rejected: Authentifizierung fehlgeschlagen - Nodepasswort (abgelaufen/falsch) in TdpBackup.config bzw. am TSM-Server pruefen.'
				'ANS1035S' = 'Optionsdatei nicht gefunden oder fehlerhaft - Pfad (TsmOptFile) und Syntax der dsm.opt pruefen.'
			}

		function _Fmt
		{
			param ($Value)
			if ($null -eq $Value) { return '' }
			return $Value.ToString('yyyy-MM-dd HH:mm')
		}
		function _Short
		{
			param ($Text, [int]$Max = 300)
			$t = ([string]$Text -replace '\s+', ' ').Trim()
			if ($t.Length -gt $Max) { return $t.Substring(0, $Max - 3) + '...' }
			return $t
		}
		# Laengste Luecke (in Tagen) zwischen zwei Backup-Tagen der Woche, zyklisch gerechnet

		function _ParseLogTime
		{
			param ([string]$Line)
			if ($Line -notmatch '^\s*(\d{1,4}[./-]\d{1,2}[./-]\d{1,4})\s+(\d{1,2}:\d{2}:\d{2})') { return $null }
			$stamp = "$($Matches[1]) $($Matches[2])"
			$formats = [string[]]@('MM/dd/yyyy HH:mm:ss', 'dd.MM.yyyy HH:mm:ss', 'dd/MM/yyyy HH:mm:ss', 'yyyy-MM-dd HH:mm:ss', 'yyyy/MM/dd HH:mm:ss')
			$parsed = [datetime]::MinValue
			if ([datetime]::TryParseExact($stamp, $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
			return $null
		}
		# Sucht ANSxxxxE/S, ACNxxxxE/S, ACOxxxxE/S-Meldungen in den letzten Zeilen einer Logdatei
		function _ScanLogCodes
		{
			param ([string]$Path, [datetime]$Since, [datetime]$FileTime, [int]$Tail = 3000)
			$hits = @{ }
			foreach ($line in @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop))
			{
				if ($line -notmatch '\b((?:ANS|ACN|ACO)\d{4}[ES])\b') { continue }
				$code = $Matches[1]
				$t = _ParseLogTime $line
				if ($null -ne $t) { if ($t -lt $Since) { continue } }
				elseif ($FileTime -lt $Since) { continue }
				if (-not $hits.ContainsKey($code)) { $hits[$code] = [PSCustomObject]@{ Code = $code; Count = 0; Last = $null; Line = $null } }
				$hits[$code].Count++
				$hits[$code].Line = $line
				if ($null -ne $t) { $hits[$code].Last = $t }
			}
			return @($hits.Values)
		}


	function _Add
	{
		param ([string]$Severity, [string]$Category, [string]$Message, [string]$Hint = '', [string]$Database = '')
		$findings.Add([PSCustomObject]@{
				SqlInstance = $instance
				Severity    = $Severity
				Category    = $Category
				Database    = $Database
				Message     = $Message
				Hint        = $Hint
			})
	}
	function _P
	{
		param ([string]$LocalPath)
		if ($isLocal) { return $LocalPath }
		return (_ToUncPath -ComputerName $hostName -LocalPath $LocalPath)
	}

			# ------------------------------------------------------------------ BackupPlan.json (fuer Grenzen und Abgleich)
			$plan = $null
			$planFile = _P $ConfigPath
			$planOk = $false
			if (-not (Test-Path -LiteralPath $planFile))
			{
				_Add 'Critical' 'Datei' "BackupPlan.json nicht gefunden: $ConfigPath" 'Setup-TdpBackup.ps1 / Configure-BackupPlan.ps1 ausfuehren; ohne Plan bricht Backup-TdpFull.ps1 ab.'
			}
			else
			{
				try
				{
					$plan = Get-Content -LiteralPath $planFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
					$planOk = $true
				}
				catch
				{
					_Add 'Critical' 'Datei' "BackupPlan.json nicht lesbar (kein gueltiges JSON): $($_.Exception.Message)" 'JSON-Syntax korrigieren (Komma, Anfuehrungszeichen, Backslashes als \\ schreiben).'
				}
			}

			$fullDays = @(); $diffDays = @(); $jsonDbs = @(); $jsonExcluded = @()
			if ($planOk)
			{
				if ($plan.PSObject.Properties['Schedule'] -and $plan.Schedule)
				{
					if ($plan.Schedule.PSObject.Properties['FullBackupDays']) { $fullDays = @($plan.Schedule.FullBackupDays) }
					if ($plan.Schedule.PSObject.Properties['DifferentialBackupDays']) { $diffDays = @($plan.Schedule.DifferentialBackupDays) }
				}
				if ($plan.PSObject.Properties['SelectedDatabases'] -and $plan.SelectedDatabases) { $jsonDbs = @($plan.SelectedDatabases) }
				if ($plan.PSObject.Properties['ExcludedDatabases'] -and $plan.ExcludedDatabases) { $jsonExcluded = @($plan.ExcludedDatabases) }

				$validDays = [System.Enum]::GetNames([DayOfWeek])
				$badDays = @(@($fullDays) + @($diffDays) | Where-Object { $_ -and ([string]$_ -notin $validDays) })
				if ($badDays.Count -gt 0)
				{
					_Add 'Critical' 'Plan' "Ungueltige Wochentage im Plan: $($badDays -join ', ')" 'Englische Namen verwenden (Sunday ... Saturday); sonst wird an diesen Tagen nie gesichert.'
				}
				if ($fullDays.Count -eq 0)
				{
					_Add 'Critical' 'Plan' 'Im Plan ist kein FULL-Tag konfiguriert (Schedule.FullBackupDays leer)' 'Mindestens einen FULL-Tag eintragen; ohne FULL gibt es keine Basis fuer Differentials.'
				}
				if ($jsonDbs.Count -eq 0)
				{
					_Add 'Critical' 'Plan' 'Im Plan sind keine Datenbanken ausgewaehlt (SelectedDatabases leer)' 'Datenbanken mit Configure-BackupPlan.ps1 eintragen.'
				}
				$dupes = @($jsonDbs | Group-Object { ([string]$_.Name).ToLowerInvariant() } | Where-Object Count -gt 1 | ForEach-Object { $_.Group[0].Name })
				if ($dupes.Count -gt 0)
				{
					_Add 'Warning' 'Plan' "Datenbank mehrfach im Plan: $($dupes -join ', ')" 'Doppelte Eintraege entfernen (TDP_BackupPlan.DatabaseName ist UNIQUE, der Sync kann scheitern).'
				}
				$placeholders = [System.Collections.Generic.List[string]]::new()
				if ($plan.PSObject.Properties['Configuration'] -and $plan.Configuration)
				{
					foreach ($prop in $plan.Configuration.PSObject.Properties)
					{
						if ([string]$prop.Value -match '<[^>]+>') { $placeholders.Add($prop.Name) }
					}
				}
				if ($placeholders.Count -gt 0)
				{
					_Add 'Critical' 'Plan' "Platzhalter im Plan nicht ersetzt: $($placeholders -join ', ')" 'Echte Werte eintragen (z. B. <SQLInstance> durch den Instanznamen ersetzen).'
				}
			}

			# ------------------------------------------------------------------ Dateien und Logs
			$optLocal = $null; $cfgLocal = $null; $logLocal = $null
			if ($planOk -and $plan.PSObject.Properties['Configuration'] -and $plan.Configuration)
			{
				$c = $plan.Configuration
				if ($c.PSObject.Properties['TsmOptFile'] -and $c.TsmOptFile) { $optLocal = [string]$c.TsmOptFile }
				if ($c.PSObject.Properties['TdpConfigFile'] -and $c.TdpConfigFile) { $cfgLocal = [string]$c.TdpConfigFile }
				if ($c.PSObject.Properties['LogPath'] -and $c.LogPath) { $logLocal = [string]$c.LogPath }
			}
			if (-not $optLocal) { $optLocal = Join-Path $TdpDir 'dsm.opt' }
			if (-not $cfgLocal) { $cfgLocal = Join-Path $TdpDir 'tdpsql.cfg' }
			if (-not $logLocal) { $logLocal = Join-Path $TdpDir '03_Log' }

			$tdpDirP = _P $TdpDir
			if (-not (Test-Path -LiteralPath $tdpDirP))
			{
				_Add 'Critical' 'Datei' "TDP-Verzeichnis nicht erreichbar: $TdpDir$(if (-not $isLocal) { " (als $tdpDirP auf $hostName)" })" 'Pfad (-TdpDir) pruefen; bei Remote-Instanzen muss die Admin-Freigabe erreichbar sein.'
			}
			else
			{
				foreach ($f in @(@{ P = (Join-Path $TdpDir 'tdpsqlc.exe'); What = 'tdpsqlc.exe (TDP-Client)'; Sev = 'Critical' }, @{ P = $optLocal; What = 'dsm.opt (TSM-Optionsdatei)'; Sev = 'Critical' }, @{ P = $cfgLocal; What = 'tdpsql.cfg (TDP-Konfiguration)'; Sev = 'Critical' }, @{ P = (Join-Path $TdpDir 'TdpBackup.config'); What = 'TdpBackup.config (Systemkonfiguration mit Passwort)'; Sev = 'Critical' }))
				{
					if (-not (Test-Path -LiteralPath (_P $f.P)))
					{
						_Add $f.Sev 'Datei' "$($f.What) fehlt: $($f.P)" 'TDP-Installation bzw. Setup-TdpBackup.ps1 pruefen; ohne diese Datei scheitert jedes Backup.'
					}
				}

				$cmdPath = Join-Path $TdpDir '01_Backup_CMD\Backup_TdpFull.cmd'
				if (Test-Path -LiteralPath (_P $cmdPath))
				{
					$cmdText = Get-Content -LiteralPath (_P $cmdPath) -Raw -ErrorAction SilentlyContinue
					if ($cmdText -and $cmdText -notmatch 'exit\s+/b\s+%')
					{
						_Add 'Critical' 'Datei' 'Backup_TdpFull.cmd gibt den Exit-Code nicht an den Agent zurueck (kein "exit /b %...%")' 'Ohne Exit-Code meldet der Job immer Erfolg - Fehler bleiben unbemerkt. Letzte Zeile "exit /b %PowerShellExitCode%" ergaenzen.'
					}
					if ($cmdText -match '(?im)^\s*SET\s+BackupScriptsDir=(.+)$')
					{
						$bsd = $Matches[1].Trim() -replace '%TdpDir%', $TdpDir
						$bsdP = _P $bsd
						if ($bsd -notmatch '%' -and -not (Test-Path -LiteralPath (Join-Path $bsdP 'Backup-TdpFull.ps1')))
						{
							_Add 'Critical' 'Datei' "Backup-TdpFull.ps1 nicht gefunden unter $bsd (BackupScriptsDir im Wrapper)" 'Skriptpfad im Wrapper anpassen bzw. die Skripte dort ablegen; der Job startet sonst ins Leere.'
						}
						elseif ($bsd -match '\.\.')
						{
							$resolved = try { [System.IO.Path]::GetFullPath($bsdP) } catch { $null }
							if ($resolved -and -not (Test-Path -LiteralPath (Join-Path $resolved 'Backup-TdpFull.ps1')))
							{
								_Add 'Critical' 'Datei' "Backup-TdpFull.ps1 nicht gefunden unter $bsd (aufgeloest: $resolved)" 'Relativer Pfad im Wrapper zeigt ins Leere - auf den echten Skriptordner setzen.'
							}
						}
					}
				}
				else
				{
					_Add 'Warning' 'Datei' "Wrapper nicht gefunden: $cmdPath" 'Nur relevant, wenn der Job-Step diesen Pfad verwendet (siehe Agent-Befunde).'
				}

				# dsm.opt auswerten
				$optP = _P $optLocal
				$tsmHost = $null; $tsmPort = 1500
				if (Test-Path -LiteralPath $optP)
				{
					foreach ($line in @(Get-Content -LiteralPath $optP -ErrorAction SilentlyContinue))
					{
						if ($line -match '^\s*TCPS(?:ERVERADDRESS)?\s+(\S+)') { $tsmHost = $Matches[1] }
						elseif ($line -match '^\s*TCPP(?:ORT)?\s+(\d+)') { $tsmPort = [int]$Matches[1] }
					}
					if (-not $tsmHost)
					{
						_Add 'Critical' 'Datei' "In $optLocal ist keine TCPServeraddress eingetragen" 'TCPServeraddress (und ggf. TCPPort) des TSM-Servers ergaenzen.'
					}
				}
				if ($tsmHost)
				{
					if ($TestTsmServer -and $isLocal)
					{
						$tcp = New-Object System.Net.Sockets.TcpClient
						try
						{
							$ar = $tcp.BeginConnect($tsmHost, $tsmPort, $null, $null)
							if ($ar.AsyncWaitHandle.WaitOne(4000) -and $tcp.Connected)
							{
								$tcp.EndConnect($ar)
								_Add 'Info' 'TSM-Server' "TSM-Server $tsmHost`:$tsmPort ist per TCP erreichbar"
							}
							else
							{
								_Add 'Critical' 'TSM-Server' "TSM-Server $tsmHost`:$tsmPort ist nicht erreichbar (Timeout)" 'Netzwerk, Firewall, TCPServeraddress/TCPPort und Dienst auf dem TSM-Server pruefen (entspricht ANS1017E).'
							}
						}
						catch
						{
							_Add 'Critical' 'TSM-Server' "TSM-Server $tsmHost`:$tsmPort nicht erreichbar: $($_.Exception.Message)" 'Namensaufloesung, Netzwerk und Firewall pruefen.'
						}
						finally { $tcp.Close() }
					}
					elseif ($TestTsmServer)
					{
						_Add 'Info' 'TSM-Server' "TSM-Server-Test uebersprungen: nur auf dem lokalen Computer moeglich (Instanz laeuft auf $hostName)"
					}
				}

				# Logs
				$since = $now.AddDays(-$LogDays)
				$logDirP = _P $logLocal
				if (-not (Test-Path -LiteralPath $logDirP))
				{
					_Add 'Warning' 'Log' "Log-Verzeichnis fehlt: $logLocal" 'Wird vom Wrapper angelegt; fehlt es, ist der Job noch nie bis dorthin gekommen.'
				}
				else
				{
					$wrapLogs = @(Get-ChildItem -LiteralPath $logDirP -Filter 'Backup_TdpFull_*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $LogFilesToScan)
					if ($wrapLogs.Count -eq 0)
					{
						_Add 'Warning' 'Log' "Keine Wrapper-Logs (Backup_TdpFull_*.log) in $logLocal" 'Der Wrapper hat noch nie geloggt - Job lief nie bis dorthin.'
					}
					$first = $true
					foreach ($wl in $wrapLogs)
					{
						try { $txt = (Get-Content -LiteralPath $wl.FullName -Tail 400 -ErrorAction Stop) -join "`n" } catch { continue }
						$sev = if ($first) { 'Critical' } else { 'Warning' }
						if ($txt -match 'TDP Backup FAILED')
						{
							$exit = if ($txt -match 'ExitCode:\s*(\d+)') { $Matches[1] } else { '?' }
							$errLine = @($txt -split "`n" | Where-Object { $_ -match 'FAILED|ERROR|Exception|Fehler' } | Select-Object -Last 1)
							_Add $sev 'Log' "Wrapper-Log $($wl.Name) endet mit FAILED (ExitCode $exit)$(if ($errLine.Count -gt 0) { ': ' + (_Short $errLine[0] 250) })" "Ganzes Log lesen: $($wl.FullName)"
						}
						elseif ($txt -notmatch 'COMPLETED SUCCESSFULLY' -and ($now - $wl.LastWriteTime).TotalHours -gt 12)
						{
							_Add 'Warning' 'Log' "Wrapper-Log $($wl.Name) ist unvollstaendig (weder FAILED noch COMPLETED) - Lauf abgebrochen oder haengt" 'Agent-Verlauf und Prozessliste (tdpsqlc.exe) ansehen.'
						}
						$first = $false
					}

					# Per-DB-TDP-Logs (backup_FULL_<db>_*.log / backup_DIFF_*) der letzten Tage
					$dbLogs = @(Get-ChildItem -LiteralPath $logDirP -Filter 'backup_*_*.log' -File -ErrorAction SilentlyContinue |
						Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending | Select-Object -First ($LogFilesToScan * 4))
					$codeAgg = @{ }
					foreach ($dl in $dbLogs)
					{
						try { $hits = @(_ScanLogCodes -Path $dl.FullName -Since $since -FileTime $dl.LastWriteTime -Tail 1500) } catch { continue }
						foreach ($h in $hits)
						{
							if (-not $codeAgg.ContainsKey($h.Code)) { $codeAgg[$h.Code] = [PSCustomObject]@{ Code = $h.Code; Count = 0; Files = [System.Collections.Generic.List[string]]::new(); Line = $h.Line } }
							$codeAgg[$h.Code].Count += $h.Count
							$codeAgg[$h.Code].Files.Add($dl.Name)
						}
					}
					foreach ($ca in ($codeAgg.Values | Sort-Object Code))
					{
						$sev = if ($ca.Code.EndsWith('S')) { 'Critical' } else { 'Warning' }
						$hint = if ($knownCodes.ContainsKey($ca.Code)) { $knownCodes[$ca.Code] } else { 'Meldung in der IBM-Dokumentation nachschlagen (Meldungs-ID suchen).' }
						_Add $sev 'Log' "Meldung $($ca.Code) in $($ca.Files.Count) TDP-Log(s) der letzten $LogDays Tage ($($ca.Count)x): $(_Short $ca.Line 220)" $hint
					}
				}

				# tdpsql.log (LOGFile aus tdpsql.cfg)
				$cfgP = _P $cfgLocal
				if (Test-Path -LiteralPath $cfgP)
				{
					$tdpLogName = $null
					foreach ($line in @(Get-Content -LiteralPath $cfgP -ErrorAction SilentlyContinue))
					{
						if ($line -match '^\s*LOGFile\s+(.+?)\s*$') { $tdpLogName = $Matches[1].Trim('"') }
					}
					if ($tdpLogName)
					{
						$tdpLogLocal = if ($tdpLogName -match '^[A-Za-z]:\\|^\\\\') { $tdpLogName } else { Join-Path $TdpDir $tdpLogName }
						$tdpLogP = _P $tdpLogLocal
						if (Test-Path -LiteralPath $tdpLogP)
						{
							$fi = Get-Item -LiteralPath $tdpLogP
							try
							{
								foreach ($h in @(_ScanLogCodes -Path $tdpLogP -Since $since -FileTime $fi.LastWriteTime -Tail 3000 | Sort-Object Code))
								{
									$sev = if ($h.Code.EndsWith('S')) { 'Critical' } else { 'Warning' }
									$hint = if ($knownCodes.ContainsKey($h.Code)) { $knownCodes[$h.Code] } else { 'Meldung in der IBM-Dokumentation nachschlagen (Meldungs-ID suchen).' }
									$when = if ($h.Last) { ", zuletzt $(_Fmt $h.Last)" } else { '' }
									_Add $sev 'Log' "Meldung $($h.Code) in $(Split-Path $tdpLogLocal -Leaf) ($($h.Count)x$when): $(_Short $h.Line 220)" $hint
								}
							}
							catch { _Add 'Info' 'Log' "tdpsql.log nicht lesbar: $($_.Exception.Message)" }
						}
					}
				}
			}

	return [PSCustomObject]@{
		Findings          = $findings
		PlanOk            = $planOk
		Plan              = $plan
		FullDays          = @($fullDays)
		DiffDays          = @($diffDays)
		JsonDatabases     = @($jsonDbs)
		JsonExcluded      = @($jsonExcluded)
	}
}
