<#
.SYNOPSIS
Creates a SQL Server Agent job that runs Invoke-sqmPreferredPrimaryCheck every few minutes, so an
availability group returns to its defined primary node on its own after a patch weekend.

.DESCRIPTION
Wraps New-sqmAgentCommandJob (generic CmdExec wrapper + typed .clixml parameters) and adds the
recurring schedule that function does not offer: daily, repeating every -IntervalMinutes minutes.

The policy parameters (-MaxRedoQueueMB, -MinRoleAgeMinutes, -MinTargetUptimeMinutes, -AllowedDay,
-AllowedTimeStart/-AllowedTimeEnd, -CheckOnly, -FailOnBlocked) are handed straight to
Invoke-sqmPreferredPrimaryCheck - see there for what each gate does. Only parameters you actually
pass are written into the job, so the check function's defaults keep applying.

Runs that find the preferred replica already primary do nothing and finish in a second - that is
the normal case for nearly every run.

.PARAMETER SqlInstance
Instance where the job is created (default: local computer). Run this ON that instance - the
wrapper and parameter files are written to the local module folder, exactly like the module's
other job-generating functions.

.PARAMETER SqlCredential
Optional credential for the connection that CREATES the job. It is not stored in the job: the job
step runs as the SQL Agent service account (or a proxy), which therefore needs VIEW SERVER STATE on
all replicas and ALTER AVAILABILITY GROUP on the preferred replica.

.PARAMETER AvailabilityGroup
Availability group to watch.

.PARAMETER PreferredReplica
Replica that should hold the PRIMARY role, spelled as in sys.availability_replicas.

.PARAMETER JobName
Name of the Agent job. Default: 'sqmPreferredPrimary_<AvailabilityGroup>'.

.PARAMETER IntervalMinutes
Interval of the check in minutes. Default: 30.

.PARAMETER StartTime
Start of the daily recurrence, "HH:mm". Default: '00:00' (i.e. around the clock).

.PARAMETER MaxRedoQueueMB
Passed through to Invoke-sqmPreferredPrimaryCheck.

.PARAMETER MinRoleAgeMinutes
Passed through to Invoke-sqmPreferredPrimaryCheck.

.PARAMETER MinTargetUptimeMinutes
Passed through to Invoke-sqmPreferredPrimaryCheck.

.PARAMETER AllowedDay
Passed through to Invoke-sqmPreferredPrimaryCheck.

.PARAMETER AllowedTimeStart
Passed through to Invoke-sqmPreferredPrimaryCheck.

.PARAMETER AllowedTimeEnd
Passed through to Invoke-sqmPreferredPrimaryCheck.

.PARAMETER CheckOnly
The job only reports, never fails over. Recommended for the first weeks.

.PARAMETER FailOnBlocked
The job step fails when a switch back would be needed but a safety check blocked it.

.PARAMETER Force
Replace an existing job of the same name.

.PARAMETER StartJob
Run the job once immediately after creating it.

.PARAMETER EnableException
Throw exceptions immediately instead of writing an error and returning a result object.

.EXAMPLE
New-sqmPreferredPrimaryJob -AvailabilityGroup 'AG_Prod' -PreferredReplica 'SQL01' -CheckOnly

Watchdog every 30 minutes that only reports what it would do.

.EXAMPLE
New-sqmPreferredPrimaryJob -AvailabilityGroup 'AG_Prod' -PreferredReplica 'SQL01' -IntervalMinutes 15 -AllowedDay Monday,Tuesday,Wednesday,Thursday,Friday -AllowedTimeStart '06:00' -AllowedTimeEnd '20:00' -Force

Checks every 15 minutes but only switches back during the week inside working hours, so the patch
weekend is left alone.

