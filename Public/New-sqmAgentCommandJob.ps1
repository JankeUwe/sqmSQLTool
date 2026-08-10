<#
.SYNOPSIS
Creates or extends a SQL Server Agent job that runs one or more sqmSQLTool functions as CmdExec
steps, with parameters passed via a generic, reusable wrapper (no PowerShell-source string-
building of parameter values).

.DESCRIPTION
Deploys a single reusable wrapper (generic-invoke.ps1) under the module's jobs folder. The wrapper
imports sqmSQLTool, resolves the target function via Get-Command (acting as an allowlist), loads
its parameters from a per-step .clixml file (Export-Clixml/Import-Clixml - typed values, nothing
string-escaped into generated PowerShell source) and invokes the function via splatting.

Each entry in -Command becomes one CmdExec job step running:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File generic-invoke.ps1 -FunctionName <fn> -ParamsPath <clixml>

Multiple -Command entries chain into one job: steps run in order (OnSuccessAction
'GoToNextStep'), the last step quits with success, and ANY step failing quits the job with
failure immediately (fail-fast - no partial chain continues past a broken step).

Two independent choices, both supported:
  - New job (default) vs. appending step(s) to an existing job (-AppendStep). When appending, the
    previously-last step of the existing job is switched from 'QuitWithSuccess' to 'GoToNextStep'
    (via Set-DbaAgentJobStep -StepName - Set-DbaAgentJobStep has no -StepId parameter) so the
    chain actually reaches the newly appended step(s), instead of silently stopping before them.
  - On-demand (default, no schedule) vs. scheduled (-ScheduleType Daily/Weekly/Monthly), via
    New-DbaAgentSchedule (dbatools), matching New-sqmRestoreTestJob's pattern.

Each target function is validated with Get-Command -Module sqmSQLTool BEFORE anything is written
or created, so a typo in -FunctionName fails immediately instead of at the next scheduled run.

.PARAMETER SqlInstance
SQL Server instance where the job is created/extended and where the wrapper/params files are
written (default: current computer name). Run this ON the target instance - see .NOTES.

.PARAMETER SqlCredential
Optional SQL credential for the connection used to CREATE the job (Get-DbaAgentJob/New-DbaAgentJob/
New-DbaAgentJobStep/New-DbaAgentSchedule/Start-DbaAgentJob). Only needed when Windows-integrated
auth from where you're RUNNING this isn't available (e.g. no domain trust to $SqlInstance) - has no
effect on how the job step itself authenticates once created; see .NOTES for that.

.PARAMETER JobName
Name of the Agent job. Mandatory.

.PARAMETER Command
One or more hashtables describing a step, in execution order. Each entry:
    FunctionName  - mandatory, must be an exported sqmSQLTool function.
    Parameters    - optional hashtable forwarded to the function via splatting. Default: @{}.
    StepName      - optional. Default: the function name (de-duplicated with a counter if the
                    same function appears more than once in -Command).

.PARAMETER AppendStep
Add the -Command step(s) to an EXISTING job instead of creating a new one. Requires the job to
already exist. New steps are numbered after the current last step.

.PARAMETER Force
When NOT using -AppendStep: replace an existing job of the same name. Ignored with a warning if
combined with -AppendStep.

.PARAMETER ScheduleType
'None' (default, on-demand only), 'Daily', 'Weekly' or 'Monthly'.

.PARAMETER ScheduleTime
Time of day for the schedule, "HH:mm". Default: '02:00'.

.PARAMETER ScheduleDays
Weekday(s) for -ScheduleType Weekly, e.g. 'Monday','Thursday'. Mandatory for Weekly.

.PARAMETER ScheduleDayOfMonth
Day of month (1-28) for -ScheduleType Monthly. Default: 1.

.PARAMETER StartJob
Start the job immediately after creating/extending it.

.PARAMETER EnableException
Throw exceptions immediately instead of logging and returning a result object.

