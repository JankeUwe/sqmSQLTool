<#
.SYNOPSIS
Installs a predefined sqmSQLTool standard job (e.g. the AlwaysOn login sync) as a SQL Agent job
with tested defaults - one call, no parameter hashtables.

.DESCRIPTION
Standard jobs are recurring tasks whose job parameters are fixed in a catalog inside this
function: target function, safe parameter defaults, job name, schedule and whether the job only
works on the AG primary. The job itself is created by New-sqmAgentCommandJob (generic wrapper,
parameters via Clixml).

Catalog (Install-sqmStandardJob -List shows it with all defaults):

  AgLoginSync     Sync-sqmLoginsToAlwaysOn -SyncMode Union -Force:$false, daily 02:00, job
                  'sqmAutoLoginSync', plus a failover alert (see below).
                  Creates logins that are missing on any replica, in every direction: a login
                  created on the old primary shortly before a failover is no longer lost.
                  Tombstones and conflicts are only reported (event 9004). -Force (DROP + CREATE
                  of existing logins) is deliberately off: in unattended runs it lost logins
                  whenever the CREATE failed afterwards (see CHANGELOG v1.8.19.0).
  AgLoginCompare  Compare-sqmAlwaysOnLogins -FailOnDrift -OnlyDifferences, daily 06:00,
                  job 'sqmAutoLoginCompare'. The job fails on login drift (event 9001), so the
                  drift the sync does not fix (passwords, default DB) still gets noticed.

All AG standard jobs are PrimaryOnly: install them on EVERY replica. On a secondary the step ends
with success without doing anything, after a failover the new primary takes over automatically.

Failover alert (AgLoginSync): an Agent alert '<JobName> - AG failover (1480)' on message 1480
(database changes its AG role) starts the job right after a failover instead of waiting for the
next 02:00 run. 1480 is raised once per database, so the alert waits 600 s between responses.
The alert fires on the old and the new primary; PrimaryOnly lets only the new primary work.
SQL Agent allows only one alert per condition: if another alert on 1480 already exists without a
job response, the job is attached to it (its notifications stay). If it already starts another
job, nothing is changed and the result says so. -NoFailoverAlert skips the alert.

.PARAMETER Name
Standard job from the catalog: AgLoginSync, AgLoginCompare.

.PARAMETER List
Shows the catalog with all defaults instead of installing anything.

.PARAMETER SqlInstance
Instance on which the job is created (default: computer name). Run this ON that server: the
wrapper and parameter files are written locally to the module's jobs folder.

.PARAMETER SqlCredential
Only for the connection that CREATES the job. The job step itself runs as the SQL Agent service
account.

.PARAMETER AvailabilityGroupName
AG for the AG standard jobs. Without it the target function uses the first AG on the instance.

.PARAMETER JobName
Overrides the job name from the catalog.

.PARAMETER Parameters
Hashtable merged over the catalog parameters (your values win), e.g. @{ AuditAdOrphans = $true }.

.PARAMETER ScheduleType
Overrides the schedule type from the catalog: None, Daily, Weekly, Monthly.

.PARAMETER ScheduleTime
Overrides the start time from the catalog, "HH:mm".

.PARAMETER ScheduleDays
Weekdays for -ScheduleType Weekly.

.PARAMETER Force
Replaces an existing job with the same name.

.PARAMETER StartJob
Starts the job right after it was created.

.PARAMETER NoFailoverAlert
AgLoginSync only: do not create the failover alert on message 1480.

.PARAMETER EnableException
Throw exceptions immediately instead of returning a result object with Status 'Failed'.

.EXAMPLE
Install-sqmStandardJob -List

.EXAMPLE
# On every AG replica:
Install-sqmStandardJob -Name AgLoginSync

.EXAMPLE
Install-sqmStandardJob -Name AgLoginSync -AvailabilityGroupName 'AG_Prod' -Parameters @{ AuditAdOrphans = $true } -Force

.EXAMPLE
Install-sqmStandardJob -Name AgLoginCompare -ScheduleTime '07:30'

