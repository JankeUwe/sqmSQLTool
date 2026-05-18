<#
.SYNOPSIS
    Konfiguriert die IBM Spectrum Protect (TSM) Client-Optionsdatei dsm.opt
    fuer den Einsatz mit SQL Server-Backup-Verzeichnissen.

.DESCRIPTION
    Liest die vorhandene dsm.opt, ergaenzt oder ersetzt die relevanten
    Eintraege und schreibt die Datei zurueck. Vor jeder aenderung wird
    automatisch eine Sicherungskopie (dsm.opt.bak) angelegt.

    Konfigurierte Bereiche:
    - EXCLUDE fuer SQL Server-Datenbankdateien (*.mdf, *.ndf, *.ldf)
    - INCLUDE fuer Backup-Verzeichnisse (User-db, Sys-db, zusaetzliche Pfade)
    - MANAGEMENTCLASS fuer die Backup-Dateien (Aufbewahrungsdauer)

    Bei Verwendung von -UseDiff wird die Management-Klasse auf
    MC_B_NL.NL_42.42.NA erzwungen (42 Tage Aufbewahrung).

    Der Verwaltungsblock in der dsm.opt wird durch die Marker
    '* --- dtcSqlTools BEGIN ---' und '* --- dtcSqlTools END ---'
    begrenzt. Manuelle Eintraege ausserhalb bleiben erhalten.

.PARAMETER ComputerName
    Zielrechner (TSM-Client). Standard: aktueller Computername.

.PARAMETER SqlInstance
    SQL Server-Instanz zur Ermittlung des Backup-Verzeichnisses.
    Standard: $ComputerName.

.PARAMETER DsmOptPath
    Vollstaendiger Pfad zur dsm.opt auf dem Zielrechner.
    Wird automatisch ermittelt, wenn nicht angegeben.

.PARAMETER BackupDirectory
    Basis-Backup-Verzeichnis. Es werden die Unterverzeichnisse
    \User-db und \Sys-db als INCLUDE eingetragen.
    Standard: wird aus der SQL-Instanz ausgelesen (BackupDirectory).

.PARAMETER AdditionalIncludePaths
    Weitere Verzeichnisse, die als INCLUDE eingetragen werden sollen.

.PARAMETER ManagementClass
    TSM Management-Klasse fuer die Backup-Dateien.
    Erlaubt: MC_B_NL.NL_10.10.NA, MC_B_NL.NL_35.35.NA,
             MC_B_NL.NL_42.42.NA, MC_B_NL.NL_62.62.NA,
             MC_B_NL.NL_96.96.NA, MC_B_NL.NL_370.370.NA.
    Standard: MC_B_NL.NL_42.42.NA.

.PARAMETER UseDiff
    Wenn gesetzt, wird die Management-Klasse auf MC_B_NL.NL_42.42.NA
    erzwungen (Pflicht fuer Diff-Backup-Strategie).

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung (zum Auslesen des Backup-Verzeichnisses).

.PARAMETER Credential
    PSCredential fuer Remote-Dateizugriff (Copy-Item, Test-Path) auf dem Zielrechner.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer den Konfigurationsbericht.
    Standard: Get-sqmDefaultOutputPath.

.PARAMETER ContinueOnError
    Bei Fehler mit naechstem Schritt fortfahren (hier nicht zutreffend, da keine Schleife).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (statt stiller Fehlerobjekte).

.PARAMETER Confirm
    Bestaetigung vor dem Schreiben der dsm.opt anfordern.

.PARAMETER WhatIf
    Nur anzeigen, was passieren wuerde.

.EXAMPLE
    Invoke-sqmTsmConfiguration -ManagementClass MC_B_NL.NL_42.42.NA

.EXAMPLE
    Invoke-sqmTsmConfiguration -ComputerName "SQL01" -UseDiff

.EXAMPLE
    Invoke-sqmTsmConfiguration -ComputerName "SQL01" -AdditionalIncludePaths "E:\Archive"

