<#
.SYNOPSIS
Verschiebt Datenbankdateien (MDF/NDF/LDF) auf ein anderes Laufwerk oder in ein anderes Verzeichnis.

.DESCRIPTION
Verschiebt die Dateien einer Datenbank an einen neuen Ort und fuehrt dabei genau die Schritte aus,
die SQL Server dafuer verlangt. Angegeben wird entweder nur der Datenbankname (dann werden alle
Dateien bzw. alle Dateien eines Typs verschoben) oder ueber -LogicalFileName eine einzelne Datei.

Es gibt drei Ablaeufe, die sich nach der Datenbank richten:

  Benutzerdatenbank  OFFLINE -> Dateien kopieren -> ALTER DATABASE MODIFY FILE -> ONLINE
                     -> alte Dateien entfernen
  tempdb             ALTER DATABASE MODIFY FILE -> Instanz-Neustart -> alte Dateien entfernen.
                     Es wird NICHTS kopiert: tempdb wird beim Start neu angelegt. Genau deshalb
                     bleiben die alten Dateien sonst als Leichen auf dem alten Laufwerk liegen.
  model / msdb       ALTER DATABASE MODIFY FILE -> Dienst stoppen -> Dateien kopieren ->
                     Dienst starten -> alte Dateien entfernen

master wird bewusst abgelehnt. Dafuer muessen die Startparameter -d/-l/-e geaendert werden
(Set-DbaStartupParameter), das ist ein anderer Vorgang mit anderen Risiken.

Vor der ersten Aenderung wird geprueft:

  1. Datenbankzustand    ONLINE bzw. OFFLINE, kein Snapshot, kein master.
  2. AlwaysOn            Ist die Datenbank Mitglied einer AG, wird abgebrochen. Eine AG-Datenbank
                         laesst sich nicht offline setzen; das Verschieben muss repliktweise
                         erfolgen. Mit -Force wird die Pruefung uebergangen.
  3. Zielverzeichnis     Existiert es aus Sicht der INSTANZ (Test-DbaPath, also xp_fileexist)?
                         Fehlt es, wird es angelegt, die ACL des Quellverzeichnisses uebernommen
                         und dem Dienstkonto der Engine explizit Vollzugriff eingeraeumt.
  4. Schreibprobe        Auf jedem Zielverzeichnis wird testweise eine 8-MB-Datenbank angelegt und
                         sofort wieder verworfen. Erst das beweist, dass das Dienstkonto dort
                         wirklich Dateien anlegen darf. Bei tempdb ist das der entscheidende Test:
                         ein nicht beschreibbarer tempdb-Pfad bedeutet, dass die Instanz nach dem
                         Neustart gar nicht mehr hochkommt. Abschaltbar mit -SkipWriteProbe.
  5. Platz               Freier Platz am Ziel gegen die Summe der Dateigroessen plus Puffer
                         (-SpaceBufferPercent, Standard 20). Quelle ist Get-DbaDiskSpace (kennt
                         Mountpoints), Rueckfallebene xp_fixeddrives.

Alte Dateien werden nur entfernt, nachdem die Datenbank am neuen Ort nachweislich laeuft und die
neue Datei per Test-DbaPath bestaetigt ist. -KeepOldFiles unterdrueckt das Aufraeumen.

.PARAMETER SqlInstance
Ziel-Instanz (z. B. "SQL01" oder "SQL01\INST"). Ohne Angabe wird $env:COMPUTERNAME verwendet.

.PARAMETER SqlCredential
Alternative SQL-Anmeldeinformationen. Ohne Angabe wird Windows-Authentifizierung verwendet.

.PARAMETER Database
Name der Datenbank, deren Dateien verschoben werden (z. B. "SalesDB" oder "tempdb").

.PARAMETER FileDestination
Zielverzeichnis fuer die zu verschiebenden Dateien (z. B. "G:\MSSQL\Data"). Der Pfad wird aus
Sicht des SQL Servers interpretiert, nicht aus Sicht der aufrufenden Maschine.

.PARAMETER LogFileDestination
Optionales abweichendes Zielverzeichnis fuer Logdateien. Ohne Angabe landen auch die Logdateien
in -FileDestination.

.PARAMETER FileType
Welche Dateien verschoben werden: All (Standard), Data (MDF/NDF) oder Log (LDF).
Wird ignoriert, wenn -LogicalFileName angegeben ist.

.PARAMETER LogicalFileName
Logische Namen einzelner Dateien (z. B. "tempdev" oder "SalesDB_log"). Damit laesst sich gezielt
eine einzelne MDF/NDF/LDF verschieben statt der ganzen Datenbank.

.PARAMETER Credential
Windows-Anmeldeinformationen fuer die Dateioperationen und die Dienststeuerung auf dem Zielhost.
Nur noetig, wenn die Instanz auf einem anderen Rechner laeuft und der aktuelle Benutzerkontext
dort nicht ausreicht.

.PARAMETER KeepOldFiles
Laesst die Dateien am alten Ort liegen, statt sie nach erfolgreichem Verschieben zu entfernen.

.PARAMETER NoRestart
Nur fuer tempdb: setzt ALTER DATABASE MODIFY FILE ab, startet die Instanz aber NICHT neu. Die
Aenderung wird erst beim naechsten Neustart wirksam, die alten Dateien bleiben liegen
(Status PendingRestart). Fuer model/msdb ist -NoRestart nicht zulaessig, weil die Instanz sonst
beim naechsten Start die bereits umgetragenen Dateien am neuen Ort nicht faende.

.PARAMETER SkipWriteProbe
Ueberspringt die Schreibprobe im Zielverzeichnis (Punkt 4 oben). Nur sinnvoll, wenn das Anlegen
einer temporaeren Datenbank aus Audit-Gruenden unerwuenscht ist.

.PARAMETER SkipSpaceCheck
Ueberspringt die Pruefung des freien Speicherplatzes am Ziel.