.EXAMPLE
# Single step, on-demand.
New-sqmAgentCommandJob -SqlInstance 'SQL01' -JobName 'sqmCmd_LoginCompare_AG1' -Command @{
    FunctionName = 'Compare-sqmAlwaysOnLogins'
    Parameters   = @{ SqlInstance = 'SQL01'; AvailabilityGroupName = 'AG1'; OnlyDifferences = $true; FailOnDrift = $true; NoReport = $true }
}

.EXAMPLE
# Two steps chained in one job, scheduled daily at 03:00.
New-sqmAgentCommandJob -SqlInstance 'SQL01' -JobName 'sqmCmd_AGMaintenance' -ScheduleType Daily -ScheduleTime '03:00' -Command @(
    @{ FunctionName = 'Compare-sqmAlwaysOnLogins';   Parameters = @{ SqlInstance = 'SQL01'; AvailabilityGroupName = 'AG1'; FailOnDrift = $true } },
    @{ FunctionName = 'Repair-sqmAlwaysOnDatabases'; Parameters = @{ SqlInstance = 'SQL01'; AvailabilityGroupName = 'AG1' } }
)

.EXAMPLE
# Append a third step to that same job later.
New-sqmAgentCommandJob -SqlInstance 'SQL01' -JobName 'sqmCmd_AGMaintenance' -AppendStep -Command @{
    FunctionName = 'Get-sqmAlwaysOnHealthReport'
    Parameters   = @{ SqlInstance = 'SQL01' }
}

.EXAMPLE
# No domain trust to the target (e.g. a workgroup lab) - use -SqlCredential for the connection that
# creates the job. Has no effect on how the job step authenticates once it runs (see .NOTES).
$cred = Get-Credential
New-sqmAgentCommandJob -SqlInstance 'SQL01' -SqlCredential $cred -JobName 'sqmCmd_DiskCheck' -Command @{
    FunctionName = 'Get-sqmDiskSpaceReport'
    Parameters   = @{ SqlInstance = 'SQL01'; NoHistory = $true; NoOpen = $true }
}

