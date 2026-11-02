<#
.SYNOPSIS
    Ermittelt die aktuellste Restore-Kette (Full + Diff + Logs) ueber ALLE Replikate einer AG.

.DESCRIPTION
    Die Backup-Historie liegt in der msdb des Replikats, auf dem das Backup gelaufen ist. Bei einer
    AG mit Backup-Praeferenz "Secondary" liegen Fulls (COPY_ONLY) und Logs deshalb auf einem
    Secondary, und die msdb der Primary kennt sie nicht. Wer nur die Historie der Einstiegs-Instanz
    fragt, restauriert dann einen veralteten Stand oder findet gar nichts.

    Diese Funktion fragt die Historie jedes Replikats ab (inkl. COPY_ONLY), fuehrt die Zeilen
    zusammen und baut die Kette ueber die LSNs:

        1. neuestes Full (nach Startzeit, ueber alle Replikate)
        2. neuestes Diff, dessen DatabaseBackupLsn dem CheckpointLsn dieses Fulls entspricht
        3. alle Logs ab dem Ende von Full bzw. Diff, lueckenlos ueber FirstLsn/LastLsn verkettet;
           liegt dasselbe Log in mehreren Historien, gewinnt das der Arbeits-Instanz

    Pfade von anderen Replikaten sind lokale Pfade DIESES Replikats (G:\Backup\x.bak). Fuer die
    Arbeits-Instanz werden sie in den Admin-Share umgeschrieben (\\Replikat\G$\Backup\x.bak). UNC-
    Pfade bleiben unveraendert. Das Dienstkonto der Arbeits-Instanz braucht dafuer Leserechte auf
    dem Share bzw. dem Backup-Ordner des anderen Replikats.

    Ist die Datenbank in keiner AG, wird nur die Einstiegs-Instanz befragt - Verhalten wie bisher.
    Ein nicht erreichbares Replikat ist nur eine Warnung; ein Fehler bei der Einstiegs-Instanz wirft.

.PARAMETER SqlInstance
    Einstiegs-Instanz.

.PARAMETER Database
    Datenbank, deren Backups gesucht werden.

.PARAMETER SqlCredential
    Optionales PSCredential.

.OUTPUTS
    PSCustomObject mit Files (string[] in Restore-Reihenfolge), Items (Detailzeilen mit Typ, Replikat,
    Startzeit, Pfad), WorkInstance, Replicas.

.NOTES
    Private Hilfsfunktion fuer Invoke-sqmRestoreDatabase - nicht exportiert.
