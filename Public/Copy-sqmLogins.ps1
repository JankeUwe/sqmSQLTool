<#
.SYNOPSIS
    Copies logins from a source SQL Server instance to a target instance.

.DESCRIPTION
    Transfers SQL and Windows logins from a source instance to a target instance.

    Process:
        1. Connect + authentication mode check / alignment
        2. Load and filter logins
        3. Check Windows logins against Active Directory (AD module required)
           - Unresolvable logins are skipped and reported as 'AdOrphan'.
        4. Disable policy (Set-sqmSqlPolicyState -State Disable, if -DisablePolicy $true)
        5. Copy logins (Copy-DbaLogin, password hash + SID mapping)
        6. Re-enable policy - guaranteed via a finally block scoped tightly around step 5,
           even on error. The policy is only disabled for the duration of the actual copy,
           not for the connect/auth-mode/AD-check steps before it.
        7. Repair orphaned users on all user databases on the target
           (Repair-DbaDbOrphanUser - always runs, no optional switch)

    Authentication mode alignment:
        If the source uses Mixed Mode (SQL + Windows) and the target is set to
        Windows Authentication only, the target is automatically switched to Mixed Mode
        - provided -AdjustAuthMode is specified. Without this switch, the function
        aborts with an error and reports the discrepancy.
        The SQL Server service must be restarted after an authentication mode change.
        With -RestartServiceIfRequired this is done automatically.

    AD check:
        All Windows logins (type WindowsUser / WindowsGroup) from the source are
        validated against Active Directory via Get-ADObject before copying.
        Unresolvable logins are removed from the copy batch and reported as
        'AdOrphan' in the result.

        If the ActiveDirectory module is not present, -AdModuleAction controls behavior:
            'Install' (default) - Install-sqmAdModule is called.
                                  If installation fails, the AD check is
                                  skipped with a warning.
            'Skip'              - Warning, AD check is skipped.
            'Abort'             - Error, function aborts.

    Login filter:
        System logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*, BUILTIN\*)
        are excluded by default. With -IncludeSystemLogins they are included.
        Individual logins can be filtered via -ExcludeLogin.

    Passwords for SQL logins:
        Copy-DbaLogin transfers the password hash (HASHED) directly.
        SIDs are preserved (SID mapping).

    Orphaned users:
        After copying, Repair-DbaDbOrphanUser is automatically run on all user
        databases on the target (no optional switch).

    Policy:
        Immediately before the Copy-DbaLogin call, Set-sqmSqlPolicyState disables the
        configured default policy on the target instance; immediately after (in a finally
        block scoped to just that step) it is guaranteed to be re-enabled, even on error.
        Connect, auth-mode check and the AD lookup run BEFORE this window with the policy
        still enabled - the disabled window is kept as short as possible.
        Controlled by -DisablePolicy (default: $true).
        Re-enable only runs if the policy was previously successfully disabled
        ($policyWasDisabled flag).

.PARAMETER Source
    Source SQL Server instance. Mandatory.

.PARAMETER Destination
    Target SQL Server instance. Mandatory.

.PARAMETER SqlCredential
    Optional PSCredential for both instances (source and target).
    For different credentials use -SourceCredential / -DestinationCredential.

.PARAMETER SourceCredential
    PSCredential specifically for the source instance.

.PARAMETER DestinationCredential
    PSCredential specifically for the target instance.

.PARAMETER Login
    Filters the copy operation to these login names (wildcards allowed).
    Without specification, all logins (after ExcludeLogin filter) are copied.

.PARAMETER ExcludeLogin
    Logins that should not be copied (wildcards allowed).
    Example: 'AppLogin_*', 'OldUser'.

.PARAMETER IncludeSystemLogins
    When set, system logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*) are also copied.
    Default: $false.

.PARAMETER DisablePolicy
    Controls whether the default policy on the target is disabled before copying
    and re-enabled afterwards (via Set-sqmSqlPolicyState).
    Default: $true. Set to $false to skip policy handling.

.PARAMETER AdjustAuthMode
    When set and the target is Windows-only auth but the source uses Mixed Mode,
    the target is automatically switched to Mixed Mode.
    Without this switch the function aborts on mode mismatch.

.PARAMETER RestartServiceIfRequired
    When set, the SQL Server service on the target server is automatically restarted
    after an authentication mode change.
    Without this switch, only a warning is displayed.

.PARAMETER Force
    Existing logins on the target server are overwritten.

.PARAMETER AdModuleAction
    Controls behavior when the ActiveDirectory module is not present.
        'Install' (default) - Install-sqmAdModule is called to install the module.
                              If installation fails, the AD check is skipped with a warning.
        'Skip'              - AD check is skipped with a warning.
        'Abort'             - Function aborts with an error.

.PARAMETER ContinueOnError
    Continue with the next login on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before critical actions.

.PARAMETER WhatIf
    Shows all planned actions without executing them.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02'

    Copies all non-system logins. Policy is disabled/re-enabled,
    AD check and orphan repair run automatically.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -AdjustAuthMode -RestartServiceIfRequired

    Copies all logins and switches the target server to Mixed Mode if needed.
    Automatically restarts the SQL service if required.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -Login 'App_*' -Force

    Copies only logins starting with 'App_' and overwrites existing ones.

