<#
.SYNOPSIS
Creates an on-demand SQL Server Agent job that runs Invoke-sqmRestoreDatabase with the given
parameters baked in.

.DESCRIPTION
Generates a wrapper script (under the module's jobs folder) that imports sqmSQLTool and calls
Invoke-sqmRestoreDatabase with the restore parameters you specify, then creates a SQL Agent job
with a single CmdExec step that runs that wrapper. The job is created WITHOUT a schedule - a
restore is an on-demand operation, not recurring - so it is meant to be started manually
(Start-DbaAgentJob) or via -StartJob.

Auth model (matching the other sqmSQLTool job functions, e.g. New-sqmAlwaysOnRepairJob): the
generated wrapper does NOT embed any SQL credential. When the job runs, powershell.exe executes
as the SQL Agent service account and Invoke-sqmRestoreDatabase connects to the target instance via
that account's Windows identity. The Agent service account therefore needs sysadmin rights on the
target instance and, for an AlwaysOn database, on all replicas - the same requirement
Invoke-sqmRestoreDatabase already documents.

Because the wrapper script is written to the LOCAL module jobs folder
(C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\), run this function ON the target
instance (where sqmSQLTool and dbatools are installed), just like the module's other
job-generating functions.

The generated job step uses -Confirm:$false and -EnableException, so any failure inside
Invoke-sqmRestoreDatabase makes the job step (and therefore the Agent job) fail visibly, rather
than being swallowed into a returned result object nobody inspects.

.PARAMETER SqlInstance
Target SQL Server instance where the job is created and runs (default: current computer name).
This value is also baked into the wrapper as Invoke-sqmRestoreDatabase's -SqlInstance.

.PARAMETER DatabaseName
Name of the database to restore (as it appears in the backup file). Mandatory.

.PARAMETER BackupFile
Path to the full backup file (.bak), or an array for striped backups. As the job runs on the
target instance, this path must be valid/readable from that instance (local path or a share the
SQL service account can read). Use -BackupFiles for a Full+Diff+Logs sequence instead.

.PARAMETER BackupFiles
Array of backup files in order (Full, then Diff, then Logs). Alternative to -BackupFile.

.PARAMETER NewDatabaseName
Optional: new name for the database after the restore.

.PARAMETER NewDatabaseFilePath
Optional: target directory for the database data files.

.PARAMETER NewLogFilePath
Optional: target directory for the log file.

.PARAMETER BackupBeforeRestore
Optional: back up the existing database before the restore (forwarded to Invoke-sqmRestoreDatabase).

.PARAMETER NoUserExport
Optional: skip the database-user export (forwarded).

.PARAMETER KeepAlwaysOn
Optional: forwarded to Invoke-sqmRestoreDatabase (see its help - opts out of AG auto-join /
aborts for an AG member).

.PARAMETER AvailabilityGroupName
Optional: forwarded - forces AG-aware handling / selects the AG explicitly.

.PARAMETER WithNoRecovery
Optional: forwarded - restore leaves the database in RESTORING state.

.PARAMETER ContinueWithNoRecovery
Optional: forwarded - the last restore is also performed with NORECOVERY.

.PARAMETER ForceSingleUser
Optional: forwarded - force single-user mode before the restore.

.PARAMETER NoRejoinAvailabilityGroup
Optional: forwarded - do the AG detection/cleanup but skip the actual (re)join.

.PARAMETER JobName
Name of the Agent job. Default: "sqmRestore_<DatabaseName>".

.PARAMETER StepName
Name of the single job step. Default: "RunRestore".

.PARAMETER Force
Overwrite an existing job of the same name (and its generated wrapper).

.PARAMETER StartJob
Start the job immediately after creating it (Start-DbaAgentJob).

.PARAMETER EnableException
Throw exceptions immediately instead of logging and returning a result object.

.EXAMPLE
# Create an on-demand restore job for AdventureWorks and leave it for the DBA to start later.
New-sqmRestoreDatabaseJob -SqlInstance "SQL01" -BackupFile "D:\Backup\AdventureWorks.bak" -DatabaseName "AdventureWorks"

.EXAMPLE
# Create the job and run it right away (Full + Diff + Logs sequence).
$seq = @("D:\Backup\App_Full.bak","D:\Backup\App_Diff.bak","D:\Backup\App_Log1.trn")
New-sqmRestoreDatabaseJob -SqlInstance "SQL01" -BackupFiles $seq -DatabaseName "App" -StartJob

.NOTES
Requires dbatools, Invoke-sqmLogging, and Invoke-sqmRestoreDatabase (same module).
Run on the target instance so the generated wrapper lands where the Agent job can find it.
#>
function New-sqmRestoreDatabaseJob
{
	[CmdletBinding(DefaultParameterSetName = 'SingleFile', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,

		[Parameter(Mandatory = $true, ParameterSetName = 'SingleFile')]
		[string[]]$BackupFile,

		[Parameter(Mandatory = $true, ParameterSetName = 'Sequence')]
		[string[]]$BackupFiles,

		[Parameter(Mandatory = $false)]
		[string]$NewDatabaseName,

		[Parameter(Mandatory = $false)]
		[string]$NewDatabaseFilePath,

		[Parameter(Mandatory = $false)]
		[string]$NewLogFilePath,

		[Parameter(Mandatory = $false)]
		[switch]$BackupBeforeRestore,

		[Parameter(Mandatory = $false)]
		[switch]$NoUserExport,

		[Parameter(Mandatory = $false)]
		[switch]$KeepAlwaysOn,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[switch]$WithNoRecovery,

		[Parameter(Mandatory = $false)]
		[switch]$ContinueWithNoRecovery,

		[Parameter(Mandatory = $false)]
		[switch]$ForceSingleUser,

		[Parameter(Mandatory = $false)]
		[switch]$NoRejoinAvailabilityGroup,

		[Parameter(Mandatory = $false)]
		[string]$JobName,

		[Parameter(Mandatory = $false)]
		[string]$StepName = 'RunRestore',

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
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		if ([string]::IsNullOrWhiteSpace($JobName))
		{
			$JobName = "sqmRestore_$DatabaseName"
		}

		# Backup-Datei(en) je nach Parametersatz
		$isSequence = ($PSCmdlet.ParameterSetName -eq 'Sequence')
		$backupList = if ($isSequence) { $BackupFiles } else { $BackupFile }
	}

	process
	{
		try
		{
			# ------------------------------------------------------------------
			# 1. Log-/Output-Verzeichnis vorbereiten (wie die uebrigen Job-Funktionen):
			#    das Agent-Dienstkonto braucht Schreibrecht, damit Invoke-sqmLogging
			#    aus dem Job heraus schreiben kann.
			# ------------------------------------------------------------------
			$outputPath = "C:\System\WinSrvLog\MSSQL"
			if (-not (Test-Path $outputPath))
			{
				New-Item -ItemType Directory -Path $outputPath -Force -ErrorAction SilentlyContinue | Out-Null
			}
			@('NT SERVICE\MSSQLSERVER', 'NT SERVICE\SQLSERVERAGENT') | ForEach-Object {
				$null = icacls $outputPath /grant "$_`:F" /T /C 2>&1
			}

			# ------------------------------------------------------------------
			# 2. jobs-Verzeichnis des Moduls sicherstellen
			# ------------------------------------------------------------------
			$modulePath = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool'
			$jobsDir = Join-Path $modulePath 'jobs'
			if (-not (Test-Path $jobsDir))
			{
				New-Item -ItemType Directory -Path $jobsDir -Force -ErrorAction Stop | Out-Null
			}

			# ------------------------------------------------------------------
			# 3. Parameterzeile fuer den Invoke-sqmRestoreDatabase-Aufruf bauen
			#    (nur gesetzte/relevante Parameter werden aufgenommen). Strings werden
			#    fuer die Einbettung in ein Single-Quote-PowerShell-Literal escaped
			#    (' -> '') - so sind auch Pfade mit Sonderzeichen sicher.
			# ------------------------------------------------------------------
			function _q { param([string]$s) "'" + ($s -replace "'", "''") + "'" }

			$argParts = [System.Collections.Generic.List[string]]::new()
			$argParts.Add("-SqlInstance $(_q $SqlInstance)")
			$argParts.Add("-DatabaseName $(_q $DatabaseName)")

			if ($isSequence)
			{
				$quoted = ($BackupFiles | ForEach-Object { _q $_ }) -join ', '
				$argParts.Add("-BackupFiles @($quoted)")
			}
			else
			{
				$quoted = ($BackupFile | ForEach-Object { _q $_ }) -join ', '
				$argParts.Add("-BackupFile @($quoted)")
			}

			if ($NewDatabaseName)     { $argParts.Add("-NewDatabaseName $(_q $NewDatabaseName)") }
			if ($NewDatabaseFilePath) { $argParts.Add("-NewDatabaseFilePath $(_q $NewDatabaseFilePath)") }
			if ($NewLogFilePath)      { $argParts.Add("-NewLogFilePath $(_q $NewLogFilePath)") }
			if ($AvailabilityGroupName) { $argParts.Add("-AvailabilityGroupName $(_q $AvailabilityGroupName)") }

			if ($BackupBeforeRestore)       { $argParts.Add('-BackupBeforeRestore') }
			if ($NoUserExport)              { $argParts.Add('-NoUserExport') }
			if ($KeepAlwaysOn)              { $argParts.Add('-KeepAlwaysOn') }
			if ($WithNoRecovery)            { $argParts.Add('-WithNoRecovery') }
			if ($ContinueWithNoRecovery)    { $argParts.Add('-ContinueWithNoRecovery') }
			if ($ForceSingleUser)           { $argParts.Add('-ForceSingleUser') }
			if ($NoRejoinAvailabilityGroup) { $argParts.Add('-NoRejoinAvailabilityGroup') }

			# -Confirm:$false + -EnableException: der Job soll unbeaufsichtigt laufen und bei
			# einem Fehler tatsaechlich rot werden (Step schlaegt fehl), nicht still ein
			# Fehlerobjekt zurueckgeben.
			$argParts.Add('-Confirm:$false')
			$argParts.Add('-EnableException')

			$argLine = $argParts -join ' '

			# ------------------------------------------------------------------
			# 4. Wrapper-Skript erzeugen (analog Repair-Job.ps1 / Sync-Job.ps1,
			#    aber mit den konkreten Restore-Parametern)
			# ------------------------------------------------------------------
			$wrapper = @"
# Auto-generiert von New-sqmRestoreDatabaseJob am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Job: $JobName  |  Datenbank: $DatabaseName
`$ErrorActionPreference = 'Stop'

Import-Module sqmSQLTool -Force

Invoke-sqmRestoreDatabase $argLine

exit 0
"@

			$safeDb = $DatabaseName -replace '[\\/:*?"<>|]', '_'
			$wrapperPath = Join-Path $jobsDir "Restore-Job_$safeDb.ps1"

			if ($PSCmdlet.ShouldProcess($wrapperPath, "Wrapper-Skript schreiben"))
			{
				# UTF-8 MIT BOM (Windows PowerShell 5.1 liest das Skript sonst evtl. falsch)
				[System.IO.File]::WriteAllText($wrapperPath, $wrapper, (New-Object System.Text.UTF8Encoding($true)))
				Invoke-sqmLogging -Message "Wrapper-Skript geschrieben: $wrapperPath" -FunctionName $functionName -Level "INFO"
			}

			# ------------------------------------------------------------------
			# 5. Vorhandenen Job pruefen / (bei -Force) entfernen
			# ------------------------------------------------------------------
			$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction SilentlyContinue
			if ($existingJob -and -not $Force)
			{
				throw "Job '$JobName' existiert bereits. -Force zum Ueberschreiben."
			}
			if ($existingJob -and $Force)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Vorhandenen Job entfernen (-Force)"))
				{
					Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -Confirm:$false -ErrorAction Stop
					Invoke-sqmLogging -Message "Vorhandener Job '$JobName' entfernt (-Force)." -FunctionName $functionName -Level "INFO"
				}
			}

			# ------------------------------------------------------------------
			# 6. Job + CmdExec-Step anlegen (KEIN Schedule - On-Demand-Restore)
			# ------------------------------------------------------------------
			$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
			$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`""

			if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "SQL-Agent-Job (On-Demand) fuer Restore von '$DatabaseName' erstellen"))
			{
				$null = New-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName `
					-Description "On-Demand-Restore von '$DatabaseName' via Invoke-sqmRestoreDatabase (New-sqmRestoreDatabaseJob)" `
					-ErrorAction Stop

				$null = New-DbaAgentJobStep -SqlInstance $SqlInstance -Job $JobName `
					-StepName $StepName -Subsystem 'CmdExec' -Command $command `
					-OnSuccessAction QuitWithSuccess -OnFailAction QuitWithFailure -ErrorAction Stop

				Invoke-sqmLogging -Message "Job '$JobName' auf '$SqlInstance' erstellt (On-Demand, kein Schedule)." -FunctionName $functionName -Level "INFO"
			}

			# ------------------------------------------------------------------
			# 7. Optional: Job sofort starten
			# ------------------------------------------------------------------
			$started = $false
			if ($StartJob)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Job sofort starten"))
				{
					Start-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction Stop | Out-Null
					$started = $true
					Invoke-sqmLogging -Message "Job '$JobName' wurde gestartet." -FunctionName $functionName -Level "INFO"
				}
			}

			return [PSCustomObject]@{
				SqlInstance = $SqlInstance
				JobName     = $JobName
				StepName    = $StepName
				DatabaseName = $DatabaseName
				WrapperPath = $wrapperPath
				Started     = $started
				Status      = "Success"
				Message     = "On-Demand-Restore-Job erstellt$(if ($started) { ' und gestartet' })."
				Timestamp   = Get-Date
			}
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return [PSCustomObject]@{
				SqlInstance = $SqlInstance
				JobName     = $JobName
				Status      = "Failed"
				Message     = $errMsg
				Timestamp   = Get-Date
			}
		}
	}
}
