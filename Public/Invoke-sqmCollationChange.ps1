<#
.SYNOPSIS
    Stellt die Server-Collation einer SQL Server-Instanz automatisch um.

.DESCRIPTION
    aendert die SQL Server-Instanz-Collation mithilfe der undokumentierten Methode
    "sqlservr.exe -m -T4022 -T3659 -q '<Collation>'". Diese Funktion ist nur fuer
    lokale Standalone-Instanzen geeignet (keine AGs, kein Failover-Cluster).

    Die Funktion fuehrt folgende Schritte aus:
    1. Pre-Flight-Check (Verbindung, aktuelle Collation, Ziel-Collation, Lokalitaet, Dienst, Adminrechte)
    2. Rollback-Dokumentation erstellen
    3. Optionales Backup aller User-Datenbanken (-BackupBeforeChange)
    4. SQL Server-Dienst stoppen
    5. sqlservr.exe mit neuer Collation starten (wartet auf Bereitschaft)
    6. Prozess beenden (sqlservr.exe beendet sich selbst)
    7. SQL Server-Dienst normal starten
    8. Verifikation der neuen Collation
    9. Optional: ALTER DATABASE ... COLLATE fuer User-Datenbanken (-IncludeUserDatabases)

.PARAMETER SqlInstance
    SQL Server-Instanz (muss lokal sein). Standard: aktueller Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung.

.PARAMETER NewCollation
    Ziel-Collation (z.?B. 'Latin1_General_CI_AS').

.PARAMETER IncludeUserDatabases
    Wenn gesetzt, wird die Default-Collation aller Benutzerdatenbanken ebenfalls geaendert.

.PARAMETER BackupBeforeChange
    Erstellt vor der aenderung ein Full-Backup aller Benutzerdatenbanken.

.PARAMETER ExcludeDatabase
    Datenbanken, die von -IncludeUserDatabases ausgeschlossen werden (Wildcards erlaubt).

.PARAMETER ServiceName
    Windows-Dienstname (wird automatisch aus SqlInstance ermittelt, falls nicht angegeben).

.PARAMETER StartupTimeoutSeconds
    Maximale Wartezeit auf sqlservr.exe im Minimal-Modus (Standard: 120).

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer Rollback-Dokumentation und Spalten-Skript.
    Standard: Get-sqmDefaultOutputPath.

.PARAMETER ContinueOnError
    Bei Fehler in einem Schritt mit dem naechsten fortfahren (selten verwendet).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.PARAMETER Confirm
    Fordert Bestaetigung vor dem Stoppen des Dienstes und der aenderung an.

.PARAMETER WhatIf
    Zeigt alle geplanten Schritte ohne Ausfuehrung.

.EXAMPLE
    Invoke-sqmCollationChange -NewCollation "Latin1_General_CI_AS"

.EXAMPLE
    Invoke-sqmCollationChange -SqlInstance "SQL01\INST2" -NewCollation "German_CI_AS" -IncludeUserDatabases -BackupBeforeChange

.NOTES
    Voraussetzungen: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath.
    Nur fuer lokale Standalone-Instanzen. AlwaysOn AGs werden erkannt und abgelehnt.
    Administratorrechte auf dem Host sind erforderlich.
