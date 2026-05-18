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
			
			# PowerShell-Skript fuer den Job-Schritt
			# Dieses Skript laedt die benoetigten Funktionen (hier vereinfacht: wir nehmen an, dass sie bereits definiert sind)
			# Fuer Produktivumgebung besser: In ein Modul packen oder ueber -Command eine Skriptdatei aufrufen.
			$powershellCode = @'
# Importiere dbatools (falls nicht bereits geladen)
if (-not (Get-Module dbatools)) { Import-Module dbatools -ErrorAction Stop }

# Hier die benutzerdefinierten Funktionen definieren oder aus einer Datei dot-sourcen.
# Wir nehmen an, dass die Funktionen bereits im globalen Scope verfuegbar sind (z.B. durch ein Modul).
# Falls nicht, folgende Zeile aktivieren und Pfad anpassen:
# . "C:\Scripts\sqmAlwaysOnFunctions.ps1"

# Fuehre Reparatur aus
Repair-sqmAlwaysOnDatabases -SqlInstance $env:COMPUTERNAME -Force -SkipAutoSeedingCheck

# Optional: Logging in eine Datei
# $log = "C:\Logs\AlwaysOnRepair_$(Get-Date -Format 'yyyyMMdd_HHmsqm').log"
# Repair-sqmAlwaysOnDatabases -SqlInstance $env:COMPUTERNAME -Force -SkipAutoSeedingCheck | Out-File $log
'@
			
			# Erstelle Job mit dbatools
			$jobParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Job		      = $JobName
				Description   = "Fuehrt regelmaessig die Reparatur von AlwaysOn-Datenbanken durch."
				OwnerLogin    = 'sa'
				ErrorAction   = 'Stop'
			}
			if ($EnableException) { $jobParams.EnableException = $true }
			
			if ($PSCmdlet.ShouldProcess($SqlInstance, "Erstelle Job '$JobName'"))
			{
				$job = New-DbaAgentJob @jobParams
				
				# Erstelle Job-Schritt (PowerShell)
				$stepParams = @{
					SqlInstance   = $SqlInstance
					SqlCredential = $SqlCredential
					Job		      = $JobName
					StepName	  = 'RunRepair'
					SubSystem	  = 'PowerShell'
					Command	      = $powershellCode
					Database	  = 'master'
					ErrorAction   = 'Stop'
				}
				Add-DbaAgentJobStep @stepParams
				
				# Fuege Zeitplan hinzu, falls angegeben
				if ($Schedule)
				{
					$scheduleParams = @{
						SqlInstance   = $SqlInstance
						SqlCredential = $SqlCredential
						Job		      = $JobName
						Schedule	  = "$JobName Schedule"
						Frequency	  = $Schedule
						ErrorAction   = 'Stop'
					}
					if ($StartTime) { $scheduleParams.StartTime = $StartTime }
					Add-DbaAgentJobSchedule @scheduleParams
				}
				
				# Aktiviere Job
				Enable-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Job $JobName
				
				Invoke-sqmLogging -Message "Job '$JobName' erfolgreich erstellt und aktiviert." -FunctionName $functionName -Level "INFO"
				
				# Rueckgabe
				[PSCustomObject]@{
					SqlInstance = $SqlInstance
					JobName	    = $JobName
					Status	    = "Created"
					Schedule    = $Schedule
					Message	    = "Job wurde erstellt. Manueller Start: Start-DbaAgentJob -SqlInstance $SqlInstance -Job '$JobName'"
				}
			}
			else
			{
				[PSCustomObject]@{
					SqlInstance = $SqlInstance
					JobName	    = $JobName
					Status	    = "Skipped"
					Message	    = "WhatIf: Job-Erstellung uebersprungen."
				}
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