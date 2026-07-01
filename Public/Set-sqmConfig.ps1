<#
.SYNOPSIS
    Sets one or more configuration values for the MSSQLTools module.

.DESCRIPTION
    Allows setting of LogPath, OutputPath, CentralPath, Ola job names,
    TSM management classes, the HPU domain group mapping, and the
    SSRS installer path (SsrsInstallerPath).
    Each path is validated for existence or creatability.
    The configuration is permanently saved in a JSON file in the user profile.

.PARAMETER LogPath
    Directory for log files (Invoke-sqmLogging).

.PARAMETER OutputPath
    Default output directory for reports.

.PARAMETER CentralPath
    Optional central storage directory (additional copy).

.PARAMETER OlaJobNameFull
    Name of the full backup job for user databases.

.PARAMETER OlaJobNameDiff
    Name of the diff backup job for user databases.

.PARAMETER OlaJobNameLog
    Name of the log backup job for user databases.

.PARAMETER OlaJobNameIndexOpt
    Name of the IndexOptimize job.

.PARAMETER OlaJobNameIntUserDb
    Name of the IntegrityCheck job for user databases.

.PARAMETER OlaJobNameIntSysDb
    Name of the IntegrityCheck job for system databases.

.PARAMETER OlaJobNameSysDbBackup
    Name of the full backup job for system databases.

.PARAMETER TsmManagementClasses
    Array of valid TSM management classes (e.g. 'MC_B_NL.NL_42.42.NA').

