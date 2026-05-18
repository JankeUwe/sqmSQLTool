<#
.SYNOPSIS
    Kopiert Logins von einer SQL Server-Quellinstanz auf eine Zielinstanz.

.DESCRIPTION
    uebertraegt SQL- und Windows-Logins von einer Quellinstanz auf eine Zielinstanz.

    Ablauf:
        1. Policy deaktivieren  (Set-sqmSqlPolicyState -State Disable, falls -DisablePolicy $true)
        2. Verbindung + Auth-Mode-Pruefung / Angleichung
        3. Logins laden und filtern
        4. Windows-Logins gegen Active Directory pruefen (AD-Modul erforderlich)
           - Nicht aufloesbare Logins werden uebersprungen und als 'AdOrphan' gemeldet.
        5. Logins kopieren (Copy-DbaLogin, Passwort-Hash + SID-Mapping)
        6. Orphaned Users auf allen Benutzerdatenbanken des Ziels bereinigen
           (Repair-DbaDbOrphanUser - laeuft immer, kein optionaler Schalter)
        7. Policy wieder aktivieren - guaranteed via finally-Block, auch bei Fehler.

    Sicherheits-Modus-Angleichung:
        Hat die Quelle Mixed-Mode (SQL + Windows) und das Ziel nur
        Windows-Authentifizierung, wird das Ziel automatisch auf Mixed-Mode
        umgestellt - sofern -AdjustAuthMode angegeben ist. Ohne diesen Schalter
        bricht die Funktion mit einem Fehler ab und meldet die Abweichung.
        Der SQL Server-Dienst muss nach einer Auth-Mode-aenderung neu gestartet
        werden. Mit -RestartServiceIfRequired wird dies automatisch durchgefuehrt.

    AD-Pruefung:
        Alle Windows-Logins (Typ WindowsUser / WindowsGroup) der Quelle werden
        vor dem Kopieren per Get-ADObject gegen das Active Directory geprueft.
        Nicht aufloesbare Logins werden aus dem Kopier-Batch entfernt und als
        'AdOrphan' im Ergebnis gemeldet.

        Ist das ActiveDirectory-Modul nicht vorhanden, steuert -AdModuleAction
        das Verhalten:
            'Install' (Standard) - Install-sqmAdModule wird aufgerufen.
                                   Schlaegt die Installation fehl, wird die
                                   AD-Pruefung mit Warnung uebersprungen.
            'Skip'               - Warnung, AD-Pruefung wird uebersprungen.
            'Abort'              - Fehler, Funktion bricht ab.

    Login-Filter:
        System-Logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*, BUILTIN\*)
        werden standardmaessig ausgeschlossen. Mit -IncludeSystemLogins werden
        sie einbezogen. Einzelne Logins koennen ueber -ExcludeLogin gefiltert werden.

    Passwoerter bei SQL-Logins:
        Copy-DbaLogin uebertraegt den Passwort-Hash (HASHED) direkt.
        SIDs werden beibehalten (SID-Mapping).

    Orphaned Users:
        Nach dem Kopieren wird Repair-DbaDbOrphanUser auf allen Benutzerdatenbanken
        des Ziels automatisch ausgefuehrt (kein optionaler Schalter).

    Policy:
        Vor dem Kopieren wird per Set-sqmSqlPolicyState die konfigurierte
        Default-Policy auf der Zielinstanz deaktiviert. Nach Abschluss (auch
        bei Fehler) wird sie ueber einen finally-Block garantiert wieder aktiviert.
        Steuerung ueber -DisablePolicy (Standard: $true).
        Der finally-Block reaktiviert die Policy nur, wenn sie zuvor tatsaechlich
        erfolgreich deaktiviert wurde ($policyWasDisabled-Merker).

.PARAMETER Source
    Quell-SQL-Server-Instanz. Pflichtfeld.

.PARAMETER Destination
    Ziel-SQL-Server-Instanz. Pflichtfeld.

.PARAMETER SqlCredential
    Optionales PSCredential fuer beide Instanzen (Quelle und Ziel).
    Fuer unterschiedliche Credentials: -SourceCredential / -DestinationCredential.

.PARAMETER SourceCredential
    PSCredential speziell fuer die Quellinstanz.

.PARAMETER DestinationCredential
    PSCredential speziell fuer die Zielinstanz.

