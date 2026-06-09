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
      Get-sqmMachineType        - VM/Hardware-Erkennung (IsVM, MachineType)
      Get-sqmReportReference    - Standard-Referenzzeile (www.powershelldba.de)
      Invoke-sqmOpenReport      - Oeffnet Report (HTML vor TXT, nie CSV, -NoOpen)
      ConvertTo-sqmHtmlReport   - HTML-Geruest im sqmSQLTool-Theme
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

# ===========================================================================
# Report-Helper (Maschinentyp, Referenzzeile, Auto-Open, HTML-Geruest)
# Gemeinsam genutzt von allen Report-erzeugenden Public-Funktionen.
# ===========================================================================

# Ermittelt ob der Zielcomputer eine VM oder physische Hardware ist.
# Logik zentral, damit Get-sqmServerHardwareReport und Get-sqmDiskInfoByDriveLetter
# (und kuenftige Funktionen) dieselbe Erkennung nutzen.
function Get-sqmMachineType
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential
	)

	$isVM   = $false
	$vmType = 'Physisch'

	try
	{
		$cimParams = @{ ClassName = 'Win32_ComputerSystem'; ErrorAction = 'Stop' }
		if ($ComputerName -ne $env:COMPUTERNAME) { $cimParams['ComputerName'] = $ComputerName }
		if ($Credential) { $cimParams['Credential'] = $Credential }
		$cs = Get-CimInstance @cimParams

		$biosParams = @{ ClassName = 'Win32_BIOS'; ErrorAction = 'SilentlyContinue' }
		if ($ComputerName -ne $env:COMPUTERNAME) { $biosParams['ComputerName'] = $ComputerName }
		if ($Credential) { $biosParams['Credential'] = $Credential }
		$bios = Get-CimInstance @biosParams

		$model = if ($cs)   { [string]$cs.Model }              else { '' }
		$mfr   = if ($cs)   { [string]$cs.Manufacturer }       else { '' }
		$biosV = if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { '' }

		if    (($model -match 'Virtual Machine' -or $biosV -match 'VRTUAL') -and $mfr -match 'Microsoft')
			{ $isVM = $true; $vmType = 'Hyper-V' }
		elseif ($model -match 'VMware'     -or $biosV -match 'VMWARE' -or $mfr -match 'VMware')
			{ $isVM = $true; $vmType = 'VMware' }
		elseif ($model -match 'VirtualBox' -or $biosV -match 'VBOX')
			{ $isVM = $true; $vmType = 'VirtualBox' }
		elseif ($mfr   -match 'QEMU'       -or $model -match 'KVM')
			{ $isVM = $true; $vmType = 'KVM/QEMU' }
	}
	catch
	{
		$vmType = 'Unbekannt'
	}

	return [PSCustomObject]@{
		ComputerName = $ComputerName
		IsVM         = $isVM
		MachineType  = $vmType
	}
}

# Liefert die Standard-Referenzzeile fuer Report-Header (TXT und HTML).
function Get-sqmReportReference
{
	[CmdletBinding()]
	param ()
	$ver = Get-sqmConfig -Key 'ModuleVersion'
	if (-not $ver) { $ver = '' }
	$verPart = if ($ver) { " v$ver" } else { '' }
	return "Quelle: www.powershelldba.de | sqmSQLTool$verPart"
}

# Oeffnet den erzeugten Report. Regel: HTML hat Vorrang, sonst TXT.
# CSV wird NIE automatisch geoeffnet (wuerde Excel starten).
# -NoOpen unterdrueckt das Oeffnen vollstaendig.
function Invoke-sqmOpenReport
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$HtmlFile,
		[Parameter(Mandatory = $false)]
		[string]$TxtFile,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)
	if ($NoOpen) { return }

	$target = $null
	if ($HtmlFile -and (Test-Path $HtmlFile))      { $target = $HtmlFile }
	elseif ($TxtFile -and (Test-Path $TxtFile))    { $target = $TxtFile }

	if ($target)
	{
		try   { Start-Process $target | Out-Null }
		catch { Write-Verbose "Report konnte nicht geoeffnet werden: $($_.Exception.Message)" }
	}
}

# Baut ein vollstaendiges HTML-Dokument im sqmSQLTool-Theme.
# Header enthaelt Titel + Referenzzeile (www.powershelldba.de),
# Footer enthaelt powershelldba.de + Zeitstempel.
function ConvertTo-sqmHtmlReport
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Title,
		[Parameter(Mandatory = $true)]
		[string]$BodyHtml,
		[Parameter(Mandatory = $false)]
		[string]$Subtitle = ''
	)

	$reference = Get-sqmReportReference
	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

	# Minimaler HtmlEncode-Helper (kein System.Web noetig)
	$encTitle = $Title    -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
	$encSub   = $Subtitle -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
	$encRef   = $reference -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'

	$subHtml = if ($encSub) { "<div class='sub'>$encSub</div>" } else { '' }

	return @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>$encTitle</title>
<style>
body { font-family: 'Segoe UI', Arial, sans-serif; background: #060f20; color: #e2e8f0; font-size: 13px; margin: 0; }
.hdr { background: linear-gradient(160deg,#060f20 0%,#0b1e3d 100%); padding: 24px 32px; border-bottom: 1px solid #1e3a5f; }
.hdr h1 { margin: 0 0 4px 0; font-size: 22px; color: #5dade2; }
.hdr .sub { color: #94a8c0; font-size: 13px; }
.hdr .ref { color: #5dade2; font-size: 12px; margin-top: 6px; }
.wrap { padding: 20px 32px; }
table { width: 100%; border-collapse: collapse; background: #0d1f38; margin-bottom: 18px; }
th { background: #0b1e3d; color: #94a8c0; font-size: 11px; font-weight: 600; text-transform: uppercase; padding: 8px 10px; text-align: left; border-bottom: 1px solid #1e3a5f; }
td { padding: 7px 10px; border-bottom: 1px solid #14283f; }
tr:hover { background: rgba(45,134,193,0.05); }
.ok   { color: #2ecc71; }
.warn { color: #f1c40f; }
.crit { color: #e74c3c; font-weight: 600; }
.footer { padding: 14px 32px; border-top: 1px solid #1e3a5f; color: #94a8c0; font-size: 12px; }
.footer a { color: #5dade2; text-decoration: none; }
</style>
</head>
<body>
<div class="hdr">
  <h1>$encTitle</h1>
  $subHtml
  <div class="ref">$encRef</div>
</div>
<div class="wrap">
$BodyHtml
</div>
<div class="footer">
  sqmSQLTool &nbsp;|&nbsp; dtcSoftware / Uwe Janke &nbsp;|&nbsp; <a href="https://www.powershelldba.de">www.powershelldba.de</a>
  &nbsp;&nbsp;&ndash;&nbsp;&nbsp; $timestamp
</div>
</body>
</html>
"@
}