.PARAMETER HpuDomainGroupMap
    Array of PSCustomObject with fields DomainPattern (wildcard) and GroupNamePattern
    (sAMAccountName suffix of the HPU allow group). Evaluated by Get-sqmHpuAllowGroup.
    Entries are checked in order; the first match wins.
    Example:
        Set-sqmConfig -HpuDomainGroupMap @(
            [PSCustomObject]@{ DomainPattern = 'your.domain';   GroupNamePattern = 'Fg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
            [PSCustomObject]@{ DomainPattern = '*.your.domain'; GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
            [PSCustomObject]@{ DomainPattern = '*';                     GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }
        )

.PARAMETER SsrsInstallerPath
    Full UNC or local path to the SSRS installer file
    (SQLServerReportingServices.exe or .msi).
    Used by Install-sqmSsrsReportServer when -InstallerPath is not specified.
    Example: '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe'

.PARAMETER InstallSourceType
    Typ der zuletzt verwendeten Installationsquelle fuer das Auto-Update:
    'PSGallery' | 'UNC' | 'GitHub' | 'LocalDir'. Wird normalerweise von Install.ps1
    automatisch gesetzt. Das quellenbewusste Auto-Update bevorzugt diese Quelle.

.PARAMETER InstallSourcePath
    Locator zur Installationsquelle: Repository-Name (PSGallery), UNC-Pfad,
    'owner/repo' (GitHub) bzw. lokaler Pfad (LocalDir).

.PARAMETER CheckProfile
    Check-Profil fuer Invoke-sqmSetupReport und verwandte Checks.
    Auto  = FI-TS-Checks nur wenn sqmIsFitsEnvironment erkannt (Standard)
    FiTs  = FI-TS-Checks immer erzwingen (auch ausserhalb der Domaene)
    Generic = nur Standard-Checks, keine FI-TS-spezifischen Pruefungen

.PARAMETER CheckCostThresholdMin
    Mindestwert fuer Cost Threshold for Parallelism im Setup-Check.
    Standard: 50

.PARAMETER CheckTempDbMaxFiles
    Maximale TempDB-Dateianzahl im Setup-Check.
    Standard: 8

.PARAMETER CheckDiskBlockSize
    Empfohlene NTFS-Blockgroesse in Bytes fuer Get-sqmDiskBlockSize.
    Standard: 65536 (64 KB)

.PARAMETER DiskFreeSpaceThresholdPct
    Schwellwert (in Prozent) fuer den freien Speicherplatz auf Laufwerken.
    Laufwerke unterhalb dieses Schwellwerts werden als kritisch markiert und
    die benoetigte Erweiterung wird automatisch berechnet.
    Standard: 10 (10 %)

.PARAMETER Language
    Output language of the module. Allowed values: de-DE, en-US.
    Default: de-DE.
    Example: Set-sqmConfig -Language en-US

.PARAMETER PassThru
    Returns the updated configuration as an object.

.EXAMPLE
    Set-sqmConfig -LogPath "D:\Logs" -OlaJobNameFull "Prod-FULL"

.EXAMPLE
    Set-sqmConfig -TsmManagementClasses @('MC_10','MC_30','MC_100')

.EXAMPLE
    Set-sqmConfig -HpuDomainGroupMap @(
        [PSCustomObject]@{ DomainPattern = '*.sfinance.net'; GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
        [PSCustomObject]@{ DomainPattern = '*';              GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }
    )

.EXAMPLE
    Set-sqmConfig -SsrsInstallerPath '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe'
#>
function Set-sqmConfig
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param (
		[Parameter(Mandatory = $false)]
		[string]$LogPath,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[string]$CentralPath,
		[Parameter(Mandatory = $false)]
		[string]$OlaJobNameFull,
		[Parameter(Mandatory = $false)]
		[string]$OlaJobNameDiff,
		[Parameter(Mandatory = $false)]
		[string]$OlaJobNameLog,
		[Parameter(Mandatory = $false)]
		[string]$OlaJobNameIndexOpt,
		[Parameter(Mandatory = $false)]
		[string]$OlaJobNameIntUserDb,
		[Parameter(Mandatory = $false)]
		[string]$OlaJobNameIntSysDb,
		[Parameter(Mandatory = $false)]
		[string]$OlaJobNameSysDbBackup,
		[Parameter(Mandatory = $false)]
		[string[]]$TsmManagementClasses,
		[Parameter(Mandatory = $false)]
		[bool]$AutoUpdate,
		[Parameter(Mandatory = $false)]
		[string]$UpdateRepository,
		[Parameter(Mandatory = $false)]
		[ValidateSet('PSGallery', 'UNC', 'GitHub', 'LocalDir')]
		[string]$InstallSourceType,
		[Parameter(Mandatory = $false)]
		[string]$InstallSourcePath,
		[Parameter(Mandatory = $false)]
		[string]$DefaultPolicy,
		[Parameter(Mandatory = $false)]
		[PSCustomObject[]]$HpuDomainGroupMap,
		[Parameter(Mandatory = $false)]
		[string]$SsrsInstallerPath,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Auto', 'FiTs', 'Generic')]
		[string]$CheckProfile,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 1000)]
		[int]$CheckCostThresholdMin,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 64)]
		[int]$CheckTempDbMaxFiles,
		[Parameter(Mandatory = $false)]
		[ValidateSet(4096, 8192, 16384, 32768, 65536, 131072)]
		[int]$CheckDiskBlockSize,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 50)]
		[int]$DiskFreeSpaceThresholdPct,
		[Parameter(Mandatory = $false)]
		[ValidateSet('de-DE', 'en-US')]
		[string]$Language,
		[Parameter(Mandatory = $false)]
		[switch]$PassThru
	)
	
	# Hilfsfunktion zum Pruefen/Erstellen eines Pfads
	# Pfad-Existenz und Schreibbarkeit werden geprueft wenn moeglich.
	# Nicht-erreichbare Pfade erzeugen nur eine Warnung - kein Fehler.
	# Konfiguration wird trotzdem gespeichert (Pfad kann spaeter entstehen).
	function Test-AndCreatePath($Path, $Purpose)
	{
		if (-not $Path) { return $true }
		if ($Path -match '^\s*$')
		{
			Write-Error "Pfad fuer $Purpose darf nicht leer sein."
			return $false
		}
		try
		{
			if (-not (Test-Path $Path))
			{
				New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
				Write-Verbose "Verzeichnis '$Path' ($Purpose) wurde erstellt."
			}
			# Schreibtest nur wenn Pfad erreichbar - Fehler hier ist nicht kritisch
			try
			{
				$testFile = Join-Path $Path "test_$(Get-Random).tmp"
				New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop | Out-Null
				Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
			}
			catch
			{
				Write-Warning "Pfad '$Path' ($Purpose) ist nicht beschreibbar: $($_.Exception.Message). Konfiguration wird trotzdem gespeichert."
			}
			return $true
		}
		catch
		{
			# Verzeichnis konnte nicht erstellt werden - nur warnen, nicht abbrechen
			Write-Warning "Pfad '$Path' ($Purpose) konnte nicht erstellt werden: $($_.Exception.Message). Wird spaeter automatisch angelegt. Konfiguration wird gespeichert."
			return $true
		}
	}
	
	$updated = $false
	$globalConfig = $script:sqmModuleConfig
	
	# Pfad-Parameter
	if ($PSBoundParameters.ContainsKey('LogPath'))
	{
		if (Test-AndCreatePath $LogPath "LogPath")
		{
			$globalConfig['LogPath'] = $LogPath
			$updated = $true
		}
		else { return }
	}
	if ($PSBoundParameters.ContainsKey('OutputPath'))
	{
		if (Test-AndCreatePath $OutputPath "OutputPath")
		{
			$globalConfig['OutputPath'] = $OutputPath
			$updated = $true
		}
		else { return }
	}
	if ($PSBoundParameters.ContainsKey('CentralPath'))
	{
		if ($CentralPath)
		{
			if (Test-AndCreatePath $CentralPath "CentralPath")
			{
				$globalConfig['CentralPath'] = $CentralPath
				$updated = $true
			}
			else { return }
		}
		else
		{
			$globalConfig['CentralPath'] = $null
			$updated = $true
		}
	}
	
	# Ola-Job-Namen
	if ($PSBoundParameters.ContainsKey('OlaJobNameFull'))
	{
		if (-not [string]::IsNullOrWhiteSpace($OlaJobNameFull))
		{
			$globalConfig['OlaJobNameFull'] = $OlaJobNameFull
			$updated = $true
		}
		else { Write-Error "OlaJobNameFull darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('OlaJobNameDiff'))
	{
		if (-not [string]::IsNullOrWhiteSpace($OlaJobNameDiff))
		{
			$globalConfig['OlaJobNameDiff'] = $OlaJobNameDiff
			$updated = $true
		}
		else { Write-Error "OlaJobNameDiff darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('OlaJobNameLog'))
	{
		if (-not [string]::IsNullOrWhiteSpace($OlaJobNameLog))
		{
			$globalConfig['OlaJobNameLog'] = $OlaJobNameLog
			$updated = $true
		}
		else { Write-Error "OlaJobNameLog darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('OlaJobNameIndexOpt'))
	{
		if (-not [string]::IsNullOrWhiteSpace($OlaJobNameIndexOpt))
		{
			$globalConfig['OlaJobNameIndexOpt'] = $OlaJobNameIndexOpt
			$updated = $true
		}
		else { Write-Error "OlaJobNameIndexOpt darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('OlaJobNameIntUserDb'))
	{
		if (-not [string]::IsNullOrWhiteSpace($OlaJobNameIntUserDb))
		{
			$globalConfig['OlaJobNameIntUserDb'] = $OlaJobNameIntUserDb
			$updated = $true
		}
		else { Write-Error "OlaJobNameIntUserDb darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('OlaJobNameIntSysDb'))
	{
		if (-not [string]::IsNullOrWhiteSpace($OlaJobNameIntSysDb))
		{
			$globalConfig['OlaJobNameIntSysDb'] = $OlaJobNameIntSysDb
			$updated = $true
		}
		else { Write-Error "OlaJobNameIntSysDb darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('OlaJobNameSysDbBackup'))
	{
		if (-not [string]::IsNullOrWhiteSpace($OlaJobNameSysDbBackup))
		{
			$globalConfig['OlaJobNameSysDbBackup'] = $OlaJobNameSysDbBackup
			$updated = $true
		}
		else { Write-Error "OlaJobNameSysDbBackup darf nicht leer sein."; return }
	}
	
	# TSM Management-Klassen
	if ($PSBoundParameters.ContainsKey('TsmManagementClasses'))
	{
		if ($TsmManagementClasses -and $TsmManagementClasses.Count -gt 0)
		{
			$globalConfig['TsmManagementClasses'] = $TsmManagementClasses
			$updated = $true
		}
		else
		{
			Write-Error "TsmManagementClasses darf nicht leer sein."
			return
		}
	}
	
	# Update-Einstellungen
	if ($PSBoundParameters.ContainsKey('AutoUpdate'))
	{
		$globalConfig['AutoUpdate'] = $AutoUpdate
		$updated = $true
	}
	if ($PSBoundParameters.ContainsKey('UpdateRepository'))
	{
		$globalConfig['UpdateRepository'] = $UpdateRepository
		$updated = $true
	}
	if ($PSBoundParameters.ContainsKey('InstallSourceType'))
	{
		$globalConfig['InstallSourceType'] = $InstallSourceType
		$updated = $true
	}
	if ($PSBoundParameters.ContainsKey('InstallSourcePath'))
	{
		$globalConfig['InstallSourcePath'] = $InstallSourcePath
		$updated = $true
	}
	
	# Default Policy Name
	if ($PSBoundParameters.ContainsKey('DefaultPolicy'))
	{
		if (-not [string]::IsNullOrWhiteSpace($DefaultPolicy))
		{
			$globalConfig['DefaultPolicy'] = $DefaultPolicy
			$updated = $true
		}
		else { Write-Error "DefaultPolicy darf nicht leer sein."; return }
	}
	
	# HPU-Domain-Gruppen-Mapping
	if ($PSBoundParameters.ContainsKey('HpuDomainGroupMap'))
	{
		if ($HpuDomainGroupMap -and $HpuDomainGroupMap.Count -gt 0)
		{
			# Pflichtfelder jedes Eintrags pruefen
			foreach ($entry in $HpuDomainGroupMap)
			{
				if ([string]::IsNullOrWhiteSpace($entry.DomainPattern))
				{
					Write-Error "HpuDomainGroupMap: Jeder Eintrag benoetigt ein nicht-leeres Feld 'DomainPattern'."
					return
				}
				if ([string]::IsNullOrWhiteSpace($entry.GroupNamePattern))
				{
					Write-Error "HpuDomainGroupMap: Jeder Eintrag benoetigt ein nicht-leeres Feld 'GroupNamePattern'."
					return
				}
			}
			$globalConfig['HpuDomainGroupMap'] = $HpuDomainGroupMap
			$updated = $true
		}
		else
		{
			Write-Error "HpuDomainGroupMap darf nicht leer sein."
			return
		}
	}
	
	# SSRS-Installer-Pfad
	if ($PSBoundParameters.ContainsKey('SsrsInstallerPath'))
	{
		if (-not [string]::IsNullOrWhiteSpace($SsrsInstallerPath))
		{
			$ext = [System.IO.Path]::GetExtension($SsrsInstallerPath).ToLower()
			if ($ext -notin @('.exe', '.msi'))
			{
				Write-Error "SsrsInstallerPath: Nur .exe oder .msi-Dateien sind gueltig (angegeben: '$SsrsInstallerPath')."
				return
			}
			$globalConfig['SsrsInstallerPath'] = $SsrsInstallerPath
			$updated = $true
		}
		else
		{
			Write-Error "SsrsInstallerPath darf nicht leer sein."
			return
		}
	}
	
	# Check-Profil und Grenzwerte
	if ($PSBoundParameters.ContainsKey('CheckProfile'))
	{
		$globalConfig['CheckProfile'] = $CheckProfile
		$updated = $true
	}
	if ($PSBoundParameters.ContainsKey('CheckCostThresholdMin'))
	{
		$globalConfig['CheckCostThresholdMin'] = $CheckCostThresholdMin
		$updated = $true
	}
	if ($PSBoundParameters.ContainsKey('CheckTempDbMaxFiles'))
	{
		$globalConfig['CheckTempDbMaxFiles'] = $CheckTempDbMaxFiles
		$updated = $true
	}
	if ($PSBoundParameters.ContainsKey('CheckDiskBlockSize'))
	{
		$globalConfig['CheckDiskBlockSize'] = $CheckDiskBlockSize
		$updated = $true
	}
	if ($PSBoundParameters.ContainsKey('DiskFreeSpaceThresholdPct'))
	{
		$globalConfig['DiskFreeSpaceThresholdPct'] = $DiskFreeSpaceThresholdPct
		$updated = $true
	}

	# Ausgabe-Sprache
	if ($PSBoundParameters.ContainsKey('Language'))
	{
		$globalConfig['Language'] = $Language
		$script:_strings = $null    # String-Cache invalidieren
		$updated = $true
	}

	if (-not $updated)
	{
		Write-Warning "Es wurde kein gueltiger Konfigurationsparameter angegeben."
		return
	}
	
	# Persistenz: Nur explizit gesetzte Keys in JSON-Datei schreiben (Merge)
	# Verhindert, dass Auto-Werte (FI-TS-Defaults, Umgebungsvariablen) in config.json
	# landen und beim naechsten Modulimport den FI-TS-Block ueberschreiben.
	$configFile = Join-Path $env:APPDATA "MSSQLTools\config.json"
	$configDir = Split-Path $configFile -Parent
	if (-not (Test-Path $configDir))
	{
		New-Item -ItemType Directory -Path $configDir -Force | Out-Null
	}

	# Bestehende config.json einlesen (nur user-gesetzte Keys)
	$persistConfig = [ordered]@{}
	if (Test-Path $configFile)
	{
		try
		{
			$existingJson = Get-Content $configFile -Raw | ConvertFrom-Json
			foreach ($prop in $existingJson.PSObject.Properties) { $persistConfig[$prop.Name] = $prop.Value }
		}
		catch { }
	}

	# Nur in diesem Aufruf explizit geaenderte Keys uebernehmen
	foreach ($paramName in $PSBoundParameters.Keys)
	{
		if ($globalConfig.ContainsKey($paramName))
		{
			$persistConfig[$paramName] = $globalConfig[$paramName]
		}
	}

	$persistConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -Force
	Write-Verbose "Konfiguration gespeichert: $configFile"
	
	if ($PassThru)
	{
		return Get-sqmConfig
	}
}