<#
.SYNOPSIS
Backs up user databases on a SQL Server instance.

.DESCRIPTION
Backs up all or selected user databases (no system databases) in full backup mode.
The target path is read from the server properties (BackupDirectory) and must end with "User-Db".

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

When -UseExcludeTable is set, the function reads the table master.dbo.sqm_BackupExclude
(created by Sync-sqmBackupExcludeTable) and skips all databases where IsActive=1 AND
IsOrphaned=0. If the table does not exist or contains no active, non-orphaned rows,
all databases are backed up normally.

.PARAMETER SqlInstance
The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.

.PARAMETER SqlCredential
Alternative credentials (PSCredential). If not specified, Windows authentication is used.

.PARAMETER Database
Name or array of user databases to back up. Ignored when -All is set.

.PARAMETER All
When set, all user databases on the instance are backed up.

.PARAMETER BackupPath
Optional direct backup path (overrides the value from server properties).
The path must end with "User-Db".

.PARAMETER EnableException
Switch to propagate exceptions immediately (by default errors are logged as warnings).

.EXAMPLE
# Back up all user databases on the current computer
Invoke-sqmUserDatabaseBackup -All

.EXAMPLE
# Back up specific databases on a remote server
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -Database "SalesDB", "InventoryDB"

.EXAMPLE
# With an alternative path
Invoke-sqmUserDatabaseBackup -All -BackupPath "D:\Backup\User-Db"

.EXAMPLE
# Back up all user databases, skipping databases listed in sqm_BackupExclude
Invoke-sqmUserDatabaseBackup -All -UseExcludeTable

.EXAMPLE
# Back up with exclude table on a remote instance
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -All -UseExcludeTable

.NOTES
Requires the dbatools module and existing Invoke-sqmLogging and Get-sqmServerSetting functions
(for the default backup path). The path must end with 'User-Db'.
Default for SqlInstance: $env:COMPUTERNAME (applies to all future versions).
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
		[switch]$UseExcludeTable,
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
			
			# Exclude-Tabelle auswerten wenn -UseExcludeTable gesetzt
			if ($UseExcludeTable)
			{
				Invoke-sqmLogging -Message "-UseExcludeTable gesetzt: Pruefe master.dbo.sqm_BackupExclude auf Ausnahmen." -FunctionName $functionName -Level "INFO"
				try
				{
					$excludeCheck = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master `
						-Query "SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude') AND type = 'U'" `
						-ErrorAction Stop

					if ($excludeCheck)
					{
						$excludeRows = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master `
							-Query "SELECT DatabaseName FROM master.dbo.sqm_BackupExclude WHERE IsActive = 1 AND IsOrphaned = 0" `
							-ErrorAction Stop

						if ($excludeRows)
						{
							$excludeNames = @($excludeRows | Select-Object -ExpandProperty DatabaseName)
							foreach ($excludeName in $excludeNames)
							{
								Invoke-sqmLogging -Message "Datenbank '$excludeName' ist in sqm_BackupExclude (IsActive=1, IsOrphaned=0) und wird uebersprungen." -FunctionName $functionName -Level "INFO"
							}
							$databases = $databases | Where-Object { $_.Name -notin $excludeNames }
							Invoke-sqmLogging -Message "Nach Exclude-Filter: $($databases.Count) Datenbank(en) verbleiben fuer das Backup." -FunctionName $functionName -Level "INFO"
						}
						else
						{
							Invoke-sqmLogging -Message "sqm_BackupExclude enthaelt keine aktiven Eintraege. Alle Datenbanken werden gesichert." -FunctionName $functionName -Level "INFO"
						}
					}
					else
					{
						Invoke-sqmLogging -Message "Tabelle sqm_BackupExclude nicht gefunden. Alle Datenbanken werden gesichert." -FunctionName $functionName -Level "WARNING"
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Konnte sqm_BackupExclude nicht auslesen: $($_.Exception.Message). Alle Datenbanken werden gesichert." -FunctionName $functionName -Level "WARNING"
				}
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