<#
.SYNOPSIS
    Configures the IBM Spectrum Protect (TSM) client options file dsm.opt
    for use with SQL Server backup directories.

.DESCRIPTION
    Reads the existing dsm.opt, adds or replaces the relevant entries,
    and writes the file back. Before each change a backup copy (dsm.opt.bak)
    is automatically created.

    Configured sections (within the managed block):
    - EXCLUDE patterns (default: SQL Server *.mdf/*.ndf/*.ldf; override via -ExcludePatterns)
    - INCLUDE directories with per-path management class (default: User-db/Sys-db;
      override via -IncludeRule for arbitrary path -> management class mappings)

    Target file: by default the dsm.opt itself. Real environments often outsource
    INCLUDE/EXCLUDE statements into a separate file referenced via the INCLEXCL option
    (e.g. ie_dsm.opt), processed BEFORE the dsm.opt. Use -UseInclExclFile to auto-resolve
    that file from the dsm.opt's INCLEXCL option, or -InclExclPath to target it explicitly.
    The target file is created if it does not yet exist (for INCLEXCL files).

    When -UseDiff is set, the management class is forced to
    MC_B_NL.NL_42.42.NA (42-day retention).

    The managed block is delimited by the markers
    '* --- dtcSqlTools BEGIN ---' and '* --- dtcSqlTools END ---'.
    Manual entries outside this block are preserved. NOTE: if the vendor's TSM
    configurator regenerates the file, our block may be overwritten - re-run as needed.

.PARAMETER ComputerName
    Target computer (TSM client). Default: current computer name.

.PARAMETER SqlInstance
    SQL Server instance used to determine the backup directory.
    Default: $ComputerName.

.PARAMETER DsmOptPath
    Full path to the dsm.opt on the target computer.
    Determined automatically when not specified.

.PARAMETER BackupDirectory
    Base backup directory. The subdirectories \User-db and \Sys-db
    are added as INCLUDE entries.
    Default: read from the SQL instance (BackupDirectory property).

.PARAMETER AdditionalIncludePaths
    Additional directories to be added as INCLUDE entries.

.PARAMETER ManagementClass
    Default TSM management class for the backup includes (used when an include
    rule does not specify its own class). Accepts any MC_* name (validated by
    pattern, not a fixed set) so real-world classes such as MC_B_2.2_15.15.NA_IMG
    or MC_B_NL_NL_365.365.NA are allowed.
    Default: MC_B_NL.NL_42.42.NA.

.PARAMETER ExcludePatterns
    Custom EXCLUDE patterns (without the EXCLUDE keyword/quotes), e.g.
    @('S:\...\*', '*:\...\*.ldf'). When omitted, defaults to the three SQL
    database file types (*.ldf, *.mdf, *.ndf).

.PARAMETER IncludeRule
    Array of hashtables @{ Path = '...'; ManagementClass = '...' } to bind a
    management class to a specific include path. Path is taken verbatim (include
    the pattern, e.g. 'F:\Daten\SQL\Backup\...\*'). ManagementClass is optional
    and falls back to -ManagementClass. When omitted, the classic User-db/Sys-db
    model (plus -AdditionalIncludePaths) is used with the default class.

.PARAMETER UseInclExclFile
    Resolve the INCLEXCL option from the dsm.opt and write the managed block into
    that referenced include/exclude file instead of the dsm.opt itself.

.PARAMETER InclExclPath
    Explicit path to the include/exclude file to write into (overrides INCLEXCL
    resolution and the dsm.opt target).

.PARAMETER UseDiff
    When set, forces the management class to MC_B_NL.NL_42.42.NA
    (required for diff backup strategy).

.PARAMETER SqlCredential
    PSCredential for the SQL connection (to read the backup directory).

.PARAMETER Credential
    PSCredential for remote file access (Copy-Item, Test-Path) on the target computer.

.PARAMETER OutputPath
    Output directory for the configuration report.
    Default: Get-sqmDefaultOutputPath.

.PARAMETER ContinueOnError
    Continue on error (not applicable here as there is no loop).

.PARAMETER EnableException
    Throw exceptions immediately (instead of silent error objects).

.PARAMETER Confirm
    Request confirmation before writing the dsm.opt.

.PARAMETER WhatIf
    Shows what would happen without making any changes.

.EXAMPLE
    Invoke-sqmTsmConfiguration -ManagementClass MC_B_NL.NL_42.42.NA

.EXAMPLE
    Invoke-sqmTsmConfiguration -ComputerName "SQL01" -UseDiff

.EXAMPLE
    Invoke-sqmTsmConfiguration -ComputerName "SQL01" -AdditionalIncludePaths "E:\Archive"

.EXAMPLE
    # Write into the INCLEXCL-referenced ie file, with custom excludes and per-path classes
    Invoke-sqmTsmConfiguration -ComputerName "SQL01" -UseInclExclFile `
        -ExcludePatterns 'S:\...\*', '*:\...\*.ldf', '*:\...\*.mdf', '*:\...\*.ndf' `
        -IncludeRule @(
            @{ Path = 'F:\Daten\SQL\Backup\...\*';   ManagementClass = 'MC_B_NL.NL_35.35.NA' },
            @{ Path = 'F:\Daten\SQL\Backup\01Year\*'; ManagementClass = 'MC_B_NL_NL_365.365.NA' }
        )

.OUTPUTS
    PSCustomObject with ComputerName, DsmOptPath, TargetFile, BackupDirectory,
    ManagementClass, UseDiff, ExcludesWritten, IncludesWritten,
    BackupCreated, Status, Message, ReportPath.
#>
function Invoke-sqmTsmConfiguration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[string]$DsmOptPath,
		[Parameter(Mandatory = $false)]
		[string]$BackupDirectory,
		[Parameter(Mandatory = $false)]
		[string[]]$AdditionalIncludePaths = @(),
		[Parameter(Mandatory = $false)]
		# Hinweis: ValidateSet wurde durch ValidatePattern ersetzt, da reale Umgebungen
		# weitere Klassen nutzen (z. B. MC_B_2.2_15.15.NA_IMG, MC_B_NL_NL_365.365.NA),
		# die das frühere 6-Werte-Set abgelehnt hätte. Alte gültige Aufrufe bleiben gültig.
		[ValidatePattern('^MC_[A-Za-z0-9._]+$')]
		[string]$ManagementClass = 'MC_B_NL.NL_42.42.NA',
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludePatterns,
		[Parameter(Mandatory = $false)]
		[hashtable[]]$IncludeRule = @(),
		[Parameter(Mandatory = $false)]
		[switch]$UseInclExclFile,
		[Parameter(Mandatory = $false)]
		[string]$InclExclPath,
		[Parameter(Mandatory = $false)]
		[switch]$UseDiff,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		if (-not $SqlInstance) { $SqlInstance = $ComputerName }
		Invoke-sqmLogging -Message "Starte $functionName auf $ComputerName (SQL-Instanz: $SqlInstance)" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		$result = [PSCustomObject]@{
			ComputerName    = $ComputerName
			DsmOptPath	    = $null
			TargetFile	    = $null
			BackupDirectory = $null
			ManagementClass = $null
			UseDiff		    = [bool]$UseDiff
			ExcludesWritten = 0
			IncludesWritten = 0
			BackupCreated   = $false
			Status		    = 'Unknown'
			Message		    = $null
			ReportPath	    = $null
		}
		
		try
		{
			# --- Diff-Validierung ---
			if ($UseDiff)
			{
				if ($ManagementClass -and $ManagementClass -ne 'MC_B_NL.NL_42.42.NA')
				{
					$msg = "Bei -UseDiff ist MC_B_NL.NL_42.42.NA Pflicht. Angegebene Klasse '$ManagementClass' ist nicht zulaessig."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					$result.Status = 'ValidationFailed'
					$result.Message = $msg
					return $result
				}
				$ManagementClass = 'MC_B_NL.NL_42.42.NA'
				Invoke-sqmLogging -Message "UseDiff: Management-Klasse auf $ManagementClass gesetzt." -FunctionName $functionName -Level "INFO"
			}
			$result.ManagementClass = $ManagementClass
			
			# --- Backup-Verzeichnis ermitteln ---
			$effBackupDir = $BackupDirectory
			if (-not $effBackupDir)
			{
				try
				{
					$connParams = @{ SqlInstance = $SqlInstance }
					if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
					$regResult = Invoke-DbaQuery @connParams -Query @"
DECLARE @BackupDirectory NVARCHAR(4000);
EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer',
    N'BackupDirectory',
    @BackupDirectory OUTPUT;
SELECT @BackupDirectory AS BackupDirectory;
"@ -ErrorAction Stop
					$effBackupDir = $regResult.BackupDirectory
				}
				catch
				{
					Invoke-sqmLogging -Message "SQL-Registry-Abfrage fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE"
				}
				if (-not $effBackupDir)
				{
					try
					{
						$srv = Connect-DbaInstance @connParams -ErrorAction SilentlyContinue
						$effBackupDir = $srv.BackupDirectory
					}
					catch { }
				}
			}
			if (-not $effBackupDir)
			{
				$effBackupDir = 'C:\Program Files\Microsoft SQL Server\MSSQL\Backup'
				Invoke-sqmLogging -Message "Kein Backup-Verzeichnis ermittelbar - verwende Standard: $effBackupDir" -FunctionName $functionName -Level "WARNING"
			}
			$result.BackupDirectory = $effBackupDir
			Invoke-sqmLogging -Message "Backup-Verzeichnis: $effBackupDir" -FunctionName $functionName -Level "INFO"
			
			# --- dsm.opt-Pfad ermitteln (für Record + INCLEXCL-Auflösung) ---
			$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
			$localDsmOpt = $DsmOptPath
			if (-not $localDsmOpt)
			{
				$localDsmOpt = _FindDsmOptPath -ComputerName $ComputerName -IsLocal $isLocal -Credential $Credential
			}
			$result.DsmOptPath = $localDsmOpt

			# --- Zieldatei bestimmen: dsm.opt ODER ausgelagerte Include/Exclude-Datei ---
			# Reale Umgebungen lagern INCLUDE/EXCLUDE über die INCLEXCL-Option in eine separate
			# Datei (z. B. ie_dsm.opt) aus, die VOR der dsm.opt verarbeitet wird. Mit -InclExclPath
			# oder -UseInclExclFile schreiben wir dorthin statt in die dsm.opt.
			$targetLocal = $null
			$allowCreate = $false
			if ($InclExclPath)
			{
				$targetLocal = $InclExclPath
				$allowCreate = $true
				Invoke-sqmLogging -Message "Zieldatei explizit (InclExclPath): $targetLocal" -FunctionName $functionName -Level "INFO"
			}
			elseif ($UseInclExclFile)
			{
				if (-not $localDsmOpt)
				{
					$msg = "dsm.opt nicht gefunden - INCLEXCL-Verweis nicht auflösbar. Bitte -DsmOptPath oder -InclExclPath angeben."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					$result.Status = 'DsmOptNotFound'
					$result.Message = $msg
					return $result
				}
				$dsmAccess = if ($isLocal) { $localDsmOpt }
				else { _ToUncPath -ComputerName $ComputerName -LocalPath $localDsmOpt }
				$targetLocal = _ResolveInclExclPath -DsmOptAccessPath $dsmAccess
				if (-not $targetLocal)
				{
					$msg = "Keine INCLEXCL-Option in dsm.opt gefunden ($dsmAccess). Bitte -InclExclPath explizit angeben."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					$result.Status = 'InclExclNotFound'
					$result.Message = $msg
					return $result
				}
				$allowCreate = $true
				Invoke-sqmLogging -Message "INCLEXCL-Verweis aufgelöst: $targetLocal" -FunctionName $functionName -Level "INFO"
			}
			else
			{
				if (-not $localDsmOpt)
				{
					$msg = "dsm.opt konnte nicht gefunden werden. Bitte -DsmOptPath explizit angeben."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					$result.Status = 'DsmOptNotFound'
					$result.Message = $msg
					return $result
				}
				$targetLocal = $localDsmOpt
			}
			$result.TargetFile = $targetLocal

			$accessPath = if ($isLocal) { $targetLocal }
			else { _ToUncPath -ComputerName $ComputerName -LocalPath $targetLocal }
			Invoke-sqmLogging -Message "Zieldatei Zugriffspfad: $accessPath" -FunctionName $functionName -Level "VERBOSE"
			
			# --- Zieldatei lesen (bei ausgelagerter ie-Datei ggf. neu anlegen) ---
			$existingLines = [System.Collections.Generic.List[string]]::new()
			$targetExists = Test-Path -Path $accessPath -ErrorAction SilentlyContinue
			if ($targetExists)
			{
				try
				{
					$rawLines = Get-Content -Path $accessPath -Encoding UTF8 -ErrorAction Stop
					foreach ($l in $rawLines) { $existingLines.Add($l) }
					Invoke-sqmLogging -Message "Zieldatei gelesen: $($existingLines.Count) Zeilen" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$msg = "Zieldatei konnte nicht gelesen werden: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					$result.Status = 'ReadFailed'
					$result.Message = $msg
					return $result
				}
			}
			elseif ($allowCreate)
			{
				Invoke-sqmLogging -Message "Zieldatei existiert noch nicht - wird neu angelegt: $accessPath" -FunctionName $functionName -Level "INFO"
			}
			else
			{
				$msg = "dsm.opt nicht gefunden: $accessPath"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Status = 'DsmOptNotFound'
				$result.Message = $msg
				return $result
			}

			# --- Backup der Zieldatei (nur wenn vorhanden) ---
			if ($targetExists)
			{
				$bakPath = $accessPath + '.bak'
				try
				{
					Copy-Item -Path $accessPath -Destination $bakPath -Force -ErrorAction Stop
					$result.BackupCreated = $true
					Invoke-sqmLogging -Message "Backup angelegt: $bakPath" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$msg = "Backup der Zieldatei fehlgeschlagen: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					$result.Status = 'BackupFailed'
					$result.Message = $msg
					return $result
				}
			}
			
			# --- Exclude-Patterns vorbereiten ---
			# Default: die drei SQL-Datenbankdatei-Typen. Mit -ExcludePatterns überschreibbar
			# (eigene Patterns, z. B. 'S:\...\*'). Patterns ohne EXCLUDE-Schlüsselwort/Quotes.
			$effExcludePatterns = if ($PSBoundParameters.ContainsKey('ExcludePatterns') -and $ExcludePatterns)
			{
				$ExcludePatterns
			}
			else
			{
				@('*:\...\*.ldf', '*:\...\*.mdf', '*:\...\*.ndf')
			}

			# --- Include-Regeln vorbereiten ---
			# Mit -IncludeRule (@{ Path = '...'; ManagementClass = '...' }) lassen sich pro Pfad
			# eigene Managementklassen setzen (z. B. 365-Tage-Klasse für ein 01Year-Verzeichnis).
			# Path wird verbatim übernommen (inkl. Pattern wie \...\* ). Ohne -IncludeRule gilt
			# das klassische User-db/Sys-db-Modell mit der Default-$ManagementClass.
			$effIncludeRules = [System.Collections.Generic.List[object]]::new()
			if ($IncludeRule -and $IncludeRule.Count -gt 0)
			{
				foreach ($rule in $IncludeRule)
				{
					$rPath = $rule['Path']
					if (-not $rPath -or -not "$rPath".Trim()) { continue }
					$rMc = $rule['ManagementClass']
					if (-not $rMc -or -not "$rMc".Trim()) { $rMc = $ManagementClass }
					$effIncludeRules.Add([PSCustomObject]@{ Path = "$rPath".Trim(); ManagementClass = "$rMc".Trim() })
				}
			}
			else
			{
				$effIncludeRules.Add([PSCustomObject]@{ Path = "$effBackupDir\User-db\*"; ManagementClass = $ManagementClass })
				$effIncludeRules.Add([PSCustomObject]@{ Path = "$effBackupDir\Sys-db\*"; ManagementClass = $ManagementClass })
				foreach ($p in $AdditionalIncludePaths)
				{
					if ($p -and $p.Trim()) { $effIncludeRules.Add([PSCustomObject]@{ Path = ($p.TrimEnd('\') + '\*'); ManagementClass = $ManagementClass }) }
				}
			}

			# --- Verwaltungsblock erstellen ---
			$blockLines = [System.Collections.Generic.List[string]]::new()
			$blockLines.Add('')
			$blockLines.Add('* --- dtcSqlTools BEGIN ---')
			$blockLines.Add("* Konfiguriert von sqmSQLTool Invoke-sqmTsmConfiguration")
			$blockLines.Add("* Zeitpunkt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
			$blockLines.Add("* Server: $ComputerName  |  SQL-Backup: $effBackupDir")
			$blockLines.Add("* UseDiff: $UseDiff  |  Default-ManagementClass: $ManagementClass")
			$blockLines.Add('*')
			$blockLines.Add('* Vom TSM-Backup ausschliessen:')
			foreach ($excl in $effExcludePatterns)
			{
				$p = "$excl".Trim()
				if (-not $p) { continue }
				$blockLines.Add("EXCLUDE `"$p`"")
				$result.ExcludesWritten++
			}
			$blockLines.Add('*')
			$blockLines.Add('* Backup-Verzeichnisse einschliessen (mit Management-Klasse):')
			foreach ($rule in $effIncludeRules)
			{
				$blockLines.Add("INCLUDE `"$($rule.Path)`" $($rule.ManagementClass)")
				$result.IncludesWritten++
			}
			$blockLines.Add('*')
			$blockLines.Add('* --- dtcSqlTools END ---')
			$blockLines.Add('')
			
			# --- Vorhandenen Block entfernen / ersetzen ---
			$beginMarker = '* --- dtcSqlTools BEGIN ---'
			$endMarker = '* --- dtcSqlTools END ---'
			$beginIdx = -1; $endIdx = -1
			for ($i = 0; $i -lt $existingLines.Count; $i++)
			{
				if ($existingLines[$i].Trim() -eq $beginMarker) { $beginIdx = $i }
				if ($existingLines[$i].Trim() -eq $endMarker) { $endIdx = $i }
			}
			
			$newLines = [System.Collections.Generic.List[string]]::new()
			if ($beginIdx -ge 0 -and $endIdx -gt $beginIdx)
			{
				for ($i = 0; $i -lt $beginIdx; $i++)
				{
					if ($i -eq $beginIdx - 1 -and $existingLines[$i].Trim() -eq '') { continue }
					$newLines.Add($existingLines[$i])
				}
				foreach ($l in $blockLines) { $newLines.Add($l) }
				for ($i = $endIdx + 1; $i -lt $existingLines.Count; $i++) { $newLines.Add($existingLines[$i]) }
				Invoke-sqmLogging -Message "Vorhandenen dtcSqlTools-Block ersetzt." -FunctionName $functionName -Level "INFO"
			}
			else
			{
				foreach ($l in $existingLines) { $newLines.Add($l) }
				foreach ($l in $blockLines) { $newLines.Add($l) }
				Invoke-sqmLogging -Message "dtcSqlTools-Block am Ende der Zieldatei eingefuegt." -FunctionName $functionName -Level "INFO"
			}
			
			# --- Schreiben ---
			if ($PSCmdlet.ShouldProcess($accessPath, "Zieldatei schreiben"))
			{
				try
				{
					$newLines | Out-File -FilePath $accessPath -Encoding UTF8 -Force -ErrorAction Stop
					Invoke-sqmLogging -Message "Zieldatei geschrieben: $($newLines.Count) Zeilen" -FunctionName $functionName -Level "INFO"
					$result.Status = 'Success'
					$result.Message = "Konfiguriert ($accessPath): $($result.ExcludesWritten) EXCLUDE(s), $($result.IncludesWritten) INCLUDE(s), Default-MgmtClass: $ManagementClass"
				}
				catch
				{
					$msg = "Zieldatei konnte nicht geschrieben werden: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					if ($EnableException) { throw $msg }
					$result.Status = 'WriteFailed'
					$result.Message = $msg
					return $result
				}
			}
			else
			{
				$result.Status = 'WhatIf'
				$result.Message = "WhatIf: Zieldatei wuerde geschrieben werden ($($newLines.Count) Zeilen)."
			}
			
			# --- Bericht schreiben (optional) ---
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			$datestamp = Get-Date -Format 'yyyy-MM-dd'
			$safeComp = $ComputerName -replace '[\\/:*?"<>|]', '_'
			$reportFile = Join-Path $OutputPath "TsmConfiguration_${safeComp}_${datestamp}.txt"
			$result.ReportPath = $reportFile
			$exclDisplay = ($effExcludePatterns | ForEach-Object { "EXCLUDE `"$_`"" }) -join "`n  "
			$incDisplay = ($effIncludeRules | ForEach-Object { "INCLUDE `"$($_.Path)`" $($_.ManagementClass)" }) -join "`n  "
			@"
# ================================================================
# sqmSQLTool - TSM Konfigurationsbericht
# Computer       : $ComputerName
# Datum          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# dsm.opt        : $($result.DsmOptPath)
# Zieldatei      : $accessPath
# Backup-Pfad    : $effBackupDir
# Default-MgmtCls: $ManagementClass
# UseDiff        : $UseDiff
# Status         : $($result.Status)
# ================================================================

EXCLUDEs:
  $exclDisplay

INCLUDEs (mit ManagementClass):
  $incDisplay
"@ | Out-File -FilePath $reportFile -Encoding UTF8 -Force
			Copy-sqmToCentralPath -Path $reportFile
			Invoke-sqmLogging -Message "Bericht erstellt: $reportFile" -FunctionName $functionName -Level "INFO"
			
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Allgemeiner Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$result.Status = 'Failed'
			$result.Message = $errMsg
		}
		return $result
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}

# --- Private Hilfsfunktionen (nicht exportiert) ---
function _FindDsmOptPath
{
	param (
		[string]$ComputerName = "localhost",
		[bool]$IsLocal = $true,
		[System.Management.Automation.PSCredential]$Credential
	)
	
	$candidates = [System.Collections.Generic.List[string]]::new()
	
	if ($IsLocal)
	{
		# Umgebungsvariablen pruefen
		if ($env:DSM_DIR) { $candidates.Add((Join-Path $env:DSM_DIR 'dsm.opt')) }
		if ($env:DSM_CONFIG) { $candidates.Add($env:DSM_CONFIG) }
		
		# Lokale Registry (64-Bit & 32-Bit)
		$regPaths = @(
			'HKLM:\SOFTWARE\IBM\ADSM\CurrentVersion\BackupClient',
			'HKLM:\SOFTWARE\WOW6432Node\IBM\ADSM\CurrentVersion\BackupClient'
		)
		foreach ($rp in $regPaths)
		{
			$val = (Get-ItemProperty $rp -Name 'DSM_DIR' -ErrorAction SilentlyContinue).DSM_DIR
			if ($val) { $candidates.Add((Join-Path $val 'dsm.opt')) }
		}
	}
	else
	{
		try
		{
			$hklm = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $ComputerName)
			$regKeys = @(
				'SOFTWARE\IBM\ADSM\CurrentVersion\BackupClient',
				'SOFTWARE\WOW6432Node\IBM\ADSM\CurrentVersion\BackupClient'
			)
			foreach ($keyPath in $regKeys)
			{
				$tsmKey = $hklm.OpenSubKey($keyPath)
				if ($tsmKey)
				{
					$regDsmDir = $tsmKey.GetValue('DSM_DIR', '')
					if ($regDsmDir) { $candidates.Add((Join-Path $regDsmDir 'dsm.opt')) }
					$tsmKey.Close()
				}
			}
			$hklm.Close()
		}
		catch
		{
			Write-Warning "Remote Registry Zugriff auf $ComputerName fehlgeschlagen: $($_.Exception.Message)"
		}
	}
	
	# Standardpfade hinzufuegen
	$candidates.Add('C:\Program Files\Tivoli\TSM\baclient\dsm.opt')
	$candidates.Add('C:\Program Files\IBM\TSM\baclient\dsm.opt')
	$candidates.Add('C:\Program Files\IBM\SpectrumProtect\baclient\dsm.opt')
	
	foreach ($c in ($candidates | Select-Object -Unique))
	{
		if (-not $c) { continue }
		
		$testPath = if ($IsLocal) { $c }
		else { _ToUncPath -ComputerName $ComputerName -LocalPath $c }
		
		# Test-Path mit New-PSDrive kombinieren, falls Credentials noetig sind
		if (Test-Path -Path $testPath -ErrorAction SilentlyContinue)
		{
			return $c
		}
	}
	return $null
}

function _ToUncPath
{
	param ([string]$ComputerName,
		[string]$LocalPath)
	# Entfernt Backslashes am Anfang fuer Join-Path Stabilitaet
	if ($LocalPath -match '^([A-Za-z]):\\(.*)$')
	{
		return "\\$ComputerName\$($Matches[1])`$\$($Matches[2])"
	}
	return "\\$ComputerName\$($LocalPath.Replace(':', '$'))"
}

function _ResolveInclExclPath
{
	# Liest die dsm.opt und gibt den über die INCLEXCL-Option referenzierten lokalen
	# Pfad zur ausgelagerten Include/Exclude-Datei zurück (z. B. ie_dsm.opt).
	# Unterstützt INCLEXCL und INCLEXCL.WINNT, ignoriert Kommentare (*), nimmt den
	# letzten Treffer. Gibt $null zurück, wenn keine INCLEXCL-Option vorhanden ist.
	param (
		[Parameter(Mandatory = $true)]
		[string]$DsmOptAccessPath
	)

	if (-not (Test-Path -Path $DsmOptAccessPath -ErrorAction SilentlyContinue)) { return $null }

	$resolved = $null
	try
	{
		$lines = Get-Content -Path $DsmOptAccessPath -Encoding UTF8 -ErrorAction Stop
	}
	catch { return $null }

	foreach ($line in $lines)
	{
		$trimmed = $line.Trim()
		if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('*')) { continue }
		if ($trimmed -match '^(?i)INCLEXCL(\.\w+)?\s+(.+)$')
		{
			$resolved = $Matches[2].Trim().Trim('"').Trim("'")
		}
	}
	return $resolved
}