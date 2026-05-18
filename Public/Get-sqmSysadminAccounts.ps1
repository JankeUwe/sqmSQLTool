<#
.SYNOPSIS
    Ermittelt alle Logins mit Sysadmin-Rechten auf einer SQL Server-Instanz.

.DESCRIPTION
    Fragt sys.server_principals und sys.server_role_members ab und liefert
    alle direkten Mitglieder der sysadmin-Serverrolle.

    Pro Login werden folgende Informationen ermittelt:
    - Loginname und Logintyp (SQL, Windows-User, Windows-Gruppe, etc.)
    - Aktiviert / deaktiviert
    - Ist SA (SID 0x01) oder nicht
    - Erstellungsdatum
    - Ob der Login explizit ausgeschlossen wurde (-ExcludeLogin)

    Mit -ExcludeLogin koennen bekannte/erwartete Konten aus dem Bericht
    gefiltert werden (sie werden als 'Excluded' markiert).

    Mit -ExcludeSysAccounts werden bekannte SQL Server-System- und
    Dienstkonten automatisch als 'Excluded' markiert.

    BUILTIN\Administrators erhaelt einen eigenen Status 'BuiltinAdmins'
    und wird NICHT automatisch ausgeschlossen - Sicherheitspruefung erforderlich.

    Ausgabe:
        SysadminAccounts_<instanz>_<datum>.txt   - Lesbarer Bericht
        SysadminAccounts_<instanz>_<datum>.csv   - Maschinenlesbar

.PARAMETER SqlInstance
    SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    Optionales PSCredential fuer die Verbindung.

.PARAMETER ExcludeLogin
    Logins die als 'Excluded' markiert werden (Wildcards erlaubt).

.PARAMETER ExcludeSysAccounts
    Wenn gesetzt, werden bekannte Systemkonten automatisch ausgeschlossen.

.PARAMETER IncludeDisabled
    Wenn $true (Standard), werden auch deaktivierte sysadmin-Logins einbezogen.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer die Berichtsdateien. Standard: $env:ProgramData\sqmSQLTool\Logs

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz fortfahren.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (ueberschreibt ContinueOnError).

.PARAMETER Confirm
    Fordert vor dem Schreiben der Dateien eine Bestaetigung an.

.PARAMETER WhatIf
    Zeigt, welche Dateien erstellt wuerden, ohne sie zu schreiben.

.EXAMPLE
    Get-sqmSysadminAccounts

.EXAMPLE
    Get-sqmSysadminAccounts -SqlInstance "SQL01" -ExcludeSysAccounts
