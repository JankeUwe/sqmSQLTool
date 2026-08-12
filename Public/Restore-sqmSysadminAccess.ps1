<#
.SYNOPSIS
    Notfall-Wiederherstellung des sysadmin-Zugriffs, wenn KEIN funktionierender
    sysadmin-Login mehr existiert (kompletter DBA-Lockout).

.DESCRIPTION
    Automatisiert die von Microsoft dokumentierte Notfallprozedur fuer eine SQL-Server-
    Instanz, bei der niemand mehr sysadmin-Rechte hat (Logins geloescht, Passwoerter
    verloren, versehentlich alle sysadmin-Mitgliedschaften entzogen, etc.):

        1. SQL-Server-Dienst stoppen.
        2. Startparameter -m"<Marker>" setzen (Single-User-Mode, auf eine Anwendung
           mit diesem Namen beschraenkt) und den Dienst neu starten.
        3. Im Single-User-Mode gewaehrt SQL Server jedem Mitglied der lokalen
           Windows-Gruppe BUILTIN\Administrators implizit sysadmin-Rechte fuer die
           EINE erlaubte Verbindung - unabhaengig vom tatsaechlichen SQL-Login. Genau
           diese eine Verbindung wird genutzt, um den angegebenen SQL-Auth-Login
           anzulegen (oder, falls er bereits existiert, Passwort zurueckzusetzen und
           zu aktivieren) und ihn der festen Serverrolle sysadmin hinzuzufuegen.
        4. Startparameter zurueckbauen (Single-User-Mode wird entfernt) und den
           Dienst wieder im normalen Mehrbenutzerbetrieb starten.

    Referenz: https://learn.microsoft.com/sql/database-engine/configure-windows/
    connect-to-sql-server-when-system-administrators-are-locked-out

    Da im Single-User-Mode GENAU EINE Verbindung erlaubt ist, fuehrt diese Funktion
    Login-Anlage/-Reset UND Rollenvergabe in EINEM einzigen T-SQL-Batch/EINER
    einzigen Verbindung aus (kein Mehrfach-Roundtrip) - jede zusaetzliche Verbindung
    waere ein Zeitfenster, in dem ein anderer Prozess (z.B. ein Monitoring-Agent, der
    sofort nach Dienststart erneut verbindet) den einzigen Verbindungsslot belegen und
    die Prozedur zum Scheitern bringen koennte. Im selben Batch werden zusaetzlich ALLE
    aktuell aktivierten serverweiten DDL-Trigger voruebergehend deaktiviert und direkt
    danach exakt wieder aktiviert - noetig, weil der eingebaute syspolicy_server_trigger
    (Policy-Based Management) CREATE LOGIN/ALTER SERVER ROLE auch im Single-User-Mode
    per Rollback abbrechen kann (siehe Invoke-sqmTempSysadminAction fuer den bereits
    einmal live aufgetretenen Hintergrund).

    Der Dienst wird in JEDEM Fall - auch bei einem Fehler mitten in der Prozedur - im
    finally-Block gestoppt, aus dem Single-User-Mode zurueckgebaut und wieder normal
    gestartet. Ein Server, der nach einem Fehlschlag dauerhaft im Single-User-Mode
    haengen bleibt, waere schlimmer als ein fehlgeschlagener Notfall-Zugriff.

.PARAMETER SqlInstance
    SQL Server Instanz (Standardinstanz oder SERVER\INSTANZ). Default: lokaler
    Computername. Muss lokal oder per WinRM/CIM erreichbar sein (Dienststeuerung
    laeuft ueber dbatools' Get/Stop/Start-DbaService, NICHT ueber eine SQL-Verbindung -
    genau deshalb funktioniert das auch ohne jeden funktionierenden SQL-Login).

.PARAMETER Login
    Name des SQL-Server-Authentifizierungs-Logins, der Notfallzugriff erhalten soll.
    Existiert er bereits, wird nur sein Passwort zurueckgesetzt und der Login aktiviert
    (ALTER LOGIN); existiert er nicht, wird er neu angelegt (CREATE LOGIN). In beiden
    Faellen wird er anschliessend (idempotent) Mitglied der festen Serverrolle sysadmin.

