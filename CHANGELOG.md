# sqmSQLTool — Changelog

## [1.9.9.0] — 2026-07-12

### Feature: HTML reports for sysadmin/AD audit functions

- Added HTML report output (same shared theme/helper as the previous release) to
  `Get-sqmSysadminAccounts`, `Get-sqmADGroupMembers`, `Get-sqmADGroupMembersRecursive`, and
  `Get-sqmADMemberGroups`. The three AD group functions gained a new `-NoOpen` switch and now use
  `Invoke-sqmOpenReport` for consistency (HTML takes precedence when auto-opening).

## [1.9.8.0] — 2026-07-12

### Feature: HTML reports for management-facing functions

- Added HTML report output (dark "sqmSQLTool" theme via the existing `ConvertTo-sqmHtmlReport`
  helper, status-colored ok/warn/crit cells) to 8 reporting functions that previously only wrote
  TXT/CSV: `Get-sqmBlockingReport`, `Get-sqmDatabaseHealth`, `Get-sqmDistributedAgHealth`,
  `Get-sqmServiceBrokerHealth`, `Get-sqmCertificateReport`, `Export-sqmAlwaysOnConfiguration`,
  `Get-sqmSpnReport`, `Get-sqmDeadlockReport`. `Get-sqmServiceBrokerHealth` and
  `Get-sqmCertificateReport` gained an `-NoOpen` switch and now use the shared
  `Invoke-sqmOpenReport` helper instead of `notepad.exe`/no auto-open, for consistency with the
  rest of the module (HTML takes precedence over TXT when opening).

## [1.9.7.0] — 2026-07-12

### Feature: Find-sqmADUser

- New public function `Find-sqmADUser`: searches Active Directory for user accounts by a
  SamAccountName wildcard pattern (e.g. `so_*` for service accounts). RSAT (`Get-ADUser -Filter`)
  path with automatic LDAP/ADSI fallback when the ActiveDirectory module is unavailable, matching
  the existing dual-path pattern used by `Get-sqmADAccountStatus` and `Get-sqmADGroupMembers`.

## [1.9.6.0] — 2026-07-08

### Docs: translate CHANGELOG history to en-US

- All 49 historical version entries (1.3.0.0 through 1.9.5.0) translated from de-DE to en-US.
  Version numbers, dates, function names, code identifiers and error message text left
  unchanged; only prose translated.

## [1.9.5.0] — 2026-07-08

### Docs: translate comment-based help to en-US

- `Get-sqmDiskBlockSize`, `New-sqmRandomSaPassword`: comment-based help (SYNOPSIS, DESCRIPTION,
  PARAMETER, EXAMPLE, NOTES) translated from de-DE to en-US. No logic changes.

## [1.9.4.0] — 2026-07-08

### Feature: plain-language search in Show-sqmToolGui

Colleagues who can't remember function names can now type a sentence into the search box
instead of a wildcard, e.g. "restore a database" or "disk is full".

- Input without `*`/`?` is scored against name, Synopsis, Description and parameter names of
  every function (a name match is weighted much higher than a match in the body text) and shown
  as a ranked "Best matches" list instead of grouped by category.
- New `Public/nlp-synonyms.ps1`: a small, extensible keyword table for colloquial wording that
  doesn't appear verbatim in the help text (e.g. conjugations like "restoren").
- Plain wildcard/name behaviour is unchanged; nothing is ever run automatically - selecting a
  match feeds into the existing parameter/preview/run flow.

## [1.9.3.0] — 2026-07-03

### Fix: AlwaysOn propagation was missing / not reliable

**Problem reported:** jobs were missing on secondary replicas; `sqm_BackupExclude` changes
(IsActive/Reason, set via `Show-sqmBackupExcludeForm`) never reached the secondaries.

- **Fix `New-sqmOlaUsrDbBackupJob`**: the AlwaysOn job propagation at the end of the function only
  checked `JobStatus -eq 'Created'`. On every subsequent run (job already exists on the primary ->
  `JobStatus = 'Updated'` or `'AlreadyExists'`) the condition became `$false` and propagation to
  the secondaries **stopped entirely** - secondaries permanently lacked the jobs (or any later
  changes, e.g. changed schedules) after the very first run. It now propagates on `'Created'`,
  `'Updated'` AND `'AlreadyExists'` (New-sqmOlaUsrDbBackupJob is idempotent on the secondary via
  `-Update` anyway).
- **Fix `Sync-sqmBackupExcludeTable`**: the AlwaysOn propagation only recursively called
  `Sync-sqmBackupExcludeTable` on each secondary - that only detects NEW/deleted databases
  locally there, but **never** transfers the `IsActive`/`Reason` values set by the admin on the
  primary. The DDL trigger (`Register-sqmBackupExcludeTrigger`) only covers
  CREATE_DATABASE/DROP_DATABASE, also without value propagation. Result: an exclusion decision
  set via the GUI **never** reached the secondaries, not even via the periodic sync job. Fix:
  after the structural reconciliation, the primary's current data is now additionally
  transferred to every secondary via `MERGE` (IsActive/Reason). Verified on DEV02 (MERGE logic
  tested against a mock table: changes correctly applied, new rows inserted, rows not present in
  the primary list left untouched, quote escaping in `Reason` correct). Real AlwaysOn propagation
  itself could not be verified end-to-end on DEV02 (no AG present there).

## [1.9.2.0] — 2026-07-03

### Enhancement

**`Get-sqmSaLogin`** — now exported (previously private)
- Same reason as `Invoke-sqmLogging` (see 1.9.1.0): `sqmPartitionTool`'s job-creation functions
  (`New-sqmPartitionExtendJob`, `New-sqmPartitionRetentionJob`) reuse the same SA login lookup as
  the existing `New-sqmOla*Job` functions instead of duplicating it.

## [1.9.1.0] — 2026-07-03

### Enhancement

**`Invoke-sqmLogging`** — now exported (previously private)
- Reason: the new sibling project `sqmPartitionTool` (a standalone module,
  `RequiredModules = @('dbatools','sqmSQLTool')`) is meant to reuse the established logging
  instead of duplicating it. Private functions aren't visible to other modules even with a
  declared module dependency - `Invoke-sqmLogging` had to be added to `FunctionsToExport` for
  that.
