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
# Neutrale Standardwerte fuer PSGallery-Nutzer.
# FI-TS-spezifische Werte werden in Schritt 1b gesetzt wenn erkannt.
# =============================================================================
$script:sqmModuleConfig = @{
	LogPath               = "$env:ProgramData\sqmSQLTool\Logs"
	OutputPath            = "$env:ProgramData\sqmSQLTool\Logs"
	CentralPath           = $null
	OlaJobNameFull        = "OlaHH-UserDatabases-FULL"
	OlaJobNameDiff        = "OlaHH-UserDatabases-DIFF"
	OlaJobNameLog         = "OlaHH-UserDatabases-LOG"
	OlaJobNameIndexOpt    = "OlaHH IndexOptimize - USER_DATABASES"
	OlaJobNameIntUserDb   = "OlaHH IntegrityCheck - USER_DATABASES"
	OlaJobNameIntSysDb    = "OlaHH IntegrityCheck - SYSTEM_DATABASES"
	OlaJobNameSysDbBackup = "OlaHH-SystemDatabases-FULL"
	BackupDirectory       = $null
	HpuDomainGroupMap     = @()
	SsrsInstallerPath     = $null
	AutoUpdate            = $false
	UpdateRepository      = ''
	ModuleVersion         = '1.0.0'
	Language              = 'de-DE'
	# Check-Profil: 'Auto' = FI-TS wenn erkannt, 'FiTs' = immer, 'Generic' = nie FI-TS-Checks
	CheckProfile          = 'Auto'
	# Grenzwerte fuer Setup-Checks (neutrale Defaults, FI-TS-Block setzt gleiche Werte)
	CheckCostThresholdMin = 50
	CheckTempDbMaxFiles   = 8
	CheckDiskBlockSize    = 65536
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

# =============================================================================
# SCHRITT 1b: FI-TS-Umgebungserkennung
# Kriterium 1: Modul liegt auf W:\ (FI-TS Netzlaufwerk)
# Kriterium 2: Angemeldeter Benutzer ist in Domaene OFFICELAN.IZB / OFFICELAN
# Wenn erkannt: FI-TS-Standardwerte setzen (config.json ueberschreibt weiterhin).
# =============================================================================
$script:sqmIsFitsEnvironment = $false

if ($PSScriptRoot -like 'W:\*' -or $PSScriptRoot -like '\\tsclient\W\*')
{
	$script:sqmIsFitsEnvironment = $true
	Write-Verbose "sqmSQLTool: FI-TS-Umgebung erkannt (Modulpfad: $PSScriptRoot)."
}

if (-not $script:sqmIsFitsEnvironment)
{
	$_dnsDomain  = $env:USERDNSDOMAIN
	$_userDomain = $env:USERDOMAIN
	if (($_dnsDomain  -and $_dnsDomain  -eq 'OFFICELAN.IZB') -or
		($_userDomain -and $_userDomain -eq 'OFFICELAN'))
	{
		$script:sqmIsFitsEnvironment = $true
		Write-Verbose "sqmSQLTool: FI-TS-Umgebung erkannt (Domaene: $_dnsDomain / $_userDomain)."
	}
}

if ($script:sqmIsFitsEnvironment)
{
	$script:sqmModuleConfig['LogPath']                = 'C:\System\WinSrvLog\MSSQL'
	$script:sqmModuleConfig['OutputPath']             = 'C:\System\WinSrvLog\MSSQL'
	$script:sqmModuleConfig['AutoUpdate']             = $true
	$script:sqmModuleConfig['UpdateRepository']       = 'W:\75084-Datenbanken\MSSQL\CPM\sqmSQLTool'
	$script:sqmModuleConfig['TsmManagementClasses']   = @('MC_B_NL.NL_35.35.NA')
	$script:sqmModuleConfig['DefaultPolicy']          = 'New Login_Enforce Passwort Policy'
	$script:sqmModuleConfig['SsrsInstallerPath']      = 'W:\75084-Datenbanken\MSSQL\SQLSources\Reporting'
	$script:sqmModuleConfig['OlaJobNameFull']         = 'FITS-UserDatabases-FULL'
	$script:sqmModuleConfig['OlaJobNameDiff']         = 'FITS-UserDatabases-DIFF'
	$script:sqmModuleConfig['OlaJobNameLog']          = 'FITS-UserDatabases-LOG'
	$script:sqmModuleConfig['OlaJobNameIndexOpt']     = 'FITS IndexOptimize - USER_DATABASES'
	$script:sqmModuleConfig['OlaJobNameIntUserDb']    = 'FITS IntegrityCheck - USER_DATABASES'
	$script:sqmModuleConfig['OlaJobNameIntSysDb']     = 'FITS IntegrityCheck - SYSTEM_DATABASES'
	$script:sqmModuleConfig['OlaJobNameSysDbBackup']  = 'FITS-SystemDatabases-FULL'
	# FI-TS Check-Profil und Grenzwerte (identisch mit Defaults, explizit gesetzt fuer Ueberschreibbarkeit)
	$script:sqmModuleConfig['CheckProfile']           = 'FiTs'
	$script:sqmModuleConfig['CheckCostThresholdMin']  = 50
	$script:sqmModuleConfig['CheckTempDbMaxFiles']    = 8
	$script:sqmModuleConfig['CheckDiskBlockSize']     = 65536
}

# =============================================================================
# SCHRITT 1c: Persistierte Konfiguration laden (ueberschreibt alle Standardwerte)
# =============================================================================
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
# SCHRITT 5: Public-Funktionen + Update-Funktionen exportieren
# =============================================================================
# WICHTIG: Nur EIN Export-ModuleMember Aufruf! Mehrere Aufrufe überschreiben sich.

# SCHRITT 5: Wird am Ende der Datei (nach allen Funktionsdefinitionen) ausgeführt
# Export aller Funktionen nach Laden — siehe Zeile ~650

# =============================================================================
# Update-Mechanismus mit Fallback-Chain
# =============================================================================
# Priorität:
#   1. PowerShell Gallery (PSGallery)
#   2. GitHub Releases (fallback)
#   3. UNC-Pfad (fallback)
#   4. Warnung ausgeben wenn alle fehlschlagen

<#
.SYNOPSIS
    Prueft ob eine neuere Version des Moduls in PowerShell Gallery verfuegbar ist.
.PARAMETER ModuleName
    Name des Moduls (Standard: sqmSQLTool).
#>
function Test-InternetConnectivity
{
	<#
	.SYNOPSIS
	    Prüft ob eine Internetverbindung zu PowerShell Gallery vorhanden ist.
	.DESCRIPTION
	    Schneller, non-blocking Check ohne NuGet-Installation zu erzwingen.
	    Versucht DNS-Auflösung (schnell) und optional HTTP-Verbindung (mit Timeout).
	#>
	param(
		[int]$TimeoutMs = 3000
	)

	try
	{
		# Schneller DNS-Check (funktioniert meist offline auch nicht)
		$dnsTest = @{
			Server = 'www.powershellgallery.com'
			ErrorAction = 'Stop'
		}
		$null = [System.Net.Dns]::GetHostEntry($dnsTest.Server)
		return $true
	}
	catch
	{
		Write-Verbose "Keine Internetverbindung erkannt (DNS-Auflösung fehlgeschlagen)"
		return $false
	}
}

function Test-sqmModuleUpdate-PSGallery
{
	[CmdletBinding()]
	param ([string]$ModuleName = 'sqmSQLTool')

	# === FLEXIBLE LÖSUNG: Prüfe zuerst Internetverbindung ===
	# Wenn kein Internet -> kein NuGet-Hang, direkt Fallback
	if (-not (Test-InternetConnectivity))
	{
		Write-Verbose "Keine Internetverbindung: PSGallery-Check übersprungen"
		return $null
	}

	try
	{
		$galleryModule = Find-Module -Name $ModuleName -Repository PSGallery -ErrorAction Stop
		$currentVersion = [version]$script:sqmModuleConfig['ModuleVersion']
		$galleryVersion = [version]$galleryModule.Version

		if ($galleryVersion -gt $currentVersion)
		{
			Write-Verbose "PSGallery: Neuere Version verfuegbar ($($galleryModule.Version))"
			return @{
				Source = 'PSGallery'
				Version = $galleryVersion
				UpdateCommand = "Update-Module -Name $ModuleName -Repository PSGallery -Force"
			}
		}
		return $null
	}
	catch
	{
		Write-Verbose "PSGallery-Check fehlgeschlagen: $($_.Exception.Message)"
		return $null
	}
}

<#
.SYNOPSIS
    Prueft ob eine neuere Version auf GitHub Releases verfuegbar ist.
.PARAMETER GitHubRepo
    GitHub Repository (Format: owner/repo, z.B. JankeUwe/sqmSQLTool).
#>
function Test-sqmModuleUpdate-GitHub
{
	[CmdletBinding()]
	param ([string]$GitHubRepo = 'JankeUwe/sqmSQLTool')

	try
	{
		$latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubRepo/releases/latest" `
			-Headers @{'Accept' = 'application/vnd.github+json'} `
			-ErrorAction Stop

		# Version aus Tag extrahieren (v1.4.0.0 -> 1.4.0.0)
		$tagVersion = $latestRelease.tag_name -replace '^v', ''
		$currentVersion = [version]$script:sqmModuleConfig['ModuleVersion']
		$releaseVersion = [version]$tagVersion

		if ($releaseVersion -gt $currentVersion)
		{
			Write-Verbose "GitHub: Neuere Version verfuegbar ($tagVersion)"
			return @{
				Source = 'GitHub'
				Version = $releaseVersion
				URL = $latestRelease.html_url
				UpdateCommand = "# ZIP von $($latestRelease.html_url) herunterladen und manuell entpacken"
			}
		}
		return $null
	}
	catch
	{
		Write-Verbose "GitHub-Check fehlgeschlagen: $($_.Exception.Message)"
		return $null
	}
}

<#
.SYNOPSIS
    Prueft ob eine neuere Version im UNC-Pfad verfuegbar ist.
.PARAMETER RepositoryPath
    UNC-Pfad zum Repository.
#>
function Test-sqmModuleUpdate-UNC
{
	[CmdletBinding()]
	param ([string]$RepositoryPath = $script:sqmModuleConfig['UpdateRepository'])

	try
	{
		if (-not $RepositoryPath)
		{
			Write-Verbose "Kein UNC-Repository konfiguriert."
			return $null
		}

		if (-not (Test-Path -Path $RepositoryPath -ErrorAction SilentlyContinue))
		{
			Write-Verbose "UNC-Repository nicht erreichbar: $RepositoryPath"
			return $null
		}

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
				Write-Verbose "Keine Versionsinformation im UNC-Repository gefunden."
				return $null
			}
		}

		$currentVersion = [version]$script:sqmModuleConfig['ModuleVersion']
		$newVersion     = [version]$remoteVersion

		if ($newVersion -gt $currentVersion)
		{
			Write-Verbose "UNC: Neuere Version verfuegbar ($newVersion)"
			return @{
				Source = 'UNC'
				Version = $newVersion
				Path = $RepositoryPath
				UpdateCommand = "Update-sqmModule -RepositoryPath '$RepositoryPath'"
			}
		}
		return $null
	}
	catch
	{
		Write-Verbose "UNC-Check fehlgeschlagen: $($_.Exception.Message)"
		return $null
	}
}

<#
.SYNOPSIS
    Prueft ob eine neuere Version des Moduls verfuegbar ist (Fallback-Chain: PSGallery -> GitHub -> UNC).
.PARAMETER Credential
    Credentials fuer UNC-Freigaben.
#>
function Test-sqmModuleUpdate
{
	[CmdletBinding()]
	param (
		[System.Management.Automation.PSCredential]$Credential
	)

	# Fallback-Chain: PSGallery -> GitHub -> UNC
	$updateResult = Test-sqmModuleUpdate-PSGallery -ModuleName 'sqmSQLTool'
	if ($updateResult) { return $updateResult }

	$updateResult = Test-sqmModuleUpdate-GitHub -GitHubRepo 'JankeUwe/sqmSQLTool'
	if ($updateResult) { return $updateResult }

	$updateResult = Test-sqmModuleUpdate-UNC -RepositoryPath $script:sqmModuleConfig['UpdateRepository']
	if ($updateResult) { return $updateResult }

	# Keine neuere Version in keinem Repository gefunden
	return $null
}

<#
.SYNOPSIS
    Aktualisiert das sqmSQLTool-Modul (nur UNC-Repositories unterstuezt; PSGallery/GitHub sind manuell).
.PARAMETER RepositoryPath
    Pfad zum Update-Repository (UNC-Pfad).
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

	$updateInfo = Test-sqmModuleUpdate-UNC -RepositoryPath $RepositoryPath
	if (-not $Force -and -not $updateInfo)
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
				$backupDir = Join-Path $env:TEMP "sqmSQLTool_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
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

# Auto-update on module import (only when AutoUpdate = $true)
# === FLEXIBLE: Vollständige Fallback-Chain (PSGallery wird automat. übersprungen wenn offline) ===
if ($script:sqmModuleConfig['AutoUpdate'])
{
	$noUpdate = $env:SQMSQLTOOL_SKIP_AUTO_UPDATE -eq '1'
	if (-not $noUpdate)
	{
		try
		{
			# Vollständige Fallback-Chain: PSGallery (wenn online) -> GitHub -> UNC
			# PSGallery wird automatisch übersprungen wenn kein Internet erkannt
			$updateInfo = Test-sqmModuleUpdate
			if ($updateInfo)
			{
				Write-Host "`n[sqmSQLTool] Neuere Version verfuegbar: $($updateInfo.Version) (via $($updateInfo.Source))" -ForegroundColor Cyan

				if ($updateInfo.Source -eq 'UNC')
				{
					# UNC: Automatisches Update
					Write-Host "[sqmSQLTool] Fuehre Update durch..." -ForegroundColor Cyan
					Update-sqmModule -Force -Backup
				}
				elseif ($updateInfo.Source -eq 'PSGallery')
				{
					# PSGallery: Hinweis auf Update-Module
					Write-Warning @"
[sqmSQLTool] Update verfuegbar in PowerShell Gallery!

Zum Aktualisieren bitte ausfuehren:
  Update-Module -Name sqmSQLTool -Repository PSGallery -Force

Oder via Install-Module:
  Install-Module -Name sqmSQLTool -Repository PSGallery -Force -AllowClobber
"@
				}
				elseif ($updateInfo.Source -eq 'GitHub')
				{
					# GitHub: Hinweis auf GitHub Release
					Write-Warning @"
[sqmSQLTool] Update verfuegbar auf GitHub!

Release: $($updateInfo.URL)

Zum Aktualisieren:
1. ZIP herunterladen von: $($updateInfo.URL)/releases/download/v$($updateInfo.Version)/sqmSQLTool-v$($updateInfo.Version).zip
2. Entpacken nach: `$PROFILE\..\Modules\sqmSQLTool\
3. PowerShell neu starten oder: Remove-Module sqmSQLTool; Import-Module sqmSQLTool
"@
				}
			}
		}
		catch
		{
			Write-Verbose "Auto-update check failed: $($_.Exception.Message)"
		}
	}

# =============================================================================
# SCHRITT 5: Export aller Funktionen (nach allen Definitionen)
# Exportiert ALLE Funktionen, die durch dot-sourcing geladen wurden
# =============================================================================
Export-ModuleMember -Function '*'
}
