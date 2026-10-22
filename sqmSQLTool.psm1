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
# Standortspezifische Werte kommen aus dem optionalen Standort-Profil (Schritt 1c).
# =============================================================================
$script:sqmModuleConfig = @{
	LogPath               = "C:\System\WinSrvLog\MSSQL"
	OutputPath            = "C:\System\WinSrvLog\MSSQL"
	CentralPath           = $null
	OlaJobNameFull                = "OlaHH-UserDatabases-FULL"
	OlaJobNameDiff                = "OlaHH-UserDatabases-DIFF"
	OlaJobNameLog                 = "OlaHH-UserDatabases-LOG"
	OlaJobNameIndexOpt            = "OlaHH IndexOptimize - USER_DATABASES"
	OlaJobNameIntUserDb           = "OlaHH IntegrityCheck - USER_DATABASES"
	OlaJobNameIntSysDb            = "OlaHH IntegrityCheck - SYSTEM_DATABASES"
	OlaJobNameSysDbBackup         = "OlaHH-SystemDatabases-FULL"
	OlaJobNameOutputCleanup       = "DatabaseMaintenance-Output File Cleanup"
	OlaJobNamePurgeJobHistory     = "DatabaseMaintenance-sp_purge_jobhistory"
	OlaJobNameDeleteBackupHistory = "DatabaseMaintenance-sp_delete_backuphistory"
	# Sync-Job der Backup-Ausschlusstabelle (New-sqmOlaUsrDbBackupJob -UseExcludeTable)
	OlaJobNameBackupExcludeSync   = "sqm BackupExclude - SYNC"
	# Registry-Unterschluessel unter HKLM:\<RegistryBase>\ fuer Invoke-sqmMonitoringKey
	MonitoringRegistrySubKey      = "sqmSQLTool\SystemCenter"
	BackupDirectory       = $null
	# Aufbewahrung der Restore-Test-Nachweise (Monate). Nachweise sind Auditmaterial und
	# muessen ueber den Pruefzeitraum verfuegbar bleiben - Default 12 Monate. 0 = unbegrenzt
	# aufbewahren (nie aufraeumen).
	RestoreTestRetentionMonths = 12
	HpuDomainGroupMap     = @()
	# Namen von Objekten (Tabellen/Views/Prozeduren/Functions), die in master erwartet werden
	# und von Get-/Remove-sqmMasterDbCustomObjects NIE als "versehentlich angelegt" gemeldet
	# oder entfernt werden - Standard-Wartungsskripte (Ola Hallengren, Brent Ozar sp_Blitz*,
	# sp_WhoIsActive) sowie sp_BackRestRemain. CommandLog ist Ola Hallengrens Log-Tabelle
	# (landet standardmaessig in master, siehe Test-sqmOlaInstallation), keine Prozedur -
	# gehoert trotzdem auf die Whitelist. Wildcards ('sp_Blitz*') sind erlaubt.
	MasterDbObjectWhitelist = @(
		'sp_Blitz', 'sp_BlitzBackups', 'sp_BlitzCache', 'sp_BlitzFirst', 'sp_BlitzIndex',
		'sp_BlitzLock', 'sp_BlitzWho', 'CommandExecute', 'CommandLog', 'DatabaseBackup',
		'DatabaseIntegrityCheck', 'IndexOptimize', 'sp_WhoIsActive', 'sp_BackRestRemain'
	)
	SsrsInstallerPath     = $null
	# Freigabelaufwerk mit einer vorab gepackten dbatools + dbatools.library-Baseline, fuer
	# Umgebungen ohne PSGallery-Zugriff (siehe Install.ps1 Schritt 5b). $null = PSGallery nutzen.
	DbatoolsSharePath     = $null
	# Update-Pruefung beim Modulstart: 'Prompt' = neuere Version anbieten (Standard),
	# 'Auto' = ohne Rueckfrage installieren, 'Off' = nicht pruefen.
	# AutoUpdate ist der Vorgaenger: ein persistiertes AutoUpdate=$true gilt als 'Auto'.
	UpdateMode            = 'Prompt'
	AutoUpdate            = $false
	UpdateRepository      = ''
	# Auto-Update-Quelle (zuletzt verwendete Installationsquelle - von Install.ps1 gesetzt
	# bzw. zur Laufzeit erkannt). Type: 'PSGallery'|'UNC'|'GitHub'|'LocalDir'|''(leer=auto).
	InstallSourceType        = ''
	InstallSourcePath        = ''
	# Throttle fuer den On-Import-Update-Check (Stunden zwischen Netz-Pruefungen).
	UpdateCheckIntervalHours = 24
	ModuleVersion         = '1.9.10.0'
	Language              = 'en-US'
	# Check-Profil: 'Auto' = Standort-Checks wenn ein Standort-Profil aktiv ist, 'Site' = immer,
	# 'Generic' = nie. Der fruehere Wert 'FiTs' wird weiter akzeptiert und als 'Site' gefuehrt.
	CheckProfile          = 'Auto'
	# Grenzwerte fuer Setup-Checks (neutrale Defaults, ein Standort-Profil kann sie ueberschreiben)
	CheckCostThresholdMin    = 50
	CheckTempDbMaxFiles      = 8
	CheckDiskBlockSize       = 65536
	# Mindestanteil freier Plattenkapazitaet in Prozent. Ohne neutralen Default existiert der
	# Schluessel ohne Standort-Profil nicht: Get-sqmConfig warnt dann und liefert $null,
	# was zu Schwellwert 0 wird - die Erweiterungsberechnung in Get-sqmDiskInfoByDriveLetter
	# meldet damit fuer jedes Laufwerk 0 GB.
	DiskFreeSpaceThresholdPct = 10
	# Monitoring-Zugang (Enable-sqmMonitoringAccess)
	DefaultPolicy            = $null   # Policy die vor Setup deaktiviert wird, $null = kein Policy-Handling
	DefaultMonitoringUser    = $null   # Windows-Login des Monitoring-Accounts, $null = Pflicht per Parameter
	# Verbindungssicherheit: TrustServerCertificate fuer alle dbatools-Verbindungen.
	# SQL Server 2022+ / neuere Microsoft.Data.SqlClient erzwingen Encrypt=True und pruefen
	# das Serverzertifikat. Bei self-signed Zertifikaten schlaegt die Verbindung sonst mit
	# "The certificate chain was issued by an authority that is not trusted" fehl.
	TrustServerCertificate   = $true
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
# SCHRITT 1b: Persistierte Konfiguration laden (ueberschreibt Standardwerte)
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
		# Altkonfiguration: wer AutoUpdate=$true gesetzt hat (vor UpdateMode), behaelt das
		# Installieren ohne Rueckfrage.
		if ($userConfig.AutoUpdate -eq $true -and -not $userConfig.PSObject.Properties['UpdateMode'])
		{
			$script:sqmModuleConfig['UpdateMode'] = 'Auto'
		}
	}
	catch
	{
		Write-Warning "Konfiguration konnte nicht geladen werden: $($_.Exception.Message)"
	}
}

