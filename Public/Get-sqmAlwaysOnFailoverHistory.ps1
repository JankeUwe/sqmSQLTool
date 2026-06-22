<#
.SYNOPSIS
    Ermittelt AlwaysOn-Failover-Ereignisse aus dem Windows Event Log.

.DESCRIPTION
    Wertet den Windows Application Event Log auf dem Zielcomputer aus und
    liefert alle AlwaysOn-Failover-Ereignisse im angegebenen Zeitraum.

    Primaerquelle: Application Log, EventID 1480
    "The %ls role of availability group '%s' has been successfully changed to '%ls'."
    Diese EventID wird von SQL Server bei jedem AG-Rollenuebergang geschrieben.
    Sie ist strukturiert, sprachunabhaengig und in allen SQL Server-Versionen
    verfuegbar (SQL 2012+).

    Optional: Windows Failover Clustering Operational Log (EventID 1641)
    Liefert die Cluster-Perspektive des Failovers. Nur verfuegbar wenn WSFC
    installiert und der Log aktiv ist (-IncludeClusterLog).

    Ergaenzung: sys.dm_hadr_availability_replica_states.current_configuration_commit_start_time_utc
    (Naeherung fuer den Rollenzeitpunkt der lokalen Replica - ein echtes role_start_time gibt es in
    dieser DMV nicht). Wird als zusaetzliche Zeile mit Source 'RoleStartTime' ausgegeben wenn
    -SqlInstance angegeben ist. Massgeblich bleibt das Event Log (EventID 1480).

    FailoverType-Erkennung:
    - 'Planned'   : EventID 1480, Message enthaelt "user" oder "manual"
    - 'Automatic' : EventID 1480, Message enthaelt "automatic" oder "WSFC"
    - 'Forced'    : EventID 19407 (Lease-Ablauf) im gleichen Zeitfenster vorhanden
    - 'Unknown'   : Kein eindeutiges Merkmal erkennbar

    Ausgabe:
        AlwaysOnFailoverHistory_<computer>_<datum>.txt  - Lesbarer Bericht
        AlwaysOnFailoverHistory_<computer>_<datum>.csv  - Maschinenlesbar

.PARAMETER ComputerName
    Zielcomputer. Standard: aktueller Computer.
    Mehrere Computer moeglich (Pipeline). Event Log wird remote abgefragt.

.PARAMETER SqlInstance
    SQL Server-Instanz fuer role_start_time-Ergaenzung. Optional.
    Wird nicht benoetigt wenn nur Event Log ausgewertet wird.

.PARAMETER SqlCredential
    Optionales PSCredential fuer die SQL-Verbindung.

.PARAMETER AvailabilityGroup
    Filter auf eine bestimmte AG. Leer = alle AGs.

.PARAMETER Since
    Wie weit zurueck suchen. Standard: 30 Tage.

.PARAMETER IncludeClusterLog
    WSFC Operational Log (Microsoft-Windows-FailoverClustering/Operational)
    zusaetzlich auswerten. Nur verfuegbar auf WSFC-Nodes.

.PARAMETER OutputPath
    Ausgabeverzeichnis. Standard: C:\System\WinSrvLog\MSSQL

.PARAMETER ContinueOnError
    Bei Fehler auf einem Computer fortfahren.

.PARAMETER EnableException
    Fehler als terminierende Ausnahmen ausloesen.

.EXAMPLE
    Get-sqmAlwaysOnFailoverHistory

.EXAMPLE
    Get-sqmAlwaysOnFailoverHistory -ComputerName "SQL01" -Since (Get-Date).AddDays(-90)