.NOTES
Requires dbatools, New-sqmAgentCommandJob (same module).
The SQL Agent service account needs sysadmin on all replicas and write access to the configured
LogPath / output path.
#>
function Install-sqmStandardJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Install')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Install')]
		[ValidateSet('AgLoginSync', 'AgLoginCompare')]
		[string]$Name,

		[Parameter(Mandatory = $true, ParameterSetName = 'List')]
		[switch]$List,

		[Parameter(ParameterSetName = 'Install')]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(ParameterSetName = 'Install')]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(ParameterSetName = 'Install')]
		[string]$AvailabilityGroupName,

		[Parameter(ParameterSetName = 'Install')]
		[string]$JobName,

		[Parameter(ParameterSetName = 'Install')]
		[hashtable]$Parameters,

		[Parameter(ParameterSetName = 'Install')]
		[ValidateSet('None', 'Daily', 'Weekly', 'Monthly')]
		[string]$ScheduleType,

		[Parameter(ParameterSetName = 'Install')]
		[ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
		[string]$ScheduleTime,

		[Parameter(ParameterSetName = 'Install')]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
		[string[]]$ScheduleDays,

		[Parameter(ParameterSetName = 'Install')]
		[switch]$Force,

		[Parameter(ParameterSetName = 'Install')]
		[switch]$StartJob,

		[Parameter(ParameterSetName = 'Install')]
		[switch]$NoFailoverAlert,

		[Parameter(ParameterSetName = 'Install')]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# ----------------------------------------------------------------------
		# Katalog der Standard-Jobs. Neue Standard-Jobs hier eintragen und den Namen in das
		# ValidateSet von -Name aufnehmen.
		# ----------------------------------------------------------------------
		$catalog = [ordered]@{
			'AgLoginSync' = @{
				Description  = 'Fehlende Logins auf allen AG-Replikaten ergaenzen, in jede Richtung (ohne DROP/CREATE bestehender Logins). Start auch nach Failover (Alert 1480).'
				FunctionName = 'Sync-sqmLoginsToAlwaysOn'
				StepName     = 'AgLoginSync'
				# Force:$false ist Absicht: -Force = DROP+CREATE, hat unbeaufsichtigt Logins verloren (v1.8.19.0).
				# Union statt Primary: ein kurz vor dem Failover angelegter Login liegt nur auf dem neuen
				# Secondary und wuerde von einem Primary->Secondary-Sync nie gefunden.
				Parameters    = @{ Force = $false; SyncMode = 'Union' }
				JobName       = 'sqmAutoLoginSync'
				ScheduleType  = 'Daily'
				ScheduleTime  = '02:00'
				PrimaryOnly   = $true
				UsesAg        = $true
				FailoverAlert = $true
			}
			'AgLoginCompare' = @{
				Description  = 'Logins aller AG-Replikate vergleichen, Job schlaegt bei Drift fehl (Event 9001).'
				FunctionName = 'Compare-sqmAlwaysOnLogins'
				StepName     = 'AgLoginCompare'
				Parameters   = @{ FailOnDrift = $true; OnlyDifferences = $true }
				JobName      = 'sqmAutoLoginCompare'
				ScheduleType = 'Daily'
				ScheduleTime = '06:00'
				PrimaryOnly  = $true
				UsesAg       = $true
			}
		}
	}

	process
	{
		if ($PSCmdlet.ParameterSetName -eq 'List')
		{
			foreach ($key in $catalog.Keys)
			{
				$c = $catalog[$key]
				[PSCustomObject]@{
					Name         = $key
					JobName      = $c.JobName
					FunctionName = $c.FunctionName
					Parameters   = (($c.Parameters.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
					Schedule     = if ($c.ScheduleType -eq 'None') { 'On demand' } else { "$($c.ScheduleType) $($c.ScheduleTime)" }
					PrimaryOnly  = $c.PrimaryOnly
					FailoverAlert = [bool]$c.FailoverAlert
					Description  = $c.Description
				}
			}
			return
		}

		$preset = $catalog[$Name]
		if (-not $JobName) { $JobName = $preset.JobName }

		try
		{
			# ------------------------------------------------------------------
			# 1. Parameter: Katalog -> SqlInstance/AG -> Aufrufer (gewinnt).
			# ------------------------------------------------------------------
			$stepParams = @{}
			foreach ($k in $preset.Parameters.Keys) { $stepParams[$k] = $preset.Parameters[$k] }
			$stepParams['SqlInstance'] = $SqlInstance
			if ($preset.UsesAg -and $AvailabilityGroupName) { $stepParams['AvailabilityGroupName'] = $AvailabilityGroupName }
			if ($Parameters)
			{
				foreach ($k in $Parameters.Keys) { $stepParams[$k] = $Parameters[$k] }
			}

			if ($Name -eq 'AgLoginSync' -and $stepParams['Force'] -eq $true)
			{
				$msg = "AgLoginSync mit Force=`$true: bestehende Logins werden per DROP+CREATE ersetzt. Scheitert das CREATE, ist der Login auf dem Secondary weg (v1.8.19.0)."
				Write-Warning $msg
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
			}

			# ------------------------------------------------------------------
			# 2. Job ueber den generischen Baustein anlegen.
			# ------------------------------------------------------------------
			$effScheduleType = if ($ScheduleType) { $ScheduleType } else { $preset.ScheduleType }
			$effScheduleTime = if ($ScheduleTime) { $ScheduleTime } else { $preset.ScheduleTime }

			$jobParams = @{
				SqlInstance  = $SqlInstance
				JobName      = $JobName
				ScheduleType = $effScheduleType
				ScheduleTime = $effScheduleTime
				Command      = @{
					FunctionName = $preset.FunctionName
					StepName     = $preset.StepName
					Parameters   = $stepParams
					PrimaryOnly  = $preset.PrimaryOnly
				}
			}
			if ($SqlCredential) { $jobParams['SqlCredential'] = $SqlCredential }
			if ($ScheduleDays) { $jobParams['ScheduleDays'] = $ScheduleDays }

			if (-not $PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "Standard-Job '$Name' installieren"))
			{
				return
			}

			Invoke-sqmLogging -Message "Installiere Standard-Job '$Name' als '$JobName' auf '$SqlInstance' ($($preset.FunctionName), $effScheduleType $effScheduleTime, PrimaryOnly=$($preset.PrimaryOnly))." -FunctionName $functionName -Level 'INFO'

			$jobResult = New-sqmAgentCommandJob @jobParams -Force:$Force -StartJob:$StartJob -Confirm:$false -EnableException:$EnableException

			$status = if ($jobResult) { $jobResult.Status } else { 'Failed' }
			$message = if ($status -eq 'Success') { "Standard-Job '$Name' installiert." } else { "$($jobResult.Message)" }

			# ------------------------------------------------------------------
			# 3. Failover-Alert: Meldung 1480 (Datenbank wechselt die AG-Rolle) startet den Job
			#    sofort, statt bis zum naechsten Zeitplanlauf zu warten.
			# ------------------------------------------------------------------
			$alertName = $null
			$alertStatus = $null
			if ($status -eq 'Success' -and $preset.FailoverAlert -and -not $NoFailoverAlert)
			{
				$alertName = "$JobName - AG failover (1480)"
				# Agent erlaubt pro Bedingung nur einen Alert (Fehler 14501). Ein vorhandener fremder
				# 1480-Alert ohne Job bekommt den Job als Reaktion, seine Benachrichtigungen bleiben.
				$alertSql = @"
DECLARE @other sysname, @otherJob uniqueidentifier;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @alertName)
    EXEC msdb.dbo.sp_delete_alert @name = @alertName;
SELECT TOP (1) @other = name, @otherJob = job_id
FROM msdb.dbo.sysalerts
WHERE message_id = 1480 AND ISNULL(database_name, N'') = N'' AND ISNULL(event_description_keyword, N'') = N'';
IF @other IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_alert @name = @alertName, @message_id = 1480, @severity = 0, @enabled = 1,
         @delay_between_responses = 600, @include_event_description_in = 0, @job_name = @jobName;
    SELECT N'Created' AS Result, @alertName AS AlertName;
END
ELSE IF @otherJob IS NULL OR @otherJob = '00000000-0000-0000-0000-000000000000'
BEGIN
    EXEC msdb.dbo.sp_update_alert @name = @other, @job_name = @jobName;
    SELECT N'Linked' AS Result, @other AS AlertName;
END
ELSE
    SELECT N'Occupied' AS Result, @other AS AlertName;
"@
				$alertConn = @{ SqlInstance = $SqlInstance }
				if ($SqlCredential) { $alertConn['SqlCredential'] = $SqlCredential }
				try
				{
					$ar = Invoke-DbaQuery @alertConn -Database msdb -Query $alertSql -SqlParameter @{ alertName = $alertName; jobName = $JobName } -EnableException
					$alertName = [string]$ar.AlertName
					$alertStatus = [string]$ar.Result
					switch ($alertStatus)
					{
						'Created' { $message += " Failover-Alert '$alertName' (1480) startet den Job nach einem Rollenwechsel." }
						'Linked' { $message += " Vorhandener 1480-Alert '$alertName' startet jetzt zusaetzlich den Job." }
						'Occupied'
						{
							$message += " Failover-Alert NICHT angelegt: '$alertName' ueberwacht 1480 schon und startet einen anderen Job. Den Job dort als weiteren Step aufnehmen oder den Alert anpassen."
							Write-Warning $message
						}
					}
					Invoke-sqmLogging -Message "Failover-Alert fuer '$JobName': $alertStatus ('$alertName')." -FunctionName $functionName -Level $(if ($alertStatus -eq 'Occupied') { 'WARNING' } else { 'INFO' })
				}
				catch
				{
					$alertStatus = 'Failed'
					$message += " Failover-Alert konnte nicht angelegt werden: $($_.Exception.Message)"
					Write-Warning $message
					Invoke-sqmLogging -Message "Failover-Alert fuer '$JobName' fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}
			elseif ($status -eq 'Success' -and $preset.FailoverAlert -and $NoFailoverAlert)
			{
				# Ein frueher angelegter eigener Alert zeigt nach dem Neuanlegen des Jobs ins Leere.
				$alertConn = @{ SqlInstance = $SqlInstance }
				if ($SqlCredential) { $alertConn['SqlCredential'] = $SqlCredential }
				try
				{
					$ar = Invoke-DbaQuery @alertConn -Database msdb -SqlParameter @{ alertName = "$JobName - AG failover (1480)" } -EnableException -Query @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @alertName)
BEGIN
    EXEC msdb.dbo.sp_delete_alert @name = @alertName;
    SELECT N'Removed' AS Result;
END
ELSE
    SELECT N'None' AS Result;
"@
					if ($ar.Result -eq 'Removed')
					{
						$alertStatus = 'Removed'
						$message += " Bisheriger Failover-Alert '$JobName - AG failover (1480)' entfernt (-NoFailoverAlert)."
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Alten Failover-Alert nicht entfernt: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}
			$level = if ($status -eq 'Success') { 'INFO' } else { 'ERROR' }
			Invoke-sqmLogging -Message "Standard-Job '$Name' ('$JobName'): $status. $message" -FunctionName $functionName -Level $level

			return [PSCustomObject]@{
				Name         = $Name
				SqlInstance  = $SqlInstance
				JobName      = $JobName
				FunctionName = $preset.FunctionName
				Parameters   = $stepParams
				ScheduleName = $jobResult.ScheduleName
				PrimaryOnly  = $preset.PrimaryOnly
				AlertName    = $alertName
				AlertStatus  = $alertStatus
				Started      = [bool]$jobResult.Started
				Status       = $status
				Message      = $message
				Timestamp    = Get-Date
			}
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			Write-Error $errMsg
			return [PSCustomObject]@{
				Name        = $Name
				SqlInstance = $SqlInstance
				JobName     = $JobName
				Status      = 'Failed'
				Message     = $errMsg
				Timestamp   = Get-Date
			}
		}
	}
}