# =============================================================================
# SCHRITT 1c: Standort-Profil (ueberschreibt config.json - gewinnt immer)
# Umgebungsspezifische Vorgaben (Job-Namen, Freigabepfade, Monitoring-Account, ...)
# stehen nicht im Code, sondern in einer optionalen, NICHT versionierten JSON-Datei:
#   1. <Modulordner>\sqmSQLTool.site.json            (kopiert Install.ps1 aus der Quelle mit)
#   2. %ProgramData%\MSSQLTools\sqmSQLTool.site.json  (maschinenweit, ueberlebt Modul-Updates)
# Aufbau: siehe Docs/SiteProfile.md.
#   Defaults: gelten immer, wenn das Profil vorhanden ist (config.json hat Vorrang).
#   Detection.ModulePathPatterns / UserDnsDomains / UserDomains: wann 'Config' gilt
#   (ein Treffer genuegt; ohne 'Detection' gilt 'Config' immer).
#   Config: Schluessel/Werte fuer die Modulkonfiguration. %VAR% in Strings wird expandiert.
#   DbatoolsShareCandidates / DbatoolsLegacyShareCandidates: Fallback-Freigaben fuer dbatools
#   (Schritt 2, Reihenfolge: neue Pfade, dann Legacy-Pfade).
# Die Werte aus 'Config' werden NACH config.json gesetzt und haben stets Vorrang.
# =============================================================================
$script:sqmSiteProfile       = $null
$script:sqmSiteProfilePath   = $null
$script:sqmSiteProfileActive = $false

foreach ($_sitePath in @(
		(Join-Path $PSScriptRoot 'sqmSQLTool.site.json'),
		(Join-Path $env:ProgramData 'MSSQLTools\sqmSQLTool.site.json')))
{
	if (-not (Test-Path -LiteralPath $_sitePath -PathType Leaf)) { continue }
	try
	{
		$script:sqmSiteProfile     = Get-Content -LiteralPath $_sitePath -Raw -Encoding UTF8 | ConvertFrom-Json
		$script:sqmSiteProfilePath = $_sitePath
		break
	}
	catch
	{
		Write-Warning "Standort-Profil '$_sitePath' konnte nicht gelesen werden: $($_.Exception.Message)"
	}
}

