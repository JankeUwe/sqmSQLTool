<#
.SYNOPSIS
    Setzt einen oder mehrere Konfigurationswerte fuer das MSSQLTools-Modul.

.DESCRIPTION
    Erlaubt das Setzen von LogPath, OutputPath, CentralPath, Ola-Job-Namen,
    TSM Management-Klassen, des HPU-Domain-Gruppen-Mappings sowie des
    SSRS-Installer-Pfads (SsrsInstallerPath).
    Jeder Pfad wird auf Existenz bzw. Erstellbarkeit geprueft.
    Die Konfiguration wird dauerhaft in einer JSON-Datei im Benutzerprofil gespeichert.

.PARAMETER LogPath
    Verzeichnis fuer Logdateien (Invoke-sqmLogging).

.PARAMETER OutputPath
    Standard-Ausgabeverzeichnis fuer Berichte.

.PARAMETER CentralPath
    Optionales zentrales Ablageverzeichnis (zusaetzliche Kopie).

.PARAMETER OlaJobNameFull
    Name des Full-Backup-Jobs fuer User-Datenbanken.

.PARAMETER OlaJobNameDiff
    Name des Diff-Backup-Jobs fuer User-Datenbanken.

.PARAMETER OlaJobNameLog
    Name des Log-Backup-Jobs fuer User-Datenbanken.

.PARAMETER OlaJobNameIndexOpt
    Name des IndexOptimize-Jobs.

.PARAMETER OlaJobNameIntUserDb
    Name des IntegrityCheck-Jobs fuer User-Datenbanken.

.PARAMETER OlaJobNameIntSysDb
    Name des IntegrityCheck-Jobs fuer System-Datenbanken.

.PARAMETER OlaJobNameSysDbBackup
    Name des Full-Backup-Jobs fuer System-Datenbanken.

.PARAMETER TsmManagementClasses
    Array von gueltigen TSM Management-Klassen (z.B. 'MC_B_NL.NL_42.42.NA').

.PARAMETER HpuDomainGroupMap
    Array von PSCustomObject mit den Feldern DomainPattern (Wildcard) und GroupNamePattern
    (sAMAccountName-Suffix der HPU-Allow-Gruppe). Wird von Get-sqmHpuAllowGroup ausgewertet.
    Eintraege werden der Reihe nach geprueft; der erste Treffer gewinnt.
    Beispiel:
        Set-sqmConfig -HpuDomainGroupMap @(
            [PSCustomObject]@{ DomainPattern = 'bayernlb.sfinance.net'; GroupNamePattern = 'Fg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
            [PSCustomObject]@{ DomainPattern = '*.sfinance.net';        GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
            [PSCustomObject]@{ DomainPattern = '*';                     GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }
        )

.PARAMETER SsrsInstallerPath
    Vollstaendiger UNC- oder lokaler Pfad zur SSRS-Installationsdatei
    (SQLServerReportingServices.exe oder .msi).
    Wird von Install-sqmSsrsReportServer verwendet wenn -InstallerPath nicht angegeben wird.
    Beispiel: '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe'

.PARAMETER Language
    Ausgabe-Sprache des Moduls. Erlaubte Werte: de-DE, en-US.
    Standard: de-DE.
    Beispiel: Set-sqmConfig -Language en-US

.PARAMETER PassThru
    Gibt die aktualisierte Konfiguration als Objekt zurueck.

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
		[string]$DefaultPolicy,
		[Parameter(Mandatory = $false)]
		[PSCustomObject[]]$HpuDomainGroupMap,
		[Parameter(Mandatory = $false)]
		[string]$SsrsInstallerPath,
		[Parameter(Mandatory = $false)]
		[ValidateSet('de-DE', 'en-US')]
		[string]$Language,
		[Parameter(Mandatory = $false)]
		[switch]$PassThru
	)
	
	# Hilfsfunktion zum Pruefen/Erstellen eines Pfads
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
			$testFile = Join-Path $Path "test_$(Get-Random).tmp"
			New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop | Out-Null
			Remove-Item -Path $testFile -Force -ErrorAction Stop
			return $true
		}
		catch
		{
			Write-Error "Konnte Pfad '$Path' nicht fuer $Purpose verwenden: $($_.Exception.Message)"
			return $false
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
	
	# Persistenz: JSON-Datei schreiben
	$configFile = Join-Path $env:APPDATA "MSSQLTools\config.json"
	$configDir = Split-Path $configFile -Parent
	if (-not (Test-Path $configDir))
	{
		New-Item -ItemType Directory -Path $configDir -Force | Out-Null
	}
	$globalConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -Force
	Write-Verbose "Konfiguration gespeichert: $configFile"
	
	if ($PassThru)
	{
		return Get-sqmConfig
	}
}