.EXAMPLE
    Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -DisablePolicy $false -WhatIf

    Simulates the operation without policy handling.

.NOTES
    Prerequisites : dbatools, Invoke-sqmLogging, Set-sqmSqlPolicyState, Install-sqmAdModule
    AD check       : Requires the ActiveDirectory module (RSAT). Behavior when module is missing
                     is controllable via -AdModuleAction (Install/Skip/Abort).
    Auth Mode SMO  : Server.LoginMode - Integrated(0/1) = Windows Only, Mixed(2) = SQL+Windows
    Policy guarantee: A finally block scoped tightly around the Copy-DbaLogin call ensures
                      the policy is re-enabled immediately afterwards, even on unhandled
                      exceptions during the copy.
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
		
		# Credential-Aufloesung + Connection-Parameter ZUERST aufbauen - die sa-/sysadmin-
		# Erkennung weiter unten braucht $srcConnParams bereits. (Frueher standen diese Zeilen
		# weiter unten, wodurch die Abfrage immer mit leerem Splat fehlschlug und auf das Literal
		# 'sa' zurueckfiel - eine auf einem Node umbenannte sa wurde dadurch NICHT erkannt.)
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

		# Systemlogin-Muster (standardmaessig ausgeschlossen)
		# Hinweis: 'sa' wird ueber die well-known SID 0x01 erkannt (namensunabhaengig) und
		# zusaetzlich ueber die dynamische sysadmin-Erkennung - umbenannte sa-Accounts inklusive.
		$systemLoginPatterns = @('##MS_*', 'NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*')

		# 'sa' per well-known SID 0x01 ermitteln (Name kann auf einem Node umbenannt sein)
		$saLoginName = $null
		try
		{
			$saLoginName = (Invoke-DbaQuery @srcConnParams -Query "SELECT SUSER_SNAME(0x01) AS n" -ErrorAction Stop).n
			if (-not [string]::IsNullOrWhiteSpace($saLoginName))
			{
				$systemLoginPatterns += $saLoginName
				Invoke-sqmLogging -Message "Quelle: 'sa' (SID 0x01) heisst '$saLoginName' - wird von der Synchronisierung ausgeschlossen." `
								  -FunctionName $functionName -Level 'INFO'
			}
		}
		catch { }

		# Dynamisch alle sysadmin-Accounts ermitteln (handhaben umbenannte 'sa' / weitere sysadmins)
		$sysAdminLogins = @()
		try
		{
			$query = "SELECT name FROM sys.server_principals WHERE (is_srvrolemember('sysadmin', name) = 1 OR sid = 0x01) AND name NOT LIKE '##%'"
			$sysAdminLogins = @((Invoke-DbaQuery @srcConnParams -Query $query).name)
			if ($sysAdminLogins.Count -gt 0)
			{
				Invoke-sqmLogging -Message "Gefundene sysadmin-Logins: $($sysAdminLogins -join ', ')" `
								  -FunctionName $functionName -Level 'INFO'
				$systemLoginPatterns += $sysAdminLogins
			}
		}
		catch
		{
			# Fallback: 'sa' verwenden wenn Abfrage fehlschlägt
			Invoke-sqmLogging -Message "WARNUNG: Sysadmin-Logins konnten nicht ermittelt werden, verwende 'sa' als Fallback: $($_.Exception.Message)" `
							  -FunctionName $functionName -Level 'WARNING'
			$systemLoginPatterns += @('sa')
		}
		
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
		
		# (Credential-Aufloesung + $srcConnParams/$dstConnParams werden bereits oben im
		#  begin-Block aufgebaut, damit die sa-/sysadmin-Erkennung sie nutzen kann.)
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

		# Hilfsfunktion: Policy auf Zielinstanz deaktivieren.
		# Wird absichtlich erst UNMITTELBAR vor Copy-DbaLogin aufgerufen (nicht vor Connect/
		# Auth-Mode-Check/AD-Pruefung) - das Zeitfenster, in dem eine sicherheitsrelevante
		# Policy deaktiviert ist, soll so kurz wie moeglich sein.
		# Rueckgabe: $true nur wenn tatsaechlich deaktiviert wurde (dann muss _EnablePolicy
		# spaeter aufgerufen werden), sonst $false.
		function _DisablePolicy
		{
			if (-not $DisablePolicy) { return $false }

			$_configuredPolicy = Get-sqmConfig -Key 'DefaultPolicy' 3>$null
			if ([string]::IsNullOrWhiteSpace($_configuredPolicy))
			{
				$skipMsg = "Policy-Handling uebersprungen: kein 'DefaultPolicy' in der Modulkonfiguration. " +
						   "Verwende 'Set-sqmConfig -DefaultPolicy <Name>' um einen Policy-Namen zu setzen."
				Write-Warning $skipMsg
				Invoke-sqmLogging -Message $skipMsg -FunctionName $functionName -Level 'WARNING'
				_AddResult 'PolicyDisable' '(Server)' 'Skipped' $skipMsg
				return $false
			}

			try
			{
				$policyDisableAction = "Default-Policy auf '$Destination' deaktivieren"
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
					_AddResult 'PolicyDisable' '(Server)' 'Success' 'Default-Policy erfolgreich deaktiviert.'
					Invoke-sqmLogging -Message "Policy auf '$Destination' deaktiviert." `
									  -FunctionName $functionName -Level 'INFO'
					return $true
				}
				elseif ($policyStatus -eq 'Skipped')
				{
					# Policy existiert nicht - kein Re-Enable erforderlich
					_AddResult 'PolicyDisable' '(Server)' 'Skipped' 'Policy nicht gefunden - uebersprungen.'
					Invoke-sqmLogging -Message "Policy auf '$Destination' nicht gefunden - uebersprungen." `
									  -FunctionName $functionName -Level 'WARNING'
					return $false
				}
				else
				{
					$msg = "Policy-Deaktivierung auf '$Destination' fehlgeschlagen (Status: $policyStatus)."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
					_AddResult 'PolicyDisable' '(Server)' 'Failed' $msg
					if ($EnableException) { throw $msg }
					return $false
				}
			}
			catch
			{
				$msg = "Fehler bei Policy-Deaktivierung auf '$Destination': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				_AddResult 'PolicyDisable' '(Server)' 'Failed' $msg
				if ($EnableException) { throw }
				return $false
			}
		}

		# Hilfsfunktion: Policy auf Zielinstanz wieder aktivieren.
		# Wird in einem eng um Copy-DbaLogin gelegten finally-Block aufgerufen - laeuft also
		# unmittelbar NACH dem eigentlichen Lauf, garantiert auch bei Fehlern in Copy-DbaLogin.
		# EnableException wird hier absichtlich NIE gesetzt: ein Fehler beim Reaktivieren darf
		# eine urspruengliche Ausnahme aus dem Copy-Vorgang nicht verdecken.
		function _EnablePolicy
		{
			try
			{
				$reenableAction = "Default-Policy auf '$Destination' wieder aktivieren"
				Invoke-sqmLogging -Message $reenableAction -FunctionName $functionName -Level 'INFO'

				$reEnableResult = Set-sqmSqlPolicyState `
														-SqlInstance $Destination `
														-SqlCredential $dstCred `
														-State Enable `
														-ContinueOnError:$ContinueOnError `
														-EnableException:$false

				$reEnableStatus = ($reEnableResult | Select-Object -ExpandProperty Status -First 1)
				_AddResult 'PolicyEnable' '(Server)' $reEnableStatus "Policy reaktiviert: $reEnableStatus"
				Invoke-sqmLogging -Message "Policy-Reaktivierung auf '$Destination': $reEnableStatus" `
								  -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				# Fehler hier nur loggen, nicht weiterwerfen - sonst wuerde eine urspruengliche
				# Ausnahme aus dem Copy-Vorgang verdeckt.
				$msg = "KRITISCH: Policy-Reaktivierung auf '$Destination' fehlgeschlagen: $($_.Exception.Message)"
				Write-Warning $msg
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				_AddResult 'PolicyEnable' '(Server)' 'Failed' $msg
			}
		}

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
			# 1. Policy-Deaktivierung liegt jetzt eng um Copy-DbaLogin (Schritt 6, s.u.),
			#    nicht mehr hier vor Connect/Auth-Mode-Check/AD-Pruefung - das Zeitfenster
			#    mit deaktivierter Policy soll so kurz wie moeglich sein.
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
				
				# 'sa' (well-known SID 0x01) NIE kopieren - die SID-Kollision auf dem Ziel ist
				# garantiert, auch wenn sa auf einem Node umbenannt wurde. Unabhaengig von
				# -IncludeSystemLogins.
				$sourceLogins = $sourceLogins | Where-Object {
					-not ($_.Sid -and $_.Sid.Length -eq 1 -and [int]$_.Sid[0] -eq 1)
				}

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
				# Policy-Deaktivierung liegt bewusst HIER, direkt vor Copy-DbaLogin - und wird
				# im finally garantiert direkt danach wieder aktiviert (s. _DisablePolicy/
				# _EnablePolicy oben in begin). Verbinden/Auth-Mode-Check/AD-Pruefung laufen
				# VOR diesem Block mit weiterhin aktiver Policy.
				$policyWasDisabled = $false
				try
				{
					Invoke-sqmLogging -Message $copyAction -FunctionName $functionName -Level 'INFO'

					$policyWasDisabled = _DisablePolicy

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
				finally
				{
					# Laeuft garantiert direkt nach Copy-DbaLogin, auch bei Fehlern darin -
					# das Deaktivierungsfenster endet hier, nicht erst am Ende der Funktion.
					if ($policyWasDisabled) { _EnablePolicy }
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
			# Policy-Reaktivierung liegt jetzt eng um Copy-DbaLogin (Schritt 6, s.o.) und laeuft
			# dort in einem eigenen finally direkt nach dem Copy-Vorgang - nicht mehr erst hier
			# am Ende der gesamten Funktion (nach Orphan-Repair etc.).
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