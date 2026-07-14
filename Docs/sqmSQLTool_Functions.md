# sqmSQLTool - Complete Function Reference

## Installation

### From GitHub
```powershell
git clone https://github.com/JankeUwe/sqmSQLTool.git
cd sqmSQLTool
Import-Module ./sqmSQLTool.psd1 -Force
Get-Command -Module sqmSQLTool | Measure-Object

### Requirements
- PowerShell 5.1 or 7+
- SQL Server 2016 or later
- dbatools
- Sysadmin on SQL Server

---

## 14. Active Directory Integration

### Get-sqmADAccountStatus

Checks the status of an Active Directory user account.

Determines the account status using the ActiveDirectory module (RSAT) with
        automatic fallback to ADSI if RSAT is not available.
        Returns a detailed PSObject with Enabled, LockedOut, PasswordExpired
        and AccountExpired.

**Parameters:**

- **-SamAccountName** - The SamAccountName of the AD account to check.
- **-DomainController** - Optional target DC. Only used via the RSAT path.

**Examples (3):**

```powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe'

```powershell
'jdoe','jsmith' | Get-sqmADAccountStatus

```powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe' -DomainController 'DC01'

### Get-sqmADGroupMembers

Lists all members of an Active Directory group.

Simple, reliable function to list members of an AD group (including nested groups).
    Useful when SQL Server access fails and you need to check group permissions.

    Supports NESTED GROUPS: Recursively resolves all members, including members of nested groups.
    Example: If GroupA contains GroupB (which contains User2), both GroupB and User2 are returned.

    Methods:
    1. Get-ADGroupMember -Recursive (if ActiveDirectory module available) — Resolves nested groups
    2. LDAP direct query (fallback, no module required) — Direct members only

**Parameters:**

- **-GroupName** - Name of the AD group. Pipeline-capable. Format: "GroupName" or "DOMAIN\GroupName"
- **-Domain** - Optional: AD domain (e.g., "FITS.LOCAL", "corp.de") If not specified, auto-detects current domain.

**Examples (2):**

```powershell
Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"

```powershell
Get-sqmADGroupMembers -GroupName "Administrators" -Domain "FITS"

### Get-sqmHpuAllowGroup

Searches for the HPU allow group in Active Directory based on configurable domain/group mappings.

**Examples (2):**

```powershell
Get-sqmHpuAllowGroup

```powershell
Get-sqmHpuAllowGroup -EnableException

### Remove-sqmAdOrphanLogin

Removes Windows logins whose Active Directory account no longer exists (AD orphans).

Safe, deliberate cleanup of "dead" AD logins on a SQL Server instance. This is the manual
    counterpart to the detection-only -AuditAdOrphans option of New-sqmAutoLoginSyncJob and is
    intentionally NOT meant for unattended or scheduled use: a missing AD account can be a
    transient domain controller or trust problem, and dropping a valid login would cause an outage.

    Safety model:
    1. The ActiveDirectory module is REQUIRED. If it is missing, -AdModuleAction controls behavior
       (default 'Abort'). Without AD lookups orphans cannot be verified, so nothing is deleted.
    2. Only Windows logins (WINDOWS_LOGIN / WINDOWS_GROUP) are considered.
    3. System logins and ALL sysadmin logins are excluded from removal, always.
    4. A login is treated as an orphan ONLY when Active Directory positively reports the account as
       missing. If the AD query fails, the login is skipped (never deleted).
    5. Logins that own a database are skipped (dropping them would fail or orphan the ownership).
    6. Before removal a rollback script (CREATE LOGIN FROM WINDOWS + server role memberships) is
       written per run, unless -SkipBackup is set.
    7. Every removal honors -WhatIf / -Confirm (ConfirmImpact = High), so nothing is dropped silently.

**Parameters:**

- **-SqlInstance** - Target SQL Server instance. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the instance.
- **-ExcludeLogin** - Additional logins to exclude from removal (wildcards allowed). Combined with the always-on safety exclusions (system and sysadmin logins).
- **-AdModuleAction** - Behavior when the ActiveDirectory module is not present: 'Abort'   (default) - stop with an error; nothing is verified or deleted. 'Install'           - try Install-sqmAdModule, abort if it fails. 'Skip'              - NOT allowed for a destructive operation; treated like 'Abort'.
- **-BackupPath** - Directory for the rollback script. Default: C:\System\WinSrvLog\MSSQL (created if missing).
- **-SkipBackup** - Skip writing the rollback script. Not recommended.
- **-EnableException** - Throw exceptions immediately instead of returning error status.

**Examples (3):**

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -WhatIf
    Lists exactly which AD-orphaned logins would be removed, without changing anything.

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01"
    Removes confirmed AD-orphaned logins after a rollback backup, asking for confirmation per login.

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -ExcludeLogin 'DOMAIN\KeepThis*' -Confirm:$false
    Removes confirmed orphans (except the excluded pattern) without interactive confirmation.

### Get-sqmADGroupMembersRecursive

Lists all members of an Active Directory group with controlled recursion depth.

    Enhanced version of Get-sqmADGroupMembers with support for limiting nesting depth.
    Recursively resolves nested groups up to the specified depth level.

    For user accounts the real AD 'displayName' attribute is resolved (via Get-ADUser),
    so the DisplayName column shows the person's name instead of just the login/CN.
    Fallback chain: displayName -> CN/Name -> sAMAccountName.

**Parameters:**

- **-GroupName** - Name of the AD group. Pipeline-capable.
- **-Domain** - Optional: AD domain (e.g., "FITS.LOCAL", "corp.de") If not specified, auto-detects current domain.
- **-Depth** - Maximum nesting depth for group expansion (default: 2)
- **-OutputPath** - Optional: Output directory for TXT/CSV reports Default: C:\System\WinSrvLog\MSSQL

**Examples (1):**

```powershell
    Get-sqmADGroupMembersRecursive -GroupName "DL_SQL_Admins" -Depth 2

### Get-sqmADMemberGroups

Finds all Active Directory groups that contain a specified user, group, or computer.

    Inverse operation to Get-sqmADGroupMembers.
    Lists all groups (direct and nested) that contain the specified member.

**Parameters:**

- **-Identity** - Identity of the user, group, or computer. Can be: SamAccountName, UPN, or DistinguishedName Pipeline-capable.
- **-Domain** - Optional: AD domain
- **-Depth** - Maximum nesting depth for group expansion (default: 2)
- **-OutputPath** - Optional: Output directory for TXT/CSV reports Default: C:\System\WinSrvLog\MSSQL

**Examples (1):**

```powershell
    Get-sqmADMemberGroups -Identity "john.doe" -Depth 2

### Get-sqmServersFromOU

Ermittelt alle Computer-Objekte aus einer bestimmten AD-OU und gibt sie als pipefaehige Objekte aus.

    Durchsucht Active Directory (via ADSI, kein ActiveDirectory-Modul erforderlich)
    nach allen Computer-Objekten unterhalb einer OU mit dem angegebenen Namen.

    Die Ausgabe-Objekte enthalten eine SqlInstance-Eigenschaft und koennen direkt
    an beliebige sqmSQLTool-Funktionen weitergeleitet werden:

        Get-sqmServersFromOU | ForEach-Object {
            Sync-sqmBackupExcludeTable -SqlInstance $_.SqlInstance
        }

**Parameters:**

- **-OUName** - Name der OU (nicht der vollstaendige LDAP-Pfad). Beispiel: 'srvDatabase' Standard: 'srvDatabase'
- **-Domain** - FQDN der Domain. Standard: aktuelle Domain des ausfuehrenden Benutzers.
- **-SearchBase** - Expliziter LDAP-Suchpfad (DistinguishedName der OU). Wenn angegeben, wird OUName ignoriert. Beispiel: 'OU=srvDatabase,OU=Server,DC=contoso,DC=com'
- **-Recurse** - Sucht auch in untergeordneten OUs (Standard: $true).
- **-EnableException** - Loest bei Fehlern sofort eine Exception aus.

**Examples (5):**

```powershell
    # Alle SQL-Server ausgeben
    Get-sqmServersFromOU

```powershell
    # Andere OU
    Get-sqmServersFromOU -OUName 'srvApp'

```powershell
    # Expliziter Domain-Name
    Get-sqmServersFromOU -OUName 'srvDatabase' -Domain 'contoso.com'

```powershell
    # Direkt an sqmSQLTool-Funktion weiterleiten
    Get-sqmServersFromOU | ForEach-Object {
        Sync-sqmBackupExcludeTable -SqlInstance $_.SqlInstance
    }

```powershell
    # Backup-Exclude-Trigger auf allen DB-Servern registrieren
    Get-sqmServersFromOU | ForEach-Object {
        Register-sqmBackupExcludeTrigger -SqlInstance $_.SqlInstance
    }

## 10. Reporting & Analysis

### Export-sqmDatabaseDocumentation

Creates structured HTML and CSV documentation for all databases on a SQL Server instance.

Documents per database:
    - General properties (status, recovery model, collation, owner, creation date, compatibility level)
    - Size (data, log, total in MB)
    - Filegroups and files (name, path, size, autogrow, growth type)
    - Last backup times (full, diff, log)
    - Last DBCC CHECKDB execution
    - VLF count (SQL Server 2016+)
    - Object summary (tables, views, procedures, functions, triggers)
    - Database users (name, login name, type)
    - Extended properties of the database

    Output is generated as:
    - HTML file with formatted report (self-contained, no external CSS)
    - CSV file for machine processing

    Default output path is read from the module configuration (OutputPath).
    If CentralPath is configured, files are additionally copied there.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the SQL connection.
- **-Database** - Document specific databases only. Wildcards allowed (e.g. 'Sales*'). Default: all user databases.
- **-IncludeSystemDatabases** - Include system databases (master, model, msdb, tempdb). Default: $false.
- **-IncludeFileDetails** - Include filegroup and file details in the report. Default: $true.
- **-IncludeUsers** - Include database users in the report. Default: $true.
- **-IncludeObjectSummary** - Include object summary (tables, SPs, views, etc.) in the report. Default: $true.
- **-OutputPath** - Output directory. Default: value from module configuration (Get-sqmDefaultOutputPath).
- **-ContinueOnError** - Continue on error for an instance or database instead of aborting.
- **-EnableException** - Throw exceptions directly (overrides ContinueOnError).
- **-Confirm** - Request confirmation before writing output files.
- **-WhatIf** - Simulation: shows which files would be created without writing them.

**Examples (4):**

```powershell
Export-sqmDatabaseDocumentation

```powershell
Export-sqmDatabaseDocumentation -SqlInstance "SQL01" -Database "SalesDB","HRApp" -OutputPath "D:\Reports"

```powershell
Export-sqmDatabaseDocumentation -SqlInstance "SQL01" -IncludeSystemDatabases -ContinueOnError

```powershell
# Multiple instances via pipeline
    "SQL01","SQL02","SQL03" | Export-sqmDatabaseDocumentation -ContinueOnError

### Get-sqmAutoGrowthReport

Creates an AutoGrowth configuration report for all database files on a SQL Server instance.

Analyzes all data and log files of the accessible databases and evaluates their AutoGrowth settings.
    Returns warnings for percent-based growth, growth values that are too small or too large, and
    unbounded log files.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-Database** - Restrict to specific databases (array of names).
- **-IncludeSystem** - Include system databases. Default: $false.
- **-Detailed** - When set, additional file properties (physical path) are included in the output.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Get-sqmAutoGrowthReport -SqlInstance "SQL01"

```powershell
Get-sqmAutoGrowthReport -SqlInstance "SQL01" -Detailed -IncludeSystem

### Get-sqmServerHardwareReport

Erstellt einen HTML-Hardware-Konfigurationsbericht fuer einen oder mehrere Server.

Sammelt Systeminformationen via CIM/WMI und generiert einen detaillierten HTML-Report mit:
    - Betriebssystem (Windows-Version, Build, Laufzeit, Domain)
    - Prozessor (Modell, Sockel, physikalische/logische Kerne, Takt)
    - Arbeitsspeicher (Gesamt, frei, DIMM-Details mit Typ und Geschwindigkeit)
    - Laufwerke (physikalische Datentraeger + logische Laufwerke mit Auslastungsbalken)
    - Netzwerk (IP-Adressen, MAC-Adresse, DNS-Server, Gateway)
    - SQL Server Instanzen (Service-Name, Status, Starttyp)
    - VM-Erkennung (Hyper-V, VMware, VirtualBox, KVM/QEMU, Physisch)

    Voraussetzungen fuer Remote-Abfragen:
    - DCOM/WMI-Zugriff (Port 135 + dynamische Ports) auf dem Zielserver
    - Kein WinRM / PowerShell Remoting erforderlich

**Parameters:**

- **-ComputerName** - Zielserver (ein oder mehrere). Standard: lokaler Computer. Aliase: SqlInstance, ServerName
- **-ReportPath** - Ausgabepfad fuer die HTML-Report-Datei(en). Standard: %ProgramData%\sqmSQLTool\HardwareReports
- **-OutputFormat** - Ausgabeformat: HTML (Standard), CSV, TXT oder All (alle Formate gleichzeitig). - HTML: Interaktiver Dark-Theme Report (Standard) - CSV : Flache CSV-Datei fuer Weiterverarbeitung (Excel, Import etc.) - TXT : Lesbare Textdatei (wie CSV aber tabulatorgetrennt) - All : HTML + CSV + TXT werden alle erstellt
- **-NoOpen** - HTML-Datei nach dem Erstellen NICHT automatisch im Browser oeffnen.
- **-PassThru** - Gibt den vollstaendigen Pfad der erstellten Datei(en) als String zurueck.
- **-EnableException** - Ausnahmen sofort ausloesen statt Write-Error.

**Examples (6):**

```powershell
# Lokalen Server analysieren - Report wird automatisch im Browser geoeffnet
    Get-sqmServerHardwareReport

```powershell
# Remote-Server
    Get-sqmServerHardwareReport -ComputerName "SQL01"

```powershell
# Mehrere Server, eigener Report-Pfad
    Get-sqmServerHardwareReport -ComputerName "SQL01","SQL02","SQL03" -ReportPath "C:\Reports"

```powershell
# Nur speichern, nicht oeffnen - Dateipfad zurueckgeben
    $path = Get-sqmServerHardwareReport -ComputerName "SQL01" -NoOpen -PassThru
    Write-Host "Report: $path"

```powershell
# CSV-Export fuer Weiterverarbeitung in Excel
    Get-sqmServerHardwareReport -ComputerName "SQL01","SQL02" -OutputFormat CSV -NoOpen

```powershell
# Alle Formate auf einmal (HTML + CSV + TXT)
    Get-sqmServerHardwareReport -ComputerName "SQL01" -OutputFormat All -NoOpen -PassThru

### Invoke-sqmInstanceInventory

Creates a complete inventory of a SQL Server instance as a structured report (TXT + CSV).

Documents the following areas:
    - Instance (version, edition, patch level, collation, memory, CPU, sp_configure)
    - Databases (name, status, recovery, size, last backups, owner, collation)
    - Logins (name, type, status, server roles)
    - Linked servers
    - SQL Agent jobs (name, status, owner, schedules, last execution)
    - Always On (AGs, replicas, listeners)

    Output is generated as:
    - TXT file with readable report
    - CSV file with the database list

    Default output path is read from the module configuration (OutputPath).
    If configured, files are additionally copied to CentralPath.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-OutputPath** - Output directory for report files. Default: value from module configuration (Get-sqmDefaultOutputPath).
- **-ContinueOnError** - Continue on error for an instance (otherwise abort).
- **-EnableException** - Allow exceptions to pass through (for advanced error handling).
- **-Confirm** - Request confirmation before creation.
- **-WhatIf** - Test only, do not write files.

**Examples (2):**

```powershell
Invoke-sqmInstanceInventory

```powershell
Invoke-sqmInstanceInventory -SqlInstance "SQL01", "SQL02" -ContinueOnError

### Invoke-sqmSetupReport

Professional SQL Server Setup Report with critical issues, security, and database overview.

Comprehensive setup report including:
    - CRITICAL ISSUES (SA, Backups, MaxMemory)
    - SECURITY (Sysadmins, Logins with roles, CLR, xp_cmdshell)
    - INFRASTRUCTURE (Service Accounts, SPNs, Splunk)
    - CONFIGURATION (MAXDOP, Cost Threshold, TempDB)
    - DATABASES (DBOs, Recovery Models, Last Backups)

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: local computer name.
- **-SqlCredential** - Credentials for SQL connection.
- **-OutputPath** - Output path for HTML report.
- **-PassThru** - Return the file path.
- **-NoOpen** - Don't open the report in browser.

**Examples (1):**

```powershell
Invoke-sqmSetupReport -SqlInstance "SQL01"

### Get-sqmLinkedServerUsage

Analyzes which database objects (procedures, functions, views, triggers, SQL Agent jobs) access linked servers.

    Searches the definitions of all user databases for references to linked servers.
    Shows the referenced linked server, the object and the database. Optionally includes dependent jobs.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-LinkedServer** - Name of the linked server (or wildcard). Default: all.
- **-IncludeJobs** - Also checks SQL Agent job steps for T-SQL using the linked server.
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
    Get-sqmLinkedServerUsage -SqlInstance "SQL01" -LinkedServer "PROD_SRV"

### New-sqmSetupReport

Builds a self-contained animated HTML replay from a setup event JSON-Lines file.

    Internal helper for the optional setup progress report. Reads the JSON-Lines stream produced by
    Write-sqmSetupEvent and writes ONE standalone .html file that animates the timeline: a phase
    pipeline, per-step visualizations (running-arrow copy, disk format, gears, node restart, AG
    replication, listener) and play/pause/scrub controls.

    The output is fully offline (no CDN, no external resources) so it opens by double-click or from a
    share. Returns the path of the written HTML file, or $null when no usable events were found.

**Parameters:**

- **-EventPath** - Path to the JSON-Lines event file written by Write-sqmSetupEvent.
- **-OutputPath** - Path of the HTML file to write. Default: the event file with extension .html.
- **-Title** - Report title. Default: 'SQL Server Setup'.
- **-Server** - Server/instance label shown in the header. Default: $env:COMPUTERNAME.

### Write-sqmSetupEvent

Appends a single structured setup event as one JSON line (JSON-Lines) to a file.

    Internal, side-effect-free helper for the optional animated setup replay report. Each call writes
    exactly one compact JSON object terminated by a newline, so the file is a JSON-Lines stream that
    New-sqmSetupReport replays as an animated HTML timeline.

    The whole body is wrapped in try/catch: a logging/serialization failure must NEVER affect the
    installation. When -Path is empty or $null the function is a no-op, so callers can invoke it
    unconditionally (the report is opt-in via the orchestrator's -ProgressReport switch).

**Parameters:**

- **-Path** - Target JSON-Lines file. Empty/$null -> no-op.
- **-Phase** - Coarse pipeline station (copy, preinstall, dirs, install, components, drivers, postinstall, alwayson).
- **-Step** - Stable step identifier within the phase (e.g. copy-sources, hadr, node-restart, listener).
- **-State** - start | progress | done | warn | error.
- **-Title** - Short human-readable label shown in the report.
- **-Detail** - Optional detail line (e.g. instance, path).
- **-Pct** - Optional progress percentage (0-100); -1 = not applicable.
- **-Node** - Optional node/instance the event relates to (for the AlwaysOn visuals).
- **-Viz** - Visualization hint for the front-end: flow-arrows | disk-format | gears | bar | node-restart | node-fetch | data-replicate | listener | check. Defaults to a sensible value per phase.

## 3. Backup & Recovery

### Get-sqmOperationStatus

Displays progress and estimated remaining time for active backup, restore and AutoSeed operations.

The function monitors active SQL Server operations (backup, restore, AutoSeed) and calculates
the progress and estimated remaining time. It combines information from:
- Backup and restore progress: sys.dm_exec_requests
- AutoSeed progress: sys.dm_hadr_physical_seeding_stats

The function can run against a specific instance and shows all active operations by default.
Use the parameter to filter by operation type (Backup, Restore, AutoSeed).

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME) is used
by default.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (default: current computer name).
- **-SqlCredential** - Alternative credentials.
- **-OperationType** - Filters by operation type. Valid values: 'Backup', 'Restore', 'AutoSeed'.
By default all active operations are shown.
- **-Continuous** - When set, output is continuously refreshed (similar to 'watch').
Stop with Ctrl+C.
- **-RefreshSeconds** - Refresh interval in seconds for continuous mode (default: 5). Only used with -Continuous.
- **-EnableException** - Switch to allow exceptions to pass through (by default errors are logged as warnings).

**Examples (3):**

```powershell
# Show all active operations on the local instance
Get-sqmOperationStatus

```powershell
# Only active AutoSeed operations on a remote instance
Get-sqmOperationStatus -SqlInstance "SQL01" -OperationType AutoSeed

```powershell
# Continuous refresh every 10 seconds
Get-sqmOperationStatus -Continuous -RefreshSeconds 10

### Invoke-sqmRestoreDatabase

Restores a database from a backup file, with support for single-server and AlwaysOn environments.

The function performs a controlled database restore. It automatically detects whether the target
database belongs to an AlwaysOn availability group and removes it from the AG if so (including
deletion on secondary replicas). By default, once the restore completes, the database is
automatically re-added to the AG (Add-DbaAgDatabase with SeedingMode Automatic), which also
reseeds the secondaries - use -NoRejoinAvailabilityGroup to leave it standalone instead. Database
users are exported before the restore (for later recovery). Optionally a backup of the original
database can be created. After the restore, users are recovered, orphaned users are repaired,
non-existent Windows logins are removed, and the database owner is set to the SA account
(regardless of its name).

The function can also restore a sequence of backups (Full + Diff + Logs) using the `-BackupFiles`
parameter, which accepts a list of backup files in the correct order (Full, then Diff, then Logs).

Before user export and before the restore, the configured PBM policy (DefaultPolicy) is
temporarily disabled to avoid restrictions during user creation. It is re-enabled after completion.

If the database is in use, it is automatically set to single-user mode after the user export
(and switched back to multi-user after the restore) - single-user is applied only after the
export, not before, since Export-DbaUser needs its own connection to the database and would
otherwise fail with "database is already open and can only have one user at a time".

AG-membership is normally auto-detected at the start of the run. If a previous run already
removed the database from the AG but failed before rejoining it, a retry would no longer
auto-detect it as an AG database and would silently skip secondary cleanup and rejoin/reseed
entirely. Use `-AvailabilityGroupName` to force AG-aware handling regardless of current live
membership. Every rejoin attempt (success and failure) is also written to the Windows
Application Event Log (source "sqmAlwaysOn", same source as Repair-sqmAlwaysOnDatabases).

**Parameters:**

- **-SqlInstance** - Target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). Default: current computer name.
- **-SqlCredential** - Alternative credentials for the target instance.
- **-BackupFile** - Path to the full backup file (.bak). Can also be an array for striped backups.
For sequential restore (Full + Diff + Logs) use `-BackupFiles`.
- **-BackupFiles** - Array of backup files in order: Full, then Diff (optional), then Logs (optional).
Example: @("C:\Backup\Full.bak", "C:\Backup\Diff.bak", "C:\Backup\Log1.trn", "C:\Backup\Log2.trn").
Can be used instead of `-BackupFile`.
- **-DatabaseName** - Name of the database to restore (as it appears in the backup file). Required to determine file names.
- **-NewDatabaseName** - Optional: New name for the database after the restore. If specified, logical file names are
adjusted accordingly (physical files use the new name as base).
- **-NewDatabaseFilePath** - Optional: Target directory for database files (.mdf, .ndf). If not specified, the default
directory of the target instance is used (BackupDirectory or DefaultFile).
- **-NewLogFilePath** - Optional: Target directory for the log file (.ldf). If not specified, the default directory
of the target instance is used.
- **-BackupBeforeRestore** - Optional: Creates a full backup of the existing database before the restore (if present).
The backup is stored in the default backup directory named "DatabaseName_preRestore_YYYYMMDD_HHmmss.bak".
- **-NoUserExport** - Optional: Skips export of database users (users are always exported by default).
The export file is stored temporarily in the %TEMP% directory.
- **-KeepAlwaysOn** - Optional: If the database is part of an AG, it is not removed from the AG.
Note: Restoring an AG database is only possible after removing it from the AG.
Use this parameter only if the database is already outside the AG.
- **-AvailabilityGroupName** - Optional: Explicitly declares which AG the database belongs to (or should end up in after
the restore), instead of relying solely on live AG-membership detection at the start of the run.
Use this when the database was already removed from the AG by a previous, incompletely finished
run, or when restoring a brand-new database straight into an existing AG.
- **-WithNoRecovery** - Optional: Performs the restore with NORECOVERY so the database remains in restoring state
(for additional log backups). By default RECOVERY is used (database online).
- **-ContinueWithNoRecovery** - Optional: When set, the last restore is also performed with NORECOVERY (e.g. when
additional backups are to be applied manually).
- **-ForceSingleUser** - Forces the database into single-user mode before the restore (even if no active connections
are detected). By default only switches when there are active connections.
- **-NoRejoinAvailabilityGroup** - Optional: If the database was part of an AG (and removed from it for the restore), it is by
default automatically re-added to the AG afterwards (Add-DbaAgDatabase with SeedingMode Automatic,
which also seeds the secondaries). Use this switch to suppress that and leave the database
outside the AG after the restore instead.
- **-EnableException** - Switch to allow exceptions to pass through (by default errors are logged and returned as objects).
- **-Confirm** - Request confirmation before critical actions (removing from AG, restore).
- **-WhatIf** - Shows what would happen without making changes.

**Examples (4):**

```powershell
# Simple restore of a full backup file
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\AdventureWorks.bak" -DatabaseName "AdventureWorks"

```powershell
# Restore with Full + Diff + Logs
$backupSequence = @(
    "D:\Backup\AdventureWorks_Full.bak",
    "D:\Backup\AdventureWorks_Diff.bak",
    "D:\Backup\AdventureWorks_Log1.trn",
    "D:\Backup\AdventureWorks_Log2.trn"
)
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFiles $backupSequence -DatabaseName "AdventureWorks"

```powershell
# Restore with new name and forced Single-User mode
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\OldDB.bak" -DatabaseName "OldDB" -NewDatabaseName "NewDB" -ForceSingleUser

```powershell
# Retry after a previous run already removed the database from the AG but did not get to
# rejoin it - force it explicitly to guarantee the secondaries get reseeded.
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\Arena.bak" -DatabaseName "Arena" -AvailabilityGroupName "AG_Prod"

### Invoke-sqmUserDatabaseBackup

Backs up user databases on a SQL Server instance.

Backs up all or selected user databases (no system databases) in full backup mode.
The target path is read from the server properties (BackupDirectory) and must end with "User-Db".

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

When -UseExcludeTable is set, the function reads the table master.dbo.sqm_BackupExclude
(created by Sync-sqmBackupExcludeTable) and skips all databases where IsActive=1 AND
IsOrphaned=0. If the table does not exist or contains no active, non-orphaned rows,
all databases are backed up normally.

When -CheckPreferredReplica is set, the function checks whether this SQL Server instance
is the preferred backup replica for any Availability Group databases before starting any
backups. If the instance is NOT the preferred replica, the job is aborted immediately and
no backups are taken.

When -MailTo is specified, a backup report is sent via SQL Server Database Mail after all
backups have completed. By default the mail is only sent when there are failures or the
job was aborted. Add -MailOnSuccess to also receive a mail on full success.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.
- **-SqlCredential** - Alternative credentials (PSCredential). If not specified, Windows authentication is used.
- **-Database** - Name or array of user databases to back up. Ignored when -All is set.
- **-All** - When set, all user databases on the instance are backed up.
- **-BackupPath** - Optional direct backup path (overrides the value from server properties).
The path must end with "User-Db".
- **-UseExcludeTable** - When set, reads master.dbo.sqm_BackupExclude and skips databases where IsActive=1
and IsOrphaned=0.
- **-CheckPreferredReplica** - When set, checks sys.fn_hadr_backup_is_preferred_replica() for all AG databases on
this instance before starting any backups. If this instance is not the preferred backup
node for any AG database, the entire job is aborted.
- **-MailTo** - Recipient email address for the backup report. When specified, a mail is sent via SQL
Server Database Mail after the backup run. By default the mail is only sent on errors
or when the job was aborted; add -MailOnSuccess to also send on full success.
- **-MailProfile** - SQL Server Database Mail profile name to use for sending the report mail.
Default: 'Default'.
- **-MailOnSuccess** - When set together with -MailTo, a report mail is also sent when all backups succeeded
(not only on errors or abort).
- **-EnableException** - Switch to propagate exceptions immediately (by default errors are logged as warnings).

**Examples (9):**

```powershell
# Back up all user databases on the current computer
Invoke-sqmUserDatabaseBackup -All

```powershell
# Back up specific databases on a remote server
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -Database "SalesDB", "InventoryDB"

```powershell
# With an alternative path
Invoke-sqmUserDatabaseBackup -All -BackupPath "D:\Backup\User-Db"

```powershell
# Back up all user databases, skipping databases listed in sqm_BackupExclude
Invoke-sqmUserDatabaseBackup -All -UseExcludeTable

```powershell
# Back up with exclude table on a remote instance
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -All -UseExcludeTable

```powershell
# Only run backup if this instance is the preferred AG backup replica
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -All -CheckPreferredReplica

```powershell
# Back up all databases and send a mail report on errors (uses default mail profile)
Invoke-sqmUserDatabaseBackup -All -MailTo "dba@example.com"

```powershell
# Back up all databases and always send a mail report (success and failure)
Invoke-sqmUserDatabaseBackup -All -MailTo "dba@example.com" -MailProfile "SQLAlerts" -MailOnSuccess

```powershell
# Full pipeline: AG-aware backup with exclude table and mail notification
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -All -UseExcludeTable `
    -CheckPreferredReplica -MailTo "dba@example.com" -MailOnSuccess

### New-sqmBackupMaintenanceJob

Creates a SQL Agent job with two steps that implement the full dynamic backup maintenance workflow.

Creates a single SQL Agent job containing two PowerShell steps:

	Step 1 — Sync-BackupExcludeTable
	    Calls Sync-sqmBackupExcludeTable to synchronise master.dbo.sqm_BackupExclude with the
	    current set of databases on the instance. This ensures the exclude table is up-to-date
	    before the actual backup starts.

	Step 2 — Backup-UserDatabases-<BackupType>
	    Calls Invoke-sqmUserDatabaseBackup with -All and all configured options (UseExcludeTable,
	    CheckPreferredReplica, MailTo, MailProfile, MailOnSuccess, BackupPath).

	Both steps use the PowerShell subsystem so that the sqmSQLTool module is imported fresh at
	each execution. This means the job is fully self-contained and does not depend on the SQL
	Server Agent service account's PowerShell profile.

	Default schedule days per backup type (when -ScheduleDays is not specified):
	    FULL — @('Sunday')
	    DIFF — @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
	    LOG  — @('EveryDay')

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name ($env:COMPUTERNAME).
- **-SqlCredential** - PSCredential for the SQL connection.
- **-JobName** - Name of the SQL Agent job to create. Default: 'sqm-BackupMaintenance-FULL'.
- **-BackupType** - Backup type: 'FULL', 'DIFF', or 'LOG'. Default: 'FULL'.
- **-BackupPath** - Optional backup path. When specified, overrides the server default and is passed as -BackupPath to Invoke-sqmUserDatabaseBackup in Step 2.
- **-ScheduleTime** - Start time of the schedule in format 'HH:mm'. Default: '20:00'.
- **-ScheduleDays** - Days of the week for the schedule. Valid values: 'Monday'..'Sunday', 'Weekdays', 'Weekend', 'EveryDay'. When not specified, defaults depend on BackupType (see description).
- **-ScheduleIntervalMinutes** - Repeat interval within a day in minutes (e.g. 15 = every 15 minutes). 0 = run once at ScheduleTime. Default: 0.
- **-JobCategory** - SQL Agent job category. Default: 'Database Maintenance'.
- **-UseExcludeTable** - When set, passes -UseExcludeTable to Invoke-sqmUserDatabaseBackup in Step 2.
- **-CheckPreferredReplica** - When set, passes -CheckPreferredReplica to Invoke-sqmUserDatabaseBackup in Step 2.
- **-IncludeSystemDatabases** - When set, passes -IncludeSystemDatabases to Sync-sqmBackupExcludeTable in Step 1. Note: system databases are not backed up by Invoke-sqmUserDatabaseBackup (Step 2).
- **-MailTo** - Recipient email address. Passed as -MailTo to Invoke-sqmUserDatabaseBackup in Step 2.
- **-MailProfile** - SQL Server Database Mail profile name. Passed as -MailProfile to Invoke-sqmUserDatabaseBackup. Default: 'Default'.
- **-MailOnSuccess** - When set, passes -MailOnSuccess to Invoke-sqmUserDatabaseBackup in Step 2 so that a report mail is also sent on full success.
- **-OperatorName** - SQL Agent operator name for failure email notification on the job level.
- **-Update** - When set, replaces an existing job with the same name.
- **-EnableException** - Throw exceptions immediately instead of returning error objects.
- **-WhatIf** - Shows what would happen without making changes.
- **-Confirm** - Request confirmation before creating the job.

**Examples (4):**

```powershell
# Weekly FULL backup Sunday 20:00 with all features
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL `
	    -UseExcludeTable -CheckPreferredReplica `
	    -MailTo "dba@company.com" -MailProfile "DBA-Mail"

```powershell
# Daily DIFF backup with exclude table
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType DIFF `
	    -UseExcludeTable -ScheduleTime "22:00"

```powershell
# LOG backup every 15 minutes
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType LOG `
	    -ScheduleIntervalMinutes 15 -UseExcludeTable

```powershell
# Replace existing job
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL -Update

