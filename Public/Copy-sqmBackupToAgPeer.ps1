<#
.SYNOPSIS
    Kopiert Backup-Dateien aus einem lokalen Verzeichnis auf denselben Pfad der anderen Always-On-Replikate.

.DESCRIPTION
    Fuer Backups, die knoten-lokal liegen und nach einem Failover auf dem neuen Primary vorhanden sein muessen
    (z. B. anonymisierte Datenbanken, die ein anderes Team ueber den Listener abholt). Die Funktion ermittelt die
    Partner-Server selbst aus den Katalogsichten des AG (sys.availability_replicas) und kopiert -SourcePath per
    robocopy ueber die Admin-Freigabe (\\<Partner>\<Laufwerk>$\<Pfad>) in das gleichnamige Verzeichnis. Voraussetzung
    ist, dass die Verzeichnisse auf allen Knoten gleich heissen.

    Kopiert wird nur, was auf dem Partner fehlt oder aelter ist (robocopy /XO). Es wird nie etwas geloescht, auch
    nicht mit gleichem Namen auf dem Partner neuer: nach einem Failover kann der Partner den juengeren Stand haben,
    und der darf nicht ueberschrieben werden. Mehrfaches Ausfuehren ist harmlos, ein zweiter Lauf kopiert nichts.

    Gedacht als zusaetzlicher Step direkt nach dem Backup und als Nachhol-Job (am Wochenende), der bei einem
    Failover waehrend des Kopierens oder bei einem gerade neu startenden Partner den Rest erledigt. Auf einem
    Secondary soll nichts kopiert werden: im Agent-Job ueber New-sqmAgentCommandJob mit PrimaryOnly = $true
    einrichten, dann ist derselbe Job auf allen Knoten installiert und folgt dem Failover.

    Robocopy meldet Erfolg mit Exitcodes unter 8. Ab 8 gilt der Partner als fehlgeschlagen; mit -EnableException
    (im Agent-Job automatisch gesetzt) wirft die Funktion dann nach dem letzten Partner, damit der Job rot wird.

.PARAMETER SqlInstance
    Instanz, aus der die Partner-Replikate gelesen werden. Standard: lokaler Computername. Der Quellpfad wird auf dem
    Rechner gelesen, auf dem die Funktion laeuft (also lokal auf dem Knoten).

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung fuer die Abfrage der Replikate.

.PARAMETER SourcePath
    Lokales Verzeichnis mit den Backups, z. B. 'G:\Backup\Anonym'. Laufwerksbuchstabe erforderlich, damit der
    Admin-Freigabe-Pfad auf dem Partner gebildet werden kann.

.PARAMETER Filter
    Dateimuster. Standard: *.bak. Dateien mit anderer Endung (z. B. *.tmp aus einem noch laufenden Backup) werden
    nicht kopiert.

.PARAMETER AvailabilityGroupName
    Nur die Partner dieser Availability Group verwenden. Ohne Angabe: Partner aller AGs der Instanz.

.PARAMETER PartnerServer
    Partner-Rechnernamen fest vorgeben statt sie aus dem AG zu lesen. Fuer Umgebungen ohne AG oder zum Testen.

.PARAMETER EnableException
    Nach dem letzten Partner eine Ausnahme werfen, wenn ein Partner fehlgeschlagen ist (statt nur zu melden).

.EXAMPLE
    Copy-sqmBackupToAgPeer -SourcePath 'G:\Backup\Anonym'

    Kopiert alle *.bak aus G:\Backup\Anonym auf \\<Partner>\G$\Backup\Anonym, Partner werden aus dem AG ermittelt.

.EXAMPLE
    Copy-sqmBackupToAgPeer -SourcePath 'G:\Backup\Anonym' -Filter '*_anonym*.bak' -WhatIf

    Zeigt, wohin kopiert wuerde, ohne etwas zu kopieren.

.EXAMPLE
    # Zusaetzlicher Step im vorhandenen Backup-Job, arbeitet nur auf dem Primary
    New-sqmAgentCommandJob -SqlInstance 'SQL01' -JobName 'Anonym_Backup' -AppendStep -Command @{
        FunctionName = 'Copy-sqmBackupToAgPeer'
        Parameters   = @{ SourcePath = 'G:\Backup\Anonym'; Filter = '*_anonym*.bak' }
        PrimaryOnly  = $true
    }

.EXAMPLE
    # Nachhol-Job: Samstag und Sonntag frueh, falls die Kopie am Freitag durch Failover oder Patch ausgefallen ist
    New-sqmAgentCommandJob -SqlInstance 'SQL01' -JobName 'Anonym_Backup_Nachkopie' -ScheduleType Weekly -ScheduleDays 'Saturday','Sunday' -ScheduleTime '06:00' -Command @{
        FunctionName = 'Copy-sqmBackupToAgPeer'
        Parameters   = @{ SourcePath = 'G:\Backup\Anonym'; Filter = '*_anonym*.bak' }
        PrimaryOnly  = $true
    }

.OUTPUTS
    [PSCustomObject] je Partner: SqlInstance, PartnerServer, SourcePath, TargetPath, Status
    (Copied | UpToDate | WhatIf | Failed), ExitCode, Message.

