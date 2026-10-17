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

.PARAMETER BackupMaintenanceJobNameFull
    Name of the SQL Agent job New-sqmBackupMaintenanceJob creates for -BackupType FULL.
    Default (when not configured): 'sqm-BackupMaintenance-FULL'.

.PARAMETER BackupMaintenanceJobNameDiff
    Name of the SQL Agent job New-sqmBackupMaintenanceJob creates for -BackupType DIFF.
    Default (when not configured): 'sqm-BackupMaintenance-DIFF'.

.PARAMETER BackupMaintenanceJobNameLog
    Name of the SQL Agent job New-sqmBackupMaintenanceJob creates for -BackupType LOG.
    Default (when not configured): 'sqm-BackupMaintenance-LOG'.

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

.PARAMETER MasterDbObjectWhitelist
    Array of object names (tables/views/procedures/functions) that are expected in master and
    must never be reported or removed by Get-/Remove-sqmMasterDbCustomObjects, in addition to
    genuine Microsoft-shipped objects (which are always excluded via is_ms_shipped). Wildcards
    allowed. Default: the standard maintenance-script family (Ola Hallengren's
    CommandExecute/CommandLog/DatabaseBackup/DatabaseIntegrityCheck/IndexOptimize, Brent Ozar's
    sp_Blitz*, sp_WhoIsActive) plus sp_BackRestRemain.
    Example:
        Set-sqmConfig -MasterDbObjectWhitelist @('sp_Blitz*', 'sp_WhoIsActive', 'usp_MyAdminTool')

.PARAMETER SsrsInstallerPath
    Full UNC or local path to the SSRS installer file
    (SQLServerReportingServices.exe or .msi).
    Used by Install-sqmSsrsReportServer when -InstallerPath is not specified.
    Example: '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe'

.PARAMETER DbatoolsSharePath
    UNC or local path to a share containing a pre-packaged 'dbatools' + 'dbatools.library'
    baseline (two subfolders of that name). Used by Install.ps1 to sideload dbatools on
    instances without PSGallery access (e.g. isolated production servers) instead of
    deriving the path from -Source. See github.com/JankeUwe/dbatools-baseline for how such
    a share gets populated/kept in sync.
    Example: '\\fileserver\SQLAdmin\Modules'

.PARAMETER UpdateMode
    Update-Pruefung beim Modulstart (erster Aufruf einer sqmSQLTool-Funktion in einer Sitzung,
    hoechstens einmal je UpdateCheckIntervalHours, Standard 24):
    Prompt = neuere Version anbieten (Standard). In Agent-Jobs, geplanten Tasks und
             -NonInteractive-Sitzungen wird nicht geprueft.
    Auto   = ohne Rueckfrage installieren (auch in Agent-Jobs).
    Off    = nicht pruefen. Manuell jederzeit: Update-sqmModule
    Loest -AutoUpdate ab; ein frueher gespeichertes AutoUpdate=$true gilt als 'Auto'.

.PARAMETER InstallSourceType
    Typ der zuletzt verwendeten Installationsquelle fuer das Auto-Update:
    'PSGallery' | 'UNC' | 'GitHub' | 'LocalDir'. Wird normalerweise von Install.ps1
    automatisch gesetzt. Das quellenbewusste Auto-Update bevorzugt diese Quelle.

.PARAMETER InstallSourcePath
    Locator zur Installationsquelle: Repository-Name (PSGallery), UNC-Pfad,
    'owner/repo' (GitHub) bzw. lokaler Pfad (LocalDir).

.PARAMETER CheckProfile
    Check-Profil fuer Invoke-sqmSetupReport und verwandte Checks.
    Auto  = Standort-Checks nur wenn ein Standort-Profil aktiv ist (Standard)
    Site  = Standort-Checks immer erzwingen (auch ausserhalb der erkannten Umgebung)
    Generic = nur Standard-Checks, keine standortspezifischen Pruefungen
    Der fruehere Wert 'FiTs' wird weiter akzeptiert und als 'Site' gespeichert.

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

.PARAMETER TrustServerCertificate
    Whether the module's dbatools connections trust the SQL Server certificate without
    validating it (dbatools option sql.connection.trustcert).
    $true  = trust any certificate, also the auto-generated self-signed one (default).
             Connections stay encrypted, but the server identity is not checked.
    $false = validate the certificate (trusted CA, matching name, not expired). Use this once
             the instances have proper TLS certificates (Get-sqmTlsStatus, Set-sqmSqlTlsCertificate).
    Applies immediately to the current session and is saved for future sessions.
    Example: Set-sqmConfig -TrustServerCertificate $false

.PARAMETER PassThru
    Returns the updated configuration as an object.

.EXAMPLE
    Set-sqmConfig -LogPath "D:\Logs" -OlaJobNameFull "Prod-FULL"

.EXAMPLE
    Set-sqmConfig -TsmManagementClasses @('MC_10','MC_30','MC_100')

