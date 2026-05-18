<#
.SYNOPSIS
    Installiert oder aktualisiert Ola Hallengrens Maintenance Solution auf einer SQL Server-Instanz.

.DESCRIPTION
    Laedt die neueste Version der Maintenance Solution von GitHub herunter
    (https://github.com/olahallengren/sql-server-maintenance-solution/archive/refs/heads/main.zip),
    extrahiert die benoetigten Skripte und fuehrt sie in folgender Reihenfolge aus:
    1. CommandExecute.sql
    2. CommandLog.sql
    3. DatabaseBackup.sql
    4. DatabaseIntegrityCheck.sql
    5. IndexOptimize.sql

    Die Installation erstellt ausschliesslich die Datenbankobjekte (Tabellen, Prozeduren),
    aber keine SQL Agent Jobs. Die Jobs werden spaeter mit den dafuer vorgesehenen Funktionen
    (z.?B. New-sqmOlaBackupJobs) erstellt.

    Vorhandene Installationen werden mit -Force / -Update ueberschrieben.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER SourcePath
    Alternative Quelle fuer das ZIP-Archiv. Standard: GitHub-ZIP.

.PARAMETER Force
    Vorhandene Installation ignorieren und neu installieren.

.PARAMETER Update
    Alias fuer -Force.

.PARAMETER ContinueOnError
    Bei Fehler mit naechster Instanz fortfahren.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.PARAMETER Confirm
    Bestaetigung vor der Installation anfordern.

.PARAMETER WhatIf
    Zeigt, was passieren wuerde, ohne aenderungen vorzunehmen.

.EXAMPLE
    Install-sqmOlaMaintenanceSolution -SqlInstance "SQL01"

.EXAMPLE
    Install-sqmOlaMaintenanceSolution -SqlInstance "SQL01" -Force

.NOTES
    Voraussetzungen: dbatools, Invoke-sqmLogging, Test-sqmOlaInstallation.
    Die Funktion laedt das ZIP-Archiv herunter und bereinigt alle temporaeren Dateien selbststaendig.
#>
function Install-sqmOlaMaintenanceSolution
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$SourcePath = "https://github.com/olahallengren/sql-server-maintenance-solution/archive/refs/heads/main.zip",
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$Update,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		$effForce = $Force -or $Update
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		# SQL-Dateien in der benoetigten Reihenfolge
		$scriptFiles = @(
			"CommandExecute.sql",
			"CommandLog.sql",
			"DatabaseBackup.sql",
			"DatabaseIntegrityCheck.sql",
			"IndexOptimize.sql"
		)
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			$instanceResult = [PSCustomObject]@{
				SqlInstance = $instance
				SourceUsed  = $null
				Status	    = 'Unknown'
				Message	    = $null
				ExistingOla = $false
				Action	    = $null
			}
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Pruefe Ola-Installation ..." -FunctionName $functionName -Level "INFO"
				
				# Pruefen, ob Ola bereits installiert ist
				$olaCheck = Test-sqmOlaInstallation -SqlInstance $instance -SqlCredential $SqlCredential -RequiredSet Backup
				$instanceResult.ExistingOla = $olaCheck.IsInstalled
				
				if ($olaCheck.IsInstalled -and -not $effForce)
				{
					$msg = "Ola Maintenance Solution ist bereits installiert (gefunden: $($olaCheck.PresentObjects -join ', ')). Verwenden Sie -Force zum ueberschreiben."
					Invoke-sqmLogging -Message "[$instance] $msg" -FunctionName $functionName -Level "INFO"
					$instanceResult.Status = 'AlreadyInstalled'
					$instanceResult.Message = $msg
					$allResults.Add($instanceResult)
					continue
				}
				
				# Temporaeres Verzeichnis fuer Download und Extraktion
				$tempDir = Join-Path $env:TEMP "OlaInstall_$(Get-Random)"
				$zipFile = Join-Path $tempDir "main.zip"
				New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
				
				try
				{
					# ZIP herunterladen
					Invoke-sqmLogging -Message "[$instance] Lade Ola-Skripte von $SourcePath herunter ..." -FunctionName $functionName -Level "INFO"
					Invoke-WebRequest -Uri $SourcePath -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
					$instanceResult.SourceUsed = $SourcePath
					
					# ZIP extrahieren
					Invoke-sqmLogging -Message "[$instance] Extrahiere ZIP-Archiv ..." -FunctionName $functionName -Level "INFO"
					Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force -ErrorAction Stop
					
					# Das extrahierte Verzeichnis (z.?B. sql-server-maintenance-solution-main) finden
					$extractedDir = Get-ChildItem -Path $tempDir -Directory | Where-Object { $_.Name -like "sql-server-maintenance-solution-*" } | Select-Object -First 1
					if (-not $extractedDir)
					{
						throw "Konnte extrahiertes Verzeichnis nicht finden."
					}
					
					# Skripte in der definierten Reihenfolge ausfuehren
					$actionMsg = if ($olaCheck.IsInstalled -and $effForce) { "Aktualisiere Ola Maintenance Solution auf $instance" }
					else { "Installiere Ola Maintenance Solution auf $instance" }
					if ($PSCmdlet.ShouldProcess($instance, $actionMsg))
					{
						Invoke-sqmLogging -Message "[$instance] Fuehre Ola-Installationsskripte aus ..." -FunctionName $functionName -Level "INFO"
						
						foreach ($scriptFile in $scriptFiles)
						{
							$scriptPath = Join-Path $extractedDir.FullName $scriptFile
							if (-not (Test-Path $scriptPath))
							{
								Invoke-sqmLogging -Message "[$instance] Skript '$scriptFile' nicht gefunden - ueberspringe." -FunctionName $functionName -Level "WARNING"
								continue
							}
							Invoke-sqmLogging -Message "[$instance] Fuehre $scriptFile aus ..." -FunctionName $functionName -Level "VERBOSE"
							Invoke-DbaQuery @connParams -Database master -File $scriptPath -EnableException -ErrorAction Stop
						}
						
						Invoke-sqmLogging -Message "[$instance] Ola-Installation erfolgreich abgeschlossen." -FunctionName $functionName -Level "INFO"
						$instanceResult.Status = 'Success'
						$instanceResult.Action = if ($olaCheck.IsInstalled -and $effForce) { 'Updated' }
						else { 'Installed' }
						$instanceResult.Message = "Ola Maintenance Solution wurde erfolgreich ${actionMsg}. (Keine Jobs erstellt)."
					}
					else
					{
						$instanceResult.Status = 'WhatIf'
						$instanceResult.Message = "WhatIf: $actionMsg (keine Jobs)"
					}
				}
				finally
				{
					# Temporaere Dateien bereinigen
					if (Test-Path $tempDir)
					{
						Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
					}
				}
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$instanceResult.Status = 'Failed'
				$instanceResult.Message = $errMsg
				if (-not $ContinueOnError -and -not $EnableException) { throw }
				if ($EnableException) { throw $_ }
			}
			$allResults.Add($instanceResult)
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}