.NOTES
Requires dbatools, Invoke-sqmLogging (same module).
The wrapper and per-step .clixml parameter files are written to
C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\ on $SqlInstance - run this ON the
target instance, like the module's other job-generating functions.
Auth model matches New-sqmRestoreDatabaseJob/New-sqmAlwaysOnRepairJob: no SQL credential is
embedded - the job step runs as the SQL Agent service account (or an assigned job step proxy),
which therefore needs whatever rights the target function(s) require.
Do NOT put PSCredential/SecureString values into -Parameters: Export-Clixml encrypts SecureString
via DPAPI for the CURRENT Windows account only, and the job step may run as a different account
(service account / proxy) that cannot decrypt it. Use a dedicated Agent proxy (New-sqmAgentProxy)
with Windows-Auth instead.
#>
function New-sqmAgentCommandJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $true)]
		[string]$JobName,

		[Parameter(Mandatory = $true)]
		[hashtable[]]$Command,

		[Parameter(Mandatory = $false)]
		[switch]$AppendStep,

		[Parameter(Mandatory = $false)]
		[switch]$Force,

		[Parameter(Mandatory = $false)]
		[ValidateSet('None', 'Daily', 'Weekly', 'Monthly')]
		[string]$ScheduleType = 'None',

		[Parameter(Mandatory = $false)]
		[string]$ScheduleTime = '02:00',

		[Parameter(Mandatory = $false)]
		[string[]]$ScheduleDays,

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 28)]
		[int]$ScheduleDayOfMonth = 1,

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

		if ($AppendStep -and $Force)
		{
			$msg = "-Force wird bei -AppendStep ignoriert (es wird an den vorhandenen Job angehaengt, nichts ersetzt)."
			Write-Warning $msg
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
		}

		if ($ScheduleType -eq 'Weekly' -and -not $ScheduleDays)
		{
			$msg = "-ScheduleType Weekly erfordert -ScheduleDays."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw $msg }
			Write-Error $msg
			return
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance fuer Job '$JobName'." -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			# ------------------------------------------------------------------
			# 1. -Command validieren UND gegen das Modul aufloesen (Allowlist). Laeuft komplett
			#    VOR jeder Aenderung an Job/Dateisystem - ein Tippfehler im Funktionsnamen bricht
			#    hier sofort ab, nicht erst beim naechtlichen Joblauf.
			# ------------------------------------------------------------------
			$resolved = [System.Collections.Generic.List[PSCustomObject]]::new()
			$usedStepNames = @{}

			foreach ($entry in $Command)
			{
				if (-not $entry.ContainsKey('FunctionName') -or [string]::IsNullOrWhiteSpace([string]$entry['FunctionName']))
				{
					throw "Jeder -Command-Eintrag braucht 'FunctionName'."
				}

				$fn = [string]$entry['FunctionName']
				$cmdInfo = Get-Command -Name $fn -Module sqmSQLTool -ErrorAction SilentlyContinue
				if (-not $cmdInfo)
				{
					throw "Funktion '$fn' ist keine exportierte sqmSQLTool-Funktion (Tippfehler?)."
				}

				$stepParams = if ($entry.ContainsKey('Parameters') -and $entry['Parameters']) { $entry['Parameters'] } else { @{} }

				$stepName = if ($entry.ContainsKey('StepName') -and $entry['StepName']) { [string]$entry['StepName'] } else { $fn }
				if ($usedStepNames.ContainsKey($stepName))
				{
					$usedStepNames[$stepName]++
					$stepName = "$stepName`_$($usedStepNames[$stepName])"
				}
				else
				{
					$usedStepNames[$stepName] = 1
				}

				$resolved.Add([PSCustomObject]@{
					FunctionName = $fn
					Parameters   = $stepParams
					StepName     = $stepName
				})
			}

			# ------------------------------------------------------------------
			# 2. jobs-Verzeichnis sicherstellen + generischen Wrapper deployen (identisch fuer
			#    JEDE Zielfunktion, deshalb bei jedem Aufruf ueberschrieben statt bedingt neu
			#    geschrieben - so bleibt nie ein alter Stand liegen).
			# ------------------------------------------------------------------
			$modulePath = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool'
			$jobsDir = Join-Path $modulePath 'jobs'
			if (-not (Test-Path $jobsDir))
			{
				New-Item -ItemType Directory -Path $jobsDir -Force -ErrorAction Stop | Out-Null
			}

			$genericInvokePath = Join-Path $jobsDir 'generic-invoke.ps1'
			$genericInvoke = @'
param(
    [Parameter(Mandatory)][string]$FunctionName,
    [Parameter(Mandatory)][string]$ParamsPath
)
$ErrorActionPreference = 'Stop'
Import-Module sqmSQLTool -Force

$cmd = Get-Command -Name $FunctionName -Module sqmSQLTool -ErrorAction Stop
$params = Import-Clixml -Path $ParamsPath

foreach ($opt in 'EnableException', 'Confirm') {
    if ($cmd.Parameters.ContainsKey($opt) -and -not $params.ContainsKey($opt)) {
        $params[$opt] = if ($opt -eq 'Confirm') { $false } else { $true }
    }
}

