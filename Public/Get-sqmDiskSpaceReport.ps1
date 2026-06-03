<#
.SYNOPSIS
    Determines free disk space on all SQL-relevant volumes and estimates
    time to exhaustion based on growth data.

.DESCRIPTION
    Queries sys.dm_os_volume_stats for all database files and determines:
    - Free disk space per volume
    - Total size of database files on the volume
    - AutoGrowth volume over the last -HistoryDays days (from default trace)
    - Estimated days until exhaustion based on growth rate
    - Warning when free space falls below -WarnThresholdPct

    Results are saved as TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER WarnThresholdPct
    Warning when free space falls below this percentage. Default: 20.

.PARAMETER CriticalThresholdPct
    Critical when free space falls below this percentage. Default: 10.

.PARAMETER HistoryDays
    Time range for growth calculation in days. Default: 30.

.PARAMETER OutputPath
    Output directory for report files. Default: $env:ProgramData\sqmSQLTool\Logs

.PARAMETER ContinueOnError
    Continue on error for an instance (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before writing files.

.PARAMETER WhatIf
    Shows which files would be created without actually writing them.

.EXAMPLE
    Get-sqmDiskSpaceReport

.EXAMPLE
    Get-sqmDiskSpaceReport -SqlInstance "SQL01" -WarnThresholdPct 15 -OutputPath "D:\Reports"

.NOTES
    Author:       MSSQLTools
    Prerequisites: dbatools, Invoke-sqmLogging
    Default output path: $env:ProgramData\sqmSQLTool\Logs
    Growth calculation is based on the default trace (if enabled).
    If the trace is disabled, no growth value is determined.
#>
function Get-sqmDiskSpaceReport
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$WarnThresholdPct = 20,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 99)]
		[int]$CriticalThresholdPct = 10,
		[Parameter(Mandatory = $false)]
		[int]$HistoryDays = 30,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "$env:ProgramData\sqmSQLTool\Logs",
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
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade Volume-Statistiken ..." -FunctionName $functionName -Level "INFO"
				
				# 1. Volumedaten aus sys.dm_os_volume_stats
				$volumeQuery = @"
