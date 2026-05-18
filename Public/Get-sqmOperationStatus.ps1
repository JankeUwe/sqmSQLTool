<#
.SYNOPSIS
Zeigt den Fortschritt und die geschaetzte Restdauer fuer aktive Backup-, Restore- und AutoSeed-Operationen an.

.DESCRIPTION
Die Funktion ueberwacht aktive SQL Server-Operationen (Backup, Restore, AutoSeed) und berechnet
den Fortschritt sowie die geschaetzte verbleibende Zeit. Sie kombiniert Informationen aus:
- Backup- und Restore-Fortschritt: sys.dm_exec_requests
- AutoSeed-Fortschritt: sys.dm_hadr_physical_seeding_stats

Die Funktion kann auf einer bestimmten Instanz ausgefuehrt werden und zeigt standardmaessig
alle aktiven Operationen an. ueber Parameter kann nach Vorgangstyp (Backup, Restore, AutoSeed)
gefiltert werden.

Wenn kein SqlInstance-Parameter angegeben wird, wird standardmaessig der aktuelle
Computername ($env:COMPUTERNAME) verwendet. Diese Regel gilt fuer alle zukuenftigen
Versionen.

.PARAMETER SqlInstance
Die Ziel-SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
Alternative Anmeldeinformationen.

.PARAMETER OperationType
Filtert nach Vorgangstyp. Moegliche Werte: 'Backup', 'Restore', 'AutoSeed'.
Standardmaessig werden alle aktiven Operationen angezeigt.

.PARAMETER Continuous
Wenn gesetzt, wird die Ausgabe kontinuierlich aktualisiert (aehnlich wie 'watch').
Beenden mit Strg+C.

.PARAMETER RefreshSeconds
Intervall fuer die kontinuierliche Aktualisierung in Sekunden (Standard: 5). Nur in Verbindung mit -Continuous.

.PARAMETER EnableException
Schalter, um Ausnahmen durchzulassen (standardmaessig werden Fehler als Warnung protokolliert).

.EXAMPLE
# Alle aktiven Operationen auf der lokalen Instanz anzeigen
Get-sqmOperationStatus

.EXAMPLE
# Nur aktive AutoSeed-Vorgaenge auf einer entfernten Instanz
Get-sqmOperationStatus -SqlInstance "SQL01" -OperationType AutoSeed

.EXAMPLE
# Kontinuierliche Aktualisierung alle 10 Sekunden
Get-sqmOperationStatus -Continuous -RefreshSeconds 10

