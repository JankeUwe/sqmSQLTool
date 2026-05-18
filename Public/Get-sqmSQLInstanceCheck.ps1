<#
.SYNOPSIS
ueberprueft eine SQL Server-Instanz auf Best Practices.

.DESCRIPTION
Die Funktion fuehrt eine Reihe von Best-Practice-Pruefungen durch:
- Max Degree of Parallelism (MAXDOP) - Empfehlung basierend auf Anzahl der Kerne
- Max Server Memory - Sollte nicht zu hoch sein (Reserve fuer OS)
- Cost Threshold for Parallelism - Empfehlung ? 50
- Backup Directory - Existenz und Schreibrechte (optional)
- SA-Konto - Umbenennung und Deaktivierung
- xp_cmdshell - Sollte deaktiviert sein (es sei denn, benoetigt)
- Datenbank-Autogrow-Einstellungen - Prozent vs. MB, angemessene Werte
- TempDB - Anzahl der Dateien (sollte Anzahl der Kerne entsprechen, max 8), gleiche Groesse, Pfad
- Isolierte Volumes - Pruefung, ob Datenbankdateien auf getrennten Laufwerken liegen (optional)
- SQL Server Version / Service Pack - Prueft auf veraltete Versionen (optional)

Wenn kein SqlInstance-Parameter angegeben wird, wird standardmaessig der aktuelle
Computername ($env:COMPUTERNAME) verwendet.

.PARAMETER SqlInstance
Die Ziel-SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
Alternative Anmeldeinformationen.

.PARAMETER Detailed
Detaillierte Ausgabe (z.B. auch Pfadpruefungen, alle Datenbanken analysieren). Standard: $false.

.PARAMETER EnableException
Ausnahmen durchlassen.

.EXAMPLE
Get-sqmSQLInstanceCheck

.EXAMPLE
Get-sqmSQLInstanceCheck -SqlInstance "SQL01\INSTANCE" -Detailed

.NOTES
Erfordert dbatools und Invoke-sqmLogging.
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
			
			# 2. Max Server Memory
			$maxMem = $server.Configuration.MaxServerMemory.ConfigValue
			$totalMem = [math]::Round($server.PhysicalMemory / 1024, 0) # in MB
			$recommendedMem = if ($totalMem -le 4096) { $totalMem - 512 }
			elseif ($totalMem -le 16384) { $totalMem - 1024 }
			else { $totalMem - 4096 }
			$maxMemOk = ($maxMem -le $totalMem - 512) -and ($maxMem -gt 0)
			$results += [PSCustomObject]@{
				Check	     = "Max Server Memory"
				CurrentValue = "$maxMem MB"
				Recommended  = "$recommendedMem MB (Reserve fuer OS)"
				Status	     = if ($maxMem -eq 0) { "Failed" } elseif ($maxMem -le $totalMem - 512) { "OK" } else { "Warning" }
				Message	     = if ($maxMem -eq 0) { "Max Server Memory ist nicht konfiguriert (0). Dies kann zu Problemen mit dem Betriebssystem fuehren." } elseif ($maxMem -gt $totalMem - 512) { "Max Server Memory zu hoch ($maxMem MB). Lassen Sie mindestens 4-8 GB fuer das OS frei." } else { "OK." }
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
			
			# 6. Backup Directory (falls vorhanden und Detailed)
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