SELECT DISTINCT
    vs.volume_mount_point                              AS MountPoint,
    vs.logical_volume_name                             AS VolumeName,
    vs.total_bytes    / 1073741824.0                   AS TotalGB,
    vs.available_bytes / 1073741824.0                  AS FreeGB,
    (vs.total_bytes - vs.available_bytes) / 1073741824.0 AS UsedGB,
    CAST(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes,0) AS DECIMAL(5,1)) AS FreePct
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
ORDER BY vs.volume_mount_point;
"@
				$volRows = Invoke-DbaQuery @connParams -Query $volumeQuery -EnableException:$EnableException
				
				if (-not $volRows)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Volumedaten gefunden (keine Datenbankdateien?)." -FunctionName $functionName -Level "WARNING"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance = $instance
							Status	    = 'Warning'
							Message	    = 'Keine Volumedaten (keine Datenbankdateien oder keine Berechtigung fuer dm_os_volume_stats)'
							DetailRows  = @()
							TxtFile	    = $null
							CsvFile	    = $null
						})
					continue
				}
				
				# 2. AutoGrowth-Wachstum aus Default Trace (optional)
				$growthLookup = @{ }
				try
				{
					$growthQuery = @"
DECLARE @tracefile NVARCHAR(500);
SELECT @tracefile = REVERSE(SUBSTRING(REVERSE(path),CHARINDEX('\',REVERSE(path)),500)) + N'log.trc'
FROM sys.traces WHERE is_default = 1;

IF @tracefile IS NOT NULL
BEGIN
    SELECT
        LEFT(FileName, LEN(FileName) - CHARINDEX('\', REVERSE(FileName))) AS FolderPath,
        SUM(CAST(IntegerData AS BIGINT) * 8 * 1024)                       AS TotalGrowthBytes
    FROM sys.fn_trace_gettable(@tracefile, DEFAULT)
    WHERE EventClass IN (92,93)
      AND StartTime >= DATEADD(DAY, -$HistoryDays, GETDATE())
    GROUP BY LEFT(FileName, LEN(FileName) - CHARINDEX('\', REVERSE(FileName)));
END
"@
					$growthRows = Invoke-DbaQuery @connParams -Query $growthQuery -EnableException:$false -ErrorAction SilentlyContinue
					foreach ($r in $growthRows)
					{
						$drive = if ($r.FolderPath -match '^([A-Za-z]:)') { $Matches[1].ToUpper() + '\' }
						else { $r.FolderPath }
						$growthLookup[$drive] = [math]::Round($r.TotalGrowthBytes / 1073741824.0, 2)
					}
					if ($growthRows.Count -eq 0)
					{
						Invoke-sqmLogging -Message "[$instance] Keine AutoGrowth-Daten im Default Trace gefunden (Trace evtl. deaktiviert)." -FunctionName $functionName -Level "VERBOSE"
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "[$instance] Fehler beim Lesen des Default Trace: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
				
				# 3. Detailzeilen aufbereiten
				foreach ($vol in $volRows)
				{
					$mount = $vol.MountPoint
					$totalGB = [math]::Round($vol.TotalGB, 1)
					$freeGB = [math]::Round($vol.FreeGB, 1)
					$usedGB = [math]::Round($vol.UsedGB, 1)
					$freePct = [math]::Round($vol.FreePct, 1)
					
					$growthGB = $growthLookup[$mount]
					$growthPerDay = if ($growthGB -and $HistoryDays -gt 0) { [math]::Round($growthGB / $HistoryDays, 3) }
					else { 0 }
					$daysUntilFull = if ($growthPerDay -gt 0) { [math]::Round($freeGB / $growthPerDay, 0) }
					else { $null }
					
					$status = if ($freePct -le $CriticalThresholdPct) { 'Critical' }
					elseif ($freePct -le $WarnThresholdPct) { 'Warning' }
					elseif ($daysUntilFull -and $daysUntilFull -le 30) { 'Warning' }
					else { 'OK' }
					
					$detailRows.Add([PSCustomObject]@{
							SqlInstance = $instance
							MountPoint  = $mount
							VolumeName  = $vol.VolumeName
							TotalGB	    = $totalGB
							UsedGB	    = $usedGB
							FreeGB	    = $freeGB
							FreePct	    = $freePct
							GrowthLastPeriodGB = if ($growthGB) { $growthGB } else { $null }
							GrowthPerDayGB = if ($growthPerDay -gt 0) { $growthPerDay } else { $null }
							DaysUntilFull = $daysUntilFull
							HistoryDays = $HistoryDays
							Status	    = $status
							Message	    = switch ($status)
							{
								'Critical' { "Kritisch: nur $freePct% frei ($freeGB GB)!" }
								'Warning'  {
									if ($daysUntilFull -le 30 -and $daysUntilFull)
									{
										"Warnung: voll in ca. $daysUntilFull Tagen."
									}
									else { "Warnung: nur $freePct% frei ($freeGB GB)." }
								}
								default    { "OK: $freePct% frei ($freeGB GB)." }
							}
						})
				}
				
				# 4. Berichtsdateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "DiskSpaceReport_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "DiskSpaceReport_${safeInst}_${datestamp}.csv"
				
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Disk-Space-Bericht in $OutputPath"))
				{
					# Verzeichnis anlegen
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					# TXT-Bericht
					$cntCrit = ($detailRows | Where-Object Status -eq 'Critical').Count
					$cntWarn = ($detailRows | Where-Object Status -eq 'Warning').Count
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# MSSQLTools - Disk Space Report")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# Warn: <${WarnThresholdPct}% | Critical: <${CriticalThresholdPct}% | Wachstum: letzte $HistoryDays Tage")
					$lines.Add("# Critical: $cntCrit | Warning: $cntWarn")
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-6} {1,-20} {2,-8} {3,-8} {4,-8} {5,-7} {6,-10} {7,-8} {8}" -f
							'Status', 'Laufwerk', 'TotalGB', 'UsedGB', 'FreeGB', 'Free%', 'GrowthGB', 'DaysFull', 'Info'))
					$lines.Add(("-" * 105))
					foreach ($e in ($detailRows | Sort-Object Status, MountPoint))
					{
						$growthDisplay = if ($e.GrowthLastPeriodGB) { $e.GrowthLastPeriodGB }
						else { 'n/a' }
						$daysDisplay = if ($e.DaysUntilFull) { $e.DaysUntilFull }
						else { '?' }
						$lines.Add(("{0,-6} {1,-20} {2,-8} {3,-8} {4,-8} {5,-7} {6,-10} {7,-8} {8}" -f
								$e.Status, $e.MountPoint, $e.TotalGB, $e.UsedGB, $e.FreeGB,
								"$($e.FreePct)%", $growthDisplay, $daysDisplay, $e.Message))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					# CSV-Datei
					$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# Oeffne TXT-Datei wenn nicht -NoOpen
					if (-not $NoOpen -and $txtFile)
					{
						Start-Process $txtFile
					}

					Invoke-sqmLogging -Message "[$instance] Disk-Space-Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
				}
				
				# Ergebnisobjekt fuer diese Instanz
				$result = [PSCustomObject]@{
					SqlInstance					     = $instance
					Timestamp					     = $timestamp
					DetailRows					     = $detailRows
					TxtFile						     = $txtFile
					CsvFile						     = $csvFile
					Status						     = if ($cntCrit -gt 0) { 'Critical' } elseif ($cntWarn -gt 0) { 'Warning' } else { 'OK' }
				}
				$allInstanceResults.Add($result)
				
				if ($cntCrit -gt 0)
				{
					Invoke-sqmLogging -Message "[$instance] $cntCrit Critical Disk-Space-Issue(s) - Bericht: $txtFile" -FunctionName $functionName -Level "WARNING"
				}
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status	    = 'Error'
						Message	    = $errMsg
						DetailRows  = $null
						TxtFile	    = $null
						CsvFile	    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanzen verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}