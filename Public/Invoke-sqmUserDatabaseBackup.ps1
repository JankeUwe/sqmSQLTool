<#
.SYNOPSIS
Sichert Benutzerdatenbanken einer SQL Server-Instanz.

.DESCRIPTION
Die Funktion sichert alle oder ausgewaehlte Benutzerdatenbanken (keine Systemdatenbanken)
im Full-Backup-Modus. Der Zielpfad wird aus den Server-Eigenschaften (BackupDirectory)
gelesen und muss auf "User-Db" enden.

Wenn kein SqlInstance-Parameter angegeben wird, wird standardmaessig der aktuelle
Computername ($env:COMPUTERNAME) verwendet. Diese Regel gilt fuer alle zukuenftigen
Versionen.

.PARAMETER SqlInstance
Die Ziel-SQL Server-Instanz (z.B. "localhost", "SQL01\INSTANCE").
Wenn nicht angegeben, wird der aktuelle Computername verwendet.

.PARAMETER SqlCredential
Alternative Anmeldeinformationen (PSCredential). Wenn nicht angegeben, wird
Windows-Authentifizierung verwendet.

.PARAMETER Database
Name oder Array von Benutzerdatenbanken, die gesichert werden sollen. Wird ignoriert,
wenn -All gesetzt ist.

.PARAMETER All
Wenn gesetzt, werden alle Benutzerdatenbanken auf der Instanz gesichert.

.PARAMETER BackupPath
Optionaler direkter Backup-Pfad (ueberschreibt den Wert aus Server-Eigenschaften).
Der Pfad muss auf "User-Db" enden.

.PARAMETER EnableException
Schalter, um Ausnahmen durchzulassen (standardmaessig werden Fehler als Warnung
protokolliert).

.EXAMPLE
# Alle Benutzerdatenbanken auf dem aktuellen Computer sichern
Invoke-sqmUserDatabaseBackup -All

.EXAMPLE
# Bestimmte Datenbanken auf einem entfernten Server sichern
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -Database "SalesDB", "InventoryDB"

.EXAMPLE
# Mit alternativem Pfad
Invoke-sqmUserDatabaseBackup -All -BackupPath "D:\Backup\User-Db"

.NOTES
Erfordert dbatools-Modul und eine vorhandene Funktion Invoke-sqmLogging sowie
Get-sqmServerSetting (fuer den Standard-Backup-Pfad). Der Pfad muss auf 'User-Db' enden.
Default fuer SqlInstance: $env:COMPUTERNAME (gilt fuer alle zukuenftigen Versionen).
#>