.PARAMETER SpaceBufferPercent
Sicherheitsaufschlag in Prozent auf die benoetigte Groesse bei der Platzpruefung. Standard: 20.

.PARAMETER RestartTimeoutSeconds
Wie lange nach einer Dienstaktion auf die Erreichbarkeit der Instanz gewartet wird.
Standard: 300 Sekunden.

.PARAMETER Force
Beendet offene Verbindungen beim Offline-Setzen einer Benutzerdatenbank und uebergeht die
AlwaysOn-Sperre.

.PARAMETER EnableException
Wirft Ausnahmen weiter, statt sie als Ergebniszeile mit Status "Failed" zu melden.

.EXAMPLE
Move-sqmDatabaseFile -SqlInstance SQL01 -Database tempdb -FileDestination 'G:\MSSQL\TempDB'

Verschiebt alle tempdb-Dateien nach G:\MSSQL\TempDB, startet die Instanz neu und entfernt
anschliessend die alten tempdb-Dateien.

.EXAMPLE
Move-sqmDatabaseFile -SqlInstance SQL01 -Database tempdb -FileDestination 'G:\MSSQL\TempDB' -WhatIf

Fuehrt alle Vorpruefungen aus und zeigt den geplanten Ablauf, ohne etwas zu veraendern.

.EXAMPLE
Move-sqmDatabaseFile -SqlInstance SQL01 -Database SalesDB -LogicalFileName 'SalesDB_log' -FileDestination 'H:\MSSQL\Log'

Verschiebt nur die Logdatei der Datenbank SalesDB.

.EXAMPLE
Move-sqmDatabaseFile -SqlInstance SQL01 -Database SalesDB -FileDestination 'G:\MSSQL\Data' -LogFileDestination 'H:\MSSQL\Log' -Force

Verschiebt Daten- und Logdateien auf getrennte Laufwerke und beendet dabei offene Verbindungen.

.OUTPUTS
PSCustomObject je Schritt mit SqlInstance, Database, Step (Precheck/Move/Restart/Cleanup),
LogicalName, OldPath, NewPath, SizeMB, Status und Message.

.NOTES
Benoetigt dbatools und sysadmin auf der Instanz. Fuer Neustart und Dateioperationen auf einer
entfernten Instanz wird zusaetzlich Windows-Zugriff auf den Host benoetigt (administrative
Freigabe und Dienststeuerung), notfalls ueber -Credential.