### New-sqmOlaMaintenanceJobs



Creates three fully configured SQL Agent jobs on the specified SQL Server instance
    that call Ola Hallengren's IndexOptimize and DatabaseIntegrityCheck procedures.

    Prerequisite: Ola Hallengren's Maintenance Solution must be installed.
    (https://ola.hallengren.com)

    Job names are read from the module configuration (see defaults in NOTES).
    IndexOptimize uses optimized default parameters (see NOTES).

    Logging and OutputPath are controlled via the module configuration.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - PSCredential for the SQL connection.
- **-JobCategory** - Category for all three jobs. Default: 'Database Maintenance'.
- **-JobNameIndexOpt** - Name of the IndexOptimize job (overrides module configuration).
- **-JobNameIntUserDb** - Name of the IntegrityCheck job for user DBs (overrides module configuration).
- **-JobNameIntSysDb** - Name of the IntegrityCheck job for system DBs (overrides module configuration).
- **-ScheduleTime** - Start time for all jobs (format 'HH:mm'). Default: '23:00'.
- **-ScheduleDay** - Day of week as SQL Agent Frequency Interval (bitmask). Default: 1 (Sunday).
- **-Databases** - Database filter for IndexOptimize and IntegrityCheck user. Default: 'USER_DATABASES'.
- **-FragmentationLevel1** - Lower fragmentation threshold in percent (medium). Default: 5.
- **-FragmentationLevel2** - Upper fragmentation threshold in percent (high). Default: 30.
- **-MinNumberOfPages** - Minimum page count of an index to be considered. Default: 1000.
- **-FillFactor** - Fill factor for index rebuilds in percent. Default: 90.
- **-MaxDOP** - MAXDOP for IndexOptimize. Default: 0 (SQL Server decides).
- **-SortInTempdb** - Execute sort operations in TempDB. Default: 'Y'.
- **-UpdateStatistics** - Update statistics: 'ALL', 'COLUMNS', 'INDEX', 'NONE'. Default: 'ALL'.
- **-OnlyModifiedStatistics** - Only update modified statistics. Default: 'Y'.
- **-StatisticsSample** - Sample size for statistics update in percent. Default: 0 (SQL Server default).
- **-LogToTable** - Ola internal logging to CommandLog table. Default: 'Y'.
- **-CheckCommands** - DBCC command for IntegrityCheck. Default: 'CHECKDB'.
- **-PhysicalOnly** - Check physical consistency only (faster). Default: 'N'.
- **-NoIndex** - Skip non-clustered indexes in IntegrityCheck. Default: 'N'.
- **-OperatorName** - SQL Agent operator for email notification on failure.
- **-Update** - Replace existing jobs with the same name.
- **-ContinueOnError** - Continue with the next job on error (rarely used).
- **-EnableException** - Throw exceptions immediately.
- **-Confirm** - Request confirmation before creation.
- **-WhatIf** - Shows what would happen without making changes.

**Examples (2):**

```powershell
New-sqmOlaMaintenanceJobs -SqlInstance "SQL01"

```powershell
New-sqmOlaMaintenanceJobs -SqlInstance "SQL01" -ScheduleTime "22:00" -ScheduleDay 64 -OperatorName "DBAs"

### New-sqmOlaSysDbBackupJob



Creates a SQL Agent job that daily backs up master, model, and msdb completely.
    Backups are stored in a dedicated subdirectory \Sys-db: <BackupDirectory>\Sys-db.

    Job name is read from the module configuration (OlaJobNameSysDbBackup).
    Default: 'OlaHH-SystemDatabases-FULL'.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - PSCredential for the SQL connection.
- **-BackupDirectory** - Backup base directory. System databases are backed up to <BackupDirectory>\Sys-db. Default: automatically determined from SQL Server.
- **-JobName** - Name of the SQL Agent job (overrides module configuration).
- **-JobCategory** - Job category. Default: 'Database Maintenance'.
- **-ScheduleTime** - Start time in format 'HH:mm'. Default: '21:15'.
- **-CleanupTime** - Age in hours after which backup files are deleted. Default: 48. 0 = no cleanup.
- **-Compress** - Backup compression. Default: 'Y'.
- **-Verify** - Backup verification. Default: 'Y'.
- **-CheckSum** - Checksum calculation. Default: 'Y'.
- **-LogToTable** - Ola internal logging to CommandLog table. Default: 'Y'.
- **-OperatorName** - SQL Agent operator for email notification on failure.
- **-Update** - Replace an existing job with the same name.
- **-ContinueOnError** - Continue on error (rarely used here, but included for consistency).
- **-EnableException** - Throw exceptions immediately.
- **-Confirm** - Request confirmation before creation.
- **-WhatIf** - Shows what would happen without making changes.

**Examples (2):**

```powershell
New-sqmOlaSysDbBackupJob -SqlInstance "SQL01"

```powershell
New-sqmOlaSysDbBackupJob -SqlInstance "SQL01" -ScheduleTime "20:00" -OperatorName "DBAs"

### New-sqmOlaUsrDbBackupJob



Creates a separate SQL Agent job for each selected backup type (-Full, -Diff, -Log).
    Each job gets its own schedule with configurable days and start time.

    Backups are stored in <BackupDirectory>\Usr-db.
    Job names are read from the module configuration:
        OlaJobNameFull  (Default: 'OlaHH-UserDatabases-FULL')
        OlaJobNameDiff  (Default: 'OlaHH-UserDatabases-DIFF')
        OlaJobNameLog   (Default: 'OlaHH-UserDatabases-LOG')

    When -UseExcludeTable is set, the function reads master.dbo.sqm_BackupExclude
    (created by Sync-sqmBackupExcludeTable) for entries where IsActive=1 AND IsOrphaned=0.
    If entries are found, they are passed to Ola's @ExcludeDatabases parameter in the
    generated job step command. If the table does not exist or contains no matching rows,
    the -Databases parameter is used unchanged.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - PSCredential for the SQL connection.
- **-BackupDirectory** - Backup base directory. User databases are backed up to <BackupDirectory>\Usr-db. Default: automatically determined from SQL Server.
- **-Databases** - Database filter for Ola. E.g. 'USER_DATABASES', 'ALL_DATABASES', or comma-separated DB names like 'DB1,DB2'. Default: 'USER_DATABASES'.
- **-Full** - Creates a FULL backup job.
- **-FullJobName** - Overrides the job name for FULL read from the configuration.
- **-FullScheduleTime** - Start time of the FULL job in format 'HH:mm'. Default: '20:00'.
- **-FullScheduleDays** - Days of the week for the FULL job as an array. Valid values: 'Monday'..'Sunday', 'Weekdays', 'Weekend', 'EveryDay'. Multiple days: @('Monday','Wednesday','Friday'). Default: @('Sunday').
- **-FullScheduleIntervalMinutes** - Repeat interval for the FULL job in minutes (e.g. 60 = hourly). 0 = no interval, job runs once at FullScheduleTime. Default: 0.
- **-Diff** - Creates a DIFF backup job.
- **-DiffJobName** - Overrides the job name for DIFF read from the configuration.
- **-DiffScheduleTime** - Start time of the DIFF job in format 'HH:mm'. Default: '20:00'.
- **-DiffScheduleDays** - Days of the week for the DIFF job. Default: @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday').
- **-DiffScheduleIntervalMinutes** - Repeat interval for the DIFF job in minutes. 0 = once. Default: 0.
- **-Log** - Creates a LOG backup job.
- **-LogJobName** - Overrides the job name for LOG read from the configuration.
- **-LogScheduleTime** - Start time of the LOG job in format 'HH:mm'. Default: '00:00'.
- **-LogScheduleDays** - Days of the week for the LOG job. Default: @('EveryDay').
- **-LogScheduleIntervalMinutes** - Repeat interval for the LOG job in minutes (e.g. 15 = every 15 minutes). 0 = once at LogScheduleTime. Default: 0.
- **-JobCategory** - Category for all created jobs. Default: 'Database Maintenance'.
- **-CleanupTime** - Age in hours after which backup files are deleted. Default: 48. 0 = no cleanup.
- **-Compress** - Backup compression. Default: 'Y'.
- **-Verify** - Backup verification. Default: 'Y'.
- **-CheckSum** - Checksum calculation. Default: 'Y'.
- **-LogToTable** - Ola internal logging to CommandLog table. Default: 'Y'.
- **-OperatorName** - SQL Agent operator for email notification on failure.
- **-Update** - Replace existing jobs with the same name.
- **-ContinueOnError** - Continue with remaining jobs if one job fails.
- **-UseExcludeTable** - When set, reads master.dbo.sqm_BackupExclude for active, non-orphaned entries and adds them as @ExcludeDatabases to the Ola DatabaseBackup command in the job step. If the table does not exist or is empty, the Databases parameter is used unchanged.
- **-EnableException** - Throw exceptions immediately.
- **-Confirm** - Request confirmation before creation.
- **-WhatIf** - Shows what would happen without making changes.

**Examples (9):**

```powershell
New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full

```powershell
New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log

```powershell
# Create FULL job that automatically excludes databases from sqm_BackupExclude
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -UseExcludeTable

```powershell
# All three job types with exclude table integration
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log -UseExcludeTable -Update

```powershell
New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full `
        -FullScheduleTime "22:00" -FullScheduleDays @('Sunday') `
        -OperatorName "DBAs"

```powershell
New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Log `
        -LogScheduleTime "00:30" -LogScheduleDays @('EveryDay') `
        -Databases "USER_DATABASES"

```powershell
New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log `
        -FullScheduleDays @('Sunday') -FullScheduleTime "21:00" `
        -DiffScheduleDays @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') `
        -DiffScheduleTime "21:00" `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -Update

```powershell
# LOG backup every 15 minutes, daily
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Log `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -LogScheduleIntervalMinutes 15 -Update

```powershell
# FULL on multiple days, DIFF daily, LOG every 30 minutes
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log `
        -FullScheduleDays @('Monday','Wednesday','Friday') -FullScheduleTime "22:00" `
        -DiffScheduleDays @('EveryDay') -DiffScheduleTime "22:00" `
        -LogScheduleDays @('EveryDay') -LogScheduleTime "00:00" `
        -LogScheduleIntervalMinutes 30 -Update

### Set-sqmBackupExcludePermission

Grants SELECT, INSERT, and UPDATE permissions on master.dbo.sqm_BackupExclude to a login.

Ensures that the specified Windows group or SQL login has the necessary permissions
to read and modify the backup exclude table master.dbo.sqm_BackupExclude.

The function performs the following steps:
  1. Verifies that master.dbo.sqm_BackupExclude exists — if not, an error is thrown
     with the hint to run Sync-sqmBackupExcludeTable first.
  2. Checks whether the login already exists on the SQL Server instance.
     If not, it is created automatically via New-DbaLogin.
  3. Ensures the login has a corresponding database user in master.
     If not, the user is created via New-DbaDbUser.
  4. Grants SELECT, INSERT, and UPDATE on master.dbo.sqm_BackupExclude to the user.

If SqlInstance is not specified, the current computer name ($env:COMPUTERNAME) is used.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.
- **-SqlCredential** - Alternative credentials (PSCredential). If not specified, Windows authentication is used.
- **-LoginName** - The Windows group (e.g. "DOMAIN\DBA-Team") or SQL login to grant permissions to.
This parameter is mandatory.
- **-EnableException** - Switch to propagate exceptions immediately (by default errors are logged as warnings).

**Examples (3):**

```powershell
# Grant permissions to a Windows group on the local instance
Set-sqmBackupExcludePermission -LoginName "CONTOSO\DBA-Team"

```powershell
# Grant permissions to a SQL login on a remote instance
Set-sqmBackupExcludePermission -SqlInstance "SQL01" -LoginName "svc_backup"

```powershell
# Preview what would happen without making any changes
Set-sqmBackupExcludePermission -SqlInstance "SQL01" -LoginName "CONTOSO\DBA-Team" -WhatIf

### Sync-sqmBackupExcludeTable

Creates and synchronises the backup exclude table in the master database.

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

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.
- **-SqlCredential** - Alternative credentials (PSCredential). If not specified, Windows authentication is used.
- **-IncludeSystemDatabases** - When set, the system databases master, model, and msdb are also inserted into the
exclude table. tempdb is always excluded regardless of this switch.
- **-EnableException** - Switch to propagate exceptions immediately (by default errors are logged as warnings).

**Examples (4):**

```powershell
# Synchronise on the local instance – user databases only
Sync-sqmBackupExcludeTable

```powershell
# Synchronise on a remote instance including system databases
Sync-sqmBackupExcludeTable -SqlInstance "SQL01" -IncludeSystemDatabases

```powershell
# Preview what would change without making any modifications
Sync-sqmBackupExcludeTable -SqlInstance "SQL01" -WhatIf

```powershell
# Synchronise and verify that the audit history table and trigger are in place
Sync-sqmBackupExcludeTable -SqlInstance "SQL01\INST1"

### Test-sqmBackupIntegrity

Verifies one or more backup files using RESTORE VERIFYONLY.

Executes RESTORE VERIFYONLY on a backup file (local or optionally remote).
    Returns $true if the check was successful, otherwise $false.
    Can verify multiple files in sequence (e.g. stripes).

**Parameters:**

- **-SqlInstance** - SQL Server instance on which the verification runs (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-BackupPath** - Path to the backup file (.bak) on the server (local path, not UNC). Can be an array. If not specified, the directory from the module configuration (BackupDirectory) is used. Fallback: the default backup directory of the target SQL Server instance.
- **-FileListOnly** - When $true, only lists the files contained in the backup (without VerifyOnly).
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
Test-sqmBackupIntegrity -SqlInstance "SQL01" -BackupPath "D:\Backup\AdventureWorks.bak"

### Register-sqmBackupExcludeTrigger

Registriert oder entfernt den DDL-Trigger, der master.dbo.sqm_BackupExclude automatisch bei CREATE_DATABASE und DROP_DATABASE aktuell haelt.

    Legt einen server-weiten DDL-Trigger (ON ALL SERVER) an, der feuert bei:
      CREATE_DATABASE — fuegt neue Datenbank in sqm_BackupExclude ein (IsActive=1, IsOrphaned=0).
                        Reaktiviert einen ggf. bereits als verwaist markierten Eintrag.
      DROP_DATABASE   — markiert die Datenbank in sqm_BackupExclude als IsOrphaned=1.

    Damit entfaellt die Notwendigkeit, nach Datenbank-Anlage oder -Loeschung manuell
    Sync-sqmBackupExcludeTable aufzurufen — die Tabelle ist immer aktuell.

    Verhalten:
      - tempdb wird immer uebersprungen.
      - Systemdatenbanken (master, model, msdb) werden uebersprungen, ausser
        -IncludeSystemDatabases ist gesetzt.
      - Fehler im Trigger brechen CREATE DATABASE / DROP DATABASE nie ab;
        sie werden ins SQL Server Error Log geschrieben.
      - Existiert master.dbo.sqm_BackupExclude noch nicht, protokolliert der
        Trigger eine Warnung und beendet sich sauber.

    In AlwaysOn-Umgebungen wird der Trigger automatisch auf allen Secondary-Repliken
    registriert, sofern -SkipAlwaysOnPropagation nicht gesetzt ist.

    Mit -Remove wird der Trigger geloescht (inkl. Secondaries).

    Triggername: trg_sqm_BackupExclude_AutoSync

**Parameters:**

- **-SqlInstance** - SQL Server-Instanz. Standard: $env:COMPUTERNAME.
- **-SqlCredential** - PSCredential fuer SQL-Authentifizierung. Standard: Windows-Auth.
- **-IncludeSystemDatabases** - Wenn gesetzt, werden auch master, model und msdb automatisch verwaltet. Fuer Standardinstallationen nicht empfohlen.
- **-Remove** - Entfernt den Trigger (auf Primary und ggf. Secondaries).
- **-SkipAlwaysOnPropagation** - Verhindert die automatische Propagierung auf AlwaysOn-Secondaries.
- **-EnableException** - Loest bei Fehlern sofort eine Exception aus statt Write-Error.

**Examples (4):**

```powershell
    Register-sqmBackupExcludeTrigger

```powershell
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01"

```powershell
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01" -Remove
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01"

```powershell
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01" -WhatIf

### Show-sqmBackupExcludeForm

WinForms-Dialog zur Verwaltung der Backup-Ausschlusstabelle (master.dbo.sqm_BackupExclude).

    Zeigt alle Eintraege aus master.dbo.sqm_BackupExclude in einem Grid an.
    Der Anwender kann IsActive per Checkbox an- oder abwaehlen und den Reason-Text
    aendern. Verwaiste Eintraege (IsOrphaned=1) werden farblich hervorgehoben.

    Ablauf:
      1. SqlInstance eingeben (Standard: $env:COMPUTERNAME).
      2. "Sync & Laden" — fuehrt Sync-sqmBackupExcludeTable aus und laedt das Grid.
      3. IsActive-Haken setzen/entfernen, ggf. Reason anpassen.
      4. "Speichern" — schreibt nur geaenderte Zeilen per UPDATE zurueck.

**Parameters:**

- **-SqlInstance** - SQL-Instanz, die beim Oeffnen des Dialogs vorbelegt wird.
- **-SqlCredential** - Optionale Anmeldedaten (PSCredential). Ohne Angabe: Windows-Authentifizierung.

**Examples (2):**

```powershell
    Show-sqmBackupExcludeForm

```powershell
    Show-sqmBackupExcludeForm -SqlInstance "SQL01\INST1"

## 7. Configuration Management

### Compare-sqmServerConfiguration

Compares important configuration settings between two SQL Server instances.

Displays differences in the following areas: sp_configure, instance properties (Collation, Version, MaxMemory), database settings (optional). Output as a list with old/new values.

**Parameters:**

- **-SourceInstance** - Source instance (reference).
- **-TargetInstance** - Target instance (server to compare). Mandatory.
- **-SqlCredential** - PSCredential for both instances (if identical). For different credentials, separate parameters are required (simplified).
- **-CompareDatabases** - When set, databases (Name, Owner, RecoveryModel, Collation) are compared.
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
Compare-sqmServerConfiguration -SourceInstance "SQL01" -TargetInstance "SQL02"

### Export-sqmServerConfiguration

Exports all SQL Server configuration settings to a JSON snapshot file.

This function reads comprehensive configuration data from a SQL Server instance
and saves it as a JSON snapshot with timestamp. The snapshot can be used for
documentation, comparison, or rollback purposes.

Captured settings include:
- sp_configure values (MaxServerMemory, MAXDOP, xp_cmdshell, etc.)
- Instance properties (BackupDirectory, DefaultFile, DefaultLog, Collation, etc.)
- Service configuration (SQL Server, Agent, SSRS, SSIS start mode and accounts)
- Startup parameters (registry trace flags, etc.)
- TempDB configuration
- Database Mail profiles (if configured)
- Linked Servers
- Database overview (optional, slower)

**Parameters:**

- **-SqlInstance** - Target SQL Server instance (default: $env:COMPUTERNAME).
- **-SqlCredential** - Optional alternative credentials (PSCredential object).
- **-OutputPath** - Path where JSON snapshot will be saved.
Default: $env:ProgramData\sqmSQLTool\Snapshots
- **-Label** - Optional descriptive label for this snapshot (e.g., "before MaxMemory change").
Included in the JSON metadata.
- **-IncludeDatabases** - When set, includes database-level settings (slower operation).
- **-EnableException** - Switch to allow exceptions to pass through (default: errors logged as warnings).

**Examples (3):**

```powershell
# Create a snapshot before making configuration changes
$snap = Export-sqmServerConfiguration -SqlInstance "SQL01" -Label "before MaxMemory change"
Write-Host "Snapshot saved to: $($snap.SnapshotPath)"

```powershell
# Export with custom output path
Export-sqmServerConfiguration -SqlInstance "SQL01" `
  -OutputPath "C:\Backups\SQLSnapshots" `
  -Label "production-baseline"

```powershell
# Full export including databases
Export-sqmServerConfiguration -SqlInstance "SQL01" `
  -IncludeDatabases `
  -Label "complete-inventory"

### Invoke-sqmConfigRollback

Restores SQL Server configuration from a previously exported snapshot.

This function reads a JSON snapshot (created by Export-sqmServerConfiguration)
and applies those settings back to a SQL Server instance. It supports a
comprehensive rollback of configuration changes.

Supported rollback operations:
- sp_configure values (most settings; some require SQL restart)
- Instance properties (BackupDirectory, DefaultFile, DefaultLog)
- Service start mode (requires local admin on the server)
- Database Mail profiles
- Linked Server settings (limited, via T-SQL)

The function supports -WhatIf to preview changes before applying them.

**Parameters:**

- **-SqlInstance** - Target SQL Server instance (default: $env:COMPUTERNAME).
- **-SqlCredential** - Optional alternative credentials (PSCredential object).
- **-SnapshotPath** - Full path to the JSON snapshot file to restore from.
Required parameter.
- **-Category** - Limit rollback to specific categories.
Valid values: 'SpConfigure', 'InstanceProperties', 'Services', 'DatabaseMail', 'All'.
Default: 'All'
- **-WhatIf** - Show what would be changed without making actual modifications.
- **-Force** - Skip confirmation dialog and apply changes immediately.
- **-EnableException** - Switch to allow exceptions to pass through (default: errors logged as warnings).

**Examples (4):**

```powershell
# Preview what would be restored
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -WhatIf

```powershell
# Apply rollback (with confirmation)
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json"

```powershell
# Force rollback without confirmation
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -Force

```powershell
# Rollback only sp_configure settings
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -Category 'SpConfigure' `
  -Force

### Set-sqmConfig

Sets one or more configuration values for the MSSQLTools module.

Allows setting of LogPath, OutputPath, CentralPath, Ola job names,
    TSM management classes, the HPU domain group mapping, and the
    SSRS installer path (SsrsInstallerPath).
    Each path is validated for existence or creatability.
    The configuration is permanently saved in a JSON file in the user profile.

**Parameters:**

- **-LogPath** - Directory for log files (Invoke-sqmLogging).
- **-OutputPath** - Default output directory for reports.
- **-CentralPath** - Optional central storage directory (additional copy).
- **-OlaJobNameFull** - Name of the full backup job for user databases.
- **-OlaJobNameDiff** - Name of the diff backup job for user databases.
- **-OlaJobNameLog** - Name of the log backup job for user databases.
- **-OlaJobNameIndexOpt** - Name of the IndexOptimize job.
- **-OlaJobNameIntUserDb** - Name of the IntegrityCheck job for user databases.
- **-OlaJobNameIntSysDb** - Name of the IntegrityCheck job for system databases.
- **-OlaJobNameSysDbBackup** - Name of the full backup job for system databases.
- **-TsmManagementClasses** - Array of valid TSM management classes (e.g. 'MC_B_NL.NL_42.42.NA').
- **-HpuDomainGroupMap** - Array of PSCustomObject with fields DomainPattern (wildcard) and GroupNamePattern (sAMAccountName suffix of the HPU allow group). Evaluated by Get-sqmHpuAllowGroup. Entries are checked in order; the first match wins. Example: Set-sqmConfig -HpuDomainGroupMap @( [PSCustomObject]@{ DomainPattern = 'your.domain';   GroupNamePattern = 'Fg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }, [PSCustomObject]@{ DomainPattern = '*.your.domain'; GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }, [PSCustomObject]@{ DomainPattern = '*';                     GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' } )
- **-SsrsInstallerPath** - Full UNC or local path to the SSRS installer file (SQLServerReportingServices.exe or .msi). Used by Install-sqmSsrsReportServer when -InstallerPath is not specified. Example: '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe'
- **-CheckProfile** - Check-Profil fuer Invoke-sqmSetupReport und verwandte Checks. Auto  = FI-TS-Checks nur wenn sqmIsFitsEnvironment erkannt (Standard) FiTs  = FI-TS-Checks immer erzwingen (auch ausserhalb der Domaene) Generic = nur Standard-Checks, keine FI-TS-spezifischen Pruefungen
- **-CheckCostThresholdMin** - Mindestwert fuer Cost Threshold for Parallelism im Setup-Check. Standard: 50
- **-CheckTempDbMaxFiles** - Maximale TempDB-Dateianzahl im Setup-Check. Standard: 8
- **-CheckDiskBlockSize** - Empfohlene NTFS-Blockgroesse in Bytes fuer Get-sqmDiskBlockSize. Standard: 65536 (64 KB)
- **-Language** - Output language of the module. Allowed values: de-DE, en-US. Default: de-DE. Example: Set-sqmConfig -Language en-US
- **-PassThru** - Returns the updated configuration as an object.

**Examples (4):**

```powershell
Set-sqmConfig -LogPath "D:\Logs" -OlaJobNameFull "Prod-FULL"

```powershell
Set-sqmConfig -TsmManagementClasses @('MC_10','MC_30','MC_100')

```powershell
Set-sqmConfig -HpuDomainGroupMap @(
        [PSCustomObject]@{ DomainPattern = '*.sfinance.net'; GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
        [PSCustomObject]@{ DomainPattern = '*';              GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }
    )

```powershell
Set-sqmConfig -SsrsInstallerPath '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe'

### Get-sqmConfig

Returns the current module configuration.

Without parameters, the entire configuration is returned as a hashtable.
    With -Key, the value of the requested key is returned.
    If the key does not exist, a warning is shown and $null is returned.

    NOTE: Initialization of $script:sqmModuleConfig is performed exclusively
    in sqmSQLTool.psm1. This file contains only the Get-sqmConfig function.

**Parameters:**

- **-Key** - Name of the configuration key (e.g. 'LogPath', 'OutputPath', 'CentralPath').

**Examples (2):**

```powershell
Get-sqmConfig

```powershell
Get-sqmConfig -Key 'OutputPath'

### Set-sqmTcpPort

Konfiguriert den TCP-Port einer SQL Server-Instanz ueber die Registry.

Setzt den statischen TCP-Port fuer eine SQL Server-Instanz.
    Der Port wird aus BasePort und PortIncrement berechnet:
        - Default-Instanz (MSSQLSERVER): Port = BasePort
        - Named Instance:                Port = BasePort + (InstanzNummer * PortIncrement)

    Die Instanznummer wird aus dem Instanznamen extrahiert wenn moeglich
    (z.B. INST01 -> 1, INST02 -> 2). Ist keine Zahl im Namen enthalten,
    wird eine fortlaufende Nummer anhand der Registry-Reihenfolge vergeben.

    Aenderungen werden erst nach Neustart des SQL Server-Dienstes aktiv.
    Die Funktion startet den Dienst NICHT automatisch neu.

**Parameters:**

- **-SqlInstance** - Name der SQL-Instanz (z.B. "MSSQLSERVER" fuer Default, "INST01" fuer Named Instance). Darf auch als SERVERNAME\INSTANZNAME angegeben werden - der Servername wird ignoriert.
- **-BasePort** - Basisport. Standard: 1433.
- **-PortIncrement** - Schrittweite pro Instanz. Standard: 10.
- **-InstanceNumber** - Optionale explizite Instanznummer (ueberschreibt Auto-Erkennung aus Instanzname).

**Examples (2):**

```powershell
Set-sqmTcpPort -SqlInstance 'MSSQLSERVER' -BasePort 1433

```powershell
Set-sqmTcpPort -SqlInstance 'INST01' -BasePort 1433 -PortIncrement 10

### Invoke-sqmCollationChange

Automatically changes the server collation of a SQL Server instance.

Changes the SQL Server instance collation using the undocumented method
    "sqlservr.exe -m -T4022 -T3659 -q '<Collation>'". This function is only
    suitable for local standalone instances (no AGs, no failover cluster).

    The function performs the following steps:
    1. Pre-flight check (connection, current collation, target collation, locality, service, admin rights)
    2. Create rollback documentation
    3. Optional backup of all user databases (-BackupBeforeChange)
    4. Stop SQL Server service
    5. Start sqlservr.exe with new collation (waits for readiness)
    6. Terminate process (sqlservr.exe stops itself)
    7. Start SQL Server service normally
    8. Verify the new collation
    9. Optional: ALTER DATABASE ... COLLATE for user databases (-IncludeUserDatabases)

**Parameters:**

- **-SqlInstance** - SQL Server instance (must be local). Default: current computer name.
- **-SqlCredential** - PSCredential for the SQL connection.
- **-NewCollation** - Target collation (e.g. 'Latin1_General_CI_AS').
- **-IncludeUserDatabases** - When set, the default collation of all user databases is also changed.
- **-BackupBeforeChange** - Creates a full backup of all user databases before the change.
- **-ExcludeDatabase** - Databases to exclude from -IncludeUserDatabases (wildcards allowed).
- **-ServiceName** - Windows service name (automatically determined from SqlInstance if not specified).
- **-StartupTimeoutSeconds** - Maximum wait time for sqlservr.exe in minimal mode (default: 120).
- **-OutputPath** - Output directory for rollback documentation and column script. Default: Get-sqmDefaultOutputPath.
- **-ContinueOnError** - Continue with the next step on error (rarely used).
- **-EnableException** - Throw exceptions immediately.
- **-Confirm** - Request confirmation before stopping the service and making the change.
- **-WhatIf** - Shows all planned steps without execution.

**Examples (2):**

```powershell
Invoke-sqmCollationChange -NewCollation "Latin1_General_CI_AS"

```powershell
Invoke-sqmCollationChange -SqlInstance "SQL01\INST2" -NewCollation "German_CI_AS" -IncludeUserDatabases -BackupBeforeChange

### Set-sqmMaxDop

Sets MAXDOP (max degree of parallelism) to the recommended (or an explicit) value, and optionally the matching "cost threshold for parallelism".

    Companion to Test-sqmMaxDop: instead of only reporting, this applies the value.
    By default MAXDOP is set to the Microsoft recommendation min(8, logical CPUs); pass
    -MaxDop to set an exact value. The recommended "cost threshold for parallelism" (50)
    is set alongside unless -SkipCostThreshold is used. Uses dbatools and is fully
    ShouldProcess-aware (-WhatIf / -Confirm).

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: $env:COMPUTERNAME).
- **-SqlCredential** - Optional SQL authentication credential (PSCredential).
- **-MaxDop** - Explicit MAXDOP value. When omitted, min(8, logical CPUs) is used.
- **-CostThreshold** - Value for "cost threshold for parallelism". Default: 50. Ignored with -SkipCostThreshold.
- **-SkipCostThreshold** - Do not change the cost threshold; only set MAXDOP.
- **-EnableException** - Throw on error instead of logging a warning and returning a failed result.

**Examples (3):**

```powershell
    Set-sqmMaxDop -SqlInstance SQL01
    Sets MAXDOP to min(8, CPUs) and cost threshold to 50.

```powershell
    Set-sqmMaxDop -SqlInstance SQL01 -MaxDop 4 -SkipCostThreshold
    Sets MAXDOP to 4, leaves the cost threshold unchanged.

```powershell
    Set-sqmMaxDop -SqlInstance SQL01 -WhatIf
    Shows the planned MAXDOP/cost-threshold change without applying it.

### Set-sqmMaxMemory

Sets SQL Server "max server memory (MB)" to the recommended (or an explicit) value.

    Companion to Test-sqmMaxMemory: instead of only reporting, this applies the value.
    By default it sets max server memory to a percentage of physical RAM (90% by default);
    pass -MaxMemoryMB to set an exact value. Uses dbatools (Set-DbaMaxMemory) and is fully
    ShouldProcess-aware (-WhatIf / -Confirm).

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: $env:COMPUTERNAME).
- **-SqlCredential** - Optional SQL authentication credential (PSCredential).
- **-RecommendedPct** - Percentage of physical RAM to assign when -MaxMemoryMB is not given. Default: 90.
- **-MaxMemoryMB** - Explicit value in MB. Overrides -RecommendedPct.
- **-EnableException** - Throw on error instead of logging a warning and returning a failed result.

**Examples (3):**

```powershell
    Set-sqmMaxMemory -SqlInstance SQL01
    Sets max server memory to 90% of physical RAM.

```powershell
    Set-sqmMaxMemory -SqlInstance SQL01 -MaxMemoryMB 24576
    Sets max server memory to exactly 24 GB.

```powershell
    Set-sqmMaxMemory -SqlInstance SQL01 -RecommendedPct 80 -WhatIf
    Shows what would be set (80% of RAM) without changing anything.

## 17. SSRS Configuration

### Install-sqmSsrsReportServer



Executes the following steps in sequence:

    [1] Check prerequisites
        - Administrator rights on the target computer
        - Installer (.exe or .msi) found in the configured share (SsrsInstallerPath)
        - SSRS not yet installed (skippable with -Force)

    [2] Installation
        - Copies the installer to a local temp directory (UNC paths are not
          directly supported as process start)
        - Runs the installer silently:
            SQLServerReportingServices.exe
                /quiet /IAcceptLicenseTerms /Edition=<Edition> /IAcceptLicenseTerms
        - Evaluates the exit code (0 = OK, 3010 = restart recommended)
        - Waits up to 60 seconds for the SSRS WMI namespace (service startup)

    [3] Configuration
        - Calls Set-sqmSsrsConfiguration with all passed configuration parameters
          (splatting). Parameters not passed use the defaults of Set-sqmSsrsConfiguration.

    The installer path is read preferably from the -InstallerPath parameter.
    If missing, Get-sqmConfig -Key 'SsrsInstallerPath' is used.
    If that is also not set, an error is thrown.

**Parameters:**

- **-ComputerName** - Target computer. Default: $env:COMPUTERNAME (local). Remote installation via WinRM / PsRemoting is supported.
- **-InstallerPath** - Full UNC or local path to the installation file (SQLServerReportingServices.exe or .msi). Overrides Get-sqmConfig -Key 'SsrsInstallerPath'.
- **-Edition** - License edition for the silent parameter /Edition. Valid values: Eval, Developer, Expr, Web, Standard, Enterprise. Default: 'Developer'.
- **-ProductKey** - Product key (25 characters). If specified, instead of -Edition the parameter /IAcceptLicenseTerms /PID:<Key> is used.
- **-Force** - Perform installation even if SSRS is already installed.
- **-SkipConfiguration** - Install only; do not call Set-sqmSsrsConfiguration.
- **-InstanceName** - SSRS instance name. Passed to Set-sqmSsrsConfiguration. Default: 'MSSQLSERVER'.
- **-DatabaseServer** - SQL Server for the ReportServer database. Passed to Set-sqmSsrsConfiguration.
- **-DatabaseName** - Name of the ReportServer database. Default: 'ReportServer'.
- **-ReportServerUrl** - URL for the ReportServer web service. Default: 'http://+:80/ReportServer'.
- **-ReportsUrl** - URL for the reports portal. Default: 'http://+:80/Reports'.
- **-ServiceAccount** - Windows service account for SSRS.
- **-ServiceAccountPassword** - Password for -ServiceAccount (SecureString).
- **-DatabaseAuthType** - Authentication for the DB connection: 'Windows' or 'SQL'.
- **-DatabaseCredential** - PSCredential for SQL authentication (only with -DatabaseAuthType SQL).
- **-EncryptionKeyFile** - Path for the encryption key backup (.snk).
- **-EncryptionKeyPassword** - Password for the key backup (SecureString).
- **-SkipDatabase** - Skip database configuration in Set-sqmSsrsConfiguration.
- **-SkipUrls** - Skip URL configuration in Set-sqmSsrsConfiguration.
- **-SkipServiceAccount** - Skip service account configuration in Set-sqmSsrsConfiguration.
- **-SkipEncryptionKeyBackup** - Skip the key backup in Set-sqmSsrsConfiguration.
- **-Credential** - PSCredential for the WinRM connection to the target computer (remote operation).
- **-OutputPath** - Output directory for the configuration report.
- **-WmiWaitSeconds** - Maximum wait time in seconds for the SSRS WMI namespace after installation. Default: 60.
- **-ContinueOnError** - Do not treat configuration errors as terminating.
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
Install-sqmSsrsReportServer

    Installs SSRS using the installer path stored in sqmConfig,
    Edition Developer, followed by full configuration with default values.

```powershell
Install-sqmSsrsReportServer `
        -InstallerPath '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe' `
        -Edition Standard `
        -DatabaseServer 'SQL-AG-Listener' `
        -ServiceAccount 'DOMAIN\svc_ssrs' `
        -EncryptionKeyPassword (Read-Host -AsSecureString 'Key-Passwort')

```powershell
Install-sqmSsrsReportServer -SkipConfiguration -WhatIf

    Shows what would be installed without making any changes.

### Set-sqmSsrsConfiguration



Performs a complete initial or re-configuration of SSRS.
        Supports Native Mode and SharePoint Integrated Mode (automatic detection).

        Configurable areas (individually disableable):
        - Service account (SetWindowsServiceIdentity)
        - Database (create, grant permissions, set connection)
        - URLs (ReportServer Web Service + Portal, Native Mode only)
        - Encryption key (BackupEncryptionKey)

        For AlwaysOn Availability Groups (AG), the database server is automatically
        detected as a listener; the DB is created on the primary replica and the
        connection is configured to point to the listener.

        Optionally, a Policy-Based Management (PBM) policy (e.g. 'Password Policy')
        can be disabled before database creation and re-enabled after successful configuration.

**Parameters:**

- **-ComputerName** - SSRS server (local or remote). Default: $env:COMPUTERNAME.
- **-InstanceName** - SSRS instance name. Default: 'MSSQLSERVER'.
- **-DatabaseServer** - SQL Server instance or AG listener for the ReportServer database. Default: $ComputerName.
- **-DatabaseName** - Name of the ReportServer main database. Default: 'ReportServer'.
- **-ReportServerUrl** - URL for the ReportServer Web Service. Default: 'http://+:80/ReportServer'
- **-ReportsUrl** - URL for the Reports Manager / Web Portal. Default: 'http://+:80/Reports'
- **-ServiceAccount** - Windows service account for SSRS (e.g. 'DOMAIN\user' or 'NT SERVICE\...').
- **-ServiceAccountPassword** - Password for -ServiceAccount (SecureString). Not needed for managed service accounts.
- **-DatabaseAuthType** - Authentication for the DB connection: 'Windows' (default) or 'SQL'.
- **-DatabaseCredential** - PSCredential for SQL authentication (only with -DatabaseAuthType SQL).
- **-EncryptionKeyFile** - Path for the encryption key backup (.snk). If not specified, the file is stored in OutputPath with the name 'SsrsEncryptionKey_<Instance>_<Date>.snk'.
- **-EncryptionKeyPassword** - Password to protect the key file (SecureString). Required when a backup is to be created.
- **-PbmPolicyName** - Name of a Policy-Based Management policy (e.g. 'Password Policy') that is disabled before database creation and re-enabled after successful configuration.
- **-SkipDatabase** - Skip database configuration.
- **-SkipUrls** - Skip URL configuration (Native Mode only).
- **-SkipServiceAccount** - Skip service account configuration.
- **-SkipEncryptionKeyBackup** - Skip encryption key backup.
- **-Credential** - PSCredential for the WinRM connection (remote operation only).
- **-OutputPath** - Output directory for the configuration report and optionally the key file. Default: Get-sqmDefaultOutputPath.
- **-ContinueOnError** - Continue with the next step on error (rarely used).
- **-EnableException** - Throw exceptions immediately.
- **-Confirm** - Request confirmation before execution.
- **-WhatIf** - Shows what would happen without making any changes.

**Examples (2):**

```powershell
Set-sqmSsrsConfiguration

```powershell
Set-sqmSsrsConfiguration -ComputerName "SSRS01" -DatabaseServer "AG_Listener" -PbmPolicyName "Password Policy"

### Set-sqmSsrsHttpsCertificate

Binds a Windows certificate to SSRS or Power BI Report Server for HTTPS access.

Eliminates browser security warnings by binding a valid certificate to the SSRS
		or Power BI Report Server (PBIRS) HTTPS endpoint via the WMI configuration interface.

		The function performs the following steps:
		1. Discovers the SSRS/PBIRS WMI namespace dynamically under
		   root\Microsoft\SqlServer\ReportServer\{Instance}\v{Version}\Admin
		2. Validates the certificate in Cert:\LocalMachine\My by thumbprint
		3. Lists and removes existing HTTPS URL reservations for all web applications
		4. Removes existing SSL certificate bindings
		5. Reserves HTTPS URLs for all applicable web applications
		6. Creates the SSL certificate binding
		7. Optionally sets SecureConnectionLevel to require HTTPS
		8. Calls ApplyChanges() to finalize

		Supported application names (auto-detected by version):
		- ReportServerWebService  (always present)
		- ReportManager           (SSRS 2016 and earlier, v13-)
		- ReportServerWebApp      (SSRS 2017+ / PBIRS, v14+)

		Prerequisites: Local administrator rights on the target computer.
		For remote execution, WinRM must be available.
		The certificate must already be present in the LocalMachine\My store on the target.
		The SSRS service may need to be restarted after binding.

**Parameters:**

- **-ComputerName** - Target computer name or IP address. Default: localhost ($env:COMPUTERNAME).
- **-Thumbprint** - Mandatory. Certificate thumbprint (40 hex characters) from the LocalMachine\My store. Spaces are automatically removed from the thumbprint string.
- **-Port** - HTTPS port to bind. Default: 443.
- **-InstanceName** - SSRS WMI instance name (e.g. "RS_SSRS", "RS_PBIRS"). Auto-detected when only one instance is found under the WMI namespace. Required when multiple instances exist on the same server.
- **-IPAddress** - IP address for the SSL binding. Default: "0.0.0.0" (all interfaces).
- **-RequireSSL** - When specified, sets SecureConnectionLevel = 1 (HTTPS required). Default: SecureConnectionLevel = 0 (HTTPS optional, HTTP still allowed).
- **-Credential** - PSCredential for the WinRM session (remote operation only).
- **-WhatIf** - Shows what would happen without making any changes.
- **-Confirm** - Prompts for confirmation before applying changes.

**Examples (3):**

```powershell
Set-sqmSsrsHttpsCertificate -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"

		Binds the specified certificate to SSRS on the local machine on port 443.
		The SSRS instance is auto-detected.

```powershell
Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER01" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Port 8443 -InstanceName "RS_PBIRS" -RequireSSL

		Binds the certificate to Power BI Report Server on REPSERVER01, port 8443,
		and requires HTTPS (SecureConnectionLevel = 1).

```powershell
$cred = Get-Credential
		Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER02" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Credential $cred -WhatIf

		Shows what changes would be made on REPSERVER02 without applying them.

## 5. Login & User Security

### Copy-sqmLogins

Copies logins from a source SQL Server instance to a target instance.

Transfers SQL and Windows logins from a source instance to a target instance.

    Process:
        1. Disable policy  (Set-sqmSqlPolicyState -State Disable, if -DisablePolicy $true)
        2. Connect + authentication mode check / alignment
        3. Load and filter logins
        4. Check Windows logins against Active Directory (AD module required)
           - Unresolvable logins are skipped and reported as 'AdOrphan'.
        5. Copy logins (Copy-DbaLogin, password hash + SID mapping)
        6. Repair orphaned users on all user databases on the target
           (Repair-DbaDbOrphanUser - always runs, no optional switch)
        7. Re-enable policy - guaranteed via finally block, even on error.

    Authentication mode alignment:
        If the source uses Mixed Mode (SQL + Windows) and the target is set to
        Windows Authentication only, the target is automatically switched to Mixed Mode
        - provided -AdjustAuthMode is specified. Without this switch, the function
        aborts with an error and reports the discrepancy.
        The SQL Server service must be restarted after an authentication mode change.
        With -RestartServiceIfRequired this is done automatically.

    AD check:
        All Windows logins (type WindowsUser / WindowsGroup) from the source are
        validated against Active Directory via Get-ADObject before copying.
        Unresolvable logins are removed from the copy batch and reported as
        'AdOrphan' in the result.

        If the ActiveDirectory module is not present, -AdModuleAction controls behavior:
            'Install' (default) - Install-sqmAdModule is called.
                                  If installation fails, the AD check is
                                  skipped with a warning.
            'Skip'              - Warning, AD check is skipped.
            'Abort'             - Error, function aborts.

    Login filter:
        System logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*, BUILTIN\*)
        are excluded by default. With -IncludeSystemLogins they are included.
        Individual logins can be filtered via -ExcludeLogin.

    Passwords for SQL logins:
        Copy-DbaLogin transfers the password hash (HASHED) directly.
        SIDs are preserved (SID mapping).

    Orphaned users:
        After copying, Repair-DbaDbOrphanUser is automatically run on all user
        databases on the target (no optional switch).

    Policy:
        Before copying, Set-sqmSqlPolicyState disables the configured default policy
        on the target instance. After completion (even on error) it is guaranteed to
        be re-enabled via a finally block.
        Controlled by -DisablePolicy (default: $true).
        The finally block re-enables the policy only if it was previously successfully
        disabled ($policyWasDisabled flag).

**Parameters:**

- **-Source** - Source SQL Server instance. Mandatory.
- **-Destination** - Target SQL Server instance. Mandatory.
- **-SqlCredential** - Optional PSCredential for both instances (source and target). For different credentials use -SourceCredential / -DestinationCredential.
- **-SourceCredential** - PSCredential specifically for the source instance.
- **-DestinationCredential** - PSCredential specifically for the target instance.
- **-Login** - Filters the copy operation to these login names (wildcards allowed). Without specification, all logins (after ExcludeLogin filter) are copied.
- **-ExcludeLogin** - Logins that should not be copied (wildcards allowed). Example: 'AppLogin_*', 'OldUser'.
- **-IncludeSystemLogins** - When set, system logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*) are also copied. Default: $false.
- **-DisablePolicy** - Controls whether the default policy on the target is disabled before copying and re-enabled afterwards (via Set-sqmSqlPolicyState). Default: $true. Set to $false to skip policy handling.
- **-AdjustAuthMode** - When set and the target is Windows-only auth but the source uses Mixed Mode, the target is automatically switched to Mixed Mode. Without this switch the function aborts on mode mismatch.
- **-RestartServiceIfRequired** - When set, the SQL Server service on the target server is automatically restarted after an authentication mode change. Without this switch, only a warning is displayed.
- **-Force** - Existing logins on the target server are overwritten.
- **-AdModuleAction** - Controls behavior when the ActiveDirectory module is not present. 'Install' (default) - Install-sqmAdModule is called to install the module. If installation fails, the AD check is skipped with a warning. 'Skip'              - AD check is skipped with a warning. 'Abort'             - Function aborts with an error.
- **-ContinueOnError** - Continue with the next login on error.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before critical actions.
- **-WhatIf** - Shows all planned actions without executing them.

**Examples (4):**

```powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02'

    Copies all non-system logins. Policy is disabled/re-enabled,
    AD check and orphan repair run automatically.

```powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -AdjustAuthMode -RestartServiceIfRequired

    Copies all logins and switches the target server to Mixed Mode if needed.
    Automatically restarts the SQL service if required.

```powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -Login 'App_*' -Force

    Copies only logins starting with 'App_' and overwrites existing ones.

```powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -DisablePolicy $false -WhatIf

    Simulates the operation without policy handling.

### Get-sqmADAccountStatus

Checks the status of an Active Directory user account.

Determines the account status using the ActiveDirectory module (RSAT) with
        automatic fallback to ADSI if RSAT is not available.
        Returns a detailed PSObject with Enabled, LockedOut, PasswordExpired
        and AccountExpired.

**Parameters:**

- **-SamAccountName** - The SamAccountName of the AD account to check.
- **-DomainController** - Optional target DC. Only used via the RSAT path.

**Examples (3):**

```powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe'

```powershell
'jdoe','jsmith' | Get-sqmADAccountStatus

```powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe' -DomainController 'DC01'

### Get-sqmADGroupMembers

Lists all members of an Active Directory group.

Simple, reliable function to list members of an AD group (including nested groups).
    Useful when SQL Server access fails and you need to check group permissions.

    Supports NESTED GROUPS: Recursively resolves all members, including members of nested groups.
    Example: If GroupA contains GroupB (which contains User2), both GroupB and User2 are returned.

    Methods:
    1. Get-ADGroupMember -Recursive (if ActiveDirectory module available) — Resolves nested groups
    2. LDAP direct query (fallback, no module required) — Direct members only

**Parameters:**

- **-GroupName** - Name of the AD group. Pipeline-capable. Format: "GroupName" or "DOMAIN\GroupName"
- **-Domain** - Optional: AD domain (e.g., "FITS.LOCAL", "corp.de") If not specified, auto-detects current domain.

**Examples (2):**

```powershell
Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"

```powershell
Get-sqmADGroupMembers -GroupName "Administrators" -Domain "FITS"

### Get-sqmLoginSettings

Zeigt alle Logins mit Default-Datenbank und Spracheinstellung.

Liest sys.server_principals und gibt pro Login aus:
    - Name, Typ (SQL / Windows-User / Windows-Gruppe)
    - Default-Datenbank
    - Default-Sprache
    - Aktiviert / deaktiviert
    - Erstellungs- und Aenderungsdatum

    Ausgabe direkt als Objekte. Optional als CSV nach OutputPath.

**Parameters:**

- **-SqlInstance** - SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.
- **-SqlCredential** - Optionales PSCredential.
- **-LoginType** - Filter: 'All' (Standard), 'SQL', 'Windows'
- **-ExcludeSystemLogins** - NT SERVICE\*, NT AUTHORITY\*, ##MS_*## automatisch ausblenden.
- **-DefaultDatabase** - Filter: nur Logins mit dieser Default-Datenbank anzeigen.
- **-DefaultLanguage** - Filter: nur Logins mit dieser Sprache anzeigen.
- **-OutputPath** - Wenn angegeben, wird eine CSV-Datei geschrieben. Standard: kein Export.
- **-ContinueOnError** - Bei Fehler auf einer Instanz fortfahren.
- **-EnableException** - Fehler sofort als Ausnahme ausloesen.

**Examples (4):**

```powershell
Get-sqmLoginSettings

```powershell
Get-sqmLoginSettings -SqlInstance "SQL01" -ExcludeSystemLogins

```powershell
Get-sqmLoginSettings -SqlInstance "SQL01" -DefaultDatabase "master" -DefaultLanguage "us_english"

```powershell
Get-sqmLoginSettings -SqlInstance "SQL01","SQL02" -OutputPath "C:\Reports"

### Get-sqmSysadminAccounts

Retrieves all logins with sysadmin rights on a SQL Server instance.

Queries sys.server_principals and sys.server_role_members and returns
    all direct members of the sysadmin server role.

    Per login the following information is determined:
    - Login name and login type (SQL, Windows user, Windows group, etc.)
    - Enabled / disabled
    - Is SA (SID 0x01) or not
    - Creation date
    - Whether the login was explicitly excluded (-ExcludeLogin)

    With -ExcludeLogin, known/expected accounts can be filtered from the report
    (they are marked as 'Excluded').

    With -ExcludeSysAccounts, known SQL Server system and service accounts are
    automatically marked as 'Excluded'.

    BUILTIN\Administrators receives its own status 'BuiltinAdmins'
    and is NOT automatically excluded - security review required.

    Output:
        SysadminAccounts_<instance>_<date>.txt   - Readable report
        SysadminAccounts_<instance>_<date>.csv   - Machine-readable

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-ExcludeLogin** - Logins to be marked as 'Excluded' (wildcards allowed).
- **-ExcludeSysAccounts** - When set, known system accounts are automatically excluded.
- **-IncludeDisabled** - If $true (default), disabled sysadmin logins are also included.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Continue on error for an instance.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before writing files.
- **-WhatIf** - Shows which files would be created without writing them.

**Examples (2):**

```powershell
Get-sqmSysadminAccounts

```powershell
Get-sqmSysadminAccounts -SqlInstance "SQL01" -ExcludeSysAccounts

### Invoke-sqmSaObfuscation

Obfuscates the SA account on a SQL Server instance by renaming it, disabling it, and setting a random password.

Performs the following steps:
    1. Checks that at least one other active login with sysadmin rights exists (aborts otherwise).
    2. Identifies the SA account via its fixed SID 0x01 (rename-safe).
    3. Generates a secure random password (configurable length).
    4. Sets the new password.
    5. Renames the account (default: 'sqmsa').
    6. Disables the account.

    The generated password is returned in the output object — the caller is responsible for storing it securely.

**Parameters:**

- **-SqlInstance** - Target SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the SQL connection.
- **-NewName** - New name for the SA account. Default: 'sqmsa'.
- **-PasswordLength** - Length of the random password (12-128). Default: 18.
- **-ContinueOnError** - Continue with the next instance on error (otherwise aborts).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Prompts for confirmation before critical changes (default: off).
- **-WhatIf** - Shows what would happen without making any changes.

**Examples (2):**

```powershell
Invoke-sqmSaObfuscation -SqlInstance "SQL01"

```powershell
Invoke-sqmSaObfuscation -SqlInstance "SQL01" -NewName "hidden_sa" -PasswordLength 24

### Remove-sqmAdOrphanLogin

Removes Windows logins whose Active Directory account no longer exists (AD orphans).

Safe, deliberate cleanup of "dead" AD logins on a SQL Server instance. This is the manual
    counterpart to the detection-only -AuditAdOrphans option of New-sqmAutoLoginSyncJob and is
    intentionally NOT meant for unattended or scheduled use: a missing AD account can be a
    transient domain controller or trust problem, and dropping a valid login would cause an outage.

    Safety model:
    1. The ActiveDirectory module is REQUIRED. If it is missing, -AdModuleAction controls behavior
       (default 'Abort'). Without AD lookups orphans cannot be verified, so nothing is deleted.
    2. Only Windows logins (WINDOWS_LOGIN / WINDOWS_GROUP) are considered.
    3. System logins and ALL sysadmin logins are excluded from removal, always.
    4. A login is treated as an orphan ONLY when Active Directory positively reports the account as
       missing. If the AD query fails, the login is skipped (never deleted).
    5. Logins that own a database are skipped (dropping them would fail or orphan the ownership).
    6. Before removal a rollback script (CREATE LOGIN FROM WINDOWS + server role memberships) is
       written per run, unless -SkipBackup is set.
    7. Every removal honors -WhatIf / -Confirm (ConfirmImpact = High), so nothing is dropped silently.

**Parameters:**

- **-SqlInstance** - Target SQL Server instance. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the instance.
- **-ExcludeLogin** - Additional logins to exclude from removal (wildcards allowed). Combined with the always-on safety exclusions (system and sysadmin logins).
- **-AdModuleAction** - Behavior when the ActiveDirectory module is not present: 'Abort'   (default) - stop with an error; nothing is verified or deleted. 'Install'           - try Install-sqmAdModule, abort if it fails. 'Skip'              - NOT allowed for a destructive operation; treated like 'Abort'.
- **-BackupPath** - Directory for the rollback script. Default: C:\System\WinSrvLog\MSSQL (created if missing).
- **-SkipBackup** - Skip writing the rollback script. Not recommended.
- **-EnableException** - Throw exceptions immediately instead of returning error status.

**Examples (3):**

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -WhatIf
    Lists exactly which AD-orphaned logins would be removed, without changing anything.

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01"
    Removes confirmed AD-orphaned logins after a rollback backup, asking for confirmation per login.

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -ExcludeLogin 'DOMAIN\KeepThis*' -Confirm:$false
    Removes confirmed orphans (except the excluded pattern) without interactive confirmation.

### Set-sqmDatabaseOwner

Sets the owner of one or more databases to a uniform login.

Checks and corrects the database owner on one or more SQL Server instances.
    Typical use case: after restores or migrations the owner is often a login that no
    longer exists or is incorrect. The function uniformly sets it to the sa account
    (regardless of the actual sa name, which may have been renamed via obfuscation) or
    any other login.

    Process per database:
      1. Read current owner
      2. Check whether a change is necessary (already correct -> skip)
      3. Check whether the target login exists on the instance
      4. Execute ALTER AUTHORIZATION ON DATABASE::<Name> TO <Login>
      5. Log result

    Returns a status object for each database:
      Status = OK / Skipped / Failed / NotFound

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-Database** - Database name(s). Wildcards allowed (e.g. 'Prod*'). Default: all user databases.
- **-ExcludeDatabase** - Databases to exclude. Wildcards allowed.
- **-OwnerLogin** - Login to set as the new owner. Default: sa account (automatically determined via SID 0x01, regardless of whether it has been renamed).
- **-IncludeSystemDatabases** - Also include system databases (master, model, msdb). Default: $false. tempdb is always excluded.
- **-Force** - Also process databases that already have the correct owner (forces re-assignment).
- **-OutputPath** - Directory for the change log. Default: from module configuration.
- **-ContinueOnError** - Continue on error for one instance. Default: $false.
- **-EnableException** - Throw exceptions immediately.

**Examples (4):**

```powershell
# Set sa account on all user databases
    Set-sqmDatabaseOwner -SqlInstance "SQL01"

```powershell
# Specific databases with a custom login
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -Database "Prod*" -OwnerLogin "svc_sqlowner"

```powershell
# Pipeline across multiple instances
    'SQL01','SQL02' | Set-sqmDatabaseOwner

```powershell
# WhatIf - only show what would be changed
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -WhatIf

### Grant-sqmTemporarySysadmin

Grants an AD login temporary sysadmin rights for X days and revokes them automatically via a self-deleting SQL Agent job — failover-robust across all AlwaysOn replicas.

For patch/installation situations: make an AD user (or AD group) a sysadmin for a limited time.
    Without -StartDate the rights are granted immediately (inline) plus a revoke job on today+X;
    with -StartDate a grant job on the start date and a revoke job on start date+X are created.

    Only Windows/AD logins (DOMAIN\account or AD group) are supported; SQL-auth logins are rejected.
    If the login does not exist it is created (CREATE LOGIN ... FROM WINDOWS); a configured PBM policy
    (DefaultPolicy) is briefly disabled for the creation and re-enabled afterwards. A login created by
    this tool is removed again on revoke (only if it is not a member of any other server role).

    AlwaysOn (default): if the instance is part of an availability group, login creation, the sysadmin
    grant and the revoke/cleanup are performed on ALL replicas, each with its own locally running,
    self-deleting jobs. Use -PrimaryOnly to limit to the given instance.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - PSCredential for the immediate grant (SQL auth). The agent jobs run under the SQL Agent service account and use no stored credentials.
- **-Login** - AD login / group (DOMAIN\account) to become sysadmin temporarily.
- **-Days** - Duration of the sysadmin rights in days.
- **-StartDate** - Optional activation time. If omitted (or in the past), the grant happens immediately.
- **-PrimaryOnly** - Only handle the given instance, ignore AlwaysOn replicas.
- **-SkipSecondaryServers** - List of replica instance names to skip.
- **-TicketNumber** - Optional ticket/order number for logging.
- **-Force** - Overwrites existing grant/revoke jobs of the same name.

**Examples (3):**

```powershell
Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'DOM\u.maier' -Days 3 -TicketNumber 'INC0012345'
    # Immediate sysadmin for 3 days (on all AG replicas), then automatic revoke.

```powershell
Grant-sqmTemporarySysadmin -Login 'DOM\u.maier' -Days 1 -StartDate '2026-07-01 08:00' -TicketNumber 'CHG7788'
    # Activation 2026-07-01 08:00, revoke 2026-07-02 08:00.

```powershell
Grant-sqmTemporarySysadmin -SqlInstance SQL01 -Login 'DOM\u.maier' -Days 2 -PrimaryOnly -WhatIf
    # Shows only what would happen - on SQL01 only, without replicas.

### Invoke-sqmTempSysadminAction

Performs the actual sysadmin grant/revoke on one instance, optionally creating a missing AD login, removing it again on revoke, and self-deleting the calling SQL Agent job after success.

Called by the agent jobs created by Grant-sqmTemporarySysadmin, but can also be used manually
    (e.g. for an early revoke).

    Grant  -> (optional CREATE LOGIN ... FROM WINDOWS) + ALTER SERVER ROLE [sysadmin] ADD MEMBER
    Revoke -> ALTER SERVER ROLE [sysadmin] DROP MEMBER + (optional DROP LOGIN)

    -RemoveLogin drops the login on revoke only as a safety net: when the login is not a member of any
    further fixed server role besides 'public'. Otherwise it is kept and a warning is logged, so a
    login used elsewhere is never deleted by accident. Every action is written to the module log file
    and the Windows Application event log (source 'sqmSQLTool', incl. ticket number).

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - PSCredential for the SQL connection (SQL authentication).
- **-Login** - Affected Windows/AD login (DOMAIN\account or AD group).
- **-Action** - 'Grant' or 'Revoke'.
- **-CreateLoginIfMissing** - Grant only: creates a missing AD login via CREATE LOGIN ... FROM WINDOWS.
- **-RemoveLogin** - Revoke only: removes the login after the revoke (DROP LOGIN), if it is not attached to any further server role.
- **-DisablePolicy** - Disable the configured PBM policy (DefaultPolicy) before creating a login and re-enable it afterwards. Default: $true.
- **-TicketNumber** - Optional ticket/order number for logging.
- **-JobName** - Optional: name of the calling agent job. Deleted after a successful action (self-deletion).

**Examples (2):**

```powershell
Invoke-sqmTempSysadminAction -SqlInstance SQL01 -Login 'DOM\u.maier' -Action Revoke

```powershell
# Early manual revoke including removal of a self-created login:
    Invoke-sqmTempSysadminAction -Login 'DOM\u.maier' -Action Revoke -RemoveLogin

### New-sqmRandomSaPassword

Generiert ein zufaelliges, richtlinienkonformes SA-Passwort.

    Erstellt ein kryptografisch sicheres Passwort das die SQL Server
    Passwort-Richtlinie erfuellt:
        - Mindestlaenge konfigurierbar (Standard: 20 Zeichen)
        - Mindestens 1 Grossbuchstabe (A-Z)
        - Mindestens 1 Kleinbuchstabe (a-z)
        - Mindestens 1 Ziffer (0-9)
        - Mindestens 1 Sonderzeichen aus dem definierten Set

    Optionaler Datei-Export: Passwort wird DPAPI-verschluesselt in eine
    Textdatei geschrieben (ConvertFrom-SecureString).
    Nur der Benutzer/Computer der exportiert hat kann die Datei wieder lesen.

**Parameters:**

- **-Length** - Laenge des Passworts. Standard: 20. Minimum: 12.
- **-ExportPath** - Optionaler Pfad fuer die verschluesselte Passwort-Datei. Z.B.: C:\System\Passwords\sa_password.txt Wenn leer: kein Export.

**Examples (3):**

```powershell
    $pwd = New-sqmRandomSaPassword
    # Gibt SecureString zurueck

```powershell
    $pwd = New-sqmRandomSaPassword -Length 24 -ExportPath 'C:\System\Passwords\sa.txt'
    # SecureString + DPAPI-Export nach C:\System\Passwords\sa.txt

```powershell
    # Klartext anzeigen (nur fuer Debugging):
    $pwd = New-sqmRandomSaPassword
    $cred = New-Object PSCredential('sa', $pwd)
    $cred.GetNetworkCredential().Password

### Set-sqmSqlPolicyState

Enables or disables a single Policy-Based Management policy on a SQL Server instance.

    Uses dbatools (Get-DbaPbmPolicy) to check whether the specified policy exists on
    the target instance, and then toggles only that policy via its SMO object.

    Unlike older scripts, this does not change the global PBM engine state,
    but only the explicitly named policy.

**Parameters:**

- **-SqlInstance** - Target SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-Policy** - Name of the policy to toggle. Default: from module configuration (DefaultPolicy).
- **-State** - Target state: 'Enable' or 'Disable'.
- **-ContinueOnError** - Continue with the next instance on error.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Prompts for confirmation before toggling.
- **-WhatIf** - Shows what would happen without making any changes.

**Examples (2):**

```powershell
    Set-sqmSqlPolicyState -SqlInstance "SQL01" -Policy "xp_cmdshell must be disabled" -State Disable

```powershell
    "SQL01","SQL02" | Set-sqmSqlPolicyState -Policy "Password Policy" -State Enable

## 12. Server Configuration Testing

### Get-sqmClusterInfo

Retrieves information about a Windows Failover Cluster: cluster name, nodes and roles including IP addresses.

This function queries a Windows Failover Cluster and returns an object containing the cluster name,
    a list of nodes, and a list of roles (cluster groups).
    For each role, the associated IP address resources are also provided.
    By default, the core cluster group ("Cluster Group") and all storage groups ("Available Storage")
    are excluded from the role list.

    If the required PowerShell module 'FailoverClusters' is not available, an attempt is made to
    install the RSAT clustering tools automatically (Windows Server only, administrator rights required).

**Parameters:**

- **-ClusterName** - The name of the cluster to query. If not specified, the function attempts to determine the local cluster (only meaningful on a cluster node).
- **-IncludeCoreGroup** - Switch to include the core cluster group ("Cluster Group") in the roles list. Storage groups are always excluded.
- **-NoAutoInstall** - Suppresses the automatic installation of RSAT clustering tools if the module is missing.
- **-EnableException** - When set, errors are thrown as exceptions (by default an error object is returned).

**Examples (2):**

```powershell
$info = Get-sqmClusterInfo -ClusterName "MYCLUSTER"
    if (-not $info.Success) { Write-Error $info.ErrorMessage; return }
    $info.ClusterName
    $info.Nodes | Format-Table
    $info.Roles | Where-Object OwnerNode -eq "Node1" | Select Name, IPAddresses

```powershell
Get-sqmClusterInfo -IncludeCoreGroup

    Queries the local cluster and returns all roles including the core group.

### Get-sqmPerfCounters

Reads SQL Server performance counters from sys.dm_os_performance_counters.

Returns the most important SQL Server performance counters:
    Buffer Cache Hit Ratio, Page Life Expectancy, Batch Requests/sec,
    compilations, lock waits, memory, connections, scans and more.
    Automatically interprets values and flags notable ones.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: local computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-Category** - Filter on category fragments, e.g. @('Buffer','Memory','Locks'). Default: all key counters.
- **-TopN** - Maximum number of results. Default: 50.
- **-OutputPath** - If specified, a CSV report is saved.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Get-sqmPerfCounters -SqlInstance "SQL01"

```powershell
Get-sqmPerfCounters -SqlInstance "SQL01" -Category "Buffer","Memory"

### Get-sqmSpnReport

Checks the registered SPNs for SQL Server instances (default and named instances).

Automatically determines all SQL Server services on the specified computer,
    identifies the service account per instance and derives the AD account for
    the SPN check.

    Supported service account types:
    - Domain account (DOMAIN\svc_sql)        -> used directly as SPN account
    - Computer-account-based accounts (SYSTEM,
      NETWORK SERVICE, NT SERVICE\*)         -> computer account (DOMAIN\HOSTNAME$)
      The computer account is determined cleanly via
      [System.DirectoryServices.ActiveDirectory.Domain].
    - LOCAL SERVICE                          -> no network identity, SPNs
      not possible -> finding with status 'NoNetwork'

    Per instance, the four expected MSSQLSvc SPNs are checked:
        MSSQLSvc/<Hostname>:<Port>
        MSSQLSvc/<FQDN>:<Port>
        MSSQLSvc/<Hostname>        (default instance only, port 1433)
        MSSQLSvc/<FQDN>            (default instance only, port 1433)

    For named instances (dynamic port via SQL Browser), additional instance-name SPNs are checked:
        MSSQLSvc/<Hostname>:<InstanceName>
        MSSQLSvc/<FQDN>:<InstanceName>

    For AlwaysOn Availability Groups, listener SPNs are also checked:
        MSSQLSvc/<ListenerName>:<Port>
        MSSQLSvc/<ListenerFQDN>:<Port>

    Missing SPNs are prepared as ready-to-use setspn.exe commands that can be handed to the AD
    team. Each per-instance report includes a clean, comment-free "commands only" block (nothing
    but the setspn -S commands plus a trailing setspn -L verification command) that can be
    selected and copied as-is. Additionally, across ALL computers/instances processed in a single
    call, every missing-SPN command is collected into one dedicated hand-off file AND copied
    directly to the Windows clipboard (Set-Clipboard) - ready to paste straight into an email or
    ticket for the AD team, with the setspn -L check command(s) for the affected account(s)
    appended at the end.

    Output per instance:
        SpnReport_<Computer>_<Instance>_<Date>.txt   - Readable report including setspn commands
        SpnReport_<Computer>_<Instance>_<Date>.csv   - Machine-readable (one row per SPN)

    Output for the whole call (only if at least one SPN is missing anywhere):
        SpnReport_SetSpnCommands_<Timestamp>.txt     - Comment-free, copy-paste-ready command list
                                                        for the AD team (also copied to clipboard)

**Parameters:**

- **-ComputerName** - Target computer. Default: local computer. Pipeline-capable.
- **-InstanceFilter** - Optional filter on instance names (wildcards allowed). Example: 'MSSQLSERVER' for default instance only, 'SQL*' for named instances.
- **-OutputPath** - Output directory for report and CSV. Default: module configuration (Get-sqmConfig -Key 'OutputPath').
- **-ContinueOnError** - Continue with the next instance on error.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before creating files.
- **-WhatIf** - Shows which files would be created without writing them.

**Examples (5):**

```powershell
Get-sqmSpnReport

    Checks all SQL Server instances on the local computer.

```powershell
Get-sqmSpnReport -ComputerName 'SQL01' -InstanceFilter 'MSSQLSERVER'

    Checks only the default instance on SQL01.

```powershell
'SQL01','SQL02' | Get-sqmSpnReport -ContinueOnError

    Checks all instances on two servers; errors are skipped.

```powershell
$result = Get-sqmSpnReport -ComputerName 'SQL01'
    $result.DetailRows | Where-Object Status -eq 'Missing' | Select-Object Spn, SetSpnCommand

    Returns only missing SPNs with the ready-to-use setspn command.

```powershell
'SQL01','SQL02','SQL03' | Get-sqmSpnReport
    # Clipboard now holds every missing setspn command across all three servers plus the
    # setspn -L check commands - paste directly into a ticket/email for the AD team.

### Test-sqmSQLFirewall

Tests whether the firewall and network allow a TCP connection to SQL Server.

Attempts to establish a TCP connection to the specified SQL Server and port.
    By default, port 1433 (default instance) is used.

    For named instances, the SQL Browser service (UDP 1434) can additionally be
    queried to determine the dynamic TCP port of the instance.

    Returns one [PSCustomObject] per server/port combination with:
        Server, Port, Instance, TcpReachable, DynamicPort, Status, Message

**Parameters:**

- **-Server** - Hostname or IP address of the SQL Server. Pipeline-capable.
- **-Port** - TCP port to test. Default: 1433. Ignored when -Instance is specified and the SQL Browser provides the dynamic port.
- **-Instance** - Name of the named instance (without server prefix). When specified, the SQL Browser (UDP 1434) is first queried for the dynamic port of the instance, which is then tested via TCP.
- **-TimeoutSeconds** - Timeout for the TCP connection test in seconds. Default: 5.
- **-ContinueOnError** - Continue with the next server on error instead of aborting.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).

