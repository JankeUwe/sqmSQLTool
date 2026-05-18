<#
	===========================================================================
	 Created with: 	SAPIEN Technologies, Inc., PowerShell Studio 2021 v5.8.183
	 Created on:   	21.04.2026 15:37
	 Created by:   	Janke
	 Organization: 	dtcSoftware
	 Filename:     	sqmSQLTool.psm1
	-------------------------------------------------------------------------
	 Module Name: sqmSQLTool
	===========================================================================
#>

# =============================================================================
# SCHRITT 1: Modulkonfiguration als ERSTES initialisieren
# (muss vor dem Laden der Funktionen und vor Get-sqmConfig-Aufrufen stehen)
# =============================================================================
$script:sqmModuleConfig = @{
	LogPath               = "C:\system\WinSrvLog\MSSQL"
	OutputPath            = "C:\System\WinSrvLog\MSSQL"
	CentralPath           = $null
	OlaJobNameFull        = "FITS-UserDatabases-FULL"
	OlaJobNameDiff        = "FITS-UserDatabases-DIFF"
	OlaJobNameLog         = "FITS-UserDatabases-LOG"
	OlaJobNameIndexOpt    = "FITS IndexOptimize - USER_DATABASES"
	OlaJobNameIntUserDb   = "FITS IntegrityCheck - USER_DATABASES"
	OlaJobNameIntSysDb    = "FITS IntegrityCheck - SYSTEM_DATABASES"
	OlaJobNameSysDbBackup = "FITS-SystemDatabases-FULL"
	BackupDirectory       = $null
	HpuDomainGroupMap     = @()
	SsrsInstallerPath     = $null
	AutoUpdate            = $true
	UpdateRepository      = $null
	ModuleVersion         = '1.0.0'
	Language              = 'de-DE'
}

# Aktuelle Version aus der Manifestdatei lesen
$manifestPath = Join-Path $PSScriptRoot 'sqmSQLTool.psd1'
if (Test-Path $manifestPath)
{
	try
	{
		$manifestData = Import-PowerShellDataFile -Path $manifestPath -ErrorAction Stop
		$script:sqmModuleConfig['ModuleVersion'] = $manifestData.ModuleVersion
	}
	catch { }
}

# Persistierte Konfiguration laden (ueberschreibt Standardwerte)
$configFile = Join-Path $env:APPDATA "MSSQLTools\config.json"
if (Test-Path $configFile)
{
	try
	{
		$userConfig = Get-Content $configFile -Raw | ConvertFrom-Json
		foreach ($key in $userConfig.PSObject.Properties)
		{
			$script:sqmModuleConfig[$key.Name] = $key.Value
		}
	}
	catch
	{
		Write-Warning "Konfiguration konnte nicht geladen werden: $($_.Exception.Message)"
	}
}

# String-Cache invalidieren (wird durch Get-sqmString bei erstem Zugriff neu befuellt)
$script:_strings = $null

# =============================================================================
# SCHRITT 2: dbatools-Verfuegbarkeit pruefen und einmalig laden
# Robuste Pruefung: zuerst bereits geladen, dann expliziter Import-Versuch
# =============================================================================
$script:dbatoolsAvailable = $false

if (Get-Module -Name dbatools)
{
	# dbatools bereits in der Session geladen (z.B. via RequiredModules)
	$script:dbatoolsAvailable = $true
}
else
{
	try
	{
		Import-Module dbatools -ErrorAction Stop
		$script:dbatoolsAvailable = $true
	}
	catch
	{
		# dbatools nicht ladbar  - nur warnen, Modul laedt trotzdem
		$script:dbatoolsAvailable = $false
	}
}

if (-not $script:dbatoolsAvailable)
{
	Write-Warning "dbatools-Modul nicht gefunden. Funktionen die dbatools benoetigen sind nicht verfuegbar. Installation: Install-Module dbatools"
}

# =============================================================================
# SCHRITT 3: Private und Public Funktionen laden
# =============================================================================
$PublicPath  = Join-Path $PSScriptRoot 'Public'
$PrivatePath = Join-Path $PSScriptRoot 'Private'

Get-ChildItem -Path $PrivatePath -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}

Get-ChildItem -Path $PublicPath -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}

# =============================================================================
# SCHRITT 4: Logging-Bereitschaft pruefen (NACH Funktionsladung und Config-Init)
# =============================================================================
$script:sqmLoggingReady = Test-sqmLoggingPath -Path (Get-sqmConfig -Key "LogPath")

# =============================================================================
# SCHRITT 5: Public-Funktionen exportieren
# =============================================================================
$allFunctions = Get-ChildItem -Path $PublicPath -Filter *.ps1 -ErrorAction SilentlyContinue |
                ForEach-Object { $_.BaseName }

foreach ($func in $allFunctions)
{
	if ($func -like "*-sqm*")
	{
		Export-ModuleMember -Function $func
	}
}

# Update-Funktionen explizit exportieren (definiert im PSM1, nicht in Public\)
Export-ModuleMember -Function 'Test-sqmModuleUpdate', 'Update-sqmModule'

# =============================================================================
# Update-Mechanismus
# =============================================================================

<#
.SYNOPSIS
    Prueft ob eine neuere Version des MSSQLTools-Moduls im konfigurierten Repository verfuegbar ist.
