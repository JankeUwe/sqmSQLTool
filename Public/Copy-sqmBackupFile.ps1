<#
.SYNOPSIS
    Kopiert die neueste Backup-Datei eines Ola-Backup-Verzeichnisses von einem der beiden AG-Knoten nach Ziel, optional unter anderem Namen.

.DESCRIPTION
    Fuer Faelle, in denen ein bestimmtes Backup (z. B. das letzte Full einer Datenbank) unter einem festen oder zusammengesetzten
    Namen an einen anderen Ort kopiert werden muss. Wann das passiert, steuert der SQL-Agent-Job (Zeitplan, Wochentag); die Funktion
    kennt kein Datum.

    Quelle: -SourcePath ist das Ola-Stammverzeichnis (z. B. F:\Daten\MSSQLSERVER\Backup\Usr-DB\SERVER$AG). Darunter erwartet die
    Funktion Ola-Struktur: <SourcePath>\<Datenbank>\FULL, \DIFF oder \LOG. Dort wird per Platzhalter gesucht, weil Ola Datum und Uhrzeit
    an den Namen haengt (SERVER$AG_db_FULL_20261103_042816.bak). Standardmuster: Full und Diff *.bak, Log *.trn; mit -SourceFile
    ueberschreibbar. Der Quellpfad ist auf beiden Knoten gleich: die Funktion sucht auf dem lokalen Knoten direkt und auf den anderen
    Replikaten (aus sys.availability_replicas, ohne AG nur lokal) ueber die Admin-Freigabe und nimmt die Datei mit dem neuesten
    Aenderungszeitpunkt, gleich auf welchem Knoten. Bei gestripten Backups ist das die neueste einzelne Datei.

    Ziel: -TargetPath, optional -TargetFile. Ohne -TargetFile bleibt der Quellname. In beiden duerfen {Database} und {Type} (FULL, DIFF,
    LOG) stehen, damit eine Regel mehrere Datenbanken bedienen kann. Mit mehreren Datenbanken oder Typen und festem -TargetFile ohne
    Platzhalter bricht die Funktion ab, weil sich die Dateien sonst gegenseitig ersetzen wuerden.

    Kopiert wird ueber eine temporaere Datei (<Ziel>.tmp) und anschliessendes Umbenennen, damit unter dem Endnamen nie eine halbe Datei
    liegt. Existiert das Ziel schon: gleiche Groesse und gleicher Aenderungszeitpunkt = UpToDate (nichts zu tun, ein zweiter Lauf
    ist harmlos); sonst Fehler 'Exists', ausser mit -Overwrite (dann wird ersetzt). Ist ein anderes Replikat nicht erreichbar, bricht die
    Funktion ab, weil dort die neuere Datei liegen koennte; ein fehlendes Verzeichnis auf einem erreichbaren Knoten zaehlt dagegen als
    "keine Datei dort".

.PARAMETER SqlInstance
    Instanz, aus der die Replikate ermittelt werden. Standard: lokaler Computername. Die Funktion laeuft lokal auf einem der Knoten.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung fuer die Replikatabfrage.

.PARAMETER SourcePath
    Ola-Stammverzeichnis (lokaler Pfad mit Laufwerksbuchstaben). In einem PowerShell-String wegen des $ im Namen in einfachen
    Anfuehrungszeichen angeben.

.PARAMETER Database
    Datenbank(en); der Name ist zugleich der Unterordner unter -SourcePath.

.PARAMETER BackupType
    Full (Standard), Diff und/oder Log. Pro Datenbank und Typ wird eine Datei kopiert. Full und Diff liegen in FULL bzw. DIFF, Log in LOG.

.PARAMETER SourceFile
    Platzhalter fuer den Dateinamen, ueberschreibt das Standardmuster (Full/Diff *.bak, Log *.trn), zum Beispiel '*_HST_FULL_*.bak'.

.PARAMETER TargetPath
    Zielverzeichnis (lokal oder UNC), wird angelegt. {Database} und {Type} werden ersetzt.

.PARAMETER TargetFile
    Zieldateiname. Ohne Angabe der Quellname. {Database} und {Type} werden ersetzt.

.PARAMETER Overwrite
    Ein vorhandenes, abweichendes Ziel ersetzen (ueber temporaere Datei und Umbenennen).

.PARAMETER AvailabilityGroupName
    Nur die Replikate dieser Availability Group verwenden. Ohne Angabe: alle AGs der Instanz.

.PARAMETER PartnerServer
    Andere Knoten fest vorgeben statt sie aus dem AG zu lesen.

.PARAMETER EnableException
    Fehler werfen (nach Verarbeitung aller Eintraege), im Agent-Job automatisch gesetzt.

