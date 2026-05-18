<#
    Invoke-sqmHelpers.ps1  -  Private Hilfsfunktionen
    ===========================================================================
    Enthaelt interne Hilfsfunktionen, die von mehreren Public-Funktionen verwendet
    werden. Diese Datei liegt in Private\ und wird nicht exportiert.

    Funktionen:
      Get-sqmDefaultOutputPath  - Liefert den konfigurierten OutputPath (Korrektur #3)
      Format-sqmTimeSpan        - Formatiert Sekunden in lesbare Zeitangabe (Korrektur #4)
      Format-sqmFileSize        - Formatiert Bytes in lesbare Groessenangabe (Korrektur #4)
      Get-sqmSaLogin            - Liefert den Login-Namen des sa-Kontos (SID 0x01)
    ===========================================================================
#>

# KORREKTUR #3: Aus Copy-sqmToCentralPath.ps1 (Public) hierher verschoben
function Get-sqmDefaultOutputPath
{
	$path = Get-sqmConfig -Key 'OutputPath'
	if (-not $path) { $path = 'C:\System\WinSrvLog\MSSQL' }
	return $path
}

# KORREKTUR #4: Aus Get-sqmOperationStatus.ps1 hierher verschoben und mit -sqm- Praefix versehen
function Format-sqmTimeSpan
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[int]$Seconds
	)
	$ts = [TimeSpan]::FromSeconds($Seconds)
	if ($ts.TotalHours -ge 1)
	{
		return "{0}h {1}m {2}s" -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
	}
	elseif ($ts.TotalMinutes -ge 1)
	{
		return "{0}m {1}s" -f $ts.Minutes, $ts.Seconds
	}
	else
	{
		return "{0}s" -f $ts.Seconds
	}
}

function Get-sqmSaLogin
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)
	try
	{
		$row = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
			-Database 'master' `
			-Query "SELECT name FROM sys.server_principals WHERE sid = 0x01" `
			-ErrorAction Stop
		if ($row -and -not [string]::IsNullOrWhiteSpace($row.name)) { return $row.name }
	}
	catch { }
	return $null
}

function Format-sqmFileSize
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[long]$Bytes
	)
	if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
	elseif ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
	elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
	elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
	else { return "$Bytes B" }
}