<#
.SYNOPSIS
Creates a SQL Server Agent job that runs Repair-Job.ps1 (AutoRepair).

.PARAMETER SqlInstance
Target SQL instance (default: computer name).

.PARAMETER JobName
Name of the Agent job. Default: 'sqmAlwaysOnRepair'.

.PARAMETER Force
Overwrites an existing job.

.EXAMPLE
New-sqmAlwaysOnRepairJob -SqlInstance "SQL01"
#>
function New-sqmAlwaysOnRepairJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmAlwaysOnRepair',
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
			-Description "AutoRepair: Repariert AlwaysOn-Datenbanken" -ErrorAction Stop

		# Create CmdExec job step (calls Repair-Job.ps1)
		$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
		$repairScriptPath = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\Repair-Job.ps1'
		$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$repairScriptPath`""

		$jobStep = New-DbaAgentJobStep -SqlInstance $SqlInstance -Job $JobName `
			-StepName "RunRepair" -Subsystem 'CmdExec' -Command $command -ErrorAction Stop

		# Add hourly schedule
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
    @freq_interval          = 1;
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