.PARAMETER Password
    Passwort fuer den Login als SecureString. Ohne Angabe wird per
    New-sqmRandomSaPassword automatisch ein 24-stelliges, policy-konformes Passwort
    generiert und im Rueckgabeobjekt im Klartext ausgegeben (siehe .OUTPUTS) - das ist
    hier bewusst so, weil der ganze Zweck dieser Funktion ist, sofort nutzbare
    Zugangsdaten zurueckzugeben. Das Passwort wird NIRGENDS geloggt (weder Modul-Logfile
    noch Windows Event Log).

.PARAMETER TimeoutSeconds
    Maximale Wartezeit in Sekunden, bis der im Single-User-Mode neu gestartete Dienst
    eine Verbindung annimmt, bevor die Funktion mit einem Fehler abbricht (und trotzdem
    versucht, den Normalbetrieb wiederherzustellen). Default: 120.

.PARAMETER TicketNumber
    Optionale Auftrags-/Ticketnummer fuer die Protokollierung.

.PARAMETER Force
    Ueberspringt zwei Sicherheitschecks:
      - den Vorab-Verbindungstest, der die Prozedur verweigert, wenn die Instanz mit
        dem aktuellen Windows-Konto BEREITS erreichbar UND sysadmin ist (dann ist die
        Notfallprozedur unnoetig und nur zusaetzliches Risiko/Downtime);
      - die Warnung/den Abbruch, wenn die lokale Registry auf einen Windows Server
        Failover Cluster hindeutet (HKLM:\Cluster) - dort kann der Cluster-Dienst
        parallel eingreifen, wenn der SQL-Dienst direkt statt ueber die
        Cluster-Ressource gestoppt/gestartet wird. Cluster-Ressource in diesem Fall
        vorher manuell in Wartung/offline nehmen.

.PARAMETER WhatIf
    Zeigt nur, was passieren wuerde, ohne etwas zu aendern.

.PARAMETER Confirm
    Bewusst NICHT auf 'None' herabgesetzt (anders als z.B. Grant-sqmTemporarySysadmin):
    diese Funktion stoppt aktiv einen Produktionsdienst und ist als manuelle
    Notfallmassnahme einer anwesenden Person am Keyboard gedacht, nicht fuer
    unbeaufsichtigte Automation. Der Standard-PowerShell-Rueckfrage-Dialog (ConfirmImpact
    'High') bleibt daher als zusaetzliches Sicherheitsnetz aktiv. Fuer Tests/Skripte
    explizit -Confirm:$false angeben.

.OUTPUTS
    [PSCustomObject] mit SqlInstance, Login, LoginExisted, Password (SecureString),
    PasswordPlainText (String), TicketNumber, Status, Message, Timestamp.

.EXAMPLE
    Restore-sqmSysadminAccess -SqlInstance SQL01 -Login 'sqm_emergency' -TicketNumber 'INC0099887'
    # Legt 'sqm_emergency' an (oder setzt sein Passwort zurueck), macht ihn sysadmin,
    # generiertes Passwort steht im Rueckgabeobjekt.

.EXAMPLE
    $securePw = Read-Host -AsSecureString 'Neues Passwort'
    Restore-sqmSysadminAccess -Login 'sa' -Password $securePw -Force
    # Setzt bei Bedarf 'sa' auf ein selbst gewaehltes Passwort zurueck und macht ihn
    # sysadmin, ohne den Vorab-Erreichbarkeits-/Cluster-Check.

.NOTES
    Requires: dbatools (Stop-DbaService/Start-DbaService/Set-DbaStartupParameter/
    Invoke-DbaQuery), Invoke-sqmLogging, New-sqmRandomSaPassword.
    Ausfuehrender Windows-Benutzer muss lokaler Administrator auf der Zielinstanz sein
    (Voraussetzung fuer die implizite sysadmin-Vergabe im Single-User-Mode) UND
    ausreichend Rechte zur Dienststeuerung/Registry-Aenderung haben.
    Nicht getestet gegen Failover-Cluster-Instanzen (FCI) - siehe -Force.
