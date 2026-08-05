<#
.SYNOPSIS
    Fuehrt die eigentliche Rollen-Vergabe bzw. -Entziehung (sysadmin oder dbcreator) auf
    EINER Instanz aus, legt dabei optional einen fehlenden AD-Login an, entfernt ihn beim
    Entzug wieder und loescht optional den aufrufenden SQL-Agent-Job nach Erfolg
    (selbstloeschender Job).

.DESCRIPTION
    Wird von den durch Grant-sqmTemporarySysadmin erzeugten Agent-Jobs aufgerufen,
    kann aber auch manuell verwendet werden (z. B. fuer einen vorzeitigen Entzug).

    Aktion:
      Grant   -> (optional CREATE LOGIN ... FROM WINDOWS) + ALTER SERVER ROLE [<Role>] ADD MEMBER
      Revoke  -> ALTER SERVER ROLE [<Role>] DROP MEMBER + (optional DROP LOGIN)

    Sowohl Windows-/AD-Logins (DOMAIN\Konto bzw. AD-Gruppe) als auch bereits vorhandene
    SQL-Auth-Logins werden unterstuetzt. Automatisches Anlegen bei Fehlen
    (-CreateLoginIfMissing) ist auf Windows-/AD-Logins beschraenkt - fuer einen fehlenden
    SQL-Login gibt es keine sinnvolle automatische Kennwortvergabe ohne weitere Vorgaben,
    der Aufruf schlaegt in dem Fall mit einer klaren Fehlermeldung fehl.

    Zwei unabhaengige, beide standardmaessig aktive Schutzmechanismen gegen PBM
    (Policy-Based Management) -Blockaden waehrend Login-Anlage/Rollenaenderung/Login-Entfernung:

      -DisableServerTriggers (Default $true): deaktiviert ALLE aktuell aktivierten
      serverweiten DDL-Trigger fuer die Dauer der Aktion und stellt in einem finally-Block
      GENAU den vorherigen Zustand wieder her (kein pauschales "alle wieder an" - nur die
      Trigger, die vorher tatsaechlich aktiviert waren). Notwendig, weil der eingebaute
      syspolicy_server_trigger (FOR ALTER_LOGIN, CREATE_LOGIN) unbedingt bei jedem
      betroffenen Ereignis feuert und JEDE aktuell aktivierte Policy mit Auswertungsmodus
      "On Change: Prevent" auswerten kann - auch wenn eine bestimmte, bekannte Policy
      (DefaultPolicy) bereits deaktiviert ist, kann eine ANDERE aktive Policy denselben
      Rollback ausloesen ("The transaction ended in the trigger. The batch has been
      aborted."). Trigger-Deaktivierung umgeht das unabhaengig davon, welche/wie viele
      Policies aktiv sind.

      -DisablePolicy (Default $true): deaktiviert zusaetzlich die konfigurierte
      'DefaultPolicy' (Modulkonfiguration) via Set-sqmSqlPolicyState, ebenfalls mit
      garantierter Wiederherstellung. Redundant, sobald -DisableServerTriggers bereits
      aktiv ist, aber als zweite, unabhaengige Absicherung sinnvoll (z.B. falls
      Trigger-Deaktivierung aus Rechtegruenden fehlschlaegt).

    -CreateLoginIfMissing (nur Grant):
        Fehlt ein Windows-/AD-Login, wird er per 'CREATE LOGIN [..] FROM WINDOWS' angelegt.
        Im Ergebnis wird LoginCreated = $true zurueckgegeben.

    -RemoveLogin (nur Revoke):
        Nach dem Entzug der Rolle wird der Login mit 'DROP LOGIN' entfernt - ABER nur als
        Sicherheitsnetz, wenn der Login keiner weiteren festen Serverrolle ausser 'public'
        angehoert. Haengt noch etwas am Login, bleibt er stehen und es wird eine Warnung
        protokolliert (so wird nie ein anderweitig genutzter Login versehentlich geloescht).

    Protokolliert jede Aktion in das Modul-Logfile (Invoke-sqmLogging) UND in das
    Windows Application Event Log (Source 'sqmSQLTool') - inklusive Auftragsnummer.

    Ist -JobName gesetzt und die Aktion erfolgreich, wird der Job per sp_delete_job
    geloescht. Bei einem Fehler wird der Job NICHT geloescht und ein Fehler geworfen,
    damit der Fehlschlag in der Job-Historie sichtbar bleibt.

.PARAMETER SqlInstance
    SQL Server Instanz. Default: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung (SQL-Authentifizierung).

.PARAMETER Login
    Betroffener Login: Windows-/AD-Login (DOMAIN\Konto oder AD-Gruppe) oder ein bereits
    vorhandener SQL-Auth-Login.

.PARAMETER Action
    'Grant' oder 'Revoke'.

.PARAMETER Role
    Feste Serverrolle: 'sysadmin' (Default) oder 'dbcreator'.

.PARAMETER CreateLoginIfMissing
    Nur bei Grant: legt einen fehlenden Windows-/AD-Login per CREATE LOGIN ... FROM WINDOWS
    an. Fuer einen fehlenden SQL-Login wirft der Aufruf stattdessen einen klaren Fehler -
    kein automatisches Anlegen von SQL-Logins.

.PARAMETER RemoveLogin
    Nur bei Revoke: entfernt den Login nach dem Entzug (DROP LOGIN), sofern er an
    keiner weiteren festen Serverrolle haengt.

.PARAMETER DisableServerTriggers
    Alle aktuell aktivierten serverweiten DDL-Trigger fuer die Dauer der Aktion deaktivieren
    und exakt den vorherigen Zustand danach wiederherstellen. Siehe .DESCRIPTION fuer den
    Hintergrund. Default: $true.

.PARAMETER DisablePolicy
    Die konfigurierte PBM-Policy (DefaultPolicy) fuer die gesamte Dauer der Aktion vorher
    deaktivieren und danach wieder aktivieren - nicht nur um ein optionales CREATE LOGIN,
    sondern auch um ALTER SERVER ROLE ADD/DROP MEMBER (und DROP LOGIN bei -RemoveLogin).
    Siehe .DESCRIPTION fuer den Hintergrund und das Verhaeltnis zu -DisableServerTriggers.
    Default: $true.

.PARAMETER TicketNumber
    Optionale Auftrags-/Ticketnummer fuer die Protokollierung.

.PARAMETER JobName
    Optional: Name des aufrufenden Agent-Jobs. Wird nach erfolgreicher Aktion
    geloescht (Selbstloeschung).

.EXAMPLE
    Invoke-sqmTempSysadminAction -SqlInstance SQL01 -Login 'DOM\u.maier' -Action Revoke

.EXAMPLE
    # Vorzeitiger manueller Entzug inkl. Entfernen eines selbst angelegten Logins:
    Invoke-sqmTempSysadminAction -Login 'DOM\u.maier' -Action Revoke -RemoveLogin

.EXAMPLE
    # dbcreator statt sysadmin, fuer einen bestehenden SQL-Login:
    Invoke-sqmTempSysadminAction -SqlInstance SQL01 -Login 'app_deploy' -Action Grant -Role dbcreator

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Set-sqmSqlPolicyState, Get-sqmConfig.
    Ausfuehrender Kontext braucht sysadmin/ALTER ANY SERVER ROLE und ALTER TRACE/ALTER ANY
    SERVER TRIGGER auf der Instanz. Im Job-Kontext laeuft dies unter dem SQL-Agent-Dienstkonto.
#>
function Invoke-sqmTempSysadminAction
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$Login,
		[Parameter(Mandatory = $true)]
		[ValidateSet('Grant', 'Revoke')]
		[string]$Action,
		[Parameter(Mandatory = $false)]
		[ValidateSet('sysadmin', 'dbcreator')]
		[string]$Role = 'sysadmin',
		[Parameter(Mandatory = $false)]
		[switch]$CreateLoginIfMissing,
		[Parameter(Mandatory = $false)]
		[switch]$RemoveLogin,
		[Parameter(Mandatory = $false)]
		[bool]$DisableServerTriggers = $true,
		[Parameter(Mandatory = $false)]
		[bool]$DisablePolicy = $true,
		[Parameter(Mandatory = $false)]
		[string]$TicketNumber,
		[Parameter(Mandatory = $false)]
		[string]$JobName
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
	}

	process
	{
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		# Quoting: [login] (Bracket-escape) und N'login' (String-escape)
		$loginBracket = '[' + ($Login -replace '\]', ']]') + ']'
		$loginLit     = $Login -replace "'", "''"
		$ticketText   = if ($TicketNumber) { $TicketNumber } else { '(keine)' }
		$loginCreated = $false
		$loginRemoved = $false

		$roleBracket = '[' + $Role + ']'   # $Role kommt aus ValidateSet ('sysadmin'|'dbcreator'), kein Escaping noetig

		try
		{
			# Serverweite DDL-Trigger: ALLE aktuell aktivierten fuer die Dauer der Aktion
			# deaktivieren, exakten vorherigen Zustand danach wiederherstellen. Notwendig, weil
			# der eingebaute syspolicy_server_trigger (FOR ALTER_LOGIN, CREATE_LOGIN) unbedingt
			# feuert und dabei JEDE aktuell aktivierte PBM-Policy mit Auswertungsmodus
			# "On Change: Prevent" auswertet - auch wenn eine bestimmte, bekannte Policy
			# (DefaultPolicy) bereits deaktiviert ist, kann eine ANDERE aktive Policy denselben
			# Rollback ausloesen ("The transaction ended in the trigger. The batch has been
			# aborted."). Manuelles Testen (Policy vorab deaktiviert, Grant scheitert trotzdem
			# identisch) hat genau das bestaetigt - Deaktivieren nur der bekannten Policy reicht
			# nicht, der Trigger selbst muss weg.
			$triggersDisabledNames = New-Object System.Collections.Generic.List[string]
			if ($DisableServerTriggers)
			{
				try
				{
					$enabledTriggers = @(Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
							-Query "SELECT name FROM sys.server_triggers WHERE is_disabled = 0;" | Select-Object -ExpandProperty name)
					foreach ($trigName in $enabledTriggers)
					{
						$trigBracket = '[' + ($trigName -replace '\]', ']]') + ']'
						try
						{
							Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
								-Query "DISABLE TRIGGER $trigBracket ON ALL SERVER;"
							$triggersDisabledNames.Add($trigName)
						}
						catch
						{
							Invoke-sqmLogging -Message "WARNUNG: Server-Trigger '$trigName' auf '$SqlInstance' konnte nicht deaktiviert werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
						}
					}
					if ($triggersDisabledNames.Count -gt 0)
					{
						Invoke-sqmLogging -Message "Serverweite DDL-Trigger auf '$SqlInstance' fuer $Role-$Action temporaer deaktiviert: $($triggersDisabledNames -join ', ')" -FunctionName $functionName -Level 'INFO'
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "WARNUNG: Liste der Server-Trigger auf '$SqlInstance' konnte nicht ermittelt werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}

			# PBM-Policy (DefaultPolicy) zusaetzlich rund um die GESAMTE Aktion deaktivieren -
			# redundant, sobald die Trigger oben schon deaktiviert sind, aber eine zweite,
			# unabhaengige Absicherung (z.B. falls Trigger-Deaktivierung an Rechten scheitert).
			$policyDisabled = $false
			$policyName     = if ($DisablePolicy) { Get-sqmConfig -Key 'DefaultPolicy' 3>$null } else { $null }
			try
			{
				if ($DisablePolicy -and -not [string]::IsNullOrWhiteSpace($policyName))
				{
					$pd = Set-sqmSqlPolicyState @connParams -Policy $policyName -State Disable -ContinueOnError -ErrorAction Stop
					$pdFirst = $pd | Select-Object -First 1
					if ($pdFirst.Status -eq 'Success')
					{
						$policyDisabled = $true
						Invoke-sqmLogging -Message "PBM-Policy '$policyName' auf '$SqlInstance' fuer $Role-$Action temporaer deaktiviert." -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						# NICHT stillschweigend weitermachen: bleibt die Policy aktiv (z.B. weil
						# Set-sqmSqlPolicyState selbst an fehlenden Rechten oder einer
						# dbatools/SMO-Eigenheit scheitert), schlaegt die eigentliche
						# ALTER SERVER ROLE-Anweisung gleich darauf mit demselben
						# Trigger-Rollback fehl wie ohne diesen Versuch ueberhaupt - bisher
						# ohne jeden Hinweis darauf, WARUM die Deaktivierung nicht griff.
						Invoke-sqmLogging -Message "WARNUNG: PBM-Policy '$policyName' auf '$SqlInstance' konnte NICHT deaktiviert werden (Status: $($pdFirst.Status)): $($pdFirst.Message). Der folgende $Role-$Action-Versuch laeuft trotzdem, kann aber am selben Policy-Trigger scheitern." -FunctionName $functionName -Level 'WARNING'
					}
				}

				if ($Action -eq 'Grant')
				{
					# --- 1. Login-Existenz pruefen (Windows-/AD-Principals U/G oder SQL-Login S) ---
					$exists = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
						-Query "SELECT COUNT(*) AS Cnt FROM sys.server_principals WHERE name = N'$loginLit' AND type IN ('U','G','S');"
					$loginPresent = ($exists -and [int]$exists.Cnt -gt 0)

					# --- 2. Fehlt der Login: optional anlegen (nur Windows-/AD-Logins) ---
					if (-not $loginPresent)
					{
						if (-not $CreateLoginIfMissing)
						{
							throw "Login '$Login' existiert auf '$SqlInstance' nicht und -CreateLoginIfMissing wurde nicht gesetzt."
						}
						if ($Login -notmatch '\\')
						{
							throw "Login '$Login' existiert auf '$SqlInstance' nicht. Automatisches Anlegen (-CreateLoginIfMissing) unterstuetzt nur Windows-/AD-Logins (DOMAIN\Konto) - fuer einen SQL-Login muss der Login bereits vorhanden sein."
						}

						Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
							-Query "CREATE LOGIN $loginBracket FROM WINDOWS;"
						$loginCreated = $true
						$createMsg = "AD-Login '$Login' auf '$SqlInstance' angelegt (FROM WINDOWS). Auftragsnummer: $ticketText."
						Invoke-sqmLogging -Message $createMsg -FunctionName $functionName -Level 'INFO'
						Write-sqmEventLogSafe -Message $createMsg -EntryType 'Information' -EventId 9003
					}

					# --- 3. Rolle vergeben (idempotent) ---
					# WICHTIG: Bedingung ueber sys.server_role_members (DIREKTE Mitgliedschaft),
					# NICHT ueber IS_SRVROLEMEMBER(). IS_SRVROLEMEMBER() liefert die EFFEKTIVE
					# Mitgliedschaft inklusive Vererbung ueber Windows-/AD-Gruppen: ist der Login
					# Mitglied einer AD-Gruppe, die ihrerseits als sysadmin-Login eingetragen ist,
					# liefert es bereits 1 - die bedingte ALTER-Anweisung wurde dadurch
					# uebersprungen und der Login NIE direkt in die Rolle aufgenommen (genau der
					# Fall auf DWP1W02SQLT0001: "kein Fehler, Log sagt erfolgreich, trotzdem kein
					# sysadmin"). Umgekehrt kann IS_SRVROLEMEMBER() auch 0 liefern, obwohl direkte
					# Mitgliedschaft besteht (auf DEV01 mit 'NT Service\MSSQLSERVER' reproduziert).
					# Fuer "diesen Login temporaer in die Rolle aufnehmen/daraus entfernen" ist
					# ausschliesslich die direkte Mitgliedschaft massgeblich.
					$directMemberPredicate = @"
EXISTS (
    SELECT 1
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'$Role' AND m.name = N'$loginLit')
"@
					$sql = @"
IF NOT $directMemberPredicate
    ALTER SERVER ROLE $roleBracket ADD MEMBER $loginBracket;
"@
					Invoke-DbaQuery @connParams -Database master -Query $sql -EnableException -ErrorAction Stop

					# --- Verifikation: nicht auf "keine Exception = Erfolg" verlassen. Eine
					# bedingte Anweisung, deren Bedingung nicht zutrifft, ist kein SQL-Fehler -
					# ohne Nachpruefung meldete die Funktion faelschlich Erfolg, obwohl die Rolle
					# nie vergeben wurde. Gleiche Fehlerklasse wie 1.9.43.0/1.9.44.0
					# (Remove-DbaDatabase in Invoke-sqmRestoreDatabase).
					$verify = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
						-Query "SELECT CASE WHEN $directMemberPredicate THEN 1 ELSE 0 END AS IsDirectMember;"
					if (-not $verify -or [int]$verify.IsDirectMember -ne 1)
					{
						throw "ALTER SERVER ROLE $roleBracket ADD MEMBER lief ohne Fehler, aber '$Login' ist danach laut sys.server_role_members KEIN direktes Mitglied der Rolle '$Role' auf '$SqlInstance'."
					}

					$msg = "$Role Grant fuer Login '$Login' auf '$SqlInstance' erfolgreich$(if($loginCreated){' (Login neu angelegt)'}). Auftragsnummer: $ticketText."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
					Write-sqmEventLogSafe -Message $msg -EntryType 'Information' -EventId 9001
				}
				else # Revoke
				{
					# --- 1. Rolle entziehen (idempotent) ---
					# Direkte Mitgliedschaft statt IS_SRVROLEMEMBER() - siehe ausfuehrliche
					# Begruendung im Grant-Zweig oben. Beim Revoke ist die direkte Mitgliedschaft
					# ohnehin die einzig sinnvolle Bedingung: DROP MEMBER kann nur entfernen, was
					# direkt Mitglied ist - eine ueber eine AD-Gruppe geerbte Berechtigung laesst
					# sich damit gar nicht entziehen.
					$directMemberPredicate = @"
EXISTS (
    SELECT 1
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'$Role' AND m.name = N'$loginLit')
"@
					$sql = @"
IF $directMemberPredicate
    ALTER SERVER ROLE $roleBracket DROP MEMBER $loginBracket;
"@
					Invoke-DbaQuery @connParams -Database master -Query $sql -EnableException -ErrorAction Stop

					# --- Verifikation: gleiche Begruendung wie beim Grant oben, spiegelverkehrt. ---
					$verify = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
						-Query "SELECT CASE WHEN $directMemberPredicate THEN 1 ELSE 0 END AS IsDirectMember;"
					if (-not $verify -or [int]$verify.IsDirectMember -ne 0)
					{
						throw "ALTER SERVER ROLE $roleBracket DROP MEMBER lief ohne Fehler, aber '$Login' ist laut sys.server_role_members danach immer noch direktes Mitglied der Rolle '$Role' auf '$SqlInstance'."
					}

					$msg = "$Role Revoke fuer Login '$Login' auf '$SqlInstance' erfolgreich. Auftragsnummer: $ticketText."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
					Write-sqmEventLogSafe -Message $msg -EntryType 'Information' -EventId 9002

					# --- 2. Optional: selbst angelegten Login wieder entfernen ---
					if ($RemoveLogin)
					{
						# Sicherheitsnetz: nur droppen, wenn der Login an KEINER weiteren
						# festen Serverrolle ausser 'public' haengt.
						$roleCheck = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop -Query @"
SELECT COUNT(*) AS Cnt
FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
WHERE m.name = N'$loginLit' AND r.name <> 'public';
"@
						if ($roleCheck -and [int]$roleCheck.Cnt -gt 0)
						{
							$keepMsg = "Login '$Login' auf '$SqlInstance' NICHT entfernt: noch Mitglied weiterer Serverrolle(n). Auftragsnummer: $ticketText."
							Invoke-sqmLogging -Message $keepMsg -FunctionName $functionName -Level 'WARNING'
							Write-sqmEventLogSafe -Message $keepMsg -EntryType 'Warning' -EventId 9004
						}
						else
						{
							Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
								-Query "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$loginLit' AND type IN ('U','G','S')) DROP LOGIN $loginBracket;"
							$loginRemoved = $true
							$dropMsg = "Login '$Login' auf '$SqlInstance' nach Ablauf entfernt (DROP LOGIN). Auftragsnummer: $ticketText."
							Invoke-sqmLogging -Message $dropMsg -FunctionName $functionName -Level 'INFO'
							Write-sqmEventLogSafe -Message $dropMsg -EntryType 'Information' -EventId 9005
						}
					}
				}
			}
			finally
			{
				# PBM-Policy in jedem Fall wieder aktivieren, auch wenn eine der obigen
				# Anweisungen fehlschlug (der aeussere catch faengt/formatiert den Fehler
				# trotzdem noch ab - dieser finally-Block laeuft davor).
				if ($policyDisabled)
				{
					try
					{
						Set-sqmSqlPolicyState @connParams -State Enable -ContinueOnError -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "PBM-Policy '$policyName' auf '$SqlInstance' wieder aktiviert." -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						Invoke-sqmLogging -Message "WARNUNG: PBM-Policy '$policyName' auf '$SqlInstance' konnte NICHT reaktiviert werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
					}
				}

				# Serverweite DDL-Trigger in jedem Fall exakt wieder in den vorherigen Zustand
				# versetzen - NUR die Trigger, die oben tatsaechlich deaktiviert wurden (kein
				# pauschales "alle an"). Ein fehlgeschlagenes Wiederaktivieren ist sicherheits-
				# relevant genug fuer einen zusaetzlichen Eventlog-Eintrag, nicht nur eine
				# Log-Zeile - ein serverweiter DDL-Trigger, der stillschweigend deaktiviert
				# bleibt, ist ein Governance-Luecke, die jemand aktiv bemerken sollte.
				if ($triggersDisabledNames.Count -gt 0)
				{
					$triggerRestoreFailed = @()
					foreach ($trigName in $triggersDisabledNames)
					{
						$trigBracket = '[' + ($trigName -replace '\]', ']]') + ']'
						try
						{
							Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
								-Query "ENABLE TRIGGER $trigBracket ON ALL SERVER;"
						}
						catch
						{
							$triggerRestoreFailed += $trigName
							Invoke-sqmLogging -Message "WARNUNG: Server-Trigger '$trigName' auf '$SqlInstance' konnte NICHT wieder aktiviert werden - manuell pruefen! $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
						}
					}
					if ($triggerRestoreFailed.Count -eq 0)
					{
						Invoke-sqmLogging -Message "Serverweite DDL-Trigger auf '$SqlInstance' wieder aktiviert: $($triggersDisabledNames -join ', ')" -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						Write-sqmEventLogSafe -Message "Server-Trigger auf '$SqlInstance' nach temporaerer Deaktivierung fuer $Role-$Action NICHT wieder aktiviert - manuelle Pruefung erforderlich: $($triggerRestoreFailed -join ', ')" -EntryType 'Error' -EventId 9010
					}
				}
			}

			# --- Selbstloeschung des aufrufenden Jobs - NUR bei Erfolg ---
			if ($JobName)
			{
				$jobLit = $JobName -replace "'", "''"
				$delSql = "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'$jobLit') EXEC msdb.dbo.sp_delete_job @job_name = N'$jobLit';"
				Invoke-DbaQuery @connParams -Database msdb -Query $delSql -EnableException -ErrorAction Stop
				Invoke-sqmLogging -Message "Selbstloeschender Job '$JobName' entfernt." -FunctionName $functionName -Level "INFO"
			}

			return [PSCustomObject]@{
				SqlInstance  = $SqlInstance
				Login        = $Login
				Action       = $Action
				Role         = $Role
				LoginCreated = $loginCreated
				LoginRemoved = $loginRemoved
				TicketNumber = $TicketNumber
				JobDeleted   = [bool]$JobName
				Status       = 'Success'
				Message      = $msg
				Timestamp    = Get-Date
			}
		}
		catch
		{
			$errMsg = "$Role $Action fuer Login '$Login' auf '$SqlInstance' FEHLGESCHLAGEN (Auftragsnummer: $ticketText): $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			Write-sqmEventLogSafe -Message $errMsg -EntryType 'Error' -EventId 9009
			# Fehler werfen, damit ein aufrufender Agent-Job als FEHLGESCHLAGEN endet und sich NICHT loescht.
			throw $errMsg
		}
	}
}

# -------------------------------------------------------------------------------
# Private Hilfsfunktion: schreibt ins Windows Application Event Log unter der
# Source 'sqmSQLTool' (von Install.ps1 registriert). Schlaegt das Schreiben fehl
# (Source fehlt / keine Rechte), wird der Fehler ignoriert - das Logfile bleibt
# massgeblich.
# -------------------------------------------------------------------------------
function Write-sqmEventLogSafe
{
	[CmdletBinding()]
	param (
		[string]$Message,
		[ValidateSet('Information', 'Warning', 'Error')]
		[string]$EntryType = 'Information',
		[int]$EventId = 9000
	)
	try
	{
		if (-not [System.Diagnostics.EventLog]::SourceExists('sqmSQLTool'))
		{
			# Anlegen erfordert Adminrechte - bei Fehlschlag still ueberspringen.
			New-EventLog -LogName Application -Source 'sqmSQLTool' -ErrorAction Stop
		}
		Write-EventLog -LogName Application -Source 'sqmSQLTool' -EntryType $EntryType -EventId $EventId -Message $Message -ErrorAction Stop
	}
	catch
	{
		Write-Verbose "Event-Log-Eintrag uebersprungen: $($_.Exception.Message)"
	}
}
