<#
.SYNOPSIS
    Vergibt einem Login temporaer eine feste Serverrolle (sysadmin oder dbcreator) fuer
    X Tage und entzieht sie danach automatisch ueber einen selbstloeschenden SQL-Agent-Job -
    bei AlwaysOn failover-robust auf allen Replicas.

.DESCRIPTION
    Fuer Patch-/Installationssituationen: macht einen Login (Windows-/AD-Konto oder
    -Gruppe, oder ein bereits vorhandener SQL-Auth-Login) zeitlich befristet Mitglied
    einer festen Serverrolle.

      - Ohne -StartDate wird SOFORT vergeben (inline) und ein Revoke-Job auf
        heute + X Tage angelegt.
      - Mit -StartDate (in der Zukunft) wird ein Grant-Job auf das Startdatum und
        ein Revoke-Job auf Startdatum + X Tage angelegt.

    Windows-/AD-Logins (DOMAIN\Konto oder AD-Gruppe) UND bereits vorhandene SQL-Auth-Logins
    werden unterstuetzt. Automatisches Anlegen bei Fehlen ist auf Windows-/AD-Logins
    beschraenkt (siehe Login-Handling) - ein fehlender SQL-Login fuehrt zu einem klaren
    Fehler statt einer automatischen Kennwortvergabe.

    Waehrend Login-Anlage/Rollenaenderung/Login-Entfernung werden serverweite DDL-Trigger
    UND die konfigurierte PBM-Policy (DefaultPolicy) temporaer deaktiviert und exakt in den
    vorherigen Zustand zurueckversetzt - siehe Invoke-sqmTempSysadminAction fuer den
    Hintergrund (der eingebaute syspolicy_server_trigger kann sonst jede betroffene
    Anweisung per Rollback abbrechen: "The transaction ended in the trigger.").

    Login-Handling:
      - Existiert ein Windows-/AD-Login nicht, wird er angelegt (CREATE LOGIN ... FROM
        WINDOWS). Ein fehlender SQL-Login fuehrt stattdessen zu einem Fehler.
      - Wurde der Login von diesem Tool angelegt, wird er beim Entzug wieder
        entfernt (sofern er an keiner weiteren Serverrolle haengt).
      - War der Login bereits vorhanden, bleibt er bestehen - nur die Rolle
        wird entzogen.

    AlwaysOn (Default):
      Ist die Instanz Teil einer Availability Group, werden Login-Anlage,
      Rollen-Vergabe und Entzug/Cleanup auf ALLEN Replicas durchgefuehrt. Jede
      Replica erhaelt ihre eigenen, lokal arbeitenden, selbstloeschenden Jobs - so
      bleiben die temporaeren Rechte auch nach einem Failover bestehen und der
      Cleanup laeuft ueberall zuverlaessig. Mit -PrimaryOnly wird nur die
      angegebene Instanz behandelt.

    Jede Aktion wird im Modul-Logfile UND im Windows Event Log protokolliert -
    inklusive der optionalen Auftragsnummer.

.PARAMETER SqlInstance
    SQL Server Instanz. Default: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SOFORTIGE Vergabe (SQL-Auth). Hinweis: Die Agent-Jobs
    laufen unter dem SQL-Agent-Dienstkonto (Windows, i. d. R. sysadmin) und nutzen
    KEINE gespeicherten Credentials.

.PARAMETER Login
    Login/-Gruppe, der/die temporaer die Rolle erhalten soll: Windows-/AD-Konto
    (DOMAIN\Konto), AD-Gruppe, oder ein bereits vorhandener SQL-Auth-Login.

.PARAMETER Role
    Feste Serverrolle: 'sysadmin' (Default) oder 'dbcreator'.

.PARAMETER Days
    Dauer der Rollenmitgliedschaft in Tagen.

.PARAMETER StartDate
    Optionaler Aktivierungszeitpunkt. Fehlt er (oder liegt in der Vergangenheit),
    wird sofort vergeben.

.PARAMETER PrimaryOnly
    Nur die angegebene Instanz behandeln, AlwaysOn-Replicas ignorieren.

.PARAMETER SkipSecondaryServers
    Liste von Replica-Instanznamen, die uebersprungen werden sollen.

.PARAMETER TicketNumber
    Optionale Auftrags-/Ticketnummer fuer die Protokollierung.

.PARAMETER Force
    Ueberschreibt bereits vorhandene gleichnamige Grant-/Revoke-Jobs.

.PARAMETER Confirm
    Erzwingt eine interaktive Rueckfrage vor der Vergabe (Standard: keine Rueckfrage - siehe
    .NOTES).

