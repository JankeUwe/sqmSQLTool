<#
.SYNOPSIS
    Synchronizes logins across all replicas of an AlwaysOn Availability Group.

.DESCRIPTION
    Two modes (-SyncMode):

    Union (default since v1.9.191.0)
    Logins are not part of the AG, and the primary role says nothing about where a login was
    created last. If a login is created on A and the AG fails over to B before the next sync, a
    primary->secondary sync never finds it: it exists only on the (now) secondary. Union mode
    therefore reads ALL replicas:
    - A login that exists on any replica is created on every replica that lacks it (SID and
      password hash included, never DROP). The direction does not depend on the primary role.
    - Tombstones: each replica keeps its last seen login set in master.dbo.sqmLoginSyncState. A
      login that was on a replica before and is gone now was dropped there; it is NOT recreated
      but reported (event 9004). Once it is gone on all replicas, the entry is removed.
      -ResetTombstone '<login>' distributes such a login again.
    - First run (state table is created): secondaries get missing logins as before. Logins that
      are missing on the PRIMARY are not copied but marked as tombstone 'Baseline', so logins
      deliberately dropped on the primary in the past do not come back. Check the report.
    - Password changes (-HashChange Newest, default): same SQL login and SID, different
      password hash. The password set last wins (LOGINPROPERTY PasswordLastSetTime, converted to
      UTC per replica) and is applied with ALTER LOGIN ... WITH PASSWORD = <hash> HASHED, never
      DROP. CHECK_POLICY / CHECK_EXPIRATION are switched off for the change (HASHED is not allowed
      with CHECK_POLICY ON) and restored afterwards. If the two newest changes are less than
      60 seconds apart, the winner is unclear and the difference is only reported. Before the
      change, a rollback script with the old hashes is written to -BackupPath
      (LoginBackup_PasswordRollback_<replica>_<timestamp>.sql). -HashChange Report: only report.
    - Other conflicts (same name, different SID / default DB / language / disabled) are only
      reported (event 9004), never changed. -Force is ignored in this mode.
    - An unreachable replica is skipped (status Failed, event 9002) and caught up next run.

    Primary (behaviour up to v1.9.190.0)
    Copies logins from the primary to each secondary, with -Force also overwriting existing
    logins (DROP + CREATE). Logins that only exist on a secondary are never copied back.

    Process in Primary mode:
    1. Detect primary replica in the AG (role_desc = 'PRIMARY')
    2. Enumerate all secondary replicas
    3. For each secondary:
       - Connect and validate
       - Copy logins from primary via Copy-sqmLogins
       - Repair orphaned users (automatic)
       - Log result (Success/Failed/Skipped)
    4. Return summary with per-replica status

    Authentication:
    - All replicas use the same credentials (SqlCredential or SourceCredential/DestinationCredential)
    - If replicas are on different domains: use -SqlCredential with cross-domain account

    Error handling:
    - Replica connection failure: Logged as 'Failed', process continues to next replica
    - Login copy failure: Logged with error details, does not block other replicas
    - Orphan repair failure: Logged, does not block result return

    Logins excluded by default:
    - System logins (sa, ##MS_*, NT SERVICE\*, BUILTIN\*) - use -IncludeSystemLogins to include

.PARAMETER SqlInstance
    An instance of the AG (normally the primary). Default: $env:COMPUTERNAME

.PARAMETER SyncMode
    'Union' (default): missing logins in every direction, tombstones and conflicts only reported.
    'Primary': previous behaviour, primary -> secondaries, -Force overwrites existing logins.

.PARAMETER HashChange
    Union mode only. 'Newest' (default): a password changed on one replica is applied to the
    others (newest PasswordLastSetTime wins, ALTER LOGIN ... HASHED, rollback script first).
    'Report': differences are only reported.

.PARAMETER ResetTombstone
    Union mode only: login names (exact, no wildcards) whose tombstone is removed on all replicas
    before the sync, so they are distributed again. Use it after checking the report.

.PARAMETER AvailabilityGroupName
    Name of the Availability Group. If not specified, the first AG found on the instance is used.
    If multiple AGs exist: Warning is displayed, first AG is used. Specify explicitly to avoid ambiguity.

.PARAMETER SqlCredential
    PSCredential for all replicas (source and destination). Union mode uses one credential for all
    replicas: -SqlCredential, else -SourceCredential.

.PARAMETER SourceCredential
    PSCredential specifically for the primary replica (overrides -SqlCredential for source).

.PARAMETER DestinationCredential
    PSCredential for the secondary replicas (overrides -SqlCredential for destinations).

.PARAMETER Login
    Filters the copy operation to these login names (wildcards allowed).
    Without specification, all logins (after ExcludeLogin filter) are copied.

.PARAMETER ExcludeLogin
    Logins that should not be copied (wildcards allowed).
    Example: 'AppLogin_*', 'OldUser'.

.PARAMETER IncludeSystemLogins
    When set, system logins are also copied. Default: $false.

.PARAMETER AdjustAuthMode
    When set, automatically adjust target replica authentication mode to match primary if needed.

.PARAMETER RestartServiceIfRequired
    When set, restart the SQL Server service on secondary replicas if auth mode was changed.

.PARAMETER DisablePolicy
    Disable SQL Server policies on secondaries during the copy (default: $true).

.PARAMETER SkipSecondaryServers
    Comma-separated list of secondary instance names to skip (for maintenance).
    Example: 'SQL02', 'SQL03'

.PARAMETER Force
    Primary mode only (ignored with -SyncMode Union, conflicts are only reported there).
    Existing logins on secondaries are overwritten (password / language / default-db drift),
    not only new ones added. Default: $true - so a bare 'Sync-sqmLoginsToAlwaysOn' keeps the
    secondaries fully in sync. Opt out with -Force:$false (then only new logins are created).
    With SafeForceMode=true (default), all sysadmin logins, the SQL Agent account and system
    logins (sa via SID, NT SERVICE\*, etc.) are automatically excluded - no self-lockout.

.PARAMETER ForceIncludeOnly
    When Force is set with this parameter, only these logins are updated (whitelist).
    Overrides other login filters. System logins still excluded per SafeForceMode.
    Example: 'AppUser_*', 'ServiceAccount'

.PARAMETER ForceExclude
    Additional logins to exclude from Force operation (blacklist).
    Combined with SafeForceMode exclusions. Default: none.

.PARAMETER SafeForceMode
    When Force is set and SafeForceMode is true (default), automatically excludes dangerous logins:
    - sa (system admin)
    - SQL Agent Service Account
    - NT SERVICE\* (virtual accounts)
    - BUILTIN\* (Windows built-in accounts)
    Set to false ONLY if you fully understand the risks. Default: $true

.PARAMETER BackupLogins
    Creates a backup of existing logins on each secondary BEFORE applying -Force (rollback safety).
    Default: $true (paired with the Force default). Opt out with -BackupLogins:$false.
    Backup file: BackupPath\LoginBackup_<Secondary>_<Timestamp>.sql

.PARAMETER BackupPath
    Path where login backups are stored. Default: configured output path (Get-sqmDefaultOutputPath),
    i.e. C:\System\WinSrvLog\MSSQL unless overridden in the module config.
    Path is created if it doesn't exist.

.PARAMETER BackupRetentionDays
    When greater than 0, login backups (LoginBackup_*.sql) in BackupPath older than this many
    days are deleted after the sync. With -AuditAdOrphans, the LoginAudit_<instance>_* reports
    are cleaned up too. Default: 7. Set to 0 to disable cleanup (keep all files).

.PARAMETER AuditAdOrphans
    When set, runs an AD-orphan check (Invoke-sqmLoginAudit -CheckAdOrphans) on the primary AFTER
    the sync and reports Windows logins whose AD account no longer exists. Findings go to the log
    and a Windows Event Log warning (Source 'sqmSQLTool', EventId 9003) for Splunk.
    DETECTION ONLY - logins are NEVER deleted automatically. Requires the RSAT ActiveDirectory
    module and AD read rights. Default: $false.

.PARAMETER AdModuleAction
    Passed to Copy-sqmLogins: what to do if the ActiveDirectory module is missing
    (Install / Skip / Abort). Not set: Install interactively, Skip in an unattended session
    (SQL Agent job), because the RSAT installation can hang there without Windows Update.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning error status.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"
    Union mode: creates every login that is missing on any replica of ProdAG, reports conflicts
    and tombstones.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -WhatIf
    Shows what Union mode would copy and report, without changing anything.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -ResetTombstone 'AppUser'
    Distributes 'AppUser' again although it was dropped on one replica (or missing on the primary
    at the first run).

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -SyncMode Primary -Force:$false
    Previous behaviour: only primary -> secondaries, only new logins.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -IncludeSystemLogins
    Includes system logins in the sync.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -ExcludeLogin "TempUser_*"
    Skips logins matching the pattern.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -SyncMode Primary -Force -BackupLogins
    Updates existing logins (password changes) with backup before applying changes.

.EXAMPLE
    Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -SyncMode Primary `
        -Force -ForceIncludeOnly "AppUser_*", "ServiceDB_Account" -BackupLogins
    Updates only specific logins with backup enabled (safest -Force operation).

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Copy-sqmLogins, Get-sqmConfig
    Needs: sysadmin on all replicas
    Orphaned users are automatically repaired on all databases on each secondary.
#>
function Sync-sqmLoginsToAlwaysOn
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[string]$AvailabilityGroupName,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Union', 'Primary')]
		[string]$SyncMode = 'Union',

		[Parameter(Mandatory = $false)]
		[string[]]$ResetTombstone,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Newest', 'Report')]
		[string]$HashChange = 'Newest',

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$Login,

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[switch]$AdjustAuthMode,

		[Parameter(Mandatory = $false)]
		[switch]$RestartServiceIfRequired,

		[Parameter(Mandatory = $false)]
		[switch]$DisablePolicy = $true,

		[Parameter(Mandatory = $false)]
		[string[]]$SkipSecondaryServers,

		[Parameter(Mandatory = $false)]
		[switch]$Force = $true,

		[Parameter(Mandatory = $false)]
		[string[]]$ForceIncludeOnly,

		[Parameter(Mandatory = $false)]
		[string[]]$ForceExclude,

		[Parameter(Mandatory = $false)]
		[bool]$SafeForceMode = $true,

		[Parameter(Mandatory = $false)]
		[switch]$BackupLogins = $true,

		[Parameter(Mandatory = $false)]
		[string]$BackupPath = (Get-sqmDefaultOutputPath),

		[Parameter(Mandatory = $false)]
		[int]$BackupRetentionDays = 7,

		[Parameter(Mandatory = $false)]
		[switch]$AuditAdOrphans,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Install', 'Skip', 'Abort')]
		[string]$AdModuleAction,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException,

		[Parameter(Mandatory = $false)]
		[switch]$NoReport  # Skip backup file generation (for job context)
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		# Resolve credentials
		$srcCred = if ($SourceCredential) { $SourceCredential } else { $SqlCredential }
		$dstCred = if ($DestinationCredential) { $DestinationCredential } else { $SqlCredential }

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		try
		{
			# -------------------------------------------------------------------
			# 1. Resolve AvailabilityGroupName (if empty, use first AG)
			# -------------------------------------------------------------------
			$agQuery = @"
SELECT name FROM sys.availability_groups
ORDER BY name ASC
"@

			$allAgs = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $srcCred -Query $agQuery -ErrorAction Stop

			if (-not $allAgs)
			{
				throw "Keine Availability Groups auf $SqlInstance gefunden."
			}

			# Determine which AG to use
			if ([string]::IsNullOrWhiteSpace($AvailabilityGroupName))
			{
				$AvailabilityGroupName = if ($allAgs -is [System.Collections.Generic.List[PSCustomObject]]) { $allAgs[0].name } else { $allAgs.name }

				# Warn if multiple AGs exist
				if (@($allAgs).Count -gt 1)
				{
					$agList = ($allAgs | ForEach-Object { $_.name }) -join ', '
					Invoke-sqmLogging -Message "⚠️ WARNUNG: Mehrere Availability Groups gefunden [$agList]. Verwende erste: '$AvailabilityGroupName'. Tipp: Verwende -AvailabilityGroupName um AG explizit zu wählen." `
									  -FunctionName $functionName -Level 'WARNING'
				}
			}
			else
			{
				# Verify that specified AG exists
				$agExists = $allAgs | Where-Object { $_.name -eq $AvailabilityGroupName }
				if (-not $agExists)
				{
					throw "Availability Group '$AvailabilityGroupName' nicht gefunden auf $SqlInstance. Verfügbar: $(($allAgs | ForEach-Object { $_.name }) -join ', ')"
				}
			}

			Invoke-sqmLogging -Message "Verwende Availability Group: '$AvailabilityGroupName'" -FunctionName $functionName -Level 'INFO'

			# -------------------------------------------------------------------
			# 2. Get primary replica and list of secondaries
			# -------------------------------------------------------------------
			$query = @"
