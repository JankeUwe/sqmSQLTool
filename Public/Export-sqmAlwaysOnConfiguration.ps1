<#
.SYNOPSIS
	Exports the complete AlwaysOn AG configuration for one or more SQL Server instances.

.DESCRIPTION
	Reads all static AG configuration settings (not runtime status) and exports them as TXT, CSV, and optional JSON.
	For each AG on the specified instance:
	- AG name, backup preference, failover condition, health check timeout
	- All replicas with ReadableSecondary setting (with FI-TS standard warning)
	- Listener configuration (name, port, IPs)
	- Member databases

	CRITICAL FI-TS CHECK: ReadableSecondary must be NO (not NONE, READ_ONLY, or ALL).
	Any other value triggers a warning unless -NoWarning is specified.

	Results are saved as TXT report and CSV file in the specified directory.
	The function also returns an object with the detail data and file paths.

.PARAMETER SqlInstance
	SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
	Optional PSCredential for the connection.

.PARAMETER OutputPath
	Output directory for report files. Default: $env:ProgramData\sqmSQLTool\Logs

.PARAMETER NoWarning
	Suppress FI-TS ReadableSecondary warnings (Write-Warning is skipped).
	Note: Status will still be Warning if ReadableSecondary != NO.

.PARAMETER NoOpen
	Do not automatically open the TXT report after creation.

.PARAMETER EnableException
	Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
	Request confirmation before writing files.

.PARAMETER WhatIf
	Shows which files would be created without actually writing them.

.EXAMPLE
	Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01"
	# Exports all AGs from SQL01, warns if ReadableSecondary != NO

.EXAMPLE
	Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01" -NoWarning
	# Exports all AGs, suppresses Write-Warning but Status still shows if issues

.EXAMPLE
	Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01" -OutputPath "D:\Reports" -NoOpen
	# Exports to D:\Reports, does not auto-open TXT file

.NOTES
	Author:       sqmSQLTool
	Prerequisites: dbatools, Invoke-sqmLogging
	Default output path: $env:ProgramData\sqmSQLTool\Logs
	FI-TS Standard: ReadableSecondary MUST be NO on all replicas.
#>
function Export-sqmAlwaysOnConfiguration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "$env:ProgramData\sqmSQLTool\Logs",

		[Parameter(Mandatory = $false)]
		[switch]$NoWarning,

		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
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

			$configRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			$dbsByAg = @{}

			try
			{
				Invoke-sqmLogging -Message "[$instance] Lade AlwaysOn AG-Konfiguration ..." -FunctionName $functionName -Level "INFO"

				# 1. Verfuegbarkeitsgruppen abrufen
				$ags = Get-DbaAvailabilityGroup @connParams -ErrorAction Stop
				if (-not $ags)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Verfuegbarkeitsgruppen vorhanden." -FunctionName $functionName -Level "INFO"
					$allInstanceResults.Add([PSCustomObject]@{
							SqlInstance               = $instance
							AgCount                  = 0
							ReplicaCount             = 0
							ReadableSecondaryCount   = 0
							ConfigRows               = @()
							TxtFile                  = $null
							CsvFile                  = $null
							Status                   = "OK"
						})
					continue
				}

				# 2. Haupt-Config-Query: AG + Replicas + Listener + IPs
				$configQuery = @"
SELECT
    ag.name                                      AS AgName,
    ag.automated_backup_preference_desc          AS BackupPreference,
    ag.failure_condition_level                   AS FailureConditionLevel,
    ag.health_check_timeout                      AS HealthCheckTimeoutMs,
    ISNULL(ag.db_failover, 0)                    AS DbFailoverEnabled,
    ISNULL(ag.is_distributed, 0)                 AS IsDistributed,
    ar.replica_server_name                       AS ReplicaName,
    ar.availability_mode_desc                    AS AvailabilityMode,
    ar.failover_mode_desc                        AS FailoverMode,
    ar.secondary_role_allow_connections_desc     AS ReadableSecondary,
    ar.primary_role_allow_connections_desc       AS PrimaryConnections,
    ar.backup_priority                           AS BackupPriority,
    ar.session_timeout                           AS SessionTimeoutSec,
    ISNULL(al.dns_name, '')                      AS ListenerName,
    ISNULL(al.port, 0)                           AS ListenerPort,
    ISNULL(lip.ip_address, '')                   AS ListenerIP,
    ISNULL(lip.ip_subnet_mask, '')               AS ListenerSubnet
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.availability_group_listeners al ON al.group_id = ag.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses lip ON lip.listener_id = al.listener_id
ORDER BY ag.name, ar.replica_server_name
"@
				$configRows = @(Invoke-DbaQuery @connParams -Query $configQuery -ErrorAction Stop)

				# 3. Datenbanken pro AG Query
				$dbQuery = @"