.EXAMPLE
    Copy-sqmBackupFile -SourcePath 'F:\Daten\MSSQLSERVER\Backup\Usr-DB\SERVER1$AG1' -Database arenap01_HST -TargetPath '\\fs\archiv\arena' -WhatIf

    Zeigt, welche Datei kopiert wuerde (neuestes Full von beiden Knoten), ohne zu kopieren.

.EXAMPLE
    Copy-sqmBackupFile -SourcePath 'F:\Daten\MSSQLSERVER\Backup\Usr-DB\SERVER1$AG1' -Database arenap01_HST -TargetPath '\\fs\archiv\arena' -TargetFile '{Database}_Weekly.bak' -Overwrite

    Feste Zieldatei, die jede Woche ersetzt wird.

.EXAMPLE
    Copy-sqmBackupFile -SourcePath 'F:\Daten\MSSQLSERVER\Backup\Usr-DB\SERVER1$AG1' -Database DB1,DB2 -BackupType Full,Log -TargetPath '\\fs\archiv\{Database}'

    Full und Log je Datenbank, in einen Ordner pro Datenbank, unter dem Quellnamen.

.OUTPUTS
    [PSCustomObject] je Datenbank und Typ: Database, BackupType, SourceNode, SourceFile, SourceModified, SizeMB, Target, Status
    (Copied | UpToDate | WhatIf | NotFound | Exists | Failed), Message.

.NOTES
    Uses Invoke-DbaQuery. Braucht Leserechte auf den Admin-Freigaben der anderen Replikate und Schreibrechte am Ziel (bei Agent-Jobs
    das Dienstkonto oder der Proxy). Mit PrimaryOnly = $true ueber New-sqmAgentCommandJob einrichten.