.PARAMETER Login
    Filtert den Kopiervorgang auf diese Login-Namen (Wildcards erlaubt).
    Ohne Angabe werden alle Logins (nach ExcludeLogin-Filter) kopiert.

.PARAMETER ExcludeLogin
    Logins die nicht kopiert werden sollen (Wildcards erlaubt).
    Beispiel: 'AppLogin_*', 'OldUser'.

.PARAMETER IncludeSystemLogins
    Wenn gesetzt, werden auch System-Logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*)
    kopiert. Standard: $false.

.PARAMETER DisablePolicy
    Steuert ob die Default-Policy auf dem Ziel vor dem Kopieren deaktiviert
    und danach wieder aktiviert wird (via Set-sqmSqlPolicyState).
    Standard: $true. Auf $false setzen um das Policy-Handling zu ueberspringen.

.PARAMETER AdjustAuthMode
    Wenn gesetzt und das Ziel nur Windows-Auth hat, die Quelle aber Mixed-Mode,
    wird das Ziel automatisch auf Mixed-Mode umgestellt.
    Ohne diesen Schalter bricht die Funktion bei Modus-Abweichung ab.

.PARAMETER RestartServiceIfRequired
    Wenn gesetzt, wird der SQL Server-Dienst auf dem Zielserver nach einer
    Auth-Mode-aenderung automatisch neu gestartet.
    Ohne diesen Schalter wird nur ein Warnhinweis ausgegeben.

.PARAMETER Force
    Vorhandene Logins auf dem Zielserver werden ueberschrieben.

.PARAMETER AdModuleAction
    Steuert das Verhalten wenn das ActiveDirectory-Modul nicht vorhanden ist.
        'Install' (Standard) - Install-sqmAdModule wird aufgerufen um das Modul
                               zu installieren. Schlaegt die Installation fehl,
                               wird die AD-Pruefung mit Warnung uebersprungen.
        'Skip'               - AD-Pruefung wird mit Warnung uebersprungen.
        'Abort'              - Funktion bricht mit Fehler ab.

.PARAMETER ContinueOnError
    Bei Fehler einzelner Logins mit dem naechsten fortfahren.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (ueberschreibt ContinueOnError).

.PARAMETER Confirm
    Fordert vor kritischen Aktionen eine Bestaetigung an.

.PARAMETER WhatIf
    Zeigt alle geplanten Aktionen ohne Ausfuehrung.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02'

    Kopiert alle Nicht-System-Logins. Policy wird deaktiviert/reaktiviert,
    AD-Pruefung und Orphan-Repair laufen automatisch.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -AdjustAuthMode -RestartServiceIfRequired

    Kopiert alle Logins und stellt den Zielserver bei Bedarf auf Mixed-Mode um.
    Startet den SQL-Dienst automatisch neu, wenn erforderlich.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -Login 'App_*' -Force

    Kopiert nur Logins die mit 'App_' beginnen und ueberschreibt vorhandene.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -DisablePolicy $false -WhatIf

    Simuliert den Vorgang ohne Policy-Handling.

.NOTES
    Voraussetzungen : dbatools, Invoke-sqmLogging, Set-sqmSqlPolicyState, Install-sqmAdModule
    AD-Pruefung      : Benoetigt das ActiveDirectory-Modul (RSAT). Verhalten bei fehlendem
                      Modul ueber -AdModuleAction steuerbar (Install/Skip/Abort).
    Auth-Mode SMO   : Server.LoginMode - Integrated(0/1) = Windows Only, Mixed(2) = SQL+Windows
    Policy-Garantie : Der finally-Block stellt sicher dass die Policy auch bei
                      unbehandelten Ausnahmen wieder aktiviert wird.