SELECT
    ag.name           AS AgName,
    adc.database_name AS DatabaseName
FROM sys.availability_groups ag
JOIN sys.availability_databases_cluster adc ON adc.group_id = ag.group_id
ORDER BY ag.name, adc.database_name
"@
				$dbRows = @(Invoke-DbaQuery @connParams -Query $dbQuery -ErrorAction Stop)

				# Organiere Datenbanken nach AG
				foreach ($db in $dbRows)
				{
					$agName = $db.AgName
					if (-not $dbsByAg[$agName])
					{
						$dbsByAg[$agName] = [System.Collections.Generic.List[string]]::new()
					}
					$null = $dbsByAg[$agName].Add($db.DatabaseName)
				}

				# FI-TS Check: ReadableSecondary != NO
				$readableSecondaryIssues = $configRows | Where-Object {
					$_.ReadableSecondary -ne "NO" -and $_.ReadableSecondary -ne "NONE" -and -not [string]::IsNullOrWhiteSpace($_.ReadableSecondary)
				}

				if ($readableSecondaryIssues.Count -gt 0 -and -not $NoWarning)
				{
					foreach ($issue in $readableSecondaryIssues)
					{
						Write-Warning "FI-TS: AG '$($issue.AgName)' Replica '$($issue.ReplicaName)': ReadableSecondary = '$($issue.ReadableSecondary)' - FI-TS Standard erfordert NO!"
						Invoke-sqmLogging -Message "FI-TS WARNING: ReadableSecondary=$($issue.ReadableSecondary) auf Replikat $($issue.ReplicaName) in AG $($issue.AgName)" -FunctionName $functionName -Level "WARNING"
					}
				}

				# 4. Berichtsdateien schreiben
				if ($configRows.Count -gt 0)
				{
					$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
					$datestamp = Get-Date -Format "yyyy-MM-dd"
					$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
					$txtFile = Join-Path $OutputPath "AlwaysOnConfiguration_${safeInst}_${datestamp}.txt"
					$csvFile = Join-Path $OutputPath "AlwaysOnConfiguration_${safeInst}_${datestamp}.csv"

					if ($PSCmdlet.ShouldProcess($instance, "Erstelle AlwaysOn-Konfigurationsabericht in $OutputPath"))
					{
						# Verzeichnis anlegen
						if (-not (Test-Path $OutputPath))
						{
							New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
							Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
						}

						# TXT-Bericht
						$cntWarn = $readableSecondaryIssues.Count
						$cntOk = ($configRows | Where-Object { $_.ReadableSecondary -eq "NO" -or $_.ReadableSecondary -eq "NONE" -or [string]::IsNullOrWhiteSpace($_.ReadableSecondary) }).Count
						$agCount = ($configRows | Select-Object -ExpandProperty AgName -Unique).Count

						$lines = [System.Collections.Generic.List[string]]::new()
						$lines.Add("# ================================================================")
						$lines.Add("# sqmSQLTool - AlwaysOn Configuration Export")
						$lines.Add("# Instanz   : $instance")
						$lines.Add("# Erstellt  : $timestamp")
						$lines.Add("# AGs       : $agCount  |  Replicas: $($configRows.Count)  |  FI-TS Warnungen: $cntWarn")
						$lines.Add("# ================================================================")
						$lines.Add("")

						# Gruppiere nach AG
						$agNames = $configRows | Select-Object -ExpandProperty AgName -Unique
						foreach ($agName in $agNames)
						{
							$agRows = $configRows | Where-Object { $_.AgName -eq $agName }
							$firstRow = $agRows[0]

							$lines.Add("## AG: $agName")
							$lines.Add("   BackupPreference   : $($firstRow.BackupPreference)")
							$lines.Add("   FailureCondition   : $($firstRow.FailureConditionLevel)")
							$lines.Add("   HealthCheckTimeout : $($firstRow.HealthCheckTimeoutMs) ms")
							$lines.Add("   DbFailover         : $(if ($firstRow.DbFailoverEnabled) { "Enabled" } else { "Disabled" })")

							# Listener
							if ($firstRow.ListenerName)
							{
								$lines.Add("   Listener           : $($firstRow.ListenerName)  Port:$($firstRow.ListenerPort)  IP:$($firstRow.ListenerIP)")
							}

							# Datenbanken
							if ($dbsByAg[$agName] -and $dbsByAg[$agName].Count -gt 0)
							{
								$dbList = $dbsByAg[$agName] -join ", "
								$lines.Add("   Datenbanken        : $dbList")
							}

							$lines.Add("")
							$lines.Add("   REPLICAS:")
							$lines.Add(("{0,-25} {1,-18} {2,-18} {3,-20} {4,-8}" -f "Replica", "AvailMode", "FailoverMode", "ReadableSecondary", "Backup%"))
							$lines.Add(("-" * 95))

							foreach ($row in $agRows)
							{
								$status = if ($row.ReadableSecondary -eq "NO" -or $row.ReadableSecondary -eq "NONE" -or [string]::IsNullOrWhiteSpace($row.ReadableSecondary)) { "OK" } else { "WARN" }
								$lines.Add(("{0,-25} {1,-18} {2,-18} {3,-20} {4,-8} {5}" -f $row.ReplicaName, $row.AvailabilityMode, $row.FailoverMode, $row.ReadableSecondary, $row.BackupPriority, $status))
							}

							# FI-TS Warnung wenn nötig
							$agIssues = $readableSecondaryIssues | Where-Object { $_.AgName -eq $agName }
							if ($agIssues.Count -gt 0)
							{
								$lines.Add("")
								$lines.Add("   *** FI-TS WARNING: ReadableSecondary != NO!")
								$lines.Add("   *** FI-TS Standard erfordert ReadableSecondary = NO auf allen Replicas.")
							}

							$lines.Add("")
						}

						$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

						# CSV-Datei
						$configRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

						# Oeffne TXT-Datei wenn nicht -NoOpen
						if (-not $NoOpen -and $txtFile)
						{
							Start-Process $txtFile
						}

						Invoke-sqmLogging -Message "[$instance] AlwaysOn-Konfiguration exportiert: $txtFile" -FunctionName $functionName -Level "INFO"
					}
					else
					{
						Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
						$txtFile = $null
						$csvFile = $null
					}

					# Ergebnisobjekt fuer diese Instanz
					$result = [PSCustomObject]@{
						SqlInstance             = $instance
						AgCount                 = $agCount
						ReplicaCount            = $configRows.Count
						ReadableSecondaryCount  = $readableSecondaryIssues.Count
						ConfigRows              = $configRows
						TxtFile                 = $txtFile
						CsvFile                 = $csvFile
						Status                  = if ($readableSecondaryIssues.Count -gt 0) { "Warning" } else { "OK" }
					}
					$allInstanceResults.Add($result)

					if ($readableSecondaryIssues.Count -gt 0)
					{
						Invoke-sqmLogging -Message "[$instance] $($readableSecondaryIssues.Count) FI-TS ReadableSecondary Issue(s) - Bericht: $txtFile" -FunctionName $functionName -Level "WARNING"
					}
				}
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance             = $instance
						AgCount                 = 0
						ReplicaCount            = 0
						ReadableSecondaryCount  = 0
						ConfigRows              = @()
						Status                  = "Error"
						Message                 = $errMsg
						TxtFile                 = $null
						CsvFile                 = $null
					})
				if ($EnableException) { throw }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanz(en) verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}
