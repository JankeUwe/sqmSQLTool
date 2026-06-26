<#
.SYNOPSIS
    Vergibt einem Login temporaer sysadmin-Rechte fuer X Tage und entzieht sie
    danach automatisch ueber einen selbstloeschenden SQL-Agent-Job.

.DESCRIPTION
    Fuer Patch-/Installationssituationen: macht einen Anwender zeitlich befristet
    zum sysadmin.

      - Ohne -StartDate wird SOFORT vergeben (inline) und ein Revoke-Job auf
        heute + X Tage angelegt.
      - Mit -StartDate (in der Zukunft) wird ein Grant-Job auf das Startdatum und
        ein Revoke-Job auf Startdatum + X Tage angelegt.

    Beide Jobs sind One-Time-Jobs, die sich bei Erfolg selbst loeschen
    (via Invoke-sqmTempSysadminAction -> sp_delete_job).

    Jede Aktion wird im Modul-Logfile UND im Windows Event Log protokolliert -
    inklusive der optionalen Auftragsnummer.

.PARAMETER SqlInstance
    SQL Server Instanz. Default: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SOFORTIGE Vergabe (SQL-Auth). Hinweis: Die Agent-Jobs
    laufen unter dem SQL-Agent-Dienstkonto (Windows, i. d. R. sysadmin) und nutzen
    KEINE gespeicherten Credentials.

.PARAMETER Login
    Login / Server-Principal, der temporaer sysadmin werden soll. Muss bereits als
    Login existieren (wird NICHT angelegt).

.PARAMETER Days
    Dauer der sysadmin-Rechte in Tagen.

.PARAMETER StartDate
    Optionaler Aktivierungszeitpunkt. Fehlt er (oder liegt in der Vergangenheit),
    wird sofort vergeben.

.PARAMETER TicketNumber
    Optionale Auftrags-/Ticketnummer fuer die Protokollierung.

.PARAMETER Force
    Ueberschreibt bereits vorhandene gleichnamige Grant-/Revoke-Jobs.

.EXAMPLE
    Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'DOM\u.maier' -Days 3 -TicketNumber 'INC0012345'
    # Sofort sysadmin fuer 3 Tage, danach automatischer Entzug.

.EXAMPLE
    Grant-sqmTemporarySysadmin -Login 'DOM\u.maier' -Days 1 -StartDate '2026-07-01 08:00' -TicketNumber 'CHG7788'
    # Aktivierung am 01.07. 08:00, Entzug am 02.07. 08:00.