if ($script:sqmSiteProfile)
{
	# 'Defaults' gelten immer, wenn das Profil vorhanden ist (wie eingebaute Standardwerte):
	# ein in config.json gesetzter Wert hat Vorrang.
	if ($script:sqmSiteProfile.Defaults)
	{
		foreach ($_prop in $script:sqmSiteProfile.Defaults.PSObject.Properties)
		{
			if ($userConfig -and $userConfig.PSObject.Properties[$_prop.Name]) { continue }
			$_value = $_prop.Value
			if ($_value -is [string]) { $_value = [Environment]::ExpandEnvironmentVariables($_value) }
			$script:sqmModuleConfig[$_prop.Name] = $_value
		}
	}

	$_detection = $script:sqmSiteProfile.Detection
	if (-not $_detection)
	{
		$script:sqmSiteProfileActive = $true
	}
	else
	{
		foreach ($_pattern in @($_detection.ModulePathPatterns))
		{
			if ($_pattern -and $PSScriptRoot -like $_pattern)
			{
				$script:sqmSiteProfileActive = $true
				Write-Verbose "sqmSQLTool: Standort-Profil aktiv (Modulpfad: $PSScriptRoot)."
				break
			}
		}
		if (-not $script:sqmSiteProfileActive)
		{
			$_dnsDomain  = $env:USERDNSDOMAIN
			$_userDomain = $env:USERDOMAIN
			if (($_dnsDomain  -and @($_detection.UserDnsDomains) -contains $_dnsDomain) -or
				($_userDomain -and @($_detection.UserDomains) -contains $_userDomain))
			{
				$script:sqmSiteProfileActive = $true
				Write-Verbose "sqmSQLTool: Standort-Profil aktiv (Domaene: $_dnsDomain / $_userDomain)."
			}
		}
	}

	if ($script:sqmSiteProfileActive -and $script:sqmSiteProfile.Config)
	{
		foreach ($_prop in $script:sqmSiteProfile.Config.PSObject.Properties)
		{
			$_value = $_prop.Value
			if ($_value -is [string]) { $_value = [Environment]::ExpandEnvironmentVariables($_value) }
			$script:sqmModuleConfig[$_prop.Name] = $_value
		}
	}
}

# Frueherer Profilname wird weiter akzeptiert (config.json / Standort-Profil)
if ($script:sqmModuleConfig['CheckProfile'] -eq 'FiTs') { $script:sqmModuleConfig['CheckProfile'] = 'Site' }

if (-not $script:sqmSiteProfile -and $script:sqmModuleConfig['CheckProfile'] -eq 'Site')
{
	Write-Warning ("sqmSQLTool: CheckProfile ist 'Site', aber kein Standort-Profil gefunden " +
		"(<Modulordner>\sqmSQLTool.site.json oder %ProgramData%\MSSQLTools\sqmSQLTool.site.json). " +
		"Standortwerte wie Job-Namen und Freigabepfade fehlen - es gelten die neutralen Standardwerte.")
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
		# dbatools nicht via PSModulePath gefunden - Fallback: Freigaben aus dem Standort-Profil
		# (DbatoolsShareCandidates, danach DbatoolsLegacyShareCandidates; erster Treffer gewinnt)
		$_shareCandidates = @()
		if ($script:sqmSiteProfile)
		{
			$_shareCandidates = @(@($script:sqmSiteProfile.DbatoolsShareCandidates) +
				@($script:sqmSiteProfile.DbatoolsLegacyShareCandidates) | Where-Object { $_ })
		}
		$dbatoolsFallback = $_shareCandidates |
			Where-Object { [IO.Directory]::Exists([IO.Path]::Combine($_, 'dbatools')) } |
			Select-Object -First 1

		if ($dbatoolsFallback)
		{
			# Freigabe nur fuer diese Sitzung vorne in PSModulePath, dann regulaer importieren:
			# so loest dbatools auch sein RequiredModule dbatools.library von dort auf. (Frueher:
			# 'dbatools*' absteigend sortiert -> erwischte dbatools.library statt dbatools.)
			$env:PSModulePath = "$dbatoolsFallback;$env:PSModulePath"
			try
			{
				Import-Module dbatools -ErrorAction Stop
				$script:dbatoolsAvailable = $true
			}
			catch
			{
				$script:dbatoolsAvailable = $false
			}
		}
		if (-not $script:dbatoolsAvailable) { $script:dbatoolsAvailable = $false }
	}
}

