<#
.SYNOPSIS
    Fixes the SSAS internal error "pcserialize.cpp, line 1535, function 'ASDatabase::Serialize'"
    that blocks XMLA database deployment.

.DESCRIPTION
    Known SSAS issue (see Microsoft Q&A: 1350375 "How to fix Internal error: An unexpected
    error occurred (file 'pcserialize.cpp', line 1535, function 'ASDatabase::Serialize')"):
    deploying an XMLA <Create>/<Alter> script fails with this internal serialization error,
    most commonly reported when the SSAS instance is part of an Always On Availability Group
    environment. The confirmed fix is to remove the undocumented <Gen2ServerKey> element from
    msmdsrv.ini and restart the service - its purpose is unclear and no side effects have been
    reported from removing it.

    This function locates msmdsrv.ini via the Windows service command line (-s switch), backs
    it up, removes <Gen2ServerKey> if present, and optionally restarts the service. Same
    discovery approach as Get-/Set-sqmSsasDeploymentMode.

.PARAMETER InstanceName
    Name of the SSAS instance. Default: 'MSSQLSERVER' (default instance).
    For named instances e.g. 'SSAS2019'. A "Server\Instance" prefix (as copied from SSMS) is
    accepted and the server part is ignored.

.PARAMETER RestartService
    Restarts the SSAS Windows service after the change so it takes effect immediately.
    Without this switch, the change is written but only takes effect after a manual service
    restart - and the serialization error keeps occurring until then.

.PARAMETER EnableException
    Throws an exception immediately on errors (otherwise the error is logged and returned in
    the result).

.PARAMETER WhatIf
    Shows which change would be made without executing it.

.PARAMETER Confirm
    Prompts for confirmation before changing msmdsrv.ini.

.OUTPUTS
    [PSCustomObject] with:
        InstanceName     : Instance name (server prefix stripped, if any)
        ServiceName      : Windows service name of the SSAS instance
        IniPath          : Path to msmdsrv.ini
        BackupPath       : Path of the msmdsrv.ini backup (only when changed)
        ServiceRestarted : Whether the SSAS service was restarted
        Status           : NotPresent | Removed | WhatIf | Error
        Message          : Detail message

.EXAMPLE
    Repair-sqmSsasSerializeError -RestartService

    Removes <Gen2ServerKey> from the default instance's msmdsrv.ini and restarts the service
    so XMLA deployments stop failing with the ASDatabase::Serialize error immediately.

.EXAMPLE
    Repair-sqmSsasSerializeError -InstanceName 'SSAS2019' -WhatIf

    Shows whether <Gen2ServerKey> is present for the named instance without changing anything.

.NOTES
    Requires local administrator rights on the SSAS server.
    Source: https://learn.microsoft.com/en-us/answers/questions/1350375/
#>
function Repair-sqmSsasSerializeError
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$InstanceName = 'MSSQLSERVER',
		[Parameter(Mandatory = $false)]
		[switch]$RestartService,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# Bequemlichkeits-Fix: "Server\Instanz" (SSMS-Format) wird ebenso akzeptiert wie eine reine
		# Instanz - der Windows-Dienstname enthaelt nur die Instanz, ein Server-Praefix fuehrt sonst
		# zu einer ungueltigen WQL-Abfrage (Backslash ist dort ein Escape-Zeichen -> "Invalid query").
		if ($InstanceName -match '\\')
		{
			$InstanceName = $InstanceName.Substring($InstanceName.LastIndexOf('\') + 1)
		}

		$result = [PSCustomObject]@{
			InstanceName	 = $InstanceName
			ServiceName	     = $null
			IniPath		     = $null
			BackupPath	     = $null
			ServiceRestarted = $false
			Status		     = 'Error'
			Message		     = $null
		}

		Invoke-sqmLogging -Message "Starte $functionName fuer SSAS-Instanz '$InstanceName'" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# 1. Dienst und msmdsrv.ini ueber die Service-Kommandozeile (-s "<ConfigDir>") ermitteln
			$serviceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLServerOLAPService' }
			else { "MSOLAP`$$InstanceName" }
			$result.ServiceName = $serviceName

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

			$gen2Node = $configNode.SelectSingleNode('Gen2ServerKey')

			# 3. Idempotenz-Pruefung
			if (-not $gen2Node)
			{
				$result.Status  = 'NotPresent'
				$result.Message = "'<Gen2ServerKey>' ist in '$iniPath' nicht vorhanden - keine Aenderung noetig."
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
				Write-Verbose $result.Message
				return $result
			}

			# 4. Aenderung durchfuehren
			if ($PSCmdlet.ShouldProcess($iniPath, "'<Gen2ServerKey>' entfernen (behebt ASDatabase::Serialize-Fehler)"))
			{
				$backupPath = "$iniPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
				Copy-Item -Path $iniPath -Destination $backupPath -Force -ErrorAction Stop
				$result.BackupPath = $backupPath
				Invoke-sqmLogging -Message "Backup erstellt: '$backupPath'" -FunctionName $functionName -Level "INFO"

				$configNode.RemoveChild($gen2Node) | Out-Null
				$xml.Save($iniPath)

				$result.Status  = 'Removed'
				$result.Message = "'<Gen2ServerKey>' aus '$iniPath' entfernt."
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
				$result.Message = "WhatIf: '<Gen2ServerKey>' wuerde aus '$iniPath' entfernt."
			}
		}
		catch
		{
			$errMsg = "Fehler beim Entfernen von '<Gen2ServerKey>': $($_.Exception.Message)"
			$result.Message = $errMsg
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg -ErrorAction Continue
		}
		return $result
	}
}
