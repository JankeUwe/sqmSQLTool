<#
.SYNOPSIS
    Initiates failover of a Distributed AlwaysOn AG (planned, without data loss).

.DESCRIPTION
    Performs the documented planned failover of a Distributed AG from the global primary to the forwarder:

    1. Checks that all databases are synchronizing, none is suspended and the queues are small
    2. Sets both availability groups of the Distributed AG to SYNCHRONOUS_COMMIT
    3. Waits until every database is SYNCHRONIZED
    4. Sets the Distributed AG on the global primary to the SECONDARY role
    5. Runs FORCE_FAILOVER_ALLOW_DATA_LOSS on the forwarder (safe, because both sides are synchronized)
    6. Verifies the new roles and writes a report

    ALTER AVAILABILITY GROUP ... FAILOVER is not valid for a Distributed AG, therefore this function
    uses the procedure above. If the synchronization does not complete within SyncTimeoutSeconds the
    availability mode is set back to ASYNCHRONOUS_COMMIT and nothing is failed over.

    Requires explicit confirmation unless -Force is used.

.PARAMETER SqlInstance
    SQL Server instance hosting the CURRENT global primary of the Distributed AG. Default: current computer name.

.PARAMETER TargetInstance
    SQL Server instance hosting the forwarder (primary of the other AG), the future primary. Required.

.PARAMETER SqlCredential
    Optional PSCredential for both connections.

.PARAMETER AvailabilityGroupName
    Name of the Distributed AG to failover. Required.

.PARAMETER SyncTimeoutSeconds
    Maximum time to wait for SYNCHRONIZED after switching to synchronous commit. Default 600.

.PARAMETER Force
    Skip confirmation dialog.

.PARAMETER Rollback
    Rollback zum urspruenglichen Primary. Ablauf wie beim Failover, die Richtung ergibt sich aus
    SqlInstance (aktueller Primary) und TargetInstance (altes System).

.PARAMETER WhatIf
    Shows what would be done without actually performing the failover.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Invoke-sqmDistributedFailover -SqlInstance "SQL01" -TargetInstance "NEW01" -AvailabilityGroupName "MyDAG" -Force

.EXAMPLE
    Invoke-sqmDistributedFailover -SqlInstance "SQL01" -TargetInstance "NEW01" -AvailabilityGroupName "MyDAG" -WhatIf

.EXAMPLE
    # Rollback: SqlInstance ist jetzt das neue System (aktueller Primary), TargetInstance das alte
    Invoke-sqmDistributedFailover -SqlInstance "NEW01" -TargetInstance "SQL01" -AvailabilityGroupName "MyDAG" -Rollback -Force

.NOTES
    Author:       MSSQLTools
    WARNING:      This is a critical operation. Always test in DR environment first.
