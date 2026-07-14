<#
.SYNOPSIS
    Corrects the DeploymentMode of an SSAS instance (Multidimensional <-> Tabular) after installation.

.DESCRIPTION
    SQL Server Analysis Services fixes its server mode (Multidimensional, Tabular or SharePoint/
    PowerPivot) permanently at setup time via the SERVERMODE parameter. Microsoft does not officially
    support changing the mode afterwards - the documented remedy is to uninstall and reinstall the
    instance with the correct SERVERMODE.

    In practice, on an instance where SERVERMODE was chosen wrong and no databases have been deployed
    yet, the mode can be corrected by editing the <DeploymentMode> element in msmdsrv.ini and restarting
    the service:
        0 = Multidimensional
        1 = SharePoint (PowerPivot, legacy)
        2 = Tabular

    This function locates msmdsrv.ini via the Windows service command line (-s switch), backs it up,
    updates <DeploymentMode>, and optionally restarts the service.

    SAFETY: Multidimensional and Tabular use incompatible storage engines. If databases already exist
    under the instance's Data directory, switching mode orphans them - they will not open in the new
    mode. By default the function refuses to proceed when existing databases are detected; use -Force
    to override (only after you have verified there is nothing worth keeping, or made your own backup).

.PARAMETER InstanceName
    Name of the SSAS instance. Default: 'MSSQLSERVER' (default instance).
    For named instances e.g. 'SSAS2019'.

.PARAMETER Mode
    Target deployment mode: 'Multidimensional' or 'Tabular'.

.PARAMETER RestartService
    Restarts the SSAS Windows service after the change so it takes effect immediately.
    Without this switch, the change is written but only takes effect after a manual service restart.

.PARAMETER Force
    Proceeds even when existing databases are found under the instance's Data directory.
    Use only when you are certain those databases can be discarded or have been backed up separately.

.PARAMETER EnableException
    Throws an exception immediately on errors (otherwise the error is logged and returned in the result).

.PARAMETER WhatIf
    Shows which change would be made without executing it.

.PARAMETER Confirm
    Prompts for confirmation before changing msmdsrv.ini.

.OUTPUTS
    [PSCustomObject] with:
        InstanceName     : Instance name
        IniPath          : Path to msmdsrv.ini
        PreviousMode     : Deployment mode before the change
        NewMode          : Requested deployment mode
        DatabasesFound   : Number of existing database folders detected in the Data directory
        BackupPath       : Path of the msmdsrv.ini backup (only when changed)
        ServiceRestarted : Whether the SSAS service was restarted
        Status           : AlreadySet | Changed | Blocked | WhatIf | Error
        Message          : Detail message

.EXAMPLE
    Set-sqmSsasDeploymentMode -InstanceName 'MSSQLSERVER' -Mode Tabular -RestartService

    Corrects a default instance that was installed as Multidimensional but should be Tabular,
    and restarts the service immediately. Fails if databases already exist (no -Force).

.EXAMPLE
    Set-sqmSsasDeploymentMode -InstanceName 'SSAS2019' -Mode Multidimensional -WhatIf

    Shows what would be changed for the named instance without writing anything.

.NOTES
    Requires local administrator rights on the SSAS server. Not an officially supported operation -
    only safe on an instance without deployed databases. See Microsoft docs on SERVERMODE / DeploymentMode.
#>
function Set-sqmSsasDeploymentMode
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$InstanceName = 'MSSQLSERVER',
		[Parameter(Mandatory = $true)]
		[ValidateSet('Multidimensional', 'Tabular')]
		[string]$Mode,
		[Parameter(Mandatory = $false)]
		[switch]$RestartService,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$modeValueMap = @{ Multidimensional = 0; SharePoint = 1; Tabular = 2 }

		$result = [PSCustomObject]@{
			InstanceName	 = $InstanceName
			IniPath		     = $null
			PreviousMode	 = $null
			NewMode		     = $Mode
			DatabasesFound   = 0
			BackupPath	     = $null
			ServiceRestarted = $false
			Status		     = 'Error'
			Message		     = $null
		}

		Invoke-sqmLogging -Message "Starte $functionName fuer SSAS-Instanz '$InstanceName' -> Zielmodus '$Mode'" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# 1. Dienst und msmdsrv.ini ueber die Service-Kommandozeile (-s "<ConfigDir>") ermitteln
			$serviceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLServerOLAPService' }
			else { "MSOLAP`$$InstanceName" }

			$svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
			if (-not $svc)
			{
				throw "SSAS-Dienst '$serviceName' nicht gefunden."
			}

			$configDir = $null
			if ($svc.PathName -match '-s\s+"([^"]+)"')
			{
				$configDir = $Matches[1]
			}
			elseif ($svc.PathName -match '^"?([^"]+\\msmdsrv\.exe)"?')
			{
				# Fallback: Config-Ordner relativ zur Exe (...\OLAP\bin\msmdsrv.exe -> ...\OLAP\Config)
				$olapDir = Split-Path (Split-Path $Matches[1] -Parent) -Parent
				$configDir = Join-Path $olapDir 'Config'
			}
			else
			{
				throw "Konnte den Config-Pfad nicht aus der Dienst-Kommandozeile ermitteln: '$($svc.PathName)'"
			}

			$iniPath = Join-Path $configDir 'msmdsrv.ini'
			$result.IniPath = $iniPath
			if (-not (Test-Path $iniPath))
			{
				throw "msmdsrv.ini nicht gefunden unter '$iniPath'."
			}
			Invoke-sqmLogging -Message "msmdsrv.ini gefunden: '$iniPath'" -FunctionName $functionName -Level "VERBOSE"

			# 2. msmdsrv.ini als XML laden (Whitespace erhalten, um den Diff minimal zu halten)
			$xml = New-Object System.Xml.XmlDocument
			$xml.PreserveWhitespace = $true
			$xml.Load($iniPath)

			$configNode = $xml.SelectSingleNode('/ConfigurationSettings')
			if (-not $configNode)
			{
				throw "Unerwartetes Format von msmdsrv.ini - Knoten '/ConfigurationSettings' nicht gefunden."
			}

			$deployNode = $configNode.SelectSingleNode('DeploymentMode')
			$currentValue = if ($deployNode) { [int]$deployNode.InnerText } else { 0 } # fehlt der Knoten -> Default Multidimensional (0)
			$currentModeName = ($modeValueMap.GetEnumerator() | Where-Object { $_.Value -eq $currentValue } | Select-Object -First 1).Name
			if (-not $currentModeName) { $currentModeName = "Unbekannt($currentValue)" }
			$result.PreviousMode = $currentModeName

			$targetValue = $modeValueMap[$Mode]
			Invoke-sqmLogging -Message "Aktueller Modus: $currentModeName ($currentValue) | Zielmodus: $Mode ($targetValue)" -FunctionName $functionName -Level "INFO"

			# 3. Idempotenz-Pruefung
			if ($currentValue -eq $targetValue)
			{
				$result.Status  = 'AlreadySet'
				$result.Message = "DeploymentMode ist bereits '$Mode' - keine Aenderung noetig."
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
				Write-Verbose $result.Message
				return $result
			}

			# 4. Vorhandene Datenbanken erkennen (Data-Verzeichnis aus der ini, sonst Standardpfad)
			$dataDirNode = $configNode.SelectSingleNode('DataDir')
			$dataDir = if ($dataDirNode -and $dataDirNode.InnerText) { $dataDirNode.InnerText }
			else { Join-Path (Split-Path $configDir -Parent) 'Data' }

			$dbFolders = @()
			if (Test-Path $dataDir)
			{
				$dbFolders = @(Get-ChildItem -Path $dataDir -Directory -Filter '*.db' -ErrorAction SilentlyContinue)
			}
			$result.DatabasesFound = $dbFolders.Count

			if ($dbFolders.Count -gt 0 -and -not $Force)
			{
				$result.Status  = 'Blocked'
				$result.Message = "$($dbFolders.Count) vorhandene Datenbank(en) unter '$dataDir' gefunden. " +
				"Multidimensional und Tabular sind speicherformat-inkompatibel - ein Moduswechsel macht diese Datenbanken unbrauchbar. " +
				"Mit -Force erzwingen (nur nach eigener Sicherung/Pruefung)."
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "WARNING"
				Write-Warning $result.Message
				if ($EnableException) { throw $result.Message }
				return $result
			}
			if ($dbFolders.Count -gt 0)
			{
				Write-Warning "Force: $($dbFolders.Count) vorhandene Datenbank(en) unter '$dataDir' werden nach dem Moduswechsel unbrauchbar."
				Invoke-sqmLogging -Message "Force gesetzt - fahre trotz $($dbFolders.Count) vorhandener Datenbank(en) fort." -FunctionName $functionName -Level "WARNING"
			}

			# 5. Aenderung durchfuehren
			if ($PSCmdlet.ShouldProcess($iniPath, "DeploymentMode von '$currentModeName' auf '$Mode' aendern"))
			{
				$backupPath = "$iniPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
				Copy-Item -Path $iniPath -Destination $backupPath -Force -ErrorAction Stop
				$result.BackupPath = $backupPath
				Invoke-sqmLogging -Message "Backup erstellt: '$backupPath'" -FunctionName $functionName -Level "INFO"

				if (-not $deployNode)
				{
					$deployNode = $xml.CreateElement('DeploymentMode')
					$configNode.AppendChild($deployNode) | Out-Null
				}
				$deployNode.InnerText = "$targetValue"
				$xml.Save($iniPath)

				$result.Status  = 'Changed'
				$result.Message = "DeploymentMode fuer '$InstanceName' von '$currentModeName' auf '$Mode' geaendert."
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
				Write-Host "  OK: $($result.Message)" -ForegroundColor Green

				if ($RestartService)
				{
					try
					{
						Write-Host "  Starte Dienst '$serviceName' neu..." -ForegroundColor Gray
						Restart-Service -Name $serviceName -Force -ErrorAction Stop
						$result.ServiceRestarted = $true
						$result.Message += " Dienst neu gestartet."
						Invoke-sqmLogging -Message "Dienst '$serviceName' neu gestartet." -FunctionName $functionName -Level "INFO"
						Write-Host "  OK: Dienst neu gestartet." -ForegroundColor Green
					}
					catch
					{
						$restartErr = "Aenderung geschrieben, aber Dienst-Neustart fehlgeschlagen: $($_.Exception.Message)"
						$result.Message += " $restartErr"
						Invoke-sqmLogging -Message $restartErr -FunctionName $functionName -Level "ERROR"
						Write-Warning $restartErr
						if ($EnableException) { throw }
					}
				}
				else
				{
					$result.Message += " Dienst-Neustart erforderlich, damit die Aenderung wirksam wird."
					Write-Host "  Hinweis: Dienst '$serviceName' muss neu gestartet werden." -ForegroundColor Yellow
				}
			}
			else
			{
				$result.Status  = 'WhatIf'
				$result.Message = "WhatIf: DeploymentMode wuerde von '$currentModeName' auf '$Mode' geaendert."
			}
		}
		catch
		{
			$errMsg = "Fehler beim Aendern des DeploymentMode: $($_.Exception.Message)"
			$result.Message = $errMsg
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
		return $result
	}
}