if (-not $script:dbatoolsAvailable)
{
	Write-Warning "dbatools-Modul nicht gefunden. Funktionen die dbatools benoetigen sind nicht verfuegbar. Installation: Install-Module dbatools"
}
else
{
	# TrustServerCertificate fuer ALLE dbatools-Verbindungen aktivieren (self-signed Zertifikate).
	# Behebt "The certificate chain was issued by an authority that is not trusted" auf SQL 2022+.
	# Abschaltbar per Set-sqmConfig -TrustServerCertificate $false (sofort wirksam, in config.json
	# gespeichert und beim naechsten Import hier ausgewertet).
	# Der Wert wird in beide Richtungen gesetzt: ein Re-Import mit $false hebt ein frueheres
	# $true derselben Sitzung wieder auf.
	try
	{
		# Hinweis: Set-DbatoolsConfig hat KEINEN -Scope-Parameter (dbatools 2.8.x) - die
		# Einstellung gilt ohnehin sessionweit. Fruehere Variante mit "-Scope Session" warf
		# eine vom catch verschluckte Exception, sodass trustcert nie gesetzt wurde.
		Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value ([bool]$script:sqmModuleConfig['TrustServerCertificate']) -ErrorAction SilentlyContinue
	}
	catch { Write-Verbose "Konnte dbatools trustcert nicht setzen: $($_.Exception.Message)" }
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

function Test-sqmUpdateViaPSGallery
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
		# Direkt ueber die Gallery-API statt Find-Module: Find-Module fragt auf frischen Rechnern
		# nach dem NuGet-Provider (Rueckfrage mitten im Modulimport) und kennt keinen Timeout.
		[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
		$uri = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='$ModuleName'&`$filter=IsLatestVersion"
		$entry = Invoke-RestMethod -Uri $uri -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop | Select-Object -First 1
		if (-not $entry) { return $null }
		$currentVersion = [version]$script:sqmModuleConfig['ModuleVersion']
		$galleryVersion = [version]"$($entry.properties.Version)"

		if ($galleryVersion -gt $currentVersion)
		{
			Write-Verbose "PSGallery: Neuere Version verfuegbar ($galleryVersion)"
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
function Test-sqmUpdateViaGitHub
{
	[CmdletBinding()]
	param ([string]$GitHubRepo = 'JankeUwe/sqmSQLTool')

	if (-not (Test-InternetConnectivity)) { return $null }
	try
	{
		[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
		$latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubRepo/releases/latest" `
			-Headers @{'Accept' = 'application/vnd.github+json'} -TimeoutSec 5 `
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
function Test-sqmUpdateViaUNC
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
    Ermittelt die effektive Update-Quelle (zuletzt verwendete Installationsquelle).
.DESCRIPTION
    Primaer aus der Config (InstallSourceType/InstallSourcePath, von Install.ps1 gesetzt).
    Ist nichts gesetzt: Auto-Erkennung - via PowerShellGet installiert -> PSGallery,
    sonst konfiguriertes UpdateRepository -> UNC, sonst leer.
    Rueckgabe: Hashtable @{ Type='PSGallery'|'UNC'|'GitHub'|'LocalDir'|''; Path='...' }.
#>
function Get-sqmInstallSource
{
	[CmdletBinding()]
	param ()

	$type = $script:sqmModuleConfig['InstallSourceType']
	$path = $script:sqmModuleConfig['InstallSourcePath']
	if ($type) { return @{ Type = "$type"; Path = "$path" } }

	# Auto-Erkennung: ueber PowerShellGet (Install-Module) installiert -> PSGallery
	try
	{
		$inst = Get-InstalledModule -Name sqmSQLTool -ErrorAction Stop | Select-Object -First 1
		if ($inst -and $inst.Repository) { return @{ Type = 'PSGallery'; Path = "$($inst.Repository)" } }
	}
	catch { }

	# sonst: konfiguriertes UNC-Repository
	if ($script:sqmModuleConfig['UpdateRepository']) {
		return @{ Type = 'UNC'; Path = "$($script:sqmModuleConfig['UpdateRepository'])" }
	}

	return @{ Type = ''; Path = '' }
}

<#
.SYNOPSIS
    Prueft ob eine neuere Version verfuegbar ist - QUELLENBEWUSST.
.DESCRIPTION
    Prueft zuerst die zuletzt verwendete Installationsquelle (Get-sqmInstallSource).
    Ist diese erreichbar, ist sie massgeblich (kein Fallback). Ist die letzte Quelle
    unbekannt oder nicht erreichbar, greift die Fallback-Kette PSGallery -> GitHub -> UNC.
.PARAMETER Credential
    Credentials fuer UNC-Freigaben.
#>
function Test-sqmModuleUpdate
{
	[CmdletBinding()]
	param (
		[System.Management.Automation.PSCredential]$Credential
	)

	$src = Get-sqmInstallSource

	# Erreichbarkeit der letzten Quelle bestimmen
	$reachable = switch ($src.Type)
	{
		'PSGallery' { Test-InternetConnectivity }
		'GitHub'    { Test-InternetConnectivity }
		'UNC'       { [bool]$src.Path -and (Test-Path -Path $src.Path -ErrorAction SilentlyContinue) }
		'LocalDir'  { [bool]$src.Path -and (Test-Path -Path $src.Path -ErrorAction SilentlyContinue) }
		default     { $false }
	}

	if ($src.Type -and $reachable)
	{
		# Letzte Quelle ist massgeblich -> KEIN Fallback
		Write-Verbose "Update-Check gegen letzte Quelle: $($src.Type) ($($src.Path))"
		switch ($src.Type)
		{
			'PSGallery' { return Test-sqmUpdateViaPSGallery -ModuleName 'sqmSQLTool' }
			'GitHub'    { return Test-sqmUpdateViaGitHub -GitHubRepo $(if ($src.Path) { $src.Path } else { 'JankeUwe/sqmSQLTool' }) }
			'UNC'       { return Test-sqmUpdateViaUNC -RepositoryPath $src.Path }
			'LocalDir'  { return Test-sqmUpdateViaUNC -RepositoryPath $src.Path }
		}
	}

	# Quelle unbekannt oder nicht erreichbar -> Fallback-Kette PSGallery -> GitHub -> UNC
	Write-Verbose "Letzte Quelle unbekannt/nicht erreichbar -> Fallback-Kette"
	$updateResult = Test-sqmUpdateViaPSGallery -ModuleName 'sqmSQLTool'
	if ($updateResult) { return $updateResult }

	$updateResult = Test-sqmUpdateViaGitHub -GitHubRepo 'JankeUwe/sqmSQLTool'
	if ($updateResult) { return $updateResult }

	$updateResult = Test-sqmUpdateViaUNC -RepositoryPath $script:sqmModuleConfig['UpdateRepository']
	if ($updateResult) { return $updateResult }

	return $null
}

<#
.SYNOPSIS
    Kopiert die Moduldateien aus einem Quellordner in den Modulordner (mit optionalem Backup).
    Gemeinsame Hilfe fuer UNC-, LocalDir- und GitHub-Updates.
#>
function Copy-sqmModuleFiles
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)][string]$SourcePath,
		[Parameter(Mandatory)][string]$ModulePath,
		[switch]$Backup = $true
	)
	if ($Backup)
	{
		$backupDir = Join-Path $env:TEMP "sqmSQLTool_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
		Copy-Item -Path $ModulePath -Destination $backupDir -Recurse -Force -ErrorAction Stop
		Write-Host "Backup erstellt: $backupDir" -ForegroundColor Gray
	}
	Get-ChildItem -Path $SourcePath -Recurse -File | ForEach-Object {
		$relativePath = $_.FullName.Substring($SourcePath.Length).TrimStart('\')
		$targetFile   = Join-Path $ModulePath $relativePath
		$targetDir    = Split-Path $targetFile -Parent
		if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
		Copy-Item -Path $_.FullName -Destination $targetFile -Force -ErrorAction Stop
		Unblock-File -Path $targetFile -ErrorAction SilentlyContinue
	}
}

<#
.SYNOPSIS
    Zielordner fuer ein Datei-Update (UNC, LocalDir, GitHub).
.DESCRIPTION
    Liegt das Modul in einem Versionsordner (...\Modules\sqmSQLTool\1.9.140.0, so legt
    Install-Module es ab), darf die neue Version NICHT dort hinein: Ordnername und
    ModuleVersion im Manifest passen dann nicht mehr zusammen und PowerShell findet das Modul
    nicht mehr. Dann wird ein neuer Geschwisterordner mit der neuen Versionsnummer angelegt,
    die alte Version bleibt unangetastet daneben liegen.
#>
function Get-sqmModuleUpdateTarget
{
	[CmdletBinding()]
	param ([string]$NewVersion)

	$leaf = Split-Path $PSScriptRoot -Leaf
	$parsed = $null
	if ([version]::TryParse($leaf, [ref]$parsed))
	{
		if (-not $NewVersion) { throw "Modul liegt im Versionsordner '$leaf', die neue Version ist aber unbekannt." }
		return @{ Path = Join-Path (Split-Path $PSScriptRoot -Parent) $NewVersion; Versioned = $true }
	}
	return @{ Path = $PSScriptRoot; Versioned = $false }
}

<#
.SYNOPSIS
    Prueft, ob der aktuelle Benutzer in den Modulordner schreiben darf.
.DESCRIPTION
    Eine AllUsers-Installation unter Program Files braucht Adminrechte. Ohne die schlaegt das
    Update erst mitten im Kopieren fehl - deshalb vor dem Angebot pruefen.
#>
function Test-sqmModuleUpdateWritable
{
	[CmdletBinding()]
	[OutputType([bool])]
	param ()

	$dir = $PSScriptRoot
	$parsed = $null
	if ([version]::TryParse((Split-Path $dir -Leaf), [ref]$parsed)) { $dir = Split-Path $dir -Parent }
	$probe = Join-Path $dir ".sqmwrite_$PID.tmp"
	try
	{
		[System.IO.File]::WriteAllText($probe, '')
		Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
		return $true
	}
	catch { return $false }
}

<#
.SYNOPSIS
    Aktualisiert das Modul aus einem GitHub-Release (laedt das ZIP-Asset, entpackt, kopiert).
.PARAMETER Version
    Release-Version (z.B. 1.8.0.0). Ohne Angabe wird das latest-Release verwendet.
#>
function Update-sqmFromGitHub
{
	[CmdletBinding()]
	param (
		[string]$Version,
		[switch]$Backup = $true,
		[string]$GitHubRepo = 'JankeUwe/sqmSQLTool'
	)
	$tmp = Join-Path $env:TEMP "sqmSQLTool_gh_$(Get-Date -Format 'yyyyMMddHHmmss')"
	New-Item -ItemType Directory -Path $tmp -Force | Out-Null
	try
	{
		[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
		if (-not $Version)
		{
			$latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubRepo/releases/latest" `
				-Headers @{ 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop
			$Version = $latest.tag_name -replace '^v', ''
		}
		$zipUrl  = "https://github.com/$GitHubRepo/releases/download/v$Version/sqmSQLTool-v$Version.zip"
		$zipFile = Join-Path $tmp "sqmSQLTool-v$Version.zip"
		Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
		Expand-Archive -Path $zipFile -DestinationPath $tmp -Force -ErrorAction Stop

		# Quelle = Ordner, der die sqmSQLTool.psd1 enthaelt (ZIP kann einen Wurzelordner haben)
		$psd1 = Get-ChildItem -Path $tmp -Recurse -Filter 'sqmSQLTool.psd1' -ErrorAction Stop | Select-Object -First 1
		if (-not $psd1) { throw "sqmSQLTool.psd1 im heruntergeladenen ZIP nicht gefunden." }
		$target = Get-sqmModuleUpdateTarget -NewVersion $Version
		Copy-sqmModuleFiles -SourcePath $psd1.Directory.FullName -ModulePath $target.Path -Backup:($Backup -and -not $target.Versioned)
		Write-Host "Modul aus GitHub-Release v$Version aktualisiert." -ForegroundColor Green
		return $true
	}
	finally
	{
		Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
	}
}

