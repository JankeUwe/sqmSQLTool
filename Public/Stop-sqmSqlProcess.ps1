<#
.SYNOPSIS
    Beendet eine oder mehrere SQL Server Sessions (SPIDs) und benachrichtigt optional den Besitzer per Netzwerknachricht.

.DESCRIPTION
    Liest vor dem Kill die Sitzungsdaten (Login, Hostname, Programm, Datenbank) aus
    sys.dm_exec_sessions, beendet die angegebene(n) Session(en) per Stop-DbaProcess (KILL)
    und sendet danach optional (-NotifyOwner) eine Nachricht an alle aktiven interaktiven
    Sitzungen auf dem Hostnamen der Session, damit der Anwender merkt, dass seine
    Verbindung/Abfrage beendet wurde.

    "net send" existiert seit Windows Vista nicht mehr (Messenger-Dienst entfernt). Der
    Nachfolger msg.exe wurde geprueft, ist aber auf Windows-Client-SKUs (verifiziert:
    Windows 11 Home) haeufig NICHT installiert - deshalb ruft diese Funktion stattdessen die
    zugrundeliegende WTSSendMessage-API aus wtsapi32.dll direkt per P/Invoke auf (siehe
    Send-sqmWtsMessage), die auf jeder Windows-Installation vorhanden ist. Das braucht weiterhin
    eine aktive interaktive/RDP-Sitzung auf der Zielmaschine sowie Zugriffsrechte dort.
    host_name in sys.dm_exec_sessions ist ein vom Client gemeldeter Wert (nicht verifiziert) -
    bei Verbindungen ueber Anwendungsserver/Service-Accounts sitzt dort haeufig niemand
    Interaktives, die Benachrichtigung geht dann ins Leere. Ein Fehlschlag der Benachrichtigung
    bricht den Kill NICHT ab, sondern wird nur protokolliert.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER Spid
    Eine oder mehrere Session-IDs (SPIDs), die beendet werden sollen.

.PARAMETER Reason
    Freitext-Begruendung, die in der Netzwerknachricht an den Besitzer mitgeschickt wird.

.PARAMETER NotifyOwner
    Sendet nach dem Kill eine Nachricht an alle aktiven interaktiven Sitzungen auf dem
    Hostnamen der beendeten Session (per WTSSendMessage, siehe Send-sqmWtsMessage).
    Standardmaessig AUS, damit automatisierte/Job-basierte Kills keine ungewollten Popups
    ausloesen.

.PARAMETER NotifyTimeoutSeconds
    Anzeigedauer der msg.exe-Nachricht beim Empfaenger in Sekunden. Standard: 30.

.PARAMETER EnableException
    Wirft Exceptions sofort statt sie als Fehler zurueckzugeben.

.EXAMPLE
    Stop-sqmSqlProcess -SqlInstance "SQL01" -Spid 62

.EXAMPLE
    Stop-sqmSqlProcess -SqlInstance "SQL01" -Spid 62,71 -Reason "Blockiert Tagesabschluss" -NotifyOwner

.EXAMPLE
    # Alle Sessions einer Blockierungskette beenden und Besitzer benachrichtigen
    $chain = Get-sqmBlockingReport -SqlInstance "SQL01"
    Stop-sqmSqlProcess -SqlInstance "SQL01" -Spid $chain.BlockedSessions.BlockedSpid -Reason "Blockierung aufgeloest" -NotifyOwner

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Send-sqmWtsMessage
    Benoetigt VIEW SERVER STATE (lesen) und ALTER ANY CONNECTION (killen) auf der Instanz.
    Die Benachrichtigung nutzt WTSSendMessage (wtsapi32.dll) statt msg.exe, da msg.exe auf
    Windows-Client-SKUs oft fehlt (siehe Send-sqmWtsMessage). Live verifiziert: DEV03 lokal
    und DEV03 -> DEV01 cross-machine in einer Workgroup-Umgebung ohne AD-Domaene.
#>
function Stop-sqmSqlProcess
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[int[]]$Spid,
		[Parameter(Mandatory = $false)]
		[string]$Reason,
		[Parameter(Mandatory = $false)]
		[switch]$NotifyOwner,
		[Parameter(Mandatory = $false)]
		[int]$NotifyTimeoutSeconds = 30,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Spid=$($Spid -join ','), NotifyOwner=$($NotifyOwner.IsPresent))" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# -----------------------------------------------------------------------
			# Sitzungsdaten VOR dem Kill lesen - nach KILL ist die Zeile in
			# sys.dm_exec_sessions weg, dann waeren Hostname/Login nicht mehr ermittelbar.
			# -----------------------------------------------------------------------
			$spidList = ($Spid | Select-Object -Unique) -join ','
			$sessionQuery = @"
SELECT
    session_id     AS Spid,
    login_name     AS LoginName,
    host_name      AS HostName,
    program_name   AS ProgramName,
    DB_NAME(database_id) AS DatabaseName,
    status         AS Status
FROM sys.dm_exec_sessions
WHERE session_id IN ($spidList)
  AND is_user_process = 1
