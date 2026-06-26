<#
.SYNOPSIS
    Fuehrt die eigentliche sysadmin-Vergabe bzw. -Entziehung aus und loescht optional
    den aufrufenden SQL-Agent-Job nach Erfolg (selbstloeschender Job).

.DESCRIPTION
    Wird von den durch Grant-sqmTemporarySysadmin erzeugten Agent-Jobs aufgerufen,
    kann aber auch manuell verwendet werden (z. B. fuer einen vorzeitigen Entzug).

    Aktion:
      Grant   -> ALTER SERVER ROLE [sysadmin] ADD MEMBER  (nur wenn noch nicht Mitglied)
      Revoke  -> ALTER SERVER ROLE [sysadmin] DROP MEMBER  (nur wenn Mitglied)

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
    Betroffener Login / Server-Principal (Windows-, SQL- oder Gruppen-Login).

.PARAMETER Action
    'Grant' oder 'Revoke'.

.PARAMETER TicketNumber
    Optionale Auftrags-/Ticketnummer fuer die Protokollierung.

.PARAMETER JobName
    Optional: Name des aufrufenden Agent-Jobs. Wird nach erfolgreicher Aktion
    geloescht (Selbstloeschung).

.EXAMPLE
    Invoke-sqmTempSysadminAction -SqlInstance SQL01 -Login 'DOM\u.maier' -Action Revoke

.EXAMPLE
    # Vorzeitiger manueller Entzug inkl. Entfernen des geplanten Revoke-Jobs:
    Invoke-sqmTempSysadminAction -Login 'DOM\u.maier' -Action Revoke -JobName 'sqmTempSysadmin_DOM_u.maier_Revoke'

.NOTES
    Requires: dbatools, Invoke-sqmLogging. Ausfuehrender Kontext braucht sysadmin/
    ALTER auf der Serverrolle. Im Job-Kontext laeuft dies unter dem SQL-Agent-Dienstkonto.
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

		try
		{
			if ($Action -eq 'Grant')
			{
				$sql = @"
IF IS_SRVROLEMEMBER('sysadmin', N'$loginLit') = 0
    ALTER SERVER ROLE [sysadmin] ADD MEMBER $loginBracket;
"@
			}
			else
			{
				$sql = @"
IF IS_SRVROLEMEMBER('sysadmin', N'$loginLit') = 1
    ALTER SERVER ROLE [sysadmin] DROP MEMBER $loginBracket;
"@
			}

			Invoke-DbaQuery @connParams -Database master -Query $sql -EnableException -ErrorAction Stop

			$msg = "sysadmin $Action fuer Login '$Login' auf '$SqlInstance' erfolgreich. Auftragsnummer: $ticketText."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
			Write-sqmEventLogSafe -Message $msg -EntryType 'Information' -EventId $(if ($Action -eq 'Grant') { 9001 } else { 9002 })

			# Selbstloeschung des aufrufenden Jobs - NUR bei Erfolg
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