- No behavior change for sqmSQLTool itself; a pure visibility extension for cross-module use.

## [1.9.0.0] — 2026-07-02

### New function

**`Compare-sqmAlwaysOnRoles`** — server role comparison within an AlwaysOn AG
- AlwaysOn only replicates the databases, not `master` - server principals (logins) *and* their
  server role membership (sysadmin, dbcreator, securityadmin, and from SQL Server 2022 also
  custom server roles) are not kept in sync automatically. After a failover, a login on the new
  primary might no longer be sysadmin (or conversely have too many rights) without this having
  been noticed before.
- Diagnostic sibling of `Compare-sqmAlwaysOnLogins` (there: login existence/attributes; here:
  role membership). Same pattern: AG/replica resolution, system login filter,
  `-Login`/`-ExcludeLogin`, `-OnlyDifferences`, TXT/HTML report, `-FailOnDrift` (Windows Event
  Log, source `sqmSQLTool`, EventId **9010** - the first free number, 9001-9009 were already
  taken).
- Status evaluation: Critical if a login is missing on a replica OR `sysadmin` membership
  differs (the highest-privilege role); Warning for any other differing role; OK when the role
  set is identical.
- Database roles are deliberately not part of the comparison (they live inside the replicated
  database, so they're structurally unlikely to diverge).
- Verified on DEV02: role query returns correct data including `is_fixed_role` (SQL Server 2022)
  and an actually present custom server role; the "no AG found" path was cleanly tested (DEV02
  has no AlwaysOn group, so a real multi-replica comparison could not be verified end-to-end).

## [1.8.19.0] — 2026-07-02

### Bugfix (critical)

**jobs/Sync-Job.ps1** — login loss in unattended agent runs due to `-Force`
- In the SQL Agent job, `Sync-Job.ps1` called `Sync-sqmLoginsToAlwaysOn -Force`. For logins that
  already exist, `-Force` causes DROP + CREATE (not ALTER, see 1.8.18.0). If CREATE then fails
  (policy, something transient, AD latency, etc.), the login is gone entirely instead of merely
  not updated - in the unattended agent context Uwe confirmed the actual loss of several logins;
  manual runs without `-Force` went unnoticed.
- Fix: the agent job now calls `-Force:$false` - only logins missing on the secondaries are
  added, existing ones are left untouched (DROP is no longer possible). `-BackupLogins` removed
  (it was only active together with `-Force` anyway, see `if ($BackupLogins -and $Force)` in
  Sync-sqmLoginsToAlwaysOn.ps1).
- Deliberate trade-off: password/attribute drift on already-existing logins is no longer
  propagated by the automatic sync job. For deliberate, manual updates of existing logins,
  `Sync-sqmLoginsToAlwaysOn -Force -BackupLogins` remains available (the function's default for
  `-Force` is unchanged at `$true`; only the agent job was switched).

## [1.8.18.0] — 2026-07-02

### Bugfix

**`Copy-sqmLogins`** — narrowed the policy-disable window to just the actual copy call
- Background: `Sync-sqmLoginsToAlwaysOn` failed in FI-TS environments with "Policy 'New
  Login_Enforce Passwort Policy' has been violated". `Copy-sqmLogins -Force` (default `$true`)
  passes `-Force` through to dbatools' `Copy-DbaLogin`, which does DROP + CREATE instead of ALTER
  for logins that already exist - every sync run therefore triggers a real `CREATE_LOGIN` event,
  which the PBM policy checks.
- The policy used to be disabled right at the very start (before connect, auth-mode check
  including a possible service restart, AD check) and only re-enabled at the very end (after
  orphan repair) - an unnecessarily large window for a security-relevant policy.
- Fix: introduced `_DisablePolicy`/`_EnablePolicy` helper functions and wrapped them tightly
  around the `Copy-DbaLogin` call (disable immediately before, enable in a dedicated `finally`
  immediately after). Connect/auth-mode check/AD check now run BEFORE the disabled window,
  orphan repair AFTER re-enabling. Verified on DEV02: order is now AuthModeCheck -> PolicyDisable
  -> CopyLogin -> RepairOrphanUsers (previously: PolicyDisable first of all).
- No behavior change with `-DisablePolicy $false` or when no `DefaultPolicy` is configured
  (still "Skipped", no disabling).

## [1.8.17.0] — 2026-07-02

### Bugfix

**Docs/_gen-reference.ps1** — mojibake bug when run under Windows PowerShell 5.1
- `Get-Content $file -Raw` (without `-Encoding UTF8`) read `sqmSQLTool-reference.html` (no BOM)
  under PS 5.1 using the system ANSI code page instead of UTF-8. Multi-byte characters (e.g.
  "─", emoji) were thereby decoded incorrectly and permanently corrupted as broken UTF-8
  (mojibake) when written back.
- Fix: added `-Encoding UTF8`. Tested under PS 5.1 and PS 7 - reference.html stays unchanged in
  content on regeneration (143 functions, cards/nav/overview in sync), no more mojibake.
- `sqmSQLTool-reference.html` itself was already up to date (today's docstring changes only
  touched `.DESCRIPTION`/`.PARAMETER`, which this generator doesn't read - only `.SYNOPSIS` and
  `.EXAMPLE` flow into the reference).

## [1.8.16.0] — 2026-07-02

### Docs

**Docs/sqmSQLTool_Anwender-Kurzanleitung.docx** — new end-user guide
- A standalone document for end users of `Show-sqmBackupExcludeForm` (not administrators):
  opening the program, the UI/columns explained, including/excluding a database, "all
  active/inactive", the new length warning from 1.8.14.0, orphaned entries, important notes.
- Screenshot placeholder (dashed border) in the "The interface" section - to be filled in
  manually.

## [1.8.15.0] — 2026-07-02

### Docs

**Docs/sqmSQLTool_Admin-Kurzanleitung.docx** — added a simple version for Part 1
- So far, "Part 1: setting up the backup exclusion list" only described the four manual
  individual steps (sync, permission, GUI, trigger).
- New box "Simple version (recommended, from v1.8.8)" before the detailed instructions: a single
  call `New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Log -UseExcludeTable` handles step 1
  (sync) and step 4 (DDL trigger) automatically. Step 2 (group permission) and step 3 (ongoing
  GUI maintenance) remain separate. The detail heading was updated accordingly to "In detail: the
  four individual steps (manual, optional)".

## [1.8.14.0] — 2026-07-02

### Enhancement

**`Show-sqmBackupExcludeForm`** — warning display for the length of the exclusion list
- New status strip below the toolbar shows live the number of deselected (IsActive=0) databases
  and the resulting character length of the `-DatabaseName` exclusion list.
- Reason: Ola's `DatabaseBackup` outputs `@Databases` as part of a `RAISERROR('%s',...)` line;
  the `%s` parameter is truncated at 2047 characters, which can make subsequent real error
  messages disappear from the job history (see the 1.8.11.0 incident on BLBNBGFATDBA3).
- Yellow warning from 1500 characters, red error display from 1900 characters. Updates on load
  and on every checkbox toggle.

## [1.8.13.0] — 2026-07-02

### Bugfix (critical)

**`New-sqmOlaUsrDbBackupJob`** — IsActive polarity in the exclude query was inverted
- The query fixed in v1.8.11.0 filtered on `e.IsActive = 1` to build exclusions. The actual
  meaning of `IsActive` in `sqm_BackupExclude`: `IsActive=1` means "this database should be
  backed up" (default for newly discovered databases, see `Sync-sqmBackupExcludeTable`),
  `IsActive=0` means "don't back up". So `WHERE IsActive = 1` excluded exactly the databases
  that should be backed up and backed up the ones explicitly deactivated (`IsActive=0`) -
  polarity completely inverted.
- Fix: filter corrected to `e.IsActive = 0`.
- Verified on DEV02: a real FULL run now backs up exactly the 9 databases with `IsActive=1`
  (`AlwaysOnTest, amazon, DeadlockCollector, dtcSN, OperationsManagerDW, pdRessourcen,
  ReportServerTempDB, Solutioninfo, SolutioninfoSTA`) and correctly skipped the 3 with
  `IsActive=0` (`SSISDB, TestDB, ReportServer`).
- `Sync-sqmBackupExcludeTable` (default `IsActive=1` for new databases) was correct from the
  start and did NOT need to be changed - the bug was solely in the read direction of this one
  query.

## [1.8.12.0] — 2026-07-02

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — an explicit `-BackupDirectory` was being overwritten
- Previously, `\Usr-db` was appended to EVERY resolved backup path, even when the caller had
  explicitly passed `-BackupDirectory` as a complete target path. Fix: `\Usr-db` is now only
  appended to automatically resolved paths (registry / `sqlSrv.BackupDirectory` / default); an
  explicitly set `-BackupDirectory` is used unchanged as the target path.
- Verified on DEV02: `-BackupDirectory "C:\Temp\ExplicitTestPath"` results in exactly this path
  without a suffix.

## [1.8.11.0] — 2026-07-02

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — exclude prefix `!` was never valid Ola syntax
- Root cause of a real production incident (BLBNBGFATDBA3, `DatabaseBackup` job failed): the
  `!` prefix for exclusions introduced in v1.8.6.0 (`USER_DATABASES,!db1,!db2`) is never
  evaluated anywhere by Ola Hallengren's `MaintenanceSolution.sql` - it only recognizes `-db1`
  as an exclude marker (`DatabaseItem LIKE '-%'`). All `!` entries were therefore interpreted as
  positive (non-existent) database names: exclusions never took effect, and the resulting long
  "do not exist" warning list blew past the 2047-character limit of `RAISERROR('%s', ...)`,
  which made the actual error message invisible in the job history.
- Fix: prefix corrected to `-`. Additionally added a filter `EXISTS (SELECT 1 FROM
  sys.databases ...)`, so only databases that actually exist on the respective instance are
  added to the exclude list - prevents the "do not exist" list from growing again in a
  `sqm_BackupExclude` table maintained across instances.
- Verified on DEV02: a complete FULL backup run through the newly generated procedure, 0 "do not
  exist" messages, all active exclusions correctly skipped.

## [1.8.10.0] — 2026-07-02

### Bugfix

**`Show-sqmBackupExcludeForm`** — job details in the info panel correct again
- `Load-JobInfo` used to parse `@Databases`, `@Directory` etc. from the step command. After the
  switch to the procedure architecture (v1.8.7) the step only contains
  `EXEC master.dbo.[sqm_Run_...]` - the parameters live in the procedure body.
- Fix: extract the proc name from the step command via regex, then query
  `OBJECT_DEFINITION()` and parse it from there. Falls back to the step command for older jobs
  without a procedure.
- `@Databases` in ExcludeTable mode is now read from the `DECLARE` statement (instead of from
  `@Databases = @Databases` in the EXECUTE call).

## [1.8.9.0] — 2026-07-01

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — fixed three runtime errors
- `CREATE/DROP PROCEDURE master.dbo.[name]` was invalid SQL (database prefix not allowed in DDL
  statements). Fix: prefix removed; `-Database master` on the Invoke-DbaQuery connection sets
  the context correctly.
- `Set-DbaAgentJobStep -StepId` doesn't exist in the dbatools parameter set. Fix: uses
  `-StepName` (backup jobs: `"DatabaseBackup $StepSuffix"`, sync job:
  `'Sync sqm_BackupExclude'`).

## [1.8.8.0] — 2026-07-01

### Enhancements

**`New-sqmOlaUsrDbBackupJob`** — new defaults + auto-setup with -UseExcludeTable
- The default call without -Full/-Diff/-Log now automatically creates FULL + LOG (instead of an
  error). Info message in the log.
- Default FULL: 21:15, EveryDay (previously 20:00 / Sunday).
- Default LOG: every 15 minutes, EveryDay (previously once at 00:00).
- With -UseExcludeTable (primary only): automatically calls Sync-sqmBackupExcludeTable +
  Register-sqmBackupExcludeTrigger. Admin setup is reduced to a single call.

## [1.8.7.0] — 2026-07-01

### Enhancement

**`New-sqmOlaUsrDbBackupJob`** — helper procedure in master instead of inline T-SQL in the job step
- Change: the job step now only contains `EXEC master.dbo.[sqm_Run_{JobName}]`. The actual
  backup code is created as a stored procedure in master. The proc name is derived from the job
  name (special characters → underscore). Result in the Agent window: the job step is readable
  at a glance. The procedure is freshly DROP+CREATE'd on every call (including `-Update`). On
  AlwaysOn propagation, the secondaries also get their own proc.

## [1.8.6.0] — 2026-07-01

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — fixed UseExcludeTable job step SQL
- Fix: the job step used `@ExcludeDatabases` as an Ola parameter - this doesn't exist. Ola's
  `DatabaseBackup` only knows `@Databases` with `!`-prefix syntax for exclusions
  (`USER_DATABASES,!db1,!db2`). Removed dynamic SQL via `sp_executesql`; the step now directly
  builds `@Databases = @Databases + ',' + @Exclusions`.
- Fix: `FOR XML PATH ... .value()` in the agent job step failed with a QUOTED_IDENTIFIER error
  when the session option wasn't set. Added `SET QUOTED_IDENTIFIER ON;` at the start of the step
  SQL.

## [1.8.5.0] — 2026-07-01

### Enhancements

**`New-sqmOlaUsrDbBackupJob`**
- New: parameter `-CreateSyncJob` (`[bool]`, default `$true`).
  When `-UseExcludeTable` is active, a SQL Agent job is automatically created
  (`sqm BackupExclude - SYNC` or `FITS BackupExclude - SYNC` in FI-TS environments). The job runs
  every 30 minutes via a `pwsh` CmdExec step and calls `Sync-sqmBackupExcludeTable -SqlInstance
  '.'`. Ensures `IsActive` changes from `Show-sqmBackupExcludeForm` are propagated to all AG
  secondaries without manual intervention. The job is updated on `-Update`; with
  `-CreateSyncJob $false` it is not created. Job name is derived from the FULL job prefix
  (`FITS *` → FITS, otherwise standard). AG propagation: secondaries also get the sync job
  (recursive call with `CreateSyncJob = $CreateSyncJob` set).

**`New-sqmOlaUsrDbBackupJob`** — fixed a configuration bug (v1.8.4.0)
- Fix: `Set-sqmConfig` previously wrote the entire `$globalConfig` to `config.json`, which meant
  that on FI-TS machines the OlaHH job names from an earlier non-FITS session overwrote the FITS
  names. Fix (A): `Set-sqmConfig` now only saves explicitly passed keys (merge). Fix (B): in
  `sqmSQLTool.psm1`, `config.json` is loaded before the FI-TS block - the FI-TS override always
  wins.

## [1.8.3.0] — 2026-06-29

### Bugfixes & enhancements

**`Sync-sqmLoginsToAlwaysOn`**
- Fix: primary replica detection no longer fails when run on secondary instances.
  `sys.dm_hadr_availability_replica_states.role_desc` returns NULL/RESOLVING when queried from a
  secondary - switched to `sys.dm_hadr_availability_group_states.primary_replica`, which contains
  the current primary on every replica.
- Fix: a `Write-EventLog` error (AccessDenied) leaked to the console because the setter throws a
  non-terminating exception that `catch { }` doesn't catch. Added `-ErrorAction SilentlyContinue`
  (EventId 9002 / 9003).

**`Invoke-sqmCollationChange`**
- Fix: removed a `PropertyAssignmentException` on `ProcessStartInfo.CreateNoNewWindow = $true`.
  The property can't be set when `UseShellExecute` hasn't been evaluated yet. Redundant anyway:
  with `UseShellExecute = $false` + `RedirectStandard* = $true` no console window appears in the
  first place.

**`Get-sqmSQLInstanceCheck`**
- New: check **Instance Collation** (status `Info`) - reports `server.Collation` on every run.
- New: check **Database Collation vs. Instance** (only with `-Detailed`) - lists all user
  databases whose collation differs from the instance collation as `Warning`.

**`Compare-sqmServerConfiguration`**
- New: **Collation (Instance)** is now always output in the report (`Category = "Collation"`),
  not only on a mismatch - important for migration checks.

## [1.8.2.0] — 2026-06-26

### ✨ Temporary sysadmin rights: AD login creation, cleanup & AlwaysOn

Extension of `Grant-sqmTemporarySysadmin` / `Invoke-sqmTempSysadminAction`:

- **Login is created if needed** — if the login is missing, the tool creates it via
  `CREATE LOGIN [DOMAIN\Account] FROM WINDOWS` (instead of aborting as before).
- **AD logins only** — `Grant-sqmTemporarySysadmin` rejects non-Windows logins; the existence
  check is restricted to `type IN ('U','G')` (no SQL/certificate logins).
- **PBM policy handling on creation** — if `DefaultPolicy` is configured, this policy is disabled
  via `Set-sqmSqlPolicyState -State Disable` before creation and re-enabled afterwards
  (controllable via `-DisablePolicy`, default `$true`).
- **A self-created login is removed after expiry** — new switch `-RemoveLogin` in
  `Invoke-sqmTempSysadminAction`: on revocation, `DROP LOGIN`, but as a safety net **only** if the
  login isn't attached to any other fixed server role (other than `public`). Logins that already
  existed before are always kept.
- **AlwaysOn-capable (default)** — if the instance is part of an AG, login creation, sysadmin
  grant, and revocation/cleanup are performed on **all replicas**. Each replica gets its own,
  locally running, self-deleting jobs → failover-robust. Can be disabled via `-PrimaryOnly`;
  individual replicas can be skipped via `-SkipSecondaryServers`.
- `Grant-sqmTemporarySysadmin` now returns **one result object per replica** (including
  `LoginExisted`); new event IDs 9003 (login created), 9004 (drop skipped), 9005 (login removed).

## [1.8.1.0] — 2026-06-26

### ✨ Temporary sysadmin rights with automatic revocation

For patching/installation situations: temporarily make a login **sysadmin**, then automatically
revoke it via a **self-deleting SQL Agent job**.

- **`Grant-sqmTemporarySysadmin`** — grants sysadmin for `-Days` days. Without `-StartDate`
  **immediately** (inline) + a revoke job scheduled for today+X; with `-StartDate` a grant job on
  the start date and a revoke job on start date+X. Optional **`-TicketNumber`** (work order
  number) for the log. `ConfirmImpact='High'` + `-WhatIf`.
- **`Invoke-sqmTempSysadminAction`** — runs `ALTER SERVER ROLE [sysadmin] ADD|DROP MEMBER`, logs
  to the **module log file + Windows Event Log** (source `sqmSQLTool`, including the work order
  number) and **deletes the calling job on success** (`sp_delete_job`). On error the job is kept
  (as failed). Also usable for **manual early revocation**.
- One-time jobs (`sp_add_schedule @freq_type=1`); job steps call the module via
  `Import-Module sqmSQLTool` (module name, no hardcoded path). The revoke job runs under the SQL
  Agent service account.

## [1.8.0.0] — 2026-06-26

### ✨ Source-aware auto-update on import

The auto-update (`AutoUpdate=$true`) now detects a newer version and updates **automatically
from the last-used installation source** - for **all** sources (previously only UNC updated
automatically, PSGallery/GitHub only gave a hint):

- **Source is remembered**: after installation, `Install.ps1` saves the source type + path
  (`Set-sqmConfig -InstallSourceType/-InstallSourcePath`). PSGallery installs are detected at
  runtime via `Get-InstalledModule` (new private `Get-sqmInstallSource`).
- **"Last source, else fallback" logic**: `Test-sqmModuleUpdate` first checks the last source; if
  it's unknown/unreachable, the chain PSGallery→GitHub→UNC applies.
- **Automatic update per source**: `Update-sqmModule` is a dispatcher - PSGallery →
  `Install-Module -Force` (scope automatically AllUsers/CurrentUser), GitHub → download + unpack
  release ZIP (new `Update-sqmFromGitHub`), UNC/LocalDir → file copy with backup (shared
  `Copy-sqmModuleFiles`).
- **Throttle**: the on-import check runs at most every `UpdateCheckIntervalHours` (default 24)
  via a marker file - no network calls on every import. Can still be skipped via
  `SQMSQLTOOL_SKIP_AUTO_UPDATE=1`.
- Robust: an update error (e.g. AllUsers without admin rights) **never** aborts the import.
- New config keys: `InstallSourceType`, `InstallSourcePath`, `UpdateCheckIntervalHours`.

## [1.7.9.0] — 2026-06-26

### ✨ Get-sqmADGroupMembersRecursive — real display name

- For **user accounts**, the real AD attribute **`displayName`** is now resolved (via
  `Get-ADUser`), instead of only showing the CN/name from `Get-ADGroupMember` (which for many
  accounts matches the login). The `DisplayName` column now shows the person's name. Fallback
  chain: `displayName` → CN/Name → `sAMAccountName`.
- **Hardened the LDAP fallback path:** if the `displayName` attribute was missing, `InvokeGet`
  threw an exception and the member was lost. Now reads tolerantly with the same fallback chain.

## [1.7.8.1] — 2026-06-25

### 🔧 Installer — secure the dbatools dependency

- **`Install.ps1`** now ensures the mandatory **`dbatools`** dependency **in the same scope**
  before the import test runs. Previously the installer assumed dbatools was already present →
  on a **fresh server without dbatools** the import test failed. With `-Scope AllUsers`,
  dbatools is installed system-wide (no more scope mismatch where an AllUsers module can't find a
  dbatools that only lives in CurrentUser in other/admin sessions). If dbatools is missing, it is
  installed from the PSGallery (TLS 1.2 + NuGet provider are set along with it).

## [1.7.8.0] — 2026-06-25

### 🐛 Critical fix — TrustServerCertificate never took effect (module-wide)

- **`sqmSQLTool.psm1`**: the call
  `Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true -Scope Session` used the
  parameter **`-Scope`, which `Set-DbatoolsConfig` (dbatools 2.8.x) doesn't have**. The resulting
  exception was silently swallowed by the surrounding `catch` (only Write-Verbose), so
  `sql.connection.trustcert` was **never set**. Consequence: against **SQL Server 2022 over
  TCP**, virtually **every** dbatools connection failed with "The certificate chain was issued by
  an authority that is not trusted". Fix: removed `-Scope Session` (the setting applies
  session-wide anyway).

