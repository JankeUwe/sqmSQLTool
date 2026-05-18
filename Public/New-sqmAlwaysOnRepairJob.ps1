<#
.SYNOPSIS
Erstellt einen SQL Server Agent-Job, der regelmaessig Repair-sqmAlwaysOnDatabases ausfuehrt.

.DESCRIPTION
Der Job wird auf der angegebenen SQL-Instanz erstellt und verwendet das PowerShell-Subsystem,
um die Funktion Repair-sqmAlwaysOnDatabases aufzurufen. Der Job kann nach Zeitplan (z.B. stuendlich)
oder bei Bedarf manuell gestartet werden.

Voraussetzung: Die Funktionen (Repair-sqmAlwaysOnDatabases, Invoke-sqmLogging, Invoke-sqmSqlAlwaysOnAutoseeding)
sowie das dbatools-Modul muessen auf dem SQL Server verfuegbar sein (z.B. in einem Modulpfad oder als Skriptdatei).

.PARAMETER SqlInstance
Ziel-SQL-Instanz (Standard: Computername).

.PARAMETER SqlCredential
Anmeldeinformationen fuer die SQL-Instanz (fuer Job-Erstellung).

.PARAMETER JobName
Name des zu erstellenden Agent-Jobs. Standard: 'sqmAlwaysOnRepair'.

.PARAMETER Schedule
Zeitplan im Format 'FREQ=HOURLY;INTERVAL=1' (Standard stuendlich). Kann auch 'FREQ=DAILY;INTERVAL=1' sein.
Leer lassen fuer keinen Zeitplan (nur manuell).

.PARAMETER StartTime
Uhrzeit fuer den Zeitplan (z.B. '00:00:00'). Optional.

.PARAMETER Force
ueberschreibt einen vorhandenen Job mit gleichem Namen.

.PARAMETER EnableException
Ausnahmen durchlassen.

.EXAMPLE
# Erstellt einen stuendlichen Job
New-sqmAlwaysOnRepairJob

.EXAMPLE
# Taeglicher Job um 2 Uhr morgens
New-sqmAlwaysOnRepairJob -Schedule "FREQ=DAILY;INTERVAL=1" -StartTime "02:00:00"

.NOTES
Der PowerShell-Code des Job-Schritts laedt automatisch das dbatools-Modul und alle benoetigten Funktionen.
Es wird angenommen, dass die Funktionen bereits im Session-Global verfuegbar sind oder als Skript nachgeladen werden.
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