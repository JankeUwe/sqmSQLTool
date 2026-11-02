<#
.SYNOPSIS
    Gleicht die Groesse aller TempDB-Datendateien an (Standard: groesste vorhandene Datei).

.DESCRIPTION
    SQL Server verteilt Allokationen proportional zum freien Platz der Dateien (Proportional Fill). Sind die
    TempDB-Datendateien unterschiedlich gross, bekommt die groesste Datei den Grossteil der Last, und die
    zusaetzlichen Dateien bringen nicht die erwartete Entlastung der Allocation-Seiten. Diese Funktion liest die
    aktuelle Groesse aller Datendateien (tempdb.sys.database_files, also die laufende Groesse, nicht die
    Startgroesse) und vergroessert die kleineren auf die Zielgroesse.

    Zielgroesse ist standardmaessig die groesste vorhandene Datei: ALTER DATABASE ... MODIFY FILE kann eine Datei
    nur vergroessern, und so geht keine bereits eingewachsene Groesse verloren. Mit -TargetSizeMB laesst sich eine
    groessere Zielgroesse vorgeben. Die Aenderung gilt sofort (online) und wird als Startgroesse der Datei
    gespeichert, ist also nach einem Neustart noch da. Die Logdatei bleibt unberuehrt.

    Vor der ersten Aenderung wird geprueft, ob der freie Platz je Laufwerk fuer alle Vergroesserungen reicht und ob
    keine Datei ein MAXSIZE unter der Zielgroesse hat. Trifft eines zu, bricht die Funktion ab, ohne etwas zu
    aendern - sonst bliebe TempDB halb angeglichen.

    Mit -FileGrowthMB wird zusaetzlich die Autogrowth-Schrittweite aller Datendateien auf denselben festen Wert
    gesetzt. Unterschiedliche Schrittweiten lassen die Dateien beim naechsten Wachstum wieder auseinanderlaufen.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung.

.PARAMETER TargetSizeMB
    Zielgroesse je Datendatei in MB. Muss mindestens so gross sein wie die groesste vorhandene Datei, da eine Datei
    hier nicht verkleinert wird. Ohne Angabe: groesste vorhandene Datei.

.PARAMETER FileGrowthMB
    Optional: feste Autogrowth-Schrittweite in MB fuer alle Datendateien. Ohne Angabe bleibt die Schrittweite
    unveraendert (abweichende Werte werden als Hinweis gemeldet).

.PARAMETER EnableException
    Fehler werfen statt loggen und ein Fehlerobjekt zurueckgeben.

.EXAMPLE
    Set-sqmTempDbFileSize -SqlInstance "SQL01" -WhatIf

    Zeigt, welche Dateien auf welche Groesse gebracht wuerden.

.EXAMPLE
    Set-sqmTempDbFileSize -SqlInstance "SQL01"

    Bringt alle TempDB-Datendateien auf die Groesse der groessten.

.EXAMPLE
    Set-sqmTempDbFileSize -SqlInstance "SQL01" -TargetSizeMB 8192 -FileGrowthMB 512

.OUTPUTS
    [PSCustomObject] je Datendatei: SqlInstance, LogicalName, PhysicalName, OldSizeMB, NewSizeMB, OldGrowth,
    NewGrowth, Status (Changed | Unchanged | WhatIf | Failed), Message.

.NOTES
    Uses Invoke-DbaQuery. Braucht ALTER ANY DATABASE (sysadmin). Der Platzcheck nutzt sys.dm_os_volume_stats
    (VIEW SERVER STATE); fehlt das Recht, wird er mit Warnung uebersprungen.
    Verkleinern ist bewusst nicht Teil dieser Funktion: DBCC SHRINKFILE auf TempDB kann bei aktiver Last scheitern
    und verlangt oft einen Neustart. Ist die groesste Datei zu gross, die Zielgroesse nach einem Neustart mit
    Move-sqmDatabaseFile bzw. ALTER DATABASE setzen.
