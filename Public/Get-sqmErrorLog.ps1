<#
.SYNOPSIS
    Reads and categorizes the SQL Server error log, with convenience filters for the events DBAs
    actually search for.

.DESCRIPTION
    Wraps dbatools' Get-DbaErrorLog and adds what it does not provide on its own: ready-made
    filters for the handful of event types that come up in almost every troubleshooting session,
    instead of everyone re-inventing the same -match pattern.

    Two categories are detected language-neutrally, the same way Get-sqmLoginLastAccess already
    does it: the message templates for 18456 (login failed) and 18453/18454 (login succeeded) are
    read from sys.messages on the target instance and turned into regular expressions, so a German
    or French instance is matched correctly instead of only ever finding the English wording.

    The remaining categories (Backup, Restore, Errors, Shutdown, Startup, CorruptionEvents,
    IOErrors, MemoryPressure, ServiceBrokerEvents) match the well-known English message text SQL
    Server writes for these events. That text is not looked up per-language, because unlike the
    login messages it is not needed elsewhere in this module and a wrong guess at a localized
    string is worse than an honest gap. On a non-English instance, use -Pattern to supply the
    phrase your error log actually contains; -Pattern is combined with any other filter, and works
    standalone with none of the switches set.

    Selecting no category switch and no -Pattern returns every entry, each still labeled with its
    detected Category so the full log stays easy to scan.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential.

.PARAMETER LogNumber
    Which error log file(s) to read: 0 = current (default), 1 = Errorlog.1, 2 = Errorlog.2, etc.
    Accepts multiple values, e.g. -LogNumber 0,1,2 to sweep the current log plus the last two
    archives.

.PARAMETER FailedLogins
    Only failed login attempts (error 18456). Language-neutral detection.

.PARAMETER SuccessfulLogins
    Only successful logins (18453 non-trusted / 18454 trusted connection). Language-neutral
    detection.

.PARAMETER Logins
    Shorthand for -FailedLogins -SuccessfulLogins together.

.PARAMETER Backups
    Only backup-completion entries ("Database backed up.", "Log was backed up."). English text
    match, see .DESCRIPTION.

.PARAMETER Restores
    Only restore-completion entries ("Restore is complete on database ...", "Log was restored.").
    English text match.

.PARAMETER Errors
    Only internal SQL Server error entries in the "Error: <n>, Severity: <n>, State: <n>." format.

.PARAMETER Shutdowns
    Only SQL Server shutdown/termination entries.