**Examples (4):**

```powershell
Test-sqmSQLFirewall -Server "SQL01"

    Tests the default instance on TCP port 1433.

```powershell
Test-sqmSQLFirewall -Server "SQL01" -Port 54321

    Tests a custom port.

```powershell
Test-sqmSQLFirewall -Server "SQL01" -Instance "SAGE"

    Determines the dynamic port of the "SAGE" instance via SQL Browser (UDP 1434)
    and then tests the TCP connection.

```powershell
"SQL01","SQL02","SQL03" | Test-sqmSQLFirewall -Instance "PROD" -TimeoutSeconds 3

    Tests the "PROD" instance on three servers via pipeline.

### Test-sqmSqlInstanceInstalled

Prueft ob eine SQL Server-Instanz auf dem lokalen System installiert ist.

Kombiniert zwei Pruefmethoden:
        1. Registry: HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL
        2. Windows-Dienst: MSSQLSERVER (Default) oder MSSQL$<InstanceName> (Named)

    Gibt ein Objekt mit Installationsstatus, Version, Edition und Dienststatus zurueck.
    Rein lesender Zugriff - keine Aenderungen am System.

**Parameters:**

- **-InstanceName** - Name der zu pruefenden SQL-Instanz. Default: "MSSQLSERVER" (Default-Instanz).