#>
function Restore-sqmSysadminAccess
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$Login,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$Password,
		[Parameter(Mandatory = $false)]
		[ValidateRange(30, 900)]
		[int]$TimeoutSeconds = 120,
		[Parameter(Mandatory = $false)]
		[string]$TicketNumber,
		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
	}

	process
	{
		$ticketText = if ($TicketNumber) { $TicketNumber } else { '(keine)' }
		$suMarker   = 'sqmSQLToolEmergency'

		# --- Vorab-Check: ist die Instanz mit dem aktuellen Windows-Konto bereits
		# erreichbar UND ist dieses Konto bereits sysadmin? Dann ist die gesamte
		# Notfallprozedur (Dienst-Stopp/-Neustart) unnoetig und nur zusaetzliches
		# Risiko. Fehlschlagen des Tests ist der ERWARTETE Fall (bestaetigt das
		# Lockout-Szenario) und wird NICHT als Fehler behandelt.
		if (-not $Force)
		{
			# Bewusst KEIN "catch [SpezifischerTyp] { throw }" zur Unterscheidung von
			# "bereits sysadmin -> Abbruch" vs. "Verbindung schlaegt erwartungsgemaess
			# fehl": eigene throw-Statements UND dbatools' -EnableException-Fehler
			# landen beide als RuntimeException, ein Typ-Match haette hier faelschlich
			# auch den erwarteten Verbindungsfehler durchgereicht statt ihn als
			# Lockout-Bestaetigung zu behandeln. Stattdessen ein einfaches Flag: der
			# Abbruch-throw passiert erst NACH dem try/catch, komplett ausserhalb.
			$alreadySysadmin = $false
			try
			{
				$probe = Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -QueryTimeout 5 `
					-Query "SELECT ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) AS IsSysadmin;" -EnableException -ErrorAction Stop
				if ($probe -and [int]$probe.IsSysadmin -eq 1) { $alreadySysadmin = $true }
			}
			catch
			{
				Invoke-sqmLogging -Message "[$SqlInstance] Vorab-Verbindungstest bestaetigt das erwartete Lockout-Szenario (keine sysadmin-Verbindung mit aktuellem Konto moeglich): $($_.Exception.Message)" -FunctionName $functionName -Level 'INFO'
			}
			if ($alreadySysadmin)
			{
				throw "Instanz '$SqlInstance' ist mit dem aktuellen Windows-Konto bereits erreichbar UND dieses Konto ist bereits sysadmin - die Notfallprozedur (Dienst-Stopp + Single-User-Mode) ist nicht noetig. Mit -Force trotzdem erzwingen."
			}
		}

		# --- Cluster-Warnung (best effort, nur wenn Zielserver == lokaler Rechner) ---
		$targetServerPart = ($SqlInstance -split '\\')[0]
		if (-not $Force -and $targetServerPart -eq $env:COMPUTERNAME -and (Test-Path 'HKLM:\Cluster'))
		{
			throw "'$SqlInstance' scheint Teil eines Windows Server Failover Clusters zu sein (HKLM:\Cluster vorhanden). Wird der SQL-Dienst direkt statt ueber die Cluster-Ressource gestoppt/gestartet, kann der Cluster-Dienst parallel eingreifen und die Single-User-Mode-Prozedur stoeren. Cluster-Ressource vorher in der Failover-Cluster-Verwaltung offline nehmen/in Wartung setzen, dann mit -Force wiederholen."
		}

		$opDesc = "SQL-Dienst STOPPEN, im Single-User-Mode neu starten, Login '$Login' anlegen/reaktivieren + sysadmin vergeben, danach Dienst wieder normal starten"
		if (-not $PSCmdlet.ShouldProcess($SqlInstance, $opDesc)) { return }

		# --- Passwort: uebergeben oder generieren ---
		$passwordProvided = $PSBoundParameters.ContainsKey('Password')
		if (-not $passwordProvided) { $Password = New-sqmRandomSaPassword -Length 24 }
		$pwCred        = New-Object System.Management.Automation.PSCredential('placeholder', $Password)
		$plainPassword = $pwCred.GetNetworkCredential().Password

		$loginBracket = '[' + ($Login -replace '\]', ']]') + ']'
		$loginLit     = $Login -replace "'", "''"

		$batchSql = @"
DECLARE @triggerNames TABLE(name sysname);
INSERT INTO @triggerNames (name) SELECT name FROM sys.server_triggers WHERE is_disabled = 0;
IF EXISTS (SELECT 1 FROM sys.server_triggers WHERE is_disabled = 0)
    DISABLE TRIGGER ALL ON ALL SERVER;

DECLARE @loginExisted BIT = CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$loginLit' AND type = 'S') THEN 1 ELSE 0 END;

IF @loginExisted = 1
BEGIN
    ALTER LOGIN $loginBracket WITH PASSWORD = @pwd, CHECK_POLICY = ON;
    ALTER LOGIN $loginBracket ENABLE;
END
ELSE
BEGIN
    CREATE LOGIN $loginBracket WITH PASSWORD = @pwd, CHECK_POLICY = ON;
END

IF NOT EXISTS (
    SELECT 1 FROM sys.server_role_members rm
    JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'sysadmin' AND m.name = N'$loginLit')
    ALTER SERVER ROLE sysadmin ADD MEMBER $loginBracket;

DECLARE @reenableSql NVARCHAR(MAX) = N'';
SELECT @reenableSql = @reenableSql + N'ENABLE TRIGGER [' + REPLACE(name, N']', N']]') + N'] ON ALL SERVER;' FROM @triggerNames;
IF LEN(@reenableSql) > 0 EXEC sp_executesql @reenableSql;

SELECT
    @loginExisted AS LoginExisted,
    (SELECT COUNT(*) FROM @triggerNames) AS TriggersReEnabled,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.server_role_members rm
        JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
        JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
        WHERE r.name = N'sysadmin' AND m.name = N'$loginLit'
    ) THEN 1 ELSE 0 END AS IsSysadminNow;
"@

		$singleUserSet  = $false
		$batchResult    = $null

		try
		{
			# --- 1. Dienst stoppen ---
			Invoke-sqmLogging -Message "[$SqlInstance] NOTFALL-ZUGRIFF gestartet fuer Login '$Login'. SQL-Dienst wird gestoppt. Auftragsnummer: $ticketText." -FunctionName $functionName -Level 'WARNING'
			Stop-DbaService -SqlInstance $SqlInstance -Type Engine -Force -EnableException -ErrorAction Stop | Out-Null

			# --- 2. Single-User-Mode setzen + Dienst neu starten ---
			Set-DbaStartupParameter -SqlInstance $SqlInstance -SingleUser -SingleUserDetails $suMarker -Force -EnableException -ErrorAction Stop | Out-Null
			$singleUserSet = $true
			Start-DbaService -SqlInstance $SqlInstance -Type Engine -EnableException -ErrorAction Stop | Out-Null
			Invoke-sqmLogging -Message "[$SqlInstance] Dienst im Single-User-Mode (-m`"$suMarker`") gestartet." -FunctionName $functionName -Level 'INFO'

			# --- 3. Auf die EINE erlaubte Verbindung warten und den gesamten Batch
			# (Login anlegen/reset + sysadmin + Trigger-Handling + Verifikation) in
			# EINEM Versuch ausfuehren - kein separater "Ping" davor, um keine
			# zusaetzliche Verbindung zu verbrauchen, die ein anderer Prozess
			# zwischenzeitlich belegen koennte. -->
			$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
			do
			{
				try
				{
					$batchResult = Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -QueryTimeout 30 `
						-Query $batchSql -SqlParameter @{ pwd = $plainPassword } `
						-AppendConnectionString "Application Name=$suMarker" -EnableException -ErrorAction Stop
					break
				}
				catch
				{
					if ((Get-Date) -ge $deadline) { throw "SQL-Dienst auf '$SqlInstance' wurde im Single-User-Mode gestartet, nimmt aber nach $TimeoutSeconds Sekunden weiterhin keine Verbindung an: $($_.Exception.Message)" }
					Start-Sleep -Seconds 2
				}
			}
			while ($true)

			if (-not $batchResult -or [int]$batchResult.IsSysadminNow -ne 1)
			{
				throw "Batch lief ohne Exception, aber '$Login' ist laut sys.server_role_members danach KEIN direktes Mitglied der Rolle sysadmin auf '$SqlInstance'."
			}

			$loginExisted = [bool][int]$batchResult.LoginExisted
			$msg = "[$SqlInstance] NOTFALL-ZUGRIFF erfolgreich: Login '$Login' $(if($loginExisted){'reaktiviert (Passwort zurueckgesetzt)'}else{'neu angelegt'}) und Mitglied der Rolle sysadmin. Auftragsnummer: $ticketText."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
			Write-sqmEventLogSafe -EntryType 'Warning' -EventId 9020 -Message "$msg Passwort wurde NICHT protokolliert."
		}
		catch
		{
			$errMsg = "[$SqlInstance] NOTFALL-ZUGRIFF fuer Login '$Login' FEHLGESCHLAGEN (Auftragsnummer: $ticketText): $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			Write-sqmEventLogSafe -EntryType 'Error' -EventId 9021 -Message $errMsg
			throw
		}
		finally
		{
			# --- 4. IMMER versuchen, den Normalbetrieb wiederherzustellen - auch nach
			# einem Fehler. Ein Server, der dauerhaft im Single-User-Mode haengen
			# bleibt, ist schlimmer als ein fehlgeschlagener Notfall-Zugriff. ---
			if ($singleUserSet)
			{
				try { Stop-DbaService -SqlInstance $SqlInstance -Type Engine -Force -EnableException -ErrorAction Stop | Out-Null }
				catch { Invoke-sqmLogging -Message "[$SqlInstance] Dienst vor Rueckbau des Single-User-Mode konnte nicht sauber gestoppt werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING' }

				try
				{
					Set-DbaStartupParameter -SqlInstance $SqlInstance -SingleUser:$false -Force -EnableException -ErrorAction Stop | Out-Null
					Invoke-sqmLogging -Message "[$SqlInstance] Single-User-Mode-Startparameter zurueckgesetzt." -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					$critMsg = "[$SqlInstance] KRITISCH: Single-User-Mode-Startparameter konnte NICHT zurueckgesetzt werden: $($_.Exception.Message). Der Dienst startet beim naechsten Versuch weiterhin im Single-User-Mode - manuell pruefen (Get-DbaStartupParameter bzw. SQL Server Configuration Manager)!"
					Invoke-sqmLogging -Message $critMsg -FunctionName $functionName -Level 'ERROR'
					Write-sqmEventLogSafe -EntryType 'Error' -EventId 9022 -Message $critMsg
				}

				try
				{
					Start-DbaService -SqlInstance $SqlInstance -Type Engine -EnableException -ErrorAction Stop | Out-Null
					Invoke-sqmLogging -Message "[$SqlInstance] SQL-Dienst wieder im normalen Mehrbenutzerbetrieb gestartet." -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					$critMsg2 = "[$SqlInstance] KRITISCH: SQL-Dienst konnte nach der Notfallprozedur NICHT wieder gestartet werden: $($_.Exception.Message). Dienst manuell starten!"
					Invoke-sqmLogging -Message $critMsg2 -FunctionName $functionName -Level 'ERROR'
					Write-sqmEventLogSafe -EntryType 'Error' -EventId 9023 -Message $critMsg2
				}
			}

			# Klartext-Passwort-Variable im lokalen Speicher loeschen (die Kopie im
			# Rueckgabeobjekt - der ganze Zweck dieser Funktion - bleibt bestehen).
			$plainPassword = $null
		}

		return [PSCustomObject]@{
			SqlInstance       = $SqlInstance
			Login             = $Login
			LoginExisted      = [bool][int]$batchResult.LoginExisted
			Password          = $Password
			PasswordPlainText = $pwCred.GetNetworkCredential().Password
			TicketNumber      = $TicketNumber
			Status            = 'Success'
			Message           = "Login '$Login' hat jetzt sysadmin auf '$SqlInstance'. WICHTIG: Passwort sicher notieren, Zugriff verifizieren, und dieses Notfall-Konto danach entfernen oder das Passwort zeitnah rotieren (z.B. via Grant-sqmTemporarySysadmin fuer den regulaeren Login, dann DROP LOGIN $loginBracket)."
			Timestamp         = Get-Date
		}
	}
}
