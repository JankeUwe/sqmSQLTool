<#
.SYNOPSIS
Liest eine oder alle Server-Eigenschaften aus den Server-Properties einer SQL Server-Instanz.

.DESCRIPTION
Die Funktion fragt entweder einen benannten Eigenschaftswert (z.B. "BackupDirectory") aus dem
von Connect-DbaInstance  zurueckgegebenen Objekt ab, oder listet mit -All alle Eigenschaften auf.

Wenn kein SqlInstance-Parameter angegeben wird, wird standardmaessig der aktuelle
Computername ($env:COMPUTERNAME) verwendet. Diese Regel gilt fuer alle zukuenftigen
Versionen.

.PARAMETER SqlInstance
Die Ziel-SQL Server-Instanz (z.B. "localhost", "SQL01\INSTANCE").
Wenn nicht angegeben, wird der aktuelle Computername verwendet.

.PARAMETER SqlCredential
Alternative Anmeldeinformationen (PSCredential). Wenn nicht angegeben, wird
Windows-Authentifizierung verwendet.

.PARAMETER Name
Der Name der gesuchten Server-Eigenschaft. Nur folgende Werte sind erlaubt:
BackupDirectory, DefaultFile, DefaultLog, MasterDBPath, ErrorLogPath, ComputerName,
InstanceName, Edition, VersionString, ProductLevel, ProductUpdateLevel, HostPlatform,
IsClustered, IsHadrEnabled.

.PARAMETER All
Wenn gesetzt, werden alle Eigenschaften des Server-Objekts als Liste zurueckgegeben.

.PARAMETER DefaultValue
Optionaler Default-Wert, falls die Eigenschaft nicht existiert oder nicht gelesen
werden kann. Wird bei -All ignoriert.

.PARAMETER EnableException
Schalter, um Ausnahmen durchzulassen (standardmaessig werden Fehler als Warnung
protokolliert).

.EXAMPLE
# BackupDirectory vom lokalen Server lesen
$backupPath = Get-sqmServerSetting -Name "BackupDirectory"

.EXAMPLE
# Alle Eigenschaften anzeigen
Get-sqmServerSetting -All

.EXAMPLE
# Alle Eigenschaften einer entfernten Instanz mit Credentials
$cred = Get-Credential
Get-sqmServerSetting -SqlInstance "SQL01" -SqlCredential $cred -All

.NOTES
Erfordert dbatools-Modul und eine vorhandene Funktion Invoke-sqmLogging.
Default fuer SqlInstance: $env:COMPUTERNAME (gilt fuer alle zukuenftigen Versionen).
Verwendet Connect-DbaInstance , um das Serverobjekt abzurufen.
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