**Examples (3):**

```powershell
Test-sqmSqlInstanceInstalled
    # Prueft Default-Instanz MSSQLSERVER

```powershell
Test-sqmSqlInstanceInstalled -InstanceName 'INST01'

```powershell
if ((Test-sqmSqlInstanceInstalled).IsInstalled) { Write-Host "SQL installiert" }

## 4. Monitoring & Health Checks

### Get-sqmBlockingReport

Retrieves current blocking chains on a SQL Server instance.

Reads sys.dm_exec_requests, sys.dm_exec_sessions and sys.dm_exec_sql_text
    and builds complete blocking chains. For each blocked session the following is returned:
      - Blocking SPID and its SQL text
      - Blocked SPID(s) with wait time, wait type and lock resource
      - Database, login, hostname, program
      - Complete chain (head blocker to all blocked sessions)

    An optional snapshot mode can be enabled: the function then periodically writes
    snapshots as CSV files - useful for Agent jobs for historical analysis.

    Returns an object that can be used directly for further processing:
      .BlockingChains  - List of all chains with head blocker and blocked sessions
      .HeadBlockers    - Only the blocking sessions
      .BlockedSessions - Only the blocked sessions
      .HasBlocking     - $true if blocking was found

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-MinWaitSeconds** - Only report blocking that has been waiting longer than this value (in seconds). Default: 0.
- **-OutputPath** - If specified, a CSV snapshot is written to this directory.
- **-EnableException** - Throw exceptions immediately instead of returning as errors.

**Examples (4):**

```powershell
Get-sqmBlockingReport

```powershell
Get-sqmBlockingReport -SqlInstance "SQL01" -MinWaitSeconds 30

```powershell
# Check whether blocking is currently occurring
    if ((Get-sqmBlockingReport -SqlInstance "SQL01").HasBlocking) { Write-Warning "Blocking detected!" }

```powershell
# Regular snapshot via Agent job
    Get-sqmBlockingReport -SqlInstance "SQL01" -OutputPath "$env:ProgramData\sqmSQLTool\Logs\Blocking"

### Get-sqmConnectionStats

Analyzes active SQL Server connections and connection statistics.

Reads sys.dm_exec_sessions and sys.dm_exec_connections and groups
    by application, login, host or database. Shows connection load,
    active requests, CPU usage and oldest connections.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: local computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-GroupBy** - Grouping criterion: Application | Login | Host | Database. Default: Application.
- **-TopN** - Number of top groups. Default: 25.
- **-IncludeSystemConnections** - Include system connections (is_user_process = 0).
- **-OutputPath** - If specified, a CSV report is saved.
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
Get-sqmConnectionStats -SqlInstance "SQL01"

```powershell
Get-sqmConnectionStats -SqlInstance "SQL01" -GroupBy Login -TopN 10

```powershell
Get-sqmConnectionStats -SqlInstance "SQL01" -GroupBy Database -IncludeSystemConnections

### Get-sqmDatabaseHealth

Aggregated health report for all databases on an instance.

Checks per database:
    - Recovery model
    - Last DBCC CHECKDB execution and whether it was error-free
    - Last backup times (Full / Diff / Log)
    - AutoGrowth events in the last -HistoryDays days (via default trace)
    - VLF count (excessively fragmented transaction log files)
    - Database size (data + log)
    - Database status (Online, Suspect, Restoring, ...)

    Results are saved as TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-MaxCheckDbAgeDays** - Maximum age in days of the last error-free DBCC CHECKDB. Default: 14.
- **-MaxVlfCount** - Warning threshold for VLF count per database. Default: 200.
- **-HistoryDays** - Time range for AutoGrowth evaluation in days. Default: 30.
- **-ExcludeDatabase** - Databases to exclude. Wildcards allowed.
- **-IncludeSystemDatabases** - Include system databases (except tempdb). Default: $false.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Continue on error for an instance (otherwise the error is thrown).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before writing files.
- **-WhatIf** - Shows which files would be created without actually writing them.

**Examples (2):**

```powershell
Get-sqmDatabaseHealth

```powershell
Get-sqmDatabaseHealth -SqlInstance "SQL01" -IncludeSystemDatabases -OutputPath "D:\Reports"

### Get-sqmDeadlockReport

Reads and analyzes deadlock events from the System Health Extended Event session.

The System Health session (always active since SQL Server 2008) logs all
    deadlocks as XML in the ring buffer. This function reads that buffer,
    parses the deadlock graphs and returns for each deadlock:

      - Timestamp of the deadlock
      - Victim session with login, host, program, statement
      - All involved processes with their statements and held/requested locks
      - Involved resources (tables, indexes, objects)
      - Deadlock graph as XML (for SSMS import or storage as .xdl)

    Optionally, deadlock graphs can be saved as .xdl files
    (openable directly in SSMS by double-click).

    Additionally, the System Health .xel ring buffer is read when available
    (SQL Server 2012+, provides more history than the ring buffer).

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-StartTime** - Return only deadlocks from this point in time. Default: last 24 hours.
- **-EndTime** - Return only deadlocks up to this point in time. Default: now.
- **-MaxDeadlocks** - Maximum number of deadlocks returned (newest first). Default: 100.
- **-OutputPath** - If specified, deadlock graphs are saved as .xdl files in this directory (format: Deadlock_<Instance>_<Timestamp>.xdl).
- **-EnableException** - Throw exceptions immediately instead of returning as errors.

**Examples (4):**

```powershell
Get-sqmDeadlockReport

```powershell
Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-7)

```powershell
# Save deadlocks as XDL files for SSMS
    Get-sqmDeadlockReport -SqlInstance "SQL01" -OutputPath "$env:ProgramData\sqmSQLTool\Logs\Deadlocks"

```powershell
# Only deadlocks from the last hour, show number of affected statements
    Get-sqmDeadlockReport -StartTime (Get-Date).AddHours(-1) |
        Select-Object Timestamp, VictimLogin, VictimStatement, ProcessCount

### Get-sqmLongRunningQueries

Identifies long-running queries on a SQL Server instance.

Reads sys.dm_exec_requests, sys.dm_exec_sessions, sys.dm_exec_sql_text and
    sys.dm_exec_query_plan and returns all active requests that exceed the
    configured thresholds.

    Per query the following is returned:
      - Session ID, database, login, host, program
      - Duration in seconds, CPU time, logical/physical reads, writes
      - Current wait type and wait resource
      - Current statement (not just the batch) with start/end offset resolution
      - Query plan hash and query hash (for plan cache comparison)
      - Estimated completion (if percent_complete > 0)
      - Transaction isolation level

    System sessions (session_id <= 50) and the own request are automatically excluded.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-MinDurationSeconds** - Return only queries running longer than this value (seconds). Default: 30.
- **-MinCpuMs** - Return only queries whose CPU time exceeds this value (milliseconds). Default: 0.
- **-ExcludeWaitType** - Wait types to exclude (e.g. 'SLEEP_TASK','WAITFOR'). Default: common idle waits.
- **-IncludeSystemSessions** - Include system sessions (SPID <= 50) as well. Default: $false.
- **-IncludeQueryPlan** - Retrieve the XML execution plan as well (expensive - only on demand). Default: $false.
- **-OutputPath** - If specified, a CSV snapshot is written to this directory.
- **-EnableException** - Throw exceptions immediately instead of returning as errors.

**Examples (4):**

```powershell
Get-sqmLongRunningQueries

```powershell
Get-sqmLongRunningQueries -SqlInstance "SQL01" -MinDurationSeconds 60

```powershell
# Top 10 by duration
    Get-sqmLongRunningQueries -MinDurationSeconds 10 | Sort-Object DurationSeconds -Descending | Select-Object -First 10

```powershell
# Regular snapshot via Agent job
    Get-sqmLongRunningQueries -MinDurationSeconds 120 -OutputPath "$env:ProgramData\sqmSQLTool\Logs\LongRunning"

### Get-sqmServerSetting

Reads one or all server properties from a SQL Server instance.

The function queries either a named property value (e.g. "BackupDirectory") from the
object returned by Connect-DbaInstance, or lists all properties with -All.

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME)
is used by default.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.
- **-SqlCredential** - Alternative credentials (PSCredential). If not specified,
Windows Authentication is used.
- **-Name** - The name of the server property to retrieve. Only the following values are allowed:
BackupDirectory, DefaultFile, DefaultLog, MasterDBPath, ErrorLogPath, ComputerName,
InstanceName, Edition, VersionString, ProductLevel, ProductUpdateLevel, HostPlatform,
IsClustered, IsHadrEnabled.
- **-All** - When set, all properties of the server object are returned as a list.
- **-DefaultValue** - Optional default value if the property does not exist or cannot be read.
Ignored when -All is used.
- **-EnableException** - Switch to allow exceptions to pass through (by default errors are logged as warnings).

**Examples (3):**

```powershell
# Read BackupDirectory from the local server
$backupPath = Get-sqmServerSetting -Name "BackupDirectory"

```powershell
# Show all properties
Get-sqmServerSetting -All

```powershell
# All properties from a remote instance with credentials
$cred = Get-Credential
Get-sqmServerSetting -SqlInstance "SQL01" -SqlCredential $cred -All

### Get-sqmSQLInstanceCheck

Checks a SQL Server instance against best practices.

The function performs a series of best practice checks:
- Max Degree of Parallelism (MAXDOP) - recommendation based on number of cores
- Max Server Memory - should not be too high (reserve for OS)
- Cost Threshold for Parallelism - recommendation >= 50
- Backup Directory - existence and write permissions (optional)
- SA account - renaming and disabling
- xp_cmdshell - should be disabled (unless required)
- Database autogrow settings - percent vs. MB, appropriate values
- TempDB - number of files (should match number of cores, max 8), equal size, path
- Isolated volumes - check whether database files are on separate drives (optional)
- SQL Server version / service pack - checks for outdated versions (optional)

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME)
is used by default.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (default: current computer name).
- **-SqlCredential** - Alternative credentials.
- **-Detailed** - Detailed output (e.g. path checks, analyze all databases). Default: $false.
- **-EnableException** - Allow exceptions to pass through.

**Examples (2):**

```powershell
Get-sqmSQLInstanceCheck

```powershell
Get-sqmSQLInstanceCheck -SqlInstance "SQL01\INSTANCE" -Detailed

### Invoke-sqmLoginAudit

Comprehensive audit of all SQL Server logins on one or more instances.

Checks per login:
    - POLICY VIOLATIONS (CHECK_POLICY/EXPIRATION/MUST_CHANGE)
    - Password age and whether it was never changed
    - Inactive / never-used logins
    - Duplicate SIDs (failed migration)
    - AD-orphaned Windows logins (optional)

    Output as TXT report and CSV (findings only) in the configured OutputPath.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential.
- **-InactivityThresholdDays** - Logins without login since this value are considered inactive. Default: 90.
- **-MaxPasswordAgeDays** - SQL logins with password older than this value are reported (non-sysadmins). Default: 180. 0 = disabled.
- **-MaxPasswordAgeDaysSysadmin** - SQL logins with password older than this value are reported (sysadmins). Default: 365. 0 = disabled.
- **-ExcludeLogin** - Logins to exclude (wildcards). E.g. 'NT SERVICE\*', 'sqmsa'.
- **-IncludeSystemLogins** - When set, NT SERVICE\*, NT AUTHORITY\* are also included.
- **-CheckPolicyNonSysadmin** - Check password policy violations for non-sysadmin logins. Default: $true.
- **-CheckPolicySysadmin** - Check password policy violations for sysadmin logins. Default: $true.
- **-ReportBuiltInAdmins** - When BUILTIN\Administrators is found in logins, report as warning. Default: $true.
- **-CheckAdOrphans** - When set, AD orphan check is performed for Windows logins (requires AD module).
- **-GenerateHtmlReport** - Generate HTML report in addition to TXT/CSV. Default: $true.
- **-HtmlReportTemplate** - HTML template style: 'Standard', 'Compact', 'Detailed'. Default: 'Standard'.
- **-OutputPath** - Output directory. Default: from module configuration (Get-sqmDefaultOutputPath).
- **-ContinueOnError** - Continue on error for an instance.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before file creation.
- **-WhatIf** - Shows what would happen.

**Examples (2):**

```powershell
Invoke-sqmLoginAudit

```powershell
Invoke-sqmLoginAudit -SqlInstance "SQL01" -CheckAdOrphans -IncludeSystemLogins

## 8. Storage & Disk Management

### Copy-sqmNTFSPermissions

Copies NTFS permissions (ACLs) from a source path to a destination path.

Reads the explicit NTFS permissions for each file system object (folder/file) below
    the source path and applies them to the corresponding object below the destination path.
    The target structure must already exist (exception: with -CreateMissingFolders, missing
    target folders are created automatically).

**Parameters:**

- **-SourcePath** - Source path (e.g. "D:\" or "D:\Data").
- **-DestinationPath** - Destination path (e.g. "E:\" or "E:\Data").
- **-Recurse** - Recursive traversal of all subfolders and files.
- **-CreateMissingFolders** - Automatically creates missing target folders (directories only, not files). Files missing at the destination are skipped.
- **-IncludeSystemAndHidden** - Includes hidden and system objects in the processing.

**Examples (2):**

```powershell
Copy-sqmNTFSPermissions -SourcePath "D:\" -DestinationPath "E:\" -Recurse
    Copies all permissions from D: to E: (recursively).

```powershell
Copy-sqmNTFSPermissions -SourcePath "D:\Daten" -DestinationPath "E:\Daten" -Recurse -CreateMissingFolders
    Copies permissions and creates missing target folders.

### Get-sqmDiskBlockSize

Prueft die NTFS-Blockgroesse (Cluster-Groesse) von Laufwerken auf 64KB.

Liest die NTFS-Allokationseinheit (Blockgroesse) der angegebenen Laufwerke
    per WMI (Win32_Volume) und prueft ob die fuer SQL Server empfohlenen
    64 KB (65536 Bytes) konfiguriert sind.

    Kann entweder gezielt einzelne Laufwerkbuchstaben pruefen oder automatisch
    alle Laufwerke ermitteln die von einer SQL Server-Instanz genutzt werden
    (Data, Log, Backup, TempDB).

    Rein lesender Zugriff - keine Aenderungen am System.
    Zum Formatieren: Invoke-sqmFormatDrive64k

**Parameters:**

- **-Drive** - Laufwerkbuchstabe(n) ohne Doppelpunkt, z.B. 'F', 'G', 'H'. Pipeline-faehig. Wenn nicht angegeben: -SqlInstance muss gesetzt sein.
- **-SqlInstance** - SQL Server-Instanz. Wenn angegeben werden automatisch alle von SQL Server genutzten Laufwerke (Data, Log, Backup, TempDB) aus der Registry ermittelt.
- **-ComputerName** - Zielcomputer fuer die WMI-Abfrage. Standard: lokaler Computer.
- **-RecommendedBlockSize** - Empfohlene Blockgroesse in Bytes. Standard: 65536 (64 KB).
- **-EnableException** - Ausnahmen sofort ausloesen statt Write-Error.

**Examples (4):**

```powershell
# Einzelne Laufwerke pruefen
    Get-sqmDiskBlockSize -Drive 'F', 'G', 'H'

```powershell
# Automatisch alle SQL-Laufwerke der Instanz ermitteln und pruefen
    Get-sqmDiskBlockSize -SqlInstance "SQL01"

```powershell
# Pipeline
    'F','G' | Get-sqmDiskBlockSize

```powershell
# Nur Laufwerke mit falscher Blockgroesse anzeigen
    Get-sqmDiskBlockSize -SqlInstance "SQL01" | Where-Object { -not $_.IsRecommended }

### Get-sqmDiskInfoByDriveLetter

Returns disk information for a given drive letter.

Accepts a drive letter, determines the associated disk number (disk number)
    and returns the total size, free space, percentage free and the serial number
    (LUN serial number) of the physical disk.

    The result is returned as a PSCustomObject and also copied to the clipboard
    as a formatted text table.

**Parameters:**

- **-DriveLetter** - Drive letter of the volume (e.g. "C", "C:" or "D:").
- **-NoClipboard** - Suppresses copying the result to the clipboard.

**Examples (3):**

```powershell
Get-sqmDiskInfoByDriveLetter -DriveLetter "C"

    Returns disk information for drive C: and copies it to the clipboard.

```powershell
Get-sqmDiskInfoByDriveLetter "D:" -NoClipboard

    Returns disk information for drive D: without clipboard output.

```powershell
"C","D","E" | ForEach-Object { Get-sqmDiskInfoByDriveLetter $_ }

    Returns disk information for multiple drives.

### Get-sqmDiskSpaceReport



Queries sys.dm_os_volume_stats for all database files and determines:
    - Free disk space per volume
    - Total size of database files on the volume
    - AutoGrowth volume over the last -HistoryDays days (from default trace)
    - Estimated days until exhaustion based on growth rate
    - Warning when free space falls below -WarnThresholdPct

    Results are saved as TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-WarnThresholdPct** - Warning when free space falls below this percentage. Default: 20.
- **-CriticalThresholdPct** - Critical when free space falls below this percentage. Default: 10.
- **-HistoryDays** - Time range for growth calculation in days. Default: 30.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Continue on error for an instance (otherwise the error is thrown).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before writing files.
- **-WhatIf** - Shows which files would be created without actually writing them.

**Examples (2):**

```powershell
Get-sqmDiskSpaceReport

```powershell
Get-sqmDiskSpaceReport -SqlInstance "SQL01" -WarnThresholdPct 15 -OutputPath "D:\Reports"

### Get-sqmOrphanedFiles

Finds MDF/LDF/NDF database files that are not assigned to any database.

Reads all registered database files from sys.master_files and compares them
    with the files actually present in the directories.
    Files that exist on the file system but are not registered in sys.master_files
    are reported as orphaned.

    Note: Directories are searched from the PowerShell session.
    For remote instances, paths must be accessible as UNC paths or
    SearchPath must be specified explicitly as a UNC path.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: local computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-SearchPath** - Directories to search. Default: all unique directories from sys.master_files + SQL Server default paths.
- **-FileExtension** - File extensions to search for. Default: .mdf, .ldf, .ndf
- **-Recurse** - Recursively search subdirectories.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Get-sqmOrphanedFiles -SqlInstance "SQL01"

```powershell
Get-sqmOrphanedFiles -SqlInstance "SQL01" -SearchPath "D:\SQLData","E:\SQLLog" -Recurse

### Invoke-sqmFormatDrive64k



Process:
        1. Safety checks (not C:, NTFS, one primary partition).
        2. Save drive metadata (letter, label, partition size).
        3. Check allocation unit via Get-Volume / fsutil.
        4. If cluster size is already 65536 bytes -> abort with status 'AlreadyOK'.
        5. Check whether the drive is in use by a process.
           If so: warning and abort (status 'InUse').
        6. If drive contains data: back up with robocopy to
           $BackupPath\<Letter>_<Timestamp>\.
        7. Format-Volume with -AllocationUnitSize 65536 -FileSystem NTFS.
        8. Restore drive letter and label.
        9. If data was backed up: restore with robocopy.
           Restore error -> warning, backup remains on C:.
       10. Delete backup on C: only if robocopy restored without errors.

    Safety rules:
        - Drive C: is never formatted (hard-coded guard).
        - Only NTFS volumes are accepted.
        - Only drives with exactly one primary partition.
        - Drives opened by a process -> abort.

**Parameters:**

- **-DriveLetter** - Target drive letter (single letter, e.g. 'D'). Mandatory. C is explicitly prohibited.
- **-BackupPath** - Temporary backup path on C: for data backup before formatting. Default: C:\System\DriveBackup. Must reside on drive C:.
- **-Force** - Skips the interactive confirmation prompt before formatting.
- **-WhatIf** - Simulates all steps without making changes.
- **-Confirm** - Requests explicit confirmation before formatting.

**Examples (3):**

```powershell
Invoke-sqmFormatDrive64k -DriveLetter D

    Checks drive D: and formats it with 64 KB clusters if needed.
    Data is backed up to C:\System\DriveBackup first.

```powershell
Invoke-sqmFormatDrive64k -DriveLetter E -BackupPath "C:\Backup\DriveTemp" -Force

    Same as above, without confirmation prompt, using a different backup path.

```powershell
Invoke-sqmFormatDrive64k -DriveLetter D -WhatIf

    Simulates the entire process without making any changes.

### Get-sqmDiskPartitionMap

Zeigt die Zuordnung physischer Datentraeger zu logischen Laufwerksbuchstaben.

    Ermittelt fuer jeden physischen Datentraeger (Win32_DiskDrive) alle zugeordneten
    logischen Laufwerksbuchstaben via CIM-Assoziationen:

        Win32_DiskDrive
          └─ Win32_DiskDriveToDiskPartition
               └─ Win32_DiskPartition
                    └─ Win32_LogicalDiskToPartition
                         └─ Win32_LogicalDisk  (Laufwerksbuchstabe)

    Ob eine physische Disk "geteilt" ist (mehrere Laufwerksbuchstaben auf einer Disk),
    wird im Property IsShared angezeigt. Das ist besonders relevant, wenn eine Disk
    partitioniert wurde und unterschiedliche Laufwerksbuchstaben auf derselben
    physischen Disk liegen - in diesem Fall sind SerienNummern nicht eindeutig einem
    einzelnen Laufwerk zuzuordnen.

    Unterstuetzt lokale und Remote-Abfragen via CIM (DCOM/WMI, kein WinRM noetig).

**Parameters:**

- **-ComputerName** - Zielrechner (ein oder mehrere). Standard: lokaler Computer. Aliase: SqlInstance, ServerName
- **-NoClipboard** - Ergebnis NICHT in die Zwischenablage kopieren.

**Examples (4):**

```powershell
    Get-sqmDiskPartitionMap

    Zeigt die Partitions-Zuordnung des lokalen Rechners.

```powershell
    Get-sqmDiskPartitionMap -ComputerName "SQL01"

    Remote-Abfrage gegen SQL01 via CIM/DCOM.

```powershell
    Get-sqmDiskPartitionMap | Where-Object IsShared | Select-Object DiskIndex, DriveLetters

    Zeigt nur die geteilten Disks (mehrere Laufwerksbuchstaben).

```powershell
    "SQL01","SQL02" | Get-sqmDiskPartitionMap

    Partitions-Map mehrerer Server per Pipeline.

### Invoke-sqmNtfsSetup

Grants the SQL Server service accounts NTFS permissions on the instance's data, log, TempDB and backup directories (with an ACL backup beforehand).

Reproduces the manual "set NTFS permissions after install" step in an auditable way:

  1. Determines the SQL Server service accounts (Engine + Agent) for the instance via
     Get-DbaService (or uses -Account when supplied).
  2. Determines the relevant directories automatically: the instance default Data/Log/Backup
     paths (Get-DbaDefaultPath) plus every directory that currently holds a database file
     (sys.master_files, which covers Data, Log and TempDB) - or uses -Directory when supplied.
  3. Writes a backup of the current ACLs (SDDL per directory) to a timestamped JSON file under
     -BackupPath, unless -SkipBackup is set. This allows manual rollback.
  4. Grants each service account the requested rights (FullControl by default, inherited to
     sub-folders and files) on each directory.

Filesystem changes are applied locally, so this is intended to run on the SQL Server itself
(as the SQL Setup tool does). Every change honours -WhatIf / -Confirm.

If SqlInstance is not specified, the current computer name ($env:COMPUTERNAME) is used.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). Default: current computer name.
- **-SqlCredential** - Alternative credentials (PSCredential) for the SQL connection. Default: Windows authentication.
- **-Account** - One or more accounts to grant permissions to. Default: auto-discovered SQL Engine/Agent service accounts.
- **-Directory** - One or more directories to set permissions on. Default: auto-discovered Data/Log/TempDB/Backup directories.
- **-Permission** - NTFS rights to grant: 'FullControl' (default) or 'Modify'.
- **-BackupPath** - Directory for the ACL backup file. Default: the configured OutputPath (Get-sqmConfig).
- **-SkipBackup** - Skip writing the ACL backup file. Not recommended.
- **-EnableException** - Propagate exceptions immediately instead of logging them as warnings and returning a status object.

**Examples (3):**

```powershell
Invoke-sqmNtfsSetup -SqlInstance "SQL01"
Auto-discovers the service accounts and SQL directories and grants FullControl.

```powershell
Invoke-sqmNtfsSetup -SqlInstance "SQL01\INST01" -Permission Modify -WhatIf
Shows which accounts would get Modify on which directories, without changing anything.

```powershell
Invoke-sqmNtfsSetup -Directory 'E:\MSSQL\DATA','F:\MSSQL\LOG' -Account 'NT SERVICE\MSSQLSERVER'
Sets permissions only on the given directories for the given account.

## 11. Module & Update Management

### Install-sqmAdModule

Ensures that the ActiveDirectory PowerShell module (RSAT) is installed.

First checks whether the ActiveDirectory module is already available.
    If not, the function attempts installation using four methods in the following
    order (fallback chain):

        1. Windows Capability  (Add-WindowsCapability)
           Target: Windows 10/11 clients and Windows Server 2019+
           Package: Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

        2. Windows Feature  (Install-WindowsFeature)
           Target: Windows Server (all versions with ServerManager)
           Feature: RSAT-AD-PowerShell

        3. DISM  (dism.exe /Online /Add-Capability)
           Target: older systems or environments without ServerManager/PS cmdlets
           Capability: Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

        4. PSGallery  (Install-Module ActiveDirectory)
           Target: systems with internet access and PSGallery access, when all
                   other methods are unavailable or failed.
           Scope: first CurrentUser, then AllUsers.
           Prerequisite: NuGet provider >= 2.8.5.201 (installed automatically if missing).

    Each method is only attempted if the responsible cmdlets or tool are present
    on the system. If a method fails, the next one is tried.

    After successful installation, Import-Module ActiveDirectory is run
    to load the module into the current session.

    Permission note:
        All installation methods require local administrator rights.
        The function checks this beforehand and returns an informative error.

**Parameters:**

- **-SkipIfPresent** - If $true (default) and the module is already present, $true is returned immediately without attempting installation. Set to $false to force a re-import.
- **-ContinueOnError** - When set, the function returns $false on failed installation instead of throwing an error.
- **-EnableException** - When set, the function throws an exception on failed installation (overrides ContinueOnError).
- **-WhatIf** - Shows which installation method would be attempted, without executing it.
- **-Confirm** - Request confirmation before installation.

**Examples (3):**

```powershell
Install-sqmAdModule

    Checks whether the AD module is present and installs it if necessary.

```powershell
Install-sqmAdModule -ContinueOnError

    Returns $false if installation fails instead of throwing an exception.

```powershell
if (-not (Install-sqmAdModule -ContinueOnError))
    {
        Write-Warning "AD module not available - AD check will be skipped."
    }

### Test-sqmModuleUpdate

Checks all configured update sources for a newer sqmSQLTool version.

Checks GitHub, PSGallery and/or a UNC share for newer versions of sqmSQLTool.
    Returns combined results from all reachable sources.
    Use -Source to limit the check to specific sources.

**Parameters:**

- **-Source** - Which sources to check. Valid values: GitHub, PSGallery, UNC, All. Default: All
- **-RepositoryPath** - UNC path for the UNC source check. Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool
- **-EnableException** - Throw exceptions immediately instead of returning error object.

**Examples (3):**

```powershell
Test-sqmModuleUpdate

```powershell
Test-sqmModuleUpdate -Source GitHub

```powershell
Test-sqmModuleUpdate -Source UNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"

### Test-sqmUpdateViaGitHub

Checks if a newer version of sqmSQLTool is available on GitHub.

Queries the GitHub Releases API for the latest release tag of sqmSQLTool
    and compares it with the locally installed version.
    Returns a PSCustomObject with UpdateAvailable, LocalVersion, RemoteVersion and DownloadUrl.

**Parameters:**

- **-Owner** - GitHub repository owner. Default: JankeUwe
- **-Repository** - GitHub repository name. Default: sqmSQLTool
- **-EnableException** - Throw exceptions immediately instead of returning error object.

**Examples (2):**

```powershell
Test-sqmUpdateViaGitHub

```powershell
$result = Test-sqmUpdateViaGitHub
    if ($result.UpdateAvailable) { Write-Host "Update available: $($result.RemoteVersion)" }

### Test-sqmUpdateViaPSGallery

Checks if a newer version of sqmSQLTool is available on PowerShell Gallery.

Queries PowerShell Gallery for the latest published version of sqmSQLTool
    and compares it with the locally installed version.

**Parameters:**

- **-ModuleName** - Module name to check. Default: sqmSQLTool
- **-EnableException** - Throw exceptions immediately instead of returning error object.

**Examples (2):**

```powershell
Test-sqmUpdateViaPSGallery

```powershell
$result = Test-sqmUpdateViaPSGallery
    if ($result.UpdateAvailable) { Update-sqmModule -Source PSGallery }

### Test-sqmUpdateViaUNC

Checks if a newer version of sqmSQLTool is available on a UNC share.

Compares the locally installed sqmSQLTool version with the version in the
    specified UNC share. Reads ModuleVersion.txt or sqmSQLTool.psd1 from the share.

**Parameters:**

- **-RepositoryPath** - UNC path to the sqmSQLTool repository share. Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool
- **-EnableException** - Throw exceptions immediately instead of returning error object.

**Examples (2):**

```powershell
Test-sqmUpdateViaUNC

```powershell
Test-sqmUpdateViaUNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"

### Update-sqmModule

Updates the sqmSQLTool module from GitHub, PSGallery or a UNC share.

Downloads and installs the latest version of sqmSQLTool from the specified source.

    Process:
    1. Check if update is available (via Test-sqmModuleUpdate)
    2. Create backup of current installation
    3. Download/copy new version
    4. Unblock all files (remove Zone.Identifier ADS)
    5. Verify import succeeds
    6. Report installed version

    Sources:
    - GitHub  : Downloads latest release ZIP from GitHub Releases
    - PSGallery: Installs via Install-Module / Update-Module
    - UNC     : Copies from share using robocopy

**Parameters:**

- **-Source** - Update source. Valid values: GitHub, PSGallery, UNC. Default: GitHub
- **-RepositoryPath** - UNC path for UNC source. Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool
- **-Destination** - Installation path for the module. Default: C:\Windows\System32\WindowsPowerShell\v1.0\Modules\sqmSQLTool (or %ProgramFiles%\WindowsPowerShell\Modules\sqmSQLTool)
- **-Force** - Install even if no newer version is available.
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
Update-sqmModule

```powershell
Update-sqmModule -Source GitHub -Force

```powershell
Update-sqmModule -Source UNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"

### Show-sqmToolGui

Launches a small graphical interface (WinForms) for all sqmSQLTool functions.

    Shows every exported module function grouped by category in a tree. After selecting a
    function its parameters are generated automatically as input fields. The user can fill in
    values, see a live command preview and run the command directly, copy it to the clipboard
    or display its help.

    The grouping comes from Public\category-map.ps1. Functions without an entry land under
    "Other". Read-only functions (Get-/Test-) are safe to run; state-changing functions that
    support -WhatIf get a "WhatIf (simulation)" option. It is OFF by default, so "Run" actually
    executes - enable the checkbox deliberately to only simulate.

    The interface uses a Visual Studio "Dark" colour scheme.

**Parameters:**

- **-Filter** - Optional initial filter for the function list (wildcards allowed).

**Examples (2):**

```powershell
    Show-sqmToolGui
    Opens the graphical interface with all functions.

```powershell
    Show-sqmToolGui -Filter '*AlwaysOn*'
    Opens the interface filtered directly to Always-On functions.

## 16. SQL Drivers & Tools Installation

### Install-sqmDb2Driver

Installiert den IBM DB2 ODBC/CLI-Treiber.

Prueft ob ein DB2-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled -DriverType DB2).
    Bei Bedarf: Fuehrt den IBM-Installer still aus.

    Unterstuetzte Installer-Formate:
        - db2_odbc_cli.exe / db2_odbc_cli_64.exe : IBM CLI-Treiber
        - setup.exe (DB2 Client)                  : Vollstaendiger IBM-Installer
        - .msi                                    : MSI-basierter Installer

    Falls der Treiber nach der Installation nicht automatisch als ODBC-Treiber
    registriert ist, wird db2cli.exe -setup -registerall ausgefuehrt.

**Parameters:**

- **-SourcePath** - Pfad zum DB2-Installer oder Verzeichnis mit dem Installer. Z.B.: \\srv\Treiber\DB2 oder C:\Downloads\db2_odbc_cli_64.exe

**Examples (2):**

```powershell
Install-sqmDb2Driver -SourcePath '\\srv\Treiber\DB2'

```powershell
Install-sqmDb2Driver -SourcePath 'C:\Downloads\db2_odbc_cli_64.exe'

### Install-sqmJdbcDriver

Installiert den Microsoft JDBC Driver for SQL Server.

Prueft ob der JDBC-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled).
    Bei Bedarf: Kopiert die .jar-Datei aus dem SourcePath in den Zielpfad
    und setzt optional die CLASSPATH-Umgebungsvariable.

    Unterstuetzte Installer-Formate:
        - .jar  : Direkte Kopie
        - .exe  : Microsoft-Installer, wird still ausgefuehrt (/quiet /passive)
        - .zip  : Extraktion, dann .jar kopieren

