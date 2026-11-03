<#
.SYNOPSIS
    Legt fehlende TempDB-Datendateien an, bis die gewuenschte Anzahl erreicht ist.

.DESCRIPTION
    Pendant zu Test-sqmTempDbFileCount: der Test meldet, dass die Anzahl der TempDB-Datendateien nicht zur Zahl der
    logischen Kerne passt, diese Funktion behebt es. Ohne -FileCount gilt dieselbe Empfehlung wie im Test:
    min(logische Kerne der Zielinstanz, MaxFiles), MaxFiles 8 bzw. Konfiguration CheckTempDbMaxFiles.

    Neue Dateien entstehen online per ALTER DATABASE tempdb ADD FILE, ein Neustart ist nicht noetig. Sie bekommen die
    Groesse der groessten vorhandenen Datendatei (Proportional Fill verteilt sonst ungleich), dieselbe feste
    Autogrowth-Schrittweite wie die erste Datei (bei Prozentwachstum 64 MB bzw. -FileGrowthMB) und liegen im Ordner
    der ersten Datendatei, oder in -Path. Mit -EqualizeSize werden danach auch die kleineren vorhandenen Dateien
    ueber Set-sqmTempDbFileSize auf diese Groesse gebracht.

    Vor der ersten Aenderung wird geprueft, ob der freie Platz auf dem Ziellaufwerk fuer alle neuen Dateien reicht
    und ob Dateiname bzw. Zielpfad schon belegt sind. Trifft eines zu, bricht die Funktion ab, ohne etwas zu aendern.

    Entfernen von Dateien ist bewusst nicht enthalten: eine benutzte TempDB-Datei laesst sich online nicht
    zuverlaessig leeren (DBCC SHRINKFILE ... EMPTYFILE scheitert bei aktiver Last, oft hilft nur ein Neustart). Ist die
    Anzahl bereits hoeher als gewuenscht, meldet die Funktion Skipped und aendert nichts.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung.

.PARAMETER FileCount
    Gewuenschte Anzahl Datendateien. Ohne Angabe: Empfehlung aus Kernen und MaxFiles (siehe oben).

.PARAMETER MaxFiles
    Obergrenze fuer die automatische Empfehlung. Standard 8 bzw. Konfiguration CheckTempDbMaxFiles. Wirkt nicht auf
    ein explizit angegebenes -FileCount.

.PARAMETER Path
    Ordner fuer die neuen Dateien (Pfad auf dem SQL Server). Standard: Ordner der ersten Datendatei.

.PARAMETER FileGrowthMB
    Autogrowth-Schrittweite der neuen Dateien in MB. Standard: wie die erste Datei, bei Prozentwachstum 64 MB.

.PARAMETER EqualizeSize
    Bringt nach dem Anlegen alle Datendateien ueber Set-sqmTempDbFileSize auf dieselbe Groesse.

.PARAMETER EnableException
    Fehler werfen statt loggen und ein Fehlerobjekt zurueckgeben.

.EXAMPLE
    Set-sqmTempDbFileCount -SqlInstance "SQL01" -WhatIf

    Zeigt, welche Dateien angelegt wuerden.

.EXAMPLE
    Set-sqmTempDbFileCount -SqlInstance "SQL01" -EqualizeSize

    Legt fehlende Dateien an und gleicht alle Dateien in der Groesse an.

.EXAMPLE
    Set-sqmTempDbFileCount -SqlInstance "SQL01" -FileCount 8 -Path "T:\TempDB"

.OUTPUTS
    [PSCustomObject] je neuer Datei: SqlInstance, LogicalName, PhysicalName, SizeMB, GrowthMB, OldFileCount,
    NewFileCount, Status (Created | WhatIf | Skipped | Failed), Message. Ist nichts zu tun, genau ein Objekt mit
    Status Skipped.

.NOTES
    Uses Invoke-DbaQuery. Braucht ALTER ANY DATABASE (sysadmin). Der Platzcheck nutzt sys.dm_os_volume_stats
    (VIEW SERVER STATE); fehlt das Recht, wird er mit Warnung uebersprungen. Der Zielordner muss auf dem SQL Server
    existieren und fuer das Dienstkonto beschreibbar sein.