<#
.SYNOPSIS
    Aktualisiert sqmSQLTool QUELLENBEWUSST von der zuletzt verwendeten Installationsquelle.
.DESCRIPTION
    Dispatcht nach Quelle: PSGallery (Install-Module), GitHub (Release-ZIP),
    UNC/LocalDir (Datei-Copy). Ohne -UpdateInfo wird Test-sqmModuleUpdate selbst aufgerufen.
    Liegt das Modul in einem Versionsordner, wird die neue Version daneben installiert.
    Die neue Version gilt ab dem naechsten Import (neue Sitzung oder Import-Module sqmSQLTool -Force).
.PARAMETER UpdateInfo
    Optionales Ergebnis von Test-sqmModuleUpdate (Source/Version/Path).
.PARAMETER Backup
    Sicherung vor Datei-Update (Standard: $true). Entfaellt bei Versionsordnern, dort bleibt
    die alte Version ohnehin erhalten.
.PARAMETER Force
    Update auch ohne erkannte neuere Version erzwingen.
.EXAMPLE
    Update-sqmModule
    Prueft die Installationsquelle und installiert eine neuere Version, falls vorhanden.
#>
function Update-sqmModule
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param (
		[hashtable]$UpdateInfo,
		[System.Management.Automation.PSCredential]$Credential,
		[switch]$Backup = $true,
		[switch]$Force
	)
	$currentModulePath = $PSScriptRoot

	if (-not $UpdateInfo) { $UpdateInfo = Test-sqmModuleUpdate -Credential $Credential }
	if (-not $UpdateInfo -and -not $Force)
	{
		Write-Host "Keine neuere Version verfuegbar (installiert: $($script:sqmModuleConfig['ModuleVersion']))." -ForegroundColor Green
		return
	}
	if (-not (Test-sqmModuleUpdateWritable))
	{
		Write-Warning "Keine Schreibrechte auf '$currentModulePath'. PowerShell als Administrator starten und 'Update-sqmModule' erneut ausfuehren."
		return
	}

	$source = if ($UpdateInfo -and $UpdateInfo.Source) { $UpdateInfo.Source } else { (Get-sqmInstallSource).Type }
	$verTxt = if ($UpdateInfo -and $UpdateInfo.Version) { " auf $($UpdateInfo.Version)" } else { '' }
	$done = $false

	try
	{
		switch ($source)
		{
			'PSGallery' {
				$scope = if ($currentModulePath -like "$env:ProgramFiles*") { 'AllUsers' } else { 'CurrentUser' }
				if ($PSCmdlet.ShouldProcess("sqmSQLTool$verTxt via PSGallery (Scope $scope)", "Install-Module"))
				{
					try
					{
						Install-Module -Name sqmSQLTool -Repository PSGallery -Force -AllowClobber -Scope $scope -ErrorAction Stop
						Write-Host "sqmSQLTool via PSGallery aktualisiert (Scope $scope)." -ForegroundColor Green
						$done = $true
					}
					catch { Write-Warning "PSGallery-Update fehlgeschlagen: $($_.Exception.Message)" }
				}
			}
			'GitHub' {
				if ($PSCmdlet.ShouldProcess("sqmSQLTool$verTxt via GitHub-Release", "Download & Update"))
				{
					$v = if ($UpdateInfo) { "$($UpdateInfo.Version)" } else { $null }
					$done = [bool](Update-sqmFromGitHub -Version $v -Backup:$Backup)
				}
			}
			default {
				# UNC / LocalDir -> Datei-Copy
				$repo = if ($UpdateInfo -and $UpdateInfo.Path) { $UpdateInfo.Path }
						elseif ($script:sqmModuleConfig['InstallSourcePath']) { $script:sqmModuleConfig['InstallSourcePath'] }
						else { $script:sqmModuleConfig['UpdateRepository'] }
				if (-not $repo)
				{
					Write-Warning "Keine Update-Quelle ermittelbar (weder Install-Source noch UpdateRepository gesetzt)."
					return
				}
				if (-not (Test-Path -Path $repo -ErrorAction SilentlyContinue))
				{
					Write-Warning "Quelle '$repo' nicht erreichbar."
					return
				}
				# Version aus dem Quell-Manifest: bestimmt bei Versionsordnern den Zielordner
				$newVersion = if ($UpdateInfo -and $UpdateInfo.Version) { "$($UpdateInfo.Version)" }
							  else { (Import-PowerShellDataFile -Path (Join-Path $repo 'sqmSQLTool.psd1') -ErrorAction Stop).ModuleVersion }
				$target = Get-sqmModuleUpdateTarget -NewVersion $newVersion
				if ($PSCmdlet.ShouldProcess("sqmSQLTool$verTxt aus '$repo' nach '$($target.Path)'", "Datei-Update"))
				{
					Copy-sqmModuleFiles -SourcePath $repo -ModulePath $target.Path -Backup:($Backup -and -not $target.Versioned)
					# Standort-Profil, das auf der Freigabe neben/ueber dem Modulordner liegt (nicht
					# im Ordner selbst), in den neuen Modulordner mitnehmen - sonst verliert ein Update
					# die Standorterkennung, wenn %ProgramData% kein Profil hat.
					$siteNote = ''
					$siteDir = ([IO.DirectoryInfo]$repo).Parent
					while ($siteDir -and -not [IO.File]::Exists([IO.Path]::Combine($repo, 'sqmSQLTool.site.json')))
					{
						$siteFile = [IO.Path]::Combine($siteDir.FullName, 'sqmSQLTool.site.json')
						if ([IO.File]::Exists($siteFile))
						{
							Copy-Item -LiteralPath $siteFile -Destination (Join-Path $target.Path 'sqmSQLTool.site.json') -Force -ErrorAction Stop
							$siteNote = " (Standort-Profil uebernommen: $siteFile)"
							break
						}
						$siteDir = $siteDir.Parent
					}
					Write-Host "Modul wurde aktualisiert: $($target.Path)$siteNote" -ForegroundColor Green
					$done = $true
				}
			}
		}
	}
	catch
	{
		Write-Error "Update fehlgeschlagen: $($_.Exception.Message)"
	}

	if ($done)
	{
		# Signal an Start-sqmToolGui.ps1 (laedt das Modul danach neu) und an den Start-Check
		$env:SQMSQLTOOL_UPDATED = if ($UpdateInfo -and $UpdateInfo.Version) { "$($UpdateInfo.Version)" } else { 'unknown' }
		Write-Host "Die neue Version gilt ab der naechsten PowerShell-Sitzung oder nach: Import-Module sqmSQLTool -Force" -ForegroundColor Yellow
	}
}