function Invoke-sqmUserDatabaseBackup
{
	[CmdletBinding(DefaultParameterSetName = 'Specific', SupportsShouldProcess = $true)]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false, ParameterSetName = 'Specific')]
		[string[]]$Database,
		[Parameter(Mandatory = $false, ParameterSetName = 'All')]
		[switch]$All,
		[Parameter(Mandatory = $false)]
		[string]$BackupPath,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		
		# Default fuer SqlInstance: aktueller Computername
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}
		
		# Pruefung auf dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance" -FunctionName $functionName -Level "INFO"
		
		# Backup-Pfad ermitteln
		if (-not $BackupPath)
		{
			try
			{
				# Korrekte Server-Eigenschaft fuer Backup-Verzeichnis: BackupDirectory
				$BackupPath = Get-sqmServerSetting -Name "BackupDirectory" -SqlInstance $SqlInstance -SqlCredential $SqlCredential -EnableException:$EnableException
				
				if ([string]::IsNullOrWhiteSpace($BackupPath))
				{
					$msg = "Server-Eigenschaft 'BackupDirectory' ist leer oder nicht gesetzt."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					throw $msg
				}
				
				Invoke-sqmLogging -Message "Backup-Pfad aus Server-Eigenschaften gelesen: $BackupPath" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "Konnte Backup-Pfad nicht aus Server-Eigenschaften lesen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				throw $errMsg
			}
		}
		
		# Pruefen, ob der Pfad auf "User-Db" endet
		if (-not ($BackupPath -match '\\User-Db$'))
		{
			$errMsg = "Der Backup-Pfad '$BackupPath' endet nicht mit 'User-Db'. Bitte korrigieren Sie die Server-Eigenschaft BackupDirectory oder geben Sie einen gueltigen Pfad an."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		# Sicherstellen, dass der Pfad existiert
		if (-not (Test-Path $BackupPath))
		{
			try
			{
				New-Item -Path $BackupPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
				Invoke-sqmLogging -Message "Verzeichnis $BackupPath wurde erstellt." -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "Konnte Backup-Verzeichnis nicht erstellen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				throw $errMsg
			}
		}
		
		# Ergebnisliste
		$results = @()
	}
	
	process
	{
		try
		{
			# Datenbanken ermitteln
			$dbParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				ExcludeSystem = $true
				ErrorAction   = 'Stop'
			}
			if ($EnableException) { $dbParams.EnableException = $true }
			
			if ($All)
			{
				Invoke-sqmLogging -Message "Parameter -All erkannt: Es werden ALLE Benutzerdatenbanken gesichert." -FunctionName $functionName -Level "INFO"
				$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
			}
			elseif ($Database)
			{
				Invoke-sqmLogging -Message "Filtere nach angegebenen Datenbanken: $($Database -join ', ')" -FunctionName $functionName -Level "DEBUG"
				$dbParams.Database = $Database
				$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
				# Pruefen, ob alle angeforderten Datenbanken existieren
				$foundDbNames = $databases | Select-Object -ExpandProperty Name
				$missing = $Database | Where-Object { $_ -notin $foundDbNames }
				if ($missing)
				{
					$msg = "Folgende Datenbanken wurden nicht gefunden oder sind nicht zugaenglich: $($missing -join ', ')"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = $missing -join ','
						BackupFile   = $null
						Status	     = "NotFound"
						Message	     = $msg
					}
				}
			}
			else
			{
				# Kein Filter und nicht -All: alle Benutzerdatenbanken (wie -All)
				Invoke-sqmLogging -Message "Keine Filterung - verarbeite alle Benutzerdatenbanken." -FunctionName $functionName -Level "DEBUG"
				$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
			}
			
			if (-not $databases)
			{
				$msg = "Keine Benutzerdatenbanken fuer Backup gefunden (oder keine zugaenglich)."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				$results += [PSCustomObject]@{
					SqlInstance  = $SqlInstance
					DatabaseName = $null
					BackupFile   = $null
					Status	     = "NoDatabasesFound"
					Message	     = $msg
				}
				return $results
			}
			
			# Backup fuer jede Datenbank
			foreach ($db in $databases)
			{
				$dbName = $db.Name
				$backupFile = Join-Path -Path $BackupPath -ChildPath "${dbName}_$(Get-Date -Format 'yyyyMMdd_HHmsqm').bak"
				
				$backupParams = @{
					SqlInstance    = $SqlInstance
					SqlCredential  = $SqlCredential
					Database	   = $dbName
					Path		   = $backupFile
					Type		   = 'Full'
					BackupFileName = $backupFile
					ErrorAction    = 'Stop'
				}
				if ($EnableException) { $backupParams.EnableException = $true }
				
				$actionMsg = "Sichere Datenbank '$dbName' nach '$backupFile'"
				if ($PSCmdlet.ShouldProcess($dbName, $actionMsg))
				{
					try
					{
						Invoke-sqmLogging -Message $actionMsg -FunctionName $functionName -Level "INFO"
						$backupResult = Backup-DbaDatabase @backupParams
						$successMsg = "Backup von '$dbName' erfolgreich abgeschlossen. Datei: $backupFile"
						Invoke-sqmLogging -Message $successMsg -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							BackupFile   = $backupFile
							Status	     = "Success"
							Message	     = $successMsg
						}
					}
					catch
					{
						$errMsg = "Fehler beim Backup von '$dbName': $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							BackupFile   = $null
							Status	     = "Failed"
							Message	     = $errMsg
						}
					}
				}
				else
				{
					$skipMsg = "WhatIf: Backup von '$dbName' uebersprungen."
					Invoke-sqmLogging -Message $skipMsg -FunctionName $functionName -Level "VERBOSE"
					$results += [PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = $dbName
						BackupFile   = $null
						Status	     = "WhatIfSkipped"
						Message	     = $skipMsg
					}
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{
				SqlInstance  = $SqlInstance
				DatabaseName = $null
				BackupFile   = $null
				Status	     = "GlobalError"
				Message	     = $errMsg
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Objekte zurueckgegeben." -FunctionName $functionName -Level "INFO"
		return $results
	}
}