.PARAMETER RepositoryPath
    Pfad zum Update-Repository (ueberschreibt die Konfiguration).
.PARAMETER Credential
    Credentials fuer UNC-Freigaben.
#>
function Test-sqmModuleUpdate
{
	[CmdletBinding()]
	param (
		[string]$RepositoryPath = $script:sqmModuleConfig['UpdateRepository'],
		[System.Management.Automation.PSCredential]$Credential
	)
	if (-not $RepositoryPath)
	{
		Write-Verbose "Kein Update-Repository konfiguriert."
		return $false
	}
	try
	{
		$remoteVersionFile = Join-Path $RepositoryPath 'ModuleVersion.txt'
		if (Test-Path -Path $remoteVersionFile -ErrorAction SilentlyContinue)
		{
			$remoteVersion = (Get-Content -Path $remoteVersionFile -ErrorAction Stop).Trim()
		}
		else
		{
			$remoteManifest = Join-Path $RepositoryPath 'sqmSQLTool.psd1'
			if (Test-Path -Path $remoteManifest -ErrorAction SilentlyContinue)
			{
				$remoteData = Import-PowerShellDataFile -Path $remoteManifest -ErrorAction Stop
				$remoteVersion = $remoteData.ModuleVersion
			}
			else
			{
				Write-Verbose "Keine Versionsinformation im Repository gefunden."
				return $false
			}
		}
		$currentVersion = [version]$script:sqmModuleConfig['ModuleVersion']
		$newVersion     = [version]$remoteVersion
		return $newVersion -gt $currentVersion
	}
	catch
	{
		Write-Warning "Update-Pruefung fehlgeschlagen: $($_.Exception.Message)"
		return $false
	}
}

<#
.SYNOPSIS
    Aktualisiert das MSSQLTools-Modul aus dem konfigurierten Repository.
.PARAMETER RepositoryPath
    Pfad zum Update-Repository.
.PARAMETER Credential
    Credentials fuer UNC-Freigaben.
.PARAMETER Backup
    Sicherung vor dem Update erstellen (Standard: $true).
.PARAMETER Force
    Update auch ohne neuere Version erzwingen.
#>
function Update-sqmModule
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param (
		[string]$RepositoryPath = $script:sqmModuleConfig['UpdateRepository'],
		[System.Management.Automation.PSCredential]$Credential,
		[switch]$Backup = $true,
		[switch]$Force
	)
	$currentModulePath = $PSScriptRoot
	if (-not $RepositoryPath)
	{
		Write-Error "Kein Update-Repository konfiguriert. Bitte Set-sqmConfig -UpdateRepository <Pfad> ausfuehren."
		return
	}
	if (-not (Test-Path -Path $RepositoryPath -ErrorAction SilentlyContinue))
	{
		Write-Error "Repository-Pfad '$RepositoryPath' nicht erreichbar."
		return
	}
	if (-not $Force -and -not (Test-sqmModuleUpdate -RepositoryPath $RepositoryPath))
	{
		Write-Host "Keine neuere Version verfuegbar." -ForegroundColor Green
		return
	}
	if ($PSCmdlet.ShouldProcess("Modul aus '$RepositoryPath' aktualisieren", "Update"))
	{
		try
		{
			if ($Backup)
			{
				$backupDir = Join-Path $env:TEMP "MSSQLTools_Backup_$(Get-Date -Format 'yyyyMMdd_HHmsqm')"
				Copy-Item -Path $currentModulePath -Destination $backupDir -Recurse -Force -ErrorAction Stop
				Write-Host "Backup erstellt: $backupDir" -ForegroundColor Gray
			}
			Get-ChildItem -Path $RepositoryPath -Recurse -File | ForEach-Object {
				$relativePath = $_.FullName.Substring($RepositoryPath.Length).TrimStart('\')
				$targetFile   = Join-Path $currentModulePath $relativePath
				$targetDir    = Split-Path $targetFile -Parent
				if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
				Copy-Item -Path $_.FullName -Destination $targetFile -Force -ErrorAction Stop
			}
			Write-Host "Modul wurde aktualisiert." -ForegroundColor Green
			Write-Warning "Bitte PowerShell neu starten oder 'Remove-Module sqmSQLTool; Import-Module sqmSQLTool' ausfuehren."
		}
		catch
		{
			Write-Error "Update fehlgeschlagen: $($_.Exception.Message)"
		}
	}
	else
	{
		Write-Host "Update abgebrochen." -ForegroundColor Yellow
	}
}

# Automatisches Update beim Modulimport (nur wenn AutoUpdate = $true und Repository konfiguriert)
if ($script:sqmModuleConfig['AutoUpdate'] -and $script:sqmModuleConfig['UpdateRepository'])
{
	$noUpdate = $env:MSSQLTOOLS_SKIP_AUTO_UPDATE -eq '1'
	if (-not $noUpdate)
	{
		try
		{
			if (Test-sqmModuleUpdate)
			{
				Write-Host "Neue Modulversion verfuegbar. Fuehre Update durch..." -ForegroundColor Cyan
				Update-sqmModule -Force -Backup
			}
		}
		catch
		{
			Write-Warning "Automatische Update-Pruefung fehlgeschlagen: $($_.Exception.Message)"
		}
	}
}