#>
function Set-sqmTempDbFileSize
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 1048576)]
		[int]$TargetSizeMB,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 65536)]
		[int]$FileGrowthMB,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
	{
		$SqlInstance = $env:COMPUTERNAME
	}

	$connParams = @{ SqlInstance = $SqlInstance; Database = 'tempdb' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	try
	{
		if (-not $script:dbatoolsAvailable) { throw "dbatools-Modul nicht gefunden." }
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'

		# ---- 1. Datendateien lesen (laufende Groesse, Typ ROWS) ----
		$fileQuery = @"
SELECT f.file_id, f.name, f.physical_name, f.size, f.max_size, f.growth, f.is_percent_growth
FROM tempdb.sys.database_files f
WHERE f.type = 0
ORDER BY f.file_id;
"@
		$files = @(Invoke-DbaQuery @connParams -Query $fileQuery -As PSObject -EnableException -ErrorAction Stop)
		if ($files.Count -eq 0) { throw "Keine TempDB-Datendateien gefunden." }

		# Seiten (8 KB) -> KB, ganzzahlig und exakt: gleiche KB-Zahl = gleiche Groesse.
		$sizeKb = @{}
		foreach ($f in $files) { $sizeKb[[int]$f.file_id] = [long]$f.size * 8 }
		$largestKb = ($sizeKb.Values | Measure-Object -Maximum).Maximum

		if ($PSBoundParameters.ContainsKey('TargetSizeMB'))
		{
			$targetKb = [long]$TargetSizeMB * 1024
			if ($targetKb -lt $largestKb)
			{
				throw "-TargetSizeMB ($TargetSizeMB MB) ist kleiner als die groesste Datei ($([math]::Round($largestKb / 1024, 2)) MB). TempDB-Dateien werden hier nicht verkleinert."
			}
		}
		else
		{
			$targetKb = $largestKb
		}
		$targetMbText = [math]::Round($targetKb / 1024, 2)

		# ---- 2. Vorabpruefungen: MAXSIZE und freier Platz je Laufwerk ----
		$plan = foreach ($f in $files)
		{
			$id = [int]$f.file_id
			$maxKb = if ([long]$f.max_size -eq -1) { [long]::MaxValue } else { [long]$f.max_size * 8 }
			[PSCustomObject]@{
				FileId     = $id
				Name       = [string]$f.name
				Physical   = [string]$f.physical_name
				OldKb      = $sizeKb[$id]
				MaxKb      = $maxKb
				NeedsGrow  = ($sizeKb[$id] -lt $targetKb)
				OldGrowth  = if ([int]$f.is_percent_growth -eq 1) { "$($f.growth) %" } elseif ([int]$f.growth -eq 0) { 'fest' } else { "$([math]::Round(([long]$f.growth * 8) / 1024, 2)) MB" }
				GrowthRaw  = [int]$f.growth
				IsPercent  = ([int]$f.is_percent_growth -eq 1)
			}
		}

		$capped = @($plan | Where-Object { $_.NeedsGrow -and $_.MaxKb -lt $targetKb })
		if ($capped.Count -gt 0)
		{
			throw "MAXSIZE zu klein fuer die Zielgroesse $targetMbText MB: $(($capped | ForEach-Object { $_.Name }) -join ', '). Erst MAXSIZE anheben, sonst bliebe TempDB halb angeglichen."
		}

		$volumes = @{}
		try
		{
			$volQuery = @"
SELECT f.file_id, v.volume_mount_point, v.available_bytes
FROM tempdb.sys.database_files f
CROSS APPLY sys.dm_os_volume_stats(DB_ID('tempdb'), f.file_id) v
WHERE f.type = 0;
"@
			foreach ($v in @(Invoke-DbaQuery @connParams -Query $volQuery -As PSObject -EnableException -ErrorAction Stop))
			{
				$volumes[[int]$v.file_id] = @{ Mount = [string]$v.volume_mount_point; Free = [long]$v.available_bytes }
			}
		}
		catch
		{
			Invoke-sqmLogging -Message "Freier Platz je Laufwerk nicht ermittelbar (VIEW SERVER STATE?), Platzcheck uebersprungen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
		}

		if ($volumes.Count -gt 0)
		{
			$needByVolume = @{}
			$freeByVolume = @{}
			foreach ($p in ($plan | Where-Object { $_.NeedsGrow }))
			{
				if (-not $volumes.ContainsKey($p.FileId)) { continue }
				$mount = $volumes[$p.FileId].Mount
				$freeByVolume[$mount] = $volumes[$p.FileId].Free
				$needByVolume[$mount] = [long]$needByVolume[$mount] + (($targetKb - $p.OldKb) * 1024)
			}
			$short = @($needByVolume.Keys | Where-Object { $needByVolume[$_] -gt $freeByVolume[$_] })
			if ($short.Count -gt 0)
			{
				$detail = ($short | ForEach-Object { "Volume '$_' braucht $([math]::Round($needByVolume[$_] / 1MB)) MB, frei $([math]::Round($freeByVolume[$_] / 1MB)) MB" }) -join '; '
				throw "Nicht genug freier Platz fuer $targetMbText MB je Datei: $detail."
			}
		}

		$growthKb = if ($PSBoundParameters.ContainsKey('FileGrowthMB')) { [long]$FileGrowthMB * 1024 } else { $null }
		if (-not $growthKb)
		{
			$distinctGrowth = @($plan | ForEach-Object { "$($_.OldGrowth)" } | Select-Object -Unique)
			if ($distinctGrowth.Count -gt 1)
			{
				Invoke-sqmLogging -Message "Die Autogrowth-Schrittweiten der Datendateien sind unterschiedlich ($($distinctGrowth -join ', ')): die Dateien laufen beim naechsten Wachstum wieder auseinander. -FileGrowthMB setzt einen einheitlichen Wert." -FunctionName $functionName -Level 'WARNING'
			}
		}

		# ---- 3. Anpassen ----
		foreach ($p in $plan)
		{
			$needsGrowth = $growthKb -and ($p.IsPercent -or ([long]$p.GrowthRaw * 8) -ne $growthKb)
			$result = [ordered]@{
				SqlInstance  = $SqlInstance
				LogicalName  = $p.Name
				PhysicalName = $p.Physical
				OldSizeMB    = [math]::Round($p.OldKb / 1024, 2)
				NewSizeMB    = if ($p.NeedsGrow) { $targetMbText } else { [math]::Round($p.OldKb / 1024, 2) }
				OldGrowth    = $p.OldGrowth
				NewGrowth    = if ($needsGrowth) { "$FileGrowthMB MB" } else { $p.OldGrowth }
				Status       = 'Unchanged'
				Message      = 'Bereits auf Zielgroesse.'
			}

			if (-not $p.NeedsGrow -and -not $needsGrowth)
			{
				[PSCustomObject]$result
				continue
			}

			$nameLit = $p.Name.Replace("'", "''")
			# MODIFY FILE akzeptiert nur EINE Eigenschaft je Anweisung (SQL Server lehnt SIZE und
			# FILEGROWTH zusammen ab), daher je Eigenschaft eine eigene ALTER DATABASE-Anweisung.
			$statements = @()
			$actionParts = @()
			if ($p.NeedsGrow)
			{
				$statements += "ALTER DATABASE tempdb MODIFY FILE (NAME = N'$nameLit', SIZE = $($targetKb)KB);"
				$actionParts += "Groesse $targetMbText MB"
			}
			if ($needsGrowth)
			{
				$statements += "ALTER DATABASE tempdb MODIFY FILE (NAME = N'$nameLit', FILEGROWTH = $($growthKb)KB);"
				$actionParts += "Autogrowth $FileGrowthMB MB"
			}
			$sql = $statements -join ' '
			$action = "Datei '$($p.Name)': " + ($actionParts -join ', ')

			if ($PSCmdlet.ShouldProcess("tempdb auf $SqlInstance", $action))
			{
				try
				{
					foreach ($stmt in $statements) { Invoke-DbaQuery @connParams -Query $stmt -EnableException -ErrorAction Stop | Out-Null }
					$result['Status'] = 'Changed'
					$result['Message'] = $action
					Invoke-sqmLogging -Message "TempDB: $action ($SqlInstance)" -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					$result['Status'] = 'Failed'
					$result['Message'] = $_.Exception.Message
					Invoke-sqmLogging -Message "TempDB: $action fehlgeschlagen ($SqlInstance): $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
					if ($EnableException) { throw }
				}
			}
			else
			{
				$result['Status'] = 'WhatIf'
				$result['Message'] = "Wuerde ausfuehren: $sql"
			}
			[PSCustomObject]$result
		}
	}
	catch
	{
		$errMsg = "Fehler in $functionName auf ${SqlInstance}: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
		if ($EnableException) { throw }
		Write-Error $errMsg
		return [PSCustomObject]@{
			SqlInstance  = $SqlInstance
			LogicalName  = $null
			PhysicalName = $null
			OldSizeMB    = $null
			NewSizeMB    = $null
			OldGrowth    = $null
			NewGrowth    = $null
			Status       = 'Failed'
			Message      = $errMsg
		}
	}
}
