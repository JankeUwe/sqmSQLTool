<#
.SYNOPSIS
Creates the SQL Agent job for the automatic AlwaysOn login sync (standard job AgLoginSync).

.DESCRIPTION
Shortcut for Install-sqmStandardJob -Name AgLoginSync: Sync-sqmLoginsToAlwaysOn -Force:$false,
daily at 02:00, PrimaryOnly. Install it on every AG replica; only the current primary works,
after a failover the new primary takes over.

Until v1.9.167.0 this function created a step that called jobs\Sync-Job.ps1 without any
parameters. Existing jobs keep working; recreate them with -Force to switch to the new step.

.PARAMETER SqlInstance
Target SQL instance (default: computer name). Run this ON that server.

.PARAMETER AvailabilityGroupName
AG to sync. Without it Sync-sqmLoginsToAlwaysOn uses the first AG on the instance.

.PARAMETER JobName
Name of the Agent job. Default: 'sqmAutoLoginSync'.

.PARAMETER AuditAdOrphans
Additionally reports Windows logins without an AD account after each run (event 9003, detection
only, nothing is deleted).

.PARAMETER BackupRetentionDays
Retention for login backups and audit reports in days (Sync default: 7, 0 = keep all).

.PARAMETER Force
Overwrites an existing job.

.EXAMPLE
New-sqmAutoLoginSyncJob -SqlInstance "SQL01"

.EXAMPLE
New-sqmAutoLoginSyncJob -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -AuditAdOrphans -Force
#>
function New-sqmAutoLoginSyncJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmAutoLoginSync',
		[Parameter(Mandatory = $false)]
		[switch]$AuditAdOrphans,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 3650)]
		[int]$BackupRetentionDays,
		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	process
	{
		$syncParams = @{}
		if ($AuditAdOrphans) { $syncParams['AuditAdOrphans'] = $true }
		if ($PSBoundParameters.ContainsKey('BackupRetentionDays')) { $syncParams['BackupRetentionDays'] = $BackupRetentionDays }

		$installParams = @{
			Name        = 'AgLoginSync'
			SqlInstance = $SqlInstance
			JobName     = $JobName
			Parameters  = $syncParams
			Force       = $Force
		}
		if ($AvailabilityGroupName) { $installParams['AvailabilityGroupName'] = $AvailabilityGroupName }

		Install-sqmStandardJob @installParams -WhatIf:$WhatIfPreference -Confirm:$false
	}
}