.OUTPUTS
    PSCustomObject mit ComputerName, DsmOptPath, BackupDirectory,
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
		[ValidateSet(
					 'MC_B_NL.NL_10.10.NA',
					 'MC_B_NL.NL_35.35.NA',
					 'MC_B_NL.NL_42.42.NA',
					 'MC_B_NL.NL_62.62.NA',
					 'MC_B_NL.NL_96.96.NA',
					 'MC_B_NL.NL_370.370.NA'
					 )]
		[string]$ManagementClass = 'MC_B_NL.NL_42.42.NA',
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
			
			# --- dsm.opt-Pfad ermitteln ---
			$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
			$localDsmOpt = $DsmOptPath
			if (-not $localDsmOpt)
			{
				$localDsmOpt = _FindDsmOptPath -ComputerName $ComputerName -IsLocal $isLocal -Credential $Credential
			}
			if (-not $localDsmOpt)
			{
				$msg = "dsm.opt konnte nicht gefunden werden. Bitte -DsmOptPath explizit angeben."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Status = 'DsmOptNotFound'
				$result.Message = $msg
				return $result
			}
			$result.DsmOptPath = $localDsmOpt
			
			$accessPath = if ($isLocal) { $localDsmOpt }
			else { _ToUncPath -ComputerName $ComputerName -LocalPath $localDsmOpt }
			Invoke-sqmLogging -Message "dsm.opt Zugriffspfad: $accessPath" -FunctionName $functionName -Level "VERBOSE"
			
			# --- dsm.opt lesen ---
			if (-not (Test-Path -Path $accessPath -ErrorAction SilentlyContinue))
			{
				$msg = "dsm.opt nicht gefunden: $accessPath"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Status = 'DsmOptNotFound'
				$result.Message = $msg
				return $result
			}
			$existingLines = [System.Collections.Generic.List[string]]::new()
			try
			{
				$rawLines = Get-Content -Path $accessPath -Encoding UTF8 -ErrorAction Stop
				foreach ($l in $rawLines) { $existingLines.Add($l) }
				Invoke-sqmLogging -Message "dsm.opt gelesen: $($existingLines.Count) Zeilen" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$msg = "dsm.opt konnte nicht gelesen werden: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Status = 'ReadFailed'
				$result.Message = $msg
				return $result
			}
			
			# --- Backup der dsm.opt ---
			$bakPath = $accessPath + '.bak'
			try
			{
				Copy-Item -Path $accessPath -Destination $bakPath -Force -ErrorAction Stop
				$result.BackupCreated = $true
				Invoke-sqmLogging -Message "Backup angelegt: $bakPath" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$msg = "Backup der dsm.opt fehlgeschlagen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Status = 'BackupFailed'
				$result.Message = $msg
				return $result
			}
			
			# --- Include-Pfade vorbereiten ---
			$includePaths = [System.Collections.Generic.List[string]]::new()
			$includePaths.Add("$effBackupDir\User-db")
			$includePaths.Add("$effBackupDir\Sys-db")
			foreach ($p in $AdditionalIncludePaths)
			{
				if ($p -and $p.Trim()) { $includePaths.Add($p.TrimEnd('\')) }
			}
			
			# --- Verwaltungsblock erstellen ---
			$blockLines = [System.Collections.Generic.List[string]]::new()
			$blockLines.Add('')
			$blockLines.Add('* --- dtcSqlTools BEGIN ---')
			$blockLines.Add("* Konfiguriert von MSSQLTools Invoke-sqmTsmConfiguration")
			$blockLines.Add("* Zeitpunkt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
			$blockLines.Add("* Server: $ComputerName  |  SQL-Backup: $effBackupDir")
			$blockLines.Add("* UseDiff: $UseDiff  |  ManagementClass: $ManagementClass")
			$blockLines.Add('*')
			$blockLines.Add('* SQL Server Datenbankdateien vom TSM-Backup ausschliessen:')
			$excludePatterns = @('EXCLUDE "*:\...\*.ldf"', 'EXCLUDE "*:\...\*.mdf"', 'EXCLUDE "*:\...\*.ndf"')
			foreach ($excl in $excludePatterns) { $blockLines.Add($excl) }
			$result.ExcludesWritten = $excludePatterns.Count
			$blockLines.Add('*')
			$blockLines.Add('* SQL Server Backup-Verzeichnisse einschliessen:')
			foreach ($incPath in $includePaths)
			{
				$blockLines.Add("INCLUDE `"$incPath\*`"")
				$result.IncludesWritten++
			}
			$blockLines.Add('*')
			$blockLines.Add('* Management-Klasse fuer Backup-Dateien:')
			foreach ($incPath in $includePaths)
			{
				$blockLines.Add("INCLUDE `"$incPath\*`" $ManagementClass")
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
				Invoke-sqmLogging -Message "dtcSqlTools-Block am Ende der dsm.opt eingefuegt." -FunctionName $functionName -Level "INFO"
			}
			
			# --- Schreiben ---
			if ($PSCmdlet.ShouldProcess($accessPath, "dsm.opt schreiben"))
			{
				try
				{
					$newLines | Out-File -FilePath $accessPath -Encoding UTF8 -Force -ErrorAction Stop
					Invoke-sqmLogging -Message "dsm.opt geschrieben: $($newLines.Count) Zeilen" -FunctionName $functionName -Level "INFO"
					$result.Status = 'Success'
					$result.Message = "dsm.opt konfiguriert: $($result.ExcludesWritten) EXCLUDE(s), $($result.IncludesWritten) INCLUDE(s), ManagementClass: $ManagementClass"
				}
				catch
				{
					$msg = "dsm.opt konnte nicht geschrieben werden: $($_.Exception.Message)"
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
				$result.Message = "WhatIf: dsm.opt wuerde geschrieben werden ($($newLines.Count) Zeilen)."
			}
			
			# --- Bericht schreiben (optional) ---
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			$datestamp = Get-Date -Format 'yyyy-MM-dd'
			$safeComp = $ComputerName -replace '[\\/:*?"<>|]', '_'
			$reportFile = Join-Path $OutputPath "TsmConfiguration_${safeComp}_${datestamp}.txt"
			$result.ReportPath = $reportFile
			@"
# ================================================================
# MSSQLTools - TSM dsm.opt Konfigurationsbericht
# Computer      : $ComputerName
# Datum         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# dsm.opt       : $accessPath
# Backup-Pfad   : $effBackupDir
# ManagementClass: $ManagementClass
# UseDiff       : $UseDiff
# Status        : $($result.Status)
# ================================================================

EXCLUDEs:
  $($excludePatterns -join "`n  ")

INCLUDEs:
  $($includePaths -join "`n  ")

ManagementClass-Zuweisungen:
  $($includePaths -join "`n  ")
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