#>
function Set-sqmTempDbFileCount
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 64)]
		[int]$FileCount,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 64)]
		[int]$MaxFiles = 8,
		[Parameter(Mandatory = $false)]
		[string]$Path,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 65536)]
		[int]$FileGrowthMB,
		[Parameter(Mandatory = $false)]
		[switch]$EqualizeSize,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
	{
		$SqlInstance = $env:COMPUTERNAME
	}

	if (-not $PSBoundParameters.ContainsKey('MaxFiles'))
	{
		$cfgVal = Get-sqmConfig -Key 'CheckTempDbMaxFiles'
		if ($null -ne $cfgVal) { $MaxFiles = [int]$cfgVal }
	}

	$connParams = @{ SqlInstance = $SqlInstance; Database = 'tempdb' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	function _Result($Name, $Physical, $SizeMB, $GrowthMB, $Old, $New, $Status, $Message)
	{
		[PSCustomObject][ordered]@{
			SqlInstance  = $SqlInstance
			LogicalName  = $Name
			PhysicalName = $Physical
			SizeMB       = $SizeMB
			GrowthMB     = $GrowthMB
			OldFileCount = $Old
			NewFileCount = $New
			Status       = $Status
			Message      = $Message
		}
	}

	try
	{
		if (-not $script:dbatoolsAvailable) { throw "dbatools-Modul nicht gefunden." }
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'

		# ---- 1. Datendateien und Kerne der Zielinstanz lesen ----
		$fileQuery = @"
SELECT f.file_id, f.name, f.physical_name, f.size, f.growth, f.is_percent_growth
FROM tempdb.sys.database_files f
WHERE f.type = 0
ORDER BY f.file_id;
"@
		$files = @(Invoke-DbaQuery @connParams -Query $fileQuery -As PSObject -EnableException -ErrorAction Stop)
		if ($files.Count -eq 0) { throw "Keine TempDB-Datendateien gefunden." }
		$oldCount = $files.Count

		if ($PSBoundParameters.ContainsKey('FileCount'))
		{
			$targetCount = $FileCount
		}
		else
		{
			$cpu = @(Invoke-DbaQuery @connParams -Query 'SELECT cpu_count AS Cpu FROM sys.dm_os_sys_info;' -As PSObject -EnableException -ErrorAction Stop)
			$targetCount = [Math]::Min([int]$cpu[0].Cpu, $MaxFiles)
		}

		if ($oldCount -ge $targetCount)
		{
			$msg = if ($oldCount -eq $targetCount) { "TempDB hat bereits $oldCount Datendateien, nichts zu tun." }
			else { "TempDB hat $oldCount Datendateien, gewuenscht $targetCount. Entfernen wird nicht unterstuetzt (eine benutzte Datei laesst sich online nicht zuverlaessig leeren)." }
			Invoke-sqmLogging -Message "$msg ($SqlInstance)" -FunctionName $functionName -Level 'INFO'
			return (_Result $null $null $null $null $oldCount $oldCount 'Skipped' $msg)
		}

		# ---- 2. Parameter der neuen Dateien bestimmen ----
		$largestPages = ($files | ForEach-Object { [long]$_.size } | Measure-Object -Maximum).Maximum
		$sizeKb = $largestPages * 8
		$sizeMb = [math]::Round($sizeKb / 1024, 2)

		$first = $files[0]
		if ($PSBoundParameters.ContainsKey('FileGrowthMB')) { $growthKb = [long]$FileGrowthMB * 1024 }
		elseif ([int]$first.is_percent_growth -eq 1 -or [long]$first.growth -eq 0) { $growthKb = 64 * 1024 }
		else { $growthKb = [long]$first.growth * 8 }
		$growthMb = [math]::Round($growthKb / 1024, 2)

		$firstPhysical = [string]$first.physical_name
		$targetDir = if ($Path) { $Path.TrimEnd('\', '/') } else { $firstPhysical.Substring(0, [math]::Max($firstPhysical.LastIndexOfAny(@('\', '/')), 0)) }
		if ([string]::IsNullOrWhiteSpace($targetDir)) { throw "Zielordner nicht ermittelbar, bitte -Path angeben." }
		$sep = if ($targetDir -match '/') { '/' } else { '\' }

		$usedNames = @($files | ForEach-Object { ([string]$_.name).ToLowerInvariant() })
		$usedPaths = @($files | ForEach-Object { ([string]$_.physical_name).ToLowerInvariant() })
		$newFiles = [System.Collections.Generic.List[object]]::new()
		$n = 1
		while ($newFiles.Count -lt ($targetCount - $oldCount))
		{
			$n++
			# Namensschema wie bei der SQL-Server-Installation: temp2, temp3 ... / tempdb_mssql_2.ndf ...
			$name = "temp$n"
			$phys = "$targetDir${sep}tempdb_mssql_$n.ndf"
			if ($usedNames -contains $name.ToLowerInvariant() -or $usedPaths -contains $phys.ToLowerInvariant()) { continue }
			$newFiles.Add([PSCustomObject]@{ Name = $name; Physical = $phys })
		}

		# ---- 3. Vorabpruefung: freier Platz auf dem Ziellaufwerk ----
		try
		{
			$volQuery = @"
SELECT DISTINCT v.volume_mount_point, v.available_bytes
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) v;
"@
			$vols = @(Invoke-DbaQuery @connParams -Query $volQuery -As PSObject -EnableException -ErrorAction Stop)
			$best = $vols | Where-Object { $targetDir.ToLowerInvariant().StartsWith(([string]$_.volume_mount_point).ToLowerInvariant()) } |
				Sort-Object { ([string]$_.volume_mount_point).Length } -Descending | Select-Object -First 1
			if ($best)
			{
				$needBytes = [long]$newFiles.Count * $sizeKb * 1024
				if ($needBytes -gt [long]$best.available_bytes)
				{
					throw "Nicht genug freier Platz auf '$($best.volume_mount_point)': $($newFiles.Count) neue Dateien zu je $sizeMb MB brauchen $([math]::Round($needBytes / 1MB)) MB, frei $([math]::Round([long]$best.available_bytes / 1MB)) MB."
				}
			}
			else
			{
				Invoke-sqmLogging -Message "Laufwerk fuer '$targetDir' nicht in den Volume-Infos gefunden, Platzcheck uebersprungen." -FunctionName $functionName -Level 'WARNING'
			}
		}
		catch
		{
			if ($_.Exception.Message -like 'Nicht genug freier Platz*') { throw }
			Invoke-sqmLogging -Message "Freier Platz nicht ermittelbar (VIEW SERVER STATE?), Platzcheck uebersprungen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
		}

		# ---- 4. Anlegen ----
		$created = 0
		foreach ($nf in $newFiles)
		{
			$nameLit = $nf.Name.Replace("'", "''")
			$physLit = $nf.Physical.Replace("'", "''")
			$sql = "ALTER DATABASE tempdb ADD FILE (NAME = N'$nameLit', FILENAME = N'$physLit', SIZE = $($sizeKb)KB, FILEGROWTH = $($growthKb)KB);"
			$action = "Datei '$($nf.Name)' ($sizeMb MB, Autogrowth $growthMb MB) in $targetDir"

			if ($PSCmdlet.ShouldProcess("tempdb auf $SqlInstance", $action))
			{
				try
				{
					Invoke-DbaQuery @connParams -Query $sql -EnableException -ErrorAction Stop | Out-Null
					$created++
					Invoke-sqmLogging -Message "TempDB: $action angelegt ($SqlInstance)" -FunctionName $functionName -Level 'INFO'
					_Result $nf.Name $nf.Physical $sizeMb $growthMb $oldCount ($oldCount + $created) 'Created' "Angelegt: $action"
				}
				catch
				{
					$err = $_.Exception.GetBaseException().Message
					Invoke-sqmLogging -Message "TempDB: $action fehlgeschlagen ($SqlInstance): $err" -FunctionName $functionName -Level 'ERROR'
					if ($EnableException) { throw }
					_Result $nf.Name $nf.Physical $sizeMb $growthMb $oldCount ($oldCount + $created) 'Failed' $err
					break
				}
			}
			else
			{
				_Result $nf.Name $nf.Physical $sizeMb $growthMb $oldCount $oldCount 'WhatIf' "Wuerde ausfuehren: $sql"
			}
		}

		# ---- 5. Optional: vorhandene kleinere Dateien angleichen ----
		if ($EqualizeSize -and $created -gt 0)
		{
			# Ohne -TargetSizeMB gilt die groesste Datei, also genau die Groesse der neuen Dateien.
			$eq = @{ SqlInstance = $SqlInstance; EnableException = $EnableException.IsPresent }
			if ($SqlCredential) { $eq['SqlCredential'] = $SqlCredential }
			$eqResult = @(Set-sqmTempDbFileSize @eq)
			foreach ($f in ($eqResult | Where-Object { $_.Status -eq 'Failed' }))
			{
				Write-Warning "Angleichen der Dateigroesse fehlgeschlagen ($($f.LogicalName)): $($f.Message)"
			}
		}
	}
	catch
	{
		$errMsg = "Fehler in $functionName auf ${SqlInstance}: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
		if ($EnableException) { throw }
		Write-Error $errMsg
		return (_Result $null $null $null $null $null $null 'Failed' $errMsg)
	}
}