.PARAMETER WhatIf
    Zeigt nur, was passieren wuerde, ohne etwas zu aendern.

.EXAMPLE
    Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'DOM\u.maier' -Days 3 -TicketNumber 'INC0012345'
    # Sofort sysadmin fuer 3 Tage (auf allen AG-Replicas), danach automatischer Entzug.

.EXAMPLE
    Grant-sqmTemporarySysadmin -Login 'DOM\u.maier' -Days 1 -StartDate '2026-07-01 08:00' -TicketNumber 'CHG7788'
    # Aktivierung am 01.07. 08:00, Entzug am 02.07. 08:00.

.EXAMPLE
    Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'DOM\u.maier' -Days 2 -PrimaryOnly -WhatIf
    # Zeigt nur, was passieren wuerde - nur auf SQL01, ohne Replicas.

.EXAMPLE
    Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'app_deploy' -Role dbcreator -Days 1 -TicketNumber 'CHG9001'
    # dbcreator statt sysadmin, fuer einen bestehenden SQL-Login.

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Invoke-sqmTempSysadminAction.
    Aufrufer braucht fuer die Sofort-Vergabe sysadmin/ALTER auf der Serverrolle.
    Das SQL-Agent-Dienstkonto braucht sysadmin (fuer DROP/Self-Delete) und das
    Modul maschinenweit (AllUsers).

    ConfirmImpact ist 'High' (zurecht - Rechte-Eskalation auf Produktion), $ConfirmPreference
    wird aber intern auf 'None' gesetzt: -TicketNumber ist bereits der Nachweis einer bewussten
    Entscheidung, und eine interaktive Rueckfrage wuerde einen skriptgesteuerten Aufruf (z.B.
    aus einer Ticket-/ServiceNow-Automatisierung ohne interaktive Session) haengen lassen.
    -Confirm explizit angeben, um die Rueckfrage bewusst wieder einzuschalten.
