<#
.SYNOPSIS
    Vergibt einem AD-Login temporaer sysadmin-Rechte fuer X Tage und entzieht sie
    danach automatisch ueber einen selbstloeschenden SQL-Agent-Job - bei AlwaysOn
    failover-robust auf allen Replicas.

.DESCRIPTION
    Fuer Patch-/Installationssituationen: macht einen AD-Anwender (oder eine
    AD-Gruppe) zeitlich befristet zum sysadmin.

      - Ohne -StartDate wird SOFORT vergeben (inline) und ein Revoke-Job auf
        heute + X Tage angelegt.
      - Mit -StartDate (in der Zukunft) wird ein Grant-Job auf das Startdatum und
        ein Revoke-Job auf Startdatum + X Tage angelegt.

    Es werden AUSSCHLIESSLICH Windows-/AD-Logins unterstuetzt (DOMAIN\Konto oder
    AD-Gruppe). SQL-Auth-Logins werden abgewiesen.

    Login-Handling:
      - Existiert der Login nicht, wird er angelegt (CREATE LOGIN ... FROM WINDOWS).
        Eine konfigurierte PBM-Policy (DefaultPolicy) wird dafuer kurz deaktiviert
        und danach wieder aktiviert.
      - Wurde der Login von diesem Tool angelegt, wird er beim Entzug wieder
        entfernt (sofern er an keiner weiteren Serverrolle haengt).
      - War der Login bereits vorhanden, bleibt er bestehen - nur die sysadmin-Rolle
        wird entzogen.

    AlwaysOn (Default):
      Ist die Instanz Teil einer Availability Group, werden Login-Anlage,
      sysadmin-Vergabe und Entzug/Cleanup auf ALLEN Replicas durchgefuehrt. Jede
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
    AD-Login / -Gruppe (DOMAIN\Konto), der temporaer sysadmin werden soll.

.PARAMETER Days
    Dauer der sysadmin-Rechte in Tagen.

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

.EXAMPLE
    Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'DOM\u.maier' -Days 3 -TicketNumber 'INC0012345'
    # Sofort sysadmin fuer 3 Tage (auf allen AG-Replicas), danach automatischer Entzug.

.EXAMPLE
    Grant-sqmTemporarySysadmin -Login 'DOM\u.maier' -Days 1 -StartDate '2026-07-01 08:00' -TicketNumber 'CHG7788'
    # Aktivierung am 01.07. 08:00, Entzug am 02.07. 08:00.

