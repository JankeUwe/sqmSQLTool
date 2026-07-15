<#
.SYNOPSIS
Creates a scheduled SQL Server Agent job that runs Invoke-sqmRestoreTest and produces the recurring
restore-test evidence.

.DESCRIPTION
Generates a wrapper script (under the module's jobs folder) that imports sqmSQLTool and calls
Invoke-sqmRestoreTest with the parameters you specify, then creates a SQL Agent job with a single
CmdExec step running that wrapper - together with a schedule.

Unlike New-sqmRestoreDatabaseJob (an on-demand restore, deliberately without a schedule), a restore
test is a recurring obligation, so this job IS scheduled: monthly by default, which matches the
usual audit cadence. Use -ScheduleType Weekly/Daily for a tighter interval or -NoSchedule to create
the job for manual starts only.

Cleanup: when run as a job the test database is dropped after the measurement (Invoke-sqmRestoreTest
-RemoveTestDatabase). An unattended, recurring job would otherwise pile up a full-size copy of the
database on every run until the volume is full. Use -KeepTestDatabase if the copy must survive for
manual inspection - only sensible with a long schedule interval and enough free space.

The evidence (TXT + HTML) is written to the RestoreTest subfolder of the module's output path and
kept according to the retention rule (module config "RestoreTestRetentionMonths", 12 months by
default) - see Invoke-sqmRestoreTest -RetentionMonths.

Auth model (matching the other sqmSQLTool job functions): the generated wrapper does NOT embed any
SQL credential. When the job runs, powershell.exe executes as the SQL Agent service account and
Invoke-sqmRestoreTest connects via that account's Windows identity. The Agent service account
therefore needs sufficient rights on the target instance (restore + drop database) and read access
to the backup files.

Because the wrapper script is written to the LOCAL module jobs folder
(C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\), run this function ON the target
instance, just like the module's other job-generating functions.

The generated job step uses -Confirm:$false and -EnableException, so any failure inside
Invoke-sqmRestoreTest makes the job step (and therefore the Agent job) fail visibly. A restore test
that silently does nothing is worse than none at all: it would produce no evidence while everyone
assumes the obligation is covered.

.PARAMETER SqlInstance
Target SQL Server instance where the job is created and runs. Default: current computer name.

.PARAMETER SqlCredential
Optional credentials used to CREATE the job, step and schedule on the target instance. This is only
for setting the job up from a workstation; it is deliberately NOT embedded into the generated
wrapper. The job itself always runs under the SQL Agent service account's Windows identity - baking
a password into a script on disk would be the wrong trade.

.PARAMETER DatabaseName
Name of the source database as it appears in the backup. Mandatory.

.PARAMETER BackupFile
Path(s) to the backup file(s). As the job runs on the target instance, these must be readable from
there (local path or a share the Agent service account can read). Accepts a single .bak, a striped
set, or a Full+Diff+Log chain.

.PARAMETER TestDatabaseName
Optional: fixed name for the test database. Must start with "RestoreTest_". Omit it to let each run
generate its own timestamped name - recommended for a recurring job, since a fixed name would
require -AllowReplaceExistingTestDatabase on every run after the first.

.PARAMETER DataFilePath
Optional: target directory for the data files of the test database.

.PARAMETER LogFilePath
Optional: target directory for the log file of the test database.

.PARAMETER KeepTestDatabase
Optional: do NOT drop the test database after the run. By default a job run cleans up its copy.

.PARAMETER AllowReplaceExistingTestDatabase
Optional: forwarded to Invoke-sqmRestoreTest. Only needed together with a fixed -TestDatabaseName.

.PARAMETER RetentionMonths
Optional: how many months the evidence is kept. Omit to use the module configuration
("RestoreTestRetentionMonths", default 12). 0 keeps evidence forever.

.PARAMETER OutputPath
Optional: directory for the evidence. Default: the RestoreTest subfolder of the module output path.

.PARAMETER ScheduleType
Schedule frequency: Monthly (default), Weekly or Daily.

.PARAMETER ScheduleTime
Start time as "HH:mm". Default: "02:00".

.PARAMETER ScheduleDayOfMonth
Day of month for -ScheduleType Monthly (1-28). Default: 1. Capped at 28 so the schedule also fires
in February.

.PARAMETER ScheduleDays
Weekdays for -ScheduleType Weekly. Default: Sunday.

.PARAMETER NoSchedule
Create the job without a schedule (manual starts only).

.PARAMETER JobName
Optional: name of the Agent job. Default: "sqmRestoreTest_<DatabaseName>".

.PARAMETER StepName
Optional: name of the job step. Default: "RunRestoreTest".

.PARAMETER Force
Overwrite an existing job of the same name.

.PARAMETER StartJob
Start the job immediately after creation (useful to produce the first evidence right away).

.PARAMETER EnableException
Throw exceptions instead of returning a failure result object.

.EXAMPLE
# Monthly restore test on the 1st at 02:00, copy is cleaned up, evidence kept for 12 months
New-sqmRestoreTestJob -SqlInstance "SQL01" -DatabaseName "Kunde" -BackupFile "D:\Backup\Kunde_Full.bak"

.EXAMPLE
# Weekly on Sunday 23:00, files onto a dedicated test volume, run once right away
New-sqmRestoreTestJob -SqlInstance "SQL01" -DatabaseName "Kunde" -BackupFile "D:\Backup\Kunde_Full.bak" `
    -ScheduleType Weekly -ScheduleDays 'Sunday' -ScheduleTime "23:00" `
    -DataFilePath "T:\RestoreTest" -LogFilePath "T:\RestoreTest" -StartJob

.EXAMPLE
# Evidence kept for 3 years (audit requirement), monthly on the 15th
New-sqmRestoreTestJob -SqlInstance "SQL01" -DatabaseName "Kunde" -BackupFile "D:\Backup\Kunde_Full.bak" `
    -ScheduleDayOfMonth 15 -RetentionMonths 36

.NOTES
Requires dbatools, Invoke-sqmLogging and Invoke-sqmRestoreTest (same module).
Run on the target instance so the generated wrapper lands where the Agent job can find it.
#>
function New-sqmRestoreTestJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,

		[Parameter(Mandatory = $true)]
		[string[]]$BackupFile,

		[Parameter(Mandatory = $false)]
		[string]$TestDatabaseName,

		[Parameter(Mandatory = $false)]
		[string]$DataFilePath,

		[Parameter(Mandatory = $false)]
		[string]$LogFilePath,

		[Parameter(Mandatory = $false)]
		[switch]$KeepTestDatabase,

		[Parameter(Mandatory = $false)]
		[switch]$AllowReplaceExistingTestDatabase,

		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1200)]
		[int]$RetentionMonths = -1,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Monthly', 'Weekly', 'Daily')]
		[string]$ScheduleType = 'Monthly',

		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{1,2}:\d{2}$')]
		[string]$ScheduleTime = '02:00',

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 28)]
		[int]$ScheduleDayOfMonth = 1,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
		[string[]]$ScheduleDays = @('Sunday'),

		[Parameter(Mandatory = $false)]
		[switch]$NoSchedule,

		[Parameter(Mandatory = $false)]
		[string]$JobName,

		[Parameter(Mandatory = $false)]
		[string]$StepName = 'RunRestoreTest',

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
			$JobName = "sqmRestoreTest_$DatabaseName"
		}

		# Verbindungsparameter fuer alle Agent-Aufrufe. Nur fuer das ANLEGEN des Jobs -
		# das Wrapper-Skript bekommt bewusst keine Credentials (siehe .PARAMETER SqlCredential).
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		# Fruehe Pruefung des Zielnamens: dieselbe Regel wie in Invoke-sqmRestoreTest, aber schon
		# beim Anlegen des Jobs. Ein unzulaessiger Name soll nicht erst Monate spaeter beim
		# ersten geplanten Lauf auffallen.
		if ($TestDatabaseName -and -not $TestDatabaseName.StartsWith('RestoreTest_', [System.StringComparison]::OrdinalIgnoreCase))
		{
			$errMsg = "TestDatabaseName '$TestDatabaseName' beginnt nicht mit 'RestoreTest_'. " +
					  "Invoke-sqmRestoreTest wuerde den Lauf ablehnen."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
	}

	process
	{
		try
		{
			# ------------------------------------------------------------------
			# 1. Log-/Output-Verzeichnis vorbereiten (wie die uebrigen Job-Funktionen):
			#    das Agent-Dienstkonto braucht Schreibrecht, damit Invoke-sqmLogging und
			#    der Nachweis aus dem Job heraus geschrieben werden koennen.
			# ------------------------------------------------------------------
			$logPath = Get-sqmDefaultOutputPath
			$evidencePath = if ($OutputPath) { $OutputPath } else { Join-Path $logPath 'RestoreTest' }

			foreach ($dir in @($logPath, $evidencePath))
			{
				if (-not (Test-Path $dir))
				{
					New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
				}
			}
			@('NT SERVICE\MSSQLSERVER', 'NT SERVICE\SQLSERVERAGENT') | ForEach-Object {
				$null = icacls $logPath /grant "$_`:F" /T /C 2>&1
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
			# 3. Parameterzeile fuer den Invoke-sqmRestoreTest-Aufruf bauen.
			#    Strings werden fuer die Einbettung in ein Single-Quote-PowerShell-Literal
			#    escaped (' -> '') - so sind auch Pfade mit Sonderzeichen sicher.
			# ------------------------------------------------------------------
			function _q { param([string]$s) "'" + ($s -replace "'", "''") + "'" }

			$argParts = [System.Collections.Generic.List[string]]::new()
			$argParts.Add("-SqlInstance $(_q $SqlInstance)")
			$argParts.Add("-DatabaseName $(_q $DatabaseName)")

			$quoted = ($BackupFile | ForEach-Object { _q $_ }) -join ', '
			$argParts.Add("-BackupFile @($quoted)")

			if ($TestDatabaseName) { $argParts.Add("-TestDatabaseName $(_q $TestDatabaseName)") }
			if ($DataFilePath)     { $argParts.Add("-DataFilePath $(_q $DataFilePath)") }
			if ($LogFilePath)      { $argParts.Add("-LogFilePath $(_q $LogFilePath)") }
			if ($OutputPath)       { $argParts.Add("-OutputPath $(_q $OutputPath)") }

			# Aufraeumen der Kopie ist im Job der Normalfall - siehe DESCRIPTION.
			if (-not $KeepTestDatabase) { $argParts.Add('-RemoveTestDatabase') }
			if ($AllowReplaceExistingTestDatabase) { $argParts.Add('-AllowReplaceExistingTestDatabase') }

			# Nur weitergeben wenn ausdruecklich gesetzt - sonst zieht die Modulkonfiguration.
			if ($PSBoundParameters.ContainsKey('RetentionMonths')) { $argParts.Add("-RetentionMonths $RetentionMonths") }

			# -NoOpen: im Job darf kein Browser/Editor aufgehen (unbeaufsichtigter Lauf unter
			# dem Agent-Dienstkonto - Start-Process haette dort keine Sitzung).
			$argParts.Add('-NoOpen')
			$argParts.Add('-Confirm:$false')
			$argParts.Add('-EnableException')

			$argLine = $argParts -join ' '

			# ------------------------------------------------------------------
			# 4. Wrapper-Skript erzeugen
			# ------------------------------------------------------------------
			$cleanupNote = if ($KeepTestDatabase) { 'Testkopie bleibt erhalten' } else { 'Testkopie wird nach der Messung entfernt' }
			$wrapper = @"
# Auto-generiert von New-sqmRestoreTestJob am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Job: $JobName  |  Datenbank: $DatabaseName
# $cleanupNote. Nachweis: $evidencePath
`$ErrorActionPreference = 'Stop'

Import-Module sqmSQLTool -Force

Invoke-sqmRestoreTest $argLine

exit 0
"@

			$safeDb = $DatabaseName -replace '[\\/:*?"<>|]', '_'
			$wrapperPath = Join-Path $jobsDir "RestoreTest-Job_$safeDb.ps1"

			if ($PSCmdlet.ShouldProcess($wrapperPath, "Wrapper-Skript schreiben"))
			{
				# UTF-8 MIT BOM (Windows PowerShell 5.1 liest das Skript sonst evtl. falsch)
				[System.IO.File]::WriteAllText($wrapperPath, $wrapper, (New-Object System.Text.UTF8Encoding($true)))
				Invoke-sqmLogging -Message "Wrapper-Skript geschrieben: $wrapperPath" -FunctionName $functionName -Level "INFO"
			}

			# ------------------------------------------------------------------
			# 5. Vorhandenen Job pruefen / (bei -Force) entfernen
			# ------------------------------------------------------------------
			$existingJob = Get-DbaAgentJob @connParams -Job $JobName -ErrorAction SilentlyContinue
			if ($existingJob -and -not $Force)
			{
				throw "Job '$JobName' existiert bereits. -Force zum Ueberschreiben."
			}
			if ($existingJob -and $Force)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Vorhandenen Job entfernen (-Force)"))
				{
					Remove-DbaAgentJob @connParams -Job $JobName -Confirm:$false -ErrorAction Stop
					Invoke-sqmLogging -Message "Vorhandener Job '$JobName' entfernt (-Force)." -FunctionName $functionName -Level "INFO"
				}
			}

			# ------------------------------------------------------------------
			# 6. Job + CmdExec-Step anlegen
			# ------------------------------------------------------------------
			$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
			$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`""

			if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "SQL-Agent-Job fuer Restore-Test von '$DatabaseName' erstellen"))
			{
				$null = New-DbaAgentJob @connParams -Job $JobName `
					-Description "Wiederkehrender Restore-Test von '$DatabaseName' via Invoke-sqmRestoreTest (New-sqmRestoreTestJob). $cleanupNote." `
					-ErrorAction Stop

				$null = New-DbaAgentJobStep @connParams -Job $JobName `
					-StepName $StepName -Subsystem 'CmdExec' -Command $command `
					-OnSuccessAction QuitWithSuccess -OnFailAction QuitWithFailure -ErrorAction Stop

				Invoke-sqmLogging -Message "Job '$JobName' auf '$SqlInstance' erstellt." -FunctionName $functionName -Level "INFO"
			}

			# ------------------------------------------------------------------
			# 7. Schedule anlegen
			# ------------------------------------------------------------------
			$scheduleName = $null
			if (-not $NoSchedule)
			{
				$timeParts = $ScheduleTime -split ':'
				$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]
				$timeNormal = $ScheduleTime -replace ':', ''
				$scheduleName = "sqm_RestoreTest_${safeDb}_${timeNormal}"

				$schedParams = $connParams.Clone()
				$schedParams['Job']		    = $JobName
				$schedParams['Schedule']    = $scheduleName
				$schedParams['Force']	    = $true
				$schedParams['StartTime']   = $startTime
				$schedParams['ErrorAction'] = 'Stop'

				switch ($ScheduleType)
				{
					'Monthly' {
						$schedParams['FrequencyType']     = 'Monthly'
						$schedParams['FrequencyInterval'] = $ScheduleDayOfMonth
						# FrequencyRecurrenceFactor = jeden Monat (bei Monthly zwingend > 0)
						$schedParams['FrequencyRecurrenceFactor'] = 1
						$schedInfo = "monatlich am $ScheduleDayOfMonth. um $ScheduleTime"
					}
					'Weekly' {
						$schedParams['FrequencyType']     = 'Weekly'
						$schedParams['FrequencyInterval'] = $ScheduleDays
						$schedParams['FrequencyRecurrenceFactor'] = 1
						$schedInfo = "woechentlich $($ScheduleDays -join '/') um $ScheduleTime"
					}
					'Daily' {
						$schedParams['FrequencyType']     = 'Daily'
						$schedParams['FrequencyInterval'] = 1
						$schedInfo = "taeglich um $ScheduleTime"
					}
				}

				if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "Zeitplan '$scheduleName' ($schedInfo) anlegen"))
				{
					$null = New-DbaAgentSchedule @schedParams
					Invoke-sqmLogging -Message "Zeitplan '$scheduleName': $schedInfo." -FunctionName $functionName -Level "INFO"
				}
			}
			else
			{
				Invoke-sqmLogging -Message "Job '$JobName' ohne Zeitplan erstellt (-NoSchedule)." -FunctionName $functionName -Level "INFO"
			}

			# ------------------------------------------------------------------
			# 8. Optional: Job sofort starten
			# ------------------------------------------------------------------
			$started = $false
			if ($StartJob)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Job sofort starten"))
				{
					Start-DbaAgentJob @connParams -Job $JobName -ErrorAction Stop | Out-Null
					$started = $true
					Invoke-sqmLogging -Message "Job '$JobName' wurde gestartet." -FunctionName $functionName -Level "INFO"
				}
			}

			return [PSCustomObject]@{
				SqlInstance		   = $SqlInstance
				JobName			   = $JobName
				StepName		   = $StepName
				DatabaseName	   = $DatabaseName
				ScheduleName	   = $scheduleName
				Schedule		   = if ($NoSchedule) { 'kein Zeitplan' } else { $schedInfo }
				RemovesTestDatabase = (-not $KeepTestDatabase)
				EvidencePath	   = $evidencePath
				WrapperPath		   = $wrapperPath
				Started			   = $started
				Status			   = "Success"
				Message			   = "Restore-Test-Job erstellt$(if ($started) { ' und gestartet' })."
				Timestamp		   = Get-Date
			}
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return [PSCustomObject]@{
				SqlInstance = $SqlInstance
				JobName	    = $JobName
				Status	    = "Failed"
				Message	    = $errMsg
				Timestamp   = Get-Date
			}
		}
	}
}