#>
function Invoke-sqmCollationChange
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true, Position = 1)]
		[ValidateNotNullOrEmpty()]
		[string]$NewCollation,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeUserDatabases,
		[Parameter(Mandatory = $false)]
		[switch]$BackupBeforeChange,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[string]$ServiceName,
		[Parameter(Mandatory = $false)]
		[ValidateRange(30, 600)]
		[int]$StartupTimeoutSeconds = 120,
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
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
		
		$result = [PSCustomObject]@{
			SqlInstance		     = $SqlInstance
			OldCollation		 = $null
			NewCollation		 = $NewCollation
			Status			     = 'Unknown'
			UserDatabasesChanged = 0
			ColumnScriptPath	 = $null
			RollbackDocPath	     = $null
			Message			     = $null
		}
		
		$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
		$datestamp = Get-Date -Format 'yyyy-MM-dd'
		$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	}
	
	process
	{
		try
		{
			# -----------------------------------------------------------------
			# Schritt 1: Pre-Flight-Check
			# -----------------------------------------------------------------
			Write-Host "[$SqlInstance] Pre-Flight-Check..." -ForegroundColor Cyan
			
			# Verbindung herstellen
			$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop
			$oldCollation = $sqlSrv.Collation
			$result.OldCollation = $oldCollation
			Invoke-sqmLogging -Message "Aktuelle Collation: $oldCollation" -FunctionName $functionName -Level "INFO"
			
			if ($oldCollation -eq $NewCollation)
			{
				$result.Status = 'AlreadySet'
				$result.Message = "Collation ist bereits '$NewCollation'."
				Write-Host "  ? $($result.Message)" -ForegroundColor Green
				return $result
			}
			
			# Ziel-Collation validieren
			$valid = Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.fn_helpcollations() WHERE name = N'$($NewCollation -replace "'", "''")'" -ErrorAction SilentlyContinue
			if (-not $valid)
			{
				throw "Collation '$NewCollation' ist auf dieser Instanz nicht gueltig."
			}
			
			# Lokale Instanz pruefen
			$instanceHost = ($SqlInstance -split '\\')[0] -split ',' | Select-Object -First 1
			$isLocal = $instanceHost -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.', [System.Net.Dns]::GetHostName())
			if (-not $isLocal)
			{
				throw "Collation-aenderung erfordert lokale Ausfuehrung auf '$instanceHost'."
			}
			
			# sqlservr.exe-Pfad ermitteln
			$sqlBinPath = $null
			$instanceRegName = if ($SqlInstance -match '\\') { ($SqlInstance -split '\\')[1].ToUpper() }
			else { 'MSSQLSERVER' }
			$regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
			$instList = Get-ItemProperty "$regBase\Instance Names\SQL" -ErrorAction SilentlyContinue
			$regInstKey = $instList.$instanceRegName
			if ($regInstKey)
			{
				$binRoot = (Get-ItemProperty "$regBase\$regInstKey\Setup" -ErrorAction SilentlyContinue).SQLBinRoot
				if ($binRoot)
				{
					$candidate = Join-Path $binRoot 'sqlservr.exe'
					if (Test-Path $candidate) { $sqlBinPath = $candidate }
				}
			}
			if (-not $sqlBinPath)
			{
				$svcName = if ($SqlInstance -match '\\') { "MSSQL`$$($SqlInstance.Split('\')[1].ToUpper())" }
				else { 'MSSQLSERVER' }
				$svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
				if ($svc)
				{
					$exePath = ($svc.PathName -split '"')[1]
					if ($exePath -and (Test-Path $exePath)) { $sqlBinPath = $exePath }
				}
			}
			if (-not $sqlBinPath)
			{
				throw "sqlservr.exe konnte nicht gefunden werden. Bitte -ServiceName angeben."
			}
			
			# Windows-Dienstname
			if (-not $ServiceName)
			{
				$ServiceName = if ($SqlInstance -match '\\') { "MSSQL`$$($SqlInstance.Split('\')[1].ToUpper())" }
				else { 'MSSQLSERVER' }
			}
			$svcObj = Get-Service -Name $ServiceName -ErrorAction Stop
			Invoke-sqmLogging -Message "Windows-Dienst: $ServiceName (Status: $($svcObj.Status))" -FunctionName $functionName -Level "INFO"
			
			# AG-Mitgliedschaft pruefen
			$agCount = Invoke-DbaQuery @connParams -Query "SELECT COUNT(*) FROM sys.availability_replicas WHERE replica_server_name = @@SERVERNAME" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Column1
			if ($agCount -gt 0)
			{
				$agNames = Invoke-DbaQuery @connParams -Query "SELECT ag.name FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id WHERE ar.replica_server_name = @@SERVERNAME" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty name -Join ','
				throw "AlwaysOn Availability Group erkannt: $agNames. Vor der Collation-aenderung muessen alle AG-Datenbanken manuell ausgetragen werden."
			}
			
			# Adminrechte
			$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
			if (-not $isAdmin)
			{
				throw "Lokale Administratorrechte erforderlich. PowerShell als Administrator starten."
			}
			
			Write-Host "  ? Pre-Flight-Check OK - $oldCollation ? $NewCollation" -ForegroundColor Green
			
			# -----------------------------------------------------------------
			# Schritt 2: Rollback-Dokumentation
			# -----------------------------------------------------------------
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			$rollbackFile = Join-Path $OutputPath "CollationChange_Rollback_${safeInst}_${datestamp}.txt"
			$result.RollbackDocPath = $rollbackFile
			$rollbackLines = [System.Collections.Generic.List[string]]::new()
			$rollbackLines.Add("# ================================================================")
			$rollbackLines.Add("# MSSQLTools - Collation Change ROLLBACK-DOKUMENTATION")
			$rollbackLines.Add("# Instanz     : $SqlInstance")
			$rollbackLines.Add("# Zeitpunkt   : $timestamp")
			$rollbackLines.Add("# Alte Collation: $oldCollation")
			$rollbackLines.Add("# Neue Collation: $NewCollation")
			$rollbackLines.Add("# ================================================================")
			$rollbackLines.Add("")
			$rollbackLines.Add("# --- ROLLBACK: Instanz-Collation wiederherstellen ---")
			$rollbackLines.Add("# Invoke-sqmCollationChange -SqlInstance '$SqlInstance' -NewCollation '$oldCollation'")
			$rollbackLines.Add("")
			# User-DB-Collations dokumentieren
			$userDbs = Get-DbaDatabase @connParams | Where-Object { -not $_.IsSystemObject -and $_.Status -eq 'Normal' } | Where-Object { -not ($ExcludeDatabase | Where-Object { $_.Name -like $_ }) }
			if ($userDbs)
			{
				$rollbackLines.Add("# --- ROLLBACK: User-DB-Collations (ALTER DATABASE) ---")
				foreach ($db in $userDbs)
				{
					$rollbackLines.Add("ALTER DATABASE [$($db.Name)] COLLATE $($db.Collation);")
				}
				$rollbackLines.Add("")
			}
			$rollbackLines | Out-File -FilePath $rollbackFile -Encoding UTF8 -Force
			# Kopie in CentralPath (optional)
			$centralPath = Get-sqmConfig -Key 'CentralPath'
			if ($centralPath)
			{
				$centralDir = Join-Path $centralPath (Split-Path $rollbackFile -Parent)
				if (-not (Test-Path $centralDir)) { New-Item -ItemType Directory -Path $centralDir -Force | Out-Null }
				Copy-Item $rollbackFile (Join-Path $centralDir (Split-Path $rollbackFile -Leaf)) -Force -ErrorAction SilentlyContinue
			}
			Invoke-sqmLogging -Message "Rollback-Dokumentation: $rollbackFile" -FunctionName $functionName -Level "INFO"
			
			# WhatIf
			if ($WhatIfPreference)
			{
				Write-Host "  [WhatIf] Folgende Schritte wuerden ausgefuehrt:" -ForegroundColor Yellow
				Write-Host "    - Backup: $(if ($BackupBeforeChange) { 'Ja' }
					else { 'Nein' })"
				Write-Host "    - Stop-Service $ServiceName"
				Write-Host "    - sqlservr.exe -m -T4022 -T3659 -q `"$NewCollation`""
				Write-Host "    - Start-Service $ServiceName"
				Write-Host "    - Verifikation"
				if ($IncludeUserDatabases) { Write-Host "    - ALTER DATABASE ... COLLATE fuer $($userDbs.Count) User-DBs" }
				$result.Status = 'WhatIf'
				$result.Message = 'WhatIf: Keine aenderungen vorgenommen.'
				return $result
			}
			
			if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Collation aendern: $oldCollation ? $NewCollation (Dienst wird gestoppt)"))
			{
				$result.Status = 'Cancelled'
				$result.Message = 'Abgebrochen.'
				return $result
			}
			
			# -----------------------------------------------------------------
			# Schritt 3: Optionales Backup
			# -----------------------------------------------------------------
			if ($BackupBeforeChange -and $userDbs)
			{
				Write-Host "  Backup vor Collation-aenderung..." -ForegroundColor Gray
				$backupDir = Join-Path $sqlSrv.BackupDirectory 'CollationChange'
				if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
				foreach ($db in $userDbs)
				{
					try
					{
						Backup-DbaDatabase @connParams -Database $db.Name -BackupDirectory $backupDir -Type Full -CompressBackup -EnableException -ErrorAction Stop | Out-Null
						Write-Verbose "    Backup: $($db.Name) OK"
					}
					catch
					{
						Write-Warning "    Backup '$($db.Name)' fehlgeschlagen: $($_.Exception.Message)"
					}
				}
				Write-Host "  ? Backups abgeschlossen." -ForegroundColor Green
			}
			
			# -----------------------------------------------------------------
			# Schritt 4: Dienst stoppen
			# -----------------------------------------------------------------
			Write-Host "  Stoppe SQL Server-Dienst '$ServiceName'..." -ForegroundColor Gray
			Stop-Service -Name $ServiceName -Force -ErrorAction Stop
			(Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
			Write-Host "  ? Dienst gestoppt." -ForegroundColor Green
			
			# -----------------------------------------------------------------
			# Schritt 5-7: sqlservr.exe im Minimal-Modus starten
			# -----------------------------------------------------------------
			Write-Host "  Starte sqlservr.exe im Minimal-Modus mit neuer Collation..." -ForegroundColor Gray
			$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
			$startInfo.FileName = $sqlBinPath
			$startInfo.Arguments = "-m -T4022 -T3659 -q `"$NewCollation`""
			$startInfo.UseShellExecute = $false
			$startInfo.CreateNoNewWindow = $true
			$startInfo.RedirectStandardOutput = $true
			$startInfo.RedirectStandardError = $true
			$sqlProc = [System.Diagnostics.Process]::Start($startInfo)
			
			# Warten auf Bereitschaft (Errorlog pruefen)
			$errorlogPath = $null
			try
			{
				$errorlogPath = Invoke-DbaQuery @connParams -Query "EXEC xp_readerrorlog 0, 1, N'Logging SQL Server messages in file'" -ErrorAction SilentlyContinue |
				Select-Object -Last 1 -ExpandProperty Text -ErrorAction SilentlyContinue
				if ($errorlogPath -match "'(.+ERRORLOG)'") { $errorlogPath = $Matches[1] }
			}
			catch { }
			$deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
			$isReady = $false
			$readyTokens = @('Recovery is complete', 'SQL Server is now ready', 'Collation change successful', 'Server is listening on')
			while ((Get-Date) -lt $deadline -and -not $sqlProc.HasExited)
			{
				Start-Sleep -Milliseconds 500
				if ($errorlogPath -and (Test-Path $errorlogPath))
				{
					$tail = Get-Content -Path $errorlogPath -Tail 20 -ErrorAction SilentlyContinue
					if ($tail)
					{
						foreach ($token in $readyTokens)
						{
							if ($tail -match [regex]::Escape($token)) { $isReady = $true; break }
						}
					}
				}
				if ($isReady) { break }
			}
			if (-not $sqlProc.HasExited) { $sqlProc.Kill(); $null = $sqlProc.WaitForExit(10000) }
			Write-Host "  ? sqlservr.exe-Phase abgeschlossen." -ForegroundColor Green
			
			# -----------------------------------------------------------------
			# Schritt 8: Dienst normal starten
			# -----------------------------------------------------------------
			Write-Host "  Starte SQL Server-Dienst '$ServiceName'..." -ForegroundColor Gray
			Start-Service -Name $ServiceName -ErrorAction Stop
			(Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(120))
			Write-Host "  ? Dienst gestartet." -ForegroundColor Green
			Start-Sleep -Seconds 5
			
			# -----------------------------------------------------------------
			# Schritt 9: Verifikation
			# -----------------------------------------------------------------
			Write-Host "  Verifiziere neue Collation..." -ForegroundColor Gray
			$actualCollation = $null
			for ($i = 0; $i -lt 5; $i++)
			{
				try
				{
					Start-Sleep -Seconds 3
					$verifySrv = Connect-DbaInstance @connParams -ErrorAction Stop
					$actualCollation = $verifySrv.Collation
					break
				}
				catch { Write-Verbose "Verbindungsversuch $($i + 1) fehlgeschlagen" }
			}
			if ($actualCollation -ne $NewCollation)
			{
				throw "Collation nach aenderung: '$actualCollation' (erwartet: '$NewCollation')"
			}
			Write-Host "  ? Collation erfolgreich geaendert: $oldCollation ? $actualCollation" -ForegroundColor Green
			$result.Status = 'Success'
			$result.NewCollation = $actualCollation
			
			# -----------------------------------------------------------------
			# Schritt 10: User-DB-Collation anpassen (optional)
			# -----------------------------------------------------------------
			if ($IncludeUserDatabases -and $userDbs)
			{
				Write-Host "  Passe User-DB-Collation an ($($userDbs.Count) Datenbanken)..." -ForegroundColor Gray
				$changed = 0
				$colScript = [System.Collections.Generic.List[string]]::new()
				$colScript.Add("-- ================================================================")
				$colScript.Add("-- MSSQLTools - Spalten mit expliziter Collation (manuell ausfuehren)")
				$colScript.Add("-- Instanz   : $SqlInstance")
				$colScript.Add("-- Neue Collation: $NewCollation")
				$colScript.Add("-- ================================================================")
				$colScript.Add("")
				foreach ($db in $userDbs)
				{
					try
					{
						Invoke-DbaQuery @connParams -Database 'master' -Query "ALTER DATABASE [$($db.Name)] COLLATE $NewCollation;" -ErrorAction Stop | Out-Null
						$changed++
					}
					catch
					{
						Write-Warning "    ALTER DATABASE [$($db.Name)] fehlgeschlagen: $($_.Exception.Message)"
					}
					# Spalten mit expliziter Collation ermitteln
					$cols = Invoke-DbaQuery @connParams -Database $db.Name -Query @"
SELECT s.name AS SchemaName, t.name AS TableName, c.name AS ColumnName,
       tp.name AS DataType, c.max_length AS MaxLength, c.is_nullable AS IsNullable
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.types tp ON c.user_type_id = tp.user_type_id
WHERE c.collation_name IS NOT NULL AND c.collation_name <> DATABASEPROPERTYEX(DB_NAME(), 'Collation')
"@ -ErrorAction SilentlyContinue
					if ($cols)
					{
						$colScript.Add("-- === Datenbank: $($db.Name) ===")
						$colScript.Add("USE [$($db.Name)];")
						$colScript.Add("GO")
						foreach ($c in $cols)
						{
							$nullable = if ($c.IsNullable) { 'NULL' }
							else { 'NOT NULL' }
							$len = if ($c.MaxLength -eq -1) { 'MAX' }
							elseif ($c.DataType -in 'nvarchar', 'nchar', 'ntext') { $c.MaxLength / 2 }
							else { $c.MaxLength }
							$type = if ($c.DataType -in 'varchar', 'nvarchar', 'char', 'nchar') { "$($c.DataType)($len)" }
							else { $c.DataType }
							$colScript.Add("ALTER TABLE [$($c.SchemaName)].[$($c.TableName)] ALTER COLUMN [$($c.ColumnName)] $type COLLATE $NewCollation $nullable;")
						}
						$colScript.Add("")
					}
				}
				$result.UserDatabasesChanged = $changed
				Write-Host "  ? $changed von $($userDbs.Count) User-DBs angepasst." -ForegroundColor Green
				if ($colScript.Count -gt 10)
				{
					$colScriptPath = Join-Path $OutputPath "CollationChange_Columns_${safeInst}_${datestamp}.sql"
					$colScript | Out-File -FilePath $colScriptPath -Encoding UTF8 -Force
					$result.ColumnScriptPath = $colScriptPath
					Write-Host "  ?  Spalten-Skript: $colScriptPath (manuell pruefen und ausfuehren)" -ForegroundColor Yellow
				}
			}
			
			$result.Message = "Collation erfolgreich geaendert: $oldCollation ? $actualCollation"
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$result.Status = 'Failed'
			$result.Message = $errMsg
			if (-not $ContinueOnError) { throw }
		}
		finally
		{
			Write-Host ""
			Write-Host "  ? $($functionName) abgeschlossen." -ForegroundColor Green
			if ($result.RollbackDocPath) { Write-Host "    Rollback-Dokumentation: $($result.RollbackDocPath)" -ForegroundColor Gray }
			if ($result.ColumnScriptPath) { Write-Host "    Spalten-Skript: $($result.ColumnScriptPath)" -ForegroundColor Gray }
		}
		return $result
	}
}