<#
.SYNOPSIS
Creates a SQL Agent job that runs Sync-Job.ps1 (AutoSync).

.PARAMETER SqlInstance
Target SQL instance (default: computer name).

.PARAMETER JobName
Name of the Agent job. Default: 'sqmAutoLoginSync'.

.PARAMETER Force
Overwrites an existing job.

.EXAMPLE
New-sqmAutoLoginSyncJob -SqlInstance "SQL01"
#>
function New-sqmAutoLoginSyncJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmAutoLoginSync',
		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	process
	{
		# Check if job exists
		$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction SilentlyContinue
		if ($existingJob -and -not $Force)
		{
			throw "Job '$JobName' existiert bereits. -Force zum Ueberschreiben."
		}
		if ($existingJob -and $Force)
		{
			Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -Confirm:$false -ErrorAction Stop
		}

		# Create job
		$job = New-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName `
			-Description "AutoSync: Synchronisiert Logins ueber AlwaysOn-Replicas" -ErrorAction Stop

		# Create CmdExec job step (calls Sync-Job.ps1)
		$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
		$syncScriptPath = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\Sync-Job.ps1'
		$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$syncScriptPath`""

		$jobStep = New-DbaAgentJobStep -SqlInstance $SqlInstance -Job $JobName `
			-StepName "RunSync" -Subsystem 'CmdExec' -Command $command -ErrorAction Stop

		# Add daily schedule (2:00 AM)
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
    @active_start_time      = 020000;
EXEC msdb.dbo.sp_attach_schedule @job_name = N'$JobName', @schedule_name = N'$schedName';
"@
		$null = Invoke-DbaQuery -SqlInstance $SqlInstance -Database msdb -Query $schedSql -ErrorAction Stop

		[PSCustomObject]@{
			SqlInstance = $SqlInstance
			JobName     = $JobName
			Status      = "Success"
			Message     = "Job created"
			Timestamp   = Get-Date
		}
	}
}