<#
.SYNOPSIS
    Bietet eine gefundene neuere Version an (Konsole oder MessageBox) und installiert sie auf Wunsch.
.DESCRIPTION
    Konsole: Ja / Nein (spaeter erneut fragen) / Ueberspringen (diese Version nicht mehr anbieten).
    MessageBox (Start-sqmToolGui setzt SQMSQLTOOL_UPDATE_UI=MessageBox): Ja / Nein. Ohne
    Schreibrechte auf den Modulordner gibt es nur einen Hinweis, keine Rueckfrage.
#>
function Invoke-sqmUpdateOffer
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)][hashtable]$UpdateInfo,
		[Parameter(Mandatory)][string]$SkipFile,
		[int]$IntervalHours = 24,
		[switch]$MessageBox
	)

	$current = $script:sqmModuleConfig['ModuleVersion']
	$text = "Fuer sqmSQLTool ist eine neuere Version verfuegbar: $current -> $($UpdateInfo.Version) (Quelle: $($UpdateInfo.Source))."

	if (-not (Test-sqmModuleUpdateWritable))
	{
		$hint = "$text`nZum Aktualisieren PowerShell als Administrator starten und 'Update-sqmModule' ausfuehren."
		if ($MessageBox)
		{
			Add-Type -AssemblyName System.Windows.Forms
			[System.Windows.Forms.MessageBox]::Show($hint, 'sqmSQLTool-Update', 'OK', 'Information') | Out-Null
		}
		else { Write-Host "`n[sqmSQLTool] $hint`n" -ForegroundColor Cyan }
		return
	}

	if ($MessageBox)
	{
		Add-Type -AssemblyName System.Windows.Forms
		$res = [System.Windows.Forms.MessageBox]::Show("$text`n`nJetzt aktualisieren?`n(Nein = in $IntervalHours Stunden erneut fragen)",
			'sqmSQLTool-Update', 'YesNo', 'Information')
		$answer = if ("$res" -eq 'Yes') { 0 } else { 1 }
	}
	else
	{
		$choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
			(New-Object System.Management.Automation.Host.ChoiceDescription '&Ja', 'Jetzt aktualisieren'),
			(New-Object System.Management.Automation.Host.ChoiceDescription '&Nein', "Spaeter erneut fragen (in $IntervalHours Stunden)"),
			(New-Object System.Management.Automation.Host.ChoiceDescription '&Ueberspringen', "Version $($UpdateInfo.Version) nicht mehr anbieten")
		)
		$answer = $Host.UI.PromptForChoice('sqmSQLTool-Update', "$text`nJetzt aktualisieren?", $choices, 0)
	}

	switch ($answer)
	{
		0 { Update-sqmModule -UpdateInfo $UpdateInfo -Force -Backup -Confirm:$false }
		1 { Write-Host "[sqmSQLTool] Spaeter manuell moeglich mit: Update-sqmModule" -ForegroundColor Gray }
		2 {
			"$($UpdateInfo.Version)" | Set-Content -Path $SkipFile -Force -ErrorAction SilentlyContinue
			Write-Host "[sqmSQLTool] Version $($UpdateInfo.Version) wird nicht mehr angeboten. Manuell: Update-sqmModule" -ForegroundColor Gray
		}
	}
}

