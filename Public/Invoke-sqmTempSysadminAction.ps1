<#
.SYNOPSIS
    Fuehrt die eigentliche sysadmin-Vergabe bzw. -Entziehung auf EINER Instanz aus,
    legt dabei optional einen fehlenden AD-Login an, entfernt ihn beim Entzug wieder
    und loescht optional den aufrufenden SQL-Agent-Job nach Erfolg (selbstloeschender Job).

.DESCRIPTION
    Wird von den durch Grant-sqmTemporarySysadmin erzeugten Agent-Jobs aufgerufen,
    kann aber auch manuell verwendet werden (z. B. fuer einen vorzeitigen Entzug).

    Aktion:
      Grant   -> (optional CREATE LOGIN ... FROM WINDOWS) + ALTER SERVER ROLE [sysadmin] ADD MEMBER
      Revoke  -> ALTER SERVER ROLE [sysadmin] DROP MEMBER + (optional DROP LOGIN)

    Es werden ausschliesslich Windows-/AD-Logins (DOMAIN\Konto bzw. AD-Gruppe)
    unterstuetzt.

    Ist in der Modulkonfiguration eine 'DefaultPolicy' gesetzt und -DisablePolicy aktiv
    ($true, Default), wird diese PBM-Policy via Set-sqmSqlPolicyState fuer die GESAMTE
    Dauer der Aktion deaktiviert und in einem finally-Block garantiert wieder aktiviert -
    nicht nur um ein optionales CREATE LOGIN, sondern auch um ALTER SERVER ROLE ADD/DROP
    MEMBER und DROP LOGIN. Siehe .PARAMETER DisablePolicy fuer den Hintergrund
    (syspolicy_server_trigger kann jede dieser Anweisungen abfangen, nicht nur die
    Login-Anlage).

    -CreateLoginIfMissing (nur Grant):
        Fehlt der Login, wird er per 'CREATE LOGIN [..] FROM WINDOWS' angelegt.
        Im Ergebnis wird LoginCreated = $true zurueckgegeben.

    -RemoveLogin (nur Revoke):
        Nach dem Entzug der sysadmin-Rolle wird der Login mit 'DROP LOGIN' entfernt -
        ABER nur als Sicherheitsnetz, wenn der Login keiner weiteren festen Serverrolle
        ausser 'public' angehoert. Haengt noch etwas am Login, bleibt er stehen und es
        wird eine Warnung protokolliert (so wird nie ein anderweitig genutzter Login
        versehentlich geloescht).

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
    Betroffener Windows-/AD-Login (DOMAIN\Konto oder AD-Gruppe).

.PARAMETER Action
    'Grant' oder 'Revoke'.

.PARAMETER CreateLoginIfMissing
    Nur bei Grant: legt einen fehlenden AD-Login per CREATE LOGIN ... FROM WINDOWS an.

.PARAMETER RemoveLogin
    Nur bei Revoke: entfernt den Login nach dem Entzug (DROP LOGIN), sofern er an
    keiner weiteren festen Serverrolle haengt.

