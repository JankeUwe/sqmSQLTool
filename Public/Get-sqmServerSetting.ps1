<#
.SYNOPSIS
Reads one or all server properties from a SQL Server instance.

.DESCRIPTION
The function queries either a named property value (e.g. "BackupDirectory") from the
object returned by Connect-DbaInstance, or lists all properties with -All.

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME)
is used by default.

.PARAMETER SqlInstance
The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.

.PARAMETER SqlCredential
Alternative credentials (PSCredential). If not specified,
Windows Authentication is used.

.PARAMETER Name
The name of the server property to retrieve. Only the following values are allowed:
BackupDirectory, DefaultFile, DefaultLog, MasterDBPath, ErrorLogPath, ComputerName,
InstanceName, Edition, VersionString, ProductLevel, ProductUpdateLevel, HostPlatform,
IsClustered, IsHadrEnabled.

.PARAMETER All
When set, all properties of the server object are returned as a list.

.PARAMETER DefaultValue
Optional default value if the property does not exist or cannot be read.
Ignored when -All is used.

.PARAMETER EnableException
Switch to allow exceptions to pass through (by default errors are logged as warnings).

.EXAMPLE
# Read BackupDirectory from the local server
$backupPath = Get-sqmServerSetting -Name "BackupDirectory"

.EXAMPLE
# Show all properties
Get-sqmServerSetting -All

.EXAMPLE
# All properties from a remote instance with credentials
$cred = Get-Credential
Get-sqmServerSetting -SqlInstance "SQL01" -SqlCredential $cred -All

.NOTES
Requires dbatools module and an existing Invoke-sqmLogging function.
Default for SqlInstance: $env:COMPUTERNAME.
Uses Connect-DbaInstance to retrieve the server object.
#>

function Get-sqmServerSetting
{
	[CmdletBinding(DefaultParameterSetName = 'Name', SupportsShouldProcess = $false)]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true, ParameterSetName = 'Name', Position = 1)]
		[ValidateSet('BackupDirectory', 'DefaultFile', 'DefaultLog', 'MasterDBPath',
					 'ErrorLogPath', 'ComputerName', 'InstanceName', 'Edition',
					 'VersionString', 'ProductLevel', 'ProductUpdateLevel',
					 'HostPlatform', 'IsClustered', 'IsHadrEnabled')]
		[string]$Name,
		[Parameter(Mandatory = $true, ParameterSetName = 'All')]
		[switch]$All,
		[Parameter(Mandatory = $false, ParameterSetName = 'Name')]
		[string]$DefaultValue,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		
		# Default fuer SqlInstance: aktueller Computername
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}
		
		# Pruefung auf dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		if ($All)
		{
			Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance im Modus '-All'." -FunctionName $functionName -Level "INFO"
		}
		else
		{
			Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance fuer Eigenschaft '$Name'" -FunctionName $functionName -Level "INFO"
		}
	}
	
	process
	{
		try
		{
			$serverParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				ErrorAction   = 'Stop'
			}
			if ($EnableException)
			{
				$serverParams.EnableException = $true
			}
			
			Invoke-sqmLogging -Message "Rufe Server-Objekt ueber Connect-DbaInstance  ab." -FunctionName $functionName -Level "DEBUG"
			$server = Connect-DbaInstance  @serverParams
			
			if (-not $server)
			{
				$msg = "Konnte kein Server-Objekt fuer $SqlInstance abrufen."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}
			
			if ($All)
			{
				# Alle Eigenschaften sammeln
				$allProperties = $server.PSObject.Properties | Where-Object { $_.Name -notin @('PsObject', 'Adapted', 'Extended', 'MemberType', 'IsSettable', 'TypeNameOfValue') } | Sort-Object Name
				$results = @()
				foreach ($prop in $allProperties)
				{
					$value = $prop.Value
					# Konvertiere null-Werte in leere Strings fuer bessere Lesbarkeit
					if ($null -eq $value) { $value = '' }
					$results += [PSCustomObject]@{
						Name = $prop.Name
						Value = $value
						Type = if ($prop.Value) { $prop.Value.GetType().Name } else { 'null' }
					}
				}
				Invoke-sqmLogging -Message "$($results.Count) Eigenschaften vom Server-Objekt abgerufen." -FunctionName $functionName -Level "INFO"
				return $results
			}
			else
			{
				# Einzelne Eigenschaft mit ValidateSet - hier ist sicher, dass die Eigenschaft existiert
				$settingValue = $server.$Name
				Invoke-sqmLogging -Message "Eigenschaft '$Name' gefunden mit Wert: $settingValue" -FunctionName $functionName -Level "INFO"
				return $settingValue
			}
		}
		catch
		{
			$errMsg = "Fehler beim Lesen der Eigenschaft: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException)
			{
				throw
			}
			else
			{
				Write-Error $errMsg
				return $null
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}