.EXAMPLE
    Set-sqmConfig -HpuDomainGroupMap @(
        [PSCustomObject]@{ DomainPattern = '*.corp.example'; GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
        [PSCustomObject]@{ DomainPattern = '*';              GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }
    )

.EXAMPLE
    Set-sqmConfig -SsrsInstallerPath '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe'

.EXAMPLE
    Set-sqmConfig -DbatoolsSharePath '\\fileserver\SQLAdmin\Modules'

.EXAMPLE
    Set-sqmConfig -MasterDbObjectWhitelist @('sp_Blitz*', 'sp_WhoIsActive', 'CommandExecute', 'CommandLog', 'usp_MyAdminTool')
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
		[string]$BackupMaintenanceJobNameFull,
		[Parameter(Mandatory = $false)]
		[string]$BackupMaintenanceJobNameDiff,
		[Parameter(Mandatory = $false)]
		[string]$BackupMaintenanceJobNameLog,
		[Parameter(Mandatory = $false)]
		[string[]]$TsmManagementClasses,
		[Parameter(Mandatory = $false)]
		[bool]$AutoUpdate,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Prompt', 'Auto', 'Off')]
		[string]$UpdateMode,
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
		[string[]]$MasterDbObjectWhitelist,
		[Parameter(Mandatory = $false)]
		[string]$SsrsInstallerPath,
		[Parameter(Mandatory = $false)]
		[string]$DbatoolsSharePath,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Auto', 'Site', 'Generic', 'FiTs')]
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
		[bool]$TrustServerCertificate,
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

	# Backup-Maintenance-Job-Namen (New-sqmBackupMaintenanceJob, je nach -BackupType)
	if ($PSBoundParameters.ContainsKey('BackupMaintenanceJobNameFull'))
	{
		if (-not [string]::IsNullOrWhiteSpace($BackupMaintenanceJobNameFull))
		{
			$globalConfig['BackupMaintenanceJobNameFull'] = $BackupMaintenanceJobNameFull
			$updated = $true
		}
		else { Write-Error "BackupMaintenanceJobNameFull darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('BackupMaintenanceJobNameDiff'))
	{
		if (-not [string]::IsNullOrWhiteSpace($BackupMaintenanceJobNameDiff))
		{
			$globalConfig['BackupMaintenanceJobNameDiff'] = $BackupMaintenanceJobNameDiff
			$updated = $true
		}
		else { Write-Error "BackupMaintenanceJobNameDiff darf nicht leer sein."; return }
	}
	if ($PSBoundParameters.ContainsKey('BackupMaintenanceJobNameLog'))
	{
		if (-not [string]::IsNullOrWhiteSpace($BackupMaintenanceJobNameLog))
		{
			$globalConfig['BackupMaintenanceJobNameLog'] = $BackupMaintenanceJobNameLog
			$updated = $true
		}
		else { Write-Error "BackupMaintenanceJobNameLog darf nicht leer sein."; return }
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
	if ($PSBoundParameters.ContainsKey('UpdateMode'))
	{
		$globalConfig['UpdateMode'] = $UpdateMode
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
	
	# Whitelist erwarteter Objekte in master (Get-/Remove-sqmMasterDbCustomObjects)
	if ($PSBoundParameters.ContainsKey('MasterDbObjectWhitelist'))
	{
		if ($MasterDbObjectWhitelist -and $MasterDbObjectWhitelist.Count -gt 0)
		{
			$globalConfig['MasterDbObjectWhitelist'] = $MasterDbObjectWhitelist
			$updated = $true
		}
		else
		{
			Write-Error "MasterDbObjectWhitelist darf nicht leer sein."
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
	
	# dbatools-Baseline-Freigabe (Sideload ohne PSGallery-Zugriff)
	if ($PSBoundParameters.ContainsKey('DbatoolsSharePath'))
	{
		if (-not [string]::IsNullOrWhiteSpace($DbatoolsSharePath))
		{
			$globalConfig['DbatoolsSharePath'] = $DbatoolsSharePath
			$updated = $true
		}
		else
		{
			Write-Error "DbatoolsSharePath darf nicht leer sein."
			return
		}
	}

	# Check-Profil und Grenzwerte
	if ($PSBoundParameters.ContainsKey('CheckProfile'))
	{
		# 'FiTs' = frueherer Name von 'Site', weiter akzeptiert
		$globalConfig['CheckProfile'] = if ($CheckProfile -eq 'FiTs') { 'Site' } else { $CheckProfile }
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

	# Zertifikatspruefung der dbatools-Verbindungen (sofort wirksam + persistiert)
	if ($PSBoundParameters.ContainsKey('TrustServerCertificate'))
	{
		$globalConfig['TrustServerCertificate'] = $TrustServerCertificate
		if (Get-Command -Name Set-DbatoolsConfig -ErrorAction SilentlyContinue)
		{
			try
			{
				Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $TrustServerCertificate -ErrorAction Stop | Out-Null
			}
			catch { Write-Warning "dbatools-Option sql.connection.trustcert konnte nicht gesetzt werden: $($_.Exception.Message)" }
		}
		$updated = $true
	}

	if (-not $updated)
	{
		Write-Warning "Es wurde kein gueltiger Konfigurationsparameter angegeben."
		return
	}
	
	# Persistenz: Nur explizit gesetzte Keys in JSON-Datei schreiben (Merge)
	# Verhindert, dass Auto-Werte (Standort-Profil, Umgebungsvariablen) in config.json
	# landen und beim naechsten Modulimport das Standort-Profil ueberschreiben.
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
