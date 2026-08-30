<#
.SYNOPSIS
    Creates (if missing) and starts a dedicated Extended Events session that covers the
    "audit problem": login success/failure, database create/drop, and schema/metadata changes.

.DESCRIPTION
    SQL Server has no single built-in mechanism that answers "who connected, who created or
    dropped a database, who changed a table" out of the box. SQL Server Audit does, but needs
    Standard 2016 SP1+/Enterprise and carries its own operational risk (ON_FAILURE = SHUTDOWN
    can take the instance down). This function covers the same ground with a plain Extended
    Events session, available on every edition since SQL Server 2008, with the categories
    selectable independently:

      -FailedLogins       sqlserver.error_reported, filtered to error 18456.
      -SuccessfulLogins   sqlserver.login (fires only on a successful connection).
      -DatabaseCreated    sqlserver.database_created.
      -DatabaseDropped    sqlserver.database_dropped.
      -MetadataChanges    sqlserver.object_created / object_altered / object_deleted
                          (schema-level DDL: tables, views, procedures, and the rest).

    Every event collects the standard forensic actions: database_name, nt_username,
    server_principal_name, session_id, sql_text, client_app_name, client_hostname, username -
    the same fields Invoke-sqmExtendedEvents -Read already knows how to surface, so reading
    this session back needs no new function:

        Invoke-sqmExtendedEvents -SqlInstance SQL01 -SessionName sqm_AuditSession -Read

    -MetadataChanges specifics, verified live rather than assumed:
      - object_created/altered/deleted each fire twice per statement (start and commit/
        rollback). The session filters to the commit phase (ddl_phase = 1) so every change
        is counted once, not twice.
      - By default, temp objects ('#...') and SQL Server's own auto-generated statistics
        objects ('_WA_Sys_...', created automatically by many CREATE TABLE/ALTER TABLE
        statements) are excluded - neither is a schema change anyone asked to audit. Use
        -IncludeSystemGeneratedObjects to capture them anyway.
      - -TargetDatabase scopes -MetadataChanges to specific databases via the session's
        collected database_name action. This action reflects the connection's database
        context, which is exactly the scoped database for object-level DDL, so it works
        correctly here - verified live: an unrelated database's DDL is not captured when
        -TargetDatabase is set.

    -DatabaseCreated/-DatabaseDropped are always instance-wide and CANNOT be scoped with
    -TargetDatabase. This was tested, not assumed: at the moment either event fires, neither
    the collected database_name action (it reflects the connecting session's *existing*
    database context, e.g. master, not the database being created or dropped) nor a direct
    reference to the event's own database_name field produces a working filter - both were
    tried live and both silently matched nothing. If -TargetDatabase is supplied without
    -MetadataChanges, this function logs a warning rather than silently ignoring the request.

    Like Register-sqmBlockedProcessMonitor, this function never alters an already-existing
    session's event definition, even if different switches are passed on a later call - it
    only ensures the session exists and is running. Changing which categories are captured
    means dropping the session first (Invoke-sqmExtendedEvents -Stop -Drop -SessionName ...)
    and registering it again.

    Target: package0.ring_buffer (in-memory, ~4 MB, wraps around) by default. With
    -IncludeFileTarget, an additional package0.event_file target is added for longer
    retention under the instance's own error log directory unless -FileTargetPath is given.
    STARTUP_STATE=ON, so the session survives an instance restart.

.PARAMETER SqlInstance
    SQL Server instance. Default: $env:COMPUTERNAME.

.PARAMETER SqlCredential
    PSCredential for SQL authentication. Default: Windows auth.

.PARAMETER SessionName
    Name of the Extended Events session. Default: 'sqm_AuditSession'.

.PARAMETER FailedLogins
    Capture failed login attempts (error 18456).

.PARAMETER SuccessfulLogins
    Capture successful logins.

.PARAMETER DatabaseCreated
    Capture CREATE DATABASE. Always instance-wide, see .DESCRIPTION.