.NOTES
    Uses Invoke-DbaQuery, robocopy.exe. Das Konto, unter dem die Funktion laeuft (bei Agent-Jobs das Dienstkonto bzw. der
    Proxy), braucht Schreibrechte auf der Admin-Freigabe des Partners. Der Partner-Rechnername wird aus
    replica_server_name genommen (Instanzteil entfernt).
#>
function Copy-sqmBackupToAgPeer
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $true)]
		[string]$SourcePath,

		[Parameter(Mandatory = $false)]
		[string[]]$Filter = '*.bak',

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[string[]]$PartnerServer,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName fuer '$SourcePath' (Instanz '$SqlInstance')." -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		try
		{
			if ($SourcePath -notmatch '^[A-Za-z]:\\')
			{
				throw "-SourcePath muss ein lokaler Pfad mit Laufwerksbuchstaben sein (z. B. 'G:\Backup\Anonym'), erhalten: '$SourcePath'."
			}
			if (-not (Test-Path -LiteralPath $SourcePath -PathType Container))
			{
				throw "Quellverzeichnis '$SourcePath' existiert nicht."
			}

			# ------------------------------------------------------------------
			# 1. Partner ermitteln: alle anderen Replikate der AG(s) aus den Katalogsichten.
			# ------------------------------------------------------------------
			if ($PartnerServer)
			{
				$peers = @($PartnerServer)
			}
			else
			{
				if (-not $script:dbatoolsAvailable) { throw "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools" }

				$connParams = @{ SqlInstance = $SqlInstance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				$query = "SELECT DISTINCT ar.replica_server_name AS ReplicaName FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ag.group_id = ar.group_id JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id WHERE ars.is_local = 0"
				if ($AvailabilityGroupName) { $query += " AND ag.name = N'" + ($AvailabilityGroupName -replace "'", "''") + "'" }

				$rows = @(Invoke-DbaQuery @connParams -Database master -Query $query -As PSObject -EnableException -ErrorAction Stop)
				$peers = @($rows | ForEach-Object { ([string]$_.ReplicaName -split '\\')[0] } | Select-Object -Unique)

				if ($peers.Count -eq 0)
				{
					throw "Keine Partner-Replikate gefunden (Instanz '$SqlInstance' ist in keiner AG oder hat keine weiteren Replikate). Mit -PartnerServer vorgeben."
				}
			}

			# Admin-Freigabe-Pfad: G:\Backup\Anonym -> G$\Backup\Anonym
			$sharePath = $SourcePath -replace '^([A-Za-z]):', '$1$'

			# ------------------------------------------------------------------
			# 2. Pro Partner kopieren. Ein Fehler bei einem Partner stoppt die anderen nicht.
			# ------------------------------------------------------------------
			foreach ($peer in $peers)
			{
				$target = "\\$peer\$sharePath"
				$entry = [PSCustomObject]@{
					SqlInstance   = $SqlInstance
					PartnerServer = $peer
					SourcePath    = $SourcePath
					TargetPath    = $target
					Status        = 'Unknown'
					ExitCode      = $null
					Message       = ''
				}

				if (-not $PSCmdlet.ShouldProcess($target, "Backups aus '$SourcePath' kopieren ($($Filter -join ', '))"))
				{
					$entry.Status = 'WhatIf'
					$results.Add($entry)
					continue
				}

				# /XO: nichts Neueres ueberschreiben, kein /MIR und kein /PURGE: nach einem Failover kann der Partner den
				# juengeren Stand haben. /NP /NDL: kurze Ausgabe fuer das Jobprotokoll.
				$roboArgs = @($SourcePath, $target) + $Filter + @('/XO', '/R:3', '/W:10', '/NP', '/NDL')
				$robo = Invoke-sqmRobocopy -Arguments $roboArgs
				$entry.ExitCode = $robo.ExitCode

				if ($robo.ExitCode -ge 8)
				{
					$entry.Status = 'Failed'
					$tail = (@($robo.Output | Where-Object { $_ -match '\S' }) | Select-Object -Last 3) -join ' | '
					$entry.Message = "robocopy Exitcode $($robo.ExitCode) nach '$target'. $tail"
					Invoke-sqmLogging -Message $entry.Message -FunctionName $functionName -Level 'ERROR'
				}
				else
				{
					# Bit 1 = mindestens eine Datei kopiert; sonst war alles schon da.
					$entry.Status = if ($robo.ExitCode -band 1) { 'Copied' } else { 'UpToDate' }
					$entry.Message = "robocopy Exitcode $($robo.ExitCode)."
					Invoke-sqmLogging -Message "Partner '$peer': $($entry.Status) ($target)." -FunctionName $functionName -Level 'INFO'
				}
				$results.Add($entry)
			}

			$failed = @($results | Where-Object { $_.Status -eq 'Failed' })
			if ($failed.Count -gt 0)
			{
				$summary = "Kopie fehlgeschlagen fuer: " + (($failed | ForEach-Object { $_.PartnerServer }) -join ', ')
				if ($EnableException) { throw $summary }
				Write-Error $summary
			}

			return $results
		}
		catch
		{
			$errMsg = "Fehler in ${functionName}: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $results
		}
	}
}