#>
function Get-sqmRestoreChainFromReplica
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name
	$shortName = { param ($n) ($n -split '[.\\]')[0] }
	$toDecimal = { param ($v) [decimal]::Parse(([string]$v), [System.Globalization.CultureInfo]::InvariantCulture) }

	# ---- 1. Replikate ermitteln ----
	$replicas = @($SqlInstance)
	$workInstance = $SqlInstance
	try
	{
		$membership = Get-sqmDatabaseAgMembership -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database
		if ($membership.IsAgDatabase)
		{
			$agReplicas = @(Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
					-AvailabilityGroup $membership.AvailabilityGroupName -EnableException -ErrorAction Stop |
				Select-Object -ExpandProperty Name)
			if ($agReplicas.Count -gt 0)
			{
				$replicas = $agReplicas
				if (-not [string]::IsNullOrWhiteSpace($membership.PrimaryReplica)) { $workInstance = $membership.PrimaryReplica }
				if ((& $shortName $workInstance) -ieq (& $shortName $SqlInstance)) { $workInstance = $SqlInstance }
				Invoke-sqmLogging -Message "'$Database' ist in AG '$($membership.AvailabilityGroupName)': Backup-Historie wird auf allen Replikaten gesucht ($($replicas -join ', ')), Arbeits-Instanz: '$workInstance'." -FunctionName $functionName -Level "INFO"
			}
		}
	}
	catch
	{
		Invoke-sqmLogging -Message "AG-Topologie fuer '$Database' nicht ermittelbar - Backup-Historie wird nur auf '$SqlInstance' gesucht: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
		$replicas = @($SqlInstance)
		$workInstance = $SqlInstance
	}

	# ---- 2. Historie jedes Replikats einsammeln ----
	$rows = [System.Collections.Generic.List[object]]::new()
	foreach ($replica in $replicas)
	{
		$isEntry = ((& $shortName $replica) -ieq (& $shortName $SqlInstance))
		$queryInstance = if ($isEntry) { $SqlInstance } else { $replica }
		try
		{
			$hist = @(Get-DbaDbBackupHistory -SqlInstance $queryInstance -SqlCredential $SqlCredential -Database $Database `
					-Last -IncludeCopyOnly -EnableException -ErrorAction Stop)
		}
		catch
		{
			if ($isEntry -and $replicas.Count -eq 1) { throw }
			Invoke-sqmLogging -Message "Backup-Historie von '$queryInstance' nicht lesbar (wird uebersprungen): $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
			continue
		}

		$isWork = ((& $shortName $replica) -ieq (& $shortName $workInstance))
		$hostName = & $shortName $replica
		foreach ($h in $hist)
		{
			# String-Operation statt Join-Path: Join-Path loest Laufwerksbuchstaben lokal auf.
			$resolvedPaths = @(@($h.Path) | ForEach-Object {
					if (-not $isWork -and ([string]$_) -match '^([A-Za-z]):\\(.*)$') { "\\$hostName\$($Matches[1])`$\$($Matches[2])" } else { [string]$_ }
				})
			$h | Add-Member -NotePropertyName ReplicaName -NotePropertyValue $replica -Force
			$h | Add-Member -NotePropertyName IsWorkInstance -NotePropertyValue $isWork -Force
			$h | Add-Member -NotePropertyName ResolvedPaths -NotePropertyValue $resolvedPaths -Force
			$rows.Add($h)
		}
	}

	if ($rows.Count -eq 0)
	{
		throw "Keine Backup-Historie fuer Datenbank '$Database' auf den Replikaten ($($replicas -join ', ')) gefunden (msdb.dbo.backupset) - -BackupFile oder -BackupFiles muss dann explizit angegeben werden."
	}

	# ---- 3. Kette bauen ----
	$fullRow = $rows | Where-Object { $_.Type -eq 'Full' } | Sort-Object Start, { & $toDecimal $_.CheckpointLsn } -Descending | Select-Object -First 1
	if (-not $fullRow)
	{
		throw "In der Backup-Historie von '$Database' (Replikate: $($replicas -join ', ')) gibt es kein Full-Backup - -BackupFile oder -BackupFiles muss explizit angegeben werden."
	}
	$chain = [System.Collections.Generic.List[object]]::new()
	$chain.Add($fullRow)
	$fullCheckpoint = & $toDecimal $fullRow.CheckpointLsn
	$baseLast = & $toDecimal $fullRow.LastLsn

	$diffRow = $rows | Where-Object { $_.Type -eq 'Differential' -and (& $toDecimal $_.DatabaseBackupLsn) -eq $fullCheckpoint } |
		Sort-Object Start -Descending | Select-Object -First 1
	if ($diffRow)
	{
		$chain.Add($diffRow)
		$baseLast = & $toDecimal $diffRow.LastLsn
	}

	# Dasselbe Log kann in mehreren Historien stehen: je FirstLsn nur eines, bevorzugt das der Arbeits-Instanz.
	$logRows = @($rows | Where-Object { $_.Type -eq 'Log' -and (& $toDecimal $_.LastLsn) -gt $baseLast } |
			Sort-Object @{ Expression = { & $toDecimal $_.FirstLsn } }, @{ Expression = { -[int]$_.IsWorkInstance } })
	$expectedLast = $baseLast
	$seenFirst = @{}
	foreach ($log in $logRows)
	{
		$first = & $toDecimal $log.FirstLsn
		$key = $first.ToString([System.Globalization.CultureInfo]::InvariantCulture)
		if ($seenFirst.ContainsKey($key)) { continue }
		if ($first -gt $expectedLast)
		{
			Invoke-sqmLogging -Message "Luecke in der Log-Kette von '$Database': naechstes Log beginnt bei LSN $first, erwartet <= $expectedLast (Log von '$($log.ReplicaName)', $($log.Start)). Restore reicht nur bis zur Luecke." -FunctionName $functionName -Level "WARNING"
			break
		}
		$seenFirst[$key] = $true
		$chain.Add($log)
		$expectedLast = & $toDecimal $log.LastLsn
	}

	$files = [System.Collections.Generic.List[string]]::new()
	$items = foreach ($c in $chain)
	{
		foreach ($p in @($c.ResolvedPaths)) { $files.Add($p) }
		[PSCustomObject]@{
			Type    = $c.Type
			Replica = $c.ReplicaName
			Start   = $c.Start
			Path    = (@($c.ResolvedPaths) -join ', ')
		}
	}

	foreach ($i in $items)
	{
		Invoke-sqmLogging -Message "Restore-Kette: $($i.Type) von '$($i.Replica)' ($($i.Start)): $($i.Path)" -FunctionName $functionName -Level "INFO"
	}
	if ($fullRow.PSObject.Properties['IsCopyOnly'] -and $fullRow.IsCopyOnly)
	{
		Invoke-sqmLogging -Message "Das verwendete Full-Backup ist COPY_ONLY (typisch fuer Backups auf einem Secondary)." -FunctionName $functionName -Level "INFO"
	}
	foreach ($i in ($items | Where-Object { $_.Path -like '\\*' -and $_.Replica -ne $workInstance }))
	{
		foreach ($p in ($i.Path -split ', '))
		{
			if (-not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue))
			{
				Invoke-sqmLogging -Message "Backup-Datei '$p' ist vom ausfuehrenden Konto aus nicht erreichbar. Das Dienstkonto der Arbeits-Instanz '$workInstance' braucht Leserechte darauf, sonst scheitert der Restore." -FunctionName $functionName -Level "WARNING"
			}
		}
	}

	return [PSCustomObject]@{
		Files        = $files.ToArray()
		Items        = @($items)
		WorkInstance = $workInstance
		Replicas     = $replicas
	}
}
