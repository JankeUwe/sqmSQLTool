<#
.SYNOPSIS
    Reads the IBM TSM / Spectrum Protect client configuration (dsm.opt) and returns
    server, user and password settings.

.DESCRIPTION
    Locates the dsm.opt option file (locally or on a remote computer), parses it and
    returns the relevant TSM client settings as an object.

    Steps:
      1. Determine the options file path (auto-detected via _FindDsmOptPath, or -DsmOptPath).
         The file may have a different name than dsm.opt: -optfile= of the TSM services,
         DSM_CONFIG and any *.opt in the baclient directory containing TCPServeraddress
         are considered.
      2. Read the file (UNC/remote-capable via _ToUncPath).
      3. Parse all non-comment options into a hashtable.
      4. Extract TCPServeraddress, USERID and PASSWORD.
      5. Follow every INCLEXCL option (e.g. ie_dsm.opt) and parse its INCLUDE/EXCLUDE rules.
      6. Write an HTML (and TXT) report; the password is masked in the report.

    The password is returned as a SecureString; the plain-text value is only included
    when -IncludePasswordPlain is set. On error a result object with Success = $false is
    returned (or an exception is thrown when -EnableException is set).

.PARAMETER ComputerName
    Target computer. Default: local computer name.

.PARAMETER DsmOptPath
    Optional explicit path to the dsm.opt file. If omitted, it is auto-detected.

.PARAMETER IncludePasswordPlain
    Also return the password in plain text (PasswordPlain). Off by default.

.PARAMETER Credential
    Optional PSCredential for accessing a remote dsm.opt file.

.PARAMETER InclExclPath
    Optional explicit path (on the target computer) of the include/exclude file. If omitted, all
    INCLEXCL / INCLEXCL.* options of the option file are followed (relative names are resolved
    against the directory of the option file).

.PARAMETER OutputPath
    Directory for the HTML and TXT report. Default: <default output path>\Get-sqmTsmConfiguration.

.PARAMETER NoOpen
    Do not open the report after creating it.

.PARAMETER NoReport
    Do not create a report, only return the object.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning a result object with Success = $false.

.EXAMPLE
    Get-sqmTsmConfiguration -ComputerName SQL01
    # Reads the TSM configuration from SQL01 (password as SecureString).

.EXAMPLE
    Get-sqmTsmConfiguration -DsmOptPath 'C:\Program Files\Tivoli\TSM\baclient\dsm.opt' -IncludePasswordPlain
    # Uses an explicit dsm.opt path and also returns the plain-text password.

.NOTES
    Requires the private helpers _FindDsmOptPath and _ToUncPath.