.PARAMETER Startups
    Only SQL Server and per-database startup entries ("SQL Server is starting", "Starting up
    database '...'"). Verbose by design: one line per database on every service start.

.PARAMETER CorruptionEvents
    Only consistency/corruption entries (checksum failures, torn pages, consistency-based I/O
    errors).

.PARAMETER IOErrors
    Only I/O and operating-system error entries.

.PARAMETER MemoryPressure
    Only memory-pressure entries (paging, insufficient system memory, failed virtual allocations).

.PARAMETER ServiceBrokerEvents
    Only Service Broker related entries.

.PARAMETER Pattern
    Additional free-text/regex filter(s), case-insensitive. Combined with any category switches
    (AND); used standalone when no switch is set. This is the escape hatch for anything not
    covered by a category above, and for localized instances.

.PARAMETER Database
    Only entries whose text mentions one of these database names.

.PARAMETER Since
    Only entries logged on or after this date/time.

.PARAMETER Before
    Only entries logged on or before this date/time.

.PARAMETER Top
    Return at most this many entries per instance, most recent first. 0 (default) = unlimited.

.PARAMETER OutputPath
    Directory for CSV and HTML reports. Default: <OutputPath config>\ErrorLog. Set to $null/empty
    to skip report generation and only return objects.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.EXAMPLE
    Get-sqmErrorLog -SqlInstance SQL01 -FailedLogins -Since (Get-Date).AddDays(-1)

    All failed logins on SQL01 in the last 24 hours.

.EXAMPLE
    Get-sqmErrorLog -SqlInstance SQL01 -Logins -Top 100

    The 100 most recent login events (failed and successful) on SQL01.

.EXAMPLE
    Get-sqmErrorLog -SqlInstance SQL01 -Backups -Database "Orders"

    Backup-completion entries for the "Orders" database.

.EXAMPLE
    Get-sqmErrorLog -SqlInstance SQL01 -LogNumber 0,1,2 -Errors -Pattern '824|825'

    Internal SQL Server errors across the current log and the last two archives, narrowed to
    error numbers 824/825 (page checksum / retry-succeeded).

.EXAMPLE
    Get-sqmErrorLog -SqlInstance SQL01

    The full current error log, every entry categorized.

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath,
    ConvertTo-sqmMessageRegex, ConvertTo-sqmHtmlReport.
    Needs securityadmin or sysadmin (xp_readerrorlog) on the target instance.
#>
function Get-sqmErrorLog
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[int[]]$LogNumber = @(0),

		[Parameter(Mandatory = $false)]
		[switch]$FailedLogins,

		[Parameter(Mandatory = $false)]
		[switch]$SuccessfulLogins,

		[Parameter(Mandatory = $false)]
		[switch]$Logins,

		[Parameter(Mandatory = $false)]
		[switch]$Backups,

		[Parameter(Mandatory = $false)]
		[switch]$Restores,

		[Parameter(Mandatory = $false)]
		[switch]$Errors,

		[Parameter(Mandatory = $false)]
		[switch]$Shutdowns,

		[Parameter(Mandatory = $false)]
		[switch]$Startups,

		[Parameter(Mandatory = $false)]
		[switch]$CorruptionEvents,

		[Parameter(Mandatory = $false)]
		[switch]$IOErrors,

		[Parameter(Mandatory = $false)]
		[switch]$MemoryPressure,

		[Parameter(Mandatory = $false)]
		[switch]$ServiceBrokerEvents,

		[Parameter(Mandatory = $false)]
		[string[]]$Pattern = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),

		[Parameter(Mandatory = $false)]
		[Nullable[datetime]]$Since,

		[Parameter(Mandatory = $false)]
		[Nullable[datetime]]$Before,

		[Parameter(Mandatory = $false)]
		[int]$Top = 0,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'ErrorLog'),

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
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$wantFailedLogins = $FailedLogins -or $Logins
		$wantSuccessLogins = $SuccessfulLogins -or $Logins

		# Englische Textmuster fuer Kategorien ohne sys.messages-Abgleich. Siehe .DESCRIPTION:
		# bewusst nicht lokalisiert, um keine erratenen Uebersetzungen als Tatsache auszugeben.
		$categoryDefs = [ordered]@{
			Backup	   = @{ Want = [bool]$Backups; Regex = 'Database backed up\.|Log was backed up\.' }
			Restore    = @{ Want = [bool]$Restores; Regex = 'Restore is complete on database|Log was restored\.' }
			Error	   = @{ Want = [bool]$Errors; Regex = 'Error:\s*\d+,\s*Severity:\s*\d+,\s*State:\s*\d+' }
			Shutdown   = @{ Want = [bool]$Shutdowns; Regex = 'SQL Server is terminating|SQL Server is shutting down' }
			Startup    = @{ Want = [bool]$Startups; Regex = 'SQL Server is starting|Starting up database ' }
			Corruption = @{ Want = [bool]$CorruptionEvents; Regex = 'consistency-based I/O error|checksum failure|torn page detected|logical consistency error' }
			IOError    = @{ Want = [bool]$IOErrors; Regex = 'operating system returned error|I/O error' }
			Memory	   = @{ Want = [bool]$MemoryPressure; Regex = 'insufficient system memory|Failed Virtual Allocate Bytes|process memory has been paged out' }
			ServiceBroker = @{ Want = [bool]$ServiceBrokerEvents; Regex = 'Service Broker' }
		}

		$anyCategorySelected = $wantFailedLogins -or $wantSuccessLogins -or
			($categoryDefs.Values | Where-Object { $_.Want }).Count -gt 0

		Invoke-sqmLogging -Message "Starte $functionName (LogNumber=$($LogNumber -join ','))" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			try
			{
				$connParams = @{ SqlInstance = $instance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				# --- Login-Regex sprachneutral pro Instanz aus sys.messages ableiten ---
				# Alle installierten Sprachversionen der Vorlage holen (nicht nur @@LANGUAGE der
				# Session - das kann von der Sprache abweichen, in der das ErrorLog tatsaechlich
				# geschrieben wurde) und jede einzeln probieren, wie in Get-sqmLoginLastAccess.
				$failedLoginRegexes = [System.Collections.Generic.List[string]]::new()
				$successRegexes = [System.Collections.Generic.List[string]]::new()
				if ($wantFailedLogins -or -not $anyCategorySelected)
				{
					$msgRows = Invoke-DbaQuery @connParams -Database master -Query "SELECT text FROM sys.messages WHERE message_id = 18456" -EnableException:$EnableException
					foreach ($m in $msgRows)
					{
						$rx = ConvertTo-sqmMessageRegex -Template ([string]$m.text)
						if ($rx) { $failedLoginRegexes.Add($rx) }
					}
				}
				if ($wantSuccessLogins -or -not $anyCategorySelected)
				{
					$msgRows = Invoke-DbaQuery @connParams -Database master -Query "SELECT text FROM sys.messages WHERE message_id IN (18453, 18454)" -EnableException:$EnableException
					foreach ($m in $msgRows)
					{
						$rx = ConvertTo-sqmMessageRegex -Template ([string]$m.text)
						if ($rx) { $successRegexes.Add($rx) }
					}
				}

				# --- Rohdaten pro angefordertem LogNumber einsammeln ---
				$rawRows = [System.Collections.Generic.List[object]]::new()
				foreach ($ln in $LogNumber)
				{
					try
					{
						$dbaParams = @{ LogNumber = $ln; EnableException = $true }
						if ($Since) { $dbaParams['After'] = $Since }
						if ($Before) { $dbaParams['Before'] = $Before }
						$rows = Get-DbaErrorLog @connParams @dbaParams
						foreach ($r in $rows) { $rawRows.Add($r) }
					}
					catch
					{
						Invoke-sqmLogging -Message "[$instance] LogNumber $ln nicht lesbar: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
					}
				}

				if ($rawRows.Count -eq 0)
				{
					Invoke-sqmLogging -Message "[$instance] Keine ErrorLog-Eintraege gefunden." -FunctionName $functionName -Level 'WARNING'
					continue
				}

				# --- Kategorisieren und filtern ---
				$instanceRows = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($row in $rawRows)
				{
					$text = [string]$row.Text
					if ([string]::IsNullOrWhiteSpace($text)) { continue }

					$category = 'Other'
					$loginName = $null
					$errorNumber = $null; $severity = $null; $state = $null

					$hitFailedRegex = if ($failedLoginRegexes) { $failedLoginRegexes | Where-Object { $text -match $_ } | Select-Object -First 1 } else { $null }
					$hitSuccessRegex = if ($successRegexes) { $successRegexes | Where-Object { $text -match $_ } | Select-Object -First 1 } else { $null }

					if ($hitFailedRegex)
					{
						$category = 'FailedLogin'
						$null = $text -match $hitFailedRegex
						$loginName = $matches[1]
					}
					elseif ($hitSuccessRegex)
					{
						$category = 'SuccessfulLogin'
						$null = $text -match $hitSuccessRegex
						$loginName = $matches[1]
					}
					else
					{
						foreach ($key in $categoryDefs.Keys)
						{
							if ($text -match $categoryDefs[$key].Regex) { $category = $key; break }
						}
					}

					if ($category -eq 'Error')
					{
						$em = [regex]::Match($text, 'Error:\s*(\d+),\s*Severity:\s*(\d+),\s*State:\s*(\d+)')
						if ($em.Success)
						{
							$errorNumber = [int]$em.Groups[1].Value
							$severity = [int]$em.Groups[2].Value
							$state = [int]$em.Groups[3].Value
						}
					}

					# --- Auswahl anwenden: Kategorie-Switches (falls gesetzt) ---
					if ($anyCategorySelected)
					{
						$matchesSelection =
							($category -eq 'FailedLogin' -and $wantFailedLogins) -or
							($category -eq 'SuccessfulLogin' -and $wantSuccessLogins) -or
							($categoryDefs.Contains($category) -and $categoryDefs[$category].Want)
						if (-not $matchesSelection) { continue }
					}

					# --- Datenbank-Filter (Text-basiert, ODER-verknuepft) ---
					if ($Database.Count -gt 0)
					{
						$dbHit = $false
						foreach ($db in $Database)
						{
							if ($text -match [regex]::Escape($db)) { $dbHit = $true; break }
						}
						if (-not $dbHit) { continue }
					}

					# --- Freitext-/Regex-Filter (UND-verknuepft mit allem oben) ---
					if ($Pattern.Count -gt 0)
					{
						$patHit = $false
						foreach ($p in $Pattern)
						{
							if ($text -match $p) { $patHit = $true; break }
						}
						if (-not $patHit) { continue }
					}

					$instanceRows.Add([PSCustomObject]@{
							SqlInstance = $instance
							LogDate	    = $row.LogDate
							ProcessInfo = $row.ProcessInfo
							Category    = $category
							LoginName   = $loginName
							ErrorNumber = $errorNumber
							Severity    = $severity
							State	    = $state
							Text	    = $text
						})
				}

				$instanceRows = @($instanceRows | Sort-Object LogDate -Descending)
				if ($Top -gt 0) { $instanceRows = @($instanceRows | Select-Object -First $Top) }

				foreach ($r in $instanceRows) { $allResults.Add($r) }

				$byCat = ($instanceRows | Group-Object Category | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
				Invoke-sqmLogging -Message "[$instance] $($instanceRows.Count) Eintraege nach Filterung. $byCat" -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				$errMsg = "[$instance] Fehler: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
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
				$datestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
				$csvFile = Join-Path $OutputPath "ErrorLog_$datestamp.csv"
				$allResults | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
				Invoke-sqmLogging -Message "CSV geschrieben: $csvFile" -FunctionName $functionName -Level 'INFO'

				$htmlFile = Join-Path $OutputPath "ErrorLog_$datestamp.html"
				$bodyHtml = ($allResults |
					Select-Object SqlInstance, LogDate, Category, LoginName, ErrorNumber, Severity, State, Text |
					ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "SQL Server Error Log" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $($allResults.Count) Eintraege" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

				Copy-sqmToCentralPath -Path $csvFile, $htmlFile
			}
			catch
			{
				Invoke-sqmLogging -Message "Export fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Eintrag(e) gesamt." -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