### 🐛 Fixes — Get-sqmServerUtilization (verified live against SQL 2022)

- The file was saved without a UTF-8 BOM/CRLF → PS 5.1 misread box/special characters (parse
  error). Now BOM+CRLF.
- Invalid format interpolation `$($x:N0)` → `.ToString('N0')`.
- Fixed DMV queries: `COUNT(*) FILTER(...)` (PostgreSQL) → `SUM(CASE...)`; ring-buffer CPU via
  **XML** (`record.value(...)`) instead of `JSON_VALUE`; memory snapshot as a single result set
  (CROSS JOIN).
- Single-row DMV result: `$result[0].Column` grabbed the first *column* of a DataRow instead of
  the row (→ 0 values). Now `@($result)[0]` + `ISNULL(...)` in SQL against DBNull.

## [1.7.7.0] — 2026-06-25

### ✨ New / enhancement — Invoke-sqmTsmConfiguration

TSM configuration can now represent real environments where INCLUDE/EXCLUDE is offloaded to a
separate file (INCLEXCL, e.g. `ie_dsm.opt`):

- **`-UseInclExclFile`**: resolves the `INCLEXCL` option from `dsm.opt` and writes the managed
  block into the referenced include/exclude file instead of `dsm.opt`.
- **`-InclExclPath`**: specify the target file explicitly (created if needed).
- **`-ExcludePatterns`**: custom EXCLUDE patterns instead of the fixed three SQL types.
- **`-IncludeRule`** (`@{ Path=...; ManagementClass=... }`): a dedicated management class per
  path (e.g. 365 days for a `01Year` directory).