#>
function Grant-sqmTemporarySysadmin
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$Login,
		[Parameter(Mandatory = $false)]
		[ValidateSet('sysadmin', 'dbcreator')]
		[string]$Role = 'sysadmin',
		[Parameter(Mandatory = $true)]
		[ValidateRange(1, 3650)]
		[int]$Days,
		[Parameter(Mandatory = $false)]
		[datetime]$StartDate,
		[Parameter(Mandatory = $false)]
		[switch]$PrimaryOnly,
		[Parameter(Mandatory = $false)]
		[string[]]$SkipSecondaryServers = @(),
		[Parameter(Mandatory = $false)]
		[string]$TicketNumber,
		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		# ConfirmImpact bleibt 'High' (dokumentiert weiterhin zurecht als hochriskante Aktion),
		# aber PowerShells Default $ConfirmPreference = 'High' wuerde dafuer automatisch die
		# interaktive "Moechten Sie diesen Vorgang ausfuehren?"-Abfrage einblenden - Reibung, die
		# bei ticketbasierten (-TicketNumber ist bereits der Nachweis fuer eine bewusste
		# Entscheidung) oder skriptgesteuerten Aufrufen (z.B. aus einer ServiceNow-Automatisierung)
		# nicht gewuenscht ist und dort sogar haengen bleiben wuerde (keine interaktive Session zum
		# Beantworten). Default daher ohne Rueckfrage; wer die Abfrage bewusst will, kann -Confirm
		# explizit anhaengen - das ueberstimmt diesen Default fuer den einzelnen Aufruf wieder.
		$ConfirmPreference = 'None'
	}

	process
	{
		# Windows-/AD-Logins UND bereits vorhandene SQL-Auth-Logins sind erlaubt - die
		# Einschraenkung "nur Windows-Logins" gilt nur noch fuer das automatische Anlegen bei
		# Fehlen (CREATE LOGIN ... FROM WINDOWS macht fuer einen SQL-Login keinen Sinn) und wird
		# dafuer in Invoke-sqmTempSysadminAction geprueft, nicht hier pauschal fuer jeden Login.

		# --- Zeiten bestimmen ---
		$now = Get-Date
		$immediate = (-not $PSBoundParameters.ContainsKey('StartDate')) -or ($StartDate -le $now)
		$activation = if ($immediate) { $now } else { $StartDate }
		$revocation = $activation.AddDays($Days)

		# --- Punkt 2: Ziel-Replicas ermitteln (AlwaysOn) ---
		$targets = New-Object System.Collections.Generic.List[string]
		if ($PrimaryOnly)
		{
			$targets.Add($SqlInstance)
		}
		else
		{
			try
			{
				$replicas = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop -Query @"
SELECT DISTINCT ar.replica_server_name
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id;
"@
				if ($replicas)
				{
					foreach ($r in @($replicas | Select-Object -ExpandProperty replica_server_name))
					{
						if ($SkipSecondaryServers -contains $r) { continue }
						$targets.Add($r)
					}
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "AlwaysOn-Ermittlung auf '$SqlInstance' nicht moeglich, behandle nur diese Instanz: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
			}

			if ($targets.Count -eq 0) { $targets.Add($SqlInstance) }
		}

		$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
		$ticketEsc = ($TicketNumber -replace "'", "''")

		# --- lokale Hilfe: One-Time-Job auf einer Ziel-Instanz anlegen ---
		function New-sqmOneTimeJob
		{
			param([string]$TargetInstance, [string]$Name, [string]$Command, [datetime]$When, [string]$Description)

			$existing = Get-DbaAgentJob -SqlInstance $TargetInstance -Job $Name -ErrorAction SilentlyContinue
			if ($existing -and -not $Force) { throw "Job '$Name' existiert auf '$TargetInstance' bereits. -Force zum Ueberschreiben." }
			if ($existing -and $Force) { Remove-DbaAgentJob -SqlInstance $TargetInstance -Job $Name -Confirm:$false -ErrorAction Stop }

			$null = New-DbaAgentJob -SqlInstance $TargetInstance -Job $Name -Description $Description -ErrorAction Stop
			$null = New-DbaAgentJobStep -SqlInstance $TargetInstance -Job $Name -StepName 'Run' `
				-Subsystem 'CmdExec' -Command $Command -ErrorAction Stop

			$schedName = "sch_$Name"
			$startDateInt = [int]$When.ToString('yyyyMMdd')
			$startTimeInt = [int]$When.ToString('HHmmss')
			$schedSql = @"
DECLARE @sid INT;
WHILE EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'$schedName')
BEGIN
    SELECT TOP (1) @sid = schedule_id FROM msdb.dbo.sysschedules WHERE name = N'$schedName';
    EXEC msdb.dbo.sp_delete_schedule @schedule_id = @sid, @force_delete = 1;
END
EXEC msdb.dbo.sp_add_schedule
    @schedule_name     = N'$schedName',
    @enabled           = 1,
    @freq_type         = 1,
    @active_start_date = $startDateInt,
    @active_start_time = $startTimeInt;
EXEC msdb.dbo.sp_attach_schedule @job_name = N'$Name', @schedule_name = N'$schedName';
"@
			$null = Invoke-DbaQuery -SqlInstance $TargetInstance -Database msdb -Query $schedSql -EnableException -ErrorAction Stop
		}

		$results = New-Object System.Collections.Generic.List[object]

		# --- Pro Ziel-Replica vergeben/planen ---
		foreach ($target in $targets)
		{
			$tConn = @{ SqlInstance = $target }
			if ($SqlCredential) { $tConn['SqlCredential'] = $SqlCredential }

			# Jobnamen je Replica eindeutig - Rolle im Namen, damit z.B. ein temporaeres
			# sysadmin und ein temporaeres dbcreator fuer denselben Login nebeneinander
			# bestehen koennen, statt sich gegenseitig zu ueberschreiben.
			$roleTitle = (Get-Culture).TextInfo.ToTitleCase($Role)
			$sani      = (($Login + '_' + $target) -replace '[^A-Za-z0-9._-]', '_')
			$jobBase   = "sqmTemp${roleTitle}_$sani`_$($activation.ToString('yyyyMMddHHmm'))"
			$revokeJob = "${jobBase}_Revoke"
			$grantJob  = "${jobBase}_Grant"

			$instEsc  = $target -replace "'", "''"
			$loginEsc = $Login -replace "'", "''"

			# Login auf dieser Replica aktuell vorhanden? -> entscheidet ueber Cleanup
			$loginLit = $Login -replace "'", "''"
			$loginExistsNow = $false
			try
			{
				$cnt = Invoke-DbaQuery @tConn -Database master -EnableException -ErrorAction Stop `
					-Query "SELECT COUNT(*) AS Cnt FROM sys.server_principals WHERE name = N'$loginLit' AND type IN ('U','G','S');"
				$loginExistsNow = ($cnt -and [int]$cnt.Cnt -gt 0)
			}
			catch
			{
				Invoke-sqmLogging -Message "[$target] Login-Pruefung fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Role = $Role; Days = $Days; ActivationTime = $activation
						RevocationTime = $revocation; TicketNumber = $TicketNumber; Status = 'Error'
						Message = "Login-Pruefung fehlgeschlagen: $($_.Exception.Message)"
					})
				continue
			}

			$desc = "sqmSQLTool: temporaerer $Role fuer '$Login' bis $($revocation.ToString('yyyy-MM-dd HH:mm')). Auftragsnummer: $(if ($TicketNumber){$TicketNumber}else{'(keine)'})"
			$opText = if ($immediate) { 'SOFORT' } else { "ab $($activation.ToString('yyyy-MM-dd HH:mm'))" }

			if (-not $PSCmdlet.ShouldProcess($target, "$Role fuer '$Login' $opText fuer $Days Tage (Entzug $($revocation.ToString('yyyy-MM-dd HH:mm')))"))
			{
				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Role = $Role; Days = $Days; ActivationTime = $activation
						RevocationTime = $revocation; TicketNumber = $TicketNumber
						GrantJob = if ($immediate) { $null } else { $grantJob }; RevokeJob = $revokeJob
						Immediate = $immediate; LoginExisted = $loginExistsNow; Status = 'WhatIf'
						Message = 'WhatIf: keine Aenderung durchgefuehrt.'
					})
				continue
			}

			try
			{
				if ($immediate)
				{
					# Sofort vergeben (legt Login bei Bedarf an) -> erfahre, ob neu angelegt
					$grantRes = Invoke-sqmTempSysadminAction @tConn -Login $Login -Role $Role -Action Grant -CreateLoginIfMissing -TicketNumber $TicketNumber
					$loginCreated = [bool]$grantRes.LoginCreated

					# Revoke-Job lokal auf dieser Replica; entfernt Login nur wenn wir ihn anlegten
					$rmSwitch  = if ($loginCreated) { ' -RemoveLogin' } else { '' }
					$revokeCmd = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Role '$Role' -Action Revoke -TicketNumber '$ticketEsc' -JobName '$revokeJob'$rmSwitch`""
					New-sqmOneTimeJob -TargetInstance $target -Name $revokeJob -Command $revokeCmd -When $revocation -Description $desc

					$msg = "$Role sofort vergeben$(if($loginCreated){' (Login neu angelegt)'}); automatischer Entzug am $($revocation.ToString('yyyy-MM-dd HH:mm')) via Job '$revokeJob'."
				}
				else
				{
					# Geplant: Grant-Job (legt Login bei Bedarf an) + Revoke-Job.
					# Cleanup-Heuristik: fehlt der Login JETZT, wird der Grant-Job ihn anlegen -> RemoveLogin.
					$rmSwitch  = if (-not $loginExistsNow) { ' -RemoveLogin' } else { '' }

					$grantCmd  = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Role '$Role' -Action Grant -CreateLoginIfMissing -TicketNumber '$ticketEsc' -JobName '$grantJob'`""
					New-sqmOneTimeJob -TargetInstance $target -Name $grantJob -Command $grantCmd -When $activation -Description $desc

					$revokeCmd = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Role '$Role' -Action Revoke -TicketNumber '$ticketEsc' -JobName '$revokeJob'$rmSwitch`""
					New-sqmOneTimeJob -TargetInstance $target -Name $revokeJob -Command $revokeCmd -When $revocation -Description $desc

					$msg = "Vergabe am $($activation.ToString('yyyy-MM-dd HH:mm')) (Job '$grantJob'), Entzug am $($revocation.ToString('yyyy-MM-dd HH:mm')) (Job '$revokeJob')."
				}

				Invoke-sqmLogging -Message "[$target] $msg Login '$Login', Auftragsnummer: $(if($TicketNumber){$TicketNumber}else{'(keine)'})" -FunctionName $functionName -Level "INFO"

				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Role = $Role; Days = $Days; ActivationTime = $activation
						RevocationTime = $revocation; TicketNumber = $TicketNumber
						GrantJob = if ($immediate) { $null } else { $grantJob }; RevokeJob = $revokeJob
						Immediate = $immediate; LoginExisted = $loginExistsNow; Status = 'Success'; Message = $msg
					})
			}
			catch
			{
				Invoke-sqmLogging -Message "[$target] Fehler bei temporaerer $Role-Vergabe fuer '$Login': $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Role = $Role; Days = $Days; ActivationTime = $activation
						RevocationTime = $revocation; TicketNumber = $TicketNumber; Status = 'Error'
						Message = $_.Exception.Message
					})
			}
		}

		return $results
	}
}