#>
function Get-sqmTsmConfiguration
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$DsmOptPath,
		[Parameter(Mandatory = $false)]
		[switch]$IncludePasswordPlain,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[string]$InclExclPath,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'Get-sqmTsmConfiguration'),
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
		# Logging-Aufruf (setzt voraus, dass Invoke-sqmLogging existiert)
		if (Get-Command "Invoke-sqmLogging" -ErrorAction SilentlyContinue)
		{
			Invoke-sqmLogging -Message "Starte $functionName auf $ComputerName" -FunctionName $functionName -Level "INFO"
		}
	}
	
	process
	{
		try
		{
			$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
			$optFile = $DsmOptPath
			
			# 1. Pfad zur dsm.opt ermitteln
			if (-not $optFile)
			{
				if (Get-Command "_FindDsmOptPath" -ErrorAction SilentlyContinue)
				{
					$optFile = _FindDsmOptPath -ComputerName $ComputerName -IsLocal $isLocal -Credential $Credential
				}
				else
				{
					throw "Hilfsfunktion _FindDsmOptPath nicht gefunden."
				}
			}
			
			if (-not $optFile)
			{
				$msg = "dsm.opt konnte nicht gefunden werden. Bitte -DsmOptPath angeben."
				if ($EnableException) { throw $msg }
				return [PSCustomObject]@{ Success = $false; ErrorMessage = $msg; FilePath = $null }
			}
			
			# 2. Datei lesen
			$readPath = if ($isLocal -or $optFile.StartsWith('\')) { $optFile }
			else { _ToUncPath -ComputerName $ComputerName -LocalPath $optFile }
			
			$psDrive = $null
			try
			{
				if ($Credential -and -not $isLocal)
				{
					$share = ($readPath -split '\\')[0..3] -join '\'
					$psDrive = New-PSDrive -Name ('tsmcfg' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -PSProvider FileSystem -Root $share -Credential $Credential -ErrorAction Stop
				}
				$lines = Get-Content -Path $readPath -Encoding UTF8 -ErrorAction Stop
			}
			finally
			{
				if ($psDrive) { Remove-PSDrive -Name $psDrive.Name -Force -ErrorAction SilentlyContinue }
			}
			
			# 3. Optionen parsen
			$options = @{ }
			$rawNonCommentLines = [System.Collections.Generic.List[string]]::new()
			$optionList = [System.Collections.Generic.List[PSCustomObject]]::new()
			$inclExclRefs = [System.Collections.Generic.List[string]]::new()
			
			foreach ($line in $lines)
			{
				$trimmed = $line.Trim()
				if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('*')) { continue }
				
				$rawNonCommentLines.Add($trimmed)
				
				# Regex verbessert: Erlaubt Bindestriche in Keys und ist robuster bei Whitespaces
				if ($trimmed -match '^([A-Za-z0-9_.-]+)\s+(.+)$')
				{
					$key = $Matches[1]
					$value = $Matches[2].Trim().Trim("'").Trim('"') # Robusteres Entfernen von Quotes
					$options[$key] = $value
					$optionList.Add([PSCustomObject]@{ Option = $key; Value = $value })
					# INCLEXCL darf mehrfach vorkommen; die Hashtable behaelt nur den letzten Treffer
					if ($key -match '^(?i)INCLEXCL(\.\w+)?$') { $inclExclRefs.Add($value) }
				}
			}
			
			# 3b. Include/Exclude-Dateien (INCLEXCL) auswerten
			if ($InclExclPath) { $inclExclRefs.Clear(); $inclExclRefs.Add($InclExclPath) }
			$inclExclFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
			$inclExclRules = [System.Collections.Generic.List[PSCustomObject]]::new()

			foreach ($ref in ($inclExclRefs | Select-Object -Unique))
			{
				$ieLocal = $ref
				if ($ieLocal -notmatch '^([A-Za-z]:[\\/]|\\\\)') { $ieLocal = Join-Path -Path (Split-Path -Path $optFile -Parent) -ChildPath $ieLocal }
				$ieRead = if ($isLocal -or $ieLocal.StartsWith('\\')) { $ieLocal }
				else { _ToUncPath -ComputerName $ComputerName -LocalPath $ieLocal }

				$ieInfo = [PSCustomObject]@{ Reference = $ref; Path = $ieLocal; Found = $false; ErrorMessage = $null; RuleCount = 0 }
				$ieDrive = $null
				try
				{
					if ($Credential -and -not $isLocal)
					{
						$ieShare = ($ieRead -split '\\')[0..3] -join '\'
						$ieDrive = New-PSDrive -Name ('tsmie' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -PSProvider FileSystem -Root $ieShare -Credential $Credential -ErrorAction Stop
					}
					$ieLines = @(Get-Content -Path $ieRead -Encoding UTF8 -ErrorAction Stop)
					$ieInfo.Found = $true
					$lineNo = 0
					foreach ($ieLine in $ieLines)
					{
						$lineNo++
						$t = $ieLine.Trim()
						if ([string]::IsNullOrWhiteSpace($t) -or $t.StartsWith('*')) { continue }
						if ($t -match '^(?i)(INCLUDE|EXCLUDE)(\.[A-Za-z0-9]+)?\s+(.+)$')
						{
							$ruleAction = $Matches[1].ToUpper()
							$ruleType = ($Matches[1] + $Matches[2]).ToUpper()
							$rest = $Matches[3].Trim()
							$pattern = $rest
							$mgmtClass = ''
							if ($rest -match '^"([^"]*)"\s*(.*)$' -or $rest -match "^'([^']*)'\s*(.*)$")
							{
								$pattern = $Matches[1]; $mgmtClass = $Matches[2].Trim()
							}
							elseif ($rest -match '^(\S+)\s+(.+)$')
							{
								$pattern = $Matches[1]; $mgmtClass = $Matches[2].Trim()
							}
							$inclExclRules.Add([PSCustomObject]@{
									Source          = $ieLocal
									Line            = $lineNo
									Action          = $ruleAction
									Type            = $ruleType
									Pattern         = $pattern
									ManagementClass = $mgmtClass
								})
							$ieInfo.RuleCount++
						}
						else
						{
							# Andere Optionen in der Include-Datei (z. B. DOMAIN) nicht verlieren
							$inclExclRules.Add([PSCustomObject]@{
									Source = $ieLocal; Line = $lineNo; Action = 'OTHER'; Type = 'OTHER'; Pattern = $t; ManagementClass = ''
								})
						}
					}
				}
				catch
				{
					$ieInfo.ErrorMessage = $_.Exception.Message
				}
				finally
				{
					if ($ieDrive) { Remove-PSDrive -Name $ieDrive.Name -Force -ErrorAction SilentlyContinue }
				}
				$inclExclFiles.Add($ieInfo)
			}

			# 4. Spezielle Werte extrahieren (Case-Insensitive Hashtable Zugriff)
			$serverName = $options['TCPServeraddress']
			$userName = $options['USERID']
			$passwordPlain = $options['PASSWORD']
			$passwordSecure = $null
			
			if ($passwordPlain)
			{
				$passwordSecure = ConvertTo-SecureString -String $passwordPlain -AsPlainText -Force
			}
			
			# 5. Rueckgabeobjekt
			$result = [PSCustomObject]@{
				Success	      = $true
				ErrorMessage  = $null
				FilePath	  = $optFile
				ServerName    = $serverName
				UserName	  = $userName
				Password	  = $passwordSecure
				PasswordPlain = if ($IncludePasswordPlain) { $passwordPlain } else { $null }
				AllOptions    = $options
				RawContent    = $rawNonCommentLines.ToArray()
				OptionList    = $optionList.ToArray()
				InclExclFiles = $inclExclFiles.ToArray()
				InclExclRules = $inclExclRules.ToArray()
				ComputerName  = $ComputerName
				ReportFile    = $null
			}
			
			if (-not $NoReport)
			{
				try
				{
					$result.ReportFile = _WriteTsmConfigurationReport -Config $result -OutputPath $OutputPath -NoOpen:$NoOpen
				}
				catch
				{
					Write-Warning "TSM-Konfigurationsreport konnte nicht erstellt werden: $($_.Exception.Message)"
				}
			}

			return $result
		}
		catch
		{
			$errMsg = "Fehler beim Lesen der dsm.opt: $($_.Exception.Message)"
			if ($EnableException) { throw }
			return [PSCustomObject]@{ Success = $false; ErrorMessage = $errMsg; FilePath = $null }
		}
	}
	
	end
	{
		# Optionales Abschluss-Logging
	}
}

# Erstellt HTML- und TXT-Report zur TSM-Client-Konfiguration (dsm.opt + Include/Exclude-Dateien).
# Das Kennwort wird im Report immer maskiert.
function _WriteTsmConfigurationReport
{
	param (
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$Config,
		[Parameter(Mandatory = $true)]
		[string]$OutputPath,
		[switch]$NoOpen
	)

	function _h { param($x) [string]$x -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
	function _mask { param($k, $v) if ($k -match '^(?i)(PASSWORD|PASSWD)$') { '********' } else { $v } }

	if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
	$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
	$safe = ($Config.ComputerName -replace '[\\/:*?"<>|]', '_')
	$htmlFile = Join-Path $OutputPath "TsmConfiguration_${safe}_$stamp.html"
	$txtFile = Join-Path $OutputPath "TsmConfiguration_${safe}_$stamp.txt"

	$files = @($Config.InclExclFiles)
	$rules = @($Config.InclExclRules)
	$optList = @($Config.OptionList)
	$cntInc = @($rules | Where-Object Action -eq 'INCLUDE').Count
	$cntExc = @($rules | Where-Object Action -eq 'EXCLUDE').Count
	$port = $Config.AllOptions['TCPPort']
	if (-not $port) { $port = '1500 (Standard)' }
	$node = $Config.AllOptions['NODENAME']
	if (-not $node) { $node = '(Rechnername)' }

	# Hinweise
	$notes = [System.Collections.Generic.List[string]]::new()
	if (-not $Config.ServerName) { $notes.Add("<span class='crit'>TCPServeraddress fehlt</span> in der Optionsdatei.") }
	if ($Config.AllOptions['PASSWORD']) { $notes.Add("<span class='warn'>PASSWORD steht im Klartext</span> in der Optionsdatei. Ueblich ist PASSWORDACCESS GENERATE (Kennwort in der Registry).") }
	foreach ($f in $files)
	{
		if (-not $f.Found) { $notes.Add("<span class='crit'>Include/Exclude-Datei nicht lesbar:</span> $(_h $f.Path) ($(_h $f.ErrorMessage))") }
	}
	if ($files.Count -eq 0) { $notes.Add("Die Optionsdatei verweist auf keine Include/Exclude-Datei (kein INCLEXCL).") }
	$notesHtml = if ($notes.Count -gt 0) { '<ul>' + (($notes | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>' } else { "<p class='ok'>Keine Auffaelligkeiten.</p>" }

	# Kacheln
	$tile = { param($label, $value) "<div style='background:#0d1f38;border:1px solid #1e3a5f;border-radius:6px;padding:10px 14px;min-width:170px;'><div style='color:#94a8c0;font-size:11px;text-transform:uppercase;'>$label</div><div style='font-size:15px;color:#e2e8f0;margin-top:3px;word-break:break-all;'>$value</div></div>" }
	$tiles = (& $tile 'TSM-Server' (_h $Config.ServerName)) + (& $tile 'Port' (_h $port)) + (& $tile 'Knoten' (_h $node)) +
	(& $tile 'Optionsdatei' (_h $Config.FilePath)) + (& $tile 'Include/Exclude-Dateien' $files.Count) +
	(& $tile 'Include-Regeln' $cntInc) + (& $tile 'Exclude-Regeln' $cntExc)

	# Schluesseloptionen vorweg
	$keyNames = 'TCPServeraddress', 'TCPPort', 'NODENAME', 'COMMMETHOD', 'PASSWORDACCESS', 'USERID', 'PASSWORD', 'DOMAIN', 'SCHEDMODE', 'MANAGEDSERVICES', 'ERRORLOGNAME', 'SCHEDLOGNAME', 'ERRORLOGRETENTION', 'SCHEDLOGRETENTION', 'TCPWINDOWSIZE', 'TCPBUFFSIZE', 'COMPRESSION', 'ENCRYPTIONTYPE', 'RESOURCEUTILIZATION', 'TXNBYTELIMIT'
	$keyRows = ''
	foreach ($kn in $keyNames)
	{
		foreach ($o in @($optList | Where-Object { $_.Option -ieq $kn }))
		{
			$keyRows += "<tr><td>$(_h $o.Option)</td><td>$(_h (_mask $o.Option $o.Value))</td></tr>`n"
		}
	}
	$keyTable = if ($keyRows) { "<table><thead><tr><th style='width:260px'>Option</th><th>Wert</th></tr></thead><tbody>`n$keyRows</tbody></table>" } else { '<p>Keine Verbindungsoptionen gefunden.</p>' }

	$allRows = ''
	foreach ($o in $optList)
	{
		$allRows += "<tr><td>$(_h $o.Option)</td><td>$(_h (_mask $o.Option $o.Value))</td></tr>`n"
	}
	$allTable = "<table><thead><tr><th style='width:260px'>Option</th><th>Wert</th></tr></thead><tbody>`n$allRows</tbody></table>"

	# Include/Exclude je Datei
	$ieHtml = ''
	foreach ($f in $files)
	{
		$fileRules = @($rules | Where-Object { $_.Source -eq $f.Path })
		$ieHtml += "<h3 style='color:#5dade2;margin:18px 0 6px 0;'>$(_h $f.Path)</h3>`n"
		if (-not $f.Found)
		{
			$ieHtml += "<p class='crit'>Datei nicht lesbar: $(_h $f.ErrorMessage)</p>`n"
			continue
		}
		if ($fileRules.Count -eq 0) { $ieHtml += "<p>Keine Regeln in der Datei.</p>`n"; continue }
		$rr = ''
		foreach ($r in $fileRules)
		{
			$cls = switch ($r.Action) { 'INCLUDE' { 'ok' } 'EXCLUDE' { 'crit' } default { 'warn' } }
			$rr += "<tr><td class='num'>$($r.Line)</td><td class='$cls'>$(_h $r.Type)</td><td style='font-family:Consolas,monospace;'>$(_h $r.Pattern)</td><td>$(_h $r.ManagementClass)</td></tr>`n"
		}
		$ieHtml += "<table><thead><tr><th class='num' style='width:60px'>Zeile</th><th style='width:190px'>Regel</th><th>Muster</th><th>Managementklasse</th></tr></thead><tbody>`n$rr</tbody></table>`n"
	}
	if (-not $ieHtml) { $ieHtml = '<p>Keine Include/Exclude-Datei referenziert.</p>' }

	$body = "<div style='display:flex;flex-wrap:wrap;gap:10px;margin-bottom:18px;'>$tiles</div>" +
	"<h2 style='color:#5dade2;font-size:15px;'>Hinweise</h2>$notesHtml" +
	"<h2 style='color:#5dade2;font-size:15px;'>Verbindung und Knoten</h2>$keyTable" +
	"<h2 style='color:#5dade2;font-size:15px;'>Include/Exclude-Regeln</h2>" +
	"<p style='color:#94a8c0;font-size:12px;'>TSM wertet die Regeln von unten nach oben aus: die erste passende Regel von unten gilt.</p>$ieHtml" +
	"<h2 style='color:#5dade2;font-size:15px;'>Alle Optionen der Optionsdatei</h2>$allTable"

	$html = ConvertTo-sqmHtmlReport -Title 'TSM-Client-Konfiguration' -Subtitle "$(_h $Config.ComputerName) - $(_h $Config.FilePath)" -BodyHtml $body
	[System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)

	$t = [System.Collections.Generic.List[string]]::new()
	$t.Add('# sqmSQLTool - TSM-Client-Konfiguration')
	$t.Add("# Computer: $($Config.ComputerName) | Optionsdatei: $($Config.FilePath)")
	$t.Add("# Server: $($Config.ServerName) | Port: $port | Knoten: $node")
	$t.Add('')
	foreach ($o in $optList) { $t.Add(("{0,-24} {1}" -f $o.Option, (_mask $o.Option $o.Value))) }
	foreach ($f in $files)
	{
		$t.Add('')
		$t.Add("# Include/Exclude: $($f.Path)" + $(if (-not $f.Found) { " (NICHT LESBAR: $($f.ErrorMessage))" } else { '' }))
		foreach ($r in @($rules | Where-Object { $_.Source -eq $f.Path })) { $t.Add(("{0,4}  {1,-16} {2}  {3}" -f $r.Line, $r.Type, $r.Pattern, $r.ManagementClass)) }
	}
	[System.IO.File]::WriteAllText($txtFile, ($t -join "`r`n"), [System.Text.Encoding]::UTF8)

	Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
	return $htmlFile
}
