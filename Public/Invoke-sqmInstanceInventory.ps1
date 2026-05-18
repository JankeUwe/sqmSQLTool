<#
.SYNOPSIS
    Erstellt eine vollstaendige Inventarisierung einer SQL Server-Instanz als strukturierten Bericht (TXT + CSV).

.DESCRIPTION
    Dokumentiert folgende Bereiche:
    - Instanz (Version, Edition, Patch-Level, Collation, Speicher, CPU, sp_configure)
    - Datenbanken (Name, Status, Recovery, Groesse, letzte Backups, Owner, Collation)
    - Logins (Name, Typ, Status, Serverrollen)
    - Linked Server
    - SQL Agent Jobs (Name, Status, Owner, Schedules, letzte Ausfuehrung)
    - Always On (AGs, Replikate, Listener)

    Die Ausgabe erfolgt als:
    - TXT-Datei mit lesbarem Bericht
    - CSV-Datei mit der Datenbankliste

    Standard-Ausgabepfad wird aus der Modulkonfiguration (OutputPath) gelesen.
    Wenn konfiguriert, werden die Dateien zusaetzlich in den CentralPath kopiert.

.PARAMETER SqlInstance
    SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    Optionaler PSCredential fuer die Verbindung.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer die Berichtsdateien.
    Standard: Wert aus Modulkonfiguration (Get-sqmDefaultOutputPath).

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz fortfahren (sonst Abbruch).

.PARAMETER EnableException
    Ausnahmen durchlassen (fuer erweiterte Fehlerbehandlung).

.PARAMETER Confirm
    Bestaetigung vor der Erstellung anfordern.

.PARAMETER WhatIf
    Nur testen, keine Dateien schreiben.

.EXAMPLE
    Invoke-sqmInstanceInventory

.EXAMPLE
    Invoke-sqmInstanceInventory -SqlInstance "SQL01", "SQL02" -ContinueOnError

.NOTES
    Erfordert dbatools und Invoke-sqmLogging.
    Die Funktion erstellt automatisch das Ausgabeverzeichnis, falls es nicht existiert.
#>
function Invoke-sqmInstanceInventory
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
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
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Starte Inventarisierung ..." -FunctionName $functionName -Level "INFO"
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				
				# Verbindung herstellen
				$srv = Connect-DbaInstance @connParams -ErrorAction Stop
				
				# Datenbanken
				$databases = Get-DbaDatabase @connParams -ErrorAction SilentlyContinue
				
				# Letzte Backups
				$backupQuery = @"
SELECT database_name, type, MAX(backup_finish_date) AS LastBackup,
       SUM(backup_size)/1048576.0 AS AvgSizeMB
FROM msdb.dbo.backupset
WHERE type IN ('D','L') AND is_copy_only = 0
GROUP BY database_name, type;
"@
				$backupRows = Invoke-DbaQuery @connParams -Query $backupQuery -EnableException:$EnableException -ErrorAction SilentlyContinue
				$backupLookup = @{ }
				foreach ($r in $backupRows) { $backupLookup["$($r.database_name)|$($r.type)"] = $r.LastBackup }
				
				# Logins
				$logins = Get-DbaLogin @connParams -ErrorAction SilentlyContinue
				
				# Serverrollen pro Login
				$roleQuery = @"
SELECT m.name AS LoginName, r.name AS RoleName
FROM sys.server_role_members rm
JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
WHERE m.type IN ('S','U','G')
ORDER BY m.name, r.name;
"@
				$roleRows = Invoke-DbaQuery @connParams -Query $roleQuery -EnableException:$EnableException -ErrorAction SilentlyContinue
				$roleLookup = @{ }
				foreach ($r in $roleRows)
				{
					if (-not $roleLookup[$r.LoginName]) { $roleLookup[$r.LoginName] = [System.Collections.Generic.List[string]]::new() }
					$roleLookup[$r.LoginName].Add($r.RoleName)
				}
				
				# Linked Server
				$linkedServers = Get-DbaLinkedServer @connParams -ErrorAction SilentlyContinue
				
				# SQL Agent Jobs
				$jobs = Get-DbaAgentJob @connParams -ErrorAction SilentlyContinue
				
				# sp_configure Abweichungen
				$configQuery = @"
SELECT name, value_in_use, description
FROM sys.configurations
WHERE value_in_use <> minimum
  AND name NOT IN ('user connections','fill factor (%)','locks')