- **Loosened ManagementClass validation**: `ValidateSet` → `ValidatePattern '^MC_[A-Za-z0-9._]+$'`.
  Classes actually in use like `MC_B_2.2_15.15.NA_IMG` or `MC_B_NL_NL_365.365.NA` are no longer
  rejected. **Backward-compatible**: previously valid calls remain valid.
- Result object extended with **`TargetFile`** (the file actually written).

### 🔧 Note

If a `dsm.opt`/ie file is under the control of a vendor TSM configurator, that tool may overwrite
the managed block - re-run if needed.

## [1.7.6.0] — 2026-06-25

### ✨ New

- **Get-sqmServerUtilization**: new reporting function for CPU/RAM utilization trends. Collects
  data from SQL Server DMVs across multiple points in time (default 6 snapshots of 10 seconds =
  1 minute): CPU %, memory usage, worker threads, compilations. Computes Min/Max/Avg per metric
  and generates reports (TXT/CSV/HTML). Parameters: `-SampleCount` (default 6),
  `-SampleIntervalSeconds` (default 10).

## [1.7.2.0] — 2026-06-22

### 🔧 Fixes

- **Show-sqmToolGui**: for ShouldProcess-capable commands, the "WhatIf (simulation)" checkbox
  was **pre-checked** (`Checked = $true`/`$supportsWhatIf`). This caused "Run" on exactly these
  commands to run unintentionally as a pure simulation instead of executing for real. The
  checkbox is now **disabled by default** (opt-in): "Run" executes for real, simulation must be
  checked deliberately.