& $FunctionName @params
exit 0
'@

			if ($PSCmdlet.ShouldProcess($genericInvokePath, "Generischen Wrapper schreiben"))
			{
				# UTF-8 MIT BOM (Windows PowerShell 5.1 liest das Skript sonst evtl. falsch)
				[System.IO.File]::WriteAllText($genericInvokePath, $genericInvoke, (New-Object System.Text.UTF8Encoding($true)))
			}

			# ------------------------------------------------------------------
			# 3. Vorhandenen Job pruefen: anlegen, ersetzen oder erweitern.
			# ------------------------------------------------------------------
			$existingJob = Get-DbaAgentJob @connParams -Job $JobName -ErrorAction SilentlyContinue
			$startStepId = 1

			if ($AppendStep)
			{
				if (-not $existingJob)
				{
					throw "-AppendStep gesetzt, aber Job '$JobName' existiert nicht auf '$SqlInstance'."
				}

				$existingSteps = Get-DbaAgentJobStep @connParams -Job $JobName -ErrorAction Stop
				$lastStep = $existingSteps | Sort-Object -Property ID -Descending | Select-Object -First 1
				$startStepId = $lastStep.ID + 1

				if ($lastStep.OnSuccessAction -eq 'QuitWithSuccess')
				{
					if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName / $($lastStep.Name)", "OnSuccessAction auf 'GoToNextStep' umstellen, damit die Kette die neuen Steps erreicht"))
					{
						# Set-DbaAgentJobStep hat KEIN -StepId - Steps werden ueber -StepName adressiert.
						Set-DbaAgentJobStep @connParams -Job $JobName -StepName $lastStep.Name -OnSuccessAction GoToNextStep -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Bisher letzter Step '$($lastStep.Name)' auf GoToNextStep umgestellt (Anhaengen neuer Steps)." -FunctionName $functionName -Level 'INFO'
					}
				}
			}
			else
			{
				if ($existingJob -and -not $Force)
				{
					throw "Job '$JobName' existiert bereits auf '$SqlInstance'. Verwende -Force zum Ersetzen oder -AppendStep zum Erweitern."
				}
				if ($existingJob -and $Force)
				{
					if ($PSCmdlet.ShouldProcess($JobName, "Vorhandenen Job ersetzen (-Force)"))
					{
						Remove-DbaAgentJob @connParams -Job $JobName -Confirm:$false -ErrorAction Stop
						Invoke-sqmLogging -Message "Vorhandener Job '$JobName' entfernt (-Force)." -FunctionName $functionName -Level 'WARNING'
					}
				}

				if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "SQL-Agent-Job anlegen"))
				{
					$fnList = ($resolved | ForEach-Object { $_.FunctionName }) -join ', '
					New-DbaAgentJob @connParams -Job $JobName `
						-Description "sqmSQLTool-Befehlskette ($fnList) via New-sqmAgentCommandJob" `
						-ErrorAction Stop | Out-Null
				}
			}

			# ------------------------------------------------------------------
			# 4. Pro -Command-Eintrag: Parameter serialisieren (Export-Clixml - typisiert, kein
			#    Escaping in generiertem Code noetig) und CmdExec-Step anlegen. Steps werden per
			#    'GoToNextStep' verkettet, der letzte quittiert mit Erfolg; jeder Step beendet den
			#    Job bei Fehler sofort (Fail-Fast - keine Fortsetzung nach einem gebrochenen Step).
			# ------------------------------------------------------------------
			$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
			$stepId = $startStepId
			$createdSteps = [System.Collections.Generic.List[PSCustomObject]]::new()

			for ($i = 0; $i -lt $resolved.Count; $i++)
			{
				$entry = $resolved[$i]
				$isLast = ($i -eq $resolved.Count - 1)

				$safeName = ($JobName + '_' + $entry.StepName) -replace '[\\/:*?"<>|]', '_'
				$paramsPath = Join-Path $jobsDir "$safeName.clixml"

				if ($PSCmdlet.ShouldProcess($paramsPath, "Parameter fuer Step '$($entry.StepName)' serialisieren"))
				{
					$entry.Parameters | Export-Clixml -Path $paramsPath -Force
				}

				# WICHTIG: NICHT '$command' nennen - kollidiert case-insensitiv mit dem typisierten
				# Pflichtparameter '$Command' ([hashtable[]]). PowerShell erzwingt bei jeder
				# Zuweisung an eine parametertypisierte Variable weiterhin deren Typ; ein String
				# wuerde hier mit "Cannot convert ... to Hashtable[]" abbrechen.
				$stepCommand = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$genericInvokePath`" -FunctionName `"$($entry.FunctionName)`" -ParamsPath `"$paramsPath`""
				$onSuccess = if ($isLast) { 'QuitWithSuccess' } else { 'GoToNextStep' }

				if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "Step '$($entry.StepName)' (StepId $stepId) anlegen"))
				{
					New-DbaAgentJobStep @connParams -Job $JobName -StepId $stepId `
						-StepName $entry.StepName -Subsystem 'CmdExec' -Command $stepCommand `
						-OnSuccessAction $onSuccess -OnFailAction 'QuitWithFailure' -ErrorAction Stop | Out-Null
				}

				$createdSteps.Add([PSCustomObject]@{
					StepId       = $stepId
					StepName     = $entry.StepName
					FunctionName = $entry.FunctionName
					ParamsPath   = $paramsPath
				})

				$stepId++
			}

			# ------------------------------------------------------------------
			# 5. Schedule optional anlegen (New-DbaAgentSchedule statt roher T-SQL - gleiches
			#    Muster wie New-sqmRestoreTestJob).
			# ------------------------------------------------------------------
			$scheduleName = $null
			if ($ScheduleType -ne 'None')
			{
				$timeNormal = $ScheduleTime -replace ':', ''
				$startTime = if ($timeNormal.Length -eq 4) { "${timeNormal}00" } else { $timeNormal }
				$scheduleName = "sch_$JobName"

				$schedParams = $connParams.Clone()
				$schedParams['Job']       = $JobName
				$schedParams['Schedule']  = $scheduleName
				$schedParams['Force']     = $true
				$schedParams['StartTime'] = $startTime

				switch ($ScheduleType)
				{
					'Daily' {
						$schedParams['FrequencyType'] = 'Daily'
						$schedParams['FrequencyInterval'] = 1
						$schedInfo = "taeglich um $ScheduleTime"
					}
					'Weekly' {
						$schedParams['FrequencyType'] = 'Weekly'
						$schedParams['FrequencyInterval'] = $ScheduleDays
						$schedParams['FrequencyRecurrenceFactor'] = 1
						$schedInfo = "woechentlich $($ScheduleDays -join '/') um $ScheduleTime"
					}
					'Monthly' {
						$schedParams['FrequencyType'] = 'Monthly'
						$schedParams['FrequencyInterval'] = $ScheduleDayOfMonth
						$schedParams['FrequencyRecurrenceFactor'] = 1
						$schedInfo = "monatlich am $ScheduleDayOfMonth. um $ScheduleTime"
					}
				}

				if ($PSCmdlet.ShouldProcess("$SqlInstance / $JobName", "Zeitplan '$scheduleName' ($schedInfo) anlegen"))
				{
					New-DbaAgentSchedule @schedParams -ErrorAction Stop | Out-Null
					Invoke-sqmLogging -Message "Zeitplan '$scheduleName': $schedInfo." -FunctionName $functionName -Level 'INFO'
				}
			}

			# ------------------------------------------------------------------
			# 6. Optional: Job sofort starten.
			# ------------------------------------------------------------------
			$started = $false
			if ($StartJob)
			{
				if ($PSCmdlet.ShouldProcess($JobName, "Job sofort starten"))
				{
					Start-DbaAgentJob @connParams -Job $JobName -ErrorAction Stop | Out-Null
					$started = $true
					Invoke-sqmLogging -Message "Job '$JobName' wurde gestartet." -FunctionName $functionName -Level 'INFO'
				}
			}

			$modeText = if ($AppendStep) { 'AppendStep' } else { 'NewJob' }
			Invoke-sqmLogging -Message "$functionName fuer Job '$JobName' abgeschlossen ($($createdSteps.Count) Step(s), Mode: $modeText)." -FunctionName $functionName -Level 'INFO'

			return [PSCustomObject]@{
				SqlInstance  = $SqlInstance
				JobName      = $JobName
				Mode         = $modeText
				Steps        = $createdSteps
				ScheduleName = $scheduleName
				Started      = $started
				Status       = 'Success'
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
				SqlInstance = $SqlInstance
				JobName     = $JobName
				Status      = 'Failed'
				Message     = $errMsg
				Timestamp   = Get-Date
			}
		}
	}
}