.PARAMETER DatabaseDropped
    Capture DROP DATABASE. Always instance-wide, see .DESCRIPTION.

.PARAMETER MetadataChanges
    Capture schema-level DDL (object created/altered/deleted) across the instance, or scoped
    to -TargetDatabase.

.PARAMETER All
    Shorthand for enabling every category above.

.PARAMETER TargetDatabase
    Database name(s) to scope -MetadataChanges to. Without this, metadata changes across every
    database on the instance are captured. Has no effect on -DatabaseCreated/-DatabaseDropped.

.PARAMETER IncludeSystemGeneratedObjects
    Also capture temp objects ('#...') and auto-generated statistics objects ('_WA_Sys_...')
    under -MetadataChanges. Excluded by default as noise, not schema changes.

.PARAMETER IncludeFileTarget
    Also adds a package0.event_file target for retention beyond the ring buffer's limited
    in-memory window. Only takes effect when the session is first created.

.PARAMETER FileTargetPath
    Directory for the event_file target (only used with -IncludeFileTarget). Default: the
    instance's own error log directory.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.OUTPUTS
    PSCustomObject: SqlInstance, SessionName, Action, Categories, Message

.EXAMPLE
    Register-sqmAuditSession -SqlInstance "SQL01" -FailedLogins -SuccessfulLogins

    Login auditing only.

.EXAMPLE
    Register-sqmAuditSession -SqlInstance "SQL01" -All -IncludeFileTarget

    Every category, with durable file-based retention.

.EXAMPLE
    Register-sqmAuditSession -SqlInstance "SQL01" -MetadataChanges -TargetDatabase "Orders", "Billing"

    Schema-change auditing scoped to two databases, nothing else.

.EXAMPLE
    Register-sqmAuditSession -SqlInstance "SQL01" -All
    Invoke-sqmExtendedEvents -SqlInstance "SQL01" -SessionName sqm_AuditSession -Read

    Set up, then read back with the module's existing Extended Events reader.

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Permissions: ALTER ANY EVENT SESSION (sysadmin covers this).
    Companion reader: Invoke-sqmExtendedEvents -Read -SessionName <SessionName>.
#>
function Register-sqmAuditSession
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$SessionName = 'sqm_AuditSession',
		[Parameter(Mandatory = $false)]
		[switch]$FailedLogins,
		[Parameter(Mandatory = $false)]
		[switch]$SuccessfulLogins,
		[Parameter(Mandatory = $false)]
		[switch]$DatabaseCreated,
		[Parameter(Mandatory = $false)]
		[switch]$DatabaseDropped,
		[Parameter(Mandatory = $false)]
		[switch]$MetadataChanges,
		[Parameter(Mandatory = $false)]
		[switch]$All,
		[Parameter(Mandatory = $false)]
		[string[]]$TargetDatabase = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemGeneratedObjects,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeFileTarget,
		[Parameter(Mandatory = $false)]
		[string]$FileTargetPath,
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
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		$wantFailedLogins = [bool]($FailedLogins -or $All)
		$wantSuccessLogins = [bool]($SuccessfulLogins -or $All)
		$wantDbCreated = [bool]($DatabaseCreated -or $All)
		$wantDbDropped = [bool]($DatabaseDropped -or $All)
		$wantMetadata = [bool]($MetadataChanges -or $All)

		if (-not ($wantFailedLogins -or $wantSuccessLogins -or $wantDbCreated -or $wantDbDropped -or $wantMetadata))
		{
			$msg = "Mindestens eine Kategorie muss gewaehlt werden: -FailedLogins, -SuccessfulLogins, -DatabaseCreated, -DatabaseDropped, -MetadataChanges, oder -All."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		if ($TargetDatabase.Count -gt 0 -and -not $wantMetadata)
		{
			Invoke-sqmLogging -Message "-TargetDatabase wirkt nur auf -MetadataChanges (nicht auf -DatabaseCreated/-DatabaseDropped, siehe .DESCRIPTION) - hier ohne Effekt, da -MetadataChanges nicht gewaehlt ist." -FunctionName $functionName -Level "WARNING"
		}

		$stdActions = "ACTION(sqlserver.database_name,sqlserver.nt_username,sqlserver.server_principal_name,sqlserver.session_id,sqlserver.sql_text,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.username)"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$existingSession = Invoke-DbaQuery @connParams -Database master `
				-Query "SELECT 1 AS Found FROM sys.server_event_sessions WHERE name = N'$SessionName'" -ErrorAction Stop

			$categories = [System.Collections.Generic.List[string]]::new()
			if ($wantFailedLogins) { $categories.Add('FailedLogins') }
			if ($wantSuccessLogins) { $categories.Add('SuccessfulLogins') }
			if ($wantDbCreated) { $categories.Add('DatabaseCreated') }
			if ($wantDbDropped) { $categories.Add('DatabaseDropped') }
			if ($wantMetadata) { $categories.Add('MetadataChanges') }

			if (-not $existingSession)
			{
				# --- Metadaten-Praedikat: ddl_phase=Commit + optionaler Rausch-Ausschluss + optionales DB-Scoping ---
				$metaPredicateParts = [System.Collections.Generic.List[string]]::new()
				$metaPredicateParts.Add('([ddl_phase]=(1))')
				if (-not $IncludeSystemGeneratedObjects)
				{
					$metaPredicateParts.Add("(NOT [sqlserver].[like_i_sql_unicode_string]([object_name],N'#%'))")
					$metaPredicateParts.Add("(NOT [sqlserver].[like_i_sql_unicode_string]([object_name],N'_WA_Sys_%'))")
				}
				if ($TargetDatabase.Count -gt 0)
				{
					$dbOr = ($TargetDatabase | ForEach-Object { "[sqlserver].[database_name]=N'$($_.Replace("'", "''"))'" }) -join ' OR '
					$metaPredicateParts.Add("($dbOr)")
				}
				$metaPredicate = $metaPredicateParts -join ' AND '

				$eventClauses = [System.Collections.Generic.List[string]]::new()
				if ($wantFailedLogins)
				{
					$eventClauses.Add("ADD EVENT sqlserver.error_reported($stdActions WHERE ([error_number]=(18456)))")
				}
				if ($wantSuccessLogins)
				{
					$eventClauses.Add("ADD EVENT sqlserver.login($stdActions)")
				}
				if ($wantDbCreated)
				{
					$eventClauses.Add("ADD EVENT sqlserver.database_created($stdActions)")
				}
				if ($wantDbDropped)
				{
					$eventClauses.Add("ADD EVENT sqlserver.database_dropped($stdActions)")
				}
				if ($wantMetadata)
				{
					foreach ($ev in @('object_created', 'object_altered', 'object_deleted'))
					{
						$eventClauses.Add("ADD EVENT sqlserver.$ev($stdActions WHERE $metaPredicate)")
					}
				}

				$targetSql = "ADD TARGET package0.ring_buffer(SET max_memory=4096)"
				if ($IncludeFileTarget)
				{
					$fileDir = $FileTargetPath
					if (-not $fileDir)
					{
						$dirRow = Invoke-DbaQuery @connParams -Database master -Query @"
DECLARE @ErrLog NVARCHAR(260) = CAST(SERVERPROPERTY('ErrorLogFileName') AS NVARCHAR(260));
SELECT LEFT(@ErrLog, LEN(@ErrLog) - CHARINDEX('\', REVERSE(@ErrLog))) AS ErrorLogDir;
"@
						$fileDir = if ($dirRow) { $dirRow.ErrorLogDir } else { $null }
					}
					if ($fileDir)
					{
						$fileDirSql = $fileDir.Replace("'", "''")
						$targetSql += ",`nADD TARGET package0.event_file(SET filename=N'$fileDirSql\$SessionName.xel', max_file_size=50, max_rollover_files=5)"
					}
					else
					{
						Invoke-sqmLogging -Message "[$SqlInstance] Konnte ErrorLog-Verzeichnis fuer den File-Target nicht ermitteln - nur Ring-Buffer wird angelegt." -FunctionName $functionName -Level "WARNING"
					}
				}

				$createSql = "CREATE EVENT SESSION [$SessionName] ON SERVER`n" + ($eventClauses -join ",`n") + "`n$targetSql`nWITH (MAX_MEMORY=4096KB, EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY=5 SECONDS, STARTUP_STATE=ON)"

				$actionMsg = "Lege Extended-Events-Session '$SessionName' an ($($categories -join ', '))"
				if ($PSCmdlet.ShouldProcess($SqlInstance, $actionMsg))
				{
					Invoke-DbaQuery @connParams -Database master -Query $createSql -ErrorAction Stop
					Invoke-DbaQuery @connParams -Database master -Query "ALTER EVENT SESSION [$SessionName] ON SERVER STATE = START;" -ErrorAction Stop
					Invoke-sqmLogging -Message "[$SqlInstance] Session '$SessionName' angelegt und gestartet ($($categories -join ', '))." -FunctionName $functionName -Level "INFO"
					return [PSCustomObject]@{
						SqlInstance = $SqlInstance
						SessionName = $SessionName
						Action	    = 'Created'
						Categories  = $categories.ToArray()
						Message	    = "Session '$SessionName' wurde neu angelegt und gestartet."
					}
				}
				else
				{
					return [PSCustomObject]@{
						SqlInstance = $SqlInstance
						SessionName = $SessionName
						Action	    = 'WhatIfSkipped'
						Categories  = $categories.ToArray()
						Message	    = "WhatIf: Session '$SessionName' wuerde angelegt werden."
					}
				}
			}
			else
			{
				Invoke-sqmLogging -Message "[$SqlInstance] Session '$SessionName' existiert bereits - die uebergebenen Kategorien-Switches wirken nicht auf eine vorhandene Session (siehe .DESCRIPTION). Zum Aendern: Invoke-sqmExtendedEvents -Stop -Drop -SessionName '$SessionName', dann erneut registrieren." -FunctionName $functionName -Level "INFO"

				$isRunning = Invoke-DbaQuery @connParams -Database master `
					-Query "SELECT 1 AS Running FROM sys.dm_xe_sessions WHERE name = N'$SessionName'" -ErrorAction Stop

				if (-not $isRunning)
				{
					$actionMsg = "Starte vorhandene, aber gestoppte Session '$SessionName'"
					if ($PSCmdlet.ShouldProcess($SqlInstance, $actionMsg))
					{
						Invoke-DbaQuery @connParams -Database master -Query "ALTER EVENT SESSION [$SessionName] ON SERVER STATE = START;" -ErrorAction Stop
						Invoke-sqmLogging -Message "[$SqlInstance] Session '$SessionName' war gestoppt und wurde gestartet." -FunctionName $functionName -Level "INFO"
						return [PSCustomObject]@{
							SqlInstance = $SqlInstance
							SessionName = $SessionName
							Action	    = 'Started'
							Categories  = $categories.ToArray()
							Message	    = "Session '$SessionName' existierte bereits, war aber gestoppt - jetzt gestartet."
						}
					}
					else
					{
						return [PSCustomObject]@{
							SqlInstance = $SqlInstance
							SessionName = $SessionName
							Action	    = 'WhatIfSkipped'
							Categories  = $categories.ToArray()
							Message	    = "WhatIf: Session '$SessionName' wuerde gestartet werden."
						}
					}
				}

				return [PSCustomObject]@{
					SqlInstance = $SqlInstance
					SessionName = $SessionName
					Action	    = 'Unchanged'
					Categories  = $categories.ToArray()
					Message	    = "Session '$SessionName' existiert bereits und laeuft."
				}
			}
		}
		catch
		{
			$errMsg = "Fehler beim Anlegen/Starten von '$SessionName': $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}
}