**Parameters:**

- **-SourcePath** - Quellpfad wo der JDBC-Installer oder die .jar liegt. Z.B.: \\srv\Treiber\JDBC oder C:\Downloads\sqljdbc_12.4
- **-DestinationPath** - Zielpfad fuer die .jar-Datei. Standard: C:\Program Files\Microsoft JDBC Driver for SQL Server\
- **-UpdateClassPath** - Wenn $true: CLASSPATH-Systemumgebungsvariable wird um den Zielpfad erweitert. Standard: $false

**Examples (2):**

```powershell
Install-sqmJdbcDriver -SourcePath '\\srv\Treiber\JDBC'

```powershell
Install-sqmJdbcDriver -SourcePath 'C:\Downloads\jdbc' -UpdateClassPath $true

### Install-sqmOdbcDriver

Installiert den Microsoft ODBC Driver for SQL Server.

Prueft ob der ODBC-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled).
    Bei Bedarf: Fuehrt den Installer still aus.

    Unterstuetzte Installer-Formate:
        - .msi : msiexec /i /quiet /norestart
        - .exe : Direktausfuehrung mit /quiet /norestart

**Parameters:**

- **-SourcePath** - Pfad zum ODBC-Installer oder Verzeichnis mit dem Installer. Z.B.: \\srv\Treiber\ODBC oder C:\Downloads\msodbcsql.msi
- **-DriverName** - Optionaler Treibername fuer die Vorab-Pruefung via Test-sqmDriverInstalled. Standard: automatische Erkennung (neuester Microsoft SQL ODBC-Treiber).

**Examples (2):**

```powershell
Install-sqmOdbcDriver -SourcePath '\\srv\Treiber\ODBC'

```powershell
Install-sqmOdbcDriver -SourcePath 'C:\Setup\msodbcsql18.msi'

### Uninstall-sqmDb2Driver

Deinstalliert den IBM DB2 ODBC/CLI-Treiber.

**Examples (1):**

```powershell
Uninstall-sqmDb2Driver

### Uninstall-sqmJdbcDriver

Deinstalliert den Microsoft JDBC Driver for SQL Server.

Entfernt vorhandene mssql-jdbc*.jar Dateien aus dem Standard-Installationsverzeichnis
        des Microsoft JDBC Driver for SQL Server. Da JDBC als JAR-Datei deployed wird
        (kein MSI), genuegt das Loeschen der JAR-Dateien als Deinstallation.
        Optionale Bereinigung des CLASSPATH-Eintrags.

**Parameters:**

- **-RemoveClassPath** - Entfernt den CLASSPATH-Systemeintrag wenn vorhanden. Standard: $false.

**Examples (2):**

```powershell
Uninstall-sqmJdbcDriver

```powershell
Uninstall-sqmJdbcDriver -RemoveClassPath

### Uninstall-sqmOdbcDriver

Deinstalliert den Microsoft ODBC Driver for SQL Server.

Sucht den installierten Microsoft ODBC Driver for SQL Server in der
        Windows-Uninstall-Registry und fuehrt eine stille Deinstallation via
        msiexec /x durch. Wird typischerweise vor einer Neuinstallation einer
        neueren Version aufgerufen.

**Parameters:**

- **-DriverName** - Optionaler Treibername fuer gezieltes Matching. Standard: Wildcard 'Microsoft ODBC Driver * for SQL Server'.

**Examples (2):**

```powershell
Uninstall-sqmOdbcDriver

```powershell
Uninstall-sqmOdbcDriver -DriverName 'Microsoft ODBC Driver 17 for SQL Server'

### Test-sqmDriverInstalled

Prueft ob ein JDBC-, ODBC- oder DB2-Treiber auf dem System installiert ist.

    Treiber-Erkennung je nach Typ:

    ODBC:
        - Get-OdbcDriver (Windows PowerShell / CIM)
        - Registry: HKLM:\SOFTWARE\ODBC\ODBCINST.INI\<TreiberName>

    JDBC:
        - Suche nach Microsoft JDBC Driver .jar-Dateien in bekannten Pfaden:
          %ProgramFiles%\Microsoft JDBC Driver*\sqljdbc_*\
          %ProgramFiles(x86)%\Microsoft JDBC Driver*\
          Tomcat-Lib, JBoss-Lib, WildFly-Lib (falls vorhanden)

    DB2:
        - Registry: HKLM:\SOFTWARE\IBM\DB2
        - Get-OdbcDriver fuer IBM DB2 ODBC DRIVER
        - db2cli.exe im PATH oder %ProgramFiles%\IBM\SQLLIB\BIN\

**Parameters:**

- **-DriverType** - Art des Treibers: JDBC | ODBC | DB2. Mandatory.
- **-DriverName** - Optionaler spezifischer Treibername fuer die Suche. ODBC: z.B. "ODBC Driver 17 for SQL Server" JDBC: z.B. "mssql-jdbc-12.4.0.jre11.jar" DB2: z.B. "IBM DB2 ODBC DRIVER"

**Examples (4):**

```powershell
    Test-sqmDriverInstalled -DriverType ODBC

```powershell
    Test-sqmDriverInstalled -DriverType ODBC -DriverName 'ODBC Driver 18 for SQL Server'

```powershell
    Test-sqmDriverInstalled -DriverType JDBC

```powershell
    Test-sqmDriverInstalled -DriverType DB2

## 19. External Systems Integration

### Invoke-sqmSplunkConfiguration

Configures the Splunk Universal Forwarder on SQL Server hosts.

Detects all SQL Server instances, sets machine-wide environment variables
        for the ErrorLog path (MSSQL1_Log, MSSQL2_Log, ...) and manages the
        SplunkForwarder service — locally or remotely on any number of servers.
        Existing environment variables are not overwritten.

**Parameters:**

- **-Mode** - Set  - Set environment variables and start/restart SplunkForwarder (default). Test - Check only, no changes.
- **-Remote** - Remote execution via AD OU search. Combine with -SearchOU.
- **-SearchOU** - Distinguished Name or simple OU name. Default: OUServDatabase.
- **-ComputerList** - Explicit server list: string array or path to a text file (# = comment).
- **-Credential** - Credentials for AD and remoting.
- **-LogPath** - Directory for log files. Default: sqmSQLTool LogPath configuration.
- **-LogCallback** - Optional ScriptBlock for GUI logging.

**Examples (5):**

```powershell
Invoke-sqmSplunkConfiguration

```powershell
Invoke-sqmSplunkConfiguration -Mode Test

```powershell
Invoke-sqmSplunkConfiguration -Remote -SearchOU "OU=DB-Server,DC=contoso,DC=com"

```powershell
Invoke-sqmSplunkConfiguration -ComputerList "SRV-SQL01","SRV-SQL02"

```powershell
Invoke-sqmSplunkConfiguration -ComputerList "C:\Listen\db-server.txt" -Mode Test

### Invoke-sqmTsmConfiguration



Reads the existing dsm.opt, adds or replaces the relevant entries,
    and writes the file back. Before each change a backup copy (dsm.opt.bak)
    is automatically created.

    Configured sections:
    - EXCLUDE for SQL Server database files (*.mdf, *.ndf, *.ldf)
    - INCLUDE for backup directories (User-db, Sys-db, additional paths)
    - MANAGEMENTCLASS for backup files (retention period)

    When -UseDiff is set, the management class is forced to
    MC_B_NL.NL_42.42.NA (42-day retention).

    The managed block in dsm.opt is delimited by the markers
    '* --- dtcSqlTools BEGIN ---' and '* --- dtcSqlTools END ---'.
    Manual entries outside this block are preserved.

**Parameters:**

- **-ComputerName** - Target computer (TSM client). Default: current computer name.
- **-SqlInstance** - SQL Server instance used to determine the backup directory. Default: $ComputerName.
- **-DsmOptPath** - Full path to the dsm.opt on the target computer. Determined automatically when not specified.
- **-BackupDirectory** - Base backup directory. The subdirectories \User-db and \Sys-db are added as INCLUDE entries. Default: read from the SQL instance (BackupDirectory property).
- **-AdditionalIncludePaths** - Additional directories to be added as INCLUDE entries.
- **-ManagementClass** - TSM management class for the backup files. Allowed values: MC_B_NL.NL_10.10.NA, MC_B_NL.NL_35.35.NA, MC_B_NL.NL_42.42.NA, MC_B_NL.NL_62.62.NA, MC_B_NL.NL_96.96.NA, MC_B_NL.NL_370.370.NA. Default: MC_B_NL.NL_42.42.NA.
- **-UseDiff** - When set, forces the management class to MC_B_NL.NL_42.42.NA (required for diff backup strategy).
- **-SqlCredential** - PSCredential for the SQL connection (to read the backup directory).
- **-Credential** - PSCredential for remote file access (Copy-Item, Test-Path) on the target computer.
- **-OutputPath** - Output directory for the configuration report. Default: Get-sqmDefaultOutputPath.
- **-ContinueOnError** - Continue on error (not applicable here as there is no loop).
- **-EnableException** - Throw exceptions immediately (instead of silent error objects).
- **-Confirm** - Request confirmation before writing the dsm.opt.
- **-WhatIf** - Shows what would happen without making any changes.

**Examples (3):**

```powershell
Invoke-sqmTsmConfiguration -ManagementClass MC_B_NL.NL_42.42.NA

```powershell
Invoke-sqmTsmConfiguration -ComputerName "SQL01" -UseDiff

```powershell
Invoke-sqmTsmConfiguration -ComputerName "SQL01" -AdditionalIncludePaths "E:\Archive"

### Test-sqmTsmConnection

Tests the connection to an IBM Spectrum Protect (TSM) server using dsmadmc.

Locates dsmadmc.exe on the local or remote computer, reads the TSM configuration
    from dsm.opt (server name, user name, password) if not provided explicitly,
    and executes a 'show version' command to verify that the TSM server is reachable.

**Parameters:**

- **-ComputerName** - Target computer on which the connection test is performed. Default: current computer name.
- **-DsmadmcPath** - Full path to dsmadmc.exe. Determined automatically from the registry if not specified.
- **-UserName** - TSM user name (USERID from dsm.opt if not specified).
- **-Password** - TSM password as SecureString (PASSWORD from dsm.opt if not specified).
- **-ServerName** - TSM server address (TCPServeraddress from dsm.opt if not specified).
- **-DsmOptPath** - Full path to dsm.opt. Determined automatically if not specified.
- **-Credential** - PSCredential for remote access (WinRM).
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Test-sqmTsmConnection

```powershell
Test-sqmTsmConnection -ComputerName "SQL01" -UserName "tsm_admin" -Password (Read-Host -AsSecureString)

### Get-sqmTsmConfiguration

Reads the IBM TSM / Spectrum Protect client configuration (dsm.opt) and returns server, user and password settings.

    Locates the dsm.opt option file (locally or on a remote computer), parses it and
    returns the relevant TSM client settings as an object.

    Steps:
      1. Determine the dsm.opt path (auto-detected via _FindDsmOptPath, or -DsmOptPath).
      2. Read the file (UNC/remote-capable via _ReadRemoteFile).
      3. Parse all non-comment options into a hashtable.
      4. Extract TCPServeraddress, USERID and PASSWORD.

    The password is returned as a SecureString; the plain-text value is only included
    when -IncludePasswordPlain is set. On error a result object with Success = $false is
    returned (or an exception is thrown when -EnableException is set).

**Parameters:**

- **-ComputerName** - Target computer. Default: local computer name.
- **-DsmOptPath** - Optional explicit path to the dsm.opt file. If omitted, it is auto-detected.
- **-IncludePasswordPlain** - Also return the password in plain text (PasswordPlain). Off by default.
- **-Credential** - Optional PSCredential for accessing a remote dsm.opt file.
- **-EnableException** - Throw exceptions immediately instead of returning a result object with Success = $false.

**Examples (2):**

```powershell
    Get-sqmTsmConfiguration -ComputerName SQL01
    # Reads the TSM configuration from SQL01 (password as SecureString).

```powershell
    Get-sqmTsmConfiguration -DsmOptPath 'C:\Program Files\Tivoli\TSM\baclient\dsm.opt' -IncludePasswordPlain
    # Uses an explicit dsm.opt path and also returns the plain-text password.

## 13. SQL Agent & Proxy Jobs

### Get-sqmAgentJobHistory

Displays the execution history of SQL Agent jobs.

Returns the last execution(s) of all or selected SQL Agent jobs.
    Can filter by job name, status (success/failure) and time range.
    By default, the last 7 days are shown.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-JobName** - Name or wildcard pattern (e.g. '*Backup*') to filter jobs.
- **-Status** - 'Success', 'Failure', 'Retry' or 'Cancelled'. Default: all.
- **-Since** - Show history from this date onwards. Default: today minus 7 days.
- **-LastX** - Instead of a time range: number of last executions per job (e.g. -LastX 5).
- **-OutputPath** - Export as CSV (optional). If specified, a CSV file is created.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Get-sqmAgentJobHistory

```powershell
Get-sqmAgentJobHistory -JobName '*Backup*' -Status Failure -Since (Get-Date).AddDays(-1)

### New-sqmAgentProxy

Erstellt einen SQL Server Credential und einen SQL Agent Proxy und verbindet beide.

Legt in einem Schritt einen neuen SQL Server Credential an und erstellt darauf
    basierend einen SQL Server Agent Proxy. Die Windows-Credentials werden interaktiv
    per Get-Credential abgefragt. Der Account wird vor der Erstellung auf Existenz
    und Eignung geprueft (Enabled, nicht gesperrt, Passwort nicht abgelaufen,
    Konto nicht abgelaufen). Ueber -Subsystem wird gesteuert welche Subsysteme
    dem Proxy zugewiesen werden.

    Ablauf:
      1. Get-Credential Dialog - Windows-Account eingeben
      2. AD-Pruefung: Existenz, Enabled, LockedOut, PasswordExpired, AccountExpired
      3. Pruefen ob Credential bereits existiert (Fehler oder -Force)
      4. Credential anlegen (CREATE CREDENTIAL) via SMO
      5. Pruefen ob Proxy bereits existiert (Fehler oder -Force)
      6. Agent Proxy anlegen und mit dem Credential verbinden via SMO
      7. Subsysteme gemaess -Subsystem zuweisen (CmdExec, SSIS, PowerShell oder All)
      8. Protokoll-Objekt zurueckgeben

**Parameters:**

- **-SqlInstance** - SQL Server-Instanz. Standard: lokaler Computername.
- **-SqlCredential** - PSCredential fuer die SQL-Verbindung (Windows-Auth wenn nicht angegeben).
- **-CredentialName** - Name des neuen SQL Server Credentials (z.B. "DOMAIN\ServiceAccount").
- **-ProxyName** - Name des neuen SQL Agent Proxys.
- **-ProxyDescription** - Optionale Beschreibung fuer den Proxy.
- **-WindowsCredential** - Windows-Credential direkt als PSCredential uebergeben (kein Dialog). Wenn nicht angegeben erscheint ein Get-Credential Dialog. Kann z.B. aus einem Passwort-Safe oder vorherigem Get-Credential stammen.
- **-WindowsUserName** - Optionaler Windows-Benutzername (DOMAIN\User) zur Vorbestueckung des Get-Credential Dialogs. Wird ignoriert wenn -WindowsCredential angegeben. Wenn nicht angegeben wird der CredentialName als Vorschlag verwendet.
- **-Subsystem** - Subsysteme die dem Proxy zugewiesen werden. Mehrfachauswahl moeglich. Gueltiger Werte: CmdExec, SSIS, PowerShell, All Standard: All (alle drei Subsysteme)
- **-Force** - Ueberschreibt bestehenden Credential und/oder Proxy wenn vorhanden.
- **-EnableException** - Ausnahmen sofort ausloesen statt Write-Error.

**Examples (5):**

```powershell
# Einzeiler - Credential-Dialog erscheint automatisch
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SqlServiceAccount" `
        -ProxyName "SSIS Proxy"

    # Credential direkt uebergeben - kein Dialog
    $cred = Get-Credential "DOMAIN\SvcSSIS"
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Proxy" -WindowsCredential $cred

```powershell
# Nur SSIS - Benutzername vorausgewaehlt im Dialog
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Only Proxy" -Subsystem SSIS

```powershell
# CmdExec und PowerShell
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcPS" `
        -ProxyName "Script Proxy" -Subsystem CmdExec, PowerShell

```powershell
# Abweichender Windows-Account und Force
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "ProxyCred_SSIS" `
        -ProxyName "SSIS Proxy" -WindowsUserName "DOMAIN\SvcSSIS" -Force

```powershell
# Unattended / Skript-Betrieb mit SecureString aus Vault
    $secPwd = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force
    $cred   = New-Object System.Management.Automation.PSCredential("DOMAIN\SvcSSIS", $secPwd)
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Proxy" -WindowsCredential $cred -Subsystem SSIS
    New-sqmAgentProxy -SqlInstance "SQL01\INST1" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Execution Proxy" -ProxyDescription "Fuehrt SSIS-Pakete aus" `
        -WindowsCredential $winCred -Force

### New-sqmAlwaysOnRepairJob

Creates a SQL Server Agent job that runs Repair-Job.ps1 (AutoRepair).

**Parameters:**

- **-SqlInstance** - Target SQL instance (default: computer name).
- **-JobName** - Name of the Agent job. Default: 'sqmAlwaysOnRepair'.
- **-Force** - Overwrites an existing job.

**Examples (1):**

```powershell
New-sqmAlwaysOnRepairJob -SqlInstance "SQL01"

### New-sqmAutoLoginSyncJob

Creates a SQL Agent job that runs Sync-Job.ps1 (AutoSync).

**Parameters:**

- **-SqlInstance** - Target SQL instance (default: computer name).
- **-JobName** - Name of the Agent job. Default: 'sqmAutoLoginSync'.
- **-Force** - Overwrites an existing job.

**Examples (1):**

```powershell
New-sqmAutoLoginSyncJob -SqlInstance "SQL01"

### Get-sqmAgentJobScheduleReport

Generates a comprehensive SQL Agent Job Schedule Report.

    Creates an HTML report showing all SQL Agent jobs with detailed schedule information,
    execution history, and performance metrics.

    Report includes:
    - Job Name (enabled/disabled status)
    - Schedule (start time, interval, frequency)
    - Last Execution (time, status, duration)
    - Next Scheduled Execution
    - Average Job Duration
    - Last Error Message (if failed)

**Parameters:**

- **-SqlInstance** - SQL Server instance name. Default: current computer.
- **-SqlCredential** - PSCredential for the SQL Server connection.
- **-OutputPath** - Folder path for HTML report output. Default: C:\System\WinSrvLog\MSSQL Creates filename: AgentJobSchedule_<instance>_<timestamp>.html
- **-OutputCsv** - Also export data as CSV file.
- **-EnableException** - Throw exceptions immediately instead of logging.

**Examples (2):**

```powershell
    Get-sqmAgentJobScheduleReport -SqlInstance "SQL-Server1"

```powershell
    Get-sqmAgentJobScheduleReport -SqlInstance "SQL-Server1" -OutputPath "C:\Reports" -OutputCsv

## 1. Always On & Availability Groups

### Add-sqmDatabaseToAG

Adds one or more databases to an Always On availability group (AutoSeed).

- Checks whether the database is already in an AG.
- Sets recovery mode to Full (if necessary).
- Drops existing databases on all secondary replicas.
- Adds the database to the AG using Automatic Seeding.
- With -All, databases are added sequentially to avoid load spikes.

**Parameters:**

- **-SqlInstance** - Primary SQL instance (default: computer name).
- **-SqlCredential** - Credentials.
- **-AvailabilityGroup** - Name of the target availability group (mandatory).
- **-Database** - Name or array of databases. Ignored when -All is set.
- **-All** - Add all user databases that are not yet in an AG.
- **-EnableException** - Allow exceptions to pass through.
- **-Confirm** - Request confirmation.
- **-WhatIf** - Test only (no changes).

**Examples (2):**

```powershell
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -Database "SalesDB"

```powershell
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -All

### Add-sqmDatabaseToDistributedAg

Adds a database to a Distributed AlwaysOn Availability Group.

Performs the following steps:
    1. Creates full backup of source database
    2. Backs up transaction log
    3. Restores database to secondary cluster
    4. Joins database to secondary AG
    5. Adds database to Distributed AG
    6. Monitors synchronization

    Requires:
    - Source database on primary AG
    - Secondary AG already configured
    - Distributed AG relationship established

**Parameters:**

- **-SqlInstance** - Primary SQL Server instance. Default: current computer name.
- **-AvailabilityGroupName** - Name of the Distributed AG.
- **-DatabaseName** - Name of the database to add.
- **-SecondaryInstance** - Secondary SQL Server instance where database will be restored.
- **-BackupPath** - Path for full and log backups. Default: C:\Backups
- **-SqlCredential** - Optional PSCredential for the connection.
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
Add-sqmDatabaseToDistributedAg -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -DatabaseName "MyDb" -SecondaryInstance "DR-SQL01"

### Compare-sqmAlwaysOnLogins

Vergleicht die Logins aller Replicas einer AlwaysOn Availability Group.

Ermittelt alle Replicas einer Availability Group und vergleicht pro Login:
    - Vorhanden        : existiert der Login auf jeder Replica?
    - Standard-DB      : default_database_name auf allen gleich?
    - Sprache          : default_language_name (Text) auf allen gleich?
    - Passwort-Hash    : password_hash gleich (nur SQL-Logins; Windows = N/A)
    - SID              : sid gleich? (Mismatch = verwaiste User nach Failover)

    Statusbewertung pro Login:
    - Critical : fehlt auf mindestens einer Replica, ODER SID-Mismatch,
                 ODER Passwort-Hash-Mismatch (Authentifizierung bricht nach Failover)
    - Warning  : Standard-DB oder Sprache weicht ab
    - OK       : alles konsistent

    Ausgabe als Tabelle (Rueckgabeobjekt) sowie TXT- und HTML-Report. Der HTML-Report
    wird nach dem Erstellen automatisch geoeffnet (ausser -NoOpen).

    Voraussetzung fuer den Passwort-Hash-Vergleich: Leserecht auf sys.sql_logins
    (sysadmin oder CONTROL SERVER). Fehlt das Recht, wird der Hash als N/A behandelt.

**Parameters:**

- **-SqlInstance** - Einstiegs-Instanz der AG (Primary oder eine Secondary). Standard: aktueller Computer.
- **-AvailabilityGroupName** - Name der Availability Group. Ohne Angabe wird die erste gefundene AG verwendet (bei mehreren: Warnung, erste wird genommen).
- **-SqlCredential** - Optionales PSCredential fuer alle Replicas.
- **-IncludeSystemLogins** - Wenn gesetzt, werden auch Systemlogins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*, BUILTIN\*) verglichen. Standard: ausgeblendet. Hinweis: Das 'sa'-Konto (SID 0x01, auch umbenannt) wird standardmaessig ausgeschlossen, weil jede Instanz ein eigenes Zufallspasswort verwendet (vom Sync bewusst nicht synchronisiert). Sein Passwort-Hash weicht daher erwartungsgemaess ab und wuerde sonst -FailOnDrift im Job ausloesen. Benannte sysadmin-Logins bleiben im Vergleich. Mit -IncludeSystemLogins wird 'sa' dennoch angezeigt (gilt dann wieder als Drift).
- **-Login** - Nur diese Logins vergleichen (Wildcards erlaubt).
- **-ExcludeLogin** - Diese Logins ausschliessen (Wildcards erlaubt).
- **-OnlyDifferences** - Nur Logins mit Abweichung (Status Warning/Critical) ausgeben.
- **-OutputPath** - Ausgabeverzeichnis fuer TXT/HTML. Standard: aus Modulkonfiguration.
- **-NoOpen** - Unterdrueckt das automatische Oeffnen des Reports.
- **-FailOnDrift** - Wenn gesetzt: bei Login-Drift (Status Warning oder Critical) wird ein Windows Event (Source 'sqmSQLTool', EventId 9001) geschrieben und anschliessend eine Ausnahme geworfen. Damit schlaegt ein SQL-Agent-Job-Step, der nur 'Compare-sqmAlwaysOnLogins -FailOnDrift' aufruft, bei Drift fehl (-> OnFailure-Operator-Alarm). Impliziert -NoOpen. Der Report wird vorher trotzdem geschrieben.
- **-ContinueOnError** - Bei Fehler fortfahren.
- **-EnableException** - Fehler sofort als Ausnahme ausloesen.

**Examples (3):**

```powershell
Compare-sqmAlwaysOnLogins -SqlInstance "SQL01"

```powershell
Compare-sqmAlwaysOnLogins -SqlInstance "SQL01" -AvailabilityGroupName "AG_Prod" -OnlyDifferences

```powershell
Compare-sqmAlwaysOnLogins -SqlInstance "SQL01" | Format-Table

### Complete-sqmListenerMigration

Completes listener migration after cluster team recreates the listener resource.

Re-registers the listener with SQL Server AG after cluster team has:
    1. Deleted old listener cluster resource
    2. Created new listener cluster resource (with same DNS name)

    This function:
    1. Discovers the new listener cluster resource
    2. Registers it with the SQL Server AG
    3. Verifies all databases return to ONLINE state
    4. Validates listener connectivity

    CRITICAL: Only run AFTER AD team has:
    - Deleted old listener role
    - Created new listener role (with same DNS name)
    - Configured new cluster IP address
    - Verified cluster resource is ONLINE

**Parameters:**

- **-SqlInstance** - SQL Server instance hosting the AG. Default: current computer name.
- **-AvailabilityGroupName** - Name of the Availability Group.
- **-ListenerName** - DNS name of the listener to be added (must match new cluster resource).
- **-OutputPath** - Output directory for completion report. Default: C:\System\WinSrvLog\MSSQL
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
# STEP 1: DBA runs Invoke-sqmListenerMigrationPrep
    # STEP 2: AD team deletes/recreates listener role (15-30 min wait)
    # STEP 3: DBA runs this function

    Complete-sqmListenerMigration -SqlInstance "SQL02" -AvailabilityGroupName "ProdAG" -ListenerName "PROD-SQL-Listener"

### Export-sqmAlwaysOnConfiguration

Exports the complete AlwaysOn AG configuration for one or more SQL Server instances.

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

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-OutputPath** - Output directory for report files. Default: $env:ProgramData\sqmSQLTool\Logs
- **-NoWarning** - Suppress FI-TS ReadableSecondary warnings (Write-Warning is skipped). Note: Status will still be Warning if ReadableSecondary != NO.
- **-NoOpen** - Do not automatically open the TXT report after creation.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before writing files.
- **-WhatIf** - Shows which files would be created without actually writing them.

**Examples (3):**

```powershell
Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01"
	# Exports all AGs from SQL01, warns if ReadableSecondary != NO

```powershell
Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01" -NoWarning
	# Exports all AGs, suppresses Write-Warning but Status still shows if issues

```powershell
Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01" -OutputPath "D:\Reports" -NoOpen
	# Exports to D:\Reports, does not auto-open TXT file

### Get-sqmAlwaysOnFailoverHistory

Ermittelt AlwaysOn-Failover-Ereignisse aus dem Windows Event Log.

Wertet den Windows Application Event Log auf dem Zielcomputer aus und
    liefert alle AlwaysOn-Failover-Ereignisse im angegebenen Zeitraum.

    Primaerquelle: Application Log, EventID 1480
    "The %ls role of availability group '%s' has been successfully changed to '%ls'."
    Diese EventID wird von SQL Server bei jedem AG-Rollenuebergang geschrieben.
    Sie ist strukturiert, sprachunabhaengig und in allen SQL Server-Versionen
    verfuegbar (SQL 2012+).

    Optional: Windows Failover Clustering Operational Log (EventID 1641)
    Liefert die Cluster-Perspektive des Failovers. Nur verfuegbar wenn WSFC
    installiert und der Log aktiv ist (-IncludeClusterLog).

    Ergaenzung: sys.dm_hadr_availability_replica_states.role_start_time
    Zeigt den Zeitpunkt des letzten Rollenwechsels der lokalen Replica.
    Wird als zusaetzliche Zeile mit Source 'RoleStartTime' ausgegeben wenn
    -SqlInstance angegeben ist.

    FailoverType-Erkennung:
    - 'Planned'   : EventID 1480, Message enthaelt "user" oder "manual"
    - 'Automatic' : EventID 1480, Message enthaelt "automatic" oder "WSFC"
    - 'Forced'    : EventID 19407 (Lease-Ablauf) im gleichen Zeitfenster vorhanden
    - 'Unknown'   : Kein eindeutiges Merkmal erkennbar

    Ausgabe:
        AlwaysOnFailoverHistory_<computer>_<datum>.txt  - Lesbarer Bericht
        AlwaysOnFailoverHistory_<computer>_<datum>.csv  - Maschinenlesbar