.EXAMPLE
    Get-sqmAlwaysOnFailoverHistory -ComputerName "SQL01" `
        -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -IncludeClusterLog

.EXAMPLE
    "SQL01","SQL02" | Get-sqmAlwaysOnFailoverHistory -Since (Get-Date).AddDays(-7)

.NOTES
    Benoetigt: Lesezugriff auf Windows Event Log des Zielcomputers.
    SQL-Verbindung nur wenn -SqlInstance angegeben (fuer role_start_time).
    Getestet auf SQL Server 2016-2022, PowerShell 5.1+.
#>
function Get-sqmAlwaysOnFailoverHistory
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$ComputerName = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroup,

		[Parameter(Mandatory = $false)]
		[datetime]$Since = (Get-Date).AddDays(-30),

		[Parameter(Mandatory = $false)]
		[switch]$IncludeClusterLog,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = 'C:\System\WinSrvLog\MSSQL',

		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException,

		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		Invoke-sqmLogging -Message "Starte $functionName. Since: $($Since.ToString('yyyy-MM-dd HH:mm')), OutputPath: $OutputPath" `
			-FunctionName $functionName -Level 'INFO'

		# ------------------------------------------------------------------
		# FailoverType aus Event-Message ableiten
		# ------------------------------------------------------------------
		function _GetFailoverType
		{
			param ([string]$Message, [bool]$LeaseExpiredNearby)
			if ($LeaseExpiredNearby)                              { return 'Forced' }
			if ($Message -match 'user|manual|manuell')            { return 'Planned' }
			if ($Message -match 'automatic|WSFC|automatisch')     { return 'Automatic' }
			return 'Unknown'
		}

		# ------------------------------------------------------------------
		# Rollenuebergang aus EventID 1480 Message parsen
		# Nachricht (EN): "The PRIMARY role of availability group 'AG_Prod' has
		#   been successfully changed to SECONDARY."
		# Nachricht (DE): "Die PRIMAER-Rolle der Verfuegbarkeitsgruppe 'AG_Prod'
		#   wurde erfolgreich in SEKUNDAER geaendert."
		# Wir lesen NewRole aus dem AG-Rollenuebergang-Event:
		# Das Event wird auf dem Knoten geschrieben der die NEUE Rolle annimmt.
		# ------------------------------------------------------------------
		function _ParseRole
		{
			param ([string]$Message)
			if ($Message -match 'PRIMARY|PRIMAER|primaer|primary')   { return 'PRIMARY' }
			if ($Message -match 'SECONDARY|SEKUNDAER|secondary')     { return 'SECONDARY' }
			if ($Message -match 'RESOLVING|resolving')                { return 'RESOLVING' }
			return 'UNKNOWN'
		}

		function _ParseAGName
		{
			param ([string]$Message)
			# EN: availability group 'NAME'
			# DE: Verfuegbarkeitsgruppe 'NAME'
			if ($Message -match "(?:availability group|Verfuegbarkeitsgruppe)\s+'([^']+)'")
			{
				return $matches[1]
			}
			return ''
		}
	}

	process
	{
		foreach ($computer in $ComputerName)
		{
			$computerResults = [System.Collections.Generic.List[PSCustomObject]]::new()

			try
			{
				Invoke-sqmLogging -Message "[$computer] Starte Event Log Auswertung..." `
					-FunctionName $functionName -Level 'INFO'

				# ----------------------------------------------------------
				# 1. Application Log — EventID 1480 (Rollenuebergang)
				#    und EventID 19407 (Lease-Ablauf = Forced Failover Indikator)
				# ----------------------------------------------------------
				$filterApp = @{
					LogName   = 'Application'
					Id        = @(1480, 19407)
					StartTime = $Since
				}
				if ($computer -ne $env:COMPUTERNAME)
				{
					$filterApp['ComputerName'] = $computer
				}

				$appEvents = $null
				try
				{
					$getParams = @{ FilterHashtable = $filterApp; ErrorAction = 'Stop' }
					if ($computer -ne $env:COMPUTERNAME) { $getParams['ComputerName'] = $computer }
					$appEvents = Get-WinEvent @getParams
					Invoke-sqmLogging -Message "[$computer] $($appEvents.Count) Event(s) in Application Log gefunden (ID 1480/19407)." `
						-FunctionName $functionName -Level 'INFO'
				}
				catch [System.Exception]
				{
					if ($_.Exception.Message -match 'No events were found')
					{
						Invoke-sqmLogging -Message "[$computer] Keine Failover-Events im Application Log seit $($Since.ToString('yyyy-MM-dd'))." `
							-FunctionName $functionName -Level 'INFO'
						$appEvents = @()
					}
					else { throw }
				}

				# Lease-Ablauf-Zeitstempel fuer Forced-Failover-Erkennung sammeln
				$leaseExpiredTimes = @(
					$appEvents |
					Where-Object { $_.Id -eq 19407 } |
					ForEach-Object { $_.TimeCreated }
				)

				# EventID 1480 verarbeiten
				foreach ($ev in ($appEvents | Where-Object { $_.Id -eq 1480 }))
				{
					$msg    = $ev.Message
					$agName = _ParseAGName $msg
					$role   = _ParseRole   $msg

					# AG-Filter anwenden
					if ($AvailabilityGroup -and $agName -and $agName -ne $AvailabilityGroup) { continue }

					# Forced-Failover: EventID 19407 innerhalb von 5 Minuten vor diesem Event?
					$leaseNearby = $false
					foreach ($lt in $leaseExpiredTimes)
					{
						$diff = ($ev.TimeCreated - $lt).TotalMinutes
						if ($diff -ge 0 -and $diff -le 5) { $leaseNearby = $true; break }
					}

					$failoverType = _GetFailoverType -Message $msg -LeaseExpiredNearby $leaseNearby

					$computerResults.Add([PSCustomObject]@{
						ComputerName      = $computer
						AvailabilityGroup = $agName
						FailoverTime      = $ev.TimeCreated
						NewRole           = $role
						FailoverType      = $failoverType
						EventId           = $ev.Id
						Source            = 'ApplicationLog'
						Message           = if ($msg.Length -gt 200) { $msg.Substring(0, 200) + '...' } else { $msg }
					})
				}

				# ----------------------------------------------------------
				# 2. WSFC Operational Log — EventID 1641 (optional)
				# ----------------------------------------------------------
				if ($IncludeClusterLog)
				{
					$clusterLogName = 'Microsoft-Windows-FailoverClustering/Operational'
					$filterCluster  = @{
						LogName   = $clusterLogName
						Id        = 1641
						StartTime = $Since
					}

					$clusterEvents = $null
					try
					{
						$getClParams = @{ FilterHashtable = $filterCluster; ErrorAction = 'Stop' }
						if ($computer -ne $env:COMPUTERNAME) { $getClParams['ComputerName'] = $computer }
						$clusterEvents = Get-WinEvent @getClParams
						Invoke-sqmLogging -Message "[$computer] $($clusterEvents.Count) Cluster-Event(s) (ID 1641) gefunden." `
							-FunctionName $functionName -Level 'INFO'

						foreach ($cev in $clusterEvents)
						{
							$cmsg   = $cev.Message
							$agName = _ParseAGName $cmsg
							if ($AvailabilityGroup -and $agName -and $agName -ne $AvailabilityGroup) { continue }

							$computerResults.Add([PSCustomObject]@{
								ComputerName      = $computer
								AvailabilityGroup = $agName
								FailoverTime      = $cev.TimeCreated
								NewRole           = 'PRIMARY'   # EventID 1641 = Ressource-Gruppe auf diesen Node verschoben
								FailoverType      = 'Unknown'
								EventId           = $cev.Id
								Source            = 'ClusterLog'
								Message           = if ($cmsg.Length -gt 200) { $cmsg.Substring(0, 200) + '...' } else { $cmsg }
							})
						}
					}
					catch
					{
						if ($_.Exception.Message -match 'No events were found')
						{
							Invoke-sqmLogging -Message "[$computer] Keine Cluster-Events (ID 1641) seit $($Since.ToString('yyyy-MM-dd'))." `
								-FunctionName $functionName -Level 'INFO'
						}
						elseif ($_.Exception.Message -match 'not an event log')
						{
							Invoke-sqmLogging -Message "[$computer] WSFC Operational Log nicht verfuegbar (kein WSFC-Node?)." `
								-FunctionName $functionName -Level 'WARNING'
						}
						else
						{
							Invoke-sqmLogging -Message "[$computer] Cluster-Log Fehler: $($_.Exception.Message)" `
								-FunctionName $functionName -Level 'WARNING'
						}
					}
				}

				# ----------------------------------------------------------
				# 3. role_start_time via SQL (optional, wenn SqlInstance angegeben)
				# ----------------------------------------------------------
				if ($SqlInstance)
				{
					try
					{
						$q = @"
SELECT
    ag.name                        AS AGName,
    ar.replica_server_name         AS ReplicaName,
    ars.role_desc                  AS CurrentRole,
    -- sys.dm_hadr_availability_replica_states hat KEIN role_start_time. Naechstbeste valide Spalte
    -- ist current_configuration_commit_start_time_utc (UTC) als Naeherung fuer den Rollenzeitpunkt.
    ars.current_configuration_commit_start_time_utc AS RoleStartTime
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar
    ON ar.replica_id = ars.replica_id
JOIN sys.availability_groups ag
    ON ag.group_id = ars.group_id
WHERE ars.is_local = 1
"@
						$connParams = @{ SqlInstance = $SqlInstance }
						if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

						$rows = Invoke-DbaQuery @connParams -Query $q -ErrorAction Stop
						foreach ($row in $rows)
						{
							if ($AvailabilityGroup -and $row.AGName -ne $AvailabilityGroup) { continue }
							# RoleStartTime ist UTC; gegen UTC vergleichen. NULL (z.B. Secondary) ueberspringen.
							if (-not $row.RoleStartTime -or $row.RoleStartTime -lt $Since.ToUniversalTime()) { continue }

							$computerResults.Add([PSCustomObject]@{
								ComputerName      = $computer
								AvailabilityGroup = $row.AGName
								FailoverTime      = $row.RoleStartTime
								NewRole           = $row.CurrentRole
								FailoverType      = 'Unknown'
								EventId           = $null
								Source            = 'RoleStartTime'
								Message           = "Aktuelle Rolle seit $($row.RoleStartTime.ToString('yyyy-MM-dd HH:mm:ss')). Replica: $($row.ReplicaName)"
							})
						}
						Invoke-sqmLogging -Message "[$computer] role_start_time fuer $($rows.Count) Replica(s) abgerufen." `
							-FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						Invoke-sqmLogging -Message "[$computer] role_start_time konnte nicht abgerufen werden: $($_.Exception.Message)" `
							-FunctionName $functionName -Level 'WARNING'
					}
				}

				# ----------------------------------------------------------
				# Zeitlich sortieren
				# ----------------------------------------------------------
				$sorted = $computerResults | Sort-Object FailoverTime -Descending
				foreach ($r in $sorted) { $allResults.Add($r) }

				Invoke-sqmLogging -Message "[$computer] $($computerResults.Count) Failover-Ereignis(se) gefunden." `
					-FunctionName $functionName -Level 'INFO'

				# ----------------------------------------------------------
				# Ausgabe schreiben
				# ----------------------------------------------------------
				if ($PSCmdlet.ShouldProcess($computer, "Failover-Bericht erstellen"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
					}

					$datestamp = Get-Date -Format 'yyyy-MM-dd'
					$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
					$safeComp  = $computer -replace '[\\/:*?"<>|]', '_'
					$txtFile   = Join-Path $OutputPath "AlwaysOnFailoverHistory_${safeComp}_${datestamp}.txt"
					$csvFile   = Join-Path $OutputPath "AlwaysOnFailoverHistory_${safeComp}_${datestamp}.csv"

					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add('# ================================================================')
					$lines.Add('# sqmSQLTool - AlwaysOn Failover-Historie')
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Computer  : $computer")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# Zeitraum  : ab $($Since.ToString('yyyy-MM-dd HH:mm'))")
					$lines.Add("# Ereignisse: $($computerResults.Count)")
					$lines.Add('# ================================================================')
					$lines.Add('')

					if ($computerResults.Count -eq 0)
					{
						$lines.Add("  Keine Failover-Ereignisse im Zeitraum gefunden.")
					}
					else
					{
						foreach ($ev in $sorted)
						{
							$lines.Add(("  {0,-22} {1,-20} {2,-10} {3,-10} {4,-15} [{5}]" -f
								$ev.FailoverTime.ToString('yyyy-MM-dd HH:mm:ss'),
								$ev.AvailabilityGroup,
								$ev.NewRole,
								$ev.FailoverType,
								$ev.Source,
								$ev.EventId))
							$lines.Add("    $($ev.Message)")
							$lines.Add('')
						}
					}

					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$sorted | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					Invoke-sqmOpenReport -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$computer] Bericht erstellt: $txtFile" `
						-FunctionName $functionName -Level 'INFO'
				}
			}
			catch
			{
				$errMsg = "[$computer] Fehler: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Ereignis(se) gesamt." `
			-FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
