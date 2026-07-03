<#
.SYNOPSIS
Creates and synchronises the backup exclude table in the master database.

.DESCRIPTION
Ensures the table master.dbo.sqm_BackupExclude exists on the target SQL Server instance.
If the table does not exist it is created automatically.

After the table has been created or verified, the function synchronises its content
with the current list of databases on the server:
  - Databases not yet in the table are inserted (IsActive=1, IsOrphaned=0).
  - Databases that are in the table but no longer exist on the server are marked
    IsOrphaned=1 (the row is never deleted).
  - Orphaned entries whose database has reappeared on the server are reset to
    IsOrphaned=0.
  - tempdb is always skipped, regardless of any switch.

In addition, a history table master.dbo.sqm_BackupExclude_History and an audit trigger
dbo.trg_sqm_BackupExclude_Audit are created automatically if they do not yet exist.
The trigger records every INSERT and every change to IsActive or IsOrphaned.

If SqlInstance is not specified, the current computer name ($env:COMPUTERNAME) is used.

.PARAMETER SqlInstance
The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.

.PARAMETER SqlCredential
Alternative credentials (PSCredential). If not specified, Windows authentication is used.

.PARAMETER IncludeSystemDatabases
When set, the system databases master, model, and msdb are also inserted into the
exclude table. tempdb is always excluded regardless of this switch.

.PARAMETER EnableException
Switch to propagate exceptions immediately (by default errors are logged as warnings).

.EXAMPLE
# Synchronise on the local instance – user databases only
Sync-sqmBackupExcludeTable

.EXAMPLE
# Synchronise on a remote instance including system databases
Sync-sqmBackupExcludeTable -SqlInstance "SQL01" -IncludeSystemDatabases

.EXAMPLE
# Preview what would change without making any modifications
Sync-sqmBackupExcludeTable -SqlInstance "SQL01" -WhatIf

.EXAMPLE
# Synchronise and verify that the audit history table and trigger are in place
Sync-sqmBackupExcludeTable -SqlInstance "SQL01\INST1"

.NOTES
Requires the dbatools module and the Invoke-sqmLogging function.
Default for SqlInstance: $env:COMPUTERNAME (applies to all future versions).
The history table master.dbo.sqm_BackupExclude_History and the trigger
dbo.trg_sqm_BackupExclude_Audit are created automatically on first run.
#>

function Sync-sqmBackupExcludeTable
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject[]])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[switch]$SkipAlwaysOnPropagation,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# Default fuer SqlInstance: aktueller Computername
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}

		# Pruefung auf dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance" -FunctionName $functionName -Level "INFO"

		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		$createTableSql = @"
IF NOT EXISTS (
    SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude') AND type = 'U'
)
BEGIN
    CREATE TABLE master.dbo.sqm_BackupExclude (
        DatabaseName  sysname       NOT NULL,
        Reason        nvarchar(255) NULL,
        ExcludedBy    sysname       NOT NULL CONSTRAINT DF_sqm_BackupExclude_ExcludedBy DEFAULT SUSER_SNAME(),
        ExcludedAt    datetime2     NOT NULL CONSTRAINT DF_sqm_BackupExclude_ExcludedAt DEFAULT SYSDATETIME(),
        IsActive      bit           NOT NULL CONSTRAINT DF_sqm_BackupExclude_IsActive   DEFAULT 1,
        IsOrphaned    bit           NOT NULL CONSTRAINT DF_sqm_BackupExclude_IsOrphaned DEFAULT 0,
        CONSTRAINT PK_sqm_BackupExclude PRIMARY KEY (DatabaseName)
    );
END
"@

		$createHistoryTableSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude_History') AND type = 'U')
BEGIN
    CREATE TABLE master.dbo.sqm_BackupExclude_History (
        HistoryId     int           NOT NULL IDENTITY(1,1) CONSTRAINT PK_sqm_BackupExclude_History PRIMARY KEY,
        DatabaseName  sysname       NOT NULL,
        ChangedField  nvarchar(50)  NOT NULL,
        OldValue      nvarchar(255) NULL,
        NewValue      nvarchar(255) NULL,
        ChangedBy     sysname       NOT NULL DEFAULT SUSER_SNAME(),
        ChangedAt     datetime2     NOT NULL DEFAULT SYSDATETIME()
    );
END

IF NOT EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'trg_sqm_BackupExclude_Audit')
BEGIN
    EXEC sp_executesql N'
    CREATE TRIGGER dbo.trg_sqm_BackupExclude_Audit
    ON master.dbo.sqm_BackupExclude
    AFTER INSERT, UPDATE
    AS
    BEGIN
        SET NOCOUNT ON;
        -- Track IsActive changes
        INSERT INTO master.dbo.sqm_BackupExclude_History (DatabaseName, ChangedField, OldValue, NewValue)
        SELECT i.DatabaseName,
               ''IsActive'',
               CAST(d.IsActive AS nvarchar(10)),
               CAST(i.IsActive AS nvarchar(10))
        FROM   inserted i
        LEFT   JOIN deleted d ON i.DatabaseName = d.DatabaseName
        WHERE  d.DatabaseName IS NULL                        -- INSERT
            OR ISNULL(d.IsActive,-1) <> ISNULL(i.IsActive,-1);  -- UPDATE IsActive changed

        -- Track IsOrphaned changes
        INSERT INTO master.dbo.sqm_BackupExclude_History (DatabaseName, ChangedField, OldValue, NewValue)
        SELECT i.DatabaseName,
               ''IsOrphaned'',
               CAST(d.IsOrphaned AS nvarchar(10)),
               CAST(i.IsOrphaned AS nvarchar(10))
        FROM   inserted i
        LEFT   JOIN deleted d ON i.DatabaseName = d.DatabaseName
        WHERE  d.DatabaseName IS NULL
            OR ISNULL(d.IsOrphaned,-1) <> ISNULL(i.IsOrphaned,-1);
    END';
END
"@
	}

	process
	{
		try
		{
			# 1. Verbindung aufbauen
			$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop
			Invoke-sqmLogging -Message "Verbindung zu '$SqlInstance' hergestellt." -FunctionName $functionName -Level "INFO"

			# 2. Tabelle erstellen falls nicht vorhanden
			$tableExists = Invoke-DbaQuery @connParams -Database master `
				-Query "SELECT 1 AS TableExists FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude') AND type = 'U'" `
				-ErrorAction Stop

			if (-not $tableExists)
			{
				$actionMsg = "Erstelle Tabelle master.dbo.sqm_BackupExclude auf '$SqlInstance'"
				if ($PSCmdlet.ShouldProcess($SqlInstance, $actionMsg))
				{
					Invoke-DbaQuery @connParams -Database master -Query $createTableSql -ErrorAction Stop
					Invoke-sqmLogging -Message "Tabelle master.dbo.sqm_BackupExclude wurde erstellt." -FunctionName $functionName -Level "INFO"
					$results.Add([PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = 'N/A'
						Action       = 'Created'
						IsActive     = $null
						IsOrphaned   = $null
						Message      = "Tabelle master.dbo.sqm_BackupExclude wurde neu erstellt."
					})
				}
				else
				{
					Invoke-sqmLogging -Message "WhatIf: Tabelle master.dbo.sqm_BackupExclude wuerde erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$results.Add([PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = 'N/A'
						Action       = 'WhatIfSkipped'
						IsActive     = $null
						IsOrphaned   = $null
						Message      = "WhatIf: Tabelle master.dbo.sqm_BackupExclude wuerde erstellt werden."
					})
					return
				}
			}
			else
			{
				Invoke-sqmLogging -Message "Tabelle master.dbo.sqm_BackupExclude ist bereits vorhanden." -FunctionName $functionName -Level "INFO"
			}

			# 2b. History-Tabelle und Audit-Trigger erstellen falls nicht vorhanden
			Invoke-DbaQuery @connParams -Database master -Query $createHistoryTableSql -ErrorAction Stop
			Invoke-sqmLogging -Message "History-Tabelle und Audit-Trigger geprueft/erstellt." -FunctionName $functionName -Level "INFO"

			# 3. Aktuelle Datenbanken vom Server laden
			$dbParams = @{
				SqlInstance   = $SqlInstance
				ExcludeSystem = $true
				ErrorAction   = 'Stop'
			}
			if ($SqlCredential) { $dbParams['SqlCredential'] = $SqlCredential }
			if ($EnableException) { $dbParams['EnableException'] = $true }

			$serverDatabases = Get-DbaDatabase @dbParams | Where-Object { $_.Name -ne 'tempdb' -and $_.IsAccessible }

			if ($IncludeSystemDatabases)
			{
				$sysDbs = Get-DbaDatabase @connParams -Database 'master', 'model', 'msdb' -ErrorAction SilentlyContinue |
					Where-Object { $_.Name -ne 'tempdb' -and $_.IsAccessible }
				$serverDatabases = @($serverDatabases) + @($sysDbs) | Where-Object { $_ }
				Invoke-sqmLogging -Message "IncludeSystemDatabases gesetzt: master, model, msdb werden ebenfalls beruecksichtigt." -FunctionName $functionName -Level "INFO"
			}

			$serverDbNames = $serverDatabases | Select-Object -ExpandProperty Name

			# 4. Bestehende Eintraege aus der Tabelle laden
			$existingRows = Invoke-DbaQuery @connParams -Database master `
				-Query "SELECT DatabaseName, IsActive, IsOrphaned FROM master.dbo.sqm_BackupExclude" `
				-ErrorAction Stop

			$existingDbNames = if ($existingRows) { @($existingRows | Select-Object -ExpandProperty DatabaseName) } else { @() }

			# 5. Neue Datenbanken einfuegen (noch nicht in der Tabelle)
			foreach ($dbName in $serverDbNames)
			{
				if ($dbName -eq 'tempdb') { continue }

				if ($dbName -notin $existingDbNames)
				{
					$insertSql = "INSERT INTO master.dbo.sqm_BackupExclude (DatabaseName, IsActive, IsOrphaned) VALUES (N'$($dbName.Replace("'", "''"))', 1, 0)"
					$actionMsg = "Fuege Datenbank '$dbName' in sqm_BackupExclude ein"
					if ($PSCmdlet.ShouldProcess($dbName, $actionMsg))
					{
						Invoke-DbaQuery @connParams -Database master -Query $insertSql -ErrorAction Stop
						Invoke-sqmLogging -Message "Datenbank '$dbName' wurde in sqm_BackupExclude eingefuegt (IsActive=1, IsOrphaned=0)." -FunctionName $functionName -Level "INFO"
						$results.Add([PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Action       = 'Added'
							IsActive     = $true
							IsOrphaned   = $false
							Message      = "Datenbank '$dbName' neu in die Exclude-Tabelle eingefuegt."
						})
					}
					else
					{
						Invoke-sqmLogging -Message "WhatIf: Datenbank '$dbName' wuerde eingefuegt werden." -FunctionName $functionName -Level "VERBOSE"
						$results.Add([PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Action       = 'WhatIfSkipped'
							IsActive     = $true
							IsOrphaned   = $false
							Message      = "WhatIf: Datenbank '$dbName' wuerde eingefuegt werden."
						})
					}
				}
			}

			# 6. Verwaiste Eintraege markieren (in Tabelle, aber nicht mehr auf dem Server)
			foreach ($row in $existingRows)
			{
				$dbName = $row.DatabaseName
				if ($dbName -notin $serverDbNames)
				{
					if (-not $row.IsOrphaned)
					{
						$updateSql = "UPDATE master.dbo.sqm_BackupExclude SET IsOrphaned = 1 WHERE DatabaseName = N'$($dbName.Replace("'", "''"))'"
						$actionMsg = "Markiere '$dbName' als verwaist (IsOrphaned=1)"
						if ($PSCmdlet.ShouldProcess($dbName, $actionMsg))
						{
							Invoke-DbaQuery @connParams -Database master -Query $updateSql -ErrorAction Stop
							Invoke-sqmLogging -Message "Datenbank '$dbName' existiert nicht mehr auf dem Server. IsOrphaned auf 1 gesetzt." -FunctionName $functionName -Level "WARNING"
							$results.Add([PSCustomObject]@{
								SqlInstance  = $SqlInstance
								DatabaseName = $dbName
								Action       = 'Orphaned'
								IsActive     = [bool]$row.IsActive
								IsOrphaned   = $true
								Message      = "Datenbank '$dbName' nicht mehr vorhanden. Als verwaist markiert."
							})
						}
						else
						{
							Invoke-sqmLogging -Message "WhatIf: Datenbank '$dbName' wuerde als verwaist markiert werden." -FunctionName $functionName -Level "VERBOSE"
							$results.Add([PSCustomObject]@{
								SqlInstance  = $SqlInstance
								DatabaseName = $dbName
								Action       = 'WhatIfSkipped'
								IsActive     = [bool]$row.IsActive
								IsOrphaned   = $true
								Message      = "WhatIf: Datenbank '$dbName' wuerde als verwaist markiert werden."
							})
						}
					}
					else
					{
						Invoke-sqmLogging -Message "Datenbank '$dbName' ist bereits als verwaist markiert." -FunctionName $functionName -Level "INFO"
						$results.Add([PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Action       = 'Unchanged'
							IsActive     = [bool]$row.IsActive
							IsOrphaned   = $true
							Message      = "Datenbank '$dbName' ist bereits als verwaist markiert. Keine Aenderung."
						})
					}
				}
				else
				{
					# 7. Verwaiste Eintraege reaktivieren wenn Datenbank wieder vorhanden
					if ($row.IsOrphaned)
					{
						$updateSql = "UPDATE master.dbo.sqm_BackupExclude SET IsOrphaned = 0 WHERE DatabaseName = N'$($dbName.Replace("'", "''"))'"
						$actionMsg = "Reaktiviere '$dbName': IsOrphaned auf 0 zuruecksetzen"
						if ($PSCmdlet.ShouldProcess($dbName, $actionMsg))
						{
							Invoke-DbaQuery @connParams -Database master -Query $updateSql -ErrorAction Stop
							Invoke-sqmLogging -Message "Datenbank '$dbName' ist wieder vorhanden. IsOrphaned auf 0 zurueckgesetzt." -FunctionName $functionName -Level "INFO"
							$results.Add([PSCustomObject]@{
								SqlInstance  = $SqlInstance
								DatabaseName = $dbName
								Action       = 'Unorphaned'
								IsActive     = [bool]$row.IsActive
								IsOrphaned   = $false
								Message      = "Datenbank '$dbName' wieder vorhanden. IsOrphaned auf 0 zurueckgesetzt."
							})
						}
						else
						{
							Invoke-sqmLogging -Message "WhatIf: IsOrphaned fuer '$dbName' wuerde auf 0 gesetzt werden." -FunctionName $functionName -Level "VERBOSE"
							$results.Add([PSCustomObject]@{
								SqlInstance  = $SqlInstance
								DatabaseName = $dbName
								Action       = 'WhatIfSkipped'
								IsActive     = [bool]$row.IsActive
								IsOrphaned   = $false
								Message      = "WhatIf: IsOrphaned fuer '$dbName' wuerde auf 0 gesetzt werden."
							})
						}
					}
					else
					{
						Invoke-sqmLogging -Message "Datenbank '$dbName' ist bereits korrekt in der Tabelle. Keine Aenderung." -FunctionName $functionName -Level "INFO"
						$results.Add([PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Action       = 'Unchanged'
							IsActive     = [bool]$row.IsActive
							IsOrphaned   = $false
							Message      = "Datenbank '$dbName' unveraendert."
						})
					}
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler in $functionName`: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results.Add([PSCustomObject]@{
				SqlInstance  = $SqlInstance
				DatabaseName = $null
				Action       = 'Error'
				IsActive     = $null
				IsOrphaned   = $null
				Message      = $errMsg
			})
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Objekte zurueckgegeben." -FunctionName $functionName -Level "INFO"

		# AlwaysOn-Propagierung: Tabelle auch auf Secondary-Repliken anlegen/synchronisieren
		if (-not $SkipAlwaysOnPropagation)
		{
			try
			{
				$replicaQuery = @"
SELECT r.replica_server_name
FROM   sys.availability_replicas r
WHERE  r.replica_server_name <> @@SERVERNAME
"@
				$secondaries = Invoke-DbaQuery @connParams -Database master -Query $replicaQuery -ErrorAction SilentlyContinue

				# Aktueller, endgueltiger Stand der PRIMARY nach allen obigen Aenderungen - wird unten
				# per MERGE an jede Secondary GEPUSHT (nicht nur strukturell abgeglichen). Der
				# rekursive Sync-sqmBackupExcludeTable-Aufruf allein erkennt auf der Secondary nur
				# NEUE/geloeschte Datenbanken selbst, uebernimmt aber NIE die vom Admin ueber
				# Show-sqmBackupExcludeForm gesetzten IsActive/Reason-Werte der Primary - das war die
				# Ursache dafuer, dass Aenderungen an der Exclude-Liste nie auf Secondaries ankamen.
				$primaryRows = if ($secondaries)
				{
					Invoke-DbaQuery @connParams -Database master -Query "SELECT DatabaseName, Reason, IsActive FROM master.dbo.sqm_BackupExclude" -ErrorAction Stop
				}

				foreach ($sec in $secondaries)
				{
					$secName = $sec.replica_server_name
					Invoke-sqmLogging -Message "AlwaysOn: Propagiere auf Secondary '$secName'." -FunctionName $functionName -Level "INFO"
					try
					{
						$secParams = @{
							SqlInstance              = $secName
							SkipAlwaysOnPropagation  = $true
						}
						if ($SqlCredential)          { $secParams['SqlCredential']          = $SqlCredential }
						if ($IncludeSystemDatabases) { $secParams['IncludeSystemDatabases'] = $true }

						Sync-sqmBackupExcludeTable @secParams -ErrorAction Stop | Out-Null

						if ($primaryRows)
						{
							$secConnParams = @{ SqlInstance = $secName }
							if ($SqlCredential) { $secConnParams['SqlCredential'] = $SqlCredential }

							$valuesSql = ($primaryRows | ForEach-Object {
									$reasonSql = if ([string]::IsNullOrEmpty($_.Reason)) { 'NULL' } else { "N'$($_.Reason.Replace("'", "''"))'" }
									"(N'$($_.DatabaseName.Replace("'", "''"))', $reasonSql, $([int][bool]$_.IsActive))"
								}) -join ', '

							$mergeSql = @"
MERGE master.dbo.sqm_BackupExclude AS tgt
USING (VALUES $valuesSql) AS src (DatabaseName, Reason, IsActive)
ON tgt.DatabaseName = src.DatabaseName
WHEN MATCHED AND (tgt.IsActive <> src.IsActive OR ISNULL(tgt.Reason, N'') <> ISNULL(src.Reason, N'')) THEN
    UPDATE SET IsActive = src.IsActive, Reason = src.Reason
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DatabaseName, Reason, IsActive, IsOrphaned) VALUES (src.DatabaseName, src.Reason, src.IsActive, 0);
"@
							Invoke-DbaQuery @secConnParams -Database master -Query $mergeSql -ErrorAction Stop
							Invoke-sqmLogging -Message "AlwaysOn: IsActive/Reason-Werte der Primary auf '$secName' uebertragen ($($primaryRows.Count) Zeile(n))." -FunctionName $functionName -Level "INFO"
						}

						Invoke-sqmLogging -Message "AlwaysOn: Secondary '$secName' erfolgreich synchronisiert." -FunctionName $functionName -Level "INFO"
						$results.Add([PSCustomObject]@{
							SqlInstance  = $secName
							DatabaseName = 'N/A'
							Action       = 'AlwaysOnPropagated'
							IsActive     = $null
							IsOrphaned   = $null
							Message      = "AlwaysOn Secondary '$secName' synchronisiert (inkl. IsActive/Reason-Werte)."
						})
					}
					catch
					{
						Invoke-sqmLogging -Message "AlwaysOn: Fehler bei Propagierung auf '$secName': $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
				}
			}
			catch
			{
				# Kein AG konfiguriert oder Abfrage nicht verfuegbar — kein Fehler
				Invoke-sqmLogging -Message "AlwaysOn-Erkennung: $($_.Exception.Message)" -FunctionName $functionName -Level "VERBOSE"
			}
		}

		return $results.ToArray()
	}
}