#>
function Invoke-sqmDistributedFailover
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$TargetInstance,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroupName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(30, 86400)]
		[int]$SyncTimeoutSeconds = 600,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'DistributedFailover'),
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$Rollback,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName fuer [$SqlInstance] AG=$AvailabilityGroupName" -FunctionName $functionName -Level "INFO"

		if (-not (Test-Path $OutputPath))
		{
			New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
		}
	}

	process
	{
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
		$targetParams = @{ SqlInstance = $TargetInstance }
		if ($SqlCredential) { $targetParams['SqlCredential'] = $SqlCredential }

		$isRollback = $Rollback.IsPresent
		$direction = if ($isRollback) { "ROLLBACK" } else { "FAILOVER" }
		$modeChanged = $false
		$rolesSwitched = $false
		$steps = [System.Collections.Generic.List[PSCustomObject]]::new()
		$note = {
			param ($Step, $Status, $Details)
			$steps.Add([PSCustomObject]@{ Step = $Step; Status = $Status; Details = $Details })
			Write-Information -MessageData ([PSCustomObject]@{ Step = $Step; Status = $Status }) -Tags 'sqmStep'
		}

		try
		{
			if (-not $TargetInstance)
			{
				throw "TargetInstance fehlt: Fuer das Failover einer Distributed AG werden beide Seiten benoetigt (Instanz des Forwarders)."
			}

			# Step 1: Beide AGs der Distributed AG und ihre Rolle ermitteln
			$dagInfo = @(Invoke-DbaQuery -EnableException @connParams -Query @"
SELECT ar.replica_server_name AS AgName, ars.is_local AS IsLocal
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ag.name = @n AND ag.is_distributed = 1
"@ -SqlParameters @{ n = $AvailabilityGroupName })

			if ($dagInfo.Count -ne 2)
			{
				throw "Distributed AG '$AvailabilityGroupName' auf [$SqlInstance] nicht gefunden oder unvollstaendig ($($dagInfo.Count) statt 2 Mitglieder)."
			}
			$localAg = ($dagInfo | Where-Object { $_.IsLocal -eq $true -or $_.IsLocal -eq 1 } | Select-Object -First 1).AgName
			$remoteAg = ($dagInfo | Where-Object { $_.AgName -ne $localAg } | Select-Object -First 1).AgName
			if (-not $localAg -or -not $remoteAg)
			{
				throw "Lokale AG der Distributed AG konnte auf [$SqlInstance] nicht bestimmt werden. Ist [$SqlInstance] der aktuelle globale Primary?"
			}
			& $note 'Pruefe Distributed AG' 'OK' "Lokal [$localAg] -> Ziel [$remoteAg]"

			# Step 2: Bereitschaft (nicht beim Rollback)
			if (-not $isRollback)
			{
				$snap = Get-sqmDagSyncSnapshot @connParams -DagName $AvailabilityGroupName
				$ready = Test-sqmDagFailoverReady -Snapshot $snap
				if (-not $ready.Ready)
				{
					throw "Failover NICHT empfohlen: $($ready.Reasons -join ' | ')"
				}
				& $note 'Bereitschaft' 'OK' "$($ready.DatabaseCount) Datenbank(en) bereit"
			}
			else
			{
				Invoke-sqmLogging -Message "ROLLBACK-Modus: Bereitschaftspruefung wird uebersprungen." -FunctionName $functionName -Level "WARNING"
			}

			# Step 3: Bestaetigung (wenn nicht -Force)
			$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
			if ((-not $Force -or $WhatIfPreference) -and -not $PSCmdlet.ShouldProcess("$AvailabilityGroupName ($SqlInstance -> $TargetInstance)", "$direction durchfuehren"))
			{
				Invoke-sqmLogging -Message "$direction abgebrochen durch Benutzer/WhatIf" -FunctionName $functionName -Level "INFO"
				return [PSCustomObject]@{
					Status = $(if ($WhatIfPreference) { 'WHATIF' } else { 'CANCELLED' })
					Message = "$direction abgebrochen"
					Timestamp = Get-Date
					Steps = $steps
				}
			}

			Invoke-sqmLogging -Message "Starte $direction [$AvailabilityGroupName] [$localAg] -> [$remoteAg]" -FunctionName $functionName -Level "WARNING"

			# Step 4: Beide Seiten auf SYNCHRONOUS_COMMIT
			$modeSql = "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] MODIFY AVAILABILITY GROUP ON N'$localAg' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT), N'$remoteAg' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT)"
			Invoke-DbaQuery -EnableException @connParams -Query $modeSql
			$modeChanged = $true
			Invoke-DbaQuery -EnableException @targetParams -Query $modeSql
			& $note 'Synchronous Commit' 'OK' 'Beide Seiten auf SYNCHRONOUS_COMMIT'

			# Step 5: Auf SYNCHRONIZED warten
			$deadline = (Get-Date).AddSeconds($SyncTimeoutSeconds)
			$synced = $false
			do
			{
				$snap = Get-sqmDagSyncSnapshot @connParams -DagName $AvailabilityGroupName
				$rem = @($snap | Where-Object { -not ($_.IsLocal -eq $true -or $_.IsLocal -eq 1) })
				$synced = ($rem.Count -gt 0 -and @($rem | Where-Object { $_.SyncState -ne 'SYNCHRONIZED' }).Count -eq 0)
				if (-not $synced) { Start-Sleep -Seconds 3 }
			}
			until ($synced -or (Get-Date) -gt $deadline)

			if (-not $synced)
			{
				throw "Die Datenbanken wurden innerhalb von $SyncTimeoutSeconds Sekunden nicht SYNCHRONIZED. Es wurde nichts umgeschaltet."
			}
			& $note 'Synchronisiert' 'OK' 'Alle Datenbanken SYNCHRONIZED'

			# Step 6: Alten Primary auf SECONDARY, dann Forwarder hochstufen
			Invoke-DbaQuery -EnableException @connParams -Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] SET (ROLE = SECONDARY)"
			$rolesSwitched = $true
			& $note 'Alter Primary Secondary' 'OK' "[$localAg] ist Secondary"

			Invoke-DbaQuery -EnableException @targetParams -Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] FORCE_FAILOVER_ALLOW_DATA_LOSS"
			& $note 'Neuer Primary' 'OK' "[$remoteAg] ist Primary"

			# Step 7: Verifikation
			Start-Sleep -Seconds 3
			$postFailoverStatus = @(Invoke-DbaQuery -EnableException @targetParams -Query @"
SELECT ag.name, ar.replica_server_name, ars.role_desc, ars.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ag.name = @n
"@ -SqlParameters @{ n = $AvailabilityGroupName })
			$newPrimary = $postFailoverStatus | Where-Object { $_.role_desc -eq 'PRIMARY' -and $_.replica_server_name -eq $remoteAg }
			if (-not $newPrimary)
			{
				throw "Nach dem Umschalten ist [$remoteAg] nicht als PRIMARY sichtbar. Zustand auf beiden Seiten pruefen."
			}
			& $note 'Verifikation' 'OK' "Rollen: $((($postFailoverStatus | ForEach-Object { "$($_.replica_server_name)=$($_.role_desc)" }) -join ', '))"

			# Step 8: Report
			$reportFile = Join-Path -Path $OutputPath -ChildPath "Distributed-AG-$direction-$AvailabilityGroupName-$([datetime]::Now.ToString('yyyy-MM-dd-HHmm')).txt"
			$reportContent = @(
				"================================================================"
				"sqmSQLTool - Distributed AG $direction Report"
				"================================================================"
				"Timestamp       : $timestamp"
				"Distributed AG  : $AvailabilityGroupName"
				"Alter Primary   : $localAg ($SqlInstance)"
				"Neuer Primary   : $remoteAg ($TargetInstance)"
				"Status          : SUCCESS"
				"================================================================"
				"HINWEIS: Beide Seiten stehen weiter auf SYNCHRONOUS_COMMIT (Voraussetzung fuer ein Rollback)."
				"================================================================"
			)
			foreach ($row in $postFailoverStatus)
			{
				$reportContent += "$("$($row.replica_server_name)".PadRight(20)) Role: $("$($row.role_desc)".PadRight(12)) Sync: $($row.synchronization_health_desc)"
			}
			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force

			Invoke-sqmLogging -Message "$direction abgeschlossen. Report: $reportFile" -FunctionName $functionName -Level "INFO"

			return [PSCustomObject]@{
				Status = 'SUCCESS'
				Direction = $direction
				SqlInstance = $SqlInstance
				TargetInstance = $TargetInstance
				PrimaryAg = $AvailabilityGroupName
				OldPrimaryAg = $localAg
				NewPrimaryAg = $remoteAg
				SecondaryAg = $localAg
				SecondaryServer = $SqlInstance
				Timestamp = $timestamp
				PostFailoverStatus = $postFailoverStatus
				Steps = $steps
				ReportFile = $reportFile
			}
		}
		catch
		{
			$errMsg = "Fehler beim ${direction}: $($_.Exception.Message)"

			# Aufraeumen: noch nicht umgeschaltet -> Modus zurueck auf ASYNCHRONOUS_COMMIT
			$recovery = ''
			if ($modeChanged -and -not $rolesSwitched -and $localAg -and $remoteAg)
			{
				$asyncSql = "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] MODIFY AVAILABILITY GROUP ON N'$localAg' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT), N'$remoteAg' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT)"
				try
				{
					Invoke-DbaQuery -EnableException @connParams -Query $asyncSql
					Invoke-DbaQuery -EnableException @targetParams -Query $asyncSql
					$recovery = ' Der Verfuegbarkeitsmodus wurde auf ASYNCHRONOUS_COMMIT zurueckgesetzt, es wurde nichts umgeschaltet.'
				}
				catch { $recovery = " ACHTUNG: Zuruecksetzen auf ASYNCHRONOUS_COMMIT ist fehlgeschlagen ($($_.Exception.Message)); beide Seiten manuell pruefen." }
			}
			elseif ($rolesSwitched)
			{
				$recovery = " KRITISCH: Der alte Primary ist bereits SECONDARY, der neue aber nicht bestaetigt. Auf [$TargetInstance] ausfuehren: ALTER AVAILABILITY GROUP [$AvailabilityGroupName] FORCE_FAILOVER_ALLOW_DATA_LOSS (oder auf [$SqlInstance]: ALTER AVAILABILITY GROUP [$AvailabilityGroupName] SET (ROLE = PRIMARY))."
			}
			$errMsg += $recovery
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException) { throw $errMsg }

			return [PSCustomObject]@{
				Status = 'FAILED'
				Error = $errMsg
				Timestamp = Get-Date
				Steps = $steps
			}
		}
	}
}