#>
function Copy-sqmBackupFile
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

		[Parameter(Mandatory = $true)]
		[string[]]$Database,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Full', 'Diff', 'Log')]
		[string[]]$BackupType = 'Full',

		[Parameter(Mandatory = $false)]
		[string]$SourceFile,

		[Parameter(Mandatory = $true)]
		[string]$TargetPath,

		[Parameter(Mandatory = $false)]
		[string]$TargetFile,

		[Parameter(Mandatory = $false)]
		[switch]$Overwrite,

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
		Invoke-sqmLogging -Message "Starte $functionName (Quelle '$SourcePath', Datenbank(en) '$($Database -join ',')', Typ '$($BackupType -join ',')', Ziel '$TargetPath')." -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		try
		{
			if ($SourcePath -notmatch '^[A-Za-z]:\\')
			{
				throw "-SourcePath muss ein lokaler Pfad mit Laufwerksbuchstaben sein, erhalten: '$SourcePath'."
			}
			if ($SourceFile -and ($SourceFile -match '[\\/]'))
			{
				throw "-SourceFile darf keinen Pfad enthalten, nur einen Dateinamen-Platzhalter, erhalten: '$SourceFile'."
			}
			$combos = @($Database).Count * @($BackupType).Count
			if ($TargetFile -and $combos -gt 1 -and $TargetFile -notmatch '\{Database\}|\{Type\}')
			{
				throw "-TargetFile '$TargetFile' ohne {Database}/{Type} wuerde bei $combos Dateien jeweils die vorige ersetzen. Platzhalter verwenden oder einzeln aufrufen."
			}

			# ------------------------------------------------------------------
			# 1. Knoten: lokal plus die anderen Replikate (Admin-Freigabe), Quellpfad ist auf allen gleich.
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
			}

			$drive = $SourcePath.Substring(0, 1)
			$nodes = [System.Collections.Generic.List[PSCustomObject]]::new()
			$nodes.Add([PSCustomObject]@{ Name = $env:COMPUTERNAME; IsLocal = $true; Root = $SourcePath.TrimEnd('\') })
			foreach ($peer in $peers)
			{
				$nodes.Add([PSCustomObject]@{
					Name    = $peer
					IsLocal = $false
					Root    = "\\$peer\$drive`$" + $SourcePath.Substring(2).TrimEnd('\')
				})
			}

			# Ein nicht erreichbarer Knoten bricht ab: dort koennte die neuere Datei liegen.
			foreach ($node in $nodes | Where-Object { -not $_.IsLocal })
			{
				if (-not (Test-sqmPathReachable -Path "\\$($node.Name)\$drive`$"))
				{
					throw "Knoten '$($node.Name)' nicht erreichbar (\\$($node.Name)\$drive`$). Abbruch, damit nicht eine aeltere Datei gewaehlt wird, obwohl dort eine neuere liegt."
				}
			}

			# ------------------------------------------------------------------
			# 2. Je Datenbank und Typ die neueste Datei ueber alle Knoten waehlen und kopieren.
			# ------------------------------------------------------------------
			$typeDir = @{ Full = 'FULL'; Diff = 'DIFF'; Log = 'LOG' }
			$defaultPattern = @{ Full = '*.bak'; Diff = '*.bak'; Log = '*.trn' }

			foreach ($db in $Database)
			{
				foreach ($type in $BackupType)
				{
					$typeUpper = $typeDir[$type]
					$pattern = if ($SourceFile) { $SourceFile } else { $defaultPattern[$type] }
					$entry = [PSCustomObject]@{
						Database       = $db
						BackupType     = $type
						SourceNode     = $null
						SourceFile     = $null
						SourceModified = $null
						SizeMB         = $null
						Target         = $null
						Status         = 'Unknown'
						Message        = ''
					}

					$candidates = [System.Collections.Generic.List[object]]::new()
					foreach ($node in $nodes)
					{
						$dir = "$($node.Root)\$db\$typeUpper"
						foreach ($f in @(Get-sqmNodeFile -Directory $dir -Filter $pattern))
						{
							$candidates.Add([PSCustomObject]@{ Node = $node; File = $f })
						}
					}

					if ($candidates.Count -eq 0)
					{
						$entry.Status = 'NotFound'
						$entry.Message = "Keine Datei '$pattern' in '$SourcePath\$db\$typeUpper' auf $((@($nodes | ForEach-Object { $_.Name })) -join ', ')."
						Invoke-sqmLogging -Message "${db} ($type): $($entry.Message)" -FunctionName $functionName -Level 'ERROR'
						$results.Add($entry)
						continue
					}

					# Neueste Datei; bei gleichem Zeitpunkt gewinnt der lokale Knoten (kein Umweg ueber das Netz).
					$best = $candidates | Sort-Object -Property @{ Expression = { $_.File.LastWriteTimeUtc }; Descending = $true }, @{ Expression = { -not $_.Node.IsLocal } } | Select-Object -First 1
					$src = $best.File

					$resolvedTargetPath = ($TargetPath -replace '\{Database\}', $db -replace '\{Type\}', $typeUpper).TrimEnd('\')
					$targetName = if ($TargetFile) { $TargetFile -replace '\{Database\}', $db -replace '\{Type\}', $typeUpper } else { $src.Name }
					$target = "$resolvedTargetPath\$targetName"

					$entry.SourceNode = $best.Node.Name
					$entry.SourceFile = $src.FullName
					$entry.SourceModified = $src.LastWriteTime
					$entry.SizeMB = [math]::Round($src.Length / 1MB, 1)
					$entry.Target = $target

					# Ziel schon vorhanden?
					$exists = Test-Path -LiteralPath $target -PathType Leaf
					if ($exists)
					{
						$t = Get-Item -LiteralPath $target
						if ($t.Length -eq $src.Length -and $t.LastWriteTimeUtc -eq $src.LastWriteTimeUtc)
						{
							$entry.Status = 'UpToDate'
							$entry.Message = 'Ziel ist bereits identisch (Groesse und Zeitpunkt).'
							$results.Add($entry)
							continue
						}
						if (-not $Overwrite)
						{
							$entry.Status = 'Exists'
							$entry.Message = "Ziel '$target' existiert und weicht ab. Mit -Overwrite ersetzen."
							Invoke-sqmLogging -Message "${db} ($type): $($entry.Message)" -FunctionName $functionName -Level 'ERROR'
							$results.Add($entry)
							continue
						}
					}

					if (-not $PSCmdlet.ShouldProcess($target, "'$($src.FullName)' kopieren ($($entry.SizeMB) MB)$(if ($exists) { ', vorhandenes Ziel ersetzen' })"))
					{
						$entry.Status = 'WhatIf'
						$results.Add($entry)
						continue
					}

					$tmp = "$target.tmp"
					try
					{
						if (-not (Test-Path -LiteralPath $resolvedTargetPath -PathType Container))
						{
							New-Item -ItemType Directory -Path $resolvedTargetPath -Force -ErrorAction Stop | Out-Null
						}
						Copy-Item -LiteralPath $src.FullName -Destination $tmp -Force -ErrorAction Stop
						Move-Item -LiteralPath $tmp -Destination $target -Force -ErrorAction Stop
						$entry.Status = 'Copied'
						Invoke-sqmLogging -Message "${db} ($type): '$($src.FullName)' nach '$target' kopiert ($($entry.SizeMB) MB, Knoten $($best.Node.Name))." -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						$entry.Status = 'Failed'
						$entry.Message = "Kopieren nach '$target' fehlgeschlagen: $($_.Exception.Message)"
						Invoke-sqmLogging -Message "${db} ($type): $($entry.Message)" -FunctionName $functionName -Level 'ERROR'
						if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
					}
					$results.Add($entry)
				}
			}

			$bad = @($results | Where-Object { $_.Status -in 'NotFound', 'Exists', 'Failed' })
			if ($bad.Count -gt 0)
			{
				$summary = "Nicht erfolgreich: " + (($bad | ForEach-Object { "$($_.Database)/$($_.BackupType) ($($_.Status))" }) -join ', ')
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