ORDER BY name;
"@
				$configRows = Invoke-DbaQuery @connParams -Query $configQuery -EnableException:$EnableException -ErrorAction SilentlyContinue
				
				# Always On
				$ags = Get-DbaAvailabilityGroup @connParams -ErrorAction SilentlyContinue
				$listeners = if ($ags) { Get-DbaAgListener @connParams -ErrorAction SilentlyContinue }
				
				# ========== TXT-Bericht aufbauen ==========
				$lines = [System.Collections.Generic.List[string]]::new()
				
				$lines.Add("# ================================================================")
				$lines.Add("# MSSQLTools - Instanz-Inventar")
				$lines.Add("# Instanz   : $instance")
				$lines.Add("# Erstellt  : $timestamp")
				$lines.Add("# ================================================================")
				
				# --- Instanz-Info ---
				$lines.Add(""); $lines.Add("# ?? INSTANZ ??????????????????????????????????????????????????")
				$lines.Add(("  Version          : {0}" -f $srv.Version))
				$lines.Add(("  Edition          : {0}" -f $srv.Edition))
				$lines.Add(("  Product Level    : {0}" -f $srv.ProductLevel))
				$lines.Add(("  Product Update   : {0}" -f $srv.ProductUpdateLevel))
				$lines.Add(("  Collation        : {0}" -f $srv.Collation))
				$lines.Add(("  Auth-Modus       : {0}" -f $srv.LoginMode))
				$lines.Add(("  Max Memory (MB)  : {0}" -f $srv.Configuration.MaxServerMemory.ConfigValue))
				$lines.Add(("  Min Memory (MB)  : {0}" -f $srv.Configuration.MinServerMemory.ConfigValue))
				$lines.Add(("  CPUs (logisch)   : {0}" -f $srv.Processors))
				$lines.Add(("  MAXDOP           : {0}" -f $srv.Configuration.MaxDegreeOfParallelism.ConfigValue))
				$lines.Add(("  BackupDirectory  : {0}" -f $srv.BackupDirectory))
				$lines.Add(("  DefaultDataPath  : {0}" -f $srv.DefaultFile))
				$lines.Add(("  DefaultLogPath   : {0}" -f $srv.DefaultLog))
				
				# --- Datenbanken ---
				$lines.Add(""); $lines.Add("# ?? DATENBANKEN ($(@($databases).Count)) ????????????????????????????????????")
				$lines.Add(("{0,-35} {1,-10} {2,-12} {3,-8} {4,-10} {5,-20} {6}" -f
						'Name', 'Status', 'Recovery', 'SizeMB', 'CompatLvl', 'Letztes Full', 'Owner'))
				$lines.Add(("-" * 120))
				
				$dbCsvList = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($db in ($databases | Sort-Object IsSystemObject, Name))
				{
					$lastFull = $backupLookup["$($db.Name)|D"]
					$fullStr = if ($lastFull) { $lastFull.ToString('yyyy-MM-dd HH:mm') }
					else { '(keins)' }
					
					$lines.Add(("{0,-35} {1,-10} {2,-12} {3,-8} {4,-10} {5,-20} {6}" -f
							$db.Name.Substring(0, [Math]::Min(35, $db.Name.Length)),
							$db.Status, $db.RecoveryModel,
							[math]::Round($db.Size, 0),
							$db.CompatibilityLevel, $fullStr, $db.Owner))
					
					$dbCsvList.Add([PSCustomObject]@{
							SqlInstance  = $instance
							DatabaseName = $db.Name
							Status	     = $db.Status
							RecoveryModel = $db.RecoveryModel
							SizeMB	     = [math]::Round($db.Size, 0)
							CompatibilityLevel = $db.CompatibilityLevel
							Owner	     = $db.Owner
							Collation    = $db.Collation
							IsSystemObject = $db.IsSystemObject
							LastFullBackup = $fullStr
							CreateDate   = $db.CreateDate.ToString('yyyy-MM-dd')
						})
				}
				
				# --- Logins ---
				$lines.Add(""); $lines.Add("# ?? LOGINS ($(@($logins).Count)) ??????????????????????????????????????????")
				$lines.Add(("{0,-45} {1,-18} {2,-8} {3}" -f 'Name', 'Typ', 'Enabled', 'Serverrollen'))
				$lines.Add(("-" * 100))
				foreach ($l in ($logins | Sort-Object LoginType, Name))
				{
					$roles = if ($roleLookup[$l.Name]) { $roleLookup[$l.Name] -join ', ' }
					else { '-' }
					$lines.Add(("{0,-45} {1,-18} {2,-8} {3}" -f
							$l.Name.Substring(0, [Math]::Min(45, $l.Name.Length)),
							$l.LoginType, (-not $l.IsDisabled), $roles))
				}
				
				# --- Linked Server ---
				if ($linkedServers)
				{
					$lines.Add(""); $lines.Add("# ?? LINKED SERVER ($(@($linkedServers).Count)) ?????????????????????????????????????")
					$lines.Add(("{0,-30} {1,-20} {2,-20} {3}" -f 'Name', 'Produkt', 'Provider', 'Datenquelle'))
					$lines.Add(("-" * 100))
					foreach ($ls in ($linkedServers | Sort-Object Name))
					{
						$lines.Add(("{0,-30} {1,-20} {2,-20} {3}" -f
								$ls.Name.Substring(0, [Math]::Min(30, $ls.Name.Length)),
								$ls.ProductName, $ls.ProviderName, $ls.DataSource))
					}
				}
				
				# --- SQL Agent Jobs ---
				if ($jobs)
				{
					$lines.Add(""); $lines.Add("# ?? SQL AGENT JOBS ($(@($jobs).Count)) ??????????????????????????????????????")
					$lines.Add(("{0,-45} {1,-8} {2,-25} {3,-20} {4}" -f
							'Name', 'Enabled', 'Owner', 'Letzte Ausfuehrung', 'Status'))
					$lines.Add(("-" * 120))
					foreach ($j in ($jobs | Sort-Object IsEnabled, Name))
					{
						$lastRun = if ($j.LastRunDate -and $j.LastRunDate.Year -gt 1990)
						{ $j.LastRunDate.ToString('yyyy-MM-dd HH:mm') }
						else { '(nie)' }
						$lines.Add(("{0,-45} {1,-8} {2,-25} {3,-20} {4}" -f
								$j.Name.Substring(0, [Math]::Min(45, $j.Name.Length)),
								$j.IsEnabled,
								$j.OwnerLoginName.Substring(0, [Math]::Min(25, $j.OwnerLoginName.Length)),
								$lastRun, $j.LastRunOutcome))
					}
				}
				
				# --- sp_configure Abweichungen ---
				if ($configRows)
				{
					$lines.Add(""); $lines.Add("# ?? KONFIGURATION (Abweichungen vom Standard) ????????????????")
					foreach ($c in $configRows)
					{
						$lines.Add(("  {0,-45} = {1}" -f $c.name, $c.value_in_use))
					}
				}
				
				# --- Always On ---
				if ($ags)
				{
					$lines.Add(""); $lines.Add("# ?? ALWAYS ON ($(@($ags).Count) AG(s)) ??????????????????????????????????????")
					foreach ($ag in $ags)
					{
						$lines.Add(("  AG: $($ag.Name) | Primary: $($ag.PrimaryReplica) | " +
								"AutomatedBackup: $($ag.AutomatedBackupPreference)"))
						$replicas = Get-DbaAgReplica @connParams -AvailabilityGroup $ag.Name -ErrorAction SilentlyContinue
						foreach ($r in $replicas)
						{
							$lines.Add(("    Replikat: {0,-30} Rolle: {1,-10} Mode: {2}" -f $r.Name, $r.Role, $r.AvailabilityMode))
						}
						$agListeners = $listeners | Where-Object AvailabilityGroup -eq $ag.Name
						foreach ($l in $agListeners)
						{
							$lines.Add(("    Listener: $($l.Name) Port: $($l.PortNumber) IPs: $($l.IpAddress -join ', ')"))
						}
					}
				}
				
				# --- Dateien schreiben (nur wenn -WhatIf nicht aktiv) ---
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "InstanceInventory_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "InstanceInventory_${safeInst}_${datestamp}.csv"
				
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Inventar-Dateien in $OutputPath"))
				{
					# Verzeichnis anlegen
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$dbCsvList | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
					
					# In zentrales Verzeichnis kopieren (falls konfiguriert)
					Copy-sqmToCentralPath -Path $txtFile, $csvFile
					
					Invoke-sqmLogging -Message "[$instance] Inventar erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Dateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
				}
				
				# Ergebnisobjekt
				$result = [PSCustomObject]@{
					SqlInstance = $instance
					Version	    = $srv.Version.ToString()
					Edition	    = $srv.Edition
					DatabaseCount = @($databases).Count
					LoginCount  = @($logins).Count
					JobCount    = @($jobs).Count
					AgCount	    = @($ags).Count
					TxtFile	    = $txtFile
					CsvFile	    = $csvFile
					Status	    = 'OK'
					Timestamp   = $timestamp
				}
				$allResults.Add($result)
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status	    = 'Error'
						TxtFile	    = $null
						CsvFile	    = $null
						Message	    = $errMsg
					})
				if (-not $ContinueOnError -and -not $EnableException) { throw }
				if ($EnableException) { throw $_ }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Instanzen verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}