.EXAMPLE
    Grant-sqmTemporarySysadmin -Login 'DOM\u.maier' -Days 2 -WhatIf
    # Zeigt nur, was passieren wuerde - ohne Vergabe/Job-Anlage.

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
		# --- Zeiten bestimmen ---
		$now = Get-Date
		$immediate = (-not $PSBoundParameters.ContainsKey('StartDate')) -or ($StartDate -le $now)
		$activation = if ($immediate) { $now } else { $StartDate }
		$revocation = $activation.AddDays($Days)

		# --- Login-Existenz pruefen (read-only) ---
		$loginLit = $Login -replace "'", "''"
		try
		{
			$exists = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
				-Query "SELECT COUNT(*) AS Cnt FROM sys.server_principals WHERE name = N'$loginLit' AND type IN ('U','G','S','K');"
			if (-not $exists -or [int]$exists.Cnt -eq 0)
			{
				throw "Login '$Login' existiert auf '$SqlInstance' nicht. Bitte den Login zuerst anlegen."
			}
		}
		catch
		{
			Invoke-sqmLogging -Message "Login-Pruefung fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
			throw
		}

		# --- Jobnamen ---
		$sani      = ($Login -replace '[^A-Za-z0-9._-]', '_')
		$jobBase   = "sqmTempSysadmin_$sani`_$($activation.ToString('yyyyMMddHHmm'))"
		$revokeJob = "${jobBase}_Revoke"
		$grantJob  = "${jobBase}_Grant"
		$psExe     = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

		# Werte fuer die inline -Command-Strings (Single-Quote-Escape)
		$instEsc   = $SqlInstance -replace "'", "''"
		$loginEsc  = $Login -replace "'", "''"
		$ticketEsc = ($TicketNumber -replace "'", "''")

		# --- lokale Hilfe: One-Time-Job mit CmdExec-Step + Schedule anlegen ---
		function New-sqmOneTimeJob
		{
			param([string]$Name, [string]$Command, [datetime]$When, [string]$Description)

			$existing = Get-DbaAgentJob -SqlInstance $SqlInstance -Job $Name -ErrorAction SilentlyContinue
			if ($existing -and -not $Force) { throw "Job '$Name' existiert bereits. -Force zum Ueberschreiben." }
			if ($existing -and $Force) { Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $Name -Confirm:$false -ErrorAction Stop }

			$null = New-DbaAgentJob -SqlInstance $SqlInstance -Job $Name -Description $Description -ErrorAction Stop
			$null = New-DbaAgentJobStep -SqlInstance $SqlInstance -Job $Name -StepName 'Run' `
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
			$null = Invoke-DbaQuery -SqlInstance $SqlInstance -Database msdb -Query $schedSql -EnableException -ErrorAction Stop
		}

		$result = [PSCustomObject]@{
			SqlInstance    = $SqlInstance
			Login          = $Login
			Days           = $Days
			ActivationTime = $activation
			RevocationTime = $revocation
			TicketNumber   = $TicketNumber
			GrantJob       = if ($immediate) { $null } else { $grantJob }
			RevokeJob      = $revokeJob
			Immediate      = $immediate
			Status         = 'Planned'
			Message        = $null
		}

		$desc = "sqmSQLTool: temporaerer sysadmin fuer '$Login' bis $($revocation.ToString('yyyy-MM-dd HH:mm')). Auftragsnummer: $(if ($TicketNumber){$TicketNumber}else{'(keine)'})"

		if (-not $PSCmdlet.ShouldProcess($SqlInstance, "sysadmin fuer '$Login' $(if($immediate){'SOFORT'}else{"ab $($activation.ToString('yyyy-MM-dd HH:mm'))"}) fuer $Days Tage (Entzug $($revocation.ToString('yyyy-MM-dd HH:mm')))"))
		{
			$result.Status = 'WhatIf'
			$result.Message = "WhatIf: keine Aenderung durchgefuehrt."
			return $result
		}

		try
		{
			# --- Revoke-Job IMMER anlegen ---
			$revokeCmd = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Action Revoke -TicketNumber '$ticketEsc' -JobName '$revokeJob'`""
			New-sqmOneTimeJob -Name $revokeJob -Command $revokeCmd -When $revocation -Description $desc

			# --- Grant ---
			if ($immediate)
			{
				Invoke-sqmTempSysadminAction @connParams -Login $Login -Action Grant -TicketNumber $TicketNumber | Out-Null
			}
			else
			{
				$grantCmd = "$psExe -NoProfile -ExecutionPolicy Bypass -Command `"Import-Module sqmSQLTool; Invoke-sqmTempSysadminAction -SqlInstance '$instEsc' -Login '$loginEsc' -Action Grant -TicketNumber '$ticketEsc' -JobName '$grantJob'`""
				New-sqmOneTimeJob -Name $grantJob -Command $grantCmd -When $activation -Description $desc
			}

			$result.Status = 'Success'
			$result.Message = if ($immediate)
			{
				"sysadmin sofort vergeben; automatischer Entzug am $($revocation.ToString('yyyy-MM-dd HH:mm')) via Job '$revokeJob'."
			}
			else
			{
				"Vergabe am $($activation.ToString('yyyy-MM-dd HH:mm')) (Job '$grantJob'), Entzug am $($revocation.ToString('yyyy-MM-dd HH:mm')) (Job '$revokeJob')."
			}

			Invoke-sqmLogging -Message "$($result.Message) Login '$Login', Auftragsnummer: $(if($TicketNumber){$TicketNumber}else{'(keine)'})" -FunctionName $functionName -Level "INFO"
			return $result
		}
		catch
		{
			$result.Status = 'Error'
			$result.Message = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler bei temporaerer sysadmin-Vergabe fuer '$Login': $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
			throw
		}
	}
}