# =============================================================================
# Update-Pruefung beim Modulstart. PowerShell laedt das Modul beim ersten Aufruf einer
# sqmSQLTool-Funktion automatisch - die Pruefung laeuft also vor der ersten Funktion einer
# Sitzung, hoechstens einmal je UpdateCheckIntervalHours.
#   UpdateMode 'Prompt' (Standard): neuere Version anbieten
#   UpdateMode 'Auto'             : ohne Rueckfrage installieren
#   UpdateMode 'Off'              : nicht pruefen
# Ohne Benutzer (Agent-Job, geplanter Task, -NonInteractive) kann niemand antworten: dort
# wird im Prompt-Modus nicht geprueft, sonst haengt der Import an der Rueckfrage.
# Der Import darf an der Update-Pruefung nie scheitern.
# =============================================================================
$updateMode = "$($script:sqmModuleConfig['UpdateMode'])"
if ($updateMode -notin 'Prompt', 'Auto', 'Off') { $updateMode = 'Prompt' }
$useMessageBox = $env:SQMSQLTOOL_UPDATE_UI -eq 'MessageBox'
$skipUpdateCheck = ($updateMode -eq 'Off') -or
	($env:SQMSQLTOOL_SKIP_AUTO_UPDATE -eq '1') -or ($env:MSSQLTOOLS_SKIP_AUTO_UPDATE -eq '1') -or
	($updateMode -eq 'Prompt' -and -not $useMessageBox -and -not (Test-sqmInteractiveSession))