## [1.7.1.0] — 2026-06-22

### ✨ New

- **Get-sqmDiskSpaceReport — bootstrap from backup history (method B2)**: new switch
  `-SeedFromBackupHistory`. As long as the snapshot history (B1) for a volume still has fewer
  than `-MinDataPoints` points, a growth rate is instead derived from `msdb.dbo.backupset`: per
  database, the data growth trend from the full-backup sizes (linear regression, from 3 points),
  distributed across volumes proportionally to data-file size. Bridges B1's ~5-run ramp-up time.
  Flagged with `ForecastBasis='BackupHistory'`, confidence `Low` (report column `Boot`). Once B1
  has enough snapshots, B1 takes over again. Only applies when the switch is set; requires read
  access to `msdb.dbo.backupset`.

## [1.7.0.0] — 2026-06-22

### ✨ New

- **Get-sqmDiskSpaceReport — growth forecast rebuilt on snapshot history (method B1)**: the
  forecast previously relied exclusively on AutoGrow events from the default trace and stayed
  empty whenever there were no automatic file-growth events in the time window (well-sized DBs)
  or the short default-trace retention had already evicted the events. Instead, on every run the
  volume usage is now written to a JSON history (`History\DiskHistory_<Instance>.json`) and
  evaluated over the last `-HistoryDays` days via **linear regression (least squares)**: `GB/day`,
  `DaysUntilFull`, and a confidence level (R²/point count: Low/Medium/High).
  - Measures the **actual consumption trend** (including data growth in pre-sized files) and is
    **mount-point-safe** (evaluated per `volume_mount_point`).
  - Before `-MinDataPoints` runs (default 5), the volume is transparently reported as "forecast
    still collecting data (n of m)" instead of silently `n/a`.
  - New parameters: `-HistoryPath`, `-MinDataPoints`, `-NoHistory`. New output fields:
    `DataPoints`, `ForecastConfidence`, `ForecastBasis`. Report columns: `GB/day`, `DaysFull`,
    `Conf`.
  - `-WhatIf` does not persist the history.
  - Note: for reliable forecasts, schedule the function regularly (e.g. a daily agent job).