#>
function Copy-sqmLogins
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Source,
		[Parameter(Mandatory = $true, Position = 1)]
		[string]$Destination,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Login,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,
		[Parameter(Mandatory = $false)]
		[bool]$DisablePolicy = $true,
		[Parameter(Mandatory = $false)]
		[switch]$AdjustAuthMode,
		[Parameter(Mandatory = $false)]
		[switch]$RestartServiceIfRequired,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Install', 'Skip', 'Abort')]
		[string]$AdModuleAction = 'Install',
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		
		# Systemlogin-Muster (standardmaessig ausgeschlossen)
		$systemLoginPatterns = @('sa', '##MS_*', 'NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*')
		
		# Hilfsfunktion: Prueft ob ein Name einem der Muster entspricht
		function _MatchesAnyPattern
		{
			param ([string]$Name,
				[string[]]$Patterns)
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}
		
		# Hilfsfunktion: Auth-Mode als lesbarer String
		function _AuthModeText
		{
			param ([int]$Mode)
			# SMO ServerLoginMode: Integrated=0, Normal=1 ? Windows Only; Mixed=2 ? SQL+Windows
			switch ($Mode)
			{
				0		{ 'Windows Only (Integrated)' }
				1		{ 'Windows Only (Normal)' }
				2		{ 'Mixed Mode (SQL + Windows)' }
				default { "Unbekannt ($Mode)" }
			}
		}
		
		# Credential-Aufloesung: spezifische Credentials haben Vorrang vor dem gemeinsamen
		$srcCred = if ($SourceCredential) { $SourceCredential }
		elseif ($SqlCredential) { $SqlCredential }
		else { $null }
		
		$dstCred = if ($DestinationCredential) { $DestinationCredential }
		elseif ($SqlCredential) { $SqlCredential }
		else { $null }
		
		$srcConnParams = @{ SqlInstance = $Source; ErrorAction = 'Stop' }
		$dstConnParams = @{ SqlInstance = $Destination; ErrorAction = 'Stop' }
		if ($srcCred) { $srcConnParams['SqlCredential'] = $srcCred }
		if ($dstCred) { $dstConnParams['SqlCredential'] = $dstCred }
		
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		# Hilfsfunktion: Ergebnis-Eintrag hinzufuegen
		function _AddResult
		{
			param ([string]$Action,
				[string]$LoginName,
				[string]$Status,
				[string]$Message)
			$results.Add([PSCustomObject]@{
					Source	    = $Source
					Destination = $Destination
					Action	    = $Action
					LoginName   = $LoginName
					Status	    = $Status
					Message	    = $Message
					Timestamp   = (Get-Date)
				})
		}
		
		# Merker: wurde die Policy tatsaechlich deaktiviert?
		# Wird im finally-Block ausgewertet um unnoetige Reaktivierung zu vermeiden.
		$policyWasDisabled = $false
		
		# ?? AD-Modul sicherstellen ????????????????????????????????????????????
		# Steuerung ueber -AdModuleAction:
		#   'Install' (Standard) ? Install-sqmAdModule aufrufen falls nicht vorhanden
		#   'Skip'               ? wie bisher: Warnung, AD-Pruefung wird uebersprungen
		#   'Abort'              ? Fehler wenn Modul nicht verfuegbar
		$adModuleAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
		
		if (-not $adModuleAvailable)
		{
			switch ($AdModuleAction)
			{
				'Install'
				{
					Invoke-sqmLogging -Message "ActiveDirectory-Modul nicht gefunden - starte Install-sqmAdModule." `
									  -FunctionName $functionName -Level 'INFO'
					
					$adModuleAvailable = Install-sqmAdModule -ContinueOnError -SkipIfPresent $false
					
					if ($adModuleAvailable)
					{
						Invoke-sqmLogging -Message "ActiveDirectory-Modul erfolgreich installiert und geladen." `
										  -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						$adWarnMsg = "Install-sqmAdModule fehlgeschlagen - AD-Pruefung wird uebersprungen."
						Write-Warning $adWarnMsg
						Invoke-sqmLogging -Message $adWarnMsg -FunctionName $functionName -Level 'WARNING'
					}
				}
				'Skip'
				{
					$adWarnMsg = "ActiveDirectory-Modul nicht verfuegbar und -AdModuleAction 'Skip' gesetzt - AD-Pruefung wird uebersprungen."
					Write-Warning $adWarnMsg
					Invoke-sqmLogging -Message $adWarnMsg -FunctionName $functionName -Level 'WARNING'
				}
				'Abort'
				{
					$adErrMsg = "ActiveDirectory-Modul nicht verfuegbar und -AdModuleAction 'Abort' gesetzt - Vorgang abgebrochen. " +
					"Fuehre 'Install-sqmAdModule' manuell aus oder setze -AdModuleAction 'Install'."
					Invoke-sqmLogging -Message $adErrMsg -FunctionName $functionName -Level 'ERROR'
					throw $adErrMsg
				}
			}
		}
		else
		{
			Invoke-sqmLogging -Message "ActiveDirectory-Modul bereits vorhanden - wird importiert." `
							  -FunctionName $functionName -Level 'INFO'
			Import-Module ActiveDirectory -ErrorAction SilentlyContinue
		}
	}
	
	process
	{
		try # aeusserer try ? finally garantiert Policy-Reaktivierung in jedem Fall
		{
			# ??????????????????????????????????????????????????????????????
			# 1. Policy auf Zielinstanz deaktivieren
			# ??????????????????????????????????????????????????????????????
			if ($DisablePolicy)
			{
				$policyDisableAction = "Default-Policy auf '$Destination' deaktivieren"
				if ($PSCmdlet.ShouldProcess($Destination, $policyDisableAction))
				{
					try
					{
						Invoke-sqmLogging -Message $policyDisableAction -FunctionName $functionName -Level 'INFO'
						
						$policyResult = Set-sqmSqlPolicyState `
															  -SqlInstance $Destination `
															  -SqlCredential $dstCred `
															  -State Disable `
															  -ContinueOnError:$ContinueOnError `
															  -EnableException:$EnableException
						
						$policyStatus = ($policyResult | Select-Object -ExpandProperty Status -First 1)
						
						if ($policyStatus -eq 'Success')
						{
							# Nur bei 'Success' muss spaeter reaktiviert werden
							$policyWasDisabled = $true
							_AddResult 'PolicyDisable' '(Server)' 'Success' 'Default-Policy erfolgreich deaktiviert.'
							Invoke-sqmLogging -Message "Policy auf '$Destination' deaktiviert." `
											  -FunctionName $functionName -Level 'INFO'
						}
						elseif ($policyStatus -eq 'Skipped')
						{
							# Policy existiert nicht ? kein Re-Enable erforderlich
							_AddResult 'PolicyDisable' '(Server)' 'Skipped' 'Policy nicht gefunden - uebersprungen.'
							Invoke-sqmLogging -Message "Policy auf '$Destination' nicht gefunden - uebersprungen." `
											  -FunctionName $functionName -Level 'WARNING'
						}
						else
						{
							$msg = "Policy-Deaktivierung auf '$Destination' fehlgeschlagen (Status: $policyStatus). Abbruch."
							Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
							_AddResult 'PolicyDisable' '(Server)' 'Failed' $msg
							if (-not $ContinueOnError -and $EnableException) { throw $msg }
							if (-not $ContinueOnError) { return $results }
						}
					}
					catch
					{
						$msg = "Fehler bei Policy-Deaktivierung auf '$Destination': $($_.Exception.Message)"
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
						_AddResult 'PolicyDisable' '(Server)' 'Failed' $msg
						if (-not $ContinueOnError -and $EnableException) { throw }
						if (-not $ContinueOnError) { return $results }
					}
				}
				else
				{
					_AddResult 'PolicyDisable' '(Server)' 'WhatIf' 'WhatIf: Policy wuerde deaktiviert.'
				}
			}
			
			# ??????????????????????????????????????????????????????????????
			# 2. Verbindung zu Quelle und Ziel aufbauen (SMO-Server-Objekte)
			# ??????????????????????????????????????????????????????????????
			Invoke-sqmLogging -Message "Verbinde mit Quelle '$Source' und Ziel '$Destination'." `
							  -FunctionName $functionName -Level 'INFO'
			try
			{
				$srcServer = Connect-DbaInstance @srcConnParams
			}
			catch
			{
				$msg = "Verbindung zur Quellinstanz '$Source' fehlgeschlagen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				_AddResult 'Connect' '(Quelle)' 'Failed' $msg
				if ($EnableException) { throw }
				return $results
			}
			
			try
			{
				$dstServer = Connect-DbaInstance @dstConnParams
			}
			catch
			{
				$msg = "Verbindung zur Zielinstanz '$Destination' fehlgeschlagen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				_AddResult 'Connect' '(Ziel)' 'Failed' $msg
				if ($EnableException) { throw }
				return $results
			}
			
			# ??????????????????????????????????????????????????????????????
			# 3. Authentifizierungsmodi pruefen und ggf. angleichen
			#    SMO ServerLoginMode: Integrated=0, Normal=1 ? Windows Only
			#                         Mixed=2               ? SQL + Windows
			# ??????????????????????????????????????????????????????????????
			$srcLoginMode = [int]$srcServer.LoginMode
			$dstLoginMode = [int]$dstServer.LoginMode
			$srcModeText = _AuthModeText $srcLoginMode
			$dstModeText = _AuthModeText $dstLoginMode
			$srcIsMixed = ($srcLoginMode -eq 2)
			$dstIsWindowsOnly = ($dstLoginMode -ne 2)
			
			Invoke-sqmLogging -Message "Quelle Auth-Mode: $srcModeText | Ziel Auth-Mode: $dstModeText" `
							  -FunctionName $functionName -Level 'INFO'
			
			if ($srcIsMixed -and $dstIsWindowsOnly)
			{
				if (-not $AdjustAuthMode)
				{
					$msg = "Auth-Mode-Konflikt: Quelle '$Source' ist '$srcModeText', " +
					"Ziel '$Destination' ist '$dstModeText'. SQL-Logins koennen nicht " +
					"kopiert werden. Verwende -AdjustAuthMode um das Ziel umzustellen."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
					_AddResult 'AuthModeCheck' '(alle)' 'Failed' $msg
					if ($EnableException) { throw $msg }
					Write-Error $msg
					return $results
				}
				
				$adjustAction = "Ziel '$Destination' von '$dstModeText' auf Mixed-Mode umstellen"
				if ($PSCmdlet.ShouldProcess($Destination, $adjustAction))
				{
					try
					{
						Invoke-sqmLogging -Message $adjustAction -FunctionName $functionName -Level 'INFO'
						$dstServer.LoginMode = [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed
						$dstServer.Alter()
						_AddResult 'AdjustAuthMode' '(Server)' 'Success' `
								   "Ziel von '$dstModeText' auf Mixed-Mode umgestellt. Neustart erforderlich."
						Invoke-sqmLogging -Message "Auth-Mode auf Ziel erfolgreich auf Mixed-Mode gesetzt." `
										  -FunctionName $functionName -Level 'INFO'
						
						if ($RestartServiceIfRequired)
						{
							$restartAction = "SQL Server-Dienst auf '$Destination' neu starten"
							if ($PSCmdlet.ShouldProcess($Destination, $restartAction))
							{
								try
								{
									Invoke-sqmLogging -Message $restartAction -FunctionName $functionName -Level 'INFO'
									Restart-DbaService -SqlInstance $Destination -Type Engine `
													   -Credential $dstCred -Force -EnableException
									Invoke-sqmLogging -Message "Dienst auf '$Destination' neu gestartet." `
													  -FunctionName $functionName -Level 'INFO'
									_AddResult 'RestartService' '(Server)' 'Success' 'Dienst neu gestartet.'
									Start-Sleep -Seconds 5
									$dstServer = Connect-DbaInstance @dstConnParams
								}
								catch
								{
									$msg = "Dienstneustart auf '$Destination' fehlgeschlagen: $($_.Exception.Message)"
									Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
									_AddResult 'RestartService' '(Server)' 'Failed' $msg
									if (-not $ContinueOnError -and $EnableException) { throw }
								}
							}
							else
							{
								_AddResult 'RestartService' '(Server)' 'WhatIf' 'WhatIf: Dienst-Neustart wuerde ausgefuehrt.'
							}
						}
						else
						{
							$warnMsg = "Auth-Mode auf '$Destination' geaendert, aber der SQL Server-Dienst wurde " +
							"NICHT neu gestartet. aenderung wird erst nach Neustart wirksam. " +
							"Verwende -RestartServiceIfRequired fuer automatischen Neustart."
							Write-Warning $warnMsg
							Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level 'WARNING'
							_AddResult 'AdjustAuthMode' '(Server)' 'Warning' $warnMsg
						}
					}
					catch
					{
						$msg = "Fehler beim Umstellen des Auth-Mode auf '$Destination': $($_.Exception.Message)"
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
						_AddResult 'AdjustAuthMode' '(Server)' 'Failed' $msg
						if (-not $ContinueOnError -and $EnableException) { throw }
						if (-not $ContinueOnError) { return $results }
					}
				}
				else
				{
					_AddResult 'AdjustAuthMode' '(Server)' 'WhatIf' "WhatIf: $adjustAction"
				}
			}
			else
			{
				# Kein Konflikt (Windows/Windows, Mixed/Mixed oder Windows?Mixed)
				$noConflictMsg = "Quelle: $srcModeText | Ziel: $dstModeText - kein Auth-Mode-Konflikt."
				Invoke-sqmLogging -Message $noConflictMsg -FunctionName $functionName -Level 'INFO'
				_AddResult 'AuthModeCheck' '(Server)' 'OK' $noConflictMsg
			}
			
			# ??????????????????????????????????????????????????????????????
			# 4. Logins von der Quelle laden und filtern
			# ??????????????????????????????????????????????????????????????
			Invoke-sqmLogging -Message "Lade Logins von Quelle '$Source'." `
							  -FunctionName $functionName -Level 'INFO'
			try
			{
				$sourceLogins = Get-DbaLogin @srcConnParams
				
				if (-not $IncludeSystemLogins)
				{
					$sourceLogins = $sourceLogins | Where-Object {
						-not (_MatchesAnyPattern $_.Name $systemLoginPatterns) -and
						-not $_.IsSystemObject
					}
				}
				
				if ($Login)
				{
					$sourceLogins = $sourceLogins | Where-Object {
						$n = $_.Name
						($Login | Where-Object { $n -like $_ }).Count -gt 0
					}
				}
				
				if ($ExcludeLogin)
				{
					$sourceLogins = $sourceLogins | Where-Object {
						-not (_MatchesAnyPattern $_.Name $ExcludeLogin)
					}
				}
				
				if (-not $sourceLogins -or @($sourceLogins).Count -eq 0)
				{
					$msg = "Keine Logins nach Filter-Anwendung auf '$Source' vorhanden. Vorgang beendet."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
					Write-Warning $msg
					_AddResult 'FilterLogins' '(alle)' 'Skipped' $msg
					return $results
				}
				
				Invoke-sqmLogging -Message "$(@($sourceLogins).Count) Login(s) nach Filter vorgemerkt." `
								  -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				$msg = "Fehler beim Laden der Logins von '$Source': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				_AddResult 'LoadLogins' '(alle)' 'Failed' $msg
				if ($EnableException) { throw }
				return $results
			}
			
			# ??????????????????????????????????????????????????????????????
			# 5. AD-Pruefung fuer Windows-Logins
			#    WindowsUser / WindowsGroup werden per Get-ADObject geprueft.
			#    Nicht aufloesbare Logins werden aus dem Batch entfernt und
			#    als 'AdOrphan' im Ergebnis gemeldet.
			# ??????????????????????????????????????????????????????????????
			$windowsLogins = @($sourceLogins | Where-Object {
					$_.LoginType -in @('WindowsUser', 'WindowsGroup')
				})
			
			if ($windowsLogins.Count -gt 0 -and $adModuleAvailable)
			{
				Invoke-sqmLogging -Message "AD-Pruefung: $($windowsLogins.Count) Windows-Login(s) pruefen." `
								  -FunctionName $functionName -Level 'INFO'
				
				$adOrphanNames = [System.Collections.Generic.List[string]]::new()
				
				foreach ($winLogin in $windowsLogins)
				{
					# Format DOMAIN\AccountName ? SamAccountName extrahieren
					$samName = $winLogin.Name -replace '^.*\\', ''
					
					try
					{
						$adObj = Get-ADObject -Filter { SamAccountName -eq $samName } `
											  -ErrorAction Stop |
						Select-Object -First 1
						
						if ($adObj)
						{
							Invoke-sqmLogging -Message "AD: '$($winLogin.Name)' aufgeloest ($($adObj.ObjectClass))." `
											  -FunctionName $functionName -Level 'VERBOSE'
						}
						else
						{
							$adOrphanNames.Add($winLogin.Name)
							$adMsg = "Windows-Login '$($winLogin.Name)' nicht im AD gefunden - wird uebersprungen."
							Write-Warning $adMsg
							Invoke-sqmLogging -Message $adMsg -FunctionName $functionName -Level 'WARNING'
							_AddResult 'AdCheck' $winLogin.Name 'AdOrphan' $adMsg
						}
					}
					catch
					{
						# AD-Abfrage fehlgeschlagen (z.B. kein DC erreichbar) ? Login ueberspringen
						$adMsg = "AD-Abfrage fuer '$($winLogin.Name)' fehlgeschlagen: $($_.Exception.Message) - wird uebersprungen."
						Write-Warning $adMsg
						Invoke-sqmLogging -Message $adMsg -FunctionName $functionName -Level 'WARNING'
						_AddResult 'AdCheck' $winLogin.Name 'AdQueryFailed' $adMsg
						$adOrphanNames.Add($winLogin.Name)
					}
				}
				
				if ($adOrphanNames.Count -gt 0)
				{
					# Nicht aufloesbare Logins aus dem Kopier-Batch entfernen
					$sourceLogins = $sourceLogins | Where-Object { $_.Name -notin $adOrphanNames }
					Invoke-sqmLogging -Message "$($adOrphanNames.Count) Windows-Login(s) nach AD-Pruefung entfernt." `
									  -FunctionName $functionName -Level 'INFO'
				}
				else
				{
					Invoke-sqmLogging -Message "AD-Pruefung: alle Windows-Logins aufloesbar." `
									  -FunctionName $functionName -Level 'INFO'
					_AddResult 'AdCheck' '(alle Windows-Logins)' 'OK' 'Alle Windows-Logins im AD aufgeloest.'
				}
			}
			elseif ($windowsLogins.Count -gt 0 -and -not $adModuleAvailable)
			{
				_AddResult 'AdCheck' '(alle Windows-Logins)' 'Skipped' `
						   'AD-Modul nicht verfuegbar - AD-Pruefung uebersprungen.'
			}
			
			# Nach AD-Filter erneut auf leere Liste pruefen
			if (-not $sourceLogins -or @($sourceLogins).Count -eq 0)
			{
				$msg = "Keine kopierbaren Logins nach AD-Pruefung verbleibend. Vorgang beendet."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
				Write-Warning $msg
				_AddResult 'FilterLogins' '(alle)' 'Skipped' $msg
				return $results
			}
			
			# ??????????????????????????????????????????????????????????????
			# 6. Logins kopieren (Copy-DbaLogin)
			#    Passwort-Hash (HASHED) und SID-Mapping werden uebertragen.
			# ??????????????????????????????????????????????????????????????
			$loginNames = @($sourceLogins | Select-Object -ExpandProperty Name)
			$loginCount = $loginNames.Count
			$copyAction = "$loginCount Login(s) von '$Source' nach '$Destination' kopieren"
			
			if ($PSCmdlet.ShouldProcess($Destination, $copyAction))
			{
				try
				{
					Invoke-sqmLogging -Message $copyAction -FunctionName $functionName -Level 'INFO'
					
					$copyParams = @{
						Source		    = $Source
						Destination	    = $Destination
						Login		    = $loginNames
						EnableException = $EnableException.IsPresent
					}
					if ($srcCred) { $copyParams['SqlCredential'] = $srcCred }
					if ($dstCred) { $copyParams['DestinationSqlCredential'] = $dstCred }
					if ($Force) { $copyParams['Force'] = $true }
					
					$copyResults = Copy-DbaLogin @copyParams
					
					foreach ($item in $copyResults)
					{
						$itemStatus = if ($item.Status -eq 'Successful') { 'Success' }
						else { $item.Status }
						$itemMsg = if ($item.Notes) { $item.Notes }
						else { $item.Status }
						_AddResult 'CopyLogin' $item.Name $itemStatus $itemMsg
						
						$logLevel = if ($item.Status -eq 'Successful') { 'INFO' }
						else { 'WARNING' }
						Invoke-sqmLogging -Message "Login '$($item.Name)': $itemStatus - $itemMsg" `
										  -FunctionName $functionName -Level $logLevel
					}
				}
				catch
				{
					$msg = "Fehler beim Kopieren der Logins: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
					_AddResult 'CopyLogin' '(alle)' 'Failed' $msg
					if ($EnableException) { throw }
				}
			}
			else
			{
				foreach ($n in $loginNames)
				{
					_AddResult 'CopyLogin' $n 'WhatIf' 'WhatIf: Login wuerde kopiert.'
				}
			}
			
			# ??????????????????????????????????????????????????????????????
			# 7. Orphaned Users auf Ziel bereinigen (immer, kein Schalter)
			#    Alle Benutzerdatenbanken im Status 'Normal' werden geprueft.
			# ??????????????????????????????????????????????????????????????
			$repairAction = "Orphaned Users auf '$Destination' bereinigen"
			if ($PSCmdlet.ShouldProcess($Destination, $repairAction))
			{
				try
				{
					Invoke-sqmLogging -Message $repairAction -FunctionName $functionName -Level 'INFO'
					
					$userDatabases = @(
						Get-DbaDatabase @dstConnParams |
						Where-Object { -not $_.IsSystemObject -and $_.Status -eq 'Normal' } |
						Select-Object -ExpandProperty Name
					)
					
					if ($userDatabases.Count -gt 0)
					{
						$repairResult = Repair-DbaDbOrphanUser `
															   -SqlInstance $Destination `
															   -Database $userDatabases `
															   -SqlCredential $dstCred `
															   -EnableException:$EnableException.IsPresent `
															   -ErrorAction SilentlyContinue
						
						$repairedCount = @($repairResult).Count
						Invoke-sqmLogging -Message "Orphan-Repair: $repairedCount Eintrag/Eintraege auf $($userDatabases.Count) DB(s)." `
										  -FunctionName $functionName -Level 'INFO'
						_AddResult 'RepairOrphanUsers' '(Ziel-DBs)' 'Success' `
								   "Orphan-Repair auf $($userDatabases.Count) Datenbank(en): $repairedCount Eintraege bereinigt."
					}
					else
					{
						_AddResult 'RepairOrphanUsers' '(Ziel-DBs)' 'Skipped' `
								   'Keine Benutzerdatenbanken im Status Normal auf Ziel gefunden.'
					}
				}
				catch
				{
					$msg = "Fehler beim Orphan-Repair auf '$Destination': $($_.Exception.Message)"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
					_AddResult 'RepairOrphanUsers' '(Ziel-DBs)' 'Failed' $msg
					if ($EnableException) { throw }
				}
			}
			else
			{
				_AddResult 'RepairOrphanUsers' '(Ziel-DBs)' 'WhatIf' 'WhatIf: Orphan-Repair wuerde ausgefuehrt.'
			}
		}
		finally
		{
			# ??????????????????????????????????????????????????????????????
			# 8. Policy auf Zielinstanz garantiert wieder aktivieren
			#    Laeuft immer - auch bei unbehandelten Ausnahmen im try-Block.
			#    Nur wenn $policyWasDisabled = $true (d.h. erfolgreich deaktiviert).
			#    EnableException=$false im finally-Block: Fehler hier NIEMALS werfen.
			# ??????????????????????????????????????????????????????????????
			if ($DisablePolicy -and $policyWasDisabled)
			{
				$reenableAction = "Default-Policy auf '$Destination' wieder aktivieren"
				if ($PSCmdlet.ShouldProcess($Destination, $reenableAction))
				{
					try
					{
						Invoke-sqmLogging -Message $reenableAction -FunctionName $functionName -Level 'INFO'
						
						$reEnableResult = Set-sqmSqlPolicyState `
																-SqlInstance $Destination `
																-SqlCredential $dstCred `
																-State Enable `
																-ContinueOnError:$ContinueOnError `
																-EnableException:$false # im finally-Block niemals werfen
						
						$reEnableStatus = ($reEnableResult | Select-Object -ExpandProperty Status -First 1)
						_AddResult 'PolicyEnable' '(Server)' $reEnableStatus "Policy reaktiviert: $reEnableStatus"
						Invoke-sqmLogging -Message "Policy-Reaktivierung auf '$Destination': $reEnableStatus" `
										  -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						# Fehler im finally-Block nur loggen, nicht weiterwerfen -
						# sonst wuerde eine urspruengliche Ausnahme verdeckt.
						$msg = "KRITISCH: Policy-Reaktivierung auf '$Destination' fehlgeschlagen: $($_.Exception.Message)"
						Write-Warning $msg
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
						_AddResult 'PolicyEnable' '(Server)' 'Failed' $msg
					}
				}
				else
				{
					_AddResult 'PolicyEnable' '(Server)' 'WhatIf' 'WhatIf: Policy wuerde reaktiviert.'
				}
			}
		}
	}
	
	end
	{
		$successCount = @($results | Where-Object Status -eq 'Success').Count
		$failCount = @($results | Where-Object Status -eq 'Failed').Count
		$warnCount = @($results | Where-Object Status -in @('Warning', 'AdOrphan', 'AdQueryFailed')).Count
		
		$summaryMsg = "Copy-sqmLogins abgeschlossen - Erfolg: $successCount | Fehler: $failCount | Warnungen/Orphans: $warnCount"
		Invoke-sqmLogging -Message $summaryMsg -FunctionName $functionName -Level 'INFO'
		Write-Host $summaryMsg -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' }
			else { 'Green' })
		
		return $results
	}
}