**Parameters:**

- **-ComputerName** - Zielcomputer. Standard: aktueller Computer. Mehrere Computer moeglich (Pipeline). Event Log wird remote abgefragt.
- **-SqlInstance** - SQL Server-Instanz fuer role_start_time-Ergaenzung. Optional. Wird nicht benoetigt wenn nur Event Log ausgewertet wird.
- **-SqlCredential** - Optionales PSCredential fuer die SQL-Verbindung.
- **-AvailabilityGroup** - Filter auf eine bestimmte AG. Leer = alle AGs.
- **-Since** - Wie weit zurueck suchen. Standard: 30 Tage.
- **-IncludeClusterLog** - WSFC Operational Log (Microsoft-Windows-FailoverClustering/Operational) zusaetzlich auswerten. Nur verfuegbar auf WSFC-Nodes.
- **-OutputPath** - Ausgabeverzeichnis. Standard: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Bei Fehler auf einem Computer fortfahren.
- **-EnableException** - Fehler als terminierende Ausnahmen ausloesen.

**Examples (4):**

```powershell
Get-sqmAlwaysOnFailoverHistory

```powershell
Get-sqmAlwaysOnFailoverHistory -ComputerName "SQL01" -Since (Get-Date).AddDays(-90)

```powershell
Get-sqmAlwaysOnFailoverHistory -ComputerName "SQL01" `
        -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -IncludeClusterLog

```powershell
"SQL01","SQL02" | Get-sqmAlwaysOnFailoverHistory -Since (Get-Date).AddDays(-7)

### Get-sqmAlwaysOnHealthReport

Creates a detailed health report for all Always On availability groups on an instance.

Retrieves for each AG on the specified instance:
    - Synchronization status of all replicas
    - LSN lag between primary and secondaries (redo queue, send queue)
    - Database status per replica (Synchronized, Synchronizing, NotSynchronizing, ...)
    - Connection status of replicas
    - Listener configuration
    - Running AutoSeed operations

    Results are saved as a TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-MaxRedoQueueMB** - Warning threshold for the redo queue in MB. Default: 100.
- **-MaxSendQueueMB** - Warning threshold for the send queue in MB. Default: 50.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Continue on error for an instance (otherwise the error is thrown).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before writing files.
- **-WhatIf** - Shows which files would be created without actually writing them.

**Examples (2):**

```powershell
Get-sqmAgHealthReport

```powershell
Get-sqmAgHealthReport -SqlInstance "SQL01" -MaxRedoQueueMB 200 -OutputPath "D:\Reports"

### Get-sqmDistributedAgHealth

Creates a detailed health report for Distributed AlwaysOn Availability Groups.

Retrieves for each Distributed AG on the specified instance:
    - Synchronization status between primary and secondary AGs
    - Replica status within each AG
    - Database synchronization state
    - LSN lag information (redo/send queues)
    - Listener configuration
    - Failover readiness status

    Results are saved as TXT and CSV reports. Requires SQL Server 2016 SP1 or later.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Continue on error for an instance (otherwise the error is thrown).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).

**Examples (2):**

```powershell
Get-sqmDistributedAgHealth -SqlInstance "SQL01"

```powershell
Get-sqmDistributedAgHealth -SqlInstance "SQL01", "SQL02" -OutputPath "D:\Reports"

### Invoke-sqmDistributedFailover

Initiates failover of a Distributed AlwaysOn AG.

Performs a controlled failover from the primary Distributed AG to the secondary AG.

    Process:
    1. Validates failover readiness (all replicas SYNCHRONIZED)
    2. Initiates failover on the secondary AG (makes it primary)
    3. Previous primary becomes secondary
    4. Logs all changes
    5. Exports detailed report

    Requires explicit confirmation unless -Force is used.

**Parameters:**

- **-SqlInstance** - Primary SQL Server instance. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-AvailabilityGroupName** - Name of the Distributed AG to failover. Required.
- **-Force** - Skip confirmation dialog.
- **-Rollback** - Rollback zum urspruenglichen Primary. Ueberspringt den Readiness-Check. Verwenden wenn nach einem Failover Probleme auftreten und das alte System wieder als Primary benoetigt wird.
- **-WhatIf** - Shows what would be done without actually performing the failover.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -Force

```powershell
Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -WhatIf

```powershell
# Rollback zum alten System nach fehlgeschlagenem Failover:
    Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -Rollback -Force

### Invoke-sqmFailover

Performs a controlled AlwaysOn AG failover with pre- and post-checks.

Checks before failover: synchronization status, redo queue size.
    Performs the failover: ALTER AVAILABILITY GROUP ... FAILOVER on the target secondary.
    Checks after failover: new primary reachable, all DBs SYNCHRONIZED.

**Parameters:**

- **-SqlInstance** - Current PRIMARY instance.
- **-SqlCredential** - PSCredential for the connection.
- **-AvailabilityGroup** - Name of the availability group.
- **-TargetReplica** - Instance name of the target replica. If not specified, the first SYNCHRONIZED secondary replica is selected automatically.
- **-MaxRedoQueueMB** - Maximum redo queue size in MB. Failover is aborted if exceeded. Default: 50 MB.
- **-WaitAfterFailoverSeconds** - Wait time in seconds after the failover command before post-checks run. Default: 30 seconds.
- **-ContinueOnError** - Do not throw errors; return them in the result object instead.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Invoke-sqmFailover -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -WhatIf

```powershell
Invoke-sqmFailover -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" `
        -TargetReplica "SQL02" -MaxRedoQueueMB 10

### Invoke-sqmSqlAlwaysOnAutoseeding

Enables Automatic Seeding on all replicas of an Always On Availability Group.

Configures the seeding mode of all replicas of one or more Availability Groups to
"Automatic". Using the -All switch forces processing of all Availability Groups on
the instance.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.
- **-SqlCredential** - Alternative credentials (PSCredential). If not specified, Windows authentication is used.
- **-AvailabilityGroup** - Name of the Availability Group(s). Ignored when -All is set.
- **-All** - When set, all Availability Groups on the instance are processed.
- **-EnableException** - Switch to propagate exceptions immediately (by default errors are logged as warnings).

**Examples (3):**

```powershell
# Uses the current computer name as default
Invoke-sqmSqlAlwaysOnAutoseeding

```powershell
# Explicit instance specification
Invoke-sqmSqlAlwaysOnAutoseeding -SqlInstance "SQL01\INSTANCE"

```powershell
# All groups on the current computer
Invoke-sqmSqlAlwaysOnAutoseeding -All

### Move-sqmAlwaysOnListener

Migrates an AG Listener from one Availability Group to another.

Used for Distributed AG failover scenarios where the listener must "follow" the
    primary role to a new AG.

    Process:
    1. Validate listener exists on source AG
    2. Extract listener configuration (IP, port, network mask)
    3. Remove listener from source AG
    4. Create new listener on target AG with same configuration
    5. Update DNS records (manual step documented)
    6. Verify connectivity

    IMPORTANT: This is typically done BEFORE failover to ensure zero-downtime transition.

    For Distributed AG Customer Scenario:
    - Before failover: Move listener from C1 AG to C2 AG
    - Update DNS to point to C2 listener IP
    - Trigger failover (C2 becomes primary)
    - Applications connect to listener (already pointing to C2)

**Parameters:**

- **-SqlInstance** - SQL Server instance hosting the SOURCE AG. Default: current computer name.
- **-SourceAgName** - Name of the source AG (currently has the listener).
- **-TargetAgName** - Name of the target AG (will receive the listener).
- **-TargetInstance** - SQL Server instance hosting the target AG. Default: same as SourceInstance.
- **-ListenerName** - Specific listener name to move (if multiple listeners exist). Optional.
- **-SqlCredential** - Optional PSCredential for both instances.
- **-WhatIf** - Shows what would be done without actually moving the listener.
- **-OutputPath** - Output directory for detailed logs. Default: C:\System\WinSrvLog\MSSQL
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
# Move listener from Primary AG to Secondary AG (before failover)
    Move-sqmAgListener -SqlInstance "SQL01" -SourceAgName "ProductionAG" `
        -TargetAgName "DrAG" -TargetInstance "DR-SQL01"

### New-sqmDistributedAvailabilityGroup

Creates a new Distributed AlwaysOn Availability Group.

Establishes a Distributed AG relationship between two SQL Server clusters:

    1. Validates primary and secondary AG exist and are synchronized
    2. Configures AutoSeed on both sides (if requested)
    3. Creates Distributed AG on primary cluster
    4. Registers secondary AG as part of distributed relationship
    5. Verifies initial synchronization

    Prerequisites:
    - Primary AG must exist on PrimaryInstance and be HEALTHY
    - Secondary AG must exist on SecondaryInstance
    - Both clusters must be WSFC clusters
    - Network connectivity between clusters

**Parameters:**

- **-PrimaryInstance** - SQL Server instance hosting the PRIMARY Availability Group.
- **-PrimaryAgName** - Name of the primary AG (the one that will remain primary).
- **-SecondaryInstance** - SQL Server instance hosting the SECONDARY Availability Group.
- **-SecondaryAgName** - Name of the secondary AG (the one that will be secondary in Distributed AG).
- **-SqlCredential** - Optional PSCredential for both instances (same account required).
- **-EnableAutoSeed** - Configure AutoSeed for the distributed relationship (recommended).
- **-SeedingMode** - 'Automatic' (default) = AutoSeed enabled 'Manual' = Manual backup/restore required for new databases
- **-OutputPath** - Output directory for detailed logs. Default: C:\System\WinSrvLog\MSSQL
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
New-sqmDistributedAvailabilityGroup `
        -PrimaryInstance   "SQL01" `
        -PrimaryAgName     "ProductionAG" `
        -PrimaryFqdn       "SQL01.domain.local" `
        -SecondaryInstance "DR-SQL01" `
        -SecondaryAgName   "DrAG" `
        -SecondaryFqdn     "DR-SQL01.domain.local" `
        -ServiceAccount    "DOMAIN\SqlServiceAccount" `
        -SeedingMode       Automatic

### Prepare-sqmListenerForMigration

Prepares an AG listener for cluster-level migration without downtime.

Removes the listener from the SQL Server AG while keeping databases ONLINE.

    This is CRITICAL preparation before AD/Cluster team deletes/recreates the
    listener cluster resource. Skipping this step causes all databases to enter
    RECOVERY MODE when the cluster resource is deleted.

    Process:
    1. Validates listener exists and is configured correctly
    2. Removes listener from AG (via ALTER AVAILABILITY GROUP ... REMOVE LISTENER)
    3. Verifies all databases remain ONLINE (still in AG, just no listener)
    4. Documents listener configuration for re-creation
    5. Waits for DNS/application timeout
    6. Gives AD team "safe to delete" confirmation

    CRITICAL: Run this BEFORE AD team deletes the listener cluster resource!

**Parameters:**

- **-SqlInstance** - SQL Server instance hosting the AG. Default: current computer name.
- **-AvailabilityGroupName** - Name of the Availability Group.
- **-ListenerName** - DNS name of the listener to be removed (must exist). Optional if only one listener.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-OutputPath** - Output directory for listener documentation. Default: C:\System\WinSrvLog\MSSQL
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
# STEP 1: Prepare listener before AD team deletes it
    Invoke-sqmListenerMigrationPrep -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"

    # STEP 2: Wait 15 minutes for DNS/application timeout

    # STEP 3: AD team deletes old listener role and creates new one

    # STEP 4: You run Complete-sqmListenerMigration

### Remove-sqmDatabaseFromAG

Removes one or more databases from their Always On Availability Group.

The function automatically detects which Availability Group the specified database
belongs to, removes it from the group, and then deletes it from all secondary replicas.
System databases are ignored.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default.

**Parameters:**

- **-SqlInstance** - The primary SQL Server instance (the primary replica of the AG).
Default: current computer name.
- **-SqlCredential** - Alternative credentials.
- **-Database** - Name or array of user databases to remove from their AG.
Ignored when -All is set.
- **-All** - When set, all user databases that are members of an AG are removed.
- **-EnableException** - Switch to propagate exceptions immediately.
- **-Confirm** - Prompts for confirmation before critical actions (remove from AG, delete on secondaries).
- **-WhatIf** - Shows what would happen without making any changes.

**Examples (2):**

```powershell
# Remove a single database from its AG
Remove-sqmDatabaseFromAG -Database "SalesDB"

```powershell
# Remove all AG databases
Remove-sqmDatabaseFromAG -All

### Repair-sqmAlwaysOnDatabases

Checks all AlwaysOn databases for problems and repairs them (Remove -> Cleanup -> Add).

- Determines all databases in all Availability Groups.
- Checks whether a database is problematic (synchronization status not 'HEALTHY' or 'SYNCHRONIZED').
- Ensures that Automatic Seeding is enabled on all replicas (calls Invoke-sqmSqlAlwaysOnAutoseeding).
- On problems: removes database from AG, deletes it from all secondaries, re-adds it with AutoSeed.
- Each repair is recorded in the event log (via Invoke-sqmLogging and Windows Event Log).
- Automatically creates the event log source "sqmAlwaysOn" if it does not exist.

**Parameters:**

- **-SqlInstance** - Primary SQL instance (default: computer name).
- **-SqlCredential** - Credentials.
- **-Force** - Also repair databases that are considered healthy (e.g. to force a refresh).
- **-EnableException** - Propagate exceptions immediately.
- **-WhatIf** - Test only.

**Examples (2):**

```powershell
Automatically repairs all problematic AG databases.
Repair-sqmAlwaysOnDatabases

```powershell
Forces repair of all AG databases (including healthy ones).
Repair-sqmAlwaysOnDatabases -Force

### Sync-sqmLoginsToAlwaysOn

Synchronizes logins from the primary replica to all secondary replicas in an AlwaysOn Availability Group.

Automatically detects the primary and all secondary replicas in an AlwaysOn Availability Group,
    then copies logins from the primary to each secondary.

    Process:
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

**Parameters:**

- **-SqlInstance** - The SQL Server instance hosting the primary replica. Default: $env:COMPUTERNAME
- **-AvailabilityGroupName** - Name of the Availability Group. If not specified, the first AG found on the instance is used. If multiple AGs exist: Warning is displayed, first AG is used. Specify explicitly to avoid ambiguity.
- **-SqlCredential** - PSCredential for all replicas (source and destination).
- **-SourceCredential** - PSCredential specifically for the primary replica (overrides -SqlCredential for source).
- **-DestinationCredential** - PSCredential for the secondary replicas (overrides -SqlCredential for destinations).
- **-Login** - Filters the copy operation to these login names (wildcards allowed). Without specification, all logins (after ExcludeLogin filter) are copied.
- **-ExcludeLogin** - Logins that should not be copied (wildcards allowed). Example: 'AppLogin_*', 'OldUser'.
- **-IncludeSystemLogins** - When set, system logins are also copied. Default: $false.
- **-AdjustAuthMode** - When set, automatically adjust target replica authentication mode to match primary if needed.
- **-RestartServiceIfRequired** - When set, restart the SQL Server service on secondary replicas if auth mode was changed.
- **-DisablePolicy** - Disable SQL Server policies on secondaries during the copy (default: $true).
- **-SkipSecondaryServers** - Comma-separated list of secondary instance names to skip (for maintenance). Example: 'SQL02', 'SQL03'
- **-Force** - Existing logins on secondaries are overwritten (password / language / default-db drift), not only new ones added. Default: $true - so a bare 'Sync-sqmLoginsToAlwaysOn' keeps the secondaries fully in sync. Opt out with -Force:$false (then only new logins are created). With SafeForceMode=true (default), all sysadmin logins, the SQL Agent account and system logins (sa via SID, NT SERVICE\*, etc.) are automatically excluded - no self-lockout.
- **-ForceIncludeOnly** - When Force is set with this parameter, only these logins are updated (whitelist). Overrides other login filters. System logins still excluded per SafeForceMode. Example: 'AppUser_*', 'ServiceAccount'
- **-ForceExclude** - Additional logins to exclude from Force operation (blacklist). Combined with SafeForceMode exclusions. Default: none.
- **-SafeForceMode** - When Force is set and SafeForceMode is true (default), automatically excludes dangerous logins: - sa (system admin) - SQL Agent Service Account - NT SERVICE\* (virtual accounts) - BUILTIN\* (Windows built-in accounts) Set to false ONLY if you fully understand the risks. Default: $true
- **-BackupLogins** - Creates a backup of existing logins on each secondary BEFORE applying -Force (rollback safety). Default: $true (paired with the Force default). Opt out with -BackupLogins:$false. Backup file: BackupPath\LoginBackup_<Secondary>_<Timestamp>.sql
- **-BackupPath** - Path where login backups are stored. Default: configured output path (Get-sqmDefaultOutputPath), i.e. C:\System\WinSrvLog\MSSQL unless overridden in the module config. Path is created if it doesn't exist.
- **-BackupRetentionDays** - When greater than 0, login backups (LoginBackup_*.sql) in BackupPath older than this many days are deleted after the sync. With -AuditAdOrphans, the LoginAudit_<instance>_* reports are cleaned up too. Default: 7. Set to 0 to disable cleanup (keep all files).
- **-AuditAdOrphans** - When set, runs an AD-orphan check (Invoke-sqmLoginAudit -CheckAdOrphans) on the primary AFTER the sync and reports Windows logins whose AD account no longer exists. Findings go to the log and a Windows Event Log warning (Source 'sqmSQLTool', EventId 9003) for Splunk. DETECTION ONLY - logins are NEVER deleted automatically. Requires the RSAT ActiveDirectory module and AD read rights. Default: $false.
- **-EnableException** - Throw exceptions immediately instead of returning error status.

**Examples (5):**

```powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"
    Syncs all logins from primary to all secondaries in ProdAG.

```powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -IncludeSystemLogins
    Includes system logins in the sync.

```powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -ExcludeLogin "TempUser_*"
    Skips logins matching the pattern.

```powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -Force -BackupLogins
    Updates existing logins (password changes) with backup before applying changes.

```powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" `
        -Force -ForceIncludeOnly "AppUser_*", "ServiceDB_Account" -BackupLogins
    Updates only specific logins with backup enabled (safest -Force operation).

### Test-sqmDistributedAgReadiness

Tests Distributed AlwaysOn AG readiness for failover.

Validates:
    - Synchronization status between primary and secondary AGs
    - All replicas are SYNCHRONIZED
    - Listener is online
    - Network connectivity between clusters
    - Database consistency
    - No pending transactions

    Returns a readiness score (0-100) and detailed report.

**Parameters:**

- **-SqlInstance** - Primary SQL Server instance. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-TargetInstance** - Secondary SQL Server instance for network testing. Optional.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
Test-sqmDistributedAgReadiness -SqlInstance "SQL01" -TargetInstance "DR-SQL01"

### Invoke-sqmAlwaysOnSetup

End-to-end CLI AlwaysOn setup: reads the WSFC, creates the Availability Group and synchronises logins.

    Headless orchestration wrapper around New-sqmAvailabilityGroup. Replaces the GUI of AlwaysOnSetup.ps1.

    Flow:
      1. Discover the Windows Server Failover Cluster (Get-Cluster / Get-ClusterNode) and, if not
         explicitly given, the listener role (name / IP / port from the cluster network-name resource).
      2. Discover the SQL Server engine instance + service account on each cluster node (WMI).
      3. Test connectivity: Windows auth (Kerberos) is preferred. If -SqlCredential is supplied it is
         used directly. If Windows auth fails on any node and no credential was given, the function
         stops with a clear message (the GUI tool created a temporary SQL login here - in headless
         mode you pass -SqlCredential instead, or fix the SPNs first).
      4. (Optional) Back up the current cluster settings to a text file before making changes.
      5. Create the AG via New-sqmAvailabilityGroup (HADR, endpoints, AG, secondaries, listener).
      6. Post-creation: Sync-sqmLoginsToAlwaysOn (logins to all secondaries) and
         Invoke-sqmSqlAlwaysOnAutoseeding (ensure SEEDING_MODE = AUTOMATIC on all replicas).
      7. (Optional) Generate an SPN request file for the AD team (setspn commands for the service
         account covering each node and the listener).

    This wrapper requires the FailoverClusters module on the executing node (run on a cluster member).

**Parameters:**

- **-AvailabilityGroupName** - Name of the AG to create. Default: the discovered listener (cluster role) name.
- **-Database** - Database(s) to seed into the AG (created on the primary, RECOVERY FULL, auto-seeded).
- **-PrimaryReplica** - Override the primary replica instance. Default: the SQL instance on the first cluster node.
- **-EndpointPort** - Database-mirroring endpoint port. Default: 5022.
- **-FailoverMode** - 'Automatic' (sync + automatic failover) or 'Manual' (async). Default: 'Automatic'.
- **-BackupPreference** - 'Primary' / 'Secondary' / 'PreferSecondary' / 'None'. Default: 'Primary'.
- **-ServiceAccount** - SQL service account for the endpoint CONNECT grant. Default: discovered from the SQL service.
- **-SqlCredential** - PSCredential for SQL authentication on all replicas (use when Kerberos SPNs are missing). Omit for Windows authentication.
- **-BackupClusterSettings** - Write a cluster-settings backup file before changes. Default: $true.
- **-GenerateSpnReport** - Write an SPN request file for the AD team. Default: $true.
- **-OutputPath** - Directory for the cluster-settings backup and SPN report. Default: configured output path (Get-sqmDefaultOutputPath), i.e. C:\System\WinSrvLog\MSSQL unless overridden.
- **-SkipLoginSync** - Skip the post-creation Sync-sqmLoginsToAlwaysOn step.
- **-EnableException** - Throw on error instead of logging and returning a failed result.

**Examples (2):**

```powershell
    Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb

    Reads the local cluster, creates ProdAG across all nodes using the discovered listener and
    service account, then syncs logins and enables automatic seeding.

```powershell
    Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb `
        -SqlCredential (Get-Credential sa) -WhatIf

    Dry-run using SQL authentication; shows the planned actions without changing anything.

### New-sqmAvailabilityGroup

Creates an AlwaysOn Availability Group on an existing Windows Server Failover Cluster (WSFC).

    Headless port of the AlwaysOnSetup.ps1 automation (no GUI). Drives the complete AG creation
    purely from parameters using dbatools (Invoke-DbaQuery / Connect-DbaInstance) and raw T-SQL.

    Process (each step is idempotent and skips work that is already in place):
      1. Enable HADR on every replica (sp_configure 'hadr enabled', 1) and restart the SQL service
         where HADR was not yet active (HADR requires a service restart to take effect).
      2. Create the database-mirroring endpoint (default 'HADR_Endpoint') on every replica.
      3. (Optional) Create the service-account login and GRANT CONNECT ON ENDPOINT so the replicas
         can authenticate to each other (Windows auth / Kerberos). Falls back to the UPN form for
         cross-domain accounts; on failure it logs that certificate auth must be configured manually.
      4. (Optional) Create the seed database(s) on the primary, set RECOVERY FULL.
      5. (Optional) Clean up an orphaned WSFC group left over from a failed previous attempt.
      6. CREATE AVAILABILITY GROUP on the primary (CLUSTER_TYPE = WSFC, SEEDING_MODE = AUTOMATIC),
         then JOIN + GRANT CREATE ANY DATABASE on each secondary, and MODIFY REPLICA to pin the
         configured failover/availability mode.
      7. (Optional) Add the listener (ADD LISTENER ... WITH IP ((ip, mask)), PORT = ...).

    Authentication strategy: pass -SqlCredential for SQL authentication (e.g. when Kerberos SPNs are
    missing), otherwise the current Windows identity is used on all replicas. This function does NOT
    create temporary logins or request SPNs - that orchestration lives in Invoke-sqmAlwaysOnSetup.

**Parameters:**

- **-SqlInstance** - The primary replica instance (e.g. "SQL01" or "SQL01\INST"). Default: $env:COMPUTERNAME.
- **-SecondaryReplica** - One or more secondary replica instance names. Together with -SqlInstance these form the AG (max. 3 replicas total, matching the tested topology).
- **-AvailabilityGroupName** - Name of the Availability Group to create (mandatory).
- **-Database** - One or more databases to seed into the AG. Created on the primary if missing and set to RECOVERY FULL. If omitted, the AG is created empty (databases can be added later with Add-sqmDatabaseToAG).
- **-ReplicaHostMap** - Optional hashtable mapping replica instance name -> host FQDN used in the endpoint URL (TCP://<host>:<port>). When a replica is not present in the map the host part of the instance name (before the backslash) is used.
- **-EndpointName** - Name of the database-mirroring endpoint. Default: 'HADR_Endpoint'.
- **-EndpointPort** - TCP port of the database-mirroring endpoint. Default: 5022.
- **-FailoverMode** - 'Automatic' (synchronous-commit + automatic failover) or 'Manual' (asynchronous-commit + manual failover). Default: 'Automatic'. Drives AVAILABILITY_MODE unless -AvailabilityMode is set.
- **-AvailabilityMode** - Optional explicit override: 'SynchronousCommit' or 'AsynchronousCommit'. When omitted it is derived from -FailoverMode (Automatic -> SynchronousCommit, Manual -> AsynchronousCommit).
- **-BackupPreference** - AUTOMATED_BACKUP_PREFERENCE: 'Primary', 'Secondary', 'PreferSecondary' or 'None'. Default: 'Primary'.
- **-SeedingMode** - 'Automatic' (automatic seeding, no manual backup/restore) or 'Manual'. Default: 'Automatic'.
- **-ListenerName** - Optional AG listener (network) name. When set together with -ListenerIPAddress and -ListenerPort the listener is created after the AG.
- **-ListenerIPAddress** - One or more static IPv4 addresses for the listener.
- **-ListenerSubnetMask** - Subnet mask for the listener IP(s). Default: '255.255.255.0'.
- **-ListenerPort** - TCP port of the listener. Default: 1433.
- **-ServiceAccount** - SQL Server service account (DOMAIN\User or UPN). When supplied the login is created on each replica (if missing) and granted CONNECT on the endpoint.
- **-RestartService** - Restart the SQL Server service on a replica after enabling HADR. Default: $true. HADR only takes effect after a restart, so disabling this requires you to restart the services yourself.
- **-CleanupOrphanedWsfcGroup** - When set, an orphaned WSFC group named like the AG (a remnant of a failed previous attempt, with no matching SQL AG) is removed before CREATE AVAILABILITY GROUP. Requires the FailoverClusters module on the executing node.
- **-SqlCredential** - PSCredential for SQL authentication on all replicas. Omit for Windows authentication.
- **-EnableException** - Throw on error instead of logging a warning and returning a failed result object.

**Examples (2):**

```powershell
    New-sqmAvailabilityGroup -SqlInstance SQL01 -SecondaryReplica SQL02 `
        -AvailabilityGroupName ProdAG -Database AppDb `
        -ListenerName ProdAGL -ListenerIPAddress 10.0.0.50 -ListenerPort 1433 `
        -ServiceAccount 'CONTOSO\svcSql'

    Creates a two-node synchronous AG with automatic seeding and a listener.

```powershell
    New-sqmAvailabilityGroup -SqlInstance SQL01 -SecondaryReplica SQL02,SQL03 `
        -AvailabilityGroupName ProdAG -FailoverMode Manual -BackupPreference PreferSecondary -WhatIf

    Dry-run of a three-node asynchronous AG; no changes are made.

### Sync-sqmAgNode

Synchronizes SQL Server objects from the primary replica to all secondary replicas of an Availability Group.

    Automatically detects the current primary and all Availability Groups of the
    specified instance. All AGs are processed individually.

    Synchronizes the following object types from primary to all secondaries:
        Logins        - SQL and Windows logins including SID/password transfer,
                        followed by Repair-DbaDbOrphanUser on all AG databases
                        on the secondaries (orphaned user cleanup).
        Jobs          - SQL Agent jobs including job steps, schedules, and proxies.
        LinkedServers - Linked Server definitions including login mappings.
        Operators     - SQL Agent operators.
        Alerts        - SQL Agent alerts.

    Use -ExcludeType to exclude individual types.
    Use -ObjectName to target specific logins and jobs by name.
    Use -IncludeSystemObjects to also synchronize system logins (sa, ##MS_*) and system jobs.

**Parameters:**

- **-SqlInstance** - Name of any SQL Server instance in the AG cluster (default: current computer name).
- **-SqlCredential** - Optional PSCredential for all SQL connections.
- **-AvailabilityGroup** - Optional: Name of a specific AG. Otherwise all AGs on the instance are processed.
- **-ExcludeType** - Object types that should NOT be synchronized. Valid values: Logins, Jobs, LinkedServers, Operators, Alerts.
- **-ObjectName** - Optional: Filters logins and jobs by name (wildcards allowed).
- **-IncludeSystemObjects** - When set, system objects (sa, ##MS_*, internal jobs) are synchronized. Default: $false (system objects are excluded).
- **-ContinueOnError** - Continue with the next object type on error (otherwise aborts).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Prompts for confirmation before critical actions (overwriting jobs/logins).
- **-WhatIf** - Shows all planned actions without executing them.

**Examples (2):**

```powershell
    Sync-sqmAgNode

```powershell
    Sync-sqmAgNode -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -ObjectName "AppLogin_*"

## 18. SSIS Configuration

### Invoke-sqmSsisConfiguration



Performs a complete initial or re-configuration of SSIS:
    1. SSIS service (service account + startup type)
    2. SSISDB catalog (incl. CLR activation, properties)
    3. AlwaysOn AG integration (SSISDB into AG, DMK restore, disable cleanup job, sp_ssis_startup)
    4. Create catalog folders and environments

    Connection modes: Local (direct) / Remote (dbatools + WinRM for service).

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the SQL connection.
- **-AgName** - Name of the AlwaysOn Availability Group (optional).
- **-AgListener** - AG listener name (automatically determined if not specified).
- **-AgNodes** - Explicit list of all AG nodes (optional).
- **-CatalogPassword** - Password for the SSISDB catalog (SecureString, required).
- **-CatalogFolder** - Array of catalog folder names (e.g. @('ETL','Staging')).
- **-CatalogFolderDescription** - Description for the folders (default: 'Created by MSSQLTools').
- **-Environments** - Array of environment names (created in each CatalogFolder).
- **-SsisServiceAccount** - Service account for the SSIS service (e.g. 'DOMAIN\svc_ssis').
- **-SsisServiceAccountPassword** - Password for the service account (SecureString).
- **-SsisServiceStartupType** - Startup type of the SSIS service (Automatic, Manual, Disabled; default: Automatic).
- **-RetentionPeriod** - Retention period for SSISDB logs in days (default: 365).
- **-LoggingLevel** - Logging level (0=None, 1=Basic, 2=Performance, 3=Verbose; default: 1).
- **-MaxConcurrentExecutables** - Maximum concurrent executions (default: -1 = unlimited).
- **-SkipService** - Skip service configuration.
- **-SkipCatalog** - Skip catalog creation/configuration.
- **-SkipAg** - Skip AG integration (even if -AgName is specified).
- **-SkipFolders** - Skip folder/environment creation.
- **-WinRmCredential** - Credentials for WinRM (remote service configuration, optional).
- **-OutputPath** - Output directory for the configuration report. Default: Get-sqmDefaultOutputPath.
- **-ContinueOnError** - Continue with the next step on error (rarely used).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before critical changes.
- **-WhatIf** - Shows what would happen without making changes.

**Examples (2):**

```powershell
$pwd = Read-Host "SSISDB-Kennwort" -AsSecureString
    Invoke-sqmSsisConfiguration -SqlInstance "SQL01" -CatalogPassword $pwd

```powershell
$pwd = Read-Host "SSISDB-Kennwort" -AsSecureString
    Invoke-sqmSsisConfiguration -SqlInstance "SQL01" -AgName "AG_SSIS" -CatalogPassword $pwd

### Test-sqmSSISPackageCompatibility

Validates SSIS package compatibility for SQL Server upgrades (2016 - 2025).

Tests whether SSIS packages will run in a target SQL Server version.
    Checks deprecated features, encoding issues, and connection types.

    Supports two package sources:
    1. SSISDB Catalog (deployed packages on target SQL Server)
    2. Filesystem .dtsx files (backup/undeployed packages)

    Output: HTML report + TXT + CSV (dark theme, with summary cards and filter)

**Parameters:**

- **-SqlInstance** - SQL Server instance to connect to (for SSISDB source). Omit to check only filesystem packages.
- **-SqlCredential** - Optional PSCredential for SQL authentication.
- **-FolderName** - Filter SSISDB packages to specific catalog folder(s). Example: 'MyFolder', 'Integration', etc.
- **-PackagePath** - Path to .dtsx files (filesystem source). Omit to check only SSISDB packages.
- **-Recurse** - Recurse into subfolders when reading .dtsx files.
- **-TargetVersion** - Target SQL Server version for compatibility check. Supported: 2016, 2017, 2019, 2022, 2025 Default: 2022
- **-OutputPath** - Directory for HTML/TXT/CSV reports. Default: $env:ProgramData\sqmSQLTool\SSISReports
- **-EnableException** - Throw exceptions instead of returning error status.

**Examples (3):**

```powershell
# Check deployed packages on target server
    Test-sqmSSISPackageCompatibility -SqlInstance "NewServer2025" -TargetVersion 2025

