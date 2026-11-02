<#
.SYNOPSIS
    Listet die SQL-Server-Speicherabbilder (Memory Dumps) einer Instanz und ermittelt nach Moeglichkeit den Grund.

.DESCRIPTION
    SQL Server schreibt bei schweren Fehlern (Access Violation, Assertion, Non-yielding Scheduler, Out of Memory,
    Latch-Timeout, ...) ein Speicherabbild SQLDump<n>.mdmp samt SQLDump<n>.txt in das LOG-Verzeichnis. Die Dateien
    sind gross und der Anlass ist ihnen von aussen nicht anzusehen.

    Die Funktion liest die Abbilder aus sys.dm_server_memory_dumps (Datei, Zeitpunkt, Groesse) und sucht zu jedem
    im SQL-Errorlog den Eintrag "Stack Dump being sent to ...SQLDump<n>.txt". Aus den Errorlog-Zeilen kurz davor und
    danach wird der Anlass bestimmt:

        - Fehlernummern (17066 Assertion, 17883 Non-yielding Scheduler, 701 Out of Memory, 823/824/825, 844-847 ...)
        - Exception Code und Adresse sowie das Modul (z.B. sqllang+0x...), die SPID und der Input Buffer des
          ausloesenden Befehls
        - eine Einordnung (Type) mit kurzem Hinweis, was als Naechstes zu pruefen ist

    Das ist eine Ersteinschaetzung aus dem Errorlog, keine Analyse des Abbilds. Die Ursache im Code von SQL Server
    (Stack, Modul) laesst sich nur mit dem Abbild selbst klaeren (Microsoft Support oder WinDbg); die Funktion zeigt
    aber meist, welche Sitzung und welcher Befehl beteiligt war, und liefert mit ProductVersion den Patchstand, denn
    viele Abstuerze sind in einem spaeteren Cumulative Update behoben.

    Ist der passende Errorlog-Eintrag schon rotiert (aelter als -MaxLogFiles Logs) oder fehlt das Recht auf
    xp_readerrorlog, bleibt der Grund "Unbekannt"; Datei, Zeitpunkt und Groesse stehen trotzdem im Ergebnis.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung.

.PARAMETER Days
    Nur Abbilder der letzten N Tage. Standard: 365. 0 = alle.

.PARAMETER MaxLogFiles
    Wie viele Errorlog-Dateien (aktuelle plus Archive) nach dem Anlass durchsucht werden. Standard: 20.

.PARAMETER EnableException
    Fehler werfen statt loggen und nichts zurueckgeben.

.EXAMPLE
    Get-sqmMemoryDump -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmMemoryDump -SqlInstance "SQL01" -Days 30 | Format-List FileName, CreationTime, SizeMB, Type, Reason, Hint

.EXAMPLE
    Get-sqmMemoryDump -SqlInstance "SQL01" | Group-Object Type | Sort-Object Count -Descending

.OUTPUTS
    [PSCustomObject] je Abbild: SqlInstance, ProductVersion, FileName, Path, CreationTime, SizeMB, Type, Reason,
    ErrorNumbers, ExceptionCode, ExceptionAddress, Module, Spid, InputBuffer, ErrorLogNumber, ErrorLogTime,
    Evidence, Hint. Neueste zuerst.

.NOTES
    Uses Invoke-DbaQuery. Braucht VIEW SERVER STATE (sys.dm_server_memory_dumps) und fuer den Anlass sysadmin
    (xp_readerrorlog). Ab SQL Server 2008 R2 SP1.
    Ein Abbild von einigen GB ist keine Seltenheit: Abbilder, die nicht mehr gebraucht werden, nach der Klaerung
    loeschen, sonst fuellt sich das LOG-Laufwerk.
