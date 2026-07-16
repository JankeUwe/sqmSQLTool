<#
.SYNOPSIS
    Determines the last known access per SQL Server login.

.DESCRIPTION
    SQL Server does not persist a "last login" timestamp anywhere. This function
    therefore collects what the instance can actually prove and reports the
    source and the confidence for every value instead of guessing.

    Sources (combined, newest value wins):

      Live      sys.dm_exec_sessions - only sessions that exist right now.
                Wiped by every service restart, so it can never look further
                back than sqlserver_start_time (reported as CoverageSince).

      ErrorLog  Successful login messages in the SQL Server error log. Only
                available when the 'AuditLevel' registry value is 1 (successful)
                or 3 (all); the default is 2 (failed only), which records
                nothing usable here. Limited by error log rotation.

    A login with no data gets LastAccess = $null, Source = 'None' and
    Confidence = 'Unknown'. That means "not provable", NOT "never used" - the
    distinction matters and is deliberately not collapsed.

    The error log parser is language neutral: the message templates for 18453 /
    18454 are read from sys.messages and turned into regular expressions. This
    is required because the wording and even the quoting differ per language
    (English: user 'x', German: Benutzer "x").

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential.

.PARAMETER Login
    Filter: only these logins (wildcards allowed). Default: all.

.PARAMETER ExcludeSystemLogins
    Hide NT SERVICE\*, NT AUTHORITY\* (incl. localized variants) and ##MS_*##.

.PARAMETER Source
    Which sources to query: 'All' (default), 'Live', 'ErrorLog'.

.PARAMETER OutputPath
    If specified, CSV and HTML reports are written. Default: no export.

.PARAMETER ContinueOnError
    Continue on error for an instance.

.PARAMETER EnableException
    Throw exceptions immediately.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.EXAMPLE
    Get-sqmLoginLastAccess -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmLoginLastAccess -SqlInstance "SQL01" -Source Live -ExcludeSystemLogins

.EXAMPLE
    Get-sqmLoginLastAccess -SqlInstance "SQL01" | Where-Object Confidence -eq 'Unknown'

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE; the ErrorLog source additionally needs
    securityadmin or sysadmin (xp_instance_regread / xp_readerrorlog).

    Windows GROUP logins usually show no session of their own: a member connects
    with their own AD account, so sys.dm_exec_sessions reports the account, not
    the group. Such logins are marked with a Note.
#>
function Get-sqmLoginLastAccess
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$Login = @(),

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[ValidateSet('All', 'Live', 'ErrorLog')]
		[string]$Source = 'All',

		[Parameter(Mandatory = $false)]
		[string]$OutputPath,

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
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$sysLoginPatterns = @('NT SERVICE\*', 'NT AUTHORITY\*', 'NT-AUTORIT*\*', '##MS_*##')

		function _MatchesAny
		{
			param ([string]$Name,
				[string[]]$Patterns)
			if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}

		Invoke-sqmLogging -Message "Starte $functionName (Source=$Source)" -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			try
			{
				$connParams = @{ SqlInstance = $instance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				# --- Logins -----------------------------------------------------
				$loginQuery = @"
SELECT
    name COLLATE DATABASE_DEFAULT       AS LoginName,
    type_desc COLLATE DATABASE_DEFAULT  AS LoginType,
    is_disabled                         AS IsDisabled,
    create_date                         AS CreateDate
FROM sys.server_principals
WHERE type IN ('S','U','G')
"@
				$loginRows = Invoke-DbaQuery @connParams -Database master -Query $loginQuery -EnableException:$EnableException

				$logins = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($row in $loginRows)
				{
					if ($ExcludeSystemLogins -and (_MatchesAny $row.LoginName $sysLoginPatterns)) { continue }
					if ($Login.Count -gt 0 -and -not (_MatchesAny $row.LoginName $Login)) { continue }
					$logins.Add($row)
				}

				if ($logins.Count -eq 0)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Logins nach Filterung." -FunctionName $functionName -Level 'WARNING'
					continue
				}

				# --- Startzeit der Instanz = Grenze der Live-Quelle --------------
				# ServerNow bewusst vom Server, nicht per Get-Date: alle Zeitstempel
				# stammen aus SQL Server. Gegen die Uhr des Clients gerechnet wuerde
				# schon geringer Zeitversatz negative Werte in DaysSince erzeugen.
				$timeRow = Invoke-DbaQuery @connParams -Database master -Query "SELECT sqlserver_start_time AS StartTime, GETDATE() AS ServerNow FROM sys.dm_os_sys_info" -EnableException:$EnableException
				$startTime = $timeRow.StartTime
				$serverNow = $timeRow.ServerNow

				# --- Quelle: Live (dm_exec_sessions) ----------------------------
				# Key = Loginname (lower), Value = letzter Zeitpunkt
				$liveMap = @{ }
				$sessionMap = @{ }
				if ($Source -in @('All', 'Live'))
				{
					$sessQuery = @"
SELECT
    login_name COLLATE DATABASE_DEFAULT                 AS LoginName,
    MAX(login_time)                                     AS LastLogin,
    MAX(last_request_end_time)                          AS LastRequest,
    COUNT(*)                                            AS Sessions
FROM sys.dm_exec_sessions
GROUP BY login_name
"@
					$sessRows = Invoke-DbaQuery @connParams -Database master -Query $sessQuery -EnableException:$EnableException
					foreach ($row in $sessRows)
					{
						$key = ([string]$row.LoginName).ToLowerInvariant()
						$candidates = @($row.LastLogin, $row.LastRequest) |
							Where-Object { $_ -and $_ -isnot [DBNull] -and $_ -is [datetime] }
						if ($candidates.Count -eq 0) { continue }
						$liveMap[$key]    = ($candidates | Measure-Object -Maximum).Maximum
						$sessionMap[$key] = [int]$row.Sessions
					}
					Invoke-sqmLogging -Message "[$instance] Live-Quelle: $($liveMap.Count) Login(s) mit aktiver Session seit $startTime." -FunctionName $functionName -Level 'INFO'
				}

				# --- Quelle: ErrorLog -------------------------------------------
				$logMap       = @{ }
				$auditLevel   = $null
				$logAvailable = $false
				if ($Source -in @('All', 'ErrorLog'))
				{
					try
					{
						$auditQuery = @"
DECLARE @audit INT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'AuditLevel', @audit OUTPUT;
SELECT ISNULL(@audit, 0) AS AuditLevel;
"@
						$auditRow   = Invoke-DbaQuery @connParams -Database master -Query $auditQuery -EnableException -ErrorAction Stop
						$auditLevel = [int]$auditRow.AuditLevel
					}
					catch
					{
						Invoke-sqmLogging -Message "[$instance] AuditLevel nicht lesbar (Rechte?): $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
					}

					# 1 = nur erfolgreiche, 3 = alle. 0/2 protokollieren keine Erfolge.
					if ($auditLevel -in @(1, 3))
					{
						$logAvailable = $true

						# Vorlagen aller Sprachen holen und in Regex wandeln
						$msgRows = Invoke-DbaQuery @connParams -Database master -Query "SELECT text FROM sys.messages WHERE message_id IN (18453, 18454)" -EnableException:$EnableException
						$regexes = [System.Collections.Generic.List[string]]::new()
						foreach ($m in $msgRows)
						{
							$rx = ConvertTo-sqmMessageRegex -Template ([string]$m.text)
							if ($rx) { $regexes.Add($rx) }
						}

						if ($regexes.Count -eq 0)
						{
							Invoke-sqmLogging -Message "[$instance] Keine verwertbare Meldungsvorlage (18453/18454) gefunden - ErrorLog-Quelle uebersprungen." -FunctionName $functionName -Level 'WARNING'
							$logAvailable = $false
						}
						else
						{
							$logRows = Get-DbaErrorLog @connParams -ErrorAction Stop
							foreach ($entry in $logRows)
							{
								$text = [string]$entry.Text
								if ([string]::IsNullOrWhiteSpace($text)) { continue }

								foreach ($rx in $regexes)
								{
									$m = [regex]::Match($text, $rx)
									if (-not $m.Success) { continue }

									$user = $m.Groups[1].Value
									$key  = $user.ToLowerInvariant()
									$when = $entry.LogDate
									if ($when -and (-not $logMap.ContainsKey($key) -or $when -gt $logMap[$key]))
									{
										$logMap[$key] = $when
									}
									break
								}
							}
							Invoke-sqmLogging -Message "[$instance] ErrorLog-Quelle: $($logMap.Count) Login(s) mit protokolliertem Anmeldeereignis." -FunctionName $functionName -Level 'INFO'
						}
					}
					else
					{
						Invoke-sqmLogging -Message "[$instance] AuditLevel=$auditLevel - erfolgreiche Anmeldungen werden nicht protokolliert, ErrorLog-Quelle liefert nichts." -FunctionName $functionName -Level 'INFO'
					}
				}

				# --- Zusammenfuehren ---------------------------------------------
				foreach ($lg in $logins)
				{
					$key = ([string]$lg.LoginName).ToLowerInvariant()

					$live = if ($liveMap.ContainsKey($key)) { $liveMap[$key] } else { $null }
					$log  = if ($logMap.ContainsKey($key)) { $logMap[$key] } else { $null }

					$lastAccess = $null
					$src        = 'None'
					$confidence = 'Unknown'

					if ($live -and $log)
					{
						if ($live -ge $log) { $lastAccess = $live; $src = 'Live' }
						else { $lastAccess = $log; $src = 'ErrorLog' }
						$confidence = 'Exact'
					}
					elseif ($live)
					{
						$lastAccess = $live
						$src        = 'Live'
						$confidence = 'Exact'
					}
					elseif ($log)
					{
						$lastAccess = $log
						$src        = 'ErrorLog'
						$confidence = 'Exact'
					}

					# Note: erklaert, warum kein Wert da ist bzw. was er nicht bedeutet
					$note = ''
					if (-not $lastAccess)
					{
						if ($lg.LoginType -eq 'WINDOWS_GROUP')
						{
							$note = 'Gruppenlogin - Mitglieder verbinden sich mit ihrem eigenen AD-Konto, Sessions werden nicht der Gruppe zugeordnet.'
						}
						elseif (-not $logAvailable)
						{
							$note = "Keine belastbare Quelle: nur Live-Sessions ab $startTime auswertbar (AuditLevel=$auditLevel protokolliert keine erfolgreichen Anmeldungen). Kein Nachweis ist kein Beleg fuer Nichtnutzung."
						}
						else
						{
							$note = "Kein Anmeldeereignis im vorhandenen ErrorLog und keine aktive Session. Reichweite durch Log-Rotation begrenzt."
						}
					}

					$allResults.Add([PSCustomObject]@{
						SqlInstance   = $instance
						LoginName     = $lg.LoginName
						LoginType     = $lg.LoginType
						IsDisabled    = [bool]$lg.IsDisabled
						CreateDate    = $lg.CreateDate
						LastAccess    = $lastAccess
						DaysSince     = if ($lastAccess) { [math]::Max(0, [math]::Round(($serverNow - $lastAccess).TotalDays, 1)) } else { $null }
						Source        = $src
						Confidence    = $confidence
						ActiveSessions = if ($sessionMap.ContainsKey($key)) { $sessionMap[$key] } else { 0 }
						CoverageSince = $startTime
						ErrorLogUsable = $logAvailable
						Note          = $note
					})
				}

				$known = @($allResults | Where-Object { $_.SqlInstance -eq $instance -and $_.Confidence -ne 'Unknown' }).Count
				Invoke-sqmLogging -Message "[$instance] $($logins.Count) Login(s) geprueft, $known mit belegtem Zugriff, $($logins.Count - $known) ohne Nachweis." -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				$errMsg = "[$instance] Fehler: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		if ($OutputPath -and $allResults.Count -gt 0)
		{
			try
			{
				if (-not (Test-Path $OutputPath))
				{
					New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
				}
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$csvFile = Join-Path $OutputPath "LoginLastAccess_$datestamp.csv"
				$allResults | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
				Invoke-sqmLogging -Message "CSV geschrieben: $csvFile" -FunctionName $functionName -Level 'INFO'

				$htmlFile = Join-Path $OutputPath "LoginLastAccess_$datestamp.html"
				$bodyHtml = ($allResults |
					Select-Object SqlInstance, LoginName, LoginType, IsDisabled, LastAccess, DaysSince, Source, Confidence, ActiveSessions, Note |
					ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "Login Last Access" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

				Copy-sqmToCentralPath -Path $csvFile, $htmlFile
			}
			catch
			{
				Invoke-sqmLogging -Message "Export fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Login(s) gesamt." -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