```powershell
# Check old package files before deployment
    Test-sqmSSISPackageCompatibility -PackagePath "C:\OldPackages" -TargetVersion 2025 -Recurse

```powershell
# Compare deployed vs. backup packages
    Test-sqmSSISPackageCompatibility -SqlInstance "NewServer2025" `
      -PackagePath "C:\OldPackages" -TargetVersion 2025

## 21. Analysis Services (SSAS)

### Test-sqmSsasDirectoryPermissions

Checks and corrects NTFS permissions for SSAS directories (Data, Log, Temp, Backup).

Determines the directory paths for an SSAS instance from the registry,
    checks whether the SSAS service account has FullControl access to these directories,
    and sets any missing permissions as needed.

    The function is idempotent — on repeated calls only missing permissions are added.

**Parameters:**

- **-InstanceName** - Name of the SSAS instance. Default: 'MSSQLSERVER' (default instance). For named instances e.g. 'SSAS2019'.
- **-ServiceAccount** - Optional: Name of the service account (e.g. 'NT SERVICE\MSSQLServerOLAPService'). If not specified, the account is automatically determined from the Windows service.
- **-WhatIf** - Shows which changes would be made without executing them.
- **-Confirm** - Prompts for confirmation before each change.
- **-EnableException** - Throws an exception immediately on errors (otherwise the error is logged).
- **-ContinueOnError** - Continues checking the next directories even on errors.

**Examples (2):**

```powershell
Test-sqmSsasDirectoryPermissions

    Checks the directories of the default SSAS instance and corrects missing permissions.

```powershell
Test-sqmSsasDirectoryPermissions -InstanceName "SSAS2019" -WhatIf

    Shows which permissions would be set for the named instance.

## 2. Performance Analysis & Optimization

### Get-sqmIndexFragmentation

Analyzes index fragmentation in one or more databases.

Returns the fragmentation level (%) for all indexes and recommends an action:
        - 5-30%  -> REORGANIZE
        - >30%   -> REBUILD
    Output can be restricted to specific databases, tables or a minimum fragmentation level.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-Database** - Database name or wildcard pattern (e.g. 'Sales*'). Default: all user databases.
- **-TableName** - Table name or wildcard pattern (e.g. 'Order*'). Default: all tables.
- **-MinFragmentationPercent** - Show only indexes with fragmentation >= this value. Default: 5.
- **-PageCountMin** - Show only indexes with at least this page count. Default: 0 (all indexes).
- **-OutputPath** - Optional CSV export path.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Get-sqmIndexFragmentation -Database 'AdventureWorks' -MinFragmentationPercent 10

```powershell
Get-sqmIndexFragmentation -SqlInstance 'SQL01' -MinFragmentationPercent 30

### Get-sqmMissingIndexes

Retrieves missing index recommendations from the SQL Server DMV cache.

Reads sys.dm_db_missing_index_details, sys.dm_db_missing_index_groups and
    sys.dm_db_missing_index_group_stats and calculates an impact score
    (using the Microsoft formula) and a ready-to-use CREATE INDEX statement per missing index.

    Per recommendation the following is returned:
      - Database, schema, table
      - Equality and inequality columns, include columns
      - Impact score (0-100, calculated from seeks/scans/lookups * avg_user_cost * avg_user_impact)
      - Number of seeks, scans, lookups since last SQL Server restart
      - Last seek timestamp
      - Ready-to-use CREATE INDEX statement with suggested index name

    IMPORTANT: DMV data is volatile (reset on SQL Server restart, failover,
    and certain plan cache events). Always review recommendations with the DBA
    before creating indexes - especially on heavily loaded systems.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-Database** - Filter by database name(s). Wildcards allowed. Default: all user databases.
- **-MinImpactScore** - Return only recommendations with impact score >= this value. Default: 10.
- **-MinSeeks** - Return only recommendations with at least this number of seeks/scans. Default: 50.
- **-Top** - Return at most this number of recommendations (sorted by impact score). Default: 50.
- **-OutputPath** - If specified, a CSV file with the recommendations and CREATE statements is written to this directory.
- **-EnableException** - Throw exceptions immediately.

**Examples (4):**

```powershell
Get-sqmMissingIndexes -SqlInstance "SQL01"

```powershell
# Only high-impact recommendations
    Get-sqmMissingIndexes -SqlInstance "SQL01" -MinImpactScore 50 -MinSeeks 500

```powershell
# Show top 10 and save as CSV
    Get-sqmMissingIndexes -SqlInstance "SQL01" -Top 10 -OutputPath "D:\Reports"

```powershell
# Output CREATE INDEX statements directly
    Get-sqmMissingIndexes -SqlInstance "SQL01" -MinImpactScore 30 |
        Select-Object DatabaseName, TableName, ImpactScore, CreateIndexStatement |
        Format-List

### Get-sqmWaitStatistics

Reads and analyzes SQL Server wait statistics from sys.dm_os_wait_stats.

Reads the cumulative wait statistics of the instance, filters out known idle waits
    and returns the top-N waits with category and recommended action.
    Optional: snapshot comparison (before/after) via -SnapshotBefore/-SaveSnapshot.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: local computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-TopN** - Number of top wait types to return. Default: 25.
- **-IncludeIdle** - Include idle waits (SLEEP_*, WAITFOR, etc.). Default: off.
- **-SnapshotBefore** - PSCustomObject array of an earlier snapshot (output of -SaveSnapshot). If specified, only the delta is calculated.
- **-SaveSnapshot** - Returns a snapshot array that can later be used as SnapshotBefore.
- **-OutputPath** - If specified, a CSV report is saved.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Get-sqmWaitStatistics -SqlInstance "SQL01" -TopN 20

```powershell
$before = Get-sqmWaitStatistics -SqlInstance "SQL01" -SaveSnapshot
    Get-sqmWaitStatistics -SqlInstance "SQL01" -SnapshotBefore $before

### Invoke-sqmPerfBaseline

Creates, compares or lists performance baselines (wait stats + perf counters).

Capture: Saves the current snapshot of sys.dm_os_wait_stats and
    sys.dm_os_performance_counters as a JSON file.
    Compare: Calculates the delta between two baselines.
    List:    Lists all saved baseline files.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: local computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-Action** - Capture | Compare | List. Default: Capture.
- **-BaselineName** - Label for the snapshot (used in the file name). Default: timestamp.
- **-BaselineA** - Path or file name (without path) of the first baseline for comparison. Default: the second-to-last file in OutputPath.
- **-BaselineB** - Path or file name of the second (newer) baseline. Default: the most recent file in OutputPath.
- **-OutputPath** - Directory for baseline JSON files. Default: from module configuration + \PerfBaseline.
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
# Capture baseline
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -BaselineName "before_patch"

```powershell
# Capture baseline after change and compare
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -BaselineName "after_patch"
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -Action Compare

```powershell
# List all baselines
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -Action List

### Invoke-sqmQueryStore

Configures the Query Store, reads from it, detects issues and saves reports.

Comprehensive Query Store management for one, multiple or all user databases.

    Operating modes (switches, combinable):
      -Configure  Enables and configures the Query Store (ALTER DATABASE SET QUERY_STORE).
      -Query      Reads the top-N queries from the Query Store (by duration, CPU, reads, etc.).
      -Diagnose   Detects issues: READ_ONLY status, memory pressure, plan regression,
                  forced plan failures, unstable execution plans.

    If none of the three switches are specified, -Query and -Diagnose are executed
    (report mode).

    Results are returned as PSCustomObject and optionally saved as CSV/TXT.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-Database** - One or more databases. Ignored when -All is set.
- **-All** - Process all accessible user databases.
- **-Configure** - Configure Query Store (enable/set parameters).
- **-Query** - Read top-N queries from the Query Store.
- **-Diagnose** - Detect issues in the Query Store and return them as issues.
- **-OperationMode** - Query Store operation mode. Values: READ_WRITE, READ_ONLY, OFF. Default: READ_WRITE.
- **-FlushIntervalSeconds** - Frequency of writing to the Query Store (seconds). Default: 900.
- **-IntervalLengthMinutes** - Length of a statistics interval (minutes). Default: 60.
- **-MaxStorageSizeMB** - Maximum size of the Query Store (MB). Default: 1000.
- **-QueryCaptureMode** - Capture mode. Values: ALL, AUTO, NONE. Default: AUTO.
- **-SizeBasedCleanupMode** - Automatic cleanup under memory pressure. Values: OFF, AUTO. Default: AUTO.
- **-MaxPlansPerQuery** - Maximum number of execution plans per query. Default: 200.
- **-TopN** - Number of top queries to return. Default: 25.
- **-OrderBy** - Sort column for top queries. Values: Duration, CPU, LogicalReads, ExecutionCount, Memory. Default: Duration.
- **-LookbackHours** - Lookback period in hours (from now backwards). Default: 24.
- **-MinExecutionCount** - Minimum number of executions required to be included in top queries. Default: 5.
- **-StorageWarningPct** - Fill level (%) at which a storage warning is issued. Default: 80.
- **-MaxPlansWarning** - Number of plans per query at which a plan instability warning is issued. Default: 5.
- **-OutputPath** - Directory for reports (CSV + TXT). Default: from module configuration + \QueryStore.
- **-EnableException** - Throw exceptions immediately.

**Examples (4):**

```powershell
# Report for all databases (Query + Diagnose)
    Invoke-sqmQueryStore -All

```powershell
# Configure Query Store and query immediately
    Invoke-sqmQueryStore -Database "SalesDB","CRM" -Configure -Query -Diagnose

```powershell
# Top 50 queries by CPU consumption, last 48 hours
    Invoke-sqmQueryStore -Database "SalesDB" -Query -TopN 50 -OrderBy CPU -LookbackHours 48

```powershell
# Diagnostics with storage warning from 70% and save report
    Invoke-sqmQueryStore -All -Diagnose -StorageWarningPct 70 -OutputPath "D:\Reports\QS"

### Test-sqmCostThreshold

Prueft ob CostThresholdForParallelism auf dem empfohlenen Wert liegt.

Liest den aktuellen Wert von CostThresholdForParallelism per SMO und
    vergleicht ihn mit dem konfigurierbaren Mindestwert (Standard: 50).
    Der SQL Server Default von 5 ist fuer moderne Systeme in der Regel
    zu niedrig und fuehrt zu unnoetigem parallelen Ausfuehrungsaufwand
    bei kurzen Abfragen.

    Gibt ein PSCustomObject mit Status, aktuellem Wert und Empfehlung zurueck.

**Parameters:**

- **-SqlInstance** - SQL Server-Instanz. Standard: lokaler Computername.
- **-SqlCredential** - PSCredential fuer die SQL-Verbindung.
- **-MinRecommendedValue** - Mindestwert fuer CostThresholdForParallelism. Standard: 50.
- **-EnableException** - Ausnahmen sofort ausloesen statt Write-Error.

**Examples (2):**

```powershell
Test-sqmCostThreshold -SqlInstance "SQL01"

```powershell
Test-sqmCostThreshold -SqlInstance "SQL01" -MinRecommendedValue 25

### Test-sqmMaxDop

Prueft ob MAXDOP (Max Degree of Parallelism) korrekt konfiguriert ist.

Liest den aktuellen MAXDOP-Wert aus sys.configurations und vergleicht
    ihn mit der Microsoft-Empfehlung:
        Empfehlung: min(8, Anzahl logischer CPUs)

    Sonderwert 0 bedeutet "kein Limit" = unkonfiguriert (SQL-Default, nicht empfohlen).

    Status-Auswertung:
        OK          : MAXDOP entspricht der Empfehlung
        Suboptimal  : MAXDOP weicht von der Empfehlung ab (zu hoch oder zu niedrig, aber > 0)
        Unconfigured: MAXDOP = 0 (unbegrenzt, Standard-Default)

**Parameters:**

- **-SqlInstance** - SQL Server-Instanzname. Z.B. "MSSQLSERVER" oder "SERVER\INST01".

**Examples (2):**

```powershell
Test-sqmMaxDop -SqlInstance 'MSSQLSERVER'

```powershell
Test-sqmMaxDop -SqlInstance 'SQL01\INST01'

### Test-sqmMaxMemory

Prueft ob SQL Server Max Server Memory korrekt konfiguriert ist.

Liest den aktuellen "max server memory (MB)"-Wert und vergleicht ihn
    mit der Empfehlung (90% des physischen RAM).

    Sonderwert 2147483647 (= 2^31 - 1) bedeutet "nicht konfiguriert" (SQL-Standard-Default).

    Status-Auswertung:
        OK          : Konfigurierter Wert liegt im Toleranzbereich (>=85% und <=95% RAM)
        TooHigh     : Konfiguriert aber oberhalb 95% RAM (Risiko fuer OS)
        TooLow      : Konfiguriert aber unterhalb 85% RAM (SQL Server unterversorgt)
        Unconfigured: Wert ist 2147483647 - Standard-Default, kein expliziter Wert gesetzt

**Parameters:**

- **-SqlInstance** - SQL Server-Instanzname. Z.B. "MSSQLSERVER" oder "SERVER\INST01".
- **-RecommendedPct** - Empfohlener Prozentsatz des RAM fuer SQL Server. Standard: 90.

**Examples (2):**

```powershell
Test-sqmMaxMemory -SqlInstance 'MSSQLSERVER'

```powershell
Test-sqmMaxMemory -SqlInstance 'SQL01\INST01' | Where-Object { $_.Status -ne 'OK' }

### Get-sqmTempDbRecommendation

Analyzes the TempDB configuration and provides optimization recommendations.

Checks the number and size of TempDB files, autogrow settings and the path.
    Recommends file count (matching CPU core count, max 8), equal sizes, MB-based autogrow,
    and separate drives where possible.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-OutputPath** - Optional CSV export path.
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
Get-sqmTempDbRecommendation -SqlInstance "SQL01"

### Test-sqmTempDbFileCount

Prueft ob die Anzahl der TempDB-Datendateien der empfohlenen CPU-Anzahl entspricht.

Liest die Anzahl der TempDB-Datendateien (Typ = Rows, ohne Log) per SMO und
    vergleicht sie mit der Anzahl der CPU-Kerne des Servers (max 8 gemaess
    Microsoft-Empfehlung).

    Hintergrund: Zu wenige TempDB-Dateien koennen zu PAGELATCH-Konflikten auf
    der Allocation-Seite fuehren. Microsoft empfiehlt eine Datei pro
    logischem Kern, maximal 8.

    Gibt ein PSCustomObject mit aktuellem Wert, empfohlenem Wert und Status zurueck.

**Parameters:**

- **-SqlInstance** - SQL Server-Instanz. Standard: lokaler Computername.
- **-SqlCredential** - PSCredential fuer die SQL-Verbindung.
- **-MaxFiles** - Maximale empfohlene Dateianzahl. Standard: 8 (Microsoft-Empfehlung).
- **-EnableException** - Ausnahmen sofort ausloesen statt Write-Error.

**Examples (2):**

```powershell
Test-sqmTempDbFileCount -SqlInstance "SQL01"

```powershell
Test-sqmTempDbFileCount -SqlInstance "SQL01\INST1" -MaxFiles 4

### Get-sqmServerUtilization

Collects SQL Server CPU and memory utilization trends over time.

    Captures multiple snapshots of SQL Server memory and CPU metrics from DMVs,
    calculates Min/Max/Avg trends, and generates reports (TXT, CSV, HTML).

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: local computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-SampleCount** - Number of snapshots to collect. Default: 6.
- **-SampleIntervalSeconds** - Interval between snapshots in seconds. Default: 10. (Total sampling time = SampleCount * SampleIntervalSeconds)
- **-OutputPath** - Directory for report output. Default: from module config.
- **-NoOpen** - Suppress automatic report opening.
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
    Get-sqmServerUtilization -SqlInstance "SQL01"
    # Collects 6 snapshots (60 seconds) and generates HTML report

```powershell
    Get-sqmServerUtilization -SqlInstance "SQL01" -SampleCount 12 -SampleIntervalSeconds 5
    # Collects 12 snapshots (60 seconds total)

## 6. Certificates & TLS Security

### Get-sqmCertificateReport

Creates a comprehensive report on SQL Server certificates and their expiration dates.

Checks all security-relevant certificates on one or more instances:

    MASTER KEY
      - Checks whether a Database Master Key exists in master (required for certificates)
      - Checks whether the DMK is encrypted by the Service Master Key (important for automatic startup)

    INSTANCE CERTIFICATES (sys.certificates in master)
      - AlwaysOn endpoint certificates (Hadr_endpoint)
      - Service Broker certificates
      - Backup encryption certificates
      - All other certificates in master

    TDE CERTIFICATES (Transparent Data Encryption)
      - Per encrypted database: which certificate, expiration date, encryption state

    DATABASE CERTIFICATES
      - Certificates in user databases (e.g. for column encryption, signing)

    PER CERTIFICATE:
      - Name, type, issuer, subject
      - Expiration date with traffic-light status (OK / Warning / Critical / Expired)
      - Remaining days until expiration
      - Purpose (AlwaysOn / TDE / ServiceBroker / Backup / UserDefined)
      - Whether the private key is present and encrypted
      - Thumbprint

    Results are saved as TXT report and CSV in the configured OutputPath.
    An additional filtered CSV is generated containing only expiring/expired certificates.

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-WarningThresholdDays** - Certificates expiring in less than this number of days receive status 'Warning'. Default: 90.
- **-CriticalThresholdDays** - Certificates expiring in less than this number of days receive status 'Critical'. Default: 30.
- **-IncludeUserDatabases** - Also include certificates in user databases. Default: $false.
- **-OutputPath** - Output directory for report files. Default: from module configuration.
- **-ContinueOnError** - Continue on error for an instance instead of aborting.
- **-EnableException** - Throw exceptions immediately.

**Examples (4):**

```powershell
Get-sqmCertificateReport

```powershell
Get-sqmCertificateReport -SqlInstance "SQL01","SQL02" -WarningThresholdDays 180

```powershell
# Show only expiring certificates
    Get-sqmCertificateReport -SqlInstance "SQL01" |
        Select-Object -ExpandProperty Certificates |
        Where-Object { $_.ExpiryStatus -ne 'OK' } |
        Select-Object SqlInstance, DatabaseName, CertificateName, ExpiryDate, DaysRemaining, ExpiryStatus, Purpose

```powershell
# Pipeline across multiple instances
    'SQL01','SQL02','SQL03' | Get-sqmCertificateReport -OutputPath "D:\Reports\Certs"

### Install-sqmCertificate



Supports three input formats:
      PFX   (.pfx)  - Certificate + private key in one file (CA-signed or exported)
      CER+PVK       - Certificate (.cer) + encrypted private key (.pvk) separately
      CER only      - Certificate without private key (e.g. public key for AlwaysOn replicas)

    Process:
      1. Read certificate file and validate content (expiry date, subject, format)
      2. Check whether a certificate with the same thumbprint already exists in SQL Server
      3. Import certificate via CREATE CERTIFICATE in SQL Server
      4. Automatically bind based on -Purpose:
           AlwaysOn      -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
                            Output guidance for replica distribution
           TDE           -> ALTER DATABASE ... SET ENCRYPTION KEY ... CERTIFICATE <new>
           SSL           -> Import certificate into Windows machine store +
                            set SQL Server network protocol certificate (Registry)
           ServiceBroker -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
      5. Write installation log as TXT

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the SQL Server connection.
- **-CertFile** - Path to the certificate file (.pfx, .cer, .crt, .p12). For PFX the private key is automatically imported.
- **-PrivateKeyFile** - Path to the separate private key file (.pvk). Only required for CER+PVK format.
- **-CertPassword** - Password for the PFX file or .pvk file (as SecureString).
- **-CertificateName** - Name under which the certificate is created in SQL Server. Default: file name without extension.
- **-Database** - Target database in SQL Server. Default: master.
- **-Purpose** - Purpose determines the automatic binding after import. Valid values: AlwaysOn, TDE, SSL, ServiceBroker, UserDefined. Default: UserDefined (no automatic binding).
- **-EndpointName** - Name of the endpoint for AlwaysOn/ServiceBroker binding. If not specified, the first matching endpoint is determined automatically.
- **-TdeDatabaseName** - Name of the database for TDE binding. If not specified, the current TDE-encrypted database on the instance is determined (only if unique).
- **-ReplaceCertificateName** - Name of an existing certificate that is replaced (endpoint/TDE switched) after successful installation. The old certificate is NOT deleted.
- **-ImportToWindowsStore** - Additionally import the certificate into the Windows machine certificate store. Required for SSL/TLS connections. Default: $false; automatically $true when Purpose=SSL.
- **-SetSqlServerSslCert** - Set the SQL Server network configuration to use this certificate (thumbprint). Requires a restart of the SQL Server service. Default: $false.
- **-OutputPath** - Output directory for the installation log. Default: from module configuration.
- **-EnableException** - Throw exceptions immediately.

**Examples (4):**

```powershell
# Import PFX from CA and bind to AlwaysOn endpoint
    Install-sqmCertificate -SqlInstance "SQL01" -CertFile "C:\Certs\sql01.pfx" `
        -CertPassword (Read-Host -AsSecureString) -Purpose AlwaysOn

```powershell
# Install public-key certificate on AlwaysOn replica (no private key)
    Install-sqmCertificate -SqlInstance "SQL02" -CertFile "C:\Certs\SQL01_AG_CERT.cer" `
        -CertificateName "SQL01_AG_CERT" -Purpose AlwaysOn

```powershell
# Install CER + PVK and bind TDE
    Install-sqmCertificate -SqlInstance "SQL01" `
        -CertFile "C:\Certs\tde_new.cer" `
        -PrivateKeyFile "C:\Certs\tde_new.pvk" `
        -CertPassword (Read-Host -AsSecureString "PVK password") `
        -Purpose TDE -TdeDatabaseName "ProdDB"

```powershell
# Install SSL certificate (Windows Store + SQL Server network)
    Install-sqmCertificate -SqlInstance "SQL01" -CertFile "C:\Certs\ssl.pfx" `
        -CertPassword (Read-Host -AsSecureString) -Purpose SSL -SetSqlServerSslCert

### Install-sqmCertificateToStore



Reads a certificate file (.cer, .crt, or .pfx) and installs it into the
    specified Windows certificate store (LocalMachine) on one or more computers.

    Use cases:
      - Distribute a CA root certificate to the Trusted Root store on all nodes
      - Distribute a SQL Server self-signed certificate to admin workstations
      - Distribute AlwaysOn partner certificates (CER without private key) to replica machines

    Process:
      1. Read the certificate file and determine format (PFX vs CER/CRT) by extension
         and by attempting to parse the file
      2. For PFX files: load with X509KeyStorageFlags MachineKeySet + PersistKeySet
         and an optional password
      3. For CER/CRT files: load without password
      4. Open the target store (LocalMachine\<StoreName>) with ReadWrite access
      5. Check whether a certificate with the same thumbprint is already present -
         skip and log WARNING if so
      6. Add the certificate and close the store
      7. For remote computers: serialize the certificate as a byte array and pass it
         via Invoke-Command so the import runs on the target without needing file share access

    Returns one PSCustomObject per target computer with:
      ComputerName, StoreName, Thumbprint, Subject, Expiry, Action
    Action values: Installed / AlreadyPresent / Failed

**Parameters:**

- **-CertFile** - Full path to the certificate file (.cer, .crt, or .pfx). The file must exist and be readable.
- **-StoreName** - Target Windows certificate store under LocalMachine. Valid values: Root, My, TrustedPeople, CA Default: Root
- **-ComputerName** - One or more target computer names. Default: localhost only (the local machine). For remote targets PowerShell Remoting (WinRM) must be enabled and accessible.
- **-CertPassword** - Password for PFX files as SecureString. Ignored for CER/CRT files.

**Examples (4):**

```powershell
# Install a CA root certificate to the Trusted Root store on all AlwaysOn replica nodes
    $nodes = 'SQL-AG-01', 'SQL-AG-02', 'SQL-AG-03'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\CompanyRootCA.cer' `
        -StoreName Root -ComputerName $nodes

```powershell
# Distribute a SQL Server self-signed certificate to an admin workstation
    Install-sqmCertificateToStore -CertFile 'C:\Certs\SQL-PROD-01.cer' `
        -StoreName TrustedPeople -ComputerName 'ADMINWS-01'

```powershell
# Distribute an AlwaysOn partner certificate (CER without private key) to replica machines
    $replicas = 'SQL-AG-02', 'SQL-AG-03'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\SQL-AG-01_AG_CERT.cer' `
        -StoreName My -ComputerName $replicas

```powershell
# Install a PFX certificate with password into the Personal store on the local machine
    $pwd = Read-Host -AsSecureString 'PFX password'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\sql-ssl.pfx' `
        -StoreName My -CertPassword $pwd

### New-sqmCertificateRequest



Reads all relevant properties of the existing certificate from SQL Server
    (Subject, SANs, purpose, endpoint binding) and creates:

    1. INF file (certreq configuration) with all fields from the existing certificate
    2. CSR file (.csr / PKCS#10) via Windows certreq.exe or New-SelfSignedCertificate
    3. Order data sheet (.txt) with:
         - All information for the CA order (Subject, SANs, Key Usage, EKU)
         - Suggested certificate type based on purpose
         - Checklist for the ordering process
         - T-SQL commands for later installation
    4. Optional: Generate private key locally and store securely

    PURPOSE-SPECIFIC HANDLING:
      AlwaysOn / Mirroring  -> Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication (1.3.6.1.5.5.7.3.1)
      TDE                   -> Note: TDE typically uses self-signed certificates;
                               CA-signed certificates are possible but uncommon
      SSL/TLS connections   -> Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication + Client Authentication
      Service Broker        -> Key Usage: Digital Signature, Key Encipherment

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name). Used for SAN and order sheet.
- **-SqlCredential** - PSCredential for the connection.
- **-CertificateName** - Name of the existing certificate to use as a template. If not specified, a new certificate is created without a template (-Subject then becomes required).
- **-Database** - Database where the certificate resides. Default: master.
- **-Subject** - Subject (CN) of the new certificate. Overrides the value from the existing certificate. Format: CN=SQL01.domain.com,O=Company,L=City,S=State,C=DE
- **-SubjectAlternativeNames** - Additional SANs (DNS names or IP addresses). Automatically extended with: FQDN, NetBIOS name, AG listener (if detected).
- **-KeyLength** - Key length in bits. Default: 4096.
- **-ValidityYears** - Desired validity period in years (information for the CA, not guaranteed). Default: 3.
- **-Purpose** - Purpose when no existing certificate is used as a template. Valid values: AlwaysOn, TDE, SSL, ServiceBroker, UserDefined.
- **-OutputPath** - Output directory for CSR, INF, and order data sheet. Default: $env:ProgramData\sqmSQLTool\Logs\Cert
- **-Organization** - Organization name for the certificate (O=). Default: from existing certificate or computer name.
- **-OrganizationalUnit** - Organizational unit (OU=). Optional.
- **-Locality** - City/locality (L=). Optional.
- **-State** - State/province (S=). Optional.
- **-Country** - Two-letter country code (C=). Default: DE.
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
# CSR based on an existing certificate
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "AG_CERT"

```powershell
# New CSR without template, all fields specified manually
    New-sqmCertificateRequest -SqlInstance "SQL01" -Purpose "SSL" `
        -Subject "CN=SQL01.firma.de,O=Firma GmbH,L=Muenchen,C=DE" `
        -SubjectAlternativeNames @("sql01.firma.de","sql01","192.168.1.10") `
        -KeyLength 4096 -ValidityYears 2

```powershell
# CSR with output to a specific directory
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "TLS_CERT" `
        -OutputPath "D:\CertRequests"

### New-sqmSqlCertificate

Creates a new self-signed SQL Server certificate as a renewal of an existing one.

Reads all relevant properties of the existing certificate (Subject, purpose,
    endpoint binding, TDE binding) and creates a new self-signed certificate directly
    in SQL Server using CREATE CERTIFICATE.

    Process:
      1. Read existing certificate and determine its purpose
      2. Back up old certificate as .cer + private key as .pvk (BackupPath)
      3. Create new certificate with same properties and new expiry date
      4. Automatically bind based on purpose:
           AlwaysOn  -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
           TDE       -> ALTER DATABASE ... SET ENCRYPTION KEY ... CERTIFICATE <new>
           Broker    -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
      5. Rename old certificate (suffix _OLD_<date>) — do not delete
      6. Output order data sheet as TXT (Subject, thumbprint old/new, bindings)

    NOTE: For AlwaysOn, the new certificate must subsequently be distributed to all
    replica instances. The function outputs the necessary steps as instructions.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-CertificateName** - Name of the certificate to renew (exact name from sys.certificates).
- **-Database** - Database where the certificate resides. Default: master.
- **-NewCertificateName** - Name of the new certificate. Default: <OldName>_<Year> (e.g. AG_CERT_2027).
- **-ValidityYears** - Validity period of the new certificate in years. Default: 5.
- **-BackupPath** - Path for backing up the old certificate (.cer and .pvk). Default: from module configuration (OutputPath).
- **-BackupEncryptionPassword** - Password for encrypting the exported private key (.pvk). Required when the old certificate has a private key.
- **-RenameOldCertificate** - Rename the old certificate after renewal (suffix _OLD_<date>). Default: $true.
- **-BindEndpoint** - Automatically bind the new certificate to the existing endpoint (AlwaysOn/Broker). Default: $false — must be explicitly confirmed.
- **-BindTde** - Automatically activate the new certificate for TDE-encrypted databases. Default: $false — must be explicitly confirmed.
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
# Simple renewal without automatic binding
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "AG_CERT" -BackupEncryptionPassword (Read-Host -AsSecureString)

```powershell
# With automatic endpoint binding and 10-year validity
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "AG_CERT" `
        -ValidityYears 10 -BindEndpoint `
        -BackupEncryptionPassword (Read-Host -AsSecureString "Backup-Passwort")

```powershell
# Renew TDE certificate
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "TDE_PROD" `
        -BindTde -BackupEncryptionPassword (Read-Host -AsSecureString "Backup-Passwort")

### Set-sqmSqlTlsCertificate

Binds a Windows certificate from the Machine store to SQL Server as the TLS certificate.

Replaces the default self-signed auto-generated SQL Server TLS certificate with a
    proper certificate from the LocalMachine\My store. This eliminates SSL/TLS connection
    warnings in client applications and satisfies security/compliance requirements.

    Process:
      1. Resolve the SQL Server instance registry key name from the Instance Names registry
      2. Validate the certificate: find by thumbprint, check expiry, verify private key
      3. Determine SQL Server service name (MSSQLSERVER or MSSQL$INSTANCENAME)
      4. Get SQL Server service account from WMI
      5. Grant READ permission on the certificate private key to the service account
         (supports both CSP keys in MachineKeys and CNG keys in Crypto\Keys)
      6. Write the thumbprint to the SuperSocketNetLib registry key
      7. Optionally enable Force Encryption in the same registry key
      8. Optionally restart the SQL Server service to apply the change

    Returns a PSCustomObject summarising the result. A service restart is always required
    for the new certificate to take effect - either via -Restart or manually.

**Parameters:**

- **-SqlInstance** - SQL Server instance name. For a default instance use the computer name or leave at default ($env:COMPUTERNAME). For a named instance use COMPUTERNAME\INSTANCENAME.
- **-Thumbprint** - Certificate thumbprint (hex string). Spaces are stripped automatically. Must match a certificate in Cert:\LocalMachine\My.
- **-ForceEncryption** - If specified, sets ForceEncryption = 1 in the SuperSocketNetLib registry key, requiring all connections to use TLS encryption.
- **-Restart** - If specified, restarts the SQL Server service automatically after the registry change. Without this switch the service must be restarted manually.
- **-WhatIf** - Shows what would be changed without making any modifications.
- **-Confirm** - Prompts for confirmation before making changes.

**Examples (3):**

```powershell
Set-sqmSqlTlsCertificate -SqlInstance "SQL01" -Thumbprint "A1B2C3D4E5F6..."

    Binds the specified certificate to the default instance on SQL01.
    Service restart must be performed manually.

```powershell
Set-sqmSqlTlsCertificate -SqlInstance "SQL01\INST1" -Thumbprint "A1B2C3D4E5F6..." -ForceEncryption -Restart

    Binds the certificate to the named instance INST1, enables Force Encryption,
    and restarts the SQL Server service automatically.

```powershell
Set-sqmSqlTlsCertificate -Thumbprint "A1 B2 C3 D4 E5 F6" -WhatIf

    Shows what would be done for the local default instance without making changes.
    Thumbprint spaces are stripped automatically.

### Set-sqmSsrsHttpsCertificate

Binds a Windows certificate to SSRS or Power BI Report Server for HTTPS access.

Eliminates browser security warnings by binding a valid certificate to the SSRS
		or Power BI Report Server (PBIRS) HTTPS endpoint via the WMI configuration interface.

		The function performs the following steps:
		1. Discovers the SSRS/PBIRS WMI namespace dynamically under
		   root\Microsoft\SqlServer\ReportServer\{Instance}\v{Version}\Admin
		2. Validates the certificate in Cert:\LocalMachine\My by thumbprint
		3. Lists and removes existing HTTPS URL reservations for all web applications
		4. Removes existing SSL certificate bindings
		5. Reserves HTTPS URLs for all applicable web applications
		6. Creates the SSL certificate binding
		7. Optionally sets SecureConnectionLevel to require HTTPS
		8. Calls ApplyChanges() to finalize

		Supported application names (auto-detected by version):
		- ReportServerWebService  (always present)
		- ReportManager           (SSRS 2016 and earlier, v13-)
		- ReportServerWebApp      (SSRS 2017+ / PBIRS, v14+)

		Prerequisites: Local administrator rights on the target computer.
		For remote execution, WinRM must be available.
		The certificate must already be present in the LocalMachine\My store on the target.
		The SSRS service may need to be restarted after binding.

**Parameters:**

