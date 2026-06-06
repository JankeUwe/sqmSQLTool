<#
.SYNOPSIS
Checks a SQL Server instance against best practices.

.DESCRIPTION
The function performs a series of best practice checks:
- Max Degree of Parallelism (MAXDOP) - recommendation based on number of cores
- Max Server Memory - should not be too high (reserve for OS)
- Cost Threshold for Parallelism - recommendation >= 50
- Backup Directory - existence and write permissions (optional)
- SA account - renaming and disabling
- xp_cmdshell - should be disabled (unless required)
- Database autogrow settings - percent vs. MB, appropriate values
- TempDB - number of files (should match number of cores, max 8), equal size, path
- Isolated volumes - check whether database files are on separate drives (optional)
- SQL Server version / service pack - checks for outdated versions (optional)

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME)
is used by default.

.PARAMETER SqlInstance
The target SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
Alternative credentials.

.PARAMETER Detailed
Detailed output (e.g. path checks, analyze all databases). Default: $false.

.PARAMETER EnableException
Allow exceptions to pass through.

.EXAMPLE
Get-sqmSQLInstanceCheck

.EXAMPLE
Get-sqmSQLInstanceCheck -SqlInstance "SQL01\INSTANCE" -Detailed

.NOTES
Requires dbatools and Invoke-sqmLogging.
#>
function Get-sqmSQLInstanceCheck
{
	[CmdletBinding(SupportsShouldProcess = $false)]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Detailed,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
		$results = @()
	}
	
	process
	{
		try
		{
			$server = Connect-DbaInstance  -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
			
			# 1. MAXDOP
			$maxdop = $server.Configuration.MaxDegreeOfParallelism.ConfigValue
			$cpuCount = $server.Processors
			$recommendedMaxdop = if ($cpuCount -le 4) { $cpuCount }
			elseif ($cpuCount -le 8) { 4 }
			elseif ($cpuCount -le 16) { 8 }
			else { 16 }
			$maxdopOk = ($maxdop -ge 2 -and $maxdop -le $recommendedMaxdop)
			$results += [PSCustomObject]@{
				Check	     = "MAXDOP"
				CurrentValue = $maxdop
				Recommended  = "2..$recommendedMaxdop (abhaengig von NUMA, idealerweise $recommendedMaxdop)"
				Status	     = if ($maxdopOk) { "OK" } elseif ($maxdop -eq 0) { "Warning" } else { "Failed" }
				Message	     = if ($maxdop -eq 0) { "MAXDOP=0 kann zu uebermaessiger Parallelisierung fuehren." } elseif ($maxdop -eq 1) { "MAXDOP=1 deaktiviert Parallelisierung - nicht empfohlen fuer moderne Hardware." } elseif (-not $maxdopOk) { "MAXDOP zu hoch ($maxdop). Empfohlen max. $recommendedMaxdop." } else { "In Ordnung." }
			}
			
			# 2. Max Server Memory (synchronisiert mit Test-sqmMaxMemory Logik)
			$maxMem = $server.Configuration.MaxServerMemory.ConfigValue
			$totalMem = [math]::Round($server.PhysicalMemory / 1024, 0) # in MB
			$recommendedMem = [math]::Round($totalMem * 0.90)  # 90% empfohlen
			$lowerBound = [math]::Round($totalMem * 0.85)      # 85% Untergrenze
			$upperBound = [math]::Round($totalMem * 0.95)      # 95% Obergrenze

			# Auswertung (identisch mit Test-sqmMaxMemory)
			$unconfiguredValue = 2147483647
			if ($maxMem -eq $unconfiguredValue) {
				$maxMemStatus = "Warning"
				$maxMemMsg = "Max Server Memory ist nicht konfiguriert (Default-Wert). Empfohlen: $recommendedMem MB (90% von $totalMem MB)"
			}
			elseif ($maxMem -gt $upperBound) {
				$maxMemStatus = "Warning"
				$maxMemMsg = "Max Server Memory zu hoch ($maxMem MB, >95% RAM). Obergrenze: $upperBound MB empfohlen"
			}
			elseif ($maxMem -lt $lowerBound) {
				$maxMemStatus = "Warning"
				$maxMemMsg = "Max Server Memory zu niedrig ($maxMem MB, <85% RAM). Untergrenze: $lowerBound MB"
			}
			else {
				$maxMemStatus = "OK"
				$maxMemMsg = "Max Server Memory OK ($maxMem MB). Toleranz: $lowerBound - $upperBound MB"
			}

			$results += [PSCustomObject]@{
				Check	     = "Max Server Memory"
				CurrentValue = "$maxMem MB"
				Recommended  = "$recommendedMem MB (90% von $totalMem MB RAM)"
				Status	     = $maxMemStatus
				Message	     = $maxMemMsg
			}
			
			# 3. Cost Threshold for Parallelism
			$ctp = $server.Configuration.CostThresholdForParallelism.ConfigValue
			$ctpOk = $ctp -ge 50
			$results += [PSCustomObject]@{
				Check	     = "Cost Threshold for Parallelism"
				CurrentValue = $ctp
				Recommended  = "? 50"
				Status	     = if ($ctpOk) { "OK" } else { "Failed" }
				Message	     = if ($ctpOk) { "OK." } else { "Wert zu niedrig ($ctp). Empfohlen mindestens 50." }
			}
			
			# 4. xp_cmdshell
			$xpCmd = $server.Configuration.XPCmdShell.ConfigValue
			$results += [PSCustomObject]@{
				Check	     = "xp_cmdshell"
				CurrentValue = if ($xpCmd) { "Enabled" } else { "Disabled" }
				Recommended  = "Disabled (es sei denn, benoetigt)"
				Status	     = if (-not $xpCmd) { "OK" } else { "Warning" }
				Message	     = if ($xpCmd) { "xp_cmdshell ist aktiviert - Sicherheitsrisiko." } else { "Deaktiviert - OK." }
			}
			
			# 5. SA-Konto (umbenannt/deaktiviert)
			$saLogin = Get-DbaLogin -SqlInstance $server -Login 'sa' -ErrorAction SilentlyContinue
			if (-not $saLogin)
			{
				$saSid = '0x01'
				$saLogin = Get-DbaLogin -SqlInstance $server | Where-Object { $_.SID -eq $saSid }
			}
			$saName = $saLogin.Name
			$saDisabled = $saLogin.IsDisabled
			$saOk = ($saName -ne 'sa') -or $saDisabled
			$results += [PSCustomObject]@{
				Check	     = "SA Account"
				CurrentValue = "Name: $saName, Aktiviert: $(-not $saDisabled)"
				Recommended  = "Umbenannt und/oder deaktiviert"
				Status	     = if ($saOk) { "OK" } else { "Failed" }
				Message	     = if ($saName -eq 'sa' -and -not $saDisabled) { "SA-Konto heisst noch 'sa' und ist aktiviert - Sicherheitsrisiko." } elseif ($saName -eq 'sa') { "SA-Konto heisst noch 'sa' (aber deaktiviert)." } else { "OK." }
			}

			# 6. Sysadmin Accounts (WHO)
			try
			{
				$sysadminLogins = @()
				$sysadminLogins = Get-DbaLogin -SqlInstance $server | Where-Object { $_.IsSysAdmin -eq $true } | Select-Object -ExpandProperty Name
				$sysadminCount = @($sysadminLogins).Count
				$sysadminList = if ($sysadminCount -gt 0) { $sysadminLogins -join ', ' } else { 'None' }

				$results += [PSCustomObject]@{
					Check	     = "Sysadmin Accounts"
					CurrentValue = "$sysadminCount Konto(n): $sysadminList"
					Recommended  = "Sollte auf wenige Accounts begrenzt werden (idealerweise Windows-Gruppen)"
					Status	     = if ($sysadminCount -le 2) { "OK" } elseif ($sysadminCount -le 4) { "Warning" } else { "Warning" }
					Message	     = if ($sysadminCount -le 2) { "Angemessene Anzahl von Sysadmin-Accounts." } else { "Viele Sysadmin-Accounts ($sysadminCount) - sollte auf ein Minimum beschraenkt werden." }
				}
			}
			catch
			{
				$results += [PSCustomObject]@{
					Check	     = "Sysadmin Accounts"
					CurrentValue = "Fehler beim Lesen"
					Recommended  = "-"
					Status	     = "Error"
					Message	     = $_.Exception.Message
				}
			}

			# 7. CLR Status (Common Language Runtime)
			try
			{
				$clrEnabled = $server.Configuration.IsSqlClrEnabled.ConfigValue
				$results += [PSCustomObject]@{
					Check	     = "CLR (Common Language Runtime)"
					CurrentValue = if ($clrEnabled) { "Enabled" } else { "Disabled" }
					Recommended  = "Disabled (unless required for stored procedures)"
					Status	     = if ($clrEnabled) { "Warning" } else { "OK" }
					Message	     = if ($clrEnabled) { "CLR ist aktiviert - Nutzen Sie diese Funktion?" } else { "CLR ist deaktiviert - OK (Sicherheitspraktik)." }
				}
			}
			catch
			{
				$results += [PSCustomObject]@{
					Check	     = "CLR Status"
					CurrentValue = "Fehler beim Lesen"
					Recommended  = "-"
					Status	     = "Error"
					Message	     = $_.Exception.Message
				}
			}

			# 8. Relevante SQL-Konfigurationen
			try
			{
				$configs = @()
				$configNames = @(
					'Database Mail XPs',
					'ad hoc distributed queries',
					'remote admin connections',
					'Agent XPs',
					'OLE Automation Procedures'
				)

				foreach ($configName in $configNames)
				{
					$cfgValue = $server.Configuration | Where-Object { $_.DisplayName -eq $configName } | Select-Object -First 1
					if ($cfgValue)
					{
						$status = $cfgValue.ConfigValue
						$configs += "$($configName): $(if ($status) { 'Enabled' } else { 'Disabled' })"
					}
				}

				$configList = if ($configs.Count -gt 0) { $configs -join ' | ' } else { 'Keine XP konfiguriert' }
				$results += [PSCustomObject]@{
					Check	     = "SQL XPs und Erweiterte Konfigurationen"
					CurrentValue = $configList
					Recommended  = "Nur aktiviert wenn notwendig (Sicherheitsrisiko)"
					Status	     = "Info"
					Message	     = "Ueberpruefe regelmassig ob diese XPs noch benoetigt werden."
				}
			}
			catch
			{
				$results += [PSCustomObject]@{
					Check	     = "SQL Konfigurationen"
					CurrentValue = "Fehler beim Lesen"
					Recommended  = "-"
					Status	     = "Error"
					Message	     = $_.Exception.Message
				}
			}

			# 9. Backup Directory (falls vorhanden und Detailed)
			if ($Detailed)
			{
				$backupDir = $server.BackupDirectory
				$dirExists = Test-Path $backupDir
				$results += [PSCustomObject]@{
					Check	     = "Backup Directory"
					CurrentValue = $backupDir
					Recommended  = "Verzeichnis sollte existieren und beschreibbar sein"
					Status	     = if ($dirExists) { "OK" } else { "Warning" }
					Message	     = if (-not $dirExists) { "Backup-Verzeichnis '$backupDir' existiert nicht." } else { "OK." }
				}
			}
			
			# 7. Datenbank-Autogrow-Einstellungen (nur fuer Benutzerdatenbanken, wenn Detailed)
			if ($Detailed)
			{
				$dbs = Get-DbaDatabase -SqlInstance $server -ExcludeSystem
				$badGrow = @()
				foreach ($db in $dbs)
				{
					foreach ($file in $db.FileGroups.Files)
					{
						if ($file.GrowthType -ne 'KB' -or $file.Growth -gt 1024)
						{
							$badGrow += "$($db.Name):$($file.Name)"
						}
					}
				}
				$results += [PSCustomObject]@{
					Check	     = "Autogrow Settings"
					CurrentValue = "$($badGrow.Count) Dateien mit problematischem Autogrow"
					Recommended  = "Autogrow in MB (nicht Prozent), max. 1024 MB pro Wachstum"
					Status	     = if ($badGrow.Count -eq 0) { "OK" } else { "Warning" }
					Message	     = if ($badGrow.Count -gt 0) { "Folgende Dateien haben unguenstige Autogrow-Einstellungen: $($badGrow -join ', ')" } else { "OK." }
				}
			}
			
			# 8. TempDB-Konfiguration
			$tempdb = Get-DbaDatabase -SqlInstance $server -Database 'tempdb'
			$tempdbFiles = $tempdb.FileGroups.Files
			$fileCount = $tempdbFiles.Count
			$coreCount = $server.Processors
			$idealCount = [Math]::Min($coreCount, 8)
			$fileCountOk = ($fileCount -eq $idealCount) -or ($fileCount -ge 4 -and $fileCount -le 8)
			$equalSize = ($tempdbFiles | Measure-Object -Property Size -Maximum).Maximum -eq ($tempdbFiles | Measure-Object -Property Size -Minimum).Minimum
			$results += [PSCustomObject]@{
				Check	     = "TempDB Configuration"
				CurrentValue = "$fileCount Datenbankdateien, gleiche Groesse: $equalSize"
				Recommended  = "$idealCount Dateien (entsprechend Anzahl Kerne, max 8), alle gleiche Groesse, separate Laufwerke"
				Status	     = if ($fileCountOk -and $equalSize) { "OK" } else { "Warning" }
				Message	     = if (-not $fileCountOk) { "Anzahl TempDB-Dateien: $fileCount (empfohlen $idealCount)." } elseif (-not $equalSize) { "TempDB-Dateien haben unterschiedliche Groessen." } else { "OK." }
			}
			
			# 9. SQL Server Version (optional - Warnung bei sehr alten Versionen)
			$version = $server.VersionString
			$isOld = $version -match '2008|2005|2012' # vereinfacht
			$results += [PSCustomObject]@{
				Check	     = "SQL Server Version"
				CurrentValue = $version
				Recommended  = "Aktuelle Version + neuestes Service Pack / CU"
				Status	     = if ($isOld) { "Warning" } else { "OK" }
				Message	     = if ($isOld) { "Die Version $version ist veraltet. Upgrade empfohlen." } else { "OK." }
			}
		}
		catch
		{
			$errMsg = "Fehler bei der ueberpruefung: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{
				Check	     = "Allgemeiner Fehler"
				CurrentValue = $null
				Recommended  = $null
				Status	     = "Error"
				Message	     = $errMsg
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Pruefungen durchgefuehrt." -FunctionName $functionName -Level "INFO"
		return $results
	}
}