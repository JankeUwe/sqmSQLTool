<#
.SYNOPSIS
    Reads the current DeploymentMode (Multidimensional / Tabular / SharePoint) of an SSAS instance.

.DESCRIPTION
    Locates msmdsrv.ini via the Windows service command line (-s switch) of the SSAS instance and
    reads the <DeploymentMode> element, without changing anything. Companion read-only function to
    Set-sqmSsasDeploymentMode.

.PARAMETER InstanceName
    Name of the SSAS instance. Default: 'MSSQLSERVER' (default instance).
    For named instances e.g. 'SSAS2019'. A "Server\Instance" prefix (as copied from SSMS) is
    accepted and the server part is ignored.

.PARAMETER EnableException
    Throws an exception immediately on errors (otherwise the error is logged and returned in the result).

.OUTPUTS
    [PSCustomObject] with:
        InstanceName     : Instance name (server prefix stripped, if any)
        ServiceName       : Windows service name of the SSAS instance
        IniPath          : Path to msmdsrv.ini
        DeploymentMode   : Multidimensional | Tabular | SharePoint | Unbekannt(<value>)
        DeploymentModeValue : Raw numeric value from msmdsrv.ini (0/1/2)
        Status           : OK | Error
        Message          : Detail message

.EXAMPLE
    Get-sqmSsasDeploymentMode -InstanceName 'APSM'

    Reports the current DeploymentMode of the named SSAS instance 'APSM'.

.NOTES
    Requires local administrator rights on the SSAS server (to read msmdsrv.ini).
#>
function Get-sqmSsasDeploymentMode
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$InstanceName = 'MSSQLSERVER',
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$modeValueMap = @{ Multidimensional = 0; SharePoint = 1; Tabular = 2 }

		# Bequemlichkeits-Fix: "Server\Instanz" (SSMS-Format) wird ebenso akzeptiert wie eine reine
		# Instanz - der Windows-Dienstname enthaelt nur die Instanz, ein Server-Praefix fuehrt sonst
		# zu einer ungueltigen WQL-Abfrage (Backslash ist dort ein Escape-Zeichen -> "Invalid query").
		if ($InstanceName -match '\\')
		{
			$InstanceName = $InstanceName.Substring($InstanceName.LastIndexOf('\') + 1)
		}

		$result = [PSCustomObject]@{
			InstanceName		= $InstanceName
			ServiceName		    = $null
			IniPath			    = $null
			DeploymentMode	    = $null
			DeploymentModeValue = $null
			Status			    = 'Error'
			Message			    = $null
		}

		Invoke-sqmLogging -Message "Starte $functionName fuer SSAS-Instanz '$InstanceName'" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
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

			$result.DeploymentMode = $currentModeName
			$result.DeploymentModeValue = $currentValue
			$result.Status  = 'OK'
			$result.Message = "DeploymentMode fuer '$InstanceName' ist '$currentModeName'."
			Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
			Write-Verbose $result.Message
		}
		catch
		{
			$errMsg = "Fehler beim Lesen des DeploymentMode: $($_.Exception.Message)"
			$result.Message = $errMsg
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
		return $result
	}
}
