<#
.SYNOPSIS
Creates a SQL Server Agent job that regularly runs Repair-sqmAlwaysOnDatabases.

.DESCRIPTION
The job is created on the specified SQL instance and uses the PowerShell subsystem
to call the Repair-sqmAlwaysOnDatabases function. The job can run on a schedule (e.g. hourly)
or be started manually on demand.

Prerequisite: The functions (Repair-sqmAlwaysOnDatabases, Invoke-sqmLogging, Invoke-sqmSqlAlwaysOnAutoseeding)
and the dbatools module must be available on the SQL Server (e.g. in a module path or as a script file).

.PARAMETER SqlInstance
Target SQL instance (default: computer name).

.PARAMETER SqlCredential
Credentials for the SQL instance (for job creation).

.PARAMETER JobName
Name of the Agent job to create. Default: 'sqmAlwaysOnRepair'.

.PARAMETER Schedule
Schedule in the format 'FREQ=HOURLY;INTERVAL=1' (default: hourly). Can also be 'FREQ=DAILY;INTERVAL=1'.
Leave empty for no schedule (manual only).

.PARAMETER StartTime
Time for the schedule (e.g. '00:00:00'). Optional.

.PARAMETER Force
Overwrites an existing job with the same name.

.PARAMETER EnableException
Propagate exceptions immediately.

.EXAMPLE
# Creates an hourly job
New-sqmAlwaysOnRepairJob

.EXAMPLE
# Daily job at 2 AM
New-sqmAlwaysOnRepairJob -Schedule "FREQ=DAILY;INTERVAL=1" -StartTime "02:00:00"

.NOTES
The PowerShell code in the job step automatically loads the dbatools module and all required functions.
It is assumed that the functions are already available globally in the session or are loaded as a script.
#>
function New-sqmAlwaysOnRepairJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmAlwaysOnRepair',
		[Parameter(Mandatory = $false)]
		[string]$Schedule = 'FREQ=HOURLY;INTERVAL=1',
		[Parameter(Mandatory = $false)]
		[string]$StartTime,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance, Job: $JobName" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			# Pruefen, ob Job bereits existiert
			$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Job $JobName -ErrorAction SilentlyContinue
			if ($existingJob -and -not $Force)
			{
				throw "Job '$JobName' existiert bereits. Verwenden Sie -Force zum ueberschreiben."
			}
			elseif ($existingJob -and $Force)
			{
				Invoke-sqmLogging -Message "Loesche vorhandenen Job '$JobName'." -FunctionName $functionName -Level "INFO"
				Remove-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Job $JobName -Confirm:$false -ErrorAction Stop
			}
			
			# Resolve SqlInstance if not provided
			if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
			{
				$SqlInstance = $env:COMPUTERNAME
			}

			# Check if job exists
			$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Job $JobName -ErrorAction SilentlyContinue
			if ($existingJob -and -not $Force)
			{
				throw "Job '$JobName' existiert bereits. Verwenden Sie -Force zum Ueberschreiben."
			}
			elseif ($existingJob -and $Force)
			{
				Invoke-sqmLogging -Message "Loesche vorhandenen Job '$JobName'." -FunctionName $functionName -Level "INFO"
				Remove-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Job $JobName -Confirm:$false -ErrorAction Stop
			}

			if (-not $PSCmdlet.ShouldProcess($JobName, "Erstelle neuen SQL Agent Job"))
			{
				Invoke-sqmLogging -Message "WhatIf: Job '$JobName' würde erstellt" -FunctionName $functionName -Level 'VERBOSE'
				return [PSCustomObject]@{
					SqlInstance = $SqlInstance
					JobName     = $JobName
					Status      = 'WhatIf'
					Message     = 'Job would be created'
					Timestamp   = Get-Date
				}
			}

			# Create job
			$job = New-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Job $JobName `
				-Description "Repariert regelmaessig AlwaysOn-Datenbanken und heilt autoseeding-Fehler." -ErrorAction Stop
			Invoke-sqmLogging -Message "Job '$JobName' erstellt" -FunctionName $functionName -Level 'INFO'

			# Build parameters for wrapper script
			$wrapperParams = @{}  # Repair-sqmAlwaysOnDatabases hat keine zusaetzlichen Parameter noetig

			# Create CmdExec job step (no PowerShell Proxy needed!)
			$stepParams = @{
				SqlInstance    = $SqlInstance
				JobName        = $JobName
				StepName       = "RunRepair_Step1"
				FunctionName   = 'Repair-sqmAlwaysOnDatabases'
				Parameters     = $wrapperParams
				ErrorAction    = 'Stop'
			}
			$jobStepResult = _CreateCmdExecJobStep @stepParams
			$jobStep = $jobStepResult.JobStep
			Invoke-sqmLogging -Message "Job-Schritt (CmdExec) hinzugefuegt: RunRepair_Step1" -FunctionName $functionName -Level 'INFO'

			# Add schedule if provided
			if ($Schedule)
			{
				# Parse Schedule string (e.g. 'FREQ=HOURLY;INTERVAL=1')
				# For now, use dbatools New-DbaAgentSchedule which is simpler
				$schedName = "sch_$JobName"
				$schedSql = @"
DECLARE @sid INT;
WHILE EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'$schedName')
BEGIN
    SELECT TOP (1) @sid = schedule_id FROM msdb.dbo.sysschedules WHERE name = N'$schedName';
    EXEC msdb.dbo.sp_delete_schedule @schedule_id = @sid, @force_delete = 1;
END
EXEC msdb.dbo.sp_add_schedule
    @schedule_name          = N'$schedName',
    @enabled                = 1,
    @freq_type              = 4,
    @freq_interval          = 1,
    @active_start_time      = 000000;
EXEC msdb.dbo.sp_attach_schedule @job_name = N'$JobName', @schedule_name = N'$schedName';
"@
				$null = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database msdb -Query $schedSql -ErrorAction Stop
				Invoke-sqmLogging -Message "Zeitplan hinzugefuegt: $Schedule" -FunctionName $functionName -Level 'INFO'
			}

			# Return result
			Invoke-sqmLogging -Message "Job '$JobName' erfolgreich erstellt und aktiviert." -FunctionName $functionName -Level "INFO"

			[PSCustomObject]@{
				SqlInstance = $SqlInstance
				JobName     = $JobName
				Status      = "Success"
				Schedule    = $Schedule
				Message     = "Job created successfully. Manual start: Start-DbaAgentJob -SqlInstance $SqlInstance -Job '$JobName'"
				Timestamp   = Get-Date
			}
		}
		catch
		{
			$errMsg = "Fehler beim Erstellen des Jobs: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
	}
}