Bewusst NICHT ueber Move-DbaDbFile umgesetzt: dieses Cmdlet lehnt master, model, msdb und tempdb
grundsaetzlich ab und kennt weder Schreibprobe noch Platzpruefung noch WhatIf.
#>
function Move-sqmDatabaseFile
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true, Position = 1)]
		[ValidateNotNullOrEmpty()]
		[string]$Database,
		[Parameter(Mandatory = $true, Position = 2)]
		[ValidateNotNullOrEmpty()]
		[string]$FileDestination,
		[Parameter(Mandatory = $false)]
		[string]$LogFileDestination,
		[Parameter(Mandatory = $false)]
		[ValidateSet('All', 'Data', 'Log')]
		[string]$FileType = 'All',
		[Parameter(Mandatory = $false)]
		[string[]]$LogicalFileName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[switch]$KeepOldFiles,
		[Parameter(Mandatory = $false)]
		[switch]$NoRestart,
		[Parameter(Mandatory = $false)]
		[switch]$SkipWriteProbe,
		[Parameter(Mandatory = $false)]
		[switch]$SkipSpaceCheck,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 100)]
		[int]$SpaceBufferPercent = 20,
		[Parameter(Mandatory = $false)]
		[ValidateRange(30, 3600)]
		[int]$RestartTimeoutSeconds = 300,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
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

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		# Windows-seitige Parameter (Dienststeuerung). Bewusst getrennt von $connParams: Dienste
		# steuert man ueber WMI/CIM mit einem Windows-Konto, nicht ueber die SQL-Verbindung.
		$svcParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($Credential) { $svcParams['Credential'] = $Credential }

		$FileDestination = $FileDestination.TrimEnd('\')
		if ($LogFileDestination) { $LogFileDestination = $LogFileDestination.TrimEnd('\') }

		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		function _AddResult([string]$Step, [string]$LogicalName, [string]$OldPath, [string]$NewPath, $SizeMB, [string]$Status, [string]$Message)
		{
			$results.Add([PSCustomObject]@{
					SqlInstance = $SqlInstance
					Database    = $Database
					Step	    = $Step
					LogicalName = $LogicalName
					OldPath	    = $OldPath
					NewPath	    = $NewPath
					SizeMB	    = $SizeMB
					Status	    = $Status
					Message	    = $Message
				})
		}

		# Pfade auf dem SQL-Host zusammensetzen, OHNE Join-Path. Join-Path loest den
		# Laufwerksbuchstaben gegen die PSDrives DIESER Maschine auf: fuer ein 'G:\...' auf einem
		# entfernten Server, das es hier nicht gibt, liefert es einen Fehler und einen LEEREN
		# String - und damit ein ALTER DATABASE ... FILENAME = N''.
		function _CombineServerPath([string]$Dir, [string]$Leaf)
		{
			return ($Dir.TrimEnd('\') + '\' + $Leaf.TrimStart('\'))
		}

		# Serverpfad -> von DIESER Maschine erreichbarer Pfad. Lokal unveraendert, sonst ueber die
		# administrative Freigabe (C:\Data\x.mdf -> \\HOST\C$\Data\x.mdf).
		function _ToWindowsPath([string]$Path)
		{
			if ($isLocalHost) { return $Path }
			if ($Path -like '\\*') { return $Path }
			if ($Path -match '^[A-Za-z]:\\')
			{
				return ('\\{0}\{1}$\{2}' -f $sqlHostName, $Path.Substring(0, 1), $Path.Substring(3))
			}
			return $Path
		}

		# Freier Platz am Zielpfad. Get-DbaDiskSpace kennt Mountpoints, xp_fixeddrives nur
		# Laufwerksbuchstaben - deshalb erst das eine, dann als Rueckfallebene das andere.
		function _GetFreeSpaceMb([string]$Path)
		{
			try
			{
				$dsParams = @{ ComputerName = $sqlHostName; ErrorAction = 'Stop' }
				if ($Credential) { $dsParams['Credential'] = $Credential }
				$volumes = Get-DbaDiskSpace @dsParams

				$match = $volumes |
				Where-Object { $_.Name -and $Path.ToUpperInvariant().StartsWith($_.Name.ToUpperInvariant()) } |
				Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1

				if ($match)
				{
					return [PSCustomObject]@{
						FreeMB = [double]$match.Free.Megabyte
						Volume = "$($match.Name)"
						Source = 'Get-DbaDiskSpace'
					}
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "Get-DbaDiskSpace fuer '$sqlHostName' nicht moeglich ($($_.Exception.Message)). Weiche auf xp_fixeddrives aus." -FunctionName $functionName -Level "DEBUG"
			}

			if ($Path -match '^([A-Za-z]):')
			{
				$letter = $Matches[1].ToUpperInvariant()
				try
				{
					$drives = Invoke-DbaQuery @connParams -Database master -Query 'EXEC master.dbo.xp_fixeddrives' -As PSObject -EnableException
					$row = $drives | Where-Object { "$($_.drive)".ToUpperInvariant() -eq $letter } | Select-Object -First 1
					if ($row)
					{
						return [PSCustomObject]@{
							FreeMB = [double]$row.'MB free'
							Volume = ($letter + ':\')
							Source = 'xp_fixeddrives'
						}
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "xp_fixeddrives fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "DEBUG"
				}
			}

			return $null
		}

		# Beweist, dass das Dienstkonto im Zielverzeichnis Dateien anlegen darf - indem SQL Server
		# selbst es versucht. Alles andere (ACL lesen, Test-DbaPath) beantwortet nur, ob der Pfad
		# sichtbar ist, nicht ob er beschreibbar ist.
		function _TestSqlWriteAccess([string]$DirPath)
		{
			$probeName = 'sqmMoveProbe_' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
			$probeData = _CombineServerPath $DirPath ('{0}.mdf' -f $probeName)
			$probeLog = _CombineServerPath $DirPath ('{0}_log.ldf' -f $probeName)
			$createSql = "CREATE DATABASE [$probeName] ON PRIMARY (NAME = N'$probeName', FILENAME = N'$probeData', SIZE = 8MB) " +
			"LOG ON (NAME = N'$($probeName)_log', FILENAME = N'$probeLog', SIZE = 8MB);"

			$probeOk = $false
			$probeMsg = ''
			try
			{
				$null = Invoke-DbaQuery @connParams -Database master -Query $createSql -EnableException
				$probeOk = $true
				$probeMsg = 'Schreibprobe erfolgreich.'
			}
			catch
			{
				$probeMsg = $_.Exception.Message
			}

			try { $null = Invoke-DbaQuery @connParams -Database master -Query "IF DB_ID(N'$probeName') IS NOT NULL DROP DATABASE [$probeName];" -EnableException }
			catch { Invoke-sqmLogging -Message "Probe-Datenbank '$probeName' konnte nicht entfernt werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING" }

			return [PSCustomObject]@{ Success = $probeOk; Message = $probeMsg }
		}

		# Zustand des SQL-Agent vor einer Dienstaktion merken, um ihn danach wiederherzustellen.
		# Start-DbaService -Type Engine startet den Agent NICHT mit - ein gestoppter Agent nach
		# einem Dateiumzug faellt sonst erst auf, wenn nachts die Sicherung ausbleibt.
		function _GetAgentState
		{
			try
			{
				$agent = Get-DbaService @svcParams -Type Agent | Select-Object -First 1
				if ($agent) { return "$($agent.State)" }
			}
			catch
			{
				Invoke-sqmLogging -Message "Agent-Status nicht ermittelbar: $($_.Exception.Message)" -FunctionName $functionName -Level "DEBUG"
			}
			return $null
		}

		function _WaitForInstance([int]$TimeoutSeconds)
		{
			$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
			while ((Get-Date) -lt $deadline)
			{
				try
				{
					$null = Invoke-DbaQuery @connParams -Database master -Query 'SELECT 1 AS Up' -EnableException
					return $true
				}
				catch
				{
					Start-Sleep -Seconds 5
				}
			}
			return $false
		}

		Invoke-sqmLogging -Message "Starte $functionName fuer '$Database' auf '$SqlInstance'. Ziel: '$FileDestination'." -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# ---------------------------------------------------------------------------------
			# 1. Verbindung und Grundzustand
			# ---------------------------------------------------------------------------------
			$server = Connect-DbaInstance @connParams
			$sqlHostName = "$($server.ComputerName)"
			if ([string]::IsNullOrWhiteSpace($sqlHostName)) { $sqlHostName = ($SqlInstance -split '\\')[0] }
			$isLocalHost = $sqlHostName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')

			$dbKind = 'User'
			if ($Database -in @('tempdb', 'model', 'msdb')) { $dbKind = 'System' }

			if ($Database -eq 'master')
			{
				$msg = "master wird von dieser Funktion nicht verschoben. Die Dateipfade von master stehen in den Startparametern (-d/-l/-e), nicht in ALTER DATABASE. Vorgehen: Set-DbaStartupParameter -SqlInstance $SqlInstance -MasterData/-MasterLog/-ErrorLog, Instanz stoppen, Dateien kopieren, starten."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				_AddResult 'Precheck' $null $null $FileDestination $null 'Blocked' $msg
				if ($EnableException) { throw $msg }
				return
			}

			if ($dbKind -eq 'System' -and $NoRestart -and $Database -ne 'tempdb')
			{
				$msg = "-NoRestart ist fuer '$Database' nicht zulaessig. ALTER DATABASE MODIFY FILE wuerde den neuen Pfad eintragen, die Datei laege aber noch am alten Ort - die Instanz kaeme beim naechsten Start nicht mehr hoch. Nur bei tempdb darf aufgeschoben werden, weil die Dateien dort ohnehin neu angelegt werden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				_AddResult 'Precheck' $null $null $FileDestination $null 'Blocked' $msg
				if ($EnableException) { throw $msg }
				return
			}

			$dbEscaped = $Database -replace "'", "''"
			$dbInfo = Invoke-DbaQuery @connParams -Database master -As PSObject -EnableException -Query @"
SELECT d.name AS DbName, d.state_desc AS StateDesc, d.is_read_only AS IsReadOnly,
       d.source_database_id AS SourceDatabaseId, d.recovery_model_desc AS RecoveryModel
FROM sys.databases d
WHERE d.name = N'$dbEscaped';
"@

			if (-not $dbInfo)
			{
				$msg = "Datenbank '$Database' existiert auf '$SqlInstance' nicht."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				_AddResult 'Precheck' $null $null $null $null 'NotFound' $msg
				if ($EnableException) { throw $msg }
				return
			}

			if ($null -ne $dbInfo.SourceDatabaseId -and $dbInfo.SourceDatabaseId -isnot [DBNull])
			{
				$msg = "'$Database' ist ein Datenbank-Snapshot. Snapshot-Dateien lassen sich nicht verschieben."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				_AddResult 'Precheck' $null $null $null $null 'Blocked' $msg
				if ($EnableException) { throw $msg }
				return
			}

			if ("$($dbInfo.StateDesc)" -notin @('ONLINE', 'OFFLINE'))
			{
				$msg = "'$Database' ist im Zustand '$($dbInfo.StateDesc)'. Verschoben werden kann nur aus ONLINE oder OFFLINE heraus."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				_AddResult 'Precheck' $null $null $null $null 'Blocked' $msg
				if ($EnableException) { throw $msg }
				return
			}

			if ("$($server.IsClustered)" -eq 'True')
			{
				$msg = "Failover-Cluster-Instanz erkannt: das Ziellaufwerk muss als Abhaengigkeit der SQL-Rolle eingetragen sein (Ausnahme: tempdb darf seit SQL 2012 auf lokalem Speicher liegen)."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				_AddResult 'Precheck' $null $null $FileDestination $null 'Warning' $msg
			}

			# ---------------------------------------------------------------------------------
			# 2. AlwaysOn - eine AG-Datenbank laesst sich nicht offline setzen
			# ---------------------------------------------------------------------------------
			if ($dbKind -eq 'User')
			{
				try
				{
					$agParams = @{ SqlInstance = $SqlInstance; Database = $Database }
					if ($SqlCredential) { $agParams['SqlCredential'] = $SqlCredential }
					$agInfo = Get-sqmDatabaseAgMembership @agParams

					if ($agInfo.IsAgDatabase)
					{
						$agMsg = "'$Database' ist Mitglied der Availability Group '$($agInfo.AvailabilityGroupName)'. Ein Offline-Setzen lehnt SQL Server ab; die Dateien muessen auf jedem Replikat einzeln verschoben werden (Datenbank aus der AG nehmen, verschieben, wieder aufnehmen)."
						if (-not $Force)
						{
							Invoke-sqmLogging -Message $agMsg -FunctionName $functionName -Level "ERROR"
							_AddResult 'Precheck' $null $null $FileDestination $null 'Blocked' ($agMsg + " Mit -Force wird diese Sperre uebergangen.")
							if ($EnableException) { throw $agMsg }
							return
						}
						Invoke-sqmLogging -Message ($agMsg + " -Force gesetzt: es wird trotzdem fortgefahren.") -FunctionName $functionName -Level "WARNING"
						_AddResult 'Precheck' $null $null $FileDestination $null 'Warning' ($agMsg + " -Force gesetzt.")
					}
				}
				catch
				{
					$msg = "AlwaysOn-Mitgliedschaft von '$Database' konnte nicht geklaert werden: $($_.Exception.Message). Solange das offen ist, wird nicht offline gesetzt."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					_AddResult 'Precheck' $null $null $null $null 'Blocked' $msg
					if ($EnableException) { throw }
					return
				}
			}

			# ---------------------------------------------------------------------------------
			# 3. Dateien auswaehlen. sys.master_files statt sys.database_files, weil es auch fuer
			#    eine OFFLINE-Datenbank lesbar ist und bei tempdb die konfigurierte Startgroesse
			#    zeigt - genau die Groesse, die nach dem Neustart am Ziel gebraucht wird.
			# ---------------------------------------------------------------------------------
			$allFiles = Invoke-DbaQuery @connParams -Database master -As PSObject -EnableException -Query @"
SELECT mf.file_id AS FileId, mf.name AS LogicalName, mf.physical_name AS PhysicalName,
       mf.type_desc AS TypeDesc, CAST(mf.size * 8.0 / 1024 AS decimal(18,2)) AS SizeMB
FROM sys.master_files mf
WHERE mf.database_id = DB_ID(N'$dbEscaped')
ORDER BY mf.type, mf.file_id;
"@

			if (-not $allFiles)
			{
				$msg = "Keine Dateien fuer '$Database' in sys.master_files gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				_AddResult 'Precheck' $null $null $null $null 'Failed' $msg
				if ($EnableException) { throw $msg }
				return
			}

			$selected = @($allFiles)
			if ($LogicalFileName)
			{
				$selected = @($allFiles | Where-Object { $_.LogicalName -in $LogicalFileName })
				$missing = @($LogicalFileName | Where-Object { $_ -notin @($allFiles.LogicalName) })
				foreach ($miss in $missing)
				{
					$msg = "Logische Datei '$miss' existiert in '$Database' nicht."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					_AddResult 'Precheck' $miss $null $null $null 'NotFound' $msg
				}
			}
			elseif ($FileType -eq 'Data')
			{
				$selected = @($allFiles | Where-Object { $_.TypeDesc -eq 'ROWS' })
			}
			elseif ($FileType -eq 'Log')
			{
				$selected = @($allFiles | Where-Object { $_.TypeDesc -eq 'LOG' })
			}

			if (-not $selected -or $selected.Count -eq 0)
			{
				$msg = "Keine passenden Dateien ausgewaehlt (FileType '$FileType', LogicalFileName '$($LogicalFileName -join ', ')')."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				_AddResult 'Precheck' $null $null $null $null 'NoSelection' $msg
				if ($EnableException) { throw $msg }
				return
			}

			# Zielpfade bestimmen, bereits am Ziel liegende Dateien aussortieren
			$plan = [System.Collections.Generic.List[PSCustomObject]]::new()
			foreach ($f in $selected)
			{
				$isLog = ($f.TypeDesc -eq 'LOG')
				$destDir = if ($isLog -and $LogFileDestination) { $LogFileDestination }
				else { $FileDestination }
				$fileName = Split-Path -Path "$($f.PhysicalName)" -Leaf
				$newPath = _CombineServerPath $destDir $fileName
				$oldDir = Split-Path -Path "$($f.PhysicalName)" -Parent

				if ($oldDir.TrimEnd('\').ToUpperInvariant() -eq $destDir.ToUpperInvariant())
				{
					$msg = "'$($f.LogicalName)' liegt bereits in '$destDir'."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
					_AddResult 'Move' "$($f.LogicalName)" "$($f.PhysicalName)" $newPath $f.SizeMB 'AlreadyInPlace' $msg
					continue
				}

				$plan.Add([PSCustomObject]@{
						LogicalName = "$($f.LogicalName)"
						OldPath	    = "$($f.PhysicalName)"
						OldDir	    = $oldDir
						NewPath	    = $newPath
						DestDir	    = $destDir
						SizeMB	    = [double]$f.SizeMB
						IsLog	    = $isLog
					})
			}

			if ($plan.Count -eq 0)
			{
				Invoke-sqmLogging -Message "Nichts zu tun: alle ausgewaehlten Dateien liegen bereits am Ziel." -FunctionName $functionName -Level "INFO"
				return
			}

			# ---------------------------------------------------------------------------------
			# 4. Zielverzeichnisse: sichtbar, berechtigt, beschreibbar, gross genug
			# ---------------------------------------------------------------------------------
			$destDirs = @($plan | Select-Object -ExpandProperty DestDir -Unique)
			$precheckFailed = $false

			foreach ($destDir in $destDirs)
			{
				$dirVisible = $false
				try { $dirVisible = [bool](Test-DbaPath @connParams -Path $destDir) }
				catch { $dirVisible = $false }

				if (-not $dirVisible)
				{
					$winDir = _ToWindowsPath $destDir
					$sampleSourceDir = @($plan | Where-Object { $_.DestDir -eq $destDir })[0].OldDir

					if ($PSCmdlet.ShouldProcess($sqlHostName, "Lege Zielverzeichnis '$destDir' an und uebernehme die Berechtigungen von '$sampleSourceDir'"))
					{
						try
						{
							$null = New-Item -Path $winDir -ItemType Directory -Force -ErrorAction Stop
							Invoke-sqmLogging -Message "Zielverzeichnis '$destDir' angelegt." -FunctionName $functionName -Level "INFO"

							# ACL der Quelle uebernehmen: dort hat das Dienstkonto nachweislich
							# Rechte, ein frisch angelegter Ordner erbt dagegen nur die Wurzel-ACL.
							try
							{
								$srcAcl = Get-Acl -Path (_ToWindowsPath $sampleSourceDir) -ErrorAction Stop
								Set-Acl -Path $winDir -AclObject $srcAcl -ErrorAction Stop
								Invoke-sqmLogging -Message "Berechtigungen von '$sampleSourceDir' auf '$destDir' uebernommen." -FunctionName $functionName -Level "INFO"
							}
							catch
							{
								Invoke-sqmLogging -Message "Berechtigungen konnten nicht von '$sampleSourceDir' uebernommen werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							}

							# Dienstkonto zusaetzlich explizit berechtigen
							try
							{
								$engineSvc = Get-DbaService @svcParams -Type Engine | Select-Object -First 1
								if ($engineSvc -and $engineSvc.StartName)
								{
									$acl = Get-Acl -Path $winDir -ErrorAction Stop
									$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
										"$($engineSvc.StartName)", 'FullControl',
										'ContainerInherit,ObjectInherit', 'None', 'Allow')
									$acl.AddAccessRule($rule)
									Set-Acl -Path $winDir -AclObject $acl -ErrorAction Stop
									Invoke-sqmLogging -Message "Dienstkonto '$($engineSvc.StartName)' hat Vollzugriff auf '$destDir'." -FunctionName $functionName -Level "INFO"
								}
							}
							catch
							{
								Invoke-sqmLogging -Message "Dienstkonto konnte nicht explizit berechtigt werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							}

							try { $dirVisible = [bool](Test-DbaPath @connParams -Path $destDir) }
							catch { $dirVisible = $false }
						}
						catch
						{
							$msg = "Zielverzeichnis '$destDir' konnte nicht angelegt werden ($winDir): $($_.Exception.Message)"
							Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
							_AddResult 'Precheck' $null $null $destDir $null 'Failed' $msg
							$precheckFailed = $true
							continue
						}
					}
					else
					{
						_AddResult 'Precheck' $null $null $destDir $null 'WhatIfSkipped' "WhatIf: Zielverzeichnis '$destDir' wuerde angelegt."
					}
				}

				if (-not $dirVisible -and -not $WhatIfPreference)
				{
					$msg = "Zielverzeichnis '$destDir' ist fuer die Instanz nicht sichtbar (Test-DbaPath). Pruefen Sie Pfad und Rechte des Dienstkontos."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					_AddResult 'Precheck' $null $null $destDir $null 'Failed' $msg
					$precheckFailed = $true
					continue
				}

				# Schreibprobe
				if ($SkipWriteProbe)
				{
					_AddResult 'Precheck' $null $null $destDir $null 'Skipped' "Schreibprobe uebersprungen (-SkipWriteProbe)."
				}
				elseif (-not $dirVisible)
				{
					_AddResult 'Precheck' $null $null $destDir $null 'WhatIfSkipped' "WhatIf: Schreibprobe erst nach Anlegen des Verzeichnisses moeglich."
				}
				else
				{
					$probe = _TestSqlWriteAccess $destDir
					if ($probe.Success)
					{
						Invoke-sqmLogging -Message "Schreibprobe in '$destDir' erfolgreich." -FunctionName $functionName -Level "INFO"
						_AddResult 'Precheck' $null $null $destDir $null 'Success' "Schreibprobe in '$destDir' erfolgreich."
					}
					else
					{
						$msg = "Schreibprobe in '$destDir' fehlgeschlagen: $($probe.Message). Das Dienstkonto der Engine kann dort keine Dateien anlegen."
						if ($Database -eq 'tempdb') { $msg += " tempdb dorthin zu verschieben wuerde bedeuten, dass die Instanz nach dem Neustart nicht mehr startet." }
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
						_AddResult 'Precheck' $null $null $destDir $null 'Failed' $msg
						$precheckFailed = $true
						continue
					}
				}

				# Platzbedarf
				if ($SkipSpaceCheck)
				{
					_AddResult 'Precheck' $null $null $destDir $null 'Skipped' "Platzpruefung uebersprungen (-SkipSpaceCheck)."
				}
				else
				{
					$sumMb = (@($plan | Where-Object { $_.DestDir -eq $destDir }) | Measure-Object -Property SizeMB -Sum).Sum
					$neededMb = [math]::Round($sumMb * (1 + $SpaceBufferPercent / 100), 1)
					$space = _GetFreeSpaceMb $destDir

					if (-not $space)
					{
						$msg = "Freier Platz fuer '$destDir' konnte nicht ermittelt werden. Benoetigt werden rund $neededMb MB."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
						_AddResult 'Precheck' $null $null $destDir $neededMb 'Warning' $msg
					}
					elseif ($space.FreeMB -lt $neededMb)
					{
						$msg = "Zu wenig Platz auf '$($space.Volume)': frei $([math]::Round($space.FreeMB, 1)) MB, benoetigt rund $neededMb MB inkl. $SpaceBufferPercent % Puffer (Quelle: $($space.Source))."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
						_AddResult 'Precheck' $null $null $destDir $neededMb 'Failed' $msg
						$precheckFailed = $true
						continue
					}
					else
					{
						_AddResult 'Precheck' $null $null $destDir $neededMb 'Success' "Platz auf '$($space.Volume)' ausreichend: frei $([math]::Round($space.FreeMB, 1)) MB, benoetigt rund $neededMb MB (Quelle: $($space.Source))."
					}
				}
			}

			if ($precheckFailed)
			{
				$msg = "Vorpruefung fehlgeschlagen. Es wurde nichts veraendert."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				_AddResult 'Precheck' $null $null $null $null 'Aborted' $msg
				if ($EnableException) { throw $msg }
				return
			}

			# ---------------------------------------------------------------------------------
			# 5. Eine einzige Rueckfrage fuer den gesamten Vorgang
			# ---------------------------------------------------------------------------------
			$restartText = if ($dbKind -eq 'System' -and -not $NoRestart) { 'ja (Instanz-Neustart)' }
			elseif ($dbKind -eq 'System') { 'nein (-NoRestart, wirkt erst beim naechsten Start)' }
			else { 'nein (Datenbank wird offline/online geschaltet)' }
			$cleanupText = if ($KeepOldFiles) { 'nein (-KeepOldFiles)' }
			else { 'ja' }
			$planText = "Verschiebe $($plan.Count) Datei(en) von '$((@($plan.OldDir) | Select-Object -Unique) -join ', ')' nach '$($destDirs -join ', ')'. Neustart: $restartText. Alte Dateien entfernen: $cleanupText."

			Invoke-sqmLogging -Message $planText -FunctionName $functionName -Level "INFO"

			if (-not $PSCmdlet.ShouldProcess($SqlInstance, $planText))
			{
				foreach ($p in $plan)
				{
					_AddResult 'Move' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'WhatIfSkipped' $planText
				}
				return
			}

			$agentStateBefore = $null
			if ($dbKind -eq 'System') { $agentStateBefore = _GetAgentState }

			$movedFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
			$appliedAlter = [System.Collections.Generic.List[PSCustomObject]]::new()
			$moveFailed = $false

			# ---------------------------------------------------------------------------------
			# 6a. Benutzerdatenbank: OFFLINE -> kopieren -> MODIFY FILE -> ONLINE
			# ---------------------------------------------------------------------------------
			if ($dbKind -eq 'User')
			{
				$wasOffline = ("$($dbInfo.StateDesc)" -eq 'OFFLINE')

				if (-not $wasOffline)
				{
					try
					{
						$state = Set-DbaDbState @connParams -Database $Database -Offline -Force:$Force -Confirm:$false -EnableException
						if ("$($state.Status)" -notmatch '^(?i)offline$')
						{
							throw "Set-DbaDbState meldete Status '$($state.Status)'."
						}
						Invoke-sqmLogging -Message "Datenbank '$Database' ist offline." -FunctionName $functionName -Level "INFO"
						_AddResult 'Move' $null $null $null $null 'Success' "Datenbank '$Database' ist offline."
					}
					catch
					{
						$msg = "Datenbank '$Database' konnte nicht offline gesetzt werden: $($_.Exception.Message). Ohne -Force bleiben offene Verbindungen bestehen und verhindern das Offline-Setzen."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
						_AddResult 'Move' $null $null $null $null 'Failed' $msg
						if ($EnableException) { throw }
						return
					}
				}

				foreach ($p in $plan)
				{
					try
					{
						$srcWin = _ToWindowsPath $p.OldPath
						$dstWin = _ToWindowsPath $p.NewPath
						Copy-Item -LiteralPath $srcWin -Destination $dstWin -Force -ErrorAction Stop

						$srcLen = (Get-Item -LiteralPath $srcWin -ErrorAction Stop).Length
						$dstLen = (Get-Item -LiteralPath $dstWin -ErrorAction Stop).Length
						if ($srcLen -ne $dstLen) { throw "Groesse weicht ab (Quelle $srcLen Byte, Ziel $dstLen Byte)." }

						$alter = "ALTER DATABASE [$Database] MODIFY FILE (NAME = N'$($p.LogicalName -replace "'", "''")', FILENAME = N'$($p.NewPath -replace "'", "''")');"
						$null = Invoke-DbaQuery @connParams -Database master -Query $alter -EnableException
						$appliedAlter.Add($p)
						$movedFiles.Add($p)

						Invoke-sqmLogging -Message "'$($p.LogicalName)': '$($p.OldPath)' -> '$($p.NewPath)'" -FunctionName $functionName -Level "INFO"
						_AddResult 'Move' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Success' "Kopiert und umgetragen."
					}
					catch
					{
						$msg = "'$($p.LogicalName)' konnte nicht verschoben werden: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
						_AddResult 'Move' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Failed' $msg
						$moveFailed = $true
						break
					}
				}

				# Bei einem Fehler mitten im Vorgang: bereits umgetragene Dateien zuruecksetzen,
				# damit die Datenbank wieder mit den alten Pfaden online gehen kann.
				if ($moveFailed -and $appliedAlter.Count -gt 0)
				{
					foreach ($p in $appliedAlter)
					{
						try
						{
							$revert = "ALTER DATABASE [$Database] MODIFY FILE (NAME = N'$($p.LogicalName -replace "'", "''")', FILENAME = N'$($p.OldPath -replace "'", "''")');"
							$null = Invoke-DbaQuery @connParams -Database master -Query $revert -EnableException
							_AddResult 'Move' $p.LogicalName $p.NewPath $p.OldPath $p.SizeMB 'RolledBack' "Pfad auf den alten Ort zurueckgesetzt."
						}
						catch
						{
							_AddResult 'Move' $p.LogicalName $p.NewPath $p.OldPath $p.SizeMB 'Failed' "Ruecksetzen des Pfades fehlgeschlagen: $($_.Exception.Message)"
						}
					}
					$movedFiles.Clear()
				}

				if (-not $wasOffline)
				{
					try
					{
						$null = Set-DbaDbState @connParams -Database $Database -Online -Confirm:$false -EnableException
						Invoke-sqmLogging -Message "Datenbank '$Database' ist wieder online." -FunctionName $functionName -Level "INFO"
						_AddResult 'Move' $null $null $null $null 'Success' "Datenbank '$Database' ist wieder online."
					}
					catch
					{
						$msg = "Datenbank '$Database' konnte nicht online gesetzt werden: $($_.Exception.Message). Alte Dateien werden nicht entfernt."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
						_AddResult 'Move' $null $null $null $null 'Failed' $msg
						$movedFiles.Clear()
						if ($EnableException) { throw }
					}
				}
			}

			# ---------------------------------------------------------------------------------
			# 6b. Systemdatenbank: MODIFY FILE -> Dienstaktion -> (model/msdb) kopieren
			# ---------------------------------------------------------------------------------
			else
			{
				foreach ($p in $plan)
				{
					try
					{
						$alter = "ALTER DATABASE [$Database] MODIFY FILE (NAME = N'$($p.LogicalName -replace "'", "''")', FILENAME = N'$($p.NewPath -replace "'", "''")');"
						$null = Invoke-DbaQuery @connParams -Database master -Query $alter -EnableException
						$appliedAlter.Add($p)
						Invoke-sqmLogging -Message "'$($p.LogicalName)' umgetragen: '$($p.OldPath)' -> '$($p.NewPath)' (wirkt mit dem Neustart)." -FunctionName $functionName -Level "INFO"
						_AddResult 'Move' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Success' "Pfad umgetragen, wird mit dem Neustart wirksam."
					}
					catch
					{
						$msg = "'$($p.LogicalName)' konnte nicht umgetragen werden: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
						_AddResult 'Move' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Failed' $msg
						$moveFailed = $true
						break
					}
				}

				if ($moveFailed -and $appliedAlter.Count -gt 0)
				{
					foreach ($p in $appliedAlter)
					{
						try
						{
							$revert = "ALTER DATABASE [$Database] MODIFY FILE (NAME = N'$($p.LogicalName -replace "'", "''")', FILENAME = N'$($p.OldPath -replace "'", "''")');"
							$null = Invoke-DbaQuery @connParams -Database master -Query $revert -EnableException
							_AddResult 'Move' $p.LogicalName $p.NewPath $p.OldPath $p.SizeMB 'RolledBack' "Pfad auf den alten Ort zurueckgesetzt, ein Neustart ist nicht noetig."
						}
						catch
						{
							_AddResult 'Move' $p.LogicalName $p.NewPath $p.OldPath $p.SizeMB 'Failed' "Ruecksetzen des Pfades fehlgeschlagen: $($_.Exception.Message). ACHTUNG: vor dem naechsten Neustart pruefen."
						}
					}
					$appliedAlter.Clear()
				}
				elseif ($NoRestart)
				{
					$msg = "Pfade sind umgetragen, die Instanz wurde auf Wunsch (-NoRestart) NICHT neu gestartet. Die neuen tempdb-Dateien entstehen beim naechsten Start; die alten bleiben bis dahin liegen und wurden nicht entfernt."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					_AddResult 'Restart' $null $null $null $null 'PendingRestart' $msg
				}
				else
				{
					$restartOk = $false
					try
					{
						if ($Database -eq 'tempdb')
						{
							# tempdb wird beim Start neu angelegt: ein Neustart genuegt, es wird
							# nichts kopiert. -Force nimmt die abhaengigen Dienste mit.
							$null = Restart-DbaService @svcParams -Type Engine -Force -Confirm:$false -EnableException
						}
						else
						{
							# model/msdb: die Dateien muessen bei gestopptem Dienst physisch an den
							# neuen Ort, sonst findet die Instanz sie beim Start nicht.
							$null = Stop-DbaService @svcParams -Type Engine -Force -Confirm:$false -EnableException
							foreach ($p in $appliedAlter)
							{
								Copy-Item -LiteralPath (_ToWindowsPath $p.OldPath) -Destination (_ToWindowsPath $p.NewPath) -Force -ErrorAction Stop
								Invoke-sqmLogging -Message "'$($p.LogicalName)' kopiert nach '$($p.NewPath)'." -FunctionName $functionName -Level "INFO"
							}
							$null = Start-DbaService @svcParams -Type Engine -Confirm:$false -EnableException
						}
						$restartOk = $true
					}
					catch
					{
						$msg = "Dienstaktion fehlgeschlagen: $($_.Exception.Message). Die Pfade sind bereits umgetragen - die Instanz muss manuell in einen konsistenten Zustand gebracht werden. Ist-Stand pruefen mit: SELECT name, physical_name FROM sys.master_files WHERE database_id = DB_ID('$Database')."
						Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
						_AddResult 'Restart' $null $null $null $null 'Failed' $msg
						if ($EnableException) { throw }
					}

					if ($restartOk)
					{
						if (_WaitForInstance $RestartTimeoutSeconds)
						{
							Invoke-sqmLogging -Message "Instanz '$SqlInstance' ist nach der Dienstaktion wieder erreichbar." -FunctionName $functionName -Level "INFO"
							_AddResult 'Restart' $null $null $null $null 'Success' "Instanz nach der Dienstaktion wieder erreichbar."

							# Erst jetzt gilt eine Datei als verschoben: der neue Pfad muss da sein.
							foreach ($p in $appliedAlter)
							{
								$exists = $false
								try { $exists = [bool](Test-DbaPath @connParams -Path $p.NewPath) }
								catch { $exists = $false }

								if ($exists)
								{
									$movedFiles.Add($p)
								}
								else
								{
									$msg = "Datei '$($p.NewPath)' ist nach dem Neustart nicht vorhanden. Die alte Datei wird nicht entfernt."
									Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
									_AddResult 'Move' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Failed' $msg
								}
							}
						}
						else
						{
							$msg = "Instanz '$SqlInstance' war nach $RestartTimeoutSeconds Sekunden nicht erreichbar. Alte Dateien werden NICHT entfernt. Pruefen Sie das SQL-Fehlerprotokoll: ein nicht erreichbarer tempdb-Pfad verhindert den Start."
							Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
							_AddResult 'Restart' $null $null $null $null 'Failed' $msg
							if ($EnableException) { throw $msg }
						}
					}

					# SQL Agent wieder in den Zustand von vorher bringen
					if ($agentStateBefore -eq 'Running')
					{
						if ((_GetAgentState) -ne 'Running')
						{
							try
							{
								$null = Start-DbaService @svcParams -Type Agent -Confirm:$false -EnableException
								_AddResult 'Restart' $null $null $null $null 'Success' "SQL Server Agent wieder gestartet (lief vor der Aktion)."
							}
							catch
							{
								$msg = "SQL Server Agent lief vor der Aktion, konnte aber nicht gestartet werden: $($_.Exception.Message)"
								Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
								_AddResult 'Restart' $null $null $null $null 'Warning' $msg
							}
						}
					}
				}
			}

			# ---------------------------------------------------------------------------------
			# 7. Alte Dateien entfernen - nur fuer nachweislich verschobene Dateien
			# ---------------------------------------------------------------------------------
			if ($movedFiles.Count -eq 0) { return }

			if ($KeepOldFiles)
			{
				foreach ($p in $movedFiles)
				{
					_AddResult 'Cleanup' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Skipped' "Alte Datei bleibt liegen (-KeepOldFiles)."
				}
				return
			}

			foreach ($p in $movedFiles)
			{
				$oldWin = _ToWindowsPath $p.OldPath
				try
				{
					if (Test-Path -LiteralPath $oldWin)
					{
						Remove-Item -LiteralPath $oldWin -Force -ErrorAction Stop
						Invoke-sqmLogging -Message "Alte Datei entfernt: '$($p.OldPath)'" -FunctionName $functionName -Level "INFO"
						_AddResult 'Cleanup' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Success' "Alte Datei entfernt."
					}
					else
					{
						_AddResult 'Cleanup' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Skipped' "Alte Datei war nicht mehr vorhanden."
					}
				}
				catch
				{
					$msg = "Alte Datei '$($p.OldPath)' konnte nicht entfernt werden: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					_AddResult 'Cleanup' $p.LogicalName $p.OldPath $p.NewPath $p.SizeMB 'Failed' $msg
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler in $functionName : $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			_AddResult 'Move' $null $null $null $null 'GlobalError' $errMsg
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Ergebniszeilen." -FunctionName $functionName -Level "INFO"
		return $results
	}
}