#>
function Get-sqmMemoryDump
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 36500)]
		[int]$Days = 365,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$MaxLogFiles = 20,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
	{
		$SqlInstance = $env:COMPUTERNAME
	}

	$connParams = @{ SqlInstance = $SqlInstance; Database = 'master' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	# Einordnung: erste zutreffende Regel gewinnt, spezifische vor allgemeinen.
	$rules = @(
		@{ Type = 'DeadlockedSchedulers'; Pattern = 'Error:\s*17888|schedulers on Node \d+ appear deadlocked'; Hint = 'Alle Scheduler hingen. Meist Sperren/Spinlocks im Engine oder ein Treiber-/Antivirus-Problem. Patchstand pruefen, Microsoft Support mit dem Abbild einbinden.' }
		@{ Type = 'NonYieldingScheduler'; Pattern = 'Error:\s*1788[34]|non-yielding on Scheduler'; Hint = 'Ein Worker hat den Scheduler nicht freigegeben. Haeufig CPU-Druck, Antivirus/Filtertreiber, langsamer Storage oder ein Fehler in SQL Server. Befehl im Input Buffer und I/O-Latenz pruefen, Patchstand pruefen.' }
		@{ Type = 'Assertion'; Pattern = 'SQL Server Assertion|Failed Assertion|Error:\s*1706[5-7]'; Hint = 'Interner Konsistenzfehler von SQL Server. Haeufig Datenbankkorruption oder ein Produktfehler. DBCC CHECKDB der beteiligten Datenbank, Patchstand pruefen, bei Wiederholung Microsoft Support.' }
		@{ Type = 'StackOverflow'; Pattern = 'c00000fd|EXCEPTION_STACK_OVERFLOW'; Hint = 'Stack-Ueberlauf, typisch bei sehr tief verschachtelten oder extrem grossen Abfragen (z.B. riesige IN-Listen). Befehl im Input Buffer pruefen.' }
		@{ Type = 'AccessViolation'; Pattern = 'c0000005|EXCEPTION_ACCESS_VIOLATION'; Hint = 'Zugriff auf ungueltigen Speicher. Ursache sind meist ein Produktfehler (Patchstand pruefen), ein Fremdtreiber/Antivirus oder defekter Speicher; der Input Buffer nennt den ausloesenden Befehl.' }
		@{ Type = 'OutOfMemory'; Pattern = 'Error:\s*(701|8645|8651|17803)\b|insufficient (system )?memory|Failed Virtual Allocate' ; Hint = 'Speichermangel. max server memory, Speicherverbrauch von Plan Cache/Memory Grants und den Speicher des Hosts pruefen.' }
		@{ Type = 'LatchTimeout'; Pattern = 'time out occurred while waiting for buffer latch|Error:\s*84[4-7]\b'; Hint = 'Zeitueberschreitung auf einem Buffer-Latch, meist durch haengende I/O. Storage, Treiber und Filtertreiber pruefen.' }
		@{ Type = 'Corruption'; Pattern = 'Error:\s*(823|824|825|605)\b'; Hint = 'I/O- oder Konsistenzfehler. DBCC CHECKDB der Datenbank, Storage und Backups pruefen.' }
		@{ Type = 'WorkingSetTrimmed'; Pattern = 'Error:\s*17890|significant part of sql server process memory has been paged out'; Hint = 'Das Betriebssystem hat Speicher von SQL Server ausgelagert. Lock Pages in Memory, max server memory und Treiber (Ballooning, Antivirus) pruefen.' }
		@{ Type = 'Manual'; Pattern = 'User initiated stack dump|DBCC STACKDUMP|sp_dump|requested dump'; Hint = 'Das Abbild wurde absichtlich angefordert (z.B. DBCC STACKDUMP oder ein Support-Auftrag), es ist kein Absturz.' }
	)

	try
	{
		if (-not $script:dbatoolsAvailable) { throw "dbatools-Modul nicht gefunden." }
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'

		# ---- 1. Abbilder ----
		$dumpQuery = @"
SELECT filename, CONVERT(varchar(30), CONVERT(datetime2(0), creation_time), 126) AS creation_local, size_in_bytes
FROM sys.dm_server_memory_dumps
ORDER BY creation_time DESC;
"@
		$dumps = @(Invoke-DbaQuery @connParams -Query $dumpQuery -As PSObject -EnableException -ErrorAction Stop)
		if ($Days -gt 0)
		{
			$cutoff = (Get-Date).AddDays(-$Days)
			$dumps = @($dumps | Where-Object { [datetime]::Parse([string]$_.creation_local, [System.Globalization.CultureInfo]::InvariantCulture) -ge $cutoff })
		}
		$dumps = @($dumps | Sort-Object { [datetime]::Parse([string]$_.creation_local, [System.Globalization.CultureInfo]::InvariantCulture) } -Descending)
		if ($dumps.Count -eq 0)
		{
			Invoke-sqmLogging -Message "Keine Memory Dumps auf $SqlInstance$(if ($Days -gt 0) { " in den letzten $Days Tagen" })." -FunctionName $functionName -Level 'INFO'
			return
		}

		$version = ''
		try { $version = [string](@(Invoke-DbaQuery @connParams -Query "SELECT CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')) AS v" -As PSObject -EnableException -ErrorAction Stop)[0].v) }
		catch { Invoke-sqmLogging -Message "ProductVersion nicht ermittelbar: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING' }

		# ---- 2. Errorlog: Zeile "Stack Dump being sent to ...SQLDump<n>.txt" je Dump ----
		$logHits = @{}
		$logsReadable = $true
		$logCount = 0
		try
		{
			$logCount = @(Invoke-DbaQuery @connParams -Query "EXEC sys.sp_enumerrorlogs;" -As PSObject -EnableException -ErrorAction Stop).Count
			$logCount = [math]::Min($logCount, $MaxLogFiles)
			for ($n = 0; $n -lt $logCount; $n++)
			{
				$rows = @(Invoke-DbaQuery @connParams -Query "EXEC sys.xp_readerrorlog $n, 1, N'Stack Dump being sent';" -As PSObject -EnableException -ErrorAction Stop)
				foreach ($r in $rows)
				{
					if ("$($r.Text)" -match '(SQLDump\d+)\.txt')
					{
						$key = $Matches[1].ToLowerInvariant()
						if (-not $logHits.ContainsKey($key)) { $logHits[$key] = @{ LogNo = $n; Time = [datetime]$r.LogDate } }
					}
				}
			}
		}
		catch
		{
			$logsReadable = $false
			Invoke-sqmLogging -Message "Errorlog nicht lesbar (sysadmin noetig), Anlass bleibt unbekannt: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
		}

		# ---- 3. Je Dump Anlass bestimmen ----
		foreach ($d in $dumps)
		{
			$path = [string]$d.filename
			$leaf = ($path -split '[\\/]')[-1]
			$base = [System.IO.Path]::GetFileNameWithoutExtension($leaf).ToLowerInvariant()
			$created = [datetime]::Parse([string]$d.creation_local, [System.Globalization.CultureInfo]::InvariantCulture)

			$type = 'Unknown'
			$reason = if ($logsReadable) { "Kein Errorlog-Eintrag zu $leaf gefunden (Log evtl. schon rotiert, mehr mit -MaxLogFiles)." } else { 'Errorlog nicht lesbar.' }
			# $reason wird unten nur ueberschrieben, wenn Errorlog-Kontext gefunden wurde.
			$hint = 'Abbild nur mit WinDbg oder Microsoft Support auswertbar; Patchstand pruefen.'
			$errNums = @(); $excCode = $null; $excAddr = $null; $module = $null; $spid = $null; $inputBuf = $null
			$logNo = $null; $logTime = $null; $evidence = $null

			# Anker ist der Zeitpunkt, zu dem das Abbild geschrieben wurde. Aeltere Builds nennen ausserdem
			# "Stack Dump being sent to ...SQLDump<n>.txt" im Errorlog; neuere (z.B. SQL Server 2025) tun das
			# nicht mehr, deshalb ist der Dateiname nur eine Verfeinerung, nicht Voraussetzung. Die Ursache
			# steht in den Zeilen kurz VOR dem Schreiben des Abbilds.
			$hit = $logHits[$base]
			$center = if ($hit) { $hit.Time } else { $created }
			$ctx = @()
			if ($logsReadable)
			{
				$from = $center.AddMinutes(-3).ToString('yyyyMMdd HH:mm:ss')
				$to = $center.AddMinutes(1).ToString('yyyyMMdd HH:mm:ss')
				$candidates = if ($hit) { @($hit.LogNo) } else { @(0..([math]::Max($logCount, 1) - 1)) }
				try
				{
					foreach ($n in $candidates)
					{
						$rows = @(Invoke-DbaQuery @connParams -Query "EXEC sys.xp_readerrorlog $n, 1, NULL, NULL, N'$from', N'$to', N'asc';" -As PSObject -EnableException -ErrorAction Stop)
						if ($rows.Count -gt 0) { $ctx = $rows; $logNo = $n; $logTime = $center; break }
					}
				}
				catch
				{
					$reason = "Errorlog-Kontext nicht lesbar: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "Kontext zu $leaf nicht lesbar: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}
			if ($ctx.Count -gt 0)
			{
				try
				{
					$lines = @($ctx | ForEach-Object { "$($_.Text)".Trim() } | Where-Object { $_ })
					$blob = $lines -join "`n"

					foreach ($rule in $rules)
					{
						if ($blob -match $rule.Pattern)
						{
							$type = $rule.Type
							$hint = $rule.Hint
							break
						}
					}
					$errNums = @([regex]::Matches($blob, 'Error:\s*(\d+),\s*Severity:\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Select-Object -Unique)
					if ($blob -match 'Exception Code\s*=\s*([0-9A-Fa-fx]+)\s*([A-Z_]+)?') { $excCode = ("$($Matches[1]) $($Matches[2])").Trim() }
					elseif ($blob -match 'fatal exception ([0-9A-Fa-f]+)\s+([A-Z_]+)') { $excCode = "$($Matches[1]) $($Matches[2])" }
					if ($blob -match 'Exception Address\s*=\s*([0-9A-Fa-f]+)\s*(Module\(([^)]+)\))?') { $excAddr = $Matches[1]; $module = $Matches[3] }
					# "spid 61" oder "spid = 61"; SPID 0 sind interne Threads (bei einem Stack Dump aller Thread-Stacks viele).
					$spidHit = [regex]::Matches($blob, 'spid\s*=?\s*(\d+)') | Where-Object { [int]$_.Groups[1].Value -gt 0 } | Select-Object -First 1
					if ($spidHit) { $spid = [int]$spidHit.Groups[1].Value }
					$ibIdx = -1
					for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^Input Buffer \d+ bytes') { $ibIdx = $i; break } }
					if ($ibIdx -ge 0 -and $ibIdx + 1 -lt $lines.Count) { $inputBuf = $lines[$ibIdx + 1] }

					$keyLines = @($lines | Where-Object { $_ -match 'Error:\s*\d+|Exception|Assertion|non-yielding|deadlocked|Access Violation|spid \d+|terminating this process|Input Buffer' } | Select-Object -First 10)
					$evidence = $keyLines -join ' | '

					$parts = @()
					if ($errNums.Count -gt 0) { $parts += "Fehler $($errNums -join ', ')" }
					if ($excCode) { $parts += "Exception $excCode" }
					if ($module) { $parts += "in $module" }
					if ($spid) { $parts += "SPID $spid" }
					$reason = if ($type -eq 'Unknown') { 'Anlass im Errorlog nicht eindeutig' + $(if ($parts) { ": $($parts -join '; ')" } else { '' }) }
					else { "$type" + $(if ($parts) { ": $($parts -join '; ')" } else { '' }) }
				}
				catch
				{
					$reason = "Errorlog-Kontext (Log $logNo) nicht auswertbar: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "Kontext zu $leaf nicht auswertbar: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}

			[PSCustomObject]@{
				SqlInstance      = $SqlInstance
				ProductVersion   = $version
				FileName         = $leaf
				Path             = $path
				CreationTime     = $created
				SizeMB           = [math]::Round(([long]$d.size_in_bytes) / 1MB, 1)
				Type             = $type
				Reason           = $reason
				ErrorNumbers     = $errNums
				ExceptionCode    = $excCode
				ExceptionAddress = $excAddr
				Module           = $module
				Spid             = $spid
				InputBuffer      = $inputBuf
				ErrorLogNumber   = $logNo
				ErrorLogTime     = $logTime
				Evidence         = $evidence
				Hint             = $hint
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen: $($dumps.Count) Memory Dump(s) auf $SqlInstance." -FunctionName $functionName -Level 'INFO'
	}
	catch
	{
		$errMsg = "Fehler in $functionName auf ${SqlInstance}: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
		if ($EnableException) { throw }
		Write-Error $errMsg
	}
}