## [1.6.4.0] — 2026-06-22

### 🔧 Fixes — invalid DMV columns (found via live run + static DMV validation against SQL 2022)

- **Get-sqmMissingIndexes**: the join referenced `mid.index_group_handle`, which doesn't exist in
  `sys.dm_db_missing_index_details` (only `index_handle`). The query returned "Invalid column
  name index_group_handle" → no results. Join fixed to
  `mid.index_handle = mig.index_handle`.
- **Get-sqmOperationStatus**: the AutoSeed query used the non-existent columns
  `total_size_bytes`, `start_time` and `estimated_completion_time_ms` from
  `sys.dm_hadr_physical_seeding_stats`. Corrected to the real columns `database_size_bytes`,
  `start_time_utc` and `estimate_time_complete_utc` (remaining time via `DATEDIFF` in ms), mapped
  by alias to the expected names.
- **Get-sqmAlwaysOnFailoverHistory**: an optional SQL addition read `ars.role_start_time`, which
  doesn't exist in `sys.dm_hadr_availability_replica_states`. Replaced with the valid column
  `current_configuration_commit_start_time_utc` (a UTC approximation; the Event Log, EventID
  1480, remains authoritative). Added UTC comparison and NULL protection.

## [1.6.3.0] — 2026-06-22

### 🔧 Fixes — dbatools parameter/cmdlet drift (found via static audit against dbatools 2.8.1, validated against local SQL 2022)