.EXAMPLE
    Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'DOM\u.maier' -Days 2 -PrimaryOnly -WhatIf
    # Zeigt nur, was passieren wuerde - nur auf SQL01, ohne Replicas.

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Invoke-sqmTempSysadminAction.
    Aufrufer braucht fuer die Sofort-Vergabe sysadmin/ALTER auf der Serverrolle.
    Das SQL-Agent-Dienstkonto braucht sysadmin (fuer DROP/Self-Delete) und das
    Modul maschinenweit (AllUsers).
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
	}

	process
	{
		# --- Punkt 4: ausschliesslich AD-/Windows-Logins zulassen ---
		if ($Login -notmatch '\\')
		{
			throw "Login '$Login' ist kein Windows-/AD-Login. Es werden ausschliesslich AD-Logins im Format 'DOMAIN\Konto' unterstuetzt."
		}

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

			# Jobnamen je Replica eindeutig
			$sani      = (($Login + '_' + $target) -replace '[^A-Za-z0-9._-]', '_')
			$jobBase   = "sqmTempSysadmin_$sani`_$($activation.ToString('yyyyMMddHHmm'))"
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
					-Query "SELECT COUNT(*) AS Cnt FROM sys.server_principals WHERE name = N'$loginLit' AND type IN ('U','G');"
				$loginExistsNow = ($cnt -and [int]$cnt.Cnt -gt 0)
			}
			catch
			{
				Invoke-sqmLogging -Message "[$target] Login-Pruefung fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Days = $Days; ActivationTime = $activation
						RevocationTime = $revocation; TicketNumber = $TicketNumber; Status = 'Error'
						Message = "Login-Pruefung fehlgeschlagen: $($_.Exception.Message)"
					})
				continue
			}

			$desc = "sqmSQLTool: temporaerer sysadmin fuer '$Login' bis $($revocation.ToString('yyyy-MM-dd HH:mm')). Auftragsnummer: $(if ($TicketNumber){$TicketNumber}else{'(keine)'})"
			$opText = if ($immediate) { 'SOFORT' } else { "ab $($activation.ToString('yyyy-MM-dd HH:mm'))" }

			if (-not $PSCmdlet.ShouldProcess($target, "sysadmin fuer '$Login' $opText fuer $Days Tage (Entzug $($revocation.ToString('yyyy-MM-dd HH:mm')))"))
			{
				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Days = $Days; ActivationTime = $activation
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
					$grantRes = Invoke-sqmTempSysadminAction @tConn -Login $Login -Action Grant -CreateLoginIfMissing -TicketNumber $TicketNumber
					$loginCreated = [bool]$grantRes.LoginCreated

					# Revoke-Job lokal auf dieser Replica; entfernt Login nur wenn wir ihn anlegten
					$rmSwitch  = if ($loginCreated) { ' -RemoveLogin' } else { '' }
					$revokeCmd = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Action Revoke -TicketNumber '$ticketEsc' -JobName '$revokeJob'$rmSwitch`""
					New-sqmOneTimeJob -TargetInstance $target -Name $revokeJob -Command $revokeCmd -When $revocation -Description $desc

					$msg = "sysadmin sofort vergeben$(if($loginCreated){' (Login neu angelegt)'}); automatischer Entzug am $($revocation.ToString('yyyy-MM-dd HH:mm')) via Job '$revokeJob'."
				}
				else
				{
					# Geplant: Grant-Job (legt Login bei Bedarf an) + Revoke-Job.
					# Cleanup-Heuristik: fehlt der Login JETZT, wird der Grant-Job ihn anlegen -> RemoveLogin.
					$rmSwitch  = if (-not $loginExistsNow) { ' -RemoveLogin' } else { '' }

					$grantCmd  = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Action Grant -CreateLoginIfMissing -TicketNumber '$ticketEsc' -JobName '$grantJob'`""
					New-sqmOneTimeJob -TargetInstance $target -Name $grantJob -Command $grantCmd -When $activation -Description $desc

					$revokeCmd = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Action Revoke -TicketNumber '$ticketEsc' -JobName '$revokeJob'$rmSwitch`""
					New-sqmOneTimeJob -TargetInstance $target -Name $revokeJob -Command $revokeCmd -When $revocation -Description $desc

					$msg = "Vergabe am $($activation.ToString('yyyy-MM-dd HH:mm')) (Job '$grantJob'), Entzug am $($revocation.ToString('yyyy-MM-dd HH:mm')) (Job '$revokeJob')."
				}

				Invoke-sqmLogging -Message "[$target] $msg Login '$Login', Auftragsnummer: $(if($TicketNumber){$TicketNumber}else{'(keine)'})" -FunctionName $functionName -Level "INFO"

				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Days = $Days; ActivationTime = $activation
						RevocationTime = $revocation; TicketNumber = $TicketNumber
						GrantJob = if ($immediate) { $null } else { $grantJob }; RevokeJob = $revokeJob
						Immediate = $immediate; LoginExisted = $loginExistsNow; Status = 'Success'; Message = $msg
					})
			}
			catch
			{
				Invoke-sqmLogging -Message "[$target] Fehler bei temporaerer sysadmin-Vergabe fuer '$Login': $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
				$results.Add([PSCustomObject]@{
						SqlInstance = $target; Login = $Login; Days = $Days; ActivationTime = $activation
						RevocationTime = $revocation; TicketNumber = $TicketNumber; Status = 'Error'
						Message = $_.Exception.Message
					})
			}
		}

		return $results
	}
}