SELECT
    ar.replica_server_name,
    ar.availability_mode_desc,
    ISNULL(
        CASE WHEN ar.replica_server_name = ags.primary_replica THEN 'PRIMARY' ELSE 'SECONDARY' END,
        'RESOLVING'
    ) AS role_desc
FROM sys.availability_replicas ar
INNER JOIN sys.availability_groups ag
    ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_group_states ags
    ON ag.group_id = ags.group_id
WHERE ag.name = N'$AvailabilityGroupName'
ORDER BY role_desc ASC
"@

			$replicas = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $srcCred -Query $query -ErrorAction Stop

			if (-not $replicas)
			{
				throw "Keine Availability Group oder Replicas gefunden auf $SqlInstance für AG '$AvailabilityGroupName'"
			}

			$primaryReplica = $replicas | Where-Object { $_.role_desc -eq 'PRIMARY' }
			$secondaryReplicas = $replicas | Where-Object { $_.role_desc -eq 'SECONDARY' }

			if (-not $primaryReplica)
			{
				throw "Keine Primary Replica gefunden. Instanz ist nicht Primary in dieser AG."
			}

			$agName = if ($AvailabilityGroupName) { $AvailabilityGroupName } else { $replicas[0].name }

			Invoke-sqmLogging -Message "Primary Replica: $($primaryReplica.replica_server_name) | Secondary Replicas: $($secondaryReplicas.Count)" `
							  -FunctionName $functionName -Level 'INFO'

			if (-not $secondaryReplicas)
			{
				Invoke-sqmLogging -Message "Keine Secondary Replicas gefunden. AG hat nur 1 Replica." -FunctionName $functionName -Level 'WARNING'
			}

			# -------------------------------------------------------------------
			# Union: fehlende Logins in jede Richtung, Konflikte/Tombstones nur melden
			# -------------------------------------------------------------------
			if ($SyncMode -eq 'Union')
			{
				if ($PSBoundParameters.ContainsKey('Force') -and $Force)
				{
					Invoke-sqmLogging -Message "-Force wird im SyncMode Union ignoriert: bestehende Logins werden nicht per DROP/CREATE ersetzt, nur Passwortaenderungen uebernommen (-HashChange), sonstige Abweichungen gemeldet. Fuer das alte Verhalten -SyncMode Primary." `
									  -FunctionName $functionName -Level 'WARNING'
				}

				$primaryName = [string]$primaryReplica.replica_server_name
				$unionReplicas = [System.Collections.Generic.List[string]]::new()
				foreach ($rep in $replicas)
				{
					$repName = [string]$rep.replica_server_name
					if ($repName -ne $primaryName -and $SkipSecondaryServers -contains $repName)
					{
						$results.Add([PSCustomObject]@{
							AvailabilityGroup = $agName
							SyncMode          = 'Union'
							Action            = 'ReadReplica'
							LoginName         = '(alle)'
							SourceReplica     = ''
							TargetReplica     = $repName
							Status            = 'Skipped'
							Message           = 'In SkipSecondaryServers list'
							Timestamp         = Get-Date
						})
						continue
					}
					$unionReplicas.Add($repName)
				}

				$unionParams = @{
					Replica                  = $unionReplicas.ToArray()
					PrimaryReplica           = $primaryName
					AvailabilityGroupName    = $agName
					IncludeSystemLogins      = $IncludeSystemLogins
					DisablePolicy            = [bool]$DisablePolicy
					AdjustAuthMode           = $AdjustAuthMode
					RestartServiceIfRequired = $RestartServiceIfRequired
					HashChange               = $HashChange
					BackupPath               = $BackupPath
					NoReport                 = $NoReport
				}
				$unionCred = if ($SqlCredential) { $SqlCredential } else { $srcCred }
				if ($unionCred) { $unionParams['SqlCredential'] = $unionCred }
				if ($Login) { $unionParams['Login'] = $Login }
				if ($ExcludeLogin) { $unionParams['ExcludeLogin'] = $ExcludeLogin }
				if ($ResetTombstone) { $unionParams['ResetTombstone'] = $ResetTombstone }
				if ($AdModuleAction) { $unionParams['AdModuleAction'] = $AdModuleAction }

				foreach ($row in @(Invoke-sqmLoginUnionSync @unionParams -WhatIf:$WhatIfPreference -Confirm:$false))
				{
					$results.Add($row)
				}
				return
			}

			# -------------------------------------------------------------------
			# 2. Copy logins to each secondary
			# -------------------------------------------------------------------
			foreach ($secondary in $secondaryReplicas)
			{
				$secondaryName = $secondary.replica_server_name
				$secondaryRole  = $secondary.role_desc

				# Skip if in skip list
				if ($SkipSecondaryServers -contains $secondaryName)
				{
					Invoke-sqmLogging -Message "[$secondaryName] Übersprungen (in SkipSecondaryServers)" -FunctionName $functionName -Level 'VERBOSE'
					$results.Add([PSCustomObject]@{
						AvailabilityGroup = $agName
						PrimaryReplica    = $primaryReplica.replica_server_name
						SecondaryReplica  = $secondaryName
						SecondaryRole     = $secondaryRole
						Status            = 'Skipped'
						LoginsCount       = 0
						OrphansRepaired   = 0
						Error             = 'In SkipSecondaryServers list'
						Timestamp         = Get-Date
					})
					continue
				}

				if (-not $PSCmdlet.ShouldProcess($secondaryName, "Kopiere Logins von Primary"))
				{
					Invoke-sqmLogging -Message "[$secondaryName] Übersprungen (WhatIf)" -FunctionName $functionName -Level 'VERBOSE'
					continue
				}

				try
				{
					Invoke-sqmLogging -Message "[$secondaryName] Beginne Login-Synchronisierung..." -FunctionName $functionName -Level 'INFO'

					# -----------------------------------------------------------
					# Build Copy-sqmLogins parameters
					# -----------------------------------------------------------
					$copyParams = @{
						Source                  = $primaryReplica.replica_server_name
						Destination             = $secondaryName
						SourceCredential        = $srcCred
						DestinationCredential   = $dstCred
						IncludeSystemLogins     = $IncludeSystemLogins
						AdjustAuthMode          = $AdjustAuthMode
						RestartServiceIfRequired = $RestartServiceIfRequired
						DisablePolicy           = $DisablePolicy
						ErrorAction             = 'Stop'
					}
					# Nur durchreichen wenn angegeben: Copy-sqmLogins installiert RSAT dann auch
					# unbeaufsichtigt; ohne Angabe ueberspringt es die Installation im Agent-Job.
					if ($AdModuleAction) { $copyParams.AdModuleAction = $AdModuleAction }

					# Handle -Force with SafeForceMode
					if ($Force)
					{
						$copyParams.Force = $true

						# SafeForceMode: Auto-exclude dangerous logins
						if ($SafeForceMode)
						{
							# Get sysadmin logins (handles renamed 'sa')
							$sysAdminLogins = @()
							try
							{
								$query = "SELECT name FROM sys.server_principals WHERE (is_srvrolemember('sysadmin', name) = 1 OR sid = 0x01) AND name NOT LIKE '##%'"
								$sysAdminLogins = @((Invoke-DbaQuery -SqlInstance $secondaryName -SqlCredential $dstCred -Query $query).name)
								if ($sysAdminLogins.Count -gt 0)
								{
									Invoke-sqmLogging -Message "[$secondaryName] SafeForceMode: Found sysadmin logins: $($sysAdminLogins -join ', ')" `
													  -FunctionName $functionName -Level 'INFO'
								}
							}
							catch
							{
								Invoke-sqmLogging -Message "[$secondaryName] WARNUNG: Sysadmin-Logins konnten nicht ermittelt werden, verwende 'sa' als Fallback" `
												  -FunctionName $functionName -Level 'WARNING'
								$sysAdminLogins = @('sa')
							}

							# Get SQL Agent Service Account for this secondary
							$agentAccount = $null
							try
							{
								# Get-DbaAgentServiceAccount existiert nicht. Das Agent-Dienstkonto liefert sys.dm_server_services
								# ueber die bestehende SQL-Verbindung (kein Windows/WMI noetig). servicename ist lokalisiert
								# ("SQL Server-Agent" auf DE), daher locale-robustes LIKE '%Agent%'.
								$agentSvcQuery = "SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE '%Agent%'"
								$agentAccount = (Invoke-DbaQuery -SqlInstance $secondaryName -SqlCredential $dstCred -Query $agentSvcQuery -ErrorAction Stop -EnableException).service_account
								Invoke-sqmLogging -Message "[$secondaryName] SafeForceMode: Auto-excluding Agent Account: $agentAccount" `
												  -FunctionName $functionName -Level 'INFO'
							}
							catch
							{
								Invoke-sqmLogging -Message "[$secondaryName] WARNUNG: Agent Account konnte nicht ermittelt werden" `
												  -FunctionName $functionName -Level 'WARNING'
							}

							# Build safe exclusion list (dynamic sysadmin logins + dbo)
							$safeExclude = @('dbo')
							$safeExclude += $sysAdminLogins
							if ($agentAccount)
							{
								$safeExclude += $agentAccount
							}
							$safeExclude += @('NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*', '##MS_*')

							# Combine with user-provided ForceExclude
							if ($ForceExclude)
							{
								$safeExclude += $ForceExclude
							}

							$copyParams.ExcludeLogin = $safeExclude
							Invoke-sqmLogging -Message "[$secondaryName] SafeForceMode: Excluding: $($safeExclude -join ', ')" `
											  -FunctionName $functionName -Level 'INFO'
						}

						# Use ForceIncludeOnly if provided (whitelist)
						if ($ForceIncludeOnly)
						{
							$copyParams.Login = $ForceIncludeOnly
							Invoke-sqmLogging -Message "[$secondaryName] Force mit Whitelist: $($ForceIncludeOnly -join ', ')" `
											  -FunctionName $functionName -Level 'INFO'
						}
						elseif (-not $SafeForceMode -and $ForceExclude)
						{
							# Only use ForceExclude if SafeForceMode is off
							$copyParams.ExcludeLogin = $ForceExclude
						}
					}
					else
					{
						# Normal mode (only new logins)
						$copyParams.Login = $Login
						$copyParams.ExcludeLogin = $ExcludeLogin
					}

					# -----------------------------------------------------------
					# Backup logins before -Force (if requested)
					# -----------------------------------------------------------
					$backupFile = $null
					if ($BackupLogins -and $Force)
					{
						try
						{
							if (-not (Test-Path $BackupPath))
							{
								New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
								Invoke-sqmLogging -Message "[$secondaryName] Backup-Verzeichnis erstellt: $BackupPath" `
												  -FunctionName $functionName -Level 'VERBOSE'
							}

							$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
							$backupFile = Join-Path $BackupPath "LoginBackup_$($secondaryName -replace '\\', '_')_$timestamp.sql"

							# Generate backup script (excludes sysadmin & dbo accounts)
							$backupQuery = @"
-- Login Backup for Secondary: $secondaryName
-- Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
-- Source: $($primaryReplica.replica_server_name)
-- Note: Excludes sysadmin accounts, dbo, and system accounts

SELECT 'CREATE LOGIN [' + sp.name + ']' +
       CASE
           WHEN sp.type = 'S' THEN ' WITH PASSWORD = 0x' + CONVERT(VARCHAR(MAX), sl.password_hash, 2) + ' HASHED'
           WHEN sp.type IN ('U', 'G') THEN ' FROM WINDOWS'
       END + ';'
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S', 'U', 'G')
  AND sp.name != 'dbo'
  AND is_srvrolemember('sysadmin', sp.name) = 0  -- Exclude all sysadmin accounts (handles renamed 'sa')
  AND sp.name NOT LIKE 'NT SERVICE\%'
  AND sp.name NOT LIKE 'NT AUTHORITY\%'
  AND sp.name NOT LIKE 'BUILTIN\%'
  AND sp.name NOT LIKE '##MS_%'
ORDER BY sp.name
"@

							$backupContent = Invoke-DbaQuery -SqlInstance $secondaryName -SqlCredential $dstCred -Query $backupQuery
							if ($backupContent -and -not $NoReport)
							{
								[System.IO.File]::WriteAllText($backupFile, ($backupContent | Out-String), [System.Text.Encoding]::UTF8)
								Invoke-sqmLogging -Message "[$secondaryName] Login-Backup erstellt: $backupFile" `
												  -FunctionName $functionName -Level 'INFO'
							}
						}
						catch
						{
							Invoke-sqmLogging -Message "[$secondaryName] WARNUNG: Backup konnte nicht erstellt werden: $($_.Exception.Message)" `
											  -FunctionName $functionName -Level 'WARNING'
						}
					}

					# -----------------------------------------------------------
					# Copy logins using Copy-sqmLogins
					# -----------------------------------------------------------
					$copyResult = Copy-sqmLogins @copyParams

					# Count logins
					# Copy-sqmLogins liefert eine flache Ergebnisliste (Action/LoginName/Status), keine
					# Properties .Logins/.OrphansRepaired - bis v1.9.190.0 stand hier deshalb immer 0.
					$loginsCount = @($copyResult | Where-Object { $_.Action -eq 'CopyLogin' -and $_.Status -eq 'Success' }).Count
					$orphansRepaired = @($copyResult | Where-Object { $_.Action -eq 'RepairOrphanUsers' -and $_.Status -eq 'Success' }).Count

					Invoke-sqmLogging -Message "[$secondaryName] Erfolgreich: $loginsCount Logins kopiert, $orphansRepaired Orphans repariert" `
									  -FunctionName $functionName -Level 'INFO'

					$results.Add([PSCustomObject]@{
						AvailabilityGroup = $agName
						PrimaryReplica    = $primaryReplica.replica_server_name
						SecondaryReplica  = $secondaryName
						SecondaryRole     = $secondaryRole
						Status            = 'Success'
						LoginsCount       = $loginsCount
						OrphansRepaired   = $orphansRepaired
						BackupFile        = $backupFile
						Error             = $null
						Timestamp         = Get-Date
					})
				}
				catch
				{
					$errMsg = $_.Exception.Message
					Invoke-sqmLogging -Message "[$secondaryName] Fehler: $errMsg" -FunctionName $functionName -Level 'ERROR'

					$results.Add([PSCustomObject]@{
						AvailabilityGroup = $agName
						PrimaryReplica    = $primaryReplica.replica_server_name
						SecondaryReplica  = $secondaryName
						SecondaryRole     = $secondaryRole
						Status            = 'Failed'
						LoginsCount       = 0
						OrphansRepaired   = 0
						BackupFile        = $backupFile
						Error             = $errMsg
						Timestamp         = Get-Date
					})

					if ($EnableException) { throw }
				}
			}
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler in ${functionName}: $errMsg" -FunctionName $functionName -Level 'ERROR'

			if ($EnableException) { throw }

			$results.Add([PSCustomObject]@{
				AvailabilityGroup = $AvailabilityGroupName
				PrimaryReplica    = $SqlInstance
				SecondaryReplica  = '(all)'
				SecondaryRole     = 'Unknown'
				Status            = 'Failed'
				LoginsCount       = 0
				OrphansRepaired   = 0
				Error             = $errMsg
				Timestamp         = Get-Date
			})
		}
	}

	end
	{
		$successCount = @($results | Where-Object Status -eq 'Success').Count
		$failedCount  = @($results | Where-Object Status -eq 'Failed').Count
		$skippedCount = @($results | Where-Object Status -eq 'Skipped').Count
		$warnRows     = @($results | Where-Object { $_.Status -eq 'Warning' -and $_.PSObject.Properties['Action'] })

		if ($SyncMode -eq 'Union')
		{
			$copied = @($results | Where-Object { $_.PSObject.Properties['Action'] -and $_.Action -eq 'Copy' -and $_.Status -eq 'Success' }).Count
			Invoke-sqmLogging -Message "$functionName (Union) abgeschlossen. Kopiert: $copied | Zu pruefen: $($warnRows.Count) | Failed: $failedCount | Skipped: $skippedCount" `
							  -FunctionName $functionName -Level 'INFO'
		}
		else
		{
			$totalLogins  = ($results | Where-Object { $_.PSObject.Properties['LoginsCount'] } | Measure-Object -Property LoginsCount -Sum).Sum
			$totalOrphans = ($results | Where-Object { $_.PSObject.Properties['OrphansRepaired'] } | Measure-Object -Property OrphansRepaired -Sum).Sum
			Invoke-sqmLogging -Message "$functionName abgeschlossen. Success: $successCount | Failed: $failedCount | Skipped: $skippedCount | Logins: $totalLogins | Orphans: $totalOrphans" `
							  -FunctionName $functionName -Level 'INFO'
		}

		# -------------------------------------------------------------------
		# Union: Tombstones und Konflikte brauchen eine Entscheidung -> Event 9004 (Splunk).
		# -------------------------------------------------------------------
		if ($warnRows.Count -gt 0 -and -not $WhatIfPreference)
		{
			try
			{
				$evtSrc = 'sqmSQLTool'
				if (-not [System.Diagnostics.EventLog]::SourceExists($evtSrc)) { New-EventLog -LogName Application -Source $evtSrc -ErrorAction Stop }
				$detail = (($warnRows | Select-Object -First 20 | ForEach-Object { "$($_.Action) $($_.LoginName) [$($_.TargetReplica)]: $($_.Message)" }) -join "`r`n")
				Write-EventLog -LogName Application -Source $evtSrc -EntryType Warning -EventId 9004 `
					-Message "sqmSQLTool: Login-Sync AG '$AvailabilityGroupName' - $($warnRows.Count) Login(s) zu pruefen (nicht automatisch geaendert):`r`n$detail" `
					-ErrorAction Stop
			}
			catch
			{
				Invoke-sqmLogging -Message "Event 9004 konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
			}
		}

		# -------------------------------------------------------------------
		# Bei Fehlern: Windows Event Log (Splunk). Der SQL-Agent-Job-Step ruft nur
		# 'Sync-sqmLoginsToAlwaysOn' auf (ohne throw) - die Fehlermeldung laeuft daher
		# ueber Event 9002 und das zentrale sqmSQLTool-Log, nicht ueber den Step.
		# -------------------------------------------------------------------
		if ($failedCount -gt 0)
		{
			try
			{
				$evtSrc = 'sqmSQLTool'
				if (-not [System.Diagnostics.EventLog]::SourceExists($evtSrc)) { New-EventLog -LogName Application -Source $evtSrc -ErrorAction Stop }
				Write-EventLog -LogName Application -Source $evtSrc -EntryType Error -EventId 9002 `
					-Message "sqmSQLTool: Login-Sync fehlgeschlagen AG '$AvailabilityGroupName' auf '$SqlInstance' - Failed=$failedCount" `
					-ErrorAction SilentlyContinue
			}
			catch { }
		}

		# -------------------------------------------------------------------
		# Optional: AD-Orphan-Audit auf dem Primary (nur Meldung, KEIN Auto-Delete)
		# -------------------------------------------------------------------
		if ($AuditAdOrphans)
		{
			try
			{
				$audit = Invoke-sqmLoginAudit -SqlInstance $SqlInstance -SqlCredential $srcCred -CheckAdOrphans -NoOpen -ErrorAction Stop
				$adOrphans = @($audit | ForEach-Object { $_.DetailRows } | Where-Object { $_.FindingType -eq 'AdOrphan' })
				if ($adOrphans.Count -gt 0)
				{
					$orphanNames = (($adOrphans | ForEach-Object { $_.LoginName }) -join ', ')
					Invoke-sqmLogging -Message "AD-Orphans erkannt (manuelle Pruefung noetig, KEIN Auto-Delete): $orphanNames" `
									  -FunctionName $functionName -Level 'WARNING'
					try
					{
						$evtSrc = 'sqmSQLTool'
						if (-not [System.Diagnostics.EventLog]::SourceExists($evtSrc)) { New-EventLog -LogName Application -Source $evtSrc -ErrorAction Stop }
						Write-EventLog -LogName Application -Source $evtSrc -EntryType Warning -EventId 9003 `
							-Message "sqmSQLTool: AD-verwaiste Logins auf '$SqlInstance' AG '$AvailabilityGroupName' - Count=$($adOrphans.Count): $orphanNames" `
							-ErrorAction SilentlyContinue
					}
					catch { }
				}
				else
				{
					Invoke-sqmLogging -Message "AD-Orphan-Pruefung: keine verwaisten Windows-Logins gefunden." -FunctionName $functionName -Level 'INFO'
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "AD-Orphan-Pruefung uebersprungen/fehlgeschlagen: $($_.Exception.Message)" `
								  -FunctionName $functionName -Level 'WARNING'
			}
		}

		# -------------------------------------------------------------------
		# Optional: Retention - alte Login-Backups (und Audit-Reports) aufraeumen
		# -------------------------------------------------------------------
		if ($BackupRetentionDays -gt 0 -and (Test-Path $BackupPath))
		{
			try
			{
				$cutoff = (Get-Date).AddDays(-$BackupRetentionDays)
				$old = @(Get-ChildItem -Path $BackupPath -Filter 'LoginBackup_*.sql' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
				if ($AuditAdOrphans)
				{
					$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
					$old += @(Get-ChildItem -Path $BackupPath -Filter "LoginAudit_${safeInst}_*" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
				}
				if ($old.Count -gt 0)
				{
					$old | Remove-Item -Force -ErrorAction SilentlyContinue
					Invoke-sqmLogging -Message "Retention: $($old.Count) Datei(en) aelter als $BackupRetentionDays Tage entfernt ($BackupPath)." `
									  -FunctionName $functionName -Level 'INFO'
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "Retention-Cleanup fehlgeschlagen: $($_.Exception.Message)" `
								  -FunctionName $functionName -Level 'WARNING'
			}
		}

		return $results
	}
}