#>
function Get-sqmSysadminAccounts
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin = @(),
		[Parameter(Mandatory = $false)]
		[switch]$ExcludeSysAccounts,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeDisabled = $true,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = '$env:ProgramData\sqmSQLTool\Logs',
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
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
		
		# Systemkonten-Muster fuer -ExcludeSysAccounts
		$sysAccountPatterns = @(
			'NT SERVICE\*',
			'NT AUTHORITY\SYSTEM',
			'NT AUTHORITY\NETWORK SERVICE',
			'NT AUTHORITY\LOCAL SERVICE',
			'NT AUTHORITY\*',
			'##MS_*##'
		)
		
		if ($ExcludeSysAccounts)
		{
			$ExcludeLogin = @($ExcludeLogin) + $sysAccountPatterns | Sort-Object -Unique
			Invoke-sqmLogging -Message "ExcludeSysAccounts: $($sysAccountPatterns.Count) Systemmuster hinzugefuegt." -FunctionName $functionName -Level "DEBUG"
		}
		
		# Hilfsfunktion fuer Ausschlusspruefung
		function _IsExcluded
		{
			param ([string]$Name,
				[string[]]$Patterns)
			if (-not $Patterns) { return $false }
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
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Starte Sysadmin-Audit ..." -FunctionName $functionName -Level "INFO"
				
				$disabledFilter = if ($IncludeDisabled) { '' }
				else { 'AND sp.is_disabled = 0' }
				
				# Achtung: password_last_set_time und last_login_date wurden entfernt,
				# da sie in aelteren SQL Server-Versionen nicht existieren.
				$query = @"
SELECT
    sp.name                                          AS LoginName,
    sp.type_desc                                     AS LoginType,
    sp.is_disabled                                   AS IsDisabled,
    CASE WHEN sp.sid = 0x01 THEN 1 ELSE 0 END        AS IsSa,
    sp.create_date                                   AS CreateDate,
    sp.modify_date                                   AS ModifyDate,
    NULL                                             AS LastPasswordChange,
    NULL                                             AS LastLogin,
    sp.default_database_name                         AS DefaultDatabase
FROM sys.server_principals       sp
JOIN sys.server_role_members     rm ON rm.member_principal_id = sp.principal_id
JOIN sys.server_principals       sr ON sr.principal_id        = rm.role_principal_id
WHERE sr.name        = 'sysadmin'
  AND sp.type        IN ('S','U','G','R')
  AND sp.principal_id > 1
  $disabledFilter
ORDER BY sp.type_desc, sp.name;
"@
				$rows = Invoke-DbaQuery @connParams -Query $query -EnableException:$EnableException
				
				if (-not $rows)
				{
					$msg = "Keine sysadmin-Logins auf '$instance' gefunden (unerwartet)."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$detailRows.Add([PSCustomObject]@{
							SqlInstance	       = $instance
							LoginName		   = '(keine)'
							LoginType		   = 'n/a'
							IsEnabled		   = $null
							IsSa			   = $false
							LastPasswordChange = $null
							LastLogin		   = $null
							CreateDate		   = $null
							Status			   = 'Error'
							Message		       = $msg
						})
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] $($rows.Count) sysadmin-Login(s) gefunden." -FunctionName $functionName -Level "INFO"
					
					foreach ($row in $rows)
					{
						$loginName = $row.LoginName
						$isSa = [bool]$row.IsSa
						$isEnabled = -not [bool]$row.IsDisabled
						$excluded = _IsExcluded $loginName $ExcludeLogin
						$isBuiltinAdmins = ($loginName -eq 'BUILTIN\Administrators')
						
						$status = if ($isSa) { 'SA' }
						elseif ($isBuiltinAdmins) { 'BuiltinAdmins' }
						elseif ($excluded) { 'Excluded' }
						elseif (-not $isEnabled) { 'Disabled' }
						else { 'Unexpected' }
						
						$msg = switch ($status)
						{
							'SA'            { 'SA-Konto (SID 0x01).' }
							'BuiltinAdmins' { 'BUILTIN\Administrators hat Sysadmin-Rechte - SICHERHEITSPRueFUNG ERFORDERLICH.' }
							'Excluded'      { 'Ausgeschlossen via -ExcludeLogin.' }
							'Disabled'      { 'Login hat sysadmin-Rechte, ist aber deaktiviert.' }
							'Unexpected'    { 'Sysadmin-Login - kein Ausschluss definiert.' }
						}
						
						$createDate = if ($row.CreateDate) { $row.CreateDate.ToString('yyyy-MM-dd') }
						else { $null }
						
						$detailRows.Add([PSCustomObject]@{
								SqlInstance = $instance
								LoginName   = $loginName
								LoginType   = $row.LoginType
								IsEnabled   = $isEnabled
								IsSa	    = $isSa
								LastPasswordChange = $null # Nicht verfuegbar in aelteren Versionen
								LastLogin   = $null # Nicht verfuegbar in aelteren Versionen
								CreateDate  = $createDate
								Status	    = $status
								Message	    = $msg
							})
					}
				}
				
				# Statistik
				$cntSa = ($detailRows | Where-Object Status -eq 'SA').Count
				$cntExcluded = ($detailRows | Where-Object Status -eq 'Excluded').Count
				$cntDisabled = ($detailRows | Where-Object Status -eq 'Disabled').Count
				$cntUnexpected = ($detailRows | Where-Object Status -eq 'Unexpected').Count
				$cntBuiltinAdmins = ($detailRows | Where-Object Status -eq 'BuiltinAdmins').Count
				
				Invoke-sqmLogging -Message ("[$instance] Gesamt: $($detailRows.Count) | SA: $cntSa | Ausgeschlossen: $cntExcluded | " +
					"Deaktiviert: $cntDisabled | Unerwartet: $cntUnexpected | BUILTIN\\Admins: $cntBuiltinAdmins") -FunctionName $functionName -Level "INFO"
				
				# Dateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "SysadminAccounts_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "SysadminAccounts_${safeInst}_${datestamp}.csv"
				
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Sysadmin-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					# TXT-Bericht (identisch zum vorherigen, daher hier ausgelassen - bitte aus Original uebernehmen)
					# ... (der Code fuer die TXT-Erstellung bleibt unveraendert)
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# MSSQLTools - Sysadmin-Konten Bericht")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# Gesamt    : $($detailRows.Count) Logins")
					$lines.Add("# SA        : $cntSa")
					$lines.Add("# Ausgesch. : $cntExcluded")
					$lines.Add("# Deaktiv.  : $cntDisabled")
					$lines.Add("# Unerwartet: $cntUnexpected  ? PRueFEN")
					$lines.Add("# BUILTIN\\Adm: $cntBuiltinAdmins  ? SICHERHEITSPRueFUNG")
					$lines.Add("# SysExclude: $(if ($ExcludeSysAccounts) { 'Ja (NT SERVICE\*, NT AUTHORITY\*, ##MS_*##)' }
							else { 'Nein (manuell via -ExcludeLogin)' })")
					$lines.Add("# ================================================================")
					
					# BUILTIN\Administrators
					$builtinEntries = $detailRows | Where-Object { $_.Status -eq 'BuiltinAdmins' }
					$lines.Add(""); $lines.Add("# ================================================================")
					$lines.Add("# BUILTIN\Administrators - SICHERHEITSPRueFUNG ERFORDERLICH ($cntBuiltinAdmins)")
					$lines.Add("# ================================================================")
					if ($builtinEntries)
					{
						foreach ($e in $builtinEntries)
						{
							$lines.Add(("  Name   : {0}" -f $e.LoginName))
							$lines.Add(("  Typ    : {0}  |  Aktiv: {1}  |  Erstellt: {2}" -f $e.LoginType, $e.IsEnabled, $e.CreateDate))
							$lines.Add("  ? Empfehlung: Pruefen ob BUILTIN\Administrators Sysadmin-Rechte")
							$lines.Add("    gemaess Sicherheitsrichtlinie zulaessig sind. Ggf. entfernen:")
							$lines.Add("    EXEC sp_dropsrvrolemember 'BUILTIN\Administrators','sysadmin';")
						}
					}
					else { $lines.Add("  (nicht vorhanden - kein Befund)") }
					
					# Unerwartete Konten
					$unexpected = $detailRows | Where-Object { $_.Status -eq 'Unexpected' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# UNERWARTETE SYSADMIN-KONTEN ($cntUnexpected)  ? PRueFEN")
					$lines.Add("# ----------------------------------------------------------------")
					if ($unexpected)
					{
						foreach ($e in ($unexpected | Sort-Object LoginType, LoginName))
						{
							$lines.Add(("  {0,-40} {1,-20} Enabled:{2,-5} Erstellt:{3}" -f $e.LoginName, $e.LoginType, $e.IsEnabled, $e.CreateDate))
						}
					}
					else { $lines.Add("  (keine)") }
					
					# Deaktivierte Konten
					$disabledEntries = $detailRows | Where-Object { $_.Status -eq 'Disabled' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# DEAKTIVIERTE SYSADMIN-KONTEN ($cntDisabled)")
					$lines.Add("# ----------------------------------------------------------------")
					if ($disabledEntries)
					{
						foreach ($e in ($disabledEntries | Sort-Object LoginName))
						{
							$lines.Add("  $($e.LoginName)  [$($e.LoginType)]  Erstellt: $($e.CreateDate)")
						}
					}
					else { $lines.Add("  (keine)") }
					
					# SA-Konto
					$saEntry = $detailRows | Where-Object { $_.Status -eq 'SA' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# SA-KONTO (SID 0x01)")
					$lines.Add("# ----------------------------------------------------------------")
					if ($saEntry)
					{
						foreach ($e in $saEntry)
						{
							$lines.Add(("  Name: {0,-40} Enabled: {1}" -f $e.LoginName, $e.IsEnabled))
						}
					}
					else { $lines.Add("  (nicht gefunden)") }
					
					# Ausgeschlossene Konten
					$excludedEntries = $detailRows | Where-Object { $_.Status -eq 'Excluded' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# AUSGESCHLOSSENE KONTEN ($cntExcluded)")
					$lines.Add("# ----------------------------------------------------------------")
					if ($excludedEntries)
					{
						foreach ($e in ($excludedEntries | Sort-Object LoginType, LoginName))
						{
							$lines.Add(("  {0,-40} {1,-20} Enabled:{2}" -f $e.LoginName, $e.LoginType, $e.IsEnabled))
						}
					}
					else { $lines.Add("  (keine)") }
					
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
					
					Invoke-sqmLogging -Message "[$instance] Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
				}
				
				if ($cntBuiltinAdmins -gt 0)
				{
					Invoke-sqmLogging -Message ("[$instance] BUILTIN\Administrators hat Sysadmin-Rechte - Sicherheitspruefung erforderlich!") -FunctionName $functionName -Level "WARNING"
				}
				if ($cntUnexpected -gt 0)
				{
					Invoke-sqmLogging -Message ("[$instance] $cntUnexpected unerwartete(s) sysadmin-Konto(en) gefunden.") -FunctionName $functionName -Level "WARNING"
				}
				
				$instanceResult = [PSCustomObject]@{
					SqlInstance							     = $instance
					Timestamp							     = $timestamp
					DetailRows							     = $detailRows
					TxtFile								     = $txtFile
					CsvFile								     = $csvFile
					Status								     = if ($cntUnexpected -gt 0 -or $cntBuiltinAdmins -gt 0) { 'Warning' } else { 'OK' }
				}
				$allInstanceResults.Add($instanceResult)
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