- **-ComputerName** - Target computer name or IP address. Default: localhost ($env:COMPUTERNAME).
- **-Thumbprint** - Mandatory. Certificate thumbprint (40 hex characters) from the LocalMachine\My store. Spaces are automatically removed from the thumbprint string.
- **-Port** - HTTPS port to bind. Default: 443.
- **-InstanceName** - SSRS WMI instance name (e.g. "RS_SSRS", "RS_PBIRS"). Auto-detected when only one instance is found under the WMI namespace. Required when multiple instances exist on the same server.
- **-IPAddress** - IP address for the SSL binding. Default: "0.0.0.0" (all interfaces).
- **-RequireSSL** - When specified, sets SecureConnectionLevel = 1 (HTTPS required). Default: SecureConnectionLevel = 0 (HTTPS optional, HTTP still allowed).
- **-Credential** - PSCredential for the WinRM session (remote operation only).
- **-WhatIf** - Shows what would happen without making any changes.
- **-Confirm** - Prompts for confirmation before applying changes.

**Examples (3):**

```powershell
Set-sqmSsrsHttpsCertificate -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"

		Binds the specified certificate to SSRS on the local machine on port 443.
		The SSRS instance is auto-detected.

```powershell
Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER01" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Port 8443 -InstanceName "RS_PBIRS" -RequireSSL

		Binds the certificate to Power BI Report Server on REPSERVER01, port 8443,
		and requires HTTPS (SecureConnectionLevel = 1).

```powershell
$cred = Get-Credential
		Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER02" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Credential $cred -WhatIf

		Shows what changes would be made on REPSERVER02 without applying them.

### Get-sqmTlsStatus

Audits TLS/SSL configuration and certificate status for all SQL Server instances on one or more computers.

Get-sqmTlsStatus connects to each target computer (locally or via Invoke-Command for remotes),
    reads the SQL Server instance list from the registry, and for each instance checks:

    - The TLS certificate thumbprint bound in SuperSocketNetLib (empty = auto-generated self-signed)
    - Whether ForceEncryption is enabled (0 = Warning, 1 = required)
    - Certificate details from the local machine certificate store (Cert:\LocalMachine\My):
        Expiry date, days remaining, Subject/CN, SAN entries, chain trust validation, private key presence
    - TLS protocol version state at the OS/SCHANNEL level:
        TLS 1.0, TLS 1.1, TLS 1.2, TLS 1.3 -- each reported as Enabled, Disabled, or NotConfigured

    Status is calculated per instance:
    - Critical : cert expired, cert not found in store, or cert chain not trusted
    - Warning  : cert expires within 60 days, ForceEncryption = 0, or TLS 1.0 / TLS 1.1 enabled
    - OK       : cert trusted, not expiring soon, ForceEncryption = 1, TLS 1.0 and TLS 1.1 disabled

    Results are written to a CSV and a TXT summary report in OutputPath, and returned as PSCustomObjects.

**Parameters:**

- **-ComputerName** - One or more computer names to audit. Default: current computer ($env:COMPUTERNAME).
- **-Credential** - Optional PSCredential used for Invoke-Command when auditing remote computers.
- **-OutputPath** - Directory where the CSV and TXT report files are saved. Default: C:\System\WinSrvLog\MSSQL
- **-WarnDaysBeforeExpiry** - Number of days before certificate expiry that triggers a Warning status. Default: 60

**Examples (3):**

```powershell
Get-sqmTlsStatus

    Audits all SQL Server instances on the local computer and saves results to the default log folder.

```powershell
Get-sqmTlsStatus -ComputerName "SQL01", "SQL02" -OutputPath "D:\Reports"

    Audits SQL01 and SQL02, saves reports to D:\Reports.

```powershell
$cred = Get-Credential
    Get-sqmTlsStatus -ComputerName "SQL01" -Credential $cred | Where-Object Status -ne "OK"

    Audits SQL01 with explicit credentials and filters for non-OK results.

## 15. Extended Events & Diagnostics

### Get-sqmDeadlockReport

Reads and analyzes deadlock events from the System Health Extended Event session.

The System Health session (always active since SQL Server 2008) logs all
    deadlocks as XML in the ring buffer. This function reads that buffer,
    parses the deadlock graphs and returns for each deadlock:

      - Timestamp of the deadlock
      - Victim session with login, host, program, statement
      - All involved processes with their statements and held/requested locks
      - Involved resources (tables, indexes, objects)
      - Deadlock graph as XML (for SSMS import or storage as .xdl)

    Optionally, deadlock graphs can be saved as .xdl files
    (openable directly in SSMS by double-click).

    Additionally, the System Health .xel ring buffer is read when available
    (SQL Server 2012+, provides more history than the ring buffer).

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-StartTime** - Return only deadlocks from this point in time. Default: last 24 hours.
- **-EndTime** - Return only deadlocks up to this point in time. Default: now.
- **-MaxDeadlocks** - Maximum number of deadlocks returned (newest first). Default: 100.
- **-OutputPath** - If specified, deadlock graphs are saved as .xdl files in this directory (format: Deadlock_<Instance>_<Timestamp>.xdl).
- **-EnableException** - Throw exceptions immediately instead of returning as errors.

**Examples (4):**

```powershell
Get-sqmDeadlockReport

```powershell
Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-7)

```powershell
# Save deadlocks as XDL files for SSMS
    Get-sqmDeadlockReport -SqlInstance "SQL01" -OutputPath "$env:ProgramData\sqmSQLTool\Logs\Deadlocks"

```powershell
# Only deadlocks from the last hour, show number of affected statements
    Get-sqmDeadlockReport -StartTime (Get-Date).AddHours(-1) |
        Select-Object Timestamp, VictimLogin, VictimStatement, ProcessCount

### Invoke-sqmExtendedEvents

Manages Extended Events sessions for performance analysis on SQL Server.

Creates, starts, stops, reads and evaluates Extended Events sessions.

    Operating modes (switches, combinable):
      -Create    Creates a new XEvent session based on a template.
      -Start     Starts an existing (or newly created) session.
      -Stop      Stops a running session.
      -Read      Reads events from the XEL ring buffer or a file.
      -Diagnose  Aggregates events and detects patterns (top waits, blocking chains,
                 slow queries, deadlocks).
      -Drop      Removes a session completely (including XEL files).

    If no switch is specified, -Read and -Diagnose are executed.

    Available session templates:
      SlowQueries   sql_statement_completed > threshold (default: 1000 ms)
      Blocking      blocked_process_report
      Waits         wait_info with configurable wait list
      Deadlocks     xml_deadlock_report
      AllInOne      Combines all four templates in one session

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-SessionName** - Name of the XEvent session. Default: 'sqmPerformance'.
- **-Template** - Session template when creating. Values: SlowQueries, Blocking, Waits, Deadlocks, AllInOne. Default: AllInOne.
- **-SlowQueryThresholdMs** - Minimum execution duration in milliseconds for SlowQueries capture. Default: 1000.
- **-WaitTypes** - Comma-separated list of wait types for the Waits template. Default: LCK_M_X,LCK_M_S,LCK_M_U,PAGEIOLATCH_SH,PAGEIOLATCH_EX,CXPACKET,SOS_SCHEDULER_YIELD
- **-TargetType** - Target type for event storage: RingBuffer or File. Default: RingBuffer.
- **-TargetFilePath** - Directory for XEL files (only for TargetType = File). Default: from module configuration OutputPath + \XEvents.
- **-MaxFileSizeMB** - Maximum size of an XEL file (MB). Default: 100.
- **-MaxRolloverFiles** - Number of XEL rollover files. Default: 5.
- **-RingBufferMaxMB** - Maximum size of the ring buffer (MB). Default: 50.
- **-MaxEventsRead** - Maximum number of events when reading. Default: 10000.
- **-LookbackMinutes** - Time window for diagnostic aggregation in minutes. Default: 60.
- **-TopN** - Number of top entries in diagnostic tables. Default: 25.
- **-OutputPath** - Directory for saved reports. Default: from module configuration + \XEvents.
- **-Create** - Create session.
- **-Start** - Start session.
- **-Stop** - Stop session.
- **-Read** - Read events.
- **-Diagnose** - Aggregate events and detect issues.
- **-Drop** - Remove session.
- **-EnableException** - Throw exceptions immediately.

**Examples (4):**

```powershell
# Create AllInOne session and start immediately
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Create -Start

```powershell
# Record Slow Queries > 2 seconds, save to file
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Template SlowQueries -SlowQueryThresholdMs 2000 -TargetType File -Create -Start

```powershell
# Read running session and create report
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Read -Diagnose

```powershell
# Stop session and remove it
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Stop -Drop

### Invoke-sqmMonitoringKey

Gets or sets monitoring registry values for the sqmSQLTool on one or more computers.

Reads or writes the registry key HKLM:\<RegistryBase>\dtcSoftware\sqmSQLTool on
    the specified computers. The key controls which monitoring components are active:
    SQL monitoring level (None/Standard/Full), SQLFreeSpaceVersion (Standard/Cluster),
    and TSM backup monitoring (0/1).

    When -Operation is 'Set', the specified values are written to the registry.
    The key is created automatically if it does not exist.
    The current values are always read and returned after a write operation.

    Remote access uses Invoke-Command (WinRM). Provide -Credential for remote computers
    if required.

**Parameters:**

- **-ComputerName** - Target computer(s). Pipeline-capable. Default: current computer name.
- **-Operation** - 'Get' (default) reads the current values; 'Set' writes the specified values.
- **-SQL** - SQL monitoring level: 'None', 'Standard', or 'Full'. Stored as DWORD (0/1/2) in the registry.
- **-SQLFreeSpaceVersion** - Free-space monitoring variant: 'Standard' (standalone) or 'Cluster' (AlwaysOn AG).
- **-TSM** - TSM backup monitoring: 0 = inactive, 1 = active.
- **-RegistryBase** - Registry hive path base under HKLM. Default: 'System'.
- **-AutoDetectSQLFreeSpaceVersion** - When set (and -Operation Set), automatically detects whether the instance belongs to an AlwaysOn AG and sets SQLFreeSpaceVersion accordingly (Cluster/Standard).
- **-Credential** - PSCredential for remote computer access.
- **-ContinueOnError** - Continue with the next computer on error.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).

**Examples (3):**

```powershell
Invoke-sqmMonitoringKey

```powershell
Invoke-sqmMonitoringKey -Operation Set -SQL Standard -TSM 1 -AutoDetectSQLFreeSpaceVersion

```powershell
"SQL01","SQL02" | Invoke-sqmMonitoringKey -Operation Set -SQL Full -TSM 1

## 9. Database Maintenance

### Find-sqmDatabaseObject

Searches all (or selected) databases on an instance for an object name.

Searches user databases for tables, views, procedures, functions, triggers, synonyms.
    Returns the location (database, schema, object type, name). Can filter by SQL text (full definition).

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-ObjectName** - Name of the object to search for, or wildcard (e.g. '*customer*').
- **-ObjectType** - Restrict to type: 'TABLE', 'VIEW', 'PROCEDURE', 'FUNCTION', 'TRIGGER', 'SYNONYM'. Multiple values possible as array.
- **-Database** - Databases to search (wildcard, default: all user databases).
- **-IncludeSystem** - Include system databases. Default: $false.
- **-SearchDefinition** - If $true, the object text (definition) is also searched for <ObjectName> (slower).
- **-EnableException** - Throw exceptions immediately.

**Examples (2):**

```powershell
Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "sp_GetOrders"

```powershell
Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "*log*" -ObjectType "TABLE","VIEW" -Database "Sales*"

### Invoke-sqmLogShrink

Shrinks the transaction log file (LDF) of one or more databases.

Executes DBCC SHRINKFILE on the log file(s). Calculates the target size
    as a percentage of the current size (ShrinkTargetPercent) with a
    lower threshold (MinTargetMB). Handles Always On AGs (automatically
    redirects to the primary). System databases and offline databases are skipped.

    Important notes:
    - Shrink can only reduce to the oldest active VLF.
    - In FULL recovery model, a log backup beforehand is advisable.
    - Frequent shrinking fragments VLFs.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name). For AG members, automatically redirected to the primary.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-Database** - Target database name(s) (wildcards allowed). Without specification, all user databases are processed (equivalent to -All).
- **-All** - Processes all user databases (excl. system databases, online only). Also used implicitly when neither -Database nor -All is specified.
- **-ShrinkTargetPercent** - Target size as a percentage of the current log size (1-99). Default: 10.
- **-MinTargetMB** - Minimum target size in MB (default: 64 MB).
- **-ContinueOnError** - Continue with the next database on error.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).
- **-Confirm** - Request confirmation before shrinking. Disabled by default.
- **-WhatIf** - Shows what would happen without executing the shrink.

**Examples (2):**

```powershell
Invoke-sqmLogShrink -Database "MyDB" -ShrinkTargetPercent 20

```powershell
Invoke-sqmLogShrink -SqlInstance "SQL01" -All -WhatIf

### Invoke-sqmSetDatabaseRecoveryMode

Changes the recovery mode of one or more user databases.

Sets the recovery mode (Simple, Full, BulkLogged) for all or selected user databases
on a SQL Server instance. System databases are automatically excluded.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

**Parameters:**

- **-SqlInstance** - The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.
- **-SqlCredential** - Alternative credentials (PSCredential). If not specified, Windows authentication is used.
- **-Database** - Name or array of user databases whose recovery mode should be changed.
Ignored when -All is set.
- **-All** - When set, changes the recovery mode for all user databases.
- **-RecoveryMode** - The desired recovery mode. Allowed values: Simple, Full, BulkLogged.
- **-EnableException** - Switch to propagate exceptions immediately (by default errors are logged as warnings).
- **-Confirm** - Prompts for confirmation before execution. Disabled by default.
Passed through to Set-DbaDbRecoveryModel.
- **-WhatIf** - Shows what would happen without actually making the change.
Passed through to Set-DbaDbRecoveryModel.

**Examples (2):**

```powershell
# Set all user databases to Full (without prompting)
Invoke-sqmSetDatabaseRecoveryMode -All -RecoveryMode Full

```powershell
# With confirmation prompt (passed to Set-DbaDbRecoveryModel)
Invoke-sqmSetDatabaseRecoveryMode -Database "SalesDB" -RecoveryMode Simple -Confirm

### Invoke-sqmUpdateStatistics

Updates statistics in one or more databases.

Executes UPDATE STATISTICS with configurable options (scan percentage, only modified statistics, etc.).
    Can be restricted to specific databases, tables, or statistics.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-Database** - Database name or wildcard pattern.
- **-Table** - Table name or wildcard pattern.
- **-Statistics** - Statistic name or wildcard pattern.
- **-SamplePercent** - Percentage of rows used for the update (0 = full scan). Default: 0.
- **-OnlyModified** - Only update statistics that have changed since the last update. Default: $true.
- **-Index** - Also update statistics associated with an index. Default: $true.
- **-WhatIf** - Shows which statistics would be affected.
- **-EnableException** - Throw exceptions immediately.

**Examples (1):**

```powershell
Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 10

### Set-sqmDatabaseOwner

Sets the owner of one or more databases to a uniform login.

Checks and corrects the database owner on one or more SQL Server instances.
    Typical use case: after restores or migrations the owner is often a login that no
    longer exists or is incorrect. The function uniformly sets it to the sa account
    (regardless of the actual sa name, which may have been renamed via obfuscation) or
    any other login.

    Process per database:
      1. Read current owner
      2. Check whether a change is necessary (already correct -> skip)
      3. Check whether the target login exists on the instance
      4. Execute ALTER AUTHORIZATION ON DATABASE::<Name> TO <Login>
      5. Log result

    Returns a status object for each database:
      Status = OK / Skipped / Failed / NotFound

**Parameters:**

- **-SqlInstance** - SQL Server instance(s). Pipeline-capable. Default: current computer name.
- **-SqlCredential** - PSCredential for the connection.
- **-Database** - Database name(s). Wildcards allowed (e.g. 'Prod*'). Default: all user databases.
- **-ExcludeDatabase** - Databases to exclude. Wildcards allowed.
- **-OwnerLogin** - Login to set as the new owner. Default: sa account (automatically determined via SID 0x01, regardless of whether it has been renamed).
- **-IncludeSystemDatabases** - Also include system databases (master, model, msdb). Default: $false. tempdb is always excluded.
- **-Force** - Also process databases that already have the correct owner (forces re-assignment).
- **-OutputPath** - Directory for the change log. Default: from module configuration.
- **-ContinueOnError** - Continue on error for one instance. Default: $false.
- **-EnableException** - Throw exceptions immediately.

**Examples (4):**

```powershell
# Set sa account on all user databases
    Set-sqmDatabaseOwner -SqlInstance "SQL01"

```powershell
# Specific databases with a custom login
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -Database "Prod*" -OwnerLogin "svc_sqlowner"

```powershell
# Pipeline across multiple instances
    'SQL01','SQL02' | Set-sqmDatabaseOwner

```powershell
# WhatIf - only show what would be changed
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -WhatIf

### Install-sqmOlaMaintenanceSolution

Installs or updates Ola Hallengren's Maintenance Solution on a SQL Server instance.

    Downloads the latest version of the Maintenance Solution from GitHub
    (https://github.com/olahallengren/sql-server-maintenance-solution/archive/refs/heads/main.zip),
    extracts the required scripts and executes them in the following order:
    1. CommandExecute.sql
    2. CommandLog.sql
    3. DatabaseBackup.sql
    4. DatabaseIntegrityCheck.sql
    5. IndexOptimize.sql

    The installation creates only the database objects (tables, procedures),
    but no SQL Agent jobs. Jobs are created later using the dedicated functions
    (e.g. New-sqmOlaBackupJobs).

    Existing installations are overwritten with -Force / -Update.

**Parameters:**

- **-SqlInstance** - SQL Server instance (default: current computer name).
- **-SqlCredential** - PSCredential for the connection.
- **-SourcePath** - Alternative source for the ZIP archive. Default: GitHub ZIP.
- **-Force** - Ignore existing installation and reinstall.
- **-Update** - Alias for -Force.
- **-ContinueOnError** - Continue with the next instance on error.
- **-EnableException** - Throw exceptions immediately.
- **-Confirm** - Request confirmation before installation.
- **-WhatIf** - Shows what would happen without making changes.

**Examples (2):**

```powershell
    Install-sqmOlaMaintenanceSolution -SqlInstance "SQL01"

```powershell
    Install-sqmOlaMaintenanceSolution -SqlInstance "SQL01" -Force

### Test-sqmOlaInstallation

Checks whether Ola Hallengren's Maintenance Solution is installed on a SQL Server instance.

    Tests for the presence of the stored procedure 'DatabaseBackup' in the 'master' schema.
    Optionally checks whether the 'CommandLog' table and 'DatabaseIntegrityCheck' etc. are also present.

**Parameters:**

- **-SqlInstance** - SQL Server instance.
- **-SqlCredential** - Credentials.
- **-RequiredSet** - Which components are required at minimum: 'Backup', 'Integrity', 'Index' (Default: 'Backup').

## 22. Monitoring & Registry

### Enable-sqmMonitoringAccess

Richtet einen Monitoring-Account auf allen SQL Server-Instanzen eines Computers ein.

Findet alle SQL Server-Instanzen auf dem Zielcomputer per Registry-Abfrage,
    verbindet sich mit jeder Instanz und richtet folgende Objekte ein:

    - Server-Rolle ($ServerRoleName) mit den notwendigen Server-Berechtigungen
    - Login ($MonitoringUser) als Windows-Login
    - Datenbank-Rolle ($DatabaseRoleName) in master und msdb
    - Datenbankbenutzer und Rollenzuordnung in master und msdb
    - Granulare GRANT-Berechtigungen auf System-Views und Stored Procedures

    Optional: Eine SQL Server Policy kann vor dem Setup deaktiviert und
    danach wieder aktiviert werden (-PolicyName).

    Ausgabe:
        MonitoringAccess_<computer>_<datum>.log  - Protokoll der ausgefuehrten Schritte

**Parameters:**

- **-ComputerName** - Zielcomputer. Standard: aktueller Computer.
- **-MonitoringUser** - Windows-Login des Monitoring-Accounts (z.B. "DOMAIN\MonUser").
- **-ServerRoleName** - Name der SQL Server-Rolle die angelegt wird. Standard: "MonitoringRole".
- **-DatabaseRoleName** - Name der Datenbank-Rolle die in master und msdb angelegt wird. Standard: "MonitoringDbRole".
- **-PolicyName** - Name einer SQL Server Policy die vor dem Setup deaktiviert und danach wieder aktiviert wird. Wird der Parameter weggelassen, wird keine Policy veraendert.
- **-OutputPath** - Ausgabeverzeichnis fuer das Log. Standard: C:\System\WinSrvLog\MSSQL
- **-SqlCredential** - Optionales PSCredential fuer die SQL Server-Verbindung.
- **-ContinueOnError** - Bei Fehler auf einer Instanz fortfahren statt abbrechen.
- **-EnableException** - Fehler als terminierende Ausnahmen ausloesen.

**Examples (2):**

```powershell
Enable-sqmMonitoringAccess -MonitoringUser "CORP\SvcMonitoring"

```powershell
Enable-sqmMonitoringAccess -ComputerName "SQL01" -MonitoringUser "CORP\SvcMonitoring" `
        -ServerRoleName "MonRole" -DatabaseRoleName "MonDbRole" `
        -PolicyName "Enforce Password Policy" -ContinueOnError

### Invoke-sqmMonitoringKey

Gets or sets monitoring registry values for the sqmSQLTool on one or more computers.

Reads or writes the registry key HKLM:\<RegistryBase>\dtcSoftware\sqmSQLTool on
    the specified computers. The key controls which monitoring components are active:
    SQL monitoring level (None/Standard/Full), SQLFreeSpaceVersion (Standard/Cluster),
    and TSM backup monitoring (0/1).

    When -Operation is 'Set', the specified values are written to the registry.
    The key is created automatically if it does not exist.
    The current values are always read and returned after a write operation.

    Remote access uses Invoke-Command (WinRM). Provide -Credential for remote computers
    if required.

**Parameters:**

- **-ComputerName** - Target computer(s). Pipeline-capable. Default: current computer name.
- **-Operation** - 'Get' (default) reads the current values; 'Set' writes the specified values.
- **-SQL** - SQL monitoring level: 'None', 'Standard', or 'Full'. Stored as DWORD (0/1/2) in the registry.
- **-SQLFreeSpaceVersion** - Free-space monitoring variant: 'Standard' (standalone) or 'Cluster' (AlwaysOn AG).
- **-TSM** - TSM backup monitoring: 0 = inactive, 1 = active.
- **-RegistryBase** - Registry hive path base under HKLM. Default: 'System'.
- **-AutoDetectSQLFreeSpaceVersion** - When set (and -Operation Set), automatically detects whether the instance belongs to an AlwaysOn AG and sets SQLFreeSpaceVersion accordingly (Cluster/Standard).
- **-Credential** - PSCredential for remote computer access.
- **-ContinueOnError** - Continue with the next computer on error.
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).

**Examples (3):**

```powershell
Invoke-sqmMonitoringKey

```powershell
Invoke-sqmMonitoringKey -Operation Set -SQL Standard -TSM 1 -AutoDetectSQLFreeSpaceVersion

```powershell
"SQL01","SQL02" | Invoke-sqmMonitoringKey -Operation Set -SQL Full -TSM 1

### Invoke-sqmPatchAnalysis

Compares the installed SQL Server version with known CU/SP builds.

Reads the installed SQL Server version (ProductVersion) and compares it
    against an embedded reference table of known builds. Indicates whether the
    instance is current, how many builds it lags behind the latest, and provides
    a patch recommendation.

**Parameters:**

- **-SqlInstance** - One or more SQL Server instances. Default: local computer name. Pipeline-capable.
- **-SqlCredential** - PSCredential for the connection.
- **-OutputPath** - If specified, a CSV report is saved.
- **-EnableException** - Throw exceptions immediately.

**Examples (3):**

```powershell
Invoke-sqmPatchAnalysis -SqlInstance "SQL01"

```powershell
"SQL01","SQL02","SQL03" | Invoke-sqmPatchAnalysis

```powershell
Invoke-sqmPatchAnalysis -SqlInstance "SQL01","SQL02" -OutputPath "D:\Reports"

## 20. Script Execution & Deployment

### Invoke-sqmDeployScripts

Executes numbered SQL scripts from a directory sequentially against a SQL Server database.

Runs all SQL script files whose filename starts with a numeric prefix (e.g. 001_CreateTable.sql)
    in ascending numeric order against the specified database. Before execution the function:

    - Validates that ScriptPath and LogPath exist (LogPath is created if missing)
    - Optionally creates a full database backup in a Sonderbackup subdirectory
    - Scans every script for USE DATABASE mismatches and nested BEGIN TRANSACTION statements
    - Wraps all scripts in one outer transaction by default (COMMIT on full success, ROLLBACK on any error)
    - Writes a detailed .log and .csv file to LogPath
    - Returns a result object per script plus an overall summary object

    When -WhatIf is specified the function performs all pre-checks and prints a summary table
    but does not execute any SQL or create any files.

**Parameters:**

- **-SqlInstance** - SQL Server instance name (e.g. "SQLSERVER01" or "SQLSERVER01\INST1").
- **-Database** - Target database name.
- **-ScriptPath** - Directory that contains the numbered SQL script files.
- **-LogPath** - Directory where the .log and .csv output files are written. Created if it does not exist.
- **-JobNumber** - Optional job or order number. When provided it is embedded in the log filename: yyyyMMdd_HHmmss_{JobNumber}_Deploy.log / .csv
- **-QueryTimeout** - Timeout in seconds per script execution. Default: 30.
- **-SkipBackup** - Skip the pre-deployment backup. Requires ShouldProcess confirmation (ConfirmImpact=High). If the user declines the confirmation the function aborts. When -SkipBackup is NOT set and the backup fails the function aborts before running any scripts.
- **-NoWrapTransaction** - Do not wrap all scripts in one outer transaction. Each script is responsible for its own transaction management. Default behavior: all scripts run inside one BEGIN/COMMIT/ROLLBACK block.
- **-SqlCredential** - PSCredential for SQL Server authentication. When omitted Windows Authentication is used.

**Examples (6):**

```powershell
# Basic deploy with automatic backup
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy"

```powershell
# Deploy with job number embedded in log filename
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -JobNumber "AU-2026-042"

```powershell
# Skip backup - requires interactive confirmation
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -SkipBackup

```powershell
# WhatIf dry run - no SQL executed, only pre-checks and summary table
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -WhatIf

```powershell
# No outer transaction - scripts manage their own transactions
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -NoWrapTransaction

```powershell
# SQL Server authentication
    $cred = Get-Credential
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -SqlCredential $cred

### Invoke-sqmSignModule

Signs all PowerShell script files in a module directory using Set-AuthenticodeSignature.

Signs .ps1, .psm1, and .psd1 files (configurable) under a module root directory recursively.
    Works with any code signing certificate: commercial OV cert, self-signed cert, or a
    SignPath-exported PFX file. Designed to be run before each GitHub release.

    Certificate resolution order:
      1. PFX file path  (-CertificatePath)
      2. Thumbprint      (-CertificateThumbprint) - searched in LocalMachine\My, then CurrentUser\My
      3. Auto-detect     - first valid, non-expired code signing cert in both stores

    Each file is checked for an existing signature before signing. Files with a valid
    signature are skipped unless -Force is specified. Files with an invalid or expired
    signature are always re-signed.

    On timestamp server failure the function automatically retries with a fallback TSA.

    Results are returned as a list of PSCustomObjects and copied to the clipboard.

**Parameters:**

- **-ModulePath** - Path to the module root directory. All matching files are signed recursively. If omitted, the parent of $PSScriptRoot is used (auto-detect for module-internal calls).
- **-CertificateThumbprint** - Thumbprint of a certificate in Cert:\LocalMachine\My or Cert:\CurrentUser\My. If omitted and -CertificatePath is also omitted, the function auto-detects a valid code signing certificate from both stores.
- **-CertificatePath** - Path to a .pfx file. Takes precedence over -CertificateThumbprint.
- **-CertificatePassword** - SecureString password for the PFX file specified in -CertificatePath.
- **-TimestampServer** - URL of the timestamp authority (TSA). Default: http://timestamp.digicert.com. On failure the function retries with http://timestamp.sectigo.com as fallback.
- **-IncludeExtensions** - File extensions to sign. Default: @('.ps1', '.psm1', '.psd1').
- **-Force** - Re-signs files that already carry a valid signature. Without -Force those files are skipped.

**Examples (5):**

```powershell
# 1. Sign with a specific certificate from the store
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" `
        -CertificateThumbprint "AB12CD34EF56..."

```powershell
# 2. Sign with a PFX file
    $pwd = ConvertTo-SecureString "secret" -AsPlainText -Force
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" `
        -CertificatePath "C:\Certs\CodeSign.pfx" -CertificatePassword $pwd

```powershell
# 3. Auto-detect certificate (no parameters needed if cert is in store)
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule"

```powershell
# 4. WhatIf dry run - show which files would be signed
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" -WhatIf

```powershell
# 5. Force re-sign all files, even those already signed
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" -Force

### Copy-sqmToCentralPath

Copies one or more files to the configured CentralPath.

If no CentralPath is configured, the function exits without error.
    Source files that do not exist are skipped.

**Parameters:**

- **-Path** - Path(s) of the file(s) to copy.

## 23. Service Broker

### Enable-sqmServiceBroker

Enables Service Broker on a specified database and creates SSB endpoint.

    Performs the following operations:
    1. Sets database to SINGLE_USER mode with ROLLBACK IMMEDIATE (forces user disconnections)
    2. Enables Service Broker (SET ENABLE_BROKER)
    3. Returns database to MULTI_USER mode
    4. Creates SSBEndpoint on port 4022 with WINDOWS authentication (if not exists)
    5. Grants CONNECT permission to PUBLIC

    This function is designed for both single-instance and AlwaysOn configurations.
    For AlwaysOn, the endpoint is created server-wide and applies to all replicas.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-DatabaseName** - Name of the database to enable Service Broker on. Required.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-Force** - Skip confirmation prompt and proceed directly.
- **-OutputPath** - Output directory for log file. Default: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Continue on error (otherwise the error is thrown).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).

**Examples (2):**

```powershell
    Enable-sqmServiceBroker -DatabaseName "OperationsManager"

```powershell
    Enable-sqmServiceBroker -SqlInstance "SQL01" -DatabaseName "OperationsManager" -Force

### Get-sqmServiceBrokerHealth

Creates a health report for SQL Server Service Broker configuration and status.

    Retrieves Service Broker information from a SQL Server instance:
    - Service Broker status (enabled/disabled per database)
    - Endpoints on port 4022 (SSBEndpoint)
    - Queue status and message counts
    - Undeliverable messages in transmission queue
    - Service pairs and their contracts
    - Replica status (if AlwaysOn AG is configured)

    Results are saved as a TXT report in the specified directory.
    The function automatically detects single-instance or AlwaysOn configurations.

**Parameters:**

- **-SqlInstance** - SQL Server instance. Default: current computer name.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-OutputPath** - Output directory for report files. Default: C:\System\WinSrvLog\MSSQL
- **-ContinueOnError** - Continue on error (otherwise the error is thrown).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).

**Examples (2):**

```powershell
    Get-sqmServiceBrokerHealth

```powershell
    Get-sqmServiceBrokerHealth -SqlInstance "SQL01" -OutputPath "D:\Reports"

### Invoke-sqmServiceBrokerAlwaysOn

Enables Service Broker on all nodes of an AlwaysOn Availability Group with automatic failover orchestration.

    Orchestrates the complete workflow to enable Service Broker on all nodes of an AlwaysOn AG.
    Supports two modes:

    MODE 1 (AG with database): Automatic failover orchestration
    1. Identifies the current Primary replica
    2. Iterates through each replica:
       - Fails over to that replica (makes it Primary)
       - Executes Enable-sqmServiceBroker on the new Primary
       - Validates Service Broker status
    3. Fails back to the original Primary

    MODE 2 (Database removed from AG / Broker already enabled): Direct endpoint creation
    - Creates SSBEndpoint on all instances independently
    - No failovers required
    - Useful when: database was removed from AG after Enable-Broker

    This ensures:
    - Service Broker is enabled on ALL databases (via SET ENABLE_BROKER on Primary, replicated to Secondaries)
    - SSBEndpoint exists on EVERY physical server (via CREATE ENDPOINT on each node)
    - Minimal downtime (only brief failovers if AG is present, none if Broker already enabled)

**Parameters:**

- **-SqlInstances** - Array of SQL Server instances (e.g. @("SQL01","SQL02","SQL03")). Must be at least 2 instances. Required.
- **-AvailabilityGroupName** - Name of the Availability Group. Required.
- **-DatabaseName** - Name of the database to enable Service Broker on. Required.
- **-SqlCredential** - Optional PSCredential for the connection.
- **-Force** - Skip confirmation prompt and proceed directly.
- **-OutputPath** - Output directory for log file. Default: C:\System\WinSrvLog\MSSQL
- **-WaitBetweenFailovers** - Wait time (seconds) after each failover to allow health checks. Default: 15 seconds.
- **-ContinueOnError** - Continue on error (otherwise the error is thrown).
- **-EnableException** - Throw exceptions immediately (overrides ContinueOnError).

**Examples (2):**

```powershell
    Invoke-sqmServiceBrokerAlwaysOn -SqlInstances @("SQL01","SQL02","SQL03") -AvailabilityGroupName "MyAG" -DatabaseName "OperationsManager"

```powershell
    Invoke-sqmServiceBrokerAlwaysOn -SqlInstances @("SQL01","SQL02") -AvailabilityGroupName "MyAG" -DatabaseName "MyDB" -Force -WaitBetweenFailovers 20