Mechanical parameter fixes:
- **Invoke-sqmRestoreDatabase**: `Get-DbaDefaultPath -Type Backup` → `(Get-DbaDefaultPath …).Backup`
  (`-Type` doesn't exist; affected the `-BackupBeforeRestore` path).
- **Test-sqmBackupIntegrity**: `Restore-DbaDatabase -FileListOnly` → `Read-DbaBackupHeader -FileList`
  (Restore-DbaDatabase has no `-FileListOnly`; the verify path already correctly used
  `-VerifyOnly`).
- **New-sqmBackupMaintenanceJob / New-sqmOlaMaintenanceJobs / New-sqmOlaSysDbBackupJob /
  New-sqmOlaUsrDbBackupJob**: `Set-DbaAgentJob -OperatorToEmail` → `-EmailOperator`.
- **Invoke-sqmDeployScripts**: `Connect-DbaInstance -EnableException` → `-ErrorAction Stop`
  (Connect-DbaInstance has no `-EnableException`).

Redesigns (cmdlet doesn't exist at all):
- **Invoke-sqmUpdateStatistics**: used `Update-DbaDbStatistic` - this cmdlet doesn't exist, so the
  function had no effect. Reimplemented via `Invoke-DbaQuery` with a real `UPDATE STATISTICS`;
  target statistics are determined server-side from `sys.stats`/`sys.dm_db_stats_properties`, so
  `-OnlyModified`, `-Index`, `-Table`, `-Statistics` and `-SamplePercent` (FULLSCAN/SAMPLE) now
  take effect.
- **Invoke-sqmConfigRollback**: `Set-DbaService -StartMode` doesn't exist. dbatools'
  `Get-DbaService` returns CIM instances of the `SqlService` class; the StartMode is now set via
  their CIM method `SetStartMode(UInt32)` (Automatic=2, Manual=3, Disabled=4). Works under PS 5.1
  and 7.
- **Sync-sqmLoginsToAlwaysOn**: `Get-DbaAgentServiceAccount` doesn't exist. The agent service
  account now comes from `sys.dm_server_services` (locale-robust `LIKE '%Agent%'`) via the
  existing SQL connection.

## [1.6.2.0] — 2026-06-22

### 🔧 Fixes

- **Invoke-sqmRestoreDatabase**: several dbatools parameters didn't match the installed version
  and aborted the real run:
  - `Export-DbaUser -Force` → `-Force` doesn't exist; now uses `-FilePath` (full path) without
    `-Force`. (Fixes "A parameter cannot be found that matches parameter name 'Force'".)
  - `Restore-DbaDatabase -NewDatabaseName/-DatabaseFilePath/-LogFilePath` → these parameters
    don't exist. The (possibly new) target name now goes through `-DatabaseName`
    (`$finalDbName`); the physical file names/paths are handled by the already-built
    `-FileMapping`. Renaming + moving is thereby version-stable.
  - User-export filename: `$DatabaseName_` was interpreted as an (empty) variable, so the DB name
    was missing from the name; now `${DatabaseName}` and a correct timestamp format.
- **Invoke-sqmRestoreDatabase**: fixed duplicate result rows on early returns (WhatIf/error). The
  `return $results` in the `process` block are now plain `return`; the `end` block returns the
  list exactly once.

## [1.6.1.0] — 2026-06-22

### 🔧 Fixes

- **Invoke-sqmRestoreDatabase**: aborted with "A parameter cannot be found that matches parameter
  name 'Database'" when the target database already existed. Caused by
  `Get-DbaAvailabilityGroup -Database` (this parameter doesn't exist; the parameter-binding error
  is terminating and isn't caught by `-ErrorAction SilentlyContinue`). AG membership is now
  checked via `Get-DbaAgDatabase`, and the AG object is reloaded via the AG name.
- **Invoke-sqmLogging**: the caller's `-WhatIf` leaked via `$WhatIfPreference` into the internal
  `Out-File`/`New-Item` calls and produced "What if: Output to File" noise while no log was
  written at all. Both calls now run with `-WhatIf:$false` (logging is a side channel and must
  not be subject to ShouldProcess).

## [1.6.0.0] — 2026-06-21

### ✨ New

- **Invoke-sqmNtfsSetup**: sets NTFS permissions for the SQL service accounts on the
  Data/Log/TempDB/Backup directories. Determines service accounts (Get-DbaService) and
  directories (Get-DbaDefaultPath + sys.master_files) automatically, writes an ACL backup (SDDL
  per directory) beforehand, supports `-WhatIf`/`-EnableException`. Closes the call in
  SQLSetupTool\Modules\PostInstall.psm1 that previously had no target.
- **Show-sqmToolGui**: a small WinForms interface (Visual Studio Dark) with all exported
  functions grouped by category; generates parameter inputs automatically (including a
  credential picker for PSCredential and dropdowns for ValidateSet/Enum), command preview,
  run/copy/help.

### 🔧 Fixes / maintenance

- **category-map.ps1** regenerated (was encoding-corrupt and incomplete); now covers all
  exported functions.
- **CI**: GitHub Actions workflow (PSScriptAnalyzer, BOM check, import PS 5.1 + 7, Pester).
- **Tests**: a contract test that freezes the function API used by SQLSetupTool.

## [1.5.1.0] — 2026-06-10

Version bump past the (misnamed) tag v1.5.0, so the accumulated fixes 1.4.8 - 1.4.15 are
unambiguously the newest version on GitHub and get picked up by the update mechanism. Content
identical to 1.4.15.0 (see entries below); no new function code.

## [1.4.15.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob / New-sqmAutoLoginCompareJob**: `-Overwrite` failed with "A parameter
  cannot be found that matches parameter name 'Force'". `Remove-DbaAgentJob -Force` doesn't exist
  in every dbatools version; now uses `-Confirm:$false` (version-stable, as in all other job
  functions).

## [1.4.14.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginCompareJob**: the same schedule errors as before with the sync job
  ("SqlInstance is specified more than once", `ActiveStartTimeOfDay`, version-dependent
  `New-DbaAgentSchedule` parameters, duplicate schedules). The schedule is now created via native
  msdb procedures (`sp_add_schedule` / `sp_attach_schedule`); duplicates removed beforehand by
  `schedule_id`.

### ♻️ Simplification

- **New-sqmAutoLoginCompareJob**: the job step is now two lines - `Import-Module` plus
  `Compare-sqmAlwaysOnLogins -FailOnDrift`. No hashtable, no paths, no server name.
- **Compare-sqmAlwaysOnLogins**: new switch `-FailOnDrift`. On login drift (Warning/Critical),
  Windows Event 9001 (Splunk) is written and an exception is thrown, so the SQL Agent job turns
  red (drift alarm via the OnFailure operator). Implies `-NoOpen`; the report is written
  beforehand.

### 🌐 Other

- **Default output language switched to `en-US`** (module config `Language` + Get-sqmString
  fallback). Affects all strings localized via Get-sqmString. Note: reports that are still
  hardcoded German remain German until the multi-language migration is complete.

## [1.4.13.0] — 2026-06-10

### ♻️ Simplification

- **Sync-sqmLoginsToAlwaysOn** now runs sensibly with no arguments at all: `Force`,
  `BackupLogins` (each $true) and `BackupRetentionDays` (7) are defaults. A bare
  `Sync-sqmLoginsToAlwaysOn` keeps the secondaries fully in sync (SqlInstance = computer name, AG
  = the first one found, paths from the settings). Opt out via `-Force:$false` /
  `-BackupLogins:$false`.
- **New-sqmAutoLoginSyncJob**: the job step is now just two lines - `Import-Module` plus the
  parameterless call `Sync-sqmLoginsToAlwaysOn`. No hashtable, no paths, no server name, no AG in
  the step.

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob**: "There are two or more schedules named …" - multiple schedules
  with the same name (from earlier failed attempts) are now removed by `schedule_id` in a loop
  before creating a new one, instead of via an ambiguous `@schedule_name`.
- **Sync-sqmLoginsToAlwaysOn**: reports failures via the Windows Event Log (source 'sqmSQLTool',
  EventId 9002) for Splunk - the lean job step no longer needs its own throw for that.

## [1.4.12.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob**: schedule creation failed in a version-dependent way on
  `New-DbaAgentSchedule` ("A parameter cannot be found that matches parameter name 'Force'", "…
  'sch_…' is not a valid value for the Schedule variable"). This cmdlet's parameters vary by
  dbatools version. The schedule is now created via native msdb procedures (`sp_add_schedule` /
  `sp_attach_schedule`) through `Invoke-DbaQuery` - equally stable across every SQL Server and
  dbatools version, no more API guessing.

## [1.4.11.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob**: job creation failed with "A parameter cannot be found that
  matches parameter name 'ActiveStartTimeOfDay'". `ActiveStartTimeOfDay` is an SMO property, not
  a `New-DbaAgentSchedule` parameter. The schedule now correctly uses `-StartTime` (format
  `HHMMSS`), `-FrequencyRecurrenceFactor` for Weekly/Monthly, and
  `-FrequencySubdayType Hours` / `-FrequencySubdayInterval` for hourly.

## [1.4.10.0] — 2026-06-10

### 🔧 Fixes

- **Copy-sqmLogins / AlwaysOn login sync**: a renamed `sa` wasn't recognized. Caused by an
  ordering bug - the dynamic sysadmin detection ran before `$srcConnParams` was defined, failed
  silently, and fell back to the literal `'sa'`. This allowed an `sa` renamed on one node to end
  up in the copy batch (SID collision 0x01 on the target).
  - ConnParams/credentials are now built BEFORE the detection.
  - `sa` is now additionally identified via the well-known SID `0x01` (name-independent) and is
    fundamentally never copied - not even with `-IncludeSystemLogins`.
  - The sysadmin query in Copy-sqmLogins and Sync-sqmLoginsToAlwaysOn was extended with
    `OR sid = 0x01`.

## [1.4.9.0] — 2026-06-10

### 🔧 Fixes

- **Get-sqmBlockingReport**: `most_recent_sql_handle` correctly read from
  `sys.dm_exec_connections` instead of `sys.dm_exec_sessions` (error "Invalid column name
  'most_recent_sql_handle'").
- **New-sqmAutoLoginSyncJob**: `SqlInstance` was bound twice when creating the schedule (error
  "parameter 'SqlInstance' is specified more than once") - now only explicitly once.

### ♻️ Refactoring

- **New-sqmAutoLoginSyncJob**: the job step was drastically simplified. Instead of ~60 lines of
  baked-in orchestration, now a lean direct call to `Sync-sqmLoginsToAlwaysOn`; on error `throw`
  → SQL Agent marks the job as failed (operator notification). No more hardcoded paths in the
  step.
- **Sync-sqmLoginsToAlwaysOn**: now handles retention (`-BackupRetentionDays`) and the AD orphan
  audit (`-AuditAdOrphans`, detection-only, Event Log 9003). `-BackupPath` uses the configured
  output path (`Get-sqmDefaultOutputPath`) instead of a fixed literal - all paths come from the
  settings.

## [1.4.8.0] — 2026-06-10

### ✨ New features

#### Remove-sqmAdOrphanLogin
Manual, safe removal of Windows logins whose AD account no longer exists ("dead" AD logins).
Deliberately manual only, not for unattended operation.
- ActiveDirectory module required (default `-AdModuleAction Abort`); no deletion without AD
- System logins and all sysadmin logins are always excluded; DB-owner logins are skipped
- Only treated as orphaned on a positive AD "not present" result; AD query errors → skip
- A rollback script (CREATE LOGIN FROM WINDOWS + server roles) is generated before the drop
- `ConfirmImpact = High`: `-WhatIf` / `-Confirm` apply

#### New-sqmAutoLoginSyncJob — new options
- `-Force` and `-BackupLogins` active by default: the running job keeps the secondaries fully in
  sync (password/language/default-DB drift), with a rollback backup. Opt out via `-Force:$false`
  / `-BackupLogins:$false`
- `-BackupRetentionDays` (default 7): cleans up backups, sync logs and audit reports
- `-AuditAdOrphans`: reports orphaned Windows logins after every run (sync log + Event Log
  EventId 9003 for Splunk) - detection only, no auto-delete

### 🔧 Fixes

- **Login backup query**: `password_hash` read from `sys.sql_logins` instead of
  `sys.server_principals` (error "Invalid column name 'password_hash'" with `-BackupLogins`)
- **Sync-sqmLoginsToAlwaysOn**: AG lookup now sorts by `name` instead of the non-existent column
  `creation_date`
- **Install.cmd / Update.cmd**: under GPO `RemoteSigned`, always stage locally first (removing
  Mark-of-the-Web), so execution from a UNC/`\\tsclient\` path is not blocked

## [1.4.0.0] — 2026-05-31

### ✨ New features

#### Get-sqmServerHardwareReport
Comprehensive HTML hardware report for local and remote systems:
- **RAM information**: total, available, DIMM details (manufacturer, size)
- **CPU details**: model, socket, core count, clock speed
- **Drives**: physical drives with logical partitions and utilization bars
- **VM detection**: Hyper-V, VMware, VirtualBox, KVM
- **System info**: network, operating system, SQL Server instances
- **Remote support**: CIM/WMI-based, opens the report automatically in the browser

### 🔧 Improvements

#### IntelliSense fix (PowerShell ISE / VS Code)
- `FunctionsToExport` in `sqmSQLTool.psd1` switched from the wildcard pattern `*-sqm*` to an
  explicit list of all 103 functions
- All functions now show up immediately in the IDE after `Import-Module sqmSQLTool`
- Faster IntelliSense performance

#### Code signing setup
- SignPath.io integration prepared (self-signed certificate + workflow)
- Application submitted for the SignPath.org Community plan

#### 4 new Reveal.js presentations
Interactive presentations at www.powershelldba.de/Praesentation/:
- **Performance & Diagnostics** (13 slides)
- **Security & Compliance** (12 slides)
- **Database Health & Best Practices** (12 slides)
- **Integration & External Systems** (12 slides)

---

## [1.3.0.0] — 2026-04-30

(Earlier versions not documented)
