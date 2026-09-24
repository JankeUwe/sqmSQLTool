<#
.SYNOPSIS
    Brings one or more user databases to the house standard: orphaned users repaired, users without
    login removed, compatibility level raised to the server's level, TARGET_RECOVERY_TIME set to
    60 seconds and the owner set to sa.

.DESCRIPTION
    Typical use: after a restore, a migration or an in-place upgrade. Invoke-sqmRestoreDatabase calls
    this function itself after every successful restore; standalone it can be run against any
    instance, e.g. to clean up all user databases after a server migration.

    Steps per database (each one can be switched off individually):

      1. FixOrphanUser
         Database users whose SID matches no login, but for which a login with the SAME NAME exists,
         are re-mapped to that login (ALTER USER ... WITH LOGIN). Typical after a restore onto
         another server: the SQL login exists there too, but with a different SID.

      2. RemoveUserWithoutLogin
         Remaining users whose SID matches no login are dropped. Before the drop, schemas and roles
         owned by the user are handed over to dbo - otherwise DROP USER fails. Handover and drop run
         in one transaction: if the drop fails, the ownership stays as it was.
         Kept (never dropped):
           - dbo, guest, INFORMATION_SCHEMA, sys and internal users (##...##)
           - users created WITHOUT LOGIN (Service Broker, module signing, impersonation) -
             use -IncludeUsersWithoutLogin to drop those too
           - contained database users (authentication type DATABASE) and certificate/key users
           - Windows users that have no login of their own but reach the server through a Windows
             group login (checked via xp_logininfo). Dropping them would lock out a working account.

      3. CompatibilityLevel
         Raised to the level of the server version (e.g. 160 on SQL Server 2022). A higher level is
         never lowered. Note: a new compatibility level can change execution plans (cardinality
         estimator), plan a performance check for critical applications.

      4. TargetRecoveryTime
         TARGET_RECOVERY_TIME = 60 SECONDS (indirect checkpoint), configurable.

      5. DatabaseOwner
         Owner set to the sa account, determined via SID 0x01 (works when sa has been renamed).

    Skipped entirely: databases that are not ONLINE, read-only databases, secondary replicas of an
    availability group (changes there must be made on the primary) and database snapshots.
    System databases are never processed.

    Returns one row per action:
      SqlInstance, Database, Step, Target, OldValue, NewValue, Status (OK/Skipped/Failed/WhatIf), Message

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name(s). Wildcards allowed (e.g. 'Prod*'). Default: all user databases.

.PARAMETER ExcludeDatabase
    Databases to exclude. Wildcards allowed.

.PARAMETER TargetRecoveryTimeSeconds
    Value for TARGET_RECOVERY_TIME. Default: 60.

.PARAMETER IncludeUsersWithoutLogin
    Also drop users that were deliberately created WITHOUT LOGIN. Default: they are kept.

.PARAMETER SkipOrphanRepair
    Skip step 1 (re-mapping orphaned users).

.PARAMETER SkipUserRemoval
    Skip step 2 (dropping users without login).

.PARAMETER SkipCompatibilityLevel
    Skip step 3 (compatibility level).

.PARAMETER SkipTargetRecoveryTime
    Skip step 4 (TARGET_RECOVERY_TIME).

.PARAMETER SkipOwner
    Skip step 5 (owner sa).

.PARAMETER OutputPath
    Directory for the CSV change log. Default: <module OutputPath>\DatabaseStandardization.

.PARAMETER ContinueOnError
    Continue with the next instance if one instance fails. Default: $false.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning them as Failed rows.

.EXAMPLE
    # Show what would be changed on all user databases
    Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -WhatIf

.EXAMPLE
    # One database after a migration
    Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -Database 'Arena'

.EXAMPLE
    # Everything except the compatibility level (application not yet certified)
    Invoke-sqmDatabaseStandardization -SqlInstance 'SQL01' -Database 'App*' -SkipCompatibilityLevel

.EXAMPLE
    # Several instances, only failures
    'SQL01','SQL02' | Invoke-sqmDatabaseStandardization -Confirm:$false | Where-Object Status -eq 'Failed'

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    Needs: sysadmin on the instance. SQL Server 2012 or later (authentication_type,
    TARGET_RECOVERY_TIME, sys.databases.replica_id).
    See also: Set-sqmDatabaseOwner, Invoke-sqmRestoreDatabase, Sync-sqmDatabaseLogins
#>
function Invoke-sqmDatabaseStandardization
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 3600)]
		[int]$TargetRecoveryTimeSeconds = 60,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeUsersWithoutLogin,
		[Parameter(Mandatory = $false)]
		[switch]$SkipOrphanRepair,
		[Parameter(Mandatory = $false)]
		[switch]$SkipUserRemoval,
		[Parameter(Mandatory = $false)]
		[switch]$SkipCompatibilityLevel,
		[Parameter(Mandatory = $false)]
		[switch]$SkipTargetRecoveryTime,
		[Parameter(Mandatory = $false)]
		[switch]$SkipOwner,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		if (-not $OutputPath) { $OutputPath = Join-Path (Get-sqmDefaultOutputPath) 'DatabaseStandardization' }

		# Bezeichner fuer T-SQL: [Name] mit verdoppelter schliessender Klammer. Bewusst String.Replace
		# statt -replace: im Ersetzungstext von -replace ist '\]' kein Escape, sondern landet
		# woertlich im Ergebnis.
		function ConvertTo-QuotedName([string]$Name) { '[' + $Name.Replace(']', ']]') + ']' }
		function ConvertTo-SqlLiteral([string]$Text) { "N'" + $Text.Replace("'", "''") + "'" }

		Invoke-sqmLogging -Message ("Starte " + $functionName) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			Invoke-sqmLogging -Message ("[$instance] Verarbeite Instanz") -FunctionName $functionName -Level "INFO"
			$instanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()

			try
			{
				$connParams = @{
					SqlInstance   = $instance
					SqlCredential = $SqlCredential
				}

				# -------------------------------------------------------------------
				# 1. Instanzwerte: Kompatibilitaetsstufe der Serverversion, sa-Name
				# -------------------------------------------------------------------
				# @@MICROSOFTVERSION / 0x01000000 = Hauptversion (11 = 2012 ... 16 = 2022, 17 = 2025).
				# SERVERPROPERTY('ProductMajorVersion') gibt es erst ab spaeten 2012-Builds.
				$instanceInfo = Invoke-DbaQuery @connParams -Database 'master' -EnableException -ErrorAction Stop -Query @"
SELECT (@@MICROSOFTVERSION / 16777216) * 10 AS ServerCompatibilityLevel,
       (SELECT name FROM sys.server_principals WHERE sid = 0x01) AS SaName
"@
				$serverCompatLevel = [int]$instanceInfo.ServerCompatibilityLevel
				$saName = [string]$instanceInfo.SaName
				if ([string]::IsNullOrWhiteSpace($saName) -and -not $SkipOwner)
				{
					throw "sa-Login (SID 0x01) konnte nicht ermittelt werden."
				}
				Invoke-sqmLogging -Message ("[$instance] Server-Kompatibilitaetsstufe: $serverCompatLevel, sa-Login: '$saName'") -FunctionName $functionName -Level "INFO"

				# -------------------------------------------------------------------
				# 2. Datenbanken ermitteln
				# -------------------------------------------------------------------
				$dbRows = @(Invoke-DbaQuery @connParams -Database 'master' -EnableException -ErrorAction Stop -Query @"
SELECT d.name,
       d.state_desc,
       CAST(d.is_read_only AS int) AS is_read_only,
       d.compatibility_level,
       d.target_recovery_time_in_seconds,
       CAST(CASE WHEN d.owner_sid = 0x01 THEN 1 ELSE 0 END AS int) AS owner_is_sa,
       ISNULL(SUSER_SNAME(d.owner_sid), '<unbekannt: ' + CONVERT(varchar(200), d.owner_sid, 1) + '>') AS owner_name,
       CAST(CASE WHEN d.replica_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM sys.dm_hadr_availability_replica_states ars
                WHERE ars.replica_id = d.replica_id AND ars.role = 2)
            THEN 1 ELSE 0 END AS int) AS is_ag_secondary
FROM sys.databases d
WHERE d.database_id > 4
  AND d.source_database_id IS NULL
ORDER BY d.name
"@)

				if ($Database.Count -gt 0)
				{
					$dbRows = @($dbRows | Where-Object {
							$dbName = $_.name
							$match = $false
							foreach ($pattern in $Database) { if ($dbName -eq $pattern -or $dbName -like $pattern) { $match = $true } }
							$match
						})
				}
				if ($ExcludeDatabase.Count -gt 0)
				{
					$dbRows = @($dbRows | Where-Object {
							$dbName = $_.name
							$exclude = $false
							foreach ($pattern in $ExcludeDatabase) { if ($dbName -eq $pattern -or $dbName -like $pattern) { $exclude = $true } }
							-not $exclude
						})
				}

				if ($dbRows.Count -eq 0)
				{
					Invoke-sqmLogging -Message ("[$instance] Keine Datenbanken nach Filterung gefunden.") -FunctionName $functionName -Level "WARNING"
					continue
				}
				Invoke-sqmLogging -Message ("[$instance] $($dbRows.Count) Datenbank(en) zu pruefen.") -FunctionName $functionName -Level "INFO"

				# -------------------------------------------------------------------
				# 3. Pro Datenbank die fuenf Schritte
				# -------------------------------------------------------------------
				foreach ($db in $dbRows)
				{
					$dbName = [string]$db.name
					$dbQuoted = ConvertTo-QuotedName $dbName

					# Ergebniszeile anlegen, protokollieren, sammeln
					$addRow = {
						param ($Step, $Target, $OldValue, $NewValue, $Status, $Message)
						$row = [PSCustomObject]@{
							SqlInstance = $instance
							Database    = $dbName
							Step        = $Step
							Target      = $Target
							OldValue    = $OldValue
							NewValue    = $NewValue
							Status      = $Status
							Message     = $Message
						}
						$instanceResults.Add($row)
						$level = switch ($Status) { 'Failed' { 'ERROR' } 'OK' { 'INFO' } default { 'DEBUG' } }
						Invoke-sqmLogging -Message ("[$instance] ${dbName}: $Step $Target - $Status. $Message") -FunctionName $functionName -Level $level
					}

					# Nicht bearbeitbare Datenbanken als Ganzes ueberspringen
					$skipReason = $null
					if ($db.state_desc -ne 'ONLINE') { $skipReason = "Datenbank ist nicht ONLINE ($($db.state_desc))." }
					elseif ([int]$db.is_ag_secondary -eq 1) { $skipReason = "Secondary-Replikat einer Verfuegbarkeitsgruppe - auf dem Primary ausfuehren." }
					elseif ([int]$db.is_read_only -eq 1) { $skipReason = "Datenbank ist READ_ONLY." }
					if ($skipReason)
					{
						& $addRow 'Database' $dbName $null $null 'Skipped' $skipReason
						continue
					}

					$dbParams = $connParams + @{ Database = $dbName }
					# Unter -WhatIf bleiben verwaiste User ungebunden; Schritt 2 wuerde sie sonst
					# faelschlich als "wuerde entfernt" melden.
					$whatIfRemapped = New-Object 'System.Collections.Generic.HashSet[string]'

					# ---- Schritt 1: verwaiste User per Name wieder an ihren Login binden ----
					if (-not $SkipOrphanRepair)
					{
						try
						{
							# authentication_type 1 = INSTANCE (SQL-Login), 3 = WINDOWS. COLLATE: Namen aus der
							# Datenbank und aus master koennen unterschiedliche Sortierungen haben.
							$orphans = @(Invoke-DbaQuery @dbParams -EnableException -ErrorAction Stop -Query @"
SELECT dp.name AS UserName,
       sp.name AS LoginName,
       (SELECT TOP (1) d2.name FROM sys.database_principals d2 WHERE d2.sid = sp.sid) AS MappedUser
FROM sys.database_principals dp
INNER JOIN sys.server_principals sp
        ON sp.name COLLATE DATABASE_DEFAULT = dp.name COLLATE DATABASE_DEFAULT
       AND sp.type = dp.type
WHERE dp.type IN ('S', 'U', 'G')
  AND dp.authentication_type IN (1, 3)
  AND dp.principal_id > 4
  AND NOT EXISTS (SELECT 1 FROM sys.server_principals s2 WHERE s2.sid = dp.sid)
ORDER BY dp.name
"@)
							foreach ($o in $orphans)
							{
								$userName = [string]$o.UserName
								$loginName = [string]$o.LoginName
								if ($o.MappedUser -isnot [System.DBNull] -and -not [string]::IsNullOrEmpty([string]$o.MappedUser))
								{
									& $addRow 'FixOrphanUser' $userName $null $loginName 'Failed' "Login '$loginName' ist in dieser Datenbank bereits dem User '$($o.MappedUser)' zugeordnet - manuell klaeren."
									if ($EnableException) { throw "Login '$loginName' ist in '$dbName' bereits dem User '$($o.MappedUser)' zugeordnet." }
									continue
								}
								if ($PSCmdlet.ShouldProcess("[$instance] $dbName", "User '$userName' an Login '$loginName' binden"))
								{
									try
									{
										Invoke-DbaQuery @dbParams -EnableException -ErrorAction Stop -Query ("ALTER USER " + (ConvertTo-QuotedName $userName) + " WITH LOGIN = " + (ConvertTo-QuotedName $loginName) + ";")
										& $addRow 'FixOrphanUser' $userName $null $loginName 'OK' "User an Login '$loginName' gebunden."
									}
									catch
									{
										& $addRow 'FixOrphanUser' $userName $null $loginName 'Failed' $_.Exception.Message
										if ($EnableException) { throw }
									}
								}
								else
								{
									& $addRow 'FixOrphanUser' $userName $null $loginName 'WhatIf' "Wuerde an Login '$loginName' gebunden."
									[void]$whatIfRemapped.Add($userName)
								}
							}
						}
						catch
						{
							if ($EnableException) { throw }
							& $addRow 'FixOrphanUser' $null $null $null 'Failed' $_.Exception.Message
						}
					}

					# ---- Schritt 2: User ohne Login entfernen ----
					if (-not $SkipUserRemoval)
					{
						try
						{
							$includeWithoutLogin = if ($IncludeUsersWithoutLogin) { 1 } else { 0 }
							# authentication_type 0 = NONE (WITHOUT LOGIN) nur auf Wunsch; 2 = DATABASE
							# (Contained User) und Zertifikat-/Schluessel-User (type C/K) nie.
							$candidates = @(Invoke-DbaQuery @dbParams -EnableException -ErrorAction Stop -Query @"
SELECT dp.name AS UserName,
       dp.type AS UserType,
       dp.authentication_type AS AuthType,
       SUSER_SNAME(dp.sid) AS WindowsAccount
FROM sys.database_principals dp
WHERE dp.type IN ('S', 'U', 'G')
  AND dp.principal_id > 4
  AND dp.name NOT LIKE '##%'
  AND NOT EXISTS (SELECT 1 FROM sys.server_principals sp WHERE sp.sid = dp.sid)
  AND (dp.authentication_type IN (1, 3) OR ($includeWithoutLogin = 1 AND dp.authentication_type = 0 AND dp.type = 'S'))
ORDER BY dp.name
"@)
							foreach ($c in $candidates)
							{
								$userName = [string]$c.UserName
								if ($whatIfRemapped.Contains($userName)) { continue }
								$userType = [string]$c.UserType
								$reason = if ([int]$c.AuthType -eq 0) { 'User WITHOUT LOGIN' } else { 'kein Login zur SID' }

								# Windows-User ohne eigenen Login koennen trotzdem ueber einen Gruppen-Login
								# auf den Server kommen - dann ist der Datenbank-User die Berechtigung und
								# darf nicht weg. xp_logininfo liefert in dem Fall den Zugriffspfad; kennt
								# Windows das Konto nicht mehr, wirft es einen Fehler (= wirklich verwaist).
								if ($userType -eq 'U' -and $c.WindowsAccount -isnot [System.DBNull] -and -not [string]::IsNullOrEmpty([string]$c.WindowsAccount))
								{
									$access = $null
									try
									{
										$access = @(Invoke-DbaQuery @connParams -Database 'master' -EnableException -ErrorAction Stop `
												-Query ("EXEC master.sys.xp_logininfo @acctname = " + (ConvertTo-SqlLiteral ([string]$c.WindowsAccount)) + ", @option = 'all';"))
									}
									catch
									{
										$access = $null
									}
									if ($access -and $access.Count -gt 0)
									{
										$paths = (@($access | ForEach-Object { $_.'permission path' } | Where-Object { $_ -isnot [System.DBNull] -and $_ }) | Select-Object -Unique) -join ', '
										& $addRow 'RemoveUserWithoutLogin' $userName $null $null 'Skipped' "Kein eigener Login, aber Serverzugriff ueber Windows-Gruppe ($paths) - bleibt erhalten."
										continue
									}
								}

								# Besessene Schemas und Rollen nur fuer die Meldung ermitteln
								$owned = @(Invoke-DbaQuery @dbParams -EnableException -ErrorAction Stop -Query @"
SELECT 'Schema' AS Kind, s.name AS Name FROM sys.schemas s WHERE s.principal_id = DATABASE_PRINCIPAL_ID($(ConvertTo-SqlLiteral $userName))
UNION ALL
SELECT 'Rolle', r.name FROM sys.database_principals r WHERE r.type = 'R' AND r.owning_principal_id = DATABASE_PRINCIPAL_ID($(ConvertTo-SqlLiteral $userName))
"@)
								$ownedText = if ($owned.Count -gt 0) { " Besitz an dbo uebertragen: " + ((@($owned | ForEach-Object { "$($_.Kind) $($_.Name)" })) -join ', ') + "." } else { '' }

								if ($PSCmdlet.ShouldProcess("[$instance] $dbName", "User '$userName' entfernen ($reason)"))
								{
									# Besitzuebergabe und DROP in einer Transaktion: scheitert der DROP (z.B. weil
									# der User noch andere Objekte besitzt), bleibt alles wie vorher.
									$dropSql = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @uid int = DATABASE_PRINCIPAL_ID($(ConvertTo-SqlLiteral $userName));
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(name) + N' TO dbo;' FROM sys.schemas WHERE principal_id = @uid;
SELECT @sql = @sql + N'ALTER AUTHORIZATION ON ROLE::' + QUOTENAME(name) + N' TO dbo;' FROM sys.database_principals WHERE type = 'R' AND owning_principal_id = @uid;
IF @sql <> N'' EXEC (@sql);
DROP USER $(ConvertTo-QuotedName $userName);
COMMIT TRANSACTION;
"@
									try
									{
										Invoke-DbaQuery @dbParams -EnableException -ErrorAction Stop -Query $dropSql
										& $addRow 'RemoveUserWithoutLogin' $userName $null $null 'OK' ("Entfernt ($reason)." + $ownedText)
									}
									catch
									{
										& $addRow 'RemoveUserWithoutLogin' $userName $null $null 'Failed' $_.Exception.Message
										if ($EnableException) { throw }
									}
								}
								else
								{
									& $addRow 'RemoveUserWithoutLogin' $userName $null $null 'WhatIf' ("Wuerde entfernt ($reason)." + $ownedText)
								}
							}
						}
						catch
						{
							if ($EnableException) { throw }
							& $addRow 'RemoveUserWithoutLogin' $null $null $null 'Failed' $_.Exception.Message
						}
					}

					# ---- Schritt 3: Kompatibilitaetsstufe auf Serverniveau anheben ----
					if (-not $SkipCompatibilityLevel)
					{
						$currentCompat = [int]$db.compatibility_level
						if ($currentCompat -ge $serverCompatLevel)
						{
							& $addRow 'CompatibilityLevel' $dbName $currentCompat $currentCompat 'Skipped' "Bereits auf Serverniveau."
						}
						elseif ($PSCmdlet.ShouldProcess("[$instance] $dbName", "Kompatibilitaetsstufe $currentCompat -> $serverCompatLevel"))
						{
							try
							{
								Invoke-DbaQuery @connParams -Database 'master' -EnableException -ErrorAction Stop -Query "ALTER DATABASE $dbQuoted SET COMPATIBILITY_LEVEL = $serverCompatLevel;"
								& $addRow 'CompatibilityLevel' $dbName $currentCompat $serverCompatLevel 'OK' "Angehoben."
							}
							catch
							{
								& $addRow 'CompatibilityLevel' $dbName $currentCompat $serverCompatLevel 'Failed' $_.Exception.Message
								if ($EnableException) { throw }
							}
						}
						else
						{
							& $addRow 'CompatibilityLevel' $dbName $currentCompat $serverCompatLevel 'WhatIf' "Wuerde angehoben."
						}
					}

					# ---- Schritt 4: TARGET_RECOVERY_TIME ----
					if (-not $SkipTargetRecoveryTime)
					{
						$currentTrt = [int]$db.target_recovery_time_in_seconds
						if ($currentTrt -eq $TargetRecoveryTimeSeconds)
						{
							& $addRow 'TargetRecoveryTime' $dbName $currentTrt $currentTrt 'Skipped' "Bereits $TargetRecoveryTimeSeconds Sekunden."
						}
						elseif ($PSCmdlet.ShouldProcess("[$instance] $dbName", "TARGET_RECOVERY_TIME $currentTrt -> $TargetRecoveryTimeSeconds Sekunden"))
						{
							try
							{
								Invoke-DbaQuery @connParams -Database 'master' -EnableException -ErrorAction Stop -Query "ALTER DATABASE $dbQuoted SET TARGET_RECOVERY_TIME = $TargetRecoveryTimeSeconds SECONDS;"
								& $addRow 'TargetRecoveryTime' $dbName $currentTrt $TargetRecoveryTimeSeconds 'OK' "Gesetzt."
							}
							catch
							{
								& $addRow 'TargetRecoveryTime' $dbName $currentTrt $TargetRecoveryTimeSeconds 'Failed' $_.Exception.Message
								if ($EnableException) { throw }
							}
						}
						else
						{
							& $addRow 'TargetRecoveryTime' $dbName $currentTrt $TargetRecoveryTimeSeconds 'WhatIf' "Wuerde gesetzt."
						}
					}

					# ---- Schritt 5: Owner sa ----
					if (-not $SkipOwner)
					{
						$currentOwner = [string]$db.owner_name
						if ([int]$db.owner_is_sa -eq 1)
						{
							& $addRow 'DatabaseOwner' $dbName $currentOwner $saName 'Skipped' "Owner ist bereits sa."
						}
						elseif ($PSCmdlet.ShouldProcess("[$instance] $dbName", "Owner '$currentOwner' -> '$saName'"))
						{
							try
							{
								Invoke-DbaQuery @connParams -Database 'master' -EnableException -ErrorAction Stop -Query ("ALTER AUTHORIZATION ON DATABASE::$dbQuoted TO " + (ConvertTo-QuotedName $saName) + ";")
								& $addRow 'DatabaseOwner' $dbName $currentOwner $saName 'OK' "Owner gesetzt."
							}
							catch
							{
								& $addRow 'DatabaseOwner' $dbName $currentOwner $saName 'Failed' $_.Exception.Message
								if ($EnableException) { throw }
							}
						}
						else
						{
							& $addRow 'DatabaseOwner' $dbName $currentOwner $saName 'WhatIf' "Wuerde gesetzt."
						}
					}
				}
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': " + $_.Exception.Message
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { Write-Error $errMsg; return }
				Write-Warning $errMsg
			}
			finally
			{
				# -------------------------------------------------------------------
				# 4. Protokoll schreiben (auch nach einem Abbruch: was bis dahin
				#    geaendert wurde, muss nachvollziehbar sein)
				# -------------------------------------------------------------------
				if (@($instanceResults | Where-Object { $_.Status -in 'OK', 'Failed' }).Count -gt 0)
				{
					try
					{
						if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
						$safeInst = $instance -replace '[\\/:]', '_'
						$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
						$csvFile = Join-Path $OutputPath ("Standardization_" + $safeInst + "_" + $stamp + ".csv")
						$instanceResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force -WhatIf:$false
						Copy-sqmToCentralPath -Path @($csvFile)
						Invoke-sqmLogging -Message ("[$instance] Protokoll: $csvFile") -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						Invoke-sqmLogging -Message ("[$instance] Protokoll konnte nicht geschrieben werden: " + $_.Exception.Message) -FunctionName $functionName -Level "WARNING"
					}
				}

				$okCount = @($instanceResults | Where-Object Status -eq 'OK').Count
				$failCount = @($instanceResults | Where-Object Status -eq 'Failed').Count
				$summary = "[$instance] Geaendert: $okCount, Fehler: $failCount, Zeilen gesamt: $($instanceResults.Count)"
				Invoke-sqmLogging -Message $summary -FunctionName $functionName -Level "INFO"
				Write-Verbose $summary

				foreach ($r in $instanceResults) { $allResults.Add($r) }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen. " + $allResults.Count + " Aktion(en).") -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