if (-not $skipUpdateCheck)
{
	try
	{
		$intervalH = [int]($script:sqmModuleConfig['UpdateCheckIntervalHours'])
		if ($intervalH -le 0) { $intervalH = 24 }
		$markerDir  = Join-Path $env:LOCALAPPDATA 'sqmSQLTool'
		$markerFile = Join-Path $markerDir 'lastUpdateCheck'
		$skipFile   = Join-Path $markerDir 'skippedVersion'
		$dueCheck = $true
		if (Test-Path $markerFile)
		{
			try
			{
				$last = [datetime]::Parse((Get-Content $markerFile -Raw -ErrorAction Stop).Trim())
				if ((Get-Date) -lt $last.AddHours($intervalH)) { $dueCheck = $false }
			}
			catch { }
		}

		if ($dueCheck)
		{
			# Marker sofort schreiben (verhindert Doppel-Checks bei mehreren Importen)
			if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
			(Get-Date).ToString('o') | Set-Content -Path $markerFile -Force -ErrorAction SilentlyContinue

			# Quellenbewusst: letzte Installationsquelle zuerst, sonst Fallback-Kette
			$updateInfo = Test-sqmModuleUpdate
			if ($updateInfo -and $updateMode -eq 'Prompt' -and (Test-Path $skipFile) -and
				(Get-Content $skipFile -Raw -ErrorAction SilentlyContinue).Trim() -eq "$($updateInfo.Version)")
			{
				Write-Verbose "Version $($updateInfo.Version) wurde vom Benutzer uebersprungen."
				$updateInfo = $null
			}

			if ($updateInfo -and $updateMode -eq 'Auto')
			{
				Write-Host "`n[sqmSQLTool] Neuere Version verfuegbar: $($updateInfo.Version) (Quelle: $($updateInfo.Source))" -ForegroundColor Cyan
				Write-Host "[sqmSQLTool] Fuehre automatisches Update durch..." -ForegroundColor Cyan
				Update-sqmModule -UpdateInfo $updateInfo -Force -Backup -Confirm:$false
			}
			elseif ($updateInfo)
			{
				Invoke-sqmUpdateOffer -UpdateInfo $updateInfo -SkipFile $skipFile -IntervalHours $intervalH -MessageBox:$useMessageBox
			}
		}
	}
	catch
	{
		Write-Verbose "Update-Pruefung fehlgeschlagen: $($_.Exception.Message)"
	}
}

# Export-ModuleMember wird NICHT aufgerufen!
# Export wird ausschliesslich durch FunctionsToExport in sqmSQLTool.psd1 gesteuert.
# Das verhindert die PowerShell WARNING ueber "restricted characters" (Bindestriche in Verb-Noun Namen),
# weil der Check nur beim expliziten Export-ModuleMember Aufruf ausgeloest wird.
# Private Funktionen (Get-sqmString, Invoke-sqmLogging etc.) bleiben privat da sie nicht
# in der FunctionsToExport Liste der .psd1 stehen.