.NOTES
Requires dbatools, New-sqmAgentCommandJob, Invoke-sqmPreferredPrimaryCheck (same module).
Deploy the job on the preferred node: its Agent keeps running while the node is secondary, and the
check works from either role. Deploying it on several replicas is harmless (the runs are
idempotent) but produces duplicate log entries.
#>
function New-sqmPreferredPrimaryJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroup,
		[Parameter(Mandatory = $true)]
		[string]$PreferredReplica,
		[Parameter(Mandatory = $false)]
		[string]$JobName,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 1440)]
		[int]$IntervalMinutes = 30,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
		[string]$StartTime = '00:00',
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 99999)]
		[int]$MaxRedoQueueMB,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$MinRoleAgeMinutes,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10080)]
		[int]$MinTargetUptimeMinutes,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
		[string[]]$AllowedDay,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
		[string]$AllowedTimeStart,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
		[string]$AllowedTimeEnd,
		[Parameter(Mandatory = $false)]
		[switch]$CheckOnly,
		[Parameter(Mandatory = $false)]
		[switch]$FailOnBlocked,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$StartJob,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw $msg }
			Write-Error $msg
			return
		}

		if (($AllowedTimeStart -and -not $AllowedTimeEnd) -or ($AllowedTimeEnd -and -not $AllowedTimeStart))
		{
			$msg = "-AllowedTimeStart und -AllowedTimeEnd koennen nur gemeinsam verwendet werden."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw $msg }
			Write-Error $msg
			return
		}

		if (-not $JobName)
		{
			# Zeichen, die in Jobnamen erfahrungsgemaess Aerger machen, ersetzen (AG-Namen duerfen
			# z.B. Backslashes/Doppelpunkte enthalten).
			$JobName = 'sqmPreferredPrimary_' + ($AvailabilityGroup -replace '[\\/:*?"<>|\[\]]', '_')
		}
	}

	process
	{
		try
		{
			# ------------------------------------------------------------------
			# 1. Parameter fuer den Step zusammenstellen. Nur was der Aufrufer wirklich angegeben
			#    hat wird uebernommen - sonst wuerden hier die PS-Defaults (0 bzw. leer) die
			#    Defaults der Prueffunktion ueberschreiben.
			# ------------------------------------------------------------------
			$checkParams = @{
				SqlInstance	      = $SqlInstance
				AvailabilityGroup = $AvailabilityGroup
				PreferredReplica  = $PreferredReplica
			}
			foreach ($optional in 'MaxRedoQueueMB', 'MinRoleAgeMinutes', 'MinTargetUptimeMinutes', 'AllowedDay', 'AllowedTimeStart', 'AllowedTimeEnd')
			{
				if ($PSBoundParameters.ContainsKey($optional)) { $checkParams[$optional] = $PSBoundParameters[$optional] }
			}
			if ($CheckOnly) { $checkParams['CheckOnly'] = $true }
			if ($FailOnBlocked) { $checkParams['FailOnBlocked'] = $true }

			# ------------------------------------------------------------------
			# 2. Job + Step ueber den generischen Baustein anlegen (typisierte Parameteruebergabe
			#    per Clixml, kein Zusammenbauen von PowerShell-Quelltext). Der Zeitplan kommt
			#    danach separat - New-sqmAgentCommandJob kennt nur Daily/Weekly/Monthly.
			# ------------------------------------------------------------------
			$jobParams = @{
				SqlInstance  = $SqlInstance
				JobName	     = $JobName
				ScheduleType = 'None'
				Command	     = @{
					FunctionName = 'Invoke-sqmPreferredPrimaryCheck'
					StepName     = 'PreferredPrimaryCheck'
					Parameters   = $checkParams
				}
			}
			if ($SqlCredential) { $jobParams['SqlCredential'] = $SqlCredential }

			$jobResult = New-sqmAgentCommandJob @jobParams -Force:$Force -Confirm:$false -EnableException:$EnableException

			if ($jobResult -and $jobResult.Status -ne 'Success' -and -not $WhatIfPreference)
			{
				$msg = "Job '$JobName' konnte nicht angelegt werden: $($jobResult.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw $msg }
				Write-Error $msg
				return [PSCustomObject]@{
					SqlInstance		  = $SqlInstance
					JobName			  = $JobName
					AvailabilityGroup = $AvailabilityGroup
					PreferredReplica  = $PreferredReplica
					Status			  = 'Failed'
					Message			  = $msg
					Timestamp		  = Get-Date
				}
			}

			# ------------------------------------------------------------------
			# 3. Minutenzeitplan. FrequencyType Daily + SubdayType Minutes ist der einzige Weg,
			#    einen Agent-Job unter einer Stunde wiederholen zu lassen.
			# ------------------------------------------------------------------
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$scheduleName = "sch_$JobName"
			$startTimeSql = ($StartTime -replace ':', '') + '00'

			if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "Zeitplan '$scheduleName' (alle $IntervalMinutes Minuten ab $StartTime) anlegen"))
			{
				New-DbaAgentSchedule @connParams `
									 -Job $JobName `
									 -Schedule $scheduleName `
									 -FrequencyType Daily `
									 -FrequencyInterval 1 `
									 -FrequencySubdayType Minutes `
									 -FrequencySubdayInterval $IntervalMinutes `
									 -StartTime $startTimeSql `
									 -Force `
									 -ErrorAction Stop | Out-Null
			}

			$modeText = if ($CheckOnly) { 'CheckOnly (meldet nur)' } else { 'Aktiv (schwenkt zurueck)' }
			Invoke-sqmLogging -Message "Job '$JobName' auf '$SqlInstance' eingerichtet: AG '$AvailabilityGroup' -> bevorzugtes Replikat '$PreferredReplica', alle $IntervalMinutes Minuten, $modeText." -FunctionName $functionName -Level 'INFO'

			$started = $false
			if ($StartJob)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Job sofort starten"))
				{
					Start-DbaAgentJob @connParams -Job $JobName -ErrorAction Stop | Out-Null
					$started = $true
				}
			}

			return [PSCustomObject]@{
				SqlInstance		  = $SqlInstance
				JobName			  = $JobName
				AvailabilityGroup = $AvailabilityGroup
				PreferredReplica  = $PreferredReplica
				ScheduleName	  = $scheduleName
				IntervalMinutes   = $IntervalMinutes
				CheckOnly		  = [bool]$CheckOnly
				Started			  = $started
				Status			  = 'Success'
				Message			  = "Job eingerichtet ($modeText)."
				Timestamp		  = Get-Date
			}
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			Write-Error $errMsg
			return [PSCustomObject]@{
				SqlInstance		  = $SqlInstance
				JobName			  = $JobName
				AvailabilityGroup = $AvailabilityGroup
				PreferredReplica  = $PreferredReplica
				Status			  = 'Failed'
				Message			  = $errMsg
				Timestamp		  = Get-Date
			}
		}
	}
}