.PARAMETER DisablePolicy
    Die konfigurierte PBM-Policy (DefaultPolicy) fuer die gesamte Dauer der Aktion vorher
    deaktivieren und danach wieder aktivieren - nicht nur um ein optionales CREATE LOGIN,
    sondern auch um ALTER SERVER ROLE [sysadmin] ADD/DROP MEMBER (und DROP LOGIN bei
    -RemoveLogin). Eine Policy mit Auswertungsmodus "On Change: Prevent" haengt serverweit
    am eingebauten syspolicy_server_trigger und kann JEDE DDL_SERVER_LEVEL_EVENTS-Anweisung
    per Rollback abbrechen ("The transaction ended in the trigger. The batch has been
    aborted."), nicht nur die Login-Anlage - das betrifft also genauso den eigentlichen
    sysadmin-Grant/-Revoke. Default: $true.

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

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Set-sqmSqlPolicyState, Get-sqmConfig.
    Ausfuehrender Kontext braucht sysadmin/ALTER auf der Serverrolle. Im Job-Kontext
    laeuft dies unter dem SQL-Agent-Dienstkonto.
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
		[switch]$CreateLoginIfMissing,
		[Parameter(Mandatory = $false)]
		[switch]$RemoveLogin,
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

		try
		{
			# PBM-Policy (DefaultPolicy) rund um die GESAMTE Aktion deaktivieren, nicht nur um
			# ein optionales CREATE LOGIN: eine Policy mit Auswertungsmodus "On Change: Prevent"
			# haengt serverweit am eingebauten syspolicy_server_trigger und kann JEDE
			# DDL_SERVER_LEVEL_EVENTS-Anweisung per Rollback abbrechen ("The transaction ended
			# in the trigger. The batch has been aborted.") - das betrifft ALTER SERVER ROLE
			# ADD/DROP MEMBER und DROP LOGIN genauso wie CREATE LOGIN. Frueher war die
			# Deaktivierung nur um CREATE LOGIN gelegt, wodurch der eigentliche sysadmin-Grant
			# (und - schwerwiegender - der automatische Revoke-Job Tage spaeter) auf Instanzen
			# mit einer solchen Policy weiterhin fehlschlug, obwohl das genau der Zweck dieser
			# Funktion ist.
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
						Invoke-sqmLogging -Message "PBM-Policy '$policyName' auf '$SqlInstance' fuer sysadmin-$Action temporaer deaktiviert." -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						# NICHT stillschweigend weitermachen: bleibt die Policy aktiv (z.B. weil
						# Set-sqmSqlPolicyState selbst an fehlenden Rechten oder einer
						# dbatools/SMO-Eigenheit scheitert), schlaegt die eigentliche
						# ALTER SERVER ROLE-Anweisung gleich darauf mit demselben
						# Trigger-Rollback fehl wie ohne diesen Versuch ueberhaupt - bisher
						# ohne jeden Hinweis darauf, WARUM die Deaktivierung nicht griff.
						Invoke-sqmLogging -Message "WARNUNG: PBM-Policy '$policyName' auf '$SqlInstance' konnte NICHT deaktiviert werden (Status: $($pdFirst.Status)): $($pdFirst.Message). Der folgende sysadmin-$Action-Versuch laeuft trotzdem, kann aber am selben Policy-Trigger scheitern." -FunctionName $functionName -Level 'WARNING'
					}
				}

				if ($Action -eq 'Grant')
				{
					# --- 1. Login-Existenz pruefen (nur Windows-/AD-Principals U/G) ---
					$exists = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
						-Query "SELECT COUNT(*) AS Cnt FROM sys.server_principals WHERE name = N'$loginLit' AND type IN ('U','G');"
					$loginPresent = ($exists -and [int]$exists.Cnt -gt 0)

					# --- 2. Fehlt der Login: optional anlegen ---
					if (-not $loginPresent)
					{
						if (-not $CreateLoginIfMissing)
						{
							throw "Login '$Login' existiert auf '$SqlInstance' nicht und -CreateLoginIfMissing wurde nicht gesetzt."
						}

						Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
							-Query "CREATE LOGIN $loginBracket FROM WINDOWS;"
						$loginCreated = $true
						$createMsg = "AD-Login '$Login' auf '$SqlInstance' angelegt (FROM WINDOWS). Auftragsnummer: $ticketText."
						Invoke-sqmLogging -Message $createMsg -FunctionName $functionName -Level 'INFO'
						Write-sqmEventLogSafe -Message $createMsg -EntryType 'Information' -EventId 9003
					}

					# --- 3. sysadmin vergeben (idempotent) ---
					$sql = @"
IF IS_SRVROLEMEMBER('sysadmin', N'$loginLit') = 0
    ALTER SERVER ROLE [sysadmin] ADD MEMBER $loginBracket;
"@
					Invoke-DbaQuery @connParams -Database master -Query $sql -EnableException -ErrorAction Stop

					$msg = "sysadmin Grant fuer Login '$Login' auf '$SqlInstance' erfolgreich$(if($loginCreated){' (Login neu angelegt)'}). Auftragsnummer: $ticketText."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
					Write-sqmEventLogSafe -Message $msg -EntryType 'Information' -EventId 9001
				}
				else # Revoke
				{
					# --- 1. sysadmin entziehen (idempotent) ---
					$sql = @"
IF IS_SRVROLEMEMBER('sysadmin', N'$loginLit') = 1
    ALTER SERVER ROLE [sysadmin] DROP MEMBER $loginBracket;
"@
					Invoke-DbaQuery @connParams -Database master -Query $sql -EnableException -ErrorAction Stop

					$msg = "sysadmin Revoke fuer Login '$Login' auf '$SqlInstance' erfolgreich. Auftragsnummer: $ticketText."
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
								-Query "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$loginLit' AND type IN ('U','G')) DROP LOGIN $loginBracket;"
							$loginRemoved = $true
							$dropMsg = "AD-Login '$Login' auf '$SqlInstance' nach Ablauf entfernt (DROP LOGIN). Auftragsnummer: $ticketText."
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
			$errMsg = "sysadmin $Action fuer Login '$Login' auf '$SqlInstance' FEHLGESCHLAGEN (Auftragsnummer: $ticketText): $($_.Exception.Message)"
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