"@

			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database	  = 'master'
				ErrorAction   = 'Stop'
			}

			$sessionInfo = Invoke-DbaQuery @connParams -Query $sessionQuery
			$foundSpids = @($sessionInfo | Select-Object -ExpandProperty Spid)

			$results = [System.Collections.Generic.List[PSCustomObject]]::new()

			foreach ($targetSpid in ($Spid | Select-Object -Unique))
			{
				$row = $sessionInfo | Where-Object { $_.Spid -eq $targetSpid } | Select-Object -First 1

				if (-not $row)
				{
					$notFoundMsg = "SPID $targetSpid nicht (mehr) als aktiver User-Prozess auf $SqlInstance gefunden - vermutlich bereits beendet."
					Invoke-sqmLogging -Message $notFoundMsg -FunctionName $functionName -Level "WARNING"
					$results.Add([PSCustomObject]@{
							Spid = $targetSpid
							LoginName = $null
							HostName = $null
							DatabaseName = $null
							KillStatus = 'NotFound'
							NotifyStatus = 'Skipped'
							Message = $notFoundMsg
						})
					continue
				}

				$target = "$SqlInstance (SPID $targetSpid, Login '$($row.LoginName)', Host '$($row.HostName)')"
				if (-not $PSCmdlet.ShouldProcess($target, 'Stop-DbaProcess (KILL)'))
				{
					$results.Add([PSCustomObject]@{
							Spid = $targetSpid
							LoginName = $row.LoginName
							HostName = $row.HostName
							DatabaseName = $row.DatabaseName
							KillStatus = 'WhatIf'
							NotifyStatus = 'Skipped'
							Message = 'ShouldProcess abgelehnt (WhatIf).'
						})
					continue
				}

				$killStatus = 'Success'
				$killMessage = "SPID $targetSpid beendet."
				try
				{
					Stop-DbaProcess -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Spid $targetSpid -Confirm:$false -EnableException -ErrorAction Stop
					Invoke-sqmLogging -Message "SPID $targetSpid (Login '$($row.LoginName)', Host '$($row.HostName)', DB '$($row.DatabaseName)') auf $SqlInstance beendet. Grund: $Reason" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$killStatus = 'Failed'
					$killMessage = "Konnte SPID $targetSpid nicht beenden: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $killMessage -FunctionName $functionName -Level "ERROR"
				}

				# -----------------------------------------------------------------------
				# Optionale Besitzerbenachrichtigung per msg.exe. Ein Fehlschlag hier
				# (Host offline/nicht erreichbar, keine Berechtigung, kein Hostname bekannt)
				# darf den bereits erfolgten Kill nicht als Fehlschlag erscheinen lassen -
				# daher eigenes NotifyStatus-Feld statt Exception nach oben durchzureichen.
				# -----------------------------------------------------------------------
				$notifyStatus = 'Skipped'
				$notifyMessage = 'Nicht angefordert (-NotifyOwner nicht gesetzt).'

				if ($NotifyOwner -and $killStatus -eq 'Success')
				{
					if ([string]::IsNullOrWhiteSpace($row.HostName))
					{
						$notifyStatus = 'Skipped'
						$notifyMessage = 'Kein Hostname fuer diese Session bekannt - Benachrichtigung uebersprungen.'
						Invoke-sqmLogging -Message "SPID $targetSpid`: $notifyMessage" -FunctionName $functionName -Level "WARNING"
					}
					else
					{
						$messageText = "Ihre Verbindung zu '$SqlInstance' (SPID $targetSpid, Datenbank '$($row.DatabaseName)') wurde soeben durch den DBA beendet. Die Verbindung ist geschlossen, eine laufende Transaktion wurde automatisch zurueckgerollt. Bitte melden Sie sich bei Bedarf erneut an."
						if ($Reason) { $messageText += " Grund: $Reason" }

						$wtsResult = Send-sqmWtsMessage -ComputerName $row.HostName -Title 'sqmSQLTool' -Message $messageText -TimeoutSeconds $NotifyTimeoutSeconds

						if ($wtsResult.WasDelivered)
						{
							$notifyStatus = 'Success'
							$notifyMessage = "Nachricht an '$($row.HostName)' gesendet (Sitzung(en): $($wtsResult.SessionIds -join ','))."
						}
						else
						{
							$notifyStatus = 'Failed'
							$notifyMessage = "Zustellung an '$($row.HostName)' fehlgeschlagen: $($wtsResult.Error)"
						}

						$logLevel = if ($notifyStatus -eq 'Success') { 'INFO' } else { 'WARNING' }
						Invoke-sqmLogging -Message "SPID $targetSpid`: $notifyMessage" -FunctionName $functionName -Level $logLevel
					}
				}

				$results.Add([PSCustomObject]@{
						Spid = $targetSpid
						LoginName = $row.LoginName
						HostName = $row.HostName
						DatabaseName = $row.DatabaseName
						KillStatus = $killStatus
						NotifyStatus = $notifyStatus
						Message = "$killMessage $notifyMessage".Trim()
					})
			}

			return $results
		}
		catch
		{
			$errMsg = "Fehler in $functionName auf $SqlInstance`: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}