.NOTES
Erfordert dbatools und Invoke-sqmLogging.
Die Berechnung der geschaetzten Restdauer basiert auf dem bisherigen Fortschritt
und der vergangenen Zeit. Die Genauigkeit verbessert sich mit fortschreitender Operation.
#>
function Get-sqmOperationStatus
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Backup', 'Restore', 'AutoSeed')]
		[string]$OperationType,
		[Parameter(Mandatory = $false)]
		[switch]$Continuous,
		[Parameter(Mandatory = $false)]
		[int]$RefreshSeconds = 5,
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
			throw "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
		}
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		do
		{
			try
			{
				# 1. Backup/Restore Operationen ueber sys.dm_exec_requests abrufen
				$backupRestoreQuery = @"
SELECT 
    r.session_id,
    r.command,
    r.percent_complete,
    r.estimated_completion_time,
    r.start_time,
    DB_NAME(r.database_id) AS database_name,
    DATEADD(ms, r.estimated_completion_time, GETDATE()) AS expected_completion_time
FROM sys.dm_exec_requests r
WHERE r.command IN ('BACKUP DATABASE', 'RESTORE DATABASE', 'BACKUP LOG', 'RESTORE LOG')
    AND r.percent_complete > 0
"@
				
				$backupRestoreOps = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $backupRestoreQuery -Database master -ErrorAction Stop
				
				# 2. AutoSeed Operationen ueber sys.dm_hadr_physical_seeding_stats abrufen
				# Diese DMV existiert ab SQL Server 2016
				$autoSeedQuery = @"
SELECT 
    local_database_name AS database_name,
    role_desc,
    internal_state_desc,
    transfer_rate_bytes_per_second,
    transferred_size_bytes,
    total_size_bytes,
    start_time,
    estimated_completion_time_ms,
    CASE 
        WHEN total_size_bytes > 0 THEN (transferred_size_bytes * 100.0 / total_size_bytes)
        ELSE 0
    END AS percent_complete
FROM sys.dm_hadr_physical_seeding_stats
WHERE internal_state_desc IN ('RUNNING', 'IN_PROGRESS')
"@
				
				$autoSeedOps = @()
				try
				{
					$autoSeedOps = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $autoSeedQuery -Database master -ErrorAction Stop
				}
				catch
				{
					# DMV existiert moeglicherweise nicht (z.B. SQL Server 2014 oder aelter)
					if ($_.Exception.Message -match 'Invalid object name')
					{
						Write-Verbose "sys.dm_hadr_physical_seeding_stats nicht verfuegbar (SQL Server < 2016)"
					}
					else
					{
						throw
					}
				}
				
				# Ergebnisse kombinieren und filtern
				$allOps = @()
				
				# Backup/Restore Operationen verarbeiten
				foreach ($op in $backupRestoreOps)
				{
					$operationType = if ($op.command -match 'BACKUP') { 'Backup' }
					else { 'Restore' }
					if ($OperationType -and $OperationType -ne $operationType) { continue }
					
					$percentComplete = [math]::Round($op.percent_complete, 2)
					$remainingSeconds = [math]::Round($op.estimated_completion_time / 1000, 0)
					$remainingTimeFormatted = if ($remainingSeconds -gt 0)
					{
						Format-sqmTimeSpan -Seconds $remainingSeconds
					}
					else { "Unbekannt" }
					
					$allOps += [PSCustomObject]@{
						OperationType = $operationType
						DatabaseName  = $op.database_name
						SessionId	  = $op.session_id
						PercentComplete = $percentComplete
						RemainingTime = $remainingTimeFormatted
						RemainingSeconds = $remainingSeconds
						ExpectedCompletion = if ($op.expected_completion_time) { $op.expected_completion_time } else { $null }
						StartTime	  = $op.start_time
						TransferRate  = $null
						TransferredSize = $null
						TotalSize	  = $null
						Status	      = $op.command
					}
				}
				
				# AutoSeed Operationen verarbeiten
				foreach ($op in $autoSeedOps)
				{
					if ($OperationType -and $OperationType -ne 'AutoSeed') { continue }
					
					$percentComplete = [math]::Round($op.percent_complete, 2)
					$remainingSeconds = if ($op.estimated_completion_time_ms -gt 0)
					{
						[math]::Round($op.estimated_completion_time_ms / 1000, 0)
					}
					else { $null }
					$remainingTimeFormatted = if ($remainingSeconds -gt 0)
					{
						Format-sqmTimeSpan -Seconds $remainingSeconds
					}
					else { "Unbekannt" }
					
					$transferRateFormatted = if ($op.transfer_rate_bytes_per_second -gt 0)
					{
						Format-sqmFileSize -Bytes $op.transfer_rate_bytes_per_second
					}
					else { "N/A" }
					
					$allOps += [PSCustomObject]@{
						OperationType = 'AutoSeed'
						DatabaseName  = $op.database_name
						SessionId	  = $null
						PercentComplete = $percentComplete
						RemainingTime = $remainingTimeFormatted
						RemainingSeconds = $remainingSeconds
						ExpectedCompletion = $null
						StartTime	  = $op.start_time
						TransferRate  = $transferRateFormatted
						TransferredSize = Format-sqmFileSize -Bytes $op.transferred_size_bytes
						TotalSize	  = Format-sqmFileSize -Bytes $op.total_size_bytes
						Status	      = $op.internal_state_desc
					}
				}
				
				# Ausgabe
				if ($Continuous)
				{
					Clear-Host
					Write-Host "=== SQL Server Operation Status auf $SqlInstance ===" -ForegroundColor Cyan
					Write-Host "Aktualisierung alle $RefreshSeconds Sekunden (Strg+C zum Beenden)" -ForegroundColor Gray
					Write-Host ""
				}
				
				if ($allOps.Count -eq 0)
				{
					$msg = "Keine aktiven $($OperationType -replace 'AutoSeed', 'AutoSeed-')Operationen gefunden."
					Write-Host $msg -ForegroundColor Yellow
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
				}
				else
				{
					# Formatierte Ausgabe als Tabelle
					$displayProps = @(
						@{ Name = 'Type'; Expression = { $_.OperationType } },
						@{ Name = 'Database'; Expression = { $_.DatabaseName } },
						@{ Name = 'Status'; Expression = { $_.Status } },
						@{ Name = 'Progress'; Expression = { "$($_.PercentComplete)%" } },
						@{ Name = 'Remaining'; Expression = { $_.RemainingTime } }
					)
					
					# Zusaetzliche Spalten fuer AutoSeed
					if ($allOps | Where-Object { $_.OperationType -eq 'AutoSeed' })
					{
						$displayProps += @{ Name = 'Rate'; Expression = { $_.TransferRate } }
						$displayProps += @{ Name = 'Transferred'; Expression = { $_.TransferredSize } }
					}
					
					$allOps | Select-Object -Property ($displayProps | ForEach-Object { $_.Name }) | Format-Table -AutoSize
				}
				
				# Kontinuierliche Ausfuehrung
				if ($Continuous)
				{
					Start-Sleep -Seconds $RefreshSeconds
				}
			}
			catch
			{
				$errMsg = "Fehler beim Abrufen der Operationen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				Write-Error $errMsg
				if ($Continuous) { Start-Sleep -Seconds $RefreshSeconds }
			}
		}
		while ($Continuous)
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}