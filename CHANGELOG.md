# sqmSQLTool — Changelog

## [1.9.129.0] — 2026-09-05

### New: `Show-sqmWhoIsActiveMonitor` — live grid view for `Get-sqmWhoIsActive`

`Get-sqmWhoIsActive`'s own repeat loop only prints a console table and writes
CSV/HTML at the end - not useful while actually watching a server live in the GUI.
`Show-sqmWhoIsActiveMonitor` is a WinForms dialog that shows the current snapshot in
a `DataGridView` and refreshes it automatically every N seconds ("Start"/"Stop", with
an adjustable interval and the same `ShowSleepingSpids` filter). Blocked sessions are
highlighted in red, sessions running/idle 30s+ in yellow - same severity classes as
the HTML report.

"Stop" (or closing the window mid-run) writes a report for that run exactly like
`Get-sqmWhoIsActive` does: the CSV contains every iteration, the HTML report only the
last snapshot - a long-running live session must not turn into a multi-thousand-row
HTML dump.

Refactored the query and report-writing logic that used to live inline in
`Get-sqmWhoIsActive` into two private helpers (`Get-sqmWhoIsActiveSnapshot`,
`Export-sqmWhoIsActiveReport`) so both the CLI/Agent-job function and this new GUI
monitor use the identical DMV query and HTML/CSV format - `Get-sqmWhoIsActive`'s own
behavior/output is unchanged.

## [1.9.128.0] — 2026-09-04

### `Get-sqmWaitStatistics` — tooltips explaining what each wait type means

The HTML report's WaitType column now carries a hover tooltip explaining what the wait
type actually is - independent of the existing threshold-based `Recommendation` column,
which only judges whether the current value is a problem. Backed by a new `WaitDef_*`
glossary in both language resource files, covering all 25 categorized wait types plus
7 common ones that had no category/recommendation entry (`OLEDB`, `BACKUPBUFFER`,
`BACKUPIO`, `BACKUPTHREAD`, `MSQL_XP`, `BUFFERPOOL_SCAN`,
`WAIT_ON_SYNC_STATISTICS_REFRESH`); any other wait type falls back to a generic
"see Microsoft/SQLskills docs" tooltip instead of showing nothing. The definition is
also returned as a new `Definition` property on the result objects (and therefore in
the CSV export). Switched the HTML body from `ConvertTo-Html -Fragment` to a hand-built
table, since a tooltip needs a `title` attribute `ConvertTo-Html` has no way to add.

Live-verified against DEV01: categorized types (`CXSYNC_PORT`, `WRITELOG`, ...) show
their specific explanation, uncategorized ones (`PREEMPTIVE_OS_QUERYREGISTRY`,
`LOGBUFFER`, ...) fall back cleanly, and the generated HTML properly encodes
apostrophes inside the `title` attribute.

## [1.9.127.0] — 2026-09-04

### New: `Get-sqmWhoIsActive` — sp_whoisactive-style live session monitor, repeatable

Shows currently active/blocked sessions (SPID, login/host/program, database, status,
blocking SPID, wait info, elapsed time, CPU/reads/writes, tempdb allocation, running
SQL statement) similar to Adam Machanic's `sp_whoisactive`, built entirely from DMVs
(`sys.dm_exec_sessions`/`dm_exec_requests`/`dm_exec_sql_text`/`dm_db_session_space_usage`)
so no stored procedure needs to be installed on the target instance.

`-ShowSleepingSpids` mirrors `sp_whoisactive`'s `@show_sleeping_spids` (0 = active only,
1 = active + open transactions [default], 2 = all user sessions). New relative to
`sp_whoisactive` itself: `-RepeatIntervalSeconds`/`-RepeatCount`/`-DurationMinutes` turn
it into a refreshing live monitor (client-side loop, since the stored proc has no
built-in repeat), printing a table per snapshot and collecting every snapshot into one
CSV plus an HTML report of the last snapshot at the end - including when a long-running
loop is cancelled with Ctrl+C.

## [1.9.126.0] — 2026-09-03

### New: `Repair-sqmSsasSerializeError` — fixes the known SSAS "ASDatabase::Serialize" internal error

Addresses a documented SSAS bug (Microsoft Q&A 1350375): deploying an XMLA `<Create>`/`<Alter>`
script fails with `Internal error: An unexpected error occurred (file 'pcserialize.cpp', line
1535, function 'ASDatabase::Serialize')`, most commonly reported on instances that are part of
an Always On Availability Group. The confirmed fix is removing the undocumented
`<Gen2ServerKey>` element from `msmdsrv.ini` and restarting the SSAS service.

Uses the same instance/config-file discovery as `Get-`/`Set-sqmSsasDeploymentMode` (Windows
service command line `-s` switch, XML load with whitespace preserved to keep the diff minimal).
Idempotent - a second run reports `NotPresent` instead of re-touching the file. Backs up
`msmdsrv.ini` before writing, supports `-WhatIf`/`-Confirm`, and takes `-RestartService` to
apply the fix immediately instead of leaving it for the next manual restart.

Not live-tested against DEV01 - the lab has no SSAS instance installed. Verified only by
reading the XML structure `Set-sqmSsasDeploymentMode` already parses successfully in production.

## [1.9.115.0] — 2026-08-30

### New: `Register-sqmAuditSession` — Extended Events session for the login/database/metadata audit gap

Creates (if missing) and starts a dedicated Extended Events session covering the categories
a previous blog post on SQL Server auditing methods flagged as a gap: `-FailedLogins`,
`-SuccessfulLogins`, `-DatabaseCreated`, `-DatabaseDropped`, `-MetadataChanges` (schema-level
DDL), each independently selectable, plus `-All`. No new reader was written - every event
collects the same standard actions (`database_name`, `username`, `sql_text`, etc.)
`Invoke-sqmExtendedEvents -Read` already knows how to surface.

Every predicate was verified live against DEV01 rather than assumed, and two assumptions
turned out to be wrong:

- `sys.dm_xe_objects` actually has dedicated `database_created`/`database_dropped` events
  (the auditing blog post claimed no such clean event exists for CREATE/DROP DATABASE - that
  claim was incorrect and needs fixing in the article).
- `object_created`/`object_altered`/`object_deleted` fire twice per statement (start and
  commit/rollback) - filtered to `ddl_phase = 1` (commit) so nothing is double-counted.
- Live-verified that scoping `-DatabaseCreated`/`-DatabaseDropped` to a specific database name
  via a WHERE predicate does **not** work - neither the collected `database_name` action (it
  reflects the connecting session's existing context, not the database being created/dropped)
  nor a direct reference to the event's own field produces a working filter; both were tried
  and both silently matched nothing. These two categories are always instance-wide by design,
  not by omission, and the function warns if `-TargetDatabase` is supplied without
  `-MetadataChanges` (the one category scoping actually works for, confirmed live: an
  unrelated database's DDL was not captured when scoped).
- `-MetadataChanges` excludes temp objects (`#...`) and SQL Server's own auto-generated
  statistics objects (`_WA_Sys_...`) by default (`-IncludeSystemGeneratedObjects` to capture
  them anyway) - both showed up as pure noise in live testing, including from dbatools' own
  connection-housekeeping temp tables.

Live-verified end to end against DEV01: idempotency (`-All` twice reports `Created` then
`Unchanged`, no session recreation), a failed login, a successful login, `CREATE DATABASE`,
scoped `CREATE`/`ALTER`/`DROP TABLE`, an out-of-scope table correctly excluded, and
`DROP DATABASE`, all correctly captured and read back via `Invoke-sqmExtendedEvents -Read`.

## [1.9.114.0] — 2026-08-30

### New: `Get-sqmErrorLog` — read and categorize the SQL Server error log with ready-made filters

Wraps dbatools' `Get-DbaErrorLog` and adds what it does not provide on its own: switches for the
event types that come up in almost every troubleshooting session instead of everyone re-inventing
the same `-match` pattern - `-FailedLogins`, `-SuccessfulLogins`, `-Logins` (both), `-Backups`,
`-Restores`, `-Errors` (internal `Error: n, Severity: n, State: n.` entries), `-Shutdowns`,
`-Startups`, `-CorruptionEvents`, `-IOErrors`, `-MemoryPressure`, `-ServiceBrokerEvents`, plus
`-Database`, `-Since`/`-Before`, `-LogNumber` (current log and/or archives), `-Top`, and a
freeform `-Pattern` that combines with any other filter or works standalone.

Login detection (`-FailedLogins`/`-SuccessfulLogins`) is language-neutral: the message templates
for 18456/18453/18454 are read from `sys.messages` on the target instance and turned into regular
expressions, the same approach `Get-sqmLoginLastAccess` already uses, so a non-English instance is
matched correctly instead of only ever finding the English wording. The remaining categories match
well-known English message text; the module does not guess localized strings it can't verify, and
`-Pattern` is the documented escape hatch for anything else or for a localized instance.

Every matched entry is returned with a `Category` label even with no filter applied, and exports
to CSV/HTML like the other reporting functions (`-OutputPath`, `-NoOpen`, `Copy-sqmToCentralPath`).

## [1.9.113.0] — 2026-08-29

### Fix: `Get-sqmDeadlockReport` silently found 0 deadlocks even when they existed

Confirmed on a machine where the (independently proven) `DeadlockCollector` T-SQL solution listed
deadlocks from `system_health` but `Get-sqmDeadlockReport` reported none. The ring-buffer query
pulled back the whole `<event>` element (`xdr.query('.')`) and PowerShell then tried to navigate to
the deadlock node via `$dlXml.event.'data'.value.'deadlock'` - if `<event>` has more than one
`<data>` child (as `xml_deadlock_report` can), `$dlXml.event.'data'` becomes an array instead of a
single element and the property chase silently returns nothing (no error, no exception - just 0
results). `DeadlockCollector` never had this problem because it extracts the `<deadlock>` node
*inside T-SQL* via a relative XQuery (`xdr.query('(data/value/deadlock)[1]')`) instead of leaving
the navigation to PowerShell's XML object model. `Get-sqmDeadlockReport` now does the same -
queries for `(data/value/deadlock)[1]` directly, so `$dl.DeadlockGraph` is already the `<deadlock>`
node and no further PowerShell-side navigation is needed.

## [1.9.112.0] — 2026-08-29

### Fix: GUI crashed picking a folder/file for `-OutputPath` or a `Files` parameter

`Show-sqmToolGui`'s Browse... buttons (OpenFileDialog/SaveFileDialog/FolderBrowserDialog) set the
textbox's `.Text` and then explicitly called `& $updatePreview` right after. `.Text` already fires
`Add_TextChanged($updatePreview)`, so `$updatePreview` was invoked twice within the same
click-handler call stack; that reentrant re-invocation of the same scriptblock (captured as a raw
.NET event handler) corrupted it, and the next `& $updatePreview` failed with "The expression after
'&' in a pipeline element produced an object that was not valid. It must result in a command name,
a script block, or a CommandInfo object." Removed the redundant explicit calls - the TextChanged
handler already covers it.

## [1.9.111.0] — 2026-08-28

### Fix: `MasterDbObjectWhitelist` default was missing `CommandLog`

Ola Hallengren's maintenance solution creates a `CommandLog` table in master by default (not just
the four stored procedures) - left off the default whitelist added in 1.9.110.0. Added, so a
standard Ola install doesn't get its own logging table flagged/dropped out of the box.

## [1.9.110.0] — 2026-08-28

### New: `Get-sqmMasterDbCustomObjects` / `Remove-sqmMasterDbCustomObjects` — clean up objects accidentally created in master

Users occasionally create tables, views, procedures, or functions directly in `master` by
accident (wrong database selected in SSMS, a script run without `USE`). Unlike a user database,
`master` has no natural owner for "this shouldn't be here."

`Get-sqmMasterDbCustomObjects` reads `sys.objects` in master for tables/views/procedures/functions
(`U`/`V`/`P`/`PC`/`FN`/`IF`/`TF`/`FS`/`FT`), excludes genuine Microsoft-shipped objects
(`is_ms_shipped`) and anything matching the new `MasterDbObjectWhitelist` module configuration
(wildcards allowed), and reports the rest as a TXT/CSV/HTML report.

`Remove-sqmMasterDbCustomObjects` drops what it finds - re-detects live per instance (not from a
possibly stale pipeline object), issues the correct `DROP TABLE`/`DROP VIEW`/`DROP PROCEDURE`/
`DROP FUNCTION` per object type, each wrapped in its own try/catch. Full `-WhatIf`/`-Confirm`
support (`ConfirmImpact = 'High'`), CSV changelog. There is no per-call bypass of the whitelist -
edit the configuration first if an object should be exempt.

New config key `MasterDbObjectWhitelist` (`Get-sqmConfig -Key 'MasterDbObjectWhitelist'` /
`Set-sqmConfig -MasterDbObjectWhitelist @(...)`), defaulting to the standard maintenance-script
family: `sp_Blitz`, `sp_BlitzBackups`, `sp_BlitzCache`, `sp_BlitzFirst`, `sp_BlitzIndex`,
`sp_BlitzLock`, `sp_BlitzWho`, `CommandExecute`, `DatabaseBackup`, `DatabaseIntegrityCheck`,
`IndexOptimize`, `sp_WhoIsActive`, `sp_BackRestRemain`.

Live-verified end to end against DEV01: created a table/view/procedure/function directly in
master, confirmed all four were detected and correctly typed, confirmed `-WhatIf` changed
nothing, confirmed targeted removal by `-ObjectName` and bulk removal both worked, confirmed a
final scan came back clean, and confirmed whitelisted names are never flagged.

## [1.9.109.0] — 2026-08-28

### Change: every per-database report now shows TRUSTWORTHY and isolation level

New shared private helper `Get-sqmDatabaseTrustIsolationMap` (`Private\Invoke-sqmHelpers.ps1`) reads
`is_trustworthy_on`, `is_read_committed_snapshot_on`, and `snapshot_isolation_state_desc` from
`sys.databases` for an entire instance in one query, and derives a single readable `IsolationLevel`
string (`READ_COMMITTED_SNAPSHOT`, `READ_COMMITTED (SNAPSHOT allowed)`, `READ_COMMITTED (default)`,
or both combined). Built as a dedicated raw-SQL query rather than trusting dbatools' `Get-DbaDatabase`
SMO object: `.Trustworthy` is reliably populated, but `.ReadCommittedSnapshot` comes back `$null` on a
standard `Get-DbaDatabase` call (SMO does not eager-load it) - confirmed live on DEV01, where a naive
`$db.ReadCommittedSnapshot` read would have silently reported every database as RCSI-off regardless of
the real setting.

Wired into every function that reports one row per database: `Get-sqmDbOwnerRisk` (new `IsolationLevel`
column, `TrustworthyOn` already existed), `Get-sqmDatabaseHealth`, `Export-sqmDatabaseDocumentation`,
`Invoke-sqmInstanceInventory`, `Invoke-sqmSetupReport`, `Export-sqmServerConfiguration` (new
`IsolationLevel`, `Trustworthy` already existed), and `Compare-sqmServerConfiguration -CompareDatabases`
(now also flags Trustworthy drift as `Critical` and isolation-level drift as `Warning` between source
and target). Live-verified end to end against DEV01's 22 databases for all seven functions.

## [1.9.108.0] — 2026-08-28

### New: `Get-sqmDbOwnerRisk` / `Repair-sqmDbOwnerRisk` — db_owner privilege-escalation audit and fix

db_owner is functionally equivalent to CONTROL on the database: members can create triggers and
procedures with `EXECUTE AS OWNER`, which run as the database owner (`dbo`), not the caller. If a
database has `TRUSTWORTHY = ON` and its owner maps to a sysadmin-privileged login (common, since
databases are usually created by an admin/setup account), any db_owner member can escalate to full
instance control via a single `CREATE PROCEDURE ... WITH EXECUTE AS OWNER`.

`Get-sqmDbOwnerRisk` finds, per database, any non-dbo db_owner members and whether that escalation
path is actually open (`TRUSTWORTHY` + sysadmin owner), and writes a TXT/CSV/HTML report - green
rows for databases with no unexpected db_owner members, red rows for the rest (Warning if just the
membership is wrong, Critical if the full escalation path is open).

`Repair-sqmDbOwnerRisk` fixes what it finds: removes the offending db_owner membership, adds
`db_datareader` + `db_datawriter`, creates a custom `db_execute` role (`CREATE ROLE ... AUTHORIZATION
dbo`) if it doesn't exist yet, grants that role `EXECUTE` on every user stored procedure in the
database (skipped if there are none), and adds the login to it. Accepts `Get-sqmDbOwnerRisk`'s
pipeline output directly. Full `-WhatIf`/`-Confirm` support (`ConfirmImpact = 'High'`), per-member
error isolation so one failing login doesn't stop the rest, and a CSV changelog per instance.

Background: [db_owner Risks: Trigger Creation, Ownership Chaining, and the Path to sysadmin](https://www.powershelldba.de/blog/articles/db-owner-privilege-escalation-risks.html)

## [1.9.107.0] — 2026-08-27

### New: `Get-sqmAlwaysOnQueueStatus` — pollable redo/send queue status, no report files

`Get-sqmAlwaysOnHealthReport` already reads redo queue / send queue per replica and database via
`sys.dm_hadr_database_replica_states`, but it always writes TXT/CSV/HTML report files on every
call - wrong shape for something called every few minutes by a poller (SQLLiveDiagnose central
poller in particular). The DMV query and threshold/status scoring (redo/send MB conversion,
`OverallStatus` OK/Warning/Critical) moved into a new private helper,
`Get-sqmAlwaysOnQueueSnapshot`, shared by both functions - `Get-sqmAlwaysOnHealthReport`'s own
behavior (AutoSeed tracking, TXT/CSV/HTML writing, thresholds) is unchanged, it just sources its
per-row data from the helper now instead of an inline query. `Get-sqmAlwaysOnQueueStatus` is the
new lightweight sibling: same `-SqlInstance/-SqlCredential/-MaxRedoQueueMB/-MaxSendQueueMB`
parameters, returns the row objects directly, no file I/O. An instance without any availability
groups returns an empty array, not an error.

## [1.9.106.0] — 2026-08-25

### Fix: `Get-sqmADGroupMembers` did not resolve real AD display names

Brought the non-recursive `Get-sqmADGroupMembers` in line with `Get-sqmADGroupMembersRecursive`,
which already resolved this correctly. Method 1 (`Get-ADGroupMember`) only returns the CN/Name
(often just the login), not the `displayName` attribute - user members now get their real
`displayName` loaded via `Get-ADUser -Properties DisplayName`. Method 2 (LDAP fallback) had a
latent bug: `sAMAccountName` and `displayName` were read via `InvokeGet` inside the same `try`,
so a group member whose AD object simply has no `displayName` attribute threw before the already-read
`sAMAccountName` was ever applied, silently falling back to the CN for both fields. Each attribute
is now read individually and tolerantly, with the same `displayName -> cn -> sAMAccountName`
fallback chain used elsewhere in the module.

## [1.9.105.0] — 2026-08-25

### New: `Unlock-sqmSqlLogin` — unlock a CHECK_POLICY-locked SQL login

Covers the two standard cases for a SQL-auth login locked out by repeated bad-password
attempts under `CHECK_POLICY = ON`: unlock without knowing/touching the current password
(known or unknown password, caller just wants back in), or a real password reset when the
password is genuinely lost. T-SQL has no standalone `ALTER LOGIN ... UNLOCK` - `UNLOCK`
only works combined with `PASSWORD =`. Without `-NewPassword` the function instead uses
the documented `CHECK_POLICY = OFF` / `= ON` toggle, which clears the Windows-managed
lockout flag without touching the password hash at all. Neither path restates
`CHECK_POLICY`/`CHECK_EXPIRATION` in the `ALTER LOGIN` statement, so SQL Server leaves
both exactly as they were; the function verifies that via `sys.sql_logins` afterward
instead of trusting "no exception = nothing changed". `-NewPassword` (SecureString) does
a real `PASSWORD = @newpwd UNLOCK` reset, passed as a query parameter and never logged;
`-MustChange` requires `CHECK_EXPIRATION = ON` on the login and fails fast with a clear
message otherwise instead of surfacing SQL Server's raw error. Already-unlocked logins are
a no-op (`Status = 'AlreadyUnlocked'`).

## [1.9.104.0] — 2026-08-24

### Discoverability: `Set-sqmSqlDirectoryPermissions` alias for `Invoke-sqmNtfsSetup`

A request to "add a function that sets permissions for SQL Server and SQL Agent on the
directories used by SQL Server" turned out to already exist as `Invoke-sqmNtfsSetup`
(auto-discovers the Engine/Agent service accounts via `Get-DbaService` and the Data/Log/
Backup/TempDB directories via `Get-DbaDefaultPath` + `sys.master_files`, backs up the ACLs
first, then grants FullControl/Modify). It just wasn't found because the `Invoke-*` verb and
"NtfsSetup" name give no hint that it's a permissions function. Added `Set-sqmSqlDirectoryPermissions`
as an alias (`Set-Alias` at the end of `Public\Invoke-sqmNtfsSetup.ps1`, registered in
`AliasesToExport`) so it surfaces under `Get-Command -Noun *Permission*` without touching the
existing function name, exports, docs, or any Agent job/script that already calls it by its
original name.

## [1.9.103.0] — 2026-08-23

### Fix: `Get-sqmWaitStatistics` silently swallowed SQL login/connection failures in the GUI

Bug report: `Show-sqmToolGui` crashed with "Cannot index into a null array" while testing
`Get-sqmWaitStatistics` against a SQL-authenticated login (`gui-launch.log`, three occurrences
within one session). Reproduced the SQL-login path headlessly (`$form.Show()` + `$btnRun.PerformClick()`
instead of `ShowDialog()`, so the Run button's real Click handler runs without blocking on a
modal dialog) with both a valid and an invalid DEV01 credential. The invalid-credential case
never threw a null-array error, but it did surface a real, separate, and reproducible bug:
`Invoke-DbaQuery @connParams -Database master -Query $waitSql -ErrorAction Stop` does not
actually throw on a failed login - dbatools just `Write-Warning`s and returns `$null` unless
`-EnableException` is passed - so the failed-login case fell through to the "instance returned
zero waits" path and the GUI showed "(No result / no output)" with no indication the login had
failed at all. Fixed by adding `-EnableException:$true` to that call, matching the pattern
already used for the connectivity-check query in `Get-sqmAlwaysOnHealthReport` /
`Get-sqmDistributedAgHealth`. Also extended `Show-sqmToolGui`'s connection-error detection
regex to recognize German SQL Server error text (e.g. "Fehler bei der Anmeldung") - the
existing patterns were English-only, so a German-locale instance's login failure fell through
to the generic `ERROR: ...` line instead of the clearer "SQL CONNECTION FAILED" message.

Could not reproduce the literal null-array crash itself despite testing successful login,
failed login (wrong password), and the default local-instance prefill combined with a
mismatched credential - none of those hit it. Hardened the two array-index sites in the
Run button's own mandatory-parameter validation (`$missing[0]` / `$paramSets[$i]`, the only
places in that handler that index by integer rather than by hashtable key) against a `$null`
array defensively, since a crash there would bypass the handler's own try/catch entirely (it
only wraps the actual command invocation, not the validation step before it) and reach the
top-level unhandled-exception handler with no script context. Also enhanced that top-level
handler in `Start-sqmToolGui.ps1` to log `$e.Exception.ErrorRecord.InvocationInfo.PositionMessage`
in addition to the bare `.StackTrace` - the interpreter-frame stack trace alone carries no file
or line number, which is why the original crash log couldn't be traced back to a cause. If this
recurs, `gui-launch.log` will now show the exact line.

## [1.9.102.0] — 2026-08-21

### GUI: Datei-/Ordnerauswahl und Ergebnis-Kopie in `Show-sqmToolGui`

Drei Verbesserungen an der Parameter-Erfassung der GUI:

1. Parameter, deren Name auf `File`/`Files` endet (z. B. `-BackupFile`/`-BackupFiles`
   bei `Invoke-sqmRestoreDatabase`), bekommen jetzt einen "Browse..."-Button, der einen
   `OpenFileDialog` oeffnet statt den Pfad von Hand eintippen zu muessen. Bei
   Array-Parametern ist Mehrfachauswahl aktiv; die gewaehlten Dateien werden genauso
   Komma-separiert in die Textbox geschrieben, wie sie das bestehende Splitting in
   `$buildCommand`/Run bereits erwartet.
2. `-OutputPath` wird jetzt mit demselben Standardverzeichnis vorbelegt, das die
   jeweilige Funktion sonst intern verwenden wuerde (`Get-sqmDefaultOutputPath`
   dahinter). Da dieser Default in praktisch allen betroffenen Funktionen ein Aufruf
   eines *privaten*, nicht exportierten Modul-Helfers ist, reicht ein einfaches
   `InvokeScript()` im GUI-Runspace nicht - der aus dem Funktions-AST extrahierte
   Default-Ausdruck wird deshalb per `$cmd.Module.NewBoundScriptBlock()` im
   Session-State des Moduls selbst ausgewertet (live an vier realen Varianten
   verifiziert: `Get-sqmWaitStatistics`, `Get-sqmAgentJobHistory`,
   `Enable-sqmMonitoringAccess`, `Install-sqmSsrsReportServer`). Der zugehoerige
   "Browse..."-Button oeffnet einen `FolderBrowserDialog` fuer Verzeichnis-Defaults,
   bzw. einen `SaveFileDialog`, wenn der Default (wie bei `Get-sqmAgentJobHistory`)
   bereits ein vollstaendiger Dateiname mit Endung ist.
3. Ueber dem Output-Feld sitzt jetzt ein "Copy output"-Button, der das Ergebnis der
   zuletzt ausgefuehrten Funktion in die Zwischenablage kopiert - bisher liess sich nur
   der Befehl selbst kopieren, nicht das Resultat.

Die neue AST-/Default-Auswertungslogik wurde gegen das echte, importierte Modul
getestet (vier Funktionen, alle vier `OutputPath`-Varianten liefern den korrekten
Pfad). Das WinForms-Layout selbst (Button-Platzierung, Zeilenbreite) liess sich in
dieser Umgebung nicht interaktiv per Klick verifizieren, da `ShowDialog()` blockiert
und kein Desktop-Screenshot-Werkzeug zur Verfuegung steht - rein per Code-Review gegen
das bestehende Layout-Muster abgesichert.

## [1.9.101.0] — 2026-08-18

### Neu: `Get-sqmBlockingHistory` + `Register-sqmBlockedProcessMonitor` - vergangene Blocking-Vorfaelle

Gemeldet: `Get-sqmBlockingReport` zeigt nur Blocking im Moment des Aufrufs, keine
zurueckliegenden Waits. Neue Funktion `Get-sqmBlockingHistory` liest dafuer
`blocked_process_report`-Events aus Extended-Events-Ring-Buffern (SPID, Login, Host,
Programm, Lock-Modus, Wait-Resource, Wartezeit, Statement-Ausschnitt je Vorfall).

**Zwei Design-Annahmen live widerlegt, bevor der finale Stand stand:**

1. Die eingebaute `system_health`-Session enthaelt `blocked_process_report` **nicht**
   zuverlaessig - auf einer Standardinstallation (DEV01) fehlt das Event komplett in der
   Session-Definition (`sys.server_event_session_events` gepruef). Ohne lauschendes Ziel
   verpuffen die Events, selbst bei aktiviertem `blocked process threshold (s)`. Neue
   Funktion `Register-sqmBlockedProcessMonitor` legt daher bei Bedarf eine eigene,
   dauerhafte Session `sqm_BlockedProcessMonitor` an (`blocked_process_report` +
   `xml_deadlock_report`, `ring_buffer`-Target, optional `-IncludeFileTarget` fuer
   laengere Aufbewahrung via `event_file`). `Get-sqmBlockingHistory` ruft das automatisch
   auf (`-SkipMonitorSetup` zum Abschalten) und liest zusaetzlich weiterhin
   `system_health` mit, falls das dort ausnahmsweise doch vorhanden ist.
2. Der Konfigurationsname ist tatsaechlich `'blocked process threshold (s)'` (mit
   Einheiten-Suffix) - `sp_configure`/`sys.configurations` kennen kein
   `'blocked process threshold'` ohne Suffix. Mit einem echten, live via zwei
   Hintergrund-Connections erzeugten Blocking-Vorfall verifiziert.
3. **Der eigentliche Auslieferungsbug:** `.value()` auf ein zuvor per `.query()`
   materialisiertes XML-Zwischenergebnis lieferte fuer jede Spalte `DBNull` - trotz
   nachweislich vollstaendiger Roh-XML. Live an einem echten, ~12 Sekunden gehaltenen
   Blocking-Vorfall auf DEV01 gefunden (`BlockedWaitMs`-Division warf
   `System.DBNull does not contain a method named 'op_Division'`). Fix: der komplette
   XPath laeuft jetzt in einem Zug direkt gegen die Ereignisspalte statt ueber eine
   Zwischenspalte - danach lieferten alle drei erzeugten Testereignisse exakt die
   erwarteten Werte (SPIDs, Wartezeiten 3.5/9.6/12.6s, Statements, Lock-Modus).
   Zusaetzlich gehaertet: `Invoke-DbaQuery` liefert SQL NULL als `[DBNull]`, nicht als
   PowerShell `$null` - reine Truthy-Pruefungen erkennen das nicht.

Alle Testartefakte (Testdatenbank, temporaere Monitor-Session, Threshold/Advanced-Options)
nach jedem Testlauf von DEV01 entfernt, Ausgangszustand wiederhergestellt.

## [1.9.100.0] — 2026-08-18

### Bugfix: `Sync-sqmBackupExcludeTable` — AG-Propagierung konnte die Primary ueberschreiben

Gemeldet: sind Aenderungen an `sqm_BackupExclude` zuverlaessig auf allen AG-Secondaries? Antwort
bis zu diesem Fix: nein, nicht ganz. Die Propagierung nutzte `sys.availability_replicas WHERE
replica_server_name <> @@SERVERNAME` - das listet nur "alle anderen Knoten", ohne Rollenbezug.
Der 30-Minuten-Sync-Job laeuft auf **allen** AG-Knoten, auch Secondaries. Feuert eine Secondary's
Zyklus zufaellig vor dem naechsten Zyklus der Primary, pusht die Secondary ihren eigenen, noch
veralteten Stand per MERGE auf die Primary - und macht damit eine gerade erst per
`Show-sqmBackupExcludeForm` gemachte Aenderung rueckgaengig, ohne dass es auffaellt. Passt zum
beobachteten Muster mehrfach hin- und her-getoggelter `IsActive`-Werte auf BLBNBGFATDBA3.

Fix: vor jeder Propagierung wird jetzt geprueft, ob die aktuelle Instanz tatsaechlich die
AG-Primary ist (`sys.dm_hadr_availability_group_states.primary_replica = @@SERVERNAME`) - exakt
dieselbe Technik wie der Primary-Fix in `Sync-sqmLoginsToAlwaysOn` (v1.8.3.0). Ist die Instanz
nicht Primary, wird die Propagierung fuer diesen Lauf komplett uebersprungen (keine Secondary
pusht mehr ungefragt ihren eigenen Stand nach aussen).

Gegen DEV01 verifiziert: neue Pruefquery laeuft fehlerfrei (liefert korrekt `IsPrimary=0` auf
dieser Nicht-AG-Instanz), `Sync-sqmBackupExcludeTable` laeuft weiterhin fehlerfrei end-to-end.
Das eigentliche Verhindern-Szenario (Secondary ueberschreibt Primary) konnte im Lab nicht in
einer echten Mehrknoten-AG nachgestellt werden - DEV01 hat kein AlwaysOn.

## [1.9.99.0] — 2026-08-18

### Architekturänderung: `New-sqmOlaUsrDbBackupJob -UseExcludeTable` — Cursor statt einer langen Ausschlussliste

Gemeldet: die bisherige Umsetzung baut eine einzige `'-DatabaseName,-DatabaseName,...'`-Liste
und haengt sie an Olas `@Databases`-Parameter an. Auf Instanzen mit vielen Ausschluessen
(Praxisfall: ~90 Zeilen in `sqm_BackupExclude`) wird diese Liste unpraktikabel lang.

Die generierte Prozedur (`sqm_Run_<Jobname>`) cursort jetzt einzeln durch jede
Kandidaten-Datenbank (aufgeloest aus `-Databases`: `USER_DATABASES`, `ALL_DATABASES` oder eine
explizite kommagetrennte Liste via `STRING_SPLIT`) und prueft pro Datenbank direkt gegen
`master.dbo.sqm_BackupExclude` (`IsActive = 0 AND IsOrphaned = 0` = uebersprungen). Nur
nicht-ausgeschlossene Datenbanken werden einzeln per `EXECUTE master.dbo.DatabaseBackup
@Databases = @dbName, ...` gesichert - es wird nie eine lange Liste zusammengebaut. Fehlt die
Tabelle (`OBJECT_ID(...) IS NULL`), wird jede Kandidaten-Datenbank gesichert.

`Show-sqmBackupExcludeForm`: die Warnzeile zur Laenge der Exclusion-Liste (Schwellwerte 1500/1900
Zeichen, RAISERROR-2047-Warnung) ist damit hinfaellig und wurde entfernt (`Update-
ExclusionLengthIndicator`, `$pWarn`-Panel).

Live gegen DEV01 verifiziert: generierte Prozedur (FULL + LOG) kompiliert und wird korrekt als
SQL-Agent-Job angelegt; isolierter Logik-Test (Stub statt echtem `DatabaseBackup`) mit einer
temporaer auf `IsActive=0` gesetzten Testdatenbank (`AdventureWorks`) bestaetigt: von 18
Kandidaten-Datenbanken wurden korrekt 17 "gesichert", die ausgeschlossene fehlt im Ergebnis.
Alle Testartefakte (Jobs, Prozeduren, Stub, Testtabelle) nach dem Test entfernt, Ausgangszustand
wiederhergestellt.

## [1.9.98.0] — 2026-08-18

### Bugfix (kritisch): `Invoke-sqmUserDatabaseBackup -UseExcludeTable` hatte die IsActive-Polaritaet invertiert

`master.dbo.sqm_BackupExclude` wird von zwei Funktionen gelesen: `New-sqmOlaUsrDbBackupJob`
(produktiver Standard, Ola-Hallengren-basiert) interpretiert `IsActive=1` korrekt als "diese
Datenbank wird gesichert" (Default fuer neu von `Sync-sqmBackupExcludeTable` erkannte
Datenbanken; seit v1.8.13.0 so verifiziert) und schliesst nur bei `IsActive=0 AND
IsOrphaned=0` aus. `Invoke-sqmUserDatabaseBackup -UseExcludeTable` filterte bislang jedoch auf
`IsActive = 1 AND IsOrphaned = 0` - also genau umgekehrt.

Praktische Folge: unter `Invoke-sqmUserDatabaseBackup -UseExcludeTable` wurde jede neu
erkannte Datenbank ab dem ersten `Sync-sqmBackupExcludeTable`-Lauf automatisch vom Backup
ausgeschlossen (Default-Wert `IsActive=1`), bis ein Admin die Checkbox in
`Show-sqmBackupExcludeForm` manuell umschaltet - ein stiller Datenverlust-Risikofall bei
gemischtem Einsatz beider Backup-Funktionen gegen dieselbe Tabelle.

Fix: Query auf `WHERE IsActive = 0 AND IsOrphaned = 0` korrigiert, Log-Meldungen und
Doku-Kommentare an die jetzt uebereinstimmende Semantik beider Funktionen angepasst. Das
GUI-Label "Aktiv (Backup)" in `Show-sqmBackupExcludeForm` war bereits korrekt und wurde nicht
veraendert.

## [1.9.97.0] — 2026-08-18

### Neu: `Get-sqmDatabaseHealth` zeigt Backup-Ausschluss (sqm_BackupExclude)

Gemeldet: eine Datenbank ohne (aktuelles) Backup im Health-Report ist im Report nicht von einer
Datenbank zu unterscheiden, die absichtlich ueber `master.dbo.sqm_BackupExclude` vom Backup
ausgenommen ist (siehe `New-sqmOlaUsrDbBackupJob` / `Invoke-sqmUserDatabaseBackup
-UseExcludeTable`). Neue Spalte "Backup-Ausschluss" im HTML-Bericht ("Ausgeschlossen (<Grund>)"
wenn gesetzt), neue Properties `ExcludedFromBackup`/`ExcludeReason` je Datenbank im
Rueckgabeobjekt/CSV, sowie eine Zusammenfassungszeile im TXT-Bericht.

Semantik: `IsActive = 0 AND IsOrphaned = 0` = ausgeschlossen (`IsActive=1` heisst "wird
gesichert", Default fuer neu erkannte Datenbanken) - deckungsgleich mit der Beschriftung "Aktiv
(Backup)" in `Show-sqmBackupExcludeForm` sowie mit `New-sqmOlaUsrDbBackupJob`. Fehlt die
Tabelle, werden keine Ausschluesse angenommen.

*Korrektur 1.9.98.0: die urspruengliche Fassung dieser Funktion (und dieses Eintrags) hatte die
Polaritaet fuer 1.9.97.0 fehlerhaft von `Invoke-sqmUserDatabaseBackup` uebernommen, dessen
Query selbst invertiert war - siehe oben.*

`OverallStatus` bleibt unveraendert - Backup-Aktualitaet fliesst schon bisher nicht in die
Bewertung ein (separate, bereits bestehende Luecke, hier nicht mit angefasst). Mit gemockten
dbatools-Daten via Pester verifiziert (3 neue Tests: Flag+Grund gesetzt, unbeteiligte DB bleibt
unmarkiert, HTML enthaelt Spalte+Text).

## [1.9.96.0] — 2026-08-18

### Neu: `Get-sqmDatabaseSpaceReport` - Fuellstand der Datenbankdateien (Data + Log)

Bisher gab es keinen Report fuer den tatsaechlichen Fuellstand einer Datenbank (belegte Datenseiten
vs. allokierte Dateigroesse) - nur benachbarte, aber andere Kennzahlen: `Get-sqmDiskSpaceReport`
(freier Platz auf dem Windows-Laufwerk) und `Get-sqmAutoGrowthReport` (allokierte Dateigroesse +
Autogrowth-Konfiguration). Neue Funktion liest pro Datenbank Data- und Log-Dateien getrennt aus,
aggregiert je Datenbank zu einem Fuellstand in % und markiert `Warning`/`Critical` ab konfigurierbaren
Schwellwerten (`-WarnThresholdPct` 80 / `-CriticalThresholdPct` 90, Default). CSV (Datei-Detail) +
HTML (Datenbank-Zusammenfassung, farbcodiert) im etablierten Report-Format, Default-`-OutputPath`
nach demselben Muster wie die uebrigen Reports (`Get-sqmDefaultOutputPath` + `DatabaseSpaceReport`).

Aufbauend auf dbatools' `Get-DbaDbSpace`. Fallstrick beim Bau entdeckt: `Get-DbaDbSpace`s eigener
`-IncludeSystemDBs`-Switch ist in der hier installierten dbatools-Version (2.8.4) deprecated und
bricht mit `Stop-Function` ab, ohne etwas zurueckzugeben - `-IncludeSystemDatabases` steuert die
System-DB-Aufnahme deshalb ueber `-ExcludeDatabase` (master/model/msdb/tempdb), nicht ueber den
kaputten Switch. Mit gemockten dbatools-Daten via Pester verifiziert (8 Tests: Schwellwert-Logik,
Critical-/OK-Einstufung, CSV/HTML-Erzeugung inkl. Default-Pfad).

## [1.9.95.0] — 2026-08-18

### Fix: sechs weitere Funktionen ohne Default-Wert fuer `-OutputPath`

Vollstaendige Durchsicht aller oeffentlichen Funktionen mit `-OutputPath`-Parameter nach den
Einzelfixes fuer `Get-sqmBlockingReport` (v1.9.93.0) und `Get-sqmDeadlockReport` (v1.9.94.0): 23
Funktionen hatten einen unbedingten `[string]$OutputPath,`-Parameter ohne Default. 17 davon waren
bereits korrekt (Default schon im `begin`-Block gesetzt, z. B. `Invoke-sqmPerfBaseline`,
`Get-sqmCertificateReport`, `Invoke-sqmRestoreTest`) oder haben `-OutputPath` bewusst anders belegt
(`Export-sqmDatabaseSettings`/`Export-sqmDatabaseLogins`: Mandatory, da Kennwort-Hashes/Settings
ohne explizites Ziel nicht exportiert werden sollen; `Set-sqmConfig`: setzt den Konfigurationswert
selbst, kein Report-Pfad). Sechs Funktionen fehlte der Default tatsaechlich - Fix nach dem
etablierten Muster `(Join-Path (Get-sqmDefaultOutputPath) '<Unterordner>')`:
- `Get-sqmLoginLastAccess` → `...\LoginLastAccess`
- `Get-sqmLoginPermissions` → `...\LoginPermissions`
- `Get-sqmTempDbRecommendation` → `...\TempDbRecommendation`
- `Get-sqmIndexFragmentation` → `...\IndexFragmentation`
- `Invoke-sqmPatchAnalysis` → `...\PatchAnalysis`
- `Get-sqmAgentJobHistory` → Sonderfall: `-OutputPath` ist dort ein kompletter Dateipfad (nicht
  Verzeichnis), Default ist deshalb ein vollstaendiger, zeitgestempelter Dateiname unter
  `...\AgentJobHistory`; Schreiblogik legt das uebergeordnete Verzeichnis jetzt bei Bedarf an.

Alle sechs mit gemockten dbatools-Daten via Pester verifiziert: CSV/HTML landen jetzt ohne
explizites `-OutputPath` im Default-Ordner.

## [1.9.94.0] — 2026-08-18

### Fix: `Get-sqmDeadlockReport` hatte keinen Default-Wert fuer `-OutputPath`

Gleicher Fehler wie eben bei `Get-sqmBlockingReport` (siehe dort): ohne explizites `-OutputPath`
wurden nie XDL-Graphen oder ein HTML-Summary geschrieben. Fix nach demselben Muster
`(Join-Path (Get-sqmDefaultOutputPath) 'DeadlockReport')`. Anmerkung: mindestens 23 weitere
oeffentliche Funktionen haben denselben unbedingten `[string]$OutputPath,`-Parameter ohne
Default - noch nicht angefasst, da nicht angefragt.

## [1.9.93.0] — 2026-08-18

### Fix: `Get-sqmBlockingReport` hatte keinen Default-Wert fuer `-OutputPath`

Wie schon bei den fuenf Batch-B3-Funktionen in v1.9.80.0 (siehe dort) fehlte `-OutputPath` ein
Standardwert - ohne explizite Angabe wurde nie ein CSV/HTML-Report geschrieben. Fix nach dem
etablierten Muster `(Join-Path (Get-sqmDefaultOutputPath) 'BlockingReport')`. Die bestehende
Bedingung `-and $blockedSessions.Count -gt 0` bleibt unveraendert (analog `Get-sqmMissingIndexes`:
bewusst kein leerer Report, wenn keine Blockierung vorliegt).

## [1.9.92.0] — 2026-08-17

### Neu: `Invoke-sqmSplunkConfiguration` - Modus `Remove` zum Rueckbau der Splunk-Konfiguration

Bisher konnte die Funktion die Splunk-Konfiguration nur einrichten (`Set`) oder pruefen (`Test`),
aber nicht wieder entfernen. Neuer Modus `Remove`: loescht alle `MSSQLn_Log`-Umgebungsvariablen
(unabhaengig von noch vorhandenen SQL-Instanzen, da beim Ausbau/Deinstallieren einer Instanz die
Registry-Eintraege bereits weg sein koennen) und stoppt den `SplunkForwarder`-Dienst. Funktioniert
lokal sowie ueber die bestehenden `-Remote`/`-ComputerList`-Wege, da die interne Kernlogik jetzt
den Modus als String statt als Set/Test-Bool durchreicht.

### Fix: `Invoke-sqmSplunkConfiguration` - fehlende Administratorrechte wurden als `Success` gemeldet

`_sqmSplunk_LocalCore` bricht bei fehlenden Administratorrechten (Modus `Set`/`Remove`) fruehzeitig
ab, aber der oeffentliche Rueckgabewert wurde davon unabhaengig nur anhand des tatsaechlichen
Ist-Zustands (vorhandene Env-Vars/Dienststatus) gebildet - dadurch meldete die Funktion faelschlich
`Status = Success` bzw. `NotConfigured`, obwohl gar nichts ausgefuehrt wurde. `_sqmSplunk_LocalCore`
gibt jetzt `$true`/`$false` zurueck; ein `$false` fuehrt lokal zu `Status = Error` mit der
eigentlichen Fehlermeldung. Im Remote-/List-Pfad wird der Rueckgabewert jetzt abgefangen (statt
unterhalb in `$results` einzusickern) und markiert den betroffenen Zielrechner als
`Fehler (siehe Zielrechner-Log)`.

## [1.9.91.0] — 2026-08-17

### Fix: Stop-sqmSqlProcess - Benachrichtigungstext nannte nur die Session, nicht die Konsequenz

Der `-NotifyOwner`-Nachrichtentext benannte SPID/Datenbank/Instanz und dass die Session "beendet"
wurde, sagte dem Empfaenger aber nicht, was das konkret fuer ihn bedeutet: Verbindung geschlossen,
laufende Transaktion automatisch zurueckgerollt, ggf. erneut anmelden. Aus einem Livetest gegen
DEV01 als zu wenig aussagekraeftig zurueckgemeldet. Text erweitert, damit die Konsequenz explizit
benannt wird statt nur der beendete Zustand.

## [1.9.90.0] — 2026-08-17

### Neu: `Stop-sqmSqlProcess` - SQL-Session beenden mit optionaler Besitzerbenachrichtigung

Bisher gab es in sqmSQLTool keine eigene Funktion zum gezielten Beenden einzelner SQL-Sessions
(nur den internen KILL-Aufruf in `Invoke-sqmRestoreDatabase` fuer Restore-Retries).
`Stop-sqmSqlProcess` liest vor dem Kill Login/Hostname/Programm/Datenbank der Ziel-SPID(s) aus
`sys.dm_exec_sessions`, beendet sie per `Stop-DbaProcess` und sendet bei `-NotifyOwner`
anschliessend eine Nachricht per `msg.exe` an den Hostnamen der Session ("net send" existiert
seit Vista nicht mehr). `-NotifyOwner` ist standardmaessig AUS, damit automatisierte/Job-Kills
keine Popups ausloesen. Ein Fehlschlag der Benachrichtigung (Host offline, keine Rechte, kein
Hostname bekannt) bricht den bereits erfolgten Kill nicht ab, sondern wird nur als eigenes
`NotifyStatus`-Feld im Ergebnis protokolliert. Unterstuetzt Mehrfach-SPIDs in einem Aufruf (z.B.
direkt aus `Get-sqmBlockingReport` gespeist) sowie `-WhatIf`/`-Confirm` (ConfirmImpact = High).
msg.exe-Zustellung selbst wurde noch nicht live gegen die Workgroup-Laborumgebung verifiziert -
host_name ist ein vom Client gemeldeter, nicht verifizierter Wert und bei Verbindungen ueber
Anwendungsserver/Service-Accounts sitzt dort haeufig niemand Interaktives.

## [1.9.89.0] — 2026-08-15

### Fix: Show-sqmToolGui - Mehrfachwerte bei Array-Parametern (z.B. -Database) gingen verloren

Array-Parameter wie `[string[]]$Database` (z.B. bei `Invoke-sqmUserDatabaseBackup`) wurden in der
GUI als normale einzeilige Textbox dargestellt. Beim Klick auf "Run" wurde der eingegebene Text
unveraendert als EIN String an den Parameter uebergeben (`$params[$pname] = $ctrl.Text`). Gab der
Anwender z.B. "DB1, DB2" ein, band PowerShell diesen String als Array mit genau EINEM Element
("DB1, DB2") an den Parameter, statt zwei getrennte Datenbanknamen zu liefern. Die Folge:
`Invoke-sqmUserDatabaseBackup` fand keine passende Datenbank und meldete "Keine Benutzerdatenbanken
fuer Backup gefunden", obwohl beide Datenbanken existierten. Behoben, indem der Run-Handler und die
Kommandovorschau (Copy to clipboard) den Textbox-Inhalt bei Array-Parametern jetzt an Komma/Semikolon
splitten und ein echtes Array binden; das Parameter-Tooltip weist bei Array-Typen zusaetzlich auf die
Komma-Trennung hin. Live gegen DEV01 verifiziert (vorher: "NotFound"/"NoDatabasesFound" bei
kommagetrennter Eingabe, danach: beide Datenbanken korrekt aufgeloest).

## [1.9.88.0] — 2026-08-14

### Neu: `Import-sqmServerConfiguration` - Counterpart zu `Export-sqmServerConfiguration`

Der Export erzeugte bisher nur Snapshots (fuer Dokumentation/Vergleich/Rollback), es gab keinen Weg
sie wieder anzuwenden. `Import-sqmServerConfiguration` liest eine per Export-sqmServerConfiguration
geschriebene JSON-Datei und wendet davon alles an, was auf einer bereits installierten Instanz
tatsaechlich restaurierbar ist: sp_configure (per `Set-DbaSpConfigure`), BackupDirectory/DefaultFile/
DefaultLog (per `Set-DbaDefaultPath`), TempDb-Dateigroessen/-Growth (per `ALTER DATABASE tempdb
MODIFY FILE`, verkleinert nie) und Dienst-StartMode. Aktueller und Zielwert werden vorher verglichen,
sodass nur tatsaechliche Abweichungen angefasst werden - jede Einstellung bekommt eine eigene
Ergebniszeile (Success/Skipped/Failed/WhatIf), analog zu `Import-sqmDatabaseLogins`. Nicht
restaurierbare Kategorien (Edition/Collation/LoginMode als reine Serverinstallations-Eigenschaften,
DatabaseMail, LinkedServers, das Databases-Inventar) werden als 'Informational' ausgewiesen statt
stillschweigend ignoriert.

### Neu: `Export-sqmDatabaseSettings` / `Import-sqmDatabaseSettings` - Datenbank-Options (SSMS "Options"-Seite)

Ergaenzt die bereits vorhandenen Server-weiten Snapshots um die Datenbank-Ebene: erfasst bzw.
restauriert die komplette Options-Seite der SSMS Database Properties (Compatibility Level, Recovery
Model, Page Verify, Target Recovery Time, Delayed Durability, alle ANSI-/ARITHABORT-/AUTO_*-Flags,
Cursor-Default, Parameterization, DB Chaining, Trustworthy, sowie - nur mit
`-IncludeExclusiveOptions`, da sie aktive Verbindungen trennen koennen - ReadOnly,
ReadCommittedSnapshot und BrokerEnabled). Beide Funktionen teilen sich die Settings-Definition
(`Get-sqmDatabaseSettingsDefinition` in Private/), damit Export und Import nie auseinanderlaufen.
`Export-sqmDatabaseSettings` liest alle Datenbanken in einer einzigen Abfrage gegen sys.databases
(kein Connect je Datenbank noetig), `Import-sqmDatabaseSettings` vergleicht vor jeder Aenderung den
Live-Wert und wendet ausschliesslich Abweichungen per `ALTER DATABASE ... SET` an - eine
Ergebniszeile pro Einstellung und Datenbank.

### Neu: HTML-Bericht bei `Export-sqmServerConfiguration` und `Export-sqmDatabaseSettings`

Beide Export-Funktionen schreiben jetzt zusaetzlich zur JSON-Snapshot-Datei einen HTML-Bericht mit
gleichem Dateinamen (.html statt .json) im sqmSQLTool-Theme (`ConvertTo-sqmHtmlReport`), gedacht zum
direkten Zeigen beim Kunden statt der rohen JSON-Datei. `Export-sqmServerConfiguration` listet
sp_configure, Instance Properties, Services, TempDb-Dateien, Database-Mail-Profile und Linked
Servers tabellarisch auf; `Export-sqmDatabaseSettings` zeigt eine Uebersichtstabelle aller
Datenbanken plus je Datenbank ein aufklappbares Detail (`<details>`) mit allen erfassten
Options-Werten. Wird wie bei den uebrigen Report-Funktionen des Moduls automatisch geoeffnet, `-NoOpen`
unterdrueckt das; der Pfad kommt als neues `ReportPath`-Feld im Rueckgabeobjekt.

### Fix: `Export-sqmServerConfiguration` erfasste praktisch keine sp_configure-Werte

`$server.Configuration` ist selbst kein Enumerable (ein `foreach` darueber liefert nur ein einzelnes
leeres SMO-Objekt) - die eigentlichen ~95 sp_configure-Eintraege liegen unter
`$server.Configuration.Properties`. Live gegen DEV01 getestet: vor dem Fix enthielt der Snapshot nur
einen leeren SpConfigure-Eintrag, `ConfigName` war ausserdem auf dieser SMO-Version durchgehend leer
(jetzt Fallback auf `DisplayName`, das Set-DbaSpConfigure -Name ebenfalls akzeptiert). Ohne diesen Fix
haette `Import-sqmServerConfiguration` nie etwas zum Anwenden gehabt. Betrifft nur die
SpConfigure-Erfassung, alle anderen Kategorien waren bereits korrekt.

## [1.9.87.0] — 2026-08-14

### Erweitert: `Get-sqmAutoGrowthReport` - TXT/HTML-Bericht ergaenzt

Bisher gab `Get-sqmAutoGrowthReport` nur das Objekt-Array zurueck, ohne Berichtsdateien
zu schreiben (anders als die uebrigen Report-Funktionen im Modul). Jetzt werden - wie bei
`Get-sqmDiskSpaceReport` - zusaetzlich ein TXT- und ein HTML-Bericht (nach Status sortiert,
farbcodiert) in `-OutputPath` abgelegt (Default: `AutoGrowthReports`-Unterordner unter dem
konfigurierten Standard-Ausgabepfad) und per `Invoke-sqmOpenReport` geoeffnet (`-NoOpen`
unterdrueckt das).

Die Funktion wird auch intern von `Get-sqmFileGrowthHistory` als reine Datenquelle
aufgerufen; damit dort nicht bei jedem Lauf zusaetzlich ein eigener AutoGrowth-Bericht
entsteht, ruft `Get-sqmFileGrowthHistory` jetzt mit dem neuen Schalter `-NoReport` auf.
Das zurueckgegebene Objekt-Array selbst ist unveraendert (bestehende Aufrufer funktionieren
unveraendert weiter).

## [1.9.86.0] — 2026-08-13

### Neu: `Get-sqmFileGrowthHistory` - Datei-Wachstum ueber die Zeit aufzeichnen und prognostizieren

`Get-sqmAutoGrowthReport` liefert nur eine Momentaufnahme der AutoGrowth-Konfiguration
(aktuelle Groesse, Growth-Typ/-Wert, MaxSize) - keine Historie und keinen Trend.

`Get-sqmFileGrowthHistory` schliesst diese Luecke nach dem gleichen Muster (Methode B1)
wie `Get-sqmDiskSpaceReport`: Bei jedem Lauf wird `Get-sqmAutoGrowthReport -Detailed` als
alleinige Datenquelle abgefragt und die aktuelle Groesse jeder Datei in eine
Snapshot-Historie pro Instanz (`FileGrowthHistory_<Instanz>.json`) angehaengt. Eine
lineare Regression ueber das `-HistoryDays`-Fenster liefert MB/Tag Wachstum je Datei und,
bei begrenzter MaxSize, die Prognose in wie vielen Tagen die Grenze erreicht wird. Die
Regressions-/Konfidenzberechnung selbst wird nicht neu geschrieben, sondern die bereits
vorhandene modulinterne Hilfsfunktion `Get-sqmVolumeForecast` (aus `Get-sqmDiskSpaceReport.ps1`,
generisch fuer beliebige Timestamp/Groesse-Zeitreihen) wiederverwendet. Ergebnis wird wie
gewohnt als TXT/CSV/HTML-Bericht abgelegt.

Braucht mindestens `-MinDataPoints` (Default 5) wiederkehrende Laeufe (z. B. taeglicher
Agent-Job) bevor eine Prognose statt "sammelt noch" ausgegeben wird.

Funktionsanzahl im Modul: 164 -> 165.

## [1.9.85.0] — 2026-08-12

### Neu: `Restore-sqmSysadminAccess` - Notfall-Wiederherstellung bei komplettem DBA-Lockout

Bislang gab es im Modul keine Funktion fuer den Fall, dass auf einer Instanz KEIN
funktionierender sysadmin-Login mehr existiert (Logins geloescht, Passwoerter verloren,
versehentlich alle sysadmin-Mitgliedschaften entzogen). Bisher blieb dafuer nur die
manuelle Prozedur: Dienst stoppen, mit Startparameter `-m"..."` (Single-User-Mode) neu
starten, per `sqlcmd` als lokaler Administrator verbinden (im Single-User-Mode implizit
sysadmin), Login anlegen/Passwort zuruecksetzen, `sp_addrolemember`/`ALTER SERVER ROLE`,
Dienst wieder normal starten.

`Restore-sqmSysadminAccess` automatisiert genau das (dbatools
`Stop-DbaService`/`Set-DbaStartupParameter -SingleUser`/`Start-DbaService`), fuehrt
Login-Anlage/-Reset + Rollenvergabe + Trigger-Deaktivierung/-Reaktivierung dabei in
EINEM einzigen T-SQL-Batch/EINER einzigen Verbindung aus (Single-User-Mode erlaubt nur
genau eine Verbindung - jeder zusaetzliche Roundtrip waere ein Zeitfenster fuer einen
konkurrierenden Verbindungsversuch) und baut den Single-User-Mode im `finally`-Block in
JEDEM Fall wieder zurueck, auch nach einem Fehler mitten in der Prozedur. Generiertes
Passwort wird nur im Rueckgabeobjekt ausgegeben, nie geloggt.

ConfirmImpact bleibt bewusst 'High' MIT aktivem interaktivem Rueckfrage-Dialog (anders
als z.B. `Grant-sqmTemporarySysadmin`) - gedacht als manuelle Notfallmassnahme am
Keyboard, nicht fuer unbeaufsichtigte Automation.

Funktionsanzahl im Modul: 163 -> 164.

## [1.9.84.0] — 2026-08-12

### Neu: `Get-sqmDatabaseRestoreHistory` - letzter Restore-Zeitpunkt je Datenbank

Bislang gab es im Modul keine Funktion, die auflistet, wann eine Datenbank zuletzt restauriert
wurde - relevant fuer Compliance-Nachweise, Migrations-/Test-Nachverfolgung und um zu erkennen,
ob eine erwartete Restore-Prozedur tatsaechlich gelaufen ist.

`Get-sqmDatabaseRestoreHistory` listet fuer jede Datenbank auf der Instanz (gleiche
Filterung wie `Get-sqmDatabaseHealth`: exkl. tempdb, System-DBs standardmaessig ausgeschlossen,
`-ExcludeDatabase`-Wildcards) den letzten Restore-Vorgang aus `msdb.dbo.restorehistory` (via
dbatools `Get-DbaDbRestoreHistory -Last`): Zeitpunkt, Typ (Database/Log/Differential/...),
durchfuehrender Login und Quelldatei. Datenbanken ohne jede Restore-Historie - der Normalfall bei
den meisten Produktivdatenbanken - werden explizit als "(nie restauriert)" ausgewiesen statt
stillschweigend aus der Liste zu fehlen (reines `Get-DbaDbRestoreHistory` liefert nur Zeilen fuer
tatsaechlich restaurierte Datenbanken).

Berichte werden wie bei den uebrigen `Get-sqm*`-Reportfunktionen als CSV/TXT/HTML unter
`-OutputPath` abgelegt (Default: `<OutputPath config>\DatabaseRestoreHistory`).

Unit-Tests (Pester, gemockt dbatools): 10/10 gruen. Gesamte Modul-Testsuite (229 Tests) gruen.
Funktionsanzahl im Modul: 162 -> 163 (README aktualisiert).

## [1.9.83.0] — 2026-08-12

### Fix: `Invoke-sqmRestoreDatabase` scheiterte trotz erfolgreichem SetSingleUser mit "Exclusive access could not be obtained"

Gemeldet anhand eines echten Laufs (SFCSDBS103IHZ, Restore von `arena` aus
`F:\DB_Transfer_Prod\arena.bak`): `SetSingleUser` protokollierte Erfolg, der direkt
anschliessende `Restore-DbaDatabase`-Aufruf scheiterte trotzdem mit "Exclusive access could not
be obtained because the database is in use."

Ursache: `ALTER DATABASE ... SET SINGLE_USER WITH ROLLBACK IMMEDIATE` lief ueber
`Invoke-DbaQuery`, dessen Verbindung danach geschlossen wird - der einzige Verbindungs-Slot war
damit wieder frei. Bis `Restore-DbaDatabase` seine eigene, neue Verbindung aufbaute (dazwischen
liegt zusaetzlich noch `RESTORE FILELISTONLY` fuer das Auto-FileMapping), konnte sich eine fremde
Session neu verbinden und den Slot belegen - der eigentliche RESTORE-Befehl fand die Datenbank
dann wieder "in use" vor.

Fix: Der Restore-Schritt erkennt genau diese Fehlermeldung jetzt und beendet alle Sessions auf der
Zieldatenbank per `Stop-DbaProcess`, bevor er es erneut versucht (bis zu 3 Versuche). Ein erneutes
`ALTER DATABASE SET SINGLE_USER` haette hier NICHT geholfen - dieser Befehl braucht selbst
exklusiven Zugriff, der ja gerade durch die fremde Session blockiert ist (Henne-Ei-Problem);
`Stop-DbaProcess` wirkt dagegen unabhaengig vom aktuellen User-Access-Modus.

Beim Schreiben der Regressionstests dafuer zusaetzlich einen unabhaengigen, vorbestehenden Bug
gefunden und mitbehoben: `-DatabaseName` hatte neben dem an das `FromHistory`-Set gebundenen
Attribut ein zweites, unbenanntes `[Parameter(Mandatory = $false)]` (== `__AllParameterSets`).
Kombiniert mit den explizit benannten Sets `SingleFile`/`Sequence` (ueber `-BackupFile`/
`-BackupFiles`) konnte PowerShell den Parametersatz nicht mehr auflösen, sobald `-BackupFile`
UND `-DatabaseName` gemeinsam angegeben wurden - exakt der in `.EXAMPLE` dokumentierte
Standardfall. Der Aufruf scheiterte dadurch bereits beim Parameter-Binding mit
"Parameter set cannot be resolved", bevor auch nur eine Zeile der Funktion lief. Ein bestehender
Unit-Test hatte das unbemerkt ueberdeckt, weil er nur pauschal `Should -Throw` ohne
Meldungsabgleich pruefte - die eigentlich getestete Ursache (`Get-sqmDatabaseAgMembership`
schlaegt fehl) wurde dadurch nie erreicht. Fix: `$DatabaseName` bekommt jetzt fuer jedes Set ein
eigenes, explizit benanntes `[Parameter(...)]`-Attribut statt der unbenannten Variante.

Unit-Tests (Pester, gemockt): 17/17 gruen inkl. zweier neuer Regressionstests fuer den
Exclusive-Access-Retry (erfolgreicher Retry nach 2 Fehlversuchen, endgueltiger Abbruch nach 3
Versuchen ohne Endlos-Retry) sowie einem verschaerften Test fuer den Parameterset-Fix. Gesamte
Modul-Testsuite (219 Tests) weiterhin gruen.

## [1.9.82.0] — 2026-08-11

### Fix: `Invoke-sqmSplunkConfiguration` schrieb im Remote-/List-Modus kein Controller-Log

Gemeldet: "Ebenso soll ein Log als Standardverhalten geschrieben werden." Im Local-Modus schrieb
`_sqmSplunk_LocalCore` bereits immer ein vollstaendiges Log. Im Remote- (AD-OU) und List-Modus
ging jede Meldung des Controllers (AD-Suche, Verbindungsversuche pro Zielrechner, Abschluss-
Zusammenfassung) nur an `Write-Host`/GUI-Callback - ohne Log-Datei auf dem Rechner, von dem aus
der Befehl gestartet wurde. Nur die Zielrechner selbst schrieben (via `Invoke-Command`) ihr
eigenes lokales Log.

Fix: `_sqmSplunkGuiLog` schreibt jetzt immer zusaetzlich in eine Log-Datei, wenn eine angegeben
ist (Protokollierung ist Standardverhalten, kein Opt-in-Parameter noetig). Ein Log-Dateipfad wird
zentral einmal pro Aufruf berechnet und durchgereicht (`_sqmSplunk_ForOU` → `_sqmSplunk_ForList` →
`_sqmSplunk_OnComputers`), inklusive der Abschluss-Tabelle. `_sqmSplunk_LocalCore` nimmt jetzt
direkt einen fertigen Dateipfad entgegen statt selbst einen zu erzeugen - Zielrechner im
Remote-/List-Modus erzeugen ihren eigenen Dateinamen weiterhin selbst (auf sich selbst, getrennt
vom Controller-Log).

Live verifiziert (powershell.exe 5.1, DEV03): Local-, List- (inkl. nicht erreichbarem Host und
leerer Liste) und Remote-Modus erzeugen jeweils genau eine Log-Datei mit vollstaendigem
Nachrichtenverlauf; die zuvor behobene `AmbiguousParameterSet`-Regression (siehe [1.9.81.0])
bleibt bestehen.

## [1.9.81.0] — 2026-08-11

### Fix: `Invoke-sqmSplunkConfiguration` wirft ParameterBindingException beim Setzen von `-Remote` oder `-SearchOU`

Gemeldet: "Error beim ParameterBinding" beim Setzen von Remote oder SearchOU. Live nachgestellt
(powershell.exe 5.1): Sobald `-ComputerList` zusammen mit `-Remote`/`-SearchOU` gebunden wird -
auch mit leerem Array, `$null` oder `Remote:$false` reicht bereits die reine Angabe des Parameters -
wirft PowerShell `AmbiguousParameterSet` ("Der Parametersatz kann mit den angegebenen benannten
Parametern nicht aufgeloest werden."), noch bevor der Funktionsrumpf laeuft.

Ursache: Die `param()`-Deklaration hatte `Remote`/`SearchOU` und `ComputerList` ueber
`ParameterSetName` als hart gegenseitig exklusiv markiert - obwohl der Funktionsrumpf selbst
bereits eine Prioritaetskette dafuer implementiert (`if ($Remote) ... elseif ($ComputerList) ...
else`). Diese Rumpf-Logik war durch die strikte Set-Pruefung nie erreichbar, sobald beide Parameter
gleichzeitig gebunden wurden - z. B. wenn im GUI-Formular sowohl `SearchOU` befuellt als auch aus
einem vorherigen Versuch noch Text in `ComputerList` steht.

Fix: `ParameterSetName`-Attribute von `Remote`, `SearchOU`, `ComputerList` und `Credential`
entfernt. Die Funktion hat jetzt nur noch einen Parametersatz; welcher Ausfuehrungspfad
(Remote/List/Local) genutzt wird, entscheidet weiterhin die bereits vorhandene Prioritaetslogik im
Rumpf. Live verifiziert (powershell.exe 5.1, DEV03): alle zuvor fehlschlagenden Kombinationen
(`SearchOU` + leeres/`$null`/gesetztes `ComputerList`, `Remote:$false` + `SearchOU`, `Remote:$true`
+ leeres `ComputerList`) binden jetzt fehlerfrei und laufen im jeweils korrekten Zweig.

## [1.9.80.0] — 2026-08-10

### Fix: `Get-sqmWaitStatistics` und fünf Batch-B3-Geschwister schreiben jetzt auch ohne `-OutputPath` einen Report

Gemeldet: "Get-sqmWaitStatistics erstellt keinen HTML-Report mehr". Live-Test gegen DEV01 mit
sowohl dem aktuellen Source-Stand als auch der auf einem Testrechner installierten Version
(v1.9.51.0) zeigte in beiden Staenden korrekten, funktionierenden CSV+HTML-Code - kein
Regressions-Bug. Ursache war Aufruf ohne `-OutputPath`: Anders als z. B. `Get-sqmDiskSpaceReport`
oder `Get-sqmLoginSettings` hatte `Get-sqmWaitStatistics` (und mit ihr vier weitere Funktionen aus
dem selben "Report-Standardisierung Batch B3", die im Juni zusammen die HTML-Ausgabe erhielten)
keinen Default-Wert fuer `-OutputPath` - ohne den Parameter wurde nie eine Datei geschrieben, auch
keine CSV, nur Objekte/Log.

Fix (Default-Wert nach dem bereits etablierten Muster `(Join-Path (Get-sqmDefaultOutputPath)
'<Unterordner>')`, wie es `Get-sqmLoginSettings`/`Get-sqmDiskSpaceReport` bereits nutzen):
- `Get-sqmWaitStatistics` → `...\WaitStatistics`
- `Get-sqmPerfCounters` → `...\PerfCounters`
- `Get-sqmConnectionStats` → `...\ConnectionStats`
- `Get-sqmMissingIndexes` → `...\MissingIndexes`
- `Get-sqmLongRunningQueries` → `...\LongRunningQueries`

`Get-sqmLoginSettings` hatte bereits einen Default und war nicht betroffen.

Live gegen DEV01 verifiziert (frischer Modul-Reimport aus dem Source-Verzeichnis, nicht die
lokal installierte Kopie - siehe Hinweis in [[feedback_sqmsqltool_installed_vs_source]]):
`Get-sqmWaitStatistics`, `Get-sqmConnectionStats` und `Get-sqmPerfCounters` schreiben jetzt ohne
`-OutputPath` automatisch CSV+HTML in den Default-Ordner. `Get-sqmMissingIndexes` schreibt bei 0
Treffern weiterhin bewusst keine Datei (eigene, unveraenderte Bedingung `-and $results.Count -gt
0`) - kein Bug, sondern vermeidet leere Reports.

## [1.9.79.0] — 2026-08-10

### Feature: `New-sqmAgentCommandJob` — beliebige sqmSQLTool-Funktionen generisch als Agent-Job-Step

Hintergrund: Die bisherigen `New-sqm*Job`-Funktionen (`New-sqmRestoreDatabaseJob`,
`New-sqmAlwaysOnRepairJob`, ...) sind jeweils fest auf EINE Zielfunktion mit fest verdrahteten
Parametern zugeschnitten - jede baut ihre eigene Argument-String-Zeile per Hand. Fuer beliebige
sqmSQLTool-Funktionen mit unterschiedlichsten Parametersaetzen skaliert das nicht; ein frueherer
generischer Versuch (`Private\New-sqmCmdExecJobStep.ps1` / `_CreateCmdExecJobStep`) baute
Parameter per doppelt-quotierter String-Interpolation in den generierten Wrapper ein und brach bei
`$`-Zeichen in Pfaden sowie durch hartkodierte, nicht auf jede Funktion zutreffende Flags
(`-Verbose -ContinueOnError`) - wird seither von den produktiven Job-Funktionen nicht mehr
verwendet (siehe deren Kommentare zu `_q`-Escaping).

`New-sqmAgentCommandJob` loest das strukturell statt durch besseres Escaping: Parameter werden nie
als Text in generierten PowerShell-Quellcode eingebettet, sondern per `Export-Clixml` typisiert in
eine Datei pro Step geschrieben. Ein einziger, wiederverwendbarer Wrapper (`generic-invoke.ps1`,
unter `...\sqmSQLTool\jobs\`) laedt die Datei per `Import-Clixml` und ruft die per `-FunctionName`
uebergebene Zielfunktion per Splatting auf - dieselbe Wrapper-Datei bedient jede beliebige
sqmSQLTool-Funktion, ohne pro Funktion neuen Code zu generieren. `-EnableException`/`-Confirm:$false`
werden nur gesetzt, wenn `Get-Command` bestaetigt, dass die Zielfunktion den Parameter ueberhaupt
kennt - der Bug mit den hartkodierten Flags aus dem alten Ansatz kann so nicht mehr auftreten.
`Get-Command -Module sqmSQLTool` wirkt zusaetzlich als Allowlist (nur exportierte Funktionen sind
aufrufbar) und faengt Tippfehler im Funktionsnamen schon vor dem Anlegen ab.

Zwei Achsen sind unabhaengig waehlbar:
- **Ein Job/mehrere Steps**: `-Command` nimmt ein Array von Hashtables (`FunctionName`,
  `Parameters`, optional `StepName`) - jeder Eintrag wird ein eigener, per `GoToNextStep`
  verketteter CmdExec-Step; jeder Step beendet den Job bei Fehler sofort (`QuitWithFailure`,
  Fail-Fast). `-AppendStep` haengt spaeter weitere Steps an einen bestehenden Job an; dabei wird
  der bisher letzte Step automatisch von `QuitWithSuccess` auf `GoToNextStep` umgestellt (per
  `Set-DbaAgentJobStep -StepName` - dieses Cmdlet hat kein `-StepId`, siehe Fix in [1.7.x] weiter
  unten), sonst wuerden die neuen Steps nie erreicht.
- **On-Demand/Scheduled**: `-ScheduleType None` (Default) vs. `Daily`/`Weekly`/`Monthly` via
  `New-DbaAgentSchedule` (gleiches Muster wie `New-sqmRestoreTestJob`), plus `-StartJob` fuer den
  sofortigen ersten Lauf unabhaengig vom Schedule.

Sicherheitshinweis in den Function-Docs: keine `PSCredential`/`SecureString`-Werte in `-Parameters`
- `Export-Clixml` verschluesselt SecureStrings per DPAPI nur fuer das aktuelle Windows-Konto; laeuft
der Job unter einem anderen Konto (Dienstkonto/Proxy), schlaegt die Entschluesselung fehl. Fuer
erhoehte Rechte stattdessen einen dedizierten Agent-Proxy (`New-sqmAgentProxy`) verwenden.

Beim Live-Test per `-WhatIf` gegen DEV01 (workgroup, kein Domaenen-Trust) zwei Dinge gefunden und
korrigiert:
- Ein Bug in der Step-Schleife: die lokale Variable hiess `$command` - kollidiert case-insensitiv
  mit dem typisierten Pflichtparameter `$Command` ([hashtable[]]). PowerShell erzwingt bei jeder
  Zuweisung an eine parametertypisierte Variable weiterhin deren Typ; die Zuweisung des generierten
  Kommando-Strings brach deshalb bei JEDEM echten Aufruf mit "Cannot convert ... to Hashtable[]" ab
  - unabhaengig von `-WhatIf`. Fix: umbenannt zu `$stepCommand`.
- `-SqlCredential` ergaenzt (optional, wie bei `New-sqmAgentProxy`): ohne Domaenen-Trust zum
  `-SqlInstance` schlagen die internen `Get/New/Set-DbaAgentJob*`-Aufrufe sonst mit Windows-Auth
  fehl. Aendert nichts daran, wie der Job-Step selbst spaeter authentifiziert (siehe .NOTES) - gilt
  nur fuer die Verbindung, mit der der Job ANGELEGT wird.

Beide Fixes und alle Pfade (Single-Step, Multi-Step-Kette mit Daily/Weekly-Schedule, `-AppendStep`
gegen einen echten vorhandenen Job inkl. automatischer `GoToNextStep`-Umstellung des bisher letzten
Steps, Allowlist-Ablehnung eines Tippfehler-Funktionsnamens) per `-WhatIf` gegen DEV01 verifiziert.
Echte Job-Anlage (ohne `-WhatIf`) erfordert eine elevated PowerShell-Session (Schreibzugriff auf
`C:\Program Files\...` - gilt fuer alle `New-sqm*Job`-Funktionen dieses Moduls) und wurde in dieser
Session mangels Elevation nicht ausgefuehrt.

## [1.9.78.0] — 2026-08-10

### Feature: `Export-sqmDatabaseLogins` / `Import-sqmDatabaseLogins` / `Sync-sqmDatabaseLogins`

Hintergrund: Datenbanken wie `Frontarena` werden regelmaessig von Prod nach Test kopiert und dort
per `Invoke-sqmRestoreDatabase` restored. Die Datenbank enthaelt ca. 1500 SQL-Server-Logins als
Datenbank-User; die zugehoerigen Server-Logins mit den aktuellen Kennwoertern liegen nur auf Prod
und aendern sich dort von Zeit zu Zeit (Passwortrichtlinie/Ablauf) - Test bekommt das nie
mitgeteilt. Nach einem Refresh landen die Datenbank-User zwar korrekt (mit Prod-SIDs) in der
Test-DB, aber ein ggf. bereits vorhandenes gleichnamiges Test-Login hat eine andere SID und/oder
ein veraltetes Kennwort - Endanwender koennen sich mit ihrem aktuellen Prod-Kennwort nicht an Test
anmelden.

Prod und Test koennen dabei in unterschiedlichen, sich gegenseitig nicht sehenden Domaenen/Netzen
liegen (muss aber nicht so sein) - eine gleichzeitige Live-Verbindung von einer Kontrollmaschine zu
beiden Instanzen (wie es das bestehende `Copy-sqmLogins` voraussetzt) ist deshalb keine verlaessliche
Annahme. Die neue Loesung ist daher rein dateibasiert:

- **`Export-sqmDatabaseLogins`** verbindet sich NUR zur Quelle (Prod), ermittelt die SQL-Auth-User
  einer Datenbank, schliesst sysadmin-/`sa`-/System-Logins ohne Override-Moeglichkeit aus, und
  schreibt pro Login einen eigenstaendigen, idempotenten T-SQL-Block (SID + Kennwort-Hash +
  Policy-Flags) in ein menschenlesbares, auch manuell in SSMS ausfuehrbares Skript an einen
  beliebigen Pfad. Jeder Block prueft zusaetzlich zur Laufzeit erneut, ob das Ziel-Login sysadmin/
  `sa` ist, und laesst es dann unangetastet - ein zweites, unabhaengiges Sicherheitsnetz, das auch
  bei versehentlicher Ausfuehrung gegen die falsche Instanz greift.
- **`Import-sqmDatabaseLogins`** verbindet sich NUR zum Ziel (Test), liest die von einem externen,
  nicht von diesem Modul gesteuerten Kopiervorgang dorthin transportierte Datei, deaktiviert/
  reaktiviert die konfigurierte PBM-Policy exakt wie `Copy-sqmLogins`, wendet jeden Login-Block
  einzeln an (eigenes Status-Ergebnis pro Login: `Success`/`SkippedSysadmin`/
  `SkippedSidCollision`/`Failed`) und ruft abschliessend `Repair-DbaDbOrphanUser` auf.
- **`Sync-sqmDatabaseLogins`** ist ein reiner Orchestrierungs-Wrapper fuer den Fall, dass eine
  Kontrollmaschine tatsaechlich beide Instanzen erreicht: Export in eine Temp-Datei, sofort
  Import, Temp-Datei loeschen - keine eigene Fachlogik, deckt beide Konnektivitaets-Faelle mit
  denselben zwei Bausteinen ab.

`Invoke-sqmRestoreDatabase` selbst wurde NICHT veraendert (kein zusaetzlicher Parameterpfad in einer
bereits sehr umfangreichen, AG-sensiblen Funktion) - fuer Datenbanken mit eigenstaendigen SQL-Logins
wie `Frontarena` wird `Sync-sqmDatabaseLogins` (oder das Export-/Import-Paar) direkt im Anschluss an
den Restore aufgerufen, siehe Verweis in dessen `.NOTES`.

## [1.9.77.0] — 2026-08-08

### Feature: `Invoke-sqmPerfBaseline` erfasst jetzt direkt CPU% und Memory (MB)

Anwenderwunsch: neben Wait Stats und Perf-Counter-Deltas sollen CPU und Memory auch direkt
ausgewertet werden. Jeder Snapshot (`-Action Capture`) enthaelt jetzt zusaetzlich eine
Momentaufnahme aus `sys.dm_os_ring_buffers` (CPU%) und `sys.dm_os_process_memory` /
`sys.dm_os_sys_memory` (SQL-, Available- und Total-Memory in MB), gespeichert als
`DirectMetrics`-Feld im Baseline-JSON. Da es sich - anders als Wait Stats/Perf Counter - um
Momentwerte statt kumulative Zaehler handelt, zeigt `-Action Compare` sie nicht als Delta,
sondern als neue Sektion "CPU & Memory (Zeitpunkt der Erfassung)" mit A/B nebeneinander (HTML-
Report + Rueckgabeobjekt `.DirectMetrics`). Baseline-Dateien von vor diesem Feature (kein
`DirectMetrics`-Feld) werden erkannt und im Report als "Nicht verfuegbar" markiert statt einen
Fehler zu werfen.

Die dafuer noetigen DMV-Queries (CPU-Ring-Buffer, Memory) gab es in `Get-sqmServerUtilization`
bereits einzeln; beide wurden in den neuen privaten Helper `Get-sqmDirectCpuMemory` (ein
DMV-Call via `OUTER APPLY` statt zwei getrennte Queries) ausgelagert und `Get-sqmServerUtilization`
darauf umgestellt, um die Query-Logik nicht zu duplizieren.

**Live gegen Docker-Testcontainer (`mssql-2022-test`) verifiziert:** Capture, Compare (inkl.
neuer HTML-Sektion), sowie der Ruecksprung auf einen synthetischen Alt-Snapshot ohne
`DirectMetrics`. Dabei zeigte sich ein Bug in der ersten Implementierung: `CROSS APPLY` verhaelt
sich wie ein Inner Join, sodass bei leerem Ring-Buffer (z. B. kurz nach Instanz-Neustart, wie im
frisch gestarteten Testcontainer) die komplette Ergebniszeile inkl. Memory-Werten wegfiel - mit
`OUTER APPLY` behoben, CPU% faellt in diesem Fall korrekt auf 0 zurueck statt Memory mit
wegzureissen.

## [1.9.76.0] — 2026-08-07

### Fix: `Invoke-sqmRestoreDatabase` scheiterte beim AG-Rejoin mit "RecoveryModel ... is not Full, but Simple"

Vorfall auf `SFCSDBS103IHZ`: Restore von `Test` aus einem Backup, das (oder dessen Quelldatenbank)
in SIMPLE Recovery stand. Restore, User-Import und Owner-Zuweisung liefen erfolgreich durch, aber
`Add-DbaAgDatabase` scheiterte zuverlaessig mit "RecoveryModel of database [Test] is not Full, but
Simple" - eine AG verlangt zwingend Full Recovery mit luecklosser Log-Chain.

Vor dem eigentlichen Rejoin-Versuch wird das Recovery Model jetzt geprueft; steht es nicht auf
FULL, stellt die Funktion automatisch um (`ALTER DATABASE ... SET RECOVERY FULL`) und erstellt
sofort danach ein FULL-Backup - SET RECOVERY FULL allein reicht nicht, bis zum naechsten
FULL-Backup verhaelt sich die Datenbank weiterhin wie SIMPLE ("pseudo-simple"), das haette
`Add-DbaAgDatabase` also unveraendert scheitern lassen. Neuer Ergebniseintrag `Action =
EnsureFullRecoveryModel` zeigt, ob/dass umgestellt wurde.

### Feature: `Invoke-sqmRestoreDatabase` findet das Backup automatisch, wenn nur `-DatabaseName` angegeben wird

Bisher musste immer `-BackupFile` oder `-BackupFiles` angegeben werden. Neuer Parameter-Set
`FromHistory`: wird WEDER `-BackupFile` NOCH `-BackupFiles` angegeben, wird `-DatabaseName`
zwingend erforderlich, und die aktuellste Wiederherstellungskette (neuestes Full plus alle
seitherigen Diff/Log-Backups) wird automatisch aus der Backup-Historie der Instanz ermittelt
(`Get-DbaDbBackupHistory -Database <name> -Last`, d.h. msdb.dbo.backupset) und zum
spaetestmoeglichen Zeitpunkt wiederhergestellt - der Aufrufer muss keinen Dateipfad mehr kennen:

```
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -DatabaseName "AdventureWorks"
```

Gegen DEV01 verifiziert (`-WhatIf`): die Funktion findet und verwendet korrekt die tatsaechlich
neueste Full-Backup-Datei aus der Historie, ohne dass ein Pfad angegeben wurde.

### Fix: Backup-Zielverzeichnis-Pruefung verlangte "User-Db" statt der tatsaechlich verwendeten "Usr-db"

`Invoke-sqmUserDatabaseBackup` verlangte bislang, dass der Backup-Pfad auf "User-Db" endet - eine
andere Schreibweise als die im Rest des Moduls tatsaechlich verwendete und angelegte "Usr-db"
(siehe `New-sqmOlaUsrDbBackupJob`: legt real `<BackupDirectory>\Usr-db` an). Ein voellig
regelkonformer, von den eigenen Backup-Job-Funktionen selbst angelegter Pfad waere von
`Invoke-sqmUserDatabaseBackup` also faelschlich abgelehnt worden. Dieselbe falsche Annahme
("User-db" statt "Usr-db") steckte auch in `Invoke-sqmTsmConfiguration`s Standard-INCLUDE-Regel -
das TSM-INCLUDE zeigte auf einen Ordner, den keine der Backup-Job-Funktionen je befuellt, das
tatsaechliche "Usr-db"-Verzeichnis waere von TSM nie gesichert worden. Beide jetzt auf "Usr-db"
korrigiert.

## [1.9.75.0] — 2026-08-07

### Fix: `Show-sqmToolGui` markierte Alternativ-Parameter (z.B. BackupFile/BackupFiles) faelschlich als Pflichtfeld

Die Label-Anzeige im GUI-Launcher markierte ein Parameterfeld mit einem fett gedruckten "*"
(Pflichtfeld), sobald IRGENDEINE seiner `ParameterAttribute`-Auspraegungen `Mandatory = $true`
gesetzt hatte - unabhaengig vom Parameter-Set. Bei `Invoke-sqmRestoreDatabase` ist `-BackupFile`
nur im Set `SingleFile`, `-BackupFiles` nur im Set `Sequence` Mandatory - beides sind
Alternativen, keine zwei gleichzeitig auszufuellenden Pflichtfelder. Das GUI zeigte deshalb bei
BEIDEN ein "*", obwohl nur eines gebraucht wird - genau dieselbe Fehlerklasse, die fuer die
Run-Button-Validierung bereits in 1.9.43.0 behoben wurde, hier aber nie nachgezogen.

Fix: Die Mandatory-Pruefung fuer das Label vergleicht jetzt wie die Run-Validierung ueber
`Command.ParameterSets` - "*" (fett) erscheint nur noch, wenn ein Parameter in JEDEM
Parameter-Set der Funktion Pflicht ist (also unbedingt noetig, egal welches Set gewaehlt wird).
Parameter, die nur in EINIGEN Sets Pflicht sind (Alternativen wie BackupFile/BackupFiles),
bekommen stattdessen ein leichteres "+"-Zeichen; der Tooltip nennt das/die betroffene(n)
Parameter-Set(s). Betrifft neben `Invoke-sqmRestoreDatabase` auch `Get-sqmDiskBlockSize`,
`Get-sqmServerSetting` und `New-sqmRestoreDatabaseJob`, die dasselbe Alternativ-Muster haben.

### Feature: `New-sqmBackupMaintenanceJob` liest den Jobnamen jetzt aus der Konfiguration

`-JobName` hatte bisher den fest verdrahteten Default `'sqm-BackupMaintenance-FULL'` -
unabhaengig vom gewaehlten `-BackupType`. Ein Aufruf mit `-BackupType DIFF` ohne `-JobName` legte
also einen SQL-Agent-Job an, der `sqm-BackupMaintenance-FULL` hiess, obwohl er tatsaechlich ein
DIFF-Job war.

`-JobName` hat jetzt keinen festen Default mehr; ohne explizite Angabe wird der Name aus der
Konfiguration gelesen, abhaengig vom gewaehlten `-BackupType`
(`Set-sqmConfig -BackupMaintenanceJobNameFull/-Diff/-Log`), analog zum bereits bestehenden Muster
bei `New-sqmOlaUsrDbBackupJob` (`OlaJobNameFull/Diff/Log`). Ist auch das nicht konfiguriert, greift
weiterhin ein typspezifischer Default (`sqm-BackupMaintenance-<BackupType>`), diesmal korrekt
abhaengig vom Typ statt immer "FULL".

Im GUI-Launcher (`Show-sqmToolGui`) fuellt eine Auswahl in der BackupType-Dropdown-Liste (FULL/
DIFF/LOG) das JobName-Feld jetzt automatisch mit dem konfigurierten bzw. Default-Namen - der
Anwender muss ihn im Regelfall nicht mehr selbst eintippen, kann ihn danach aber weiterhin frei
ueberschreiben.

Alle drei Aenderungen gegen DEV01 verifiziert (Jobname-Aufloesung inkl. mit und ohne konfiguriertem
Wert; DEV01 selbst war waehrend eines Teils der Tests wegen eines offensichtlich voruebergehenden
DNS-Ausfalls im Labor nicht erreichbar - unabhaengig von dieser Aenderung, die Namensaufloesung
selbst wurde unabhaengig davon per direktem Objektvergleich bestaetigt).

## [1.9.74.0] — 2026-08-07

### Fix: Get-sqmLoginSettings-Bericht zeigte DefaultDatabase/DefaultLanguage nicht an

Die zurueckgegebenen Objekte enthalten `DefaultDatabase` und `DefaultLanguage` (die CSV hatte sie
deshalb schon immer, da sie die vollen Objekte exportiert) - TXT und HTML liessen beide Felder
aber aus. Beide Spalten jetzt in TXT (unter jedem Login) und HTML (eigene Tabellenspalten,
HTML-encodiert) ergaenzt. Gegen DEV01 verifiziert.

## [1.9.73.0] — 2026-08-07

### Feature: HTML-Report fuer drei weitere Funktionen ergaenzt

`Get-sqmAlwaysOnFailoverHistory`, `Get-sqmTlsStatus` und `Invoke-sqmInstanceInventory` schrieben
bislang nur TXT + CSV, obwohl sie wie die anderen "voll ausgebauten" Reports (z.B.
`Get-sqmSysadminAccounts`) laengst einen sinnvoll farbcodierbaren Status pro Zeile berechnen. Alle
drei bekommen jetzt zusaetzlich einen HTML-Report im etablierten Stil (`ConvertTo-sqmHtmlReport`):

- `Get-sqmAlwaysOnFailoverHistory`: FailoverType farblich markiert (Forced=rot, Automatic=gelb,
  Planned=gruen).
- `Get-sqmTlsStatus`: Status farblich markiert (Critical=rot, Warning=gelb, OK=gruen), Ergebnisse
  nach Schweregrad sortiert.
- `Invoke-sqmInstanceInventory`: alle TXT-Abschnitte (Instanz, Datenbanken, Logins, Linked Server,
  Agent Jobs, Konfigurationsabweichungen, Always On) als HTML-Tabellen; Datenbanken ohne
  Vollsicherung und sysadmin-Logins gelb markiert, fehlgeschlagene Agent-Jobs rot. Bekam dabei
  auch den bislang fehlenden `-NoOpen`-Switch und das automatische Oeffnen des Reports, analog zu
  den anderen Funktionen.

Alle drei zusaetzlich gegen DEV01 verifiziert (Instance Inventory und TLS-Status remote, Failover-
Historie lokal - RPC-Zugriff auf das entfernte Application-Event-Log ist in diesem Workgroup-Labor
ohne Domaene nicht verfuegbar, unabhaengig von dieser Aenderung).

## [1.9.72.0] — 2026-08-07

### Feature: 33 weitere Report-Funktionen bekommen ein eigenes Unterverzeichnis

`C:\System\WinSrvLog\MSSQL` (der Standard-Ausgabepfad) sammelte die TXT/CSV/HTML-Dateien von
mittlerweile ueber 40 verschiedenen Funktionen gemischt im selben flachen Ordner - die Anzahl der
Dateien darin wuchs entsprechend schnell. `Get-sqmServerHardwareReport` machte es von Anfang an
richtig (eigenes Unterverzeichnis `HardwareReports`); alle anderen schrieben direkt in die Wurzel.

33 weitere Funktionen (siehe Liste unten) bekommen jetzt jeweils ihr eigenes Unterverzeichnis nach
demselben Muster, z.B. `Get-sqmSysadminAccounts` -> `SysadminAccounts`, `Get-sqmDatabaseHealth` ->
`DatabaseHealth`. Die drei Listener-Migrationsschritte (`Prepare-sqmListenerForMigration`,
`Move-sqmAlwaysOnListener`, `Complete-sqmListenerMigration`) teilen sich bewusst EIN Verzeichnis
(`ListenerMigration`), da sie Phasen desselben Vorgangs sind. Reine Pfad-Aenderung an den jeweiligen
`-OutputPath`-Standardwerten, keine Aenderung an der Report-Erstellung selbst. Bereits vorhandene
Dateien im Wurzelordner bleiben unangetastet liegen - nur neue Laeufe landen im Unterordner.

Nebenbei vereinheitlicht: mehrere Funktionen nutzten bislang einen hartcodierten Pfad-String statt
der zentralen `Get-sqmDefaultOutputPath`, wodurch eine ueber `Set-sqmConfig` gesetzte abweichende
`OutputPath`-Konfiguration fuer sie ignoriert wurde. Jetzt einheitlich ueber die zentrale Funktion.

**Bugfix dabei gefunden**: `Get-sqmServerUtilization` legte sein Ausgabeverzeichnis nie selbst an -
das fiel nie auf, solange `$OutputPath` auf die (durch andere Funktionen laengst vorhandene) flache
Wurzel zeigte. Mit eigenem Unterverzeichnis schlug der erste Lauf mit "Could not find a part of the
path" fehl. Verzeichniserstellung ergaenzt, gegen DEV01 verifiziert.

Betroffene Funktionen (neues Unterverzeichnis in Klammern): Get-sqmSpnReport (SpnReports),
Get-sqmCertificateReport (CertificateReports), Get-sqmAgentJobScheduleReport (AgentJobSchedule),
Get-sqmAlwaysOnHealthReport (AlwaysOnHealth), Get-sqmDiskSpaceReport (DiskSpaceReports),
Compare-sqmServerConfiguration (ServerConfigCompare), Get-sqmADMemberGroups (ADMemberGroups),
Get-sqmDatabaseHealth (DatabaseHealth), Compare-sqmAlwaysOnRoles (AlwaysOnRoleCompare),
Get-sqmADGroupMembersRecursive + Get-sqmADGroupMembers (ADGroupMembers, geteilt - rekursive und
nicht-rekursive Variante desselben Reports), Get-sqmServerUtilization (ServerUtilization),
Compare-sqmAlwaysOnLogins (AlwaysOnLoginCompare), Get-sqmSysadminAccounts (SysadminAccounts),
Export-sqmAlwaysOnConfiguration (AlwaysOnConfiguration), Get-sqmDistributedAgHealth
(DistributedAgHealth), Export-sqmDatabaseDocumentation (DatabaseDocumentation),
Get-sqmServiceBrokerHealth (ServiceBrokerHealth), Invoke-sqmLoginAudit (LoginAudit),
Invoke-sqmSetupReport (SetupReports), Set-sqmDatabaseOwner (DatabaseOwnerChanges),
Enable-sqmServiceBroker (ServiceBroker), Invoke-sqmServiceBrokerAlwaysOn (ServiceBrokerAlwaysOn),
Invoke-sqmDistributedFailover (DistributedFailover), New-sqmDistributedAvailabilityGroup
(DistributedAG), Prepare-sqmListenerForMigration + Move-sqmAlwaysOnListener +
Complete-sqmListenerMigration (ListenerMigration, geteilt), Invoke-sqmAlwaysOnSetup
(AlwaysOnSetup), Invoke-sqmCollationChange (CollationChange), Invoke-sqmTsmConfiguration
(TsmConfiguration), Invoke-sqmSsisConfiguration (SsisConfiguration), Set-sqmSsrsConfiguration
(SsrsConfiguration), Install-sqmCertificate (CertInstall).

## [1.9.71.0] — 2026-08-07

### Feature: Get-sqmLoginSettings schreibt jetzt automatisch einen Bericht

Bisher gab `Get-sqmLoginSettings` nur Objekte zurueck; ein CSV+HTML-Export existierte, war aber
rein opt-in (nur bei explizit angegebenem `-OutputPath`), erzeugte keine TXT-Datei, und das HTML
war eine generische `ConvertTo-Html -Fragment`-Tabelle ohne jede farbliche Kennzeichnung - obwohl
die Funktion pro Login laengst ein `RiskLevel`/`RiskIcon` berechnet (Critical/Warning/OK/N-A).

`-OutputPath` hat jetzt einen Standardwert (`<Modul-Standardpfad>\LoginSettings` - eigenes
Unterverzeichnis, analog zu `Get-sqmServerHardwareReport`\HardwareReports) und der Bericht wird
bei jedem Aufruf automatisch geschrieben:
    LoginSettings_<instanzen>_<datum>.html   - nach RiskLevel farblich markiert (rot/gelb/gruen)
    LoginSettings_<instanzen>_<datum>.txt    - gruppiert nach Critical/Warning
    LoginSettings_<instanzen>_<datum>.csv    - maschinenlesbar
Rueckgabewert (flache Login-Objektliste) bleibt unveraendert - bestehende Aufrufe/Pipelines
brechen nicht.

Gegen DEV01 bestaetigt: HTML korrekt nach Risiko sortiert und eingefaerbt (Critical/Warning rot/
gelb, N/A ungefaerbt), TXT korrekt gruppiert, CSV vollstaendig.

## [1.9.70.0] — 2026-08-07

### Fix: Setup-Report zeigte JEDE Datenbank als "Never" gesichert, unabhaengig vom echten Stand

Die Datenbank-Tabelle in `Invoke-sqmSetupReport` las `$db.LastFullBackupDate` - diese Property
existiert auf dem SMO/dbatools-Datenbankobjekt gar nicht (richtiger Name: `LastBackupDate`). Der
Tippfehler warf keinen Fehler, PowerShell liefert bei einer nicht existierenden Property auf
diesem Objekttyp stillschweigend `$null` zurueck - `$lastBackup` war deshalb fuer JEDE Datenbank
auf JEDER Instanz immer `$null`, und die Spalte "Letzte Vollsicherung" zeigte ausnahmslos "Never",
auch wenn tatsaechlich taeglich gesichert wurde.

Zusaetzlich liefert SMO fuer eine Datenbank OHNE jede Vollsicherung nicht `$null`, sondern
`DateTime.MinValue` (01.01.0001) - ein "wahrer" Wert in PowerShell. Die reine Umbenennung auf
`LastBackupDate` haette fuer echte "nie gesicherte" Datenbanken deshalb eine astronomische
Tageszahl statt "Never" erzeugt; eine zusaetzliche `Year -gt 1900`-Prufung faengt das ab.

Gegen DEV01 bestaetigt: Datenbanken mit vorhandener Vollsicherung zeigen jetzt den echten
Tagesabstand ("4 days" statt immer "Never"), echte Nie-gesichert-Faelle zeigen weiterhin korrekt
"Never".

## [1.9.69.0] — 2026-08-07

### Fix: Get-sqmSpnReport meldete SPNs der AG-Partnerreplik als Unexpected

Folgefix zu 1.9.68.0: dieselbe Ursache (geteiltes Dienstkonto ueber alle AG-Repliken +
Listener), aber fuer die Partnerreplik selbst statt nur fuer den Listener. Der generische
Soll-/Ist-Vergleich kennt nur die 4 eigenen Instanz-SPNs - SPNs, die im `setspn -L`-Ergebnis
auftauchen, aber zu einer anderen Replik derselben AG gehoeren (z.B. `sfcsdbs104ihz` im Bericht
von `sfcsdbs103ihz`), wurden faelschlich als `Unexpected` gemeldet, obwohl das im AG-Kontext mit
geteiltem Dienstkonto normal und korrekt ist.

`Get-sqmSpnReport` ermittelt jetzt zusaetzlich ueber `sys.availability_replicas` die
Partnerrepliken der lokalen AG(s) und erkennt SPNs, deren Host-Anteil zu einer Partnerreplik
gehoert, als `OK` mit erklaerendem Hinweis ("AlwaysOn Partner-SPN (Replik: ..., gemeinsames
Dienstkonto) - kein Handlungsbedarf."). Die dabei entstehende veraltete generische
`Unexpected`-Zeile fuer dieselbe SPN wird durch dieselbe Bereinigung wie in 1.9.68.0 entfernt
(jetzt erweitert um das Partner-SPN-Notat). Echte, nicht einer bekannten Replik oder dem Listener
zuordenbare Fremd-SPNs werden weiterhin als `Unexpected` gemeldet.

## [1.9.68.0] — 2026-08-07

### Fix: Get-sqmSpnReport zeigte Listener-SPNs doppelt mit widerspruechlichem Status

Bei einer AlwaysOn-Instanz, deren Repliken und Listener dasselbe Dienstkonto nutzen (Kerberos
zum Listener setzt das praktisch voraus), liefert `setspn -L` fuer dieses eine Konto auch die
SPNs der anderen Repliken und des Listeners zurueck. Der generische Soll-/Ist-Vergleich kennt
aber nur die 4 eigenen Instanz-SPNs und markierte alles andere - inklusive der Listener-SPNs -
pauschal als `Unexpected`. Der separate, spaeter laufende AG-Listener-Check bewertete dieselben
SPNs anschliessend korrekt gegen die Listener-Erwartungsliste (`OK`/`Missing`), fuegte dafuer aber
nur eine ZUSAETZLICHE Zeile hinzu statt die aeltere zu ersetzen - dieselbe SPN stand danach
zweimal im Bericht, einmal `[Unexpected]` und einmal `[OK]`.

Beispiel (2-Knoten-AG, Listener `LFCS20DBSQL1`, geteiltes Dienstkonto):

```
MSSQLSvc/LFCS20DBSQL1:1433 [Unexpected]   <- generischer Vergleich, kennt Listener-SPNs nicht
MSSQLSvc/LFCS20DBSQL1:1433 [OK]           <- Listener-Check, korrekt
```

Nach dem Listener-Check wird jetzt die veraltete generische `Unexpected`-Zeile fuer jede SPN
entfernt, die der Listener-Check bereits eigenstaendig bewertet hat - die praezisere
Listener-Bewertung bleibt als einzige Zeile stehen. Echte Fremd-SPNs (z.B. der anderen AG-Replik)
werden weiterhin unveraendert als `Unexpected` gemeldet.

## [1.9.67.0] — 2026-08-07

### Fix: FI-TS-Installation synchronisierte dbatools bei JEDER Installation neu, auch wenn aktuell

Im FITS-Zweig von `Install.ps1` (Quelle `W:\...` bzw. `\\tsclient\W\...`) lief `robocopy ... /MIR`
fuer `dbatools` und `dbatools.library` bislang bedingungslos bei jeder Installation - anders als
der PSGallery-Zweig gab es keinen "ist eh schon aktuell"-Kurzschluss. `/MIR` muss dafuer den
kompletten Dateibaum auf beiden Seiten enumerieren und vergleichen (dbatools: mehrere tausend
kleine `.ps1`-Dateien), ueber die Citrix-Freigabe `\\tsclient\W\` mit spuerbarer Latenz pro Datei -
das dauerte lange, selbst wenn am Ende nichts zu kopieren war.

Jetzt wird vorab die hoechste Versions-Ordnernummer auf Quelle und Ziel verglichen
(`Get-sqmModuleFolderVersion`); stimmen sie ueberein, wird robocopy fuer das jeweilige Modul
komplett uebersprungen. Muss synchronisiert werden (fehlende/veraltete Installation), laeuft
robocopy zusaetzlich mit `/MT:8` (Multithread) statt seriell.

## [1.9.66.0] — 2026-08-07

### Fix: SQL-Browser-Check meldete laufenden/gestoppten Dienst als "nicht installiert"

`sys.dm_server_services` listet nur den SQL Server-, Agent- und ggf. Full-Text-Dienst DER
VERBUNDENEN INSTANZ - der SQL Server Browser ist maschinenweit und taucht dort NIE auf. Die in
1.9.65.0 eingefuehrte Abfrage (`servicename LIKE '%Browser%'`) lieferte deshalb *immer* 0 Zeilen
und meldete den Browser dauerhaft als "OK (nicht installiert)", unabhaengig vom tatsaechlichen
Zustand - auch wenn er lief oder nur gestoppt/deaktiviert war.

Gegen DEV01 bestaetigt: `sys.dm_server_services` zeigt dort ausschliesslich Engine + Agent, kein
Browser-Eintrag, obwohl der Dienst laeuft (Start: Automatic).

Ersetzt durch `xp_servicecontrol N'QUERYSTATE', N'SQLBROWSER'` fuer den Laufzustand und
`xp_regread` gegen `HKLM\SYSTEM\CurrentControlSet\Services\SQLBrowser\Start` fuer den Starttyp -
beides weiterhin ohne WinRM, ueber die bestehende SQL-Verbindung.

## [1.9.65.0] — 2026-08-06

### Feature: SQL-Browser-Dienststatus im Setup-Report

`Invoke-sqmSetupReport` prueft jetzt zusaetzlich den Status des SQL Server Browser-Dienstes
(`sys.dm_server_services`, `servicename LIKE '%Browser%'`) und weist ihn im Abschnitt
"Server-Level Features" aus. Laeuft der Dienst, erscheint eine Warnung (orange): der Browser
ermoeglicht per UDP 1434 das Auffinden benannter Instanzen und ihrer dynamischen Ports im
Netzwerk und ist nur fuer genau diesen Fall noetig - laeuft er unnoetig mit, ist das ein
zusaetzlicher Angriffsvektor zur Instanz-Enumeration. Ist er gestoppt oder nicht installiert,
erscheint OK (gruen).

## [1.9.64.0] — 2026-08-05

### Fix: PBM-Policy-Handling scheiterte unter PowerShell 7 STILLSCHWEIGEND

Die dbatools-PBM-Cmdlets setzen den SMO-PolicyStore voraus und brechen unter PowerShell 7 mit
"Get-DbaPbmStore: This command is not supported on Linux or macOS" ab. Zusammen mit
`-ErrorAction SilentlyContinue` bzw. der `-ContinueOnError`-Auswertung fuehrte das zu einem
lautlosen Fehlschlag: die Policy wurde nie deaktiviert, der Aufrufer lief ungeschuetzt weiter.

Gegen DEV01 unter beiden Versionen gemessen (identisches Skript, identische Instanz):

| | PowerShell 5.1 | PowerShell 7 |
|---|---|---|
| Policy nach Disable | `is_enabled=0` | **unveraendert `1`** |
| `syspolicy_server_trigger` | von PBM entfernt | bleibt bestehen |
| `CREATE LOGIN ... FROM WINDOWS` | erfolgreich | **blockiert** |

Bemerkenswert dabei (und ebenfalls verifiziert): SQL Server entfernt den
`syspolicy_server_trigger` automatisch, sobald keine aktivierte "On Change: Prevent"-Policy mehr
existiert, und legt ihn beim Aktivieren neu an - die Trigger-Existenz wird von PBM selbst
verwaltet.

Fix: `Set-sqmSqlPolicyState` nutzt jetzt ausschliesslich T-SQL (`msdb.dbo.syspolicy_policies` zum
Pruefen, `msdb.dbo.sp_syspolicy_update_policy` zum Umschalten) statt der dbatools-PBM-Cmdlets,
inklusive Verifikation des Ergebnisses statt "keine Exception = Erfolg". Verhaelt sich unter
PS 5.1 und PS 7 identisch - beide Wege gegen DEV01 nachgewiesen.

Vollstaendiges Audit des Moduls auf weitere Betroffene: dbatools 2.8.2 sperrt genau 6 Befehle
ausserhalb der Windows PowerShell (`Copy-DbaSsisCatalog`, `Export-DbaCredential`,
`Export-DbaLinkedServer`, `Get-DbaPbmStore`, `Get-DbaSsisEnvironmentVariable`,
`New-DbaSsisCatalog`). Davon nutzt sqmSQLTool nur den PBM-Pfad, an genau zwei Stellen:
`Set-sqmSqlPolicyState` (oben) und `Invoke-sqmRestoreDatabase` (Policy-Deaktivierung vor dem
Restore, dort ebenfalls mit `-ErrorAction SilentlyContinue` und damit lautlos) - beide auf die
Katalogsicht umgestellt. Die uebrigen vier Befehle kommen im Modul nicht vor.

## [1.9.63.0] — 2026-08-05

### Neu: Warnung, wenn die "temporaere" Rolle in Wahrheit dauerhaft ueber eine Gruppe besteht

Auf DWP1W02SQLT0001 stellte sich heraus, dass die betroffenen Logins die sysadmin-Rolle bereits
ueber AD-Gruppenmitgliedschaft besassen. Das hat eine Konsequenz, die ueber den Bug aus 1.9.61.0
hinausgeht und die Kernzusage dieser Funktion beruehrt: `ALTER SERVER ROLE ... DROP MEMBER`
entfernt beim Entzug nur die DIREKTE Mitgliedschaft. Eine ueber eine Gruppe geerbte Berechtigung
bleibt danach unveraendert bestehen - die zeitliche Befristung waere also nur scheinbar gegeben,
und niemand haette es bemerkt, weil das Tool sauberen Erfolg meldete.

Neu in `Invoke-sqmTempSysadminAction`:
- Beim Grant wird vorab geprueft, ob die Rolle bereits ueber einen anderen Pfad wirksam ist
  (effektiv ja, direkt nein). Ist das so, wird die zusaetzliche direkte Mitgliedschaft zwar
  vergeben (sie schafft einen sauberen, befristeten Audit-Eintrag), aber mit einer WARNUNG in
  Logfile und Eventlog (EventId 9011) versehen, dass die geerbte Berechtigung davon unberuehrt
  bleibt.
- Beim Revoke wird NACH dem Entzug geprueft, ob der Login weiterhin effektiv Mitglied ist. Falls
  ja, warnt das Tool ausdruecklich (Logfile + Eventlog, EventId 9012), dass die privilegierten
  Rechte NICHT beendet wurden und dafuer die Gruppenmitgliedschaft angepasst werden muss.

Bewusst als Warnung und nicht als Abbruch umgesetzt: die zusaetzliche direkte Mitgliedschaft ist
fuer die Nachvollziehbarkeit (wer war wann per Ticket erhoeht) durchaus sinnvoll - sie darf nur
nicht mit einer echten Befristung verwechselt werden.

Verifiziert gegen DEV01, dass der Normalfall (keine geerbten Rechte) unveraendert und ohne
Fehlalarm durchlaeuft. Der geerbte Fall selbst liess sich in der Testumgebung nicht nachstellen
(Workgroup, keine Domaene, kein `BUILTIN\Administrators`-Login) - die Einzelbausteine der
Erkennung (`IS_SRVROLEMEMBER()` effektiv, Katalogsicht direkt) sind aber jeweils belegt.

## [1.9.62.0] — 2026-08-05

### Fix: `Get-sqmLoginSettings` untertrieb sysadmin-Privilegien, die ueber AD-Gruppen geerbt sind

Direkte Folge der Erkenntnis aus 1.9.61.0: die `IsSysAdmin`-Spalte pruefte ausschliesslich die
direkte Mitgliedschaft (`sys.server_role_members`). Ein Login, das nur ueber eine Windows-/
AD-Gruppe sysadmin ist, taucht dort gar nicht auf - der Sicherheitsreport wies ihn also als
harmlos aus, obwohl er dieselben Vollrechte hat. Fuer einen Report, dessen Zweck das Aufspueren
privilegierter Konten ist, ist das die gefaehrlichere Fehlrichtung.

Umgestellt auf "privilegiert ueber IRGENDEINEN Pfad" - bewusst die Kombination beider Quellen
statt eines simplen Austauschs, weil beide je nach Richtung untertreiben:
`IS_SRVROLEMEMBER()` erfasst die Vererbung ueber Gruppen, liefert aber seinerseits `0` fuer
manche direkten Mitglieder (auf DEV01 mit `NT Service\MSSQLSERVER` reproduziert);
`sys.server_role_members` erfasst nur direkte Mitgliedschaft. `IsSysAdmin` ist jetzt wahr, wenn
eine der beiden Quellen anschlaegt (`ISNULL()`-gesichert, damit nicht aufloesbare Logins - z.B.
verwaiste AD-Konten, `IS_SRVROLEMEMBER()` liefert dann NULL - nicht faelschlich als privilegiert
gelten).

Neue Spalte `IsSysAdminDirect` weist die direkte Mitgliedschaft weiterhin separat aus. Weichen
beide ab (`IsSysAdmin=True`, `IsSysAdminDirect=False`), sind die Rechte ueber eine Gruppe geerbt
und lassen sich nicht per `ALTER SERVER ROLE ... DROP MEMBER` am Login selbst entziehen, sondern
nur ueber die Gruppenmitgliedschaft - eine betrieblich wichtige Unterscheidung. `RiskLevel`
bewertet weiterhin auf Basis von `IsSysAdmin`, jetzt also inklusive geerbter Privilegien.

Verifiziert gegen DEV01: `NT Service\MSSQLSERVER` wird korrekt als `IsSysAdmin=True` erkannt,
obwohl `IS_SRVROLEMEMBER()` dafuer `0` liefert. Der umgekehrte Fall (nur ueber AD-Gruppe geerbt)
liess sich mangels Domaene in der Testumgebung nicht live nachstellen.

## [1.9.61.0] — 2026-08-05

### Fix (Ursache gefunden): `IS_SRVROLEMEMBER()` prueft EFFEKTIVE, nicht direkte Rollenmitgliedschaft

Das ist die eigentliche Ursache hinter "kein Fehler, Log sagt erfolgreich, trotzdem kein sysadmin"
auf DWP1W02SQLT0001 - und auch hinter allen vorherigen Fehlversuchen in dieser Reihe.

`IS_SRVROLEMEMBER('sysadmin', N'<Login>')` liefert die EFFEKTIVE Mitgliedschaft **inklusive
Vererbung ueber Windows-/AD-Gruppen**. Ist der Login Mitglied einer AD-Gruppe, die ihrerseits als
sysadmin-Login auf der Instanz eingetragen ist, liefert die Funktion bereits `1`, obwohl der Login
selbst NIE direkt in die Serverrolle aufgenommen wurde. Die bedingte Anweisung
`IF IS_SRVROLEMEMBER(...) = 0 ALTER SERVER ROLE ... ADD MEMBER` wurde dadurch uebersprungen -
ohne Fehler, ohne Effekt. Die in 1.9.60.0 ergaenzte Verifikation nutzte dieselbe Funktion und
bestaetigte den Trugschluss deshalb nur (`SELECT IS_SRVROLEMEMBER(...)` = 1, obwohl keine direkte
Mitgliedschaft bestand).

Die beiden Semantiken weichen nachweislich voneinander ab - gegen DEV01 in BEIDE Richtungen
reproduziert: `NT Service\MSSQLSERVER` ist direktes Mitglied von sysadmin
(`sys.server_role_members`), waehrend `IS_SRVROLEMEMBER()` dafuer `0` liefert.

Fix: sowohl die Bedingung als auch die Verifikation in `Invoke-sqmTempSysadminAction` pruefen
jetzt die DIREKTE Mitgliedschaft ueber `sys.server_role_members` (JOIN auf
`sys.server_principals`) statt `IS_SRVROLEMEMBER()`. Fuer "diesen Login temporaer in die Rolle
aufnehmen bzw. daraus entfernen" ist ausschliesslich die direkte Mitgliedschaft massgeblich -
eine ueber eine AD-Gruppe geerbte Berechtigung liesse sich per `DROP MEMBER` ohnehin nicht
entziehen. Als Nebeneffekt entfaellt die NULL-Sonderbehandlung: die neue Bedingung liefert immer
`0` oder `1`, nie `NULL`.

Verifiziert gegen DEV01: Grant -> direkte Mitgliedschaft 1, erneuter Grant (idempotent)
erfolgreich, Revoke -> 0, erneuter Revoke (idempotent) erfolgreich.

## [1.9.60.0] — 2026-08-05

### Fix: `Invoke-sqmTempSysadminAction` meldete Erfolg, obwohl die Rolle nie vergeben wurde

Auf DWP1W02SQLT0001 beobachtet: kein Fehler, der Revoke-Job wird angelegt, aber die Rolle war
danach nachweislich nicht vergeben. Ursache: die Grant-/Revoke-Anweisung ist bedingt (`IF
IS_SRVROLEMEMBER('$Role', N'$Login') = 0 ALTER SERVER ROLE ... ADD MEMBER ...`) -
`IS_SRVROLEMEMBER()` liefert laut Doku `NULL` statt `0`/`1`, wenn es Login oder Rolle nicht
eindeutig aufloesen kann (gegen DEV01 bestaetigt: liefert NULL fuer einen nicht auflösbaren
Login). `NULL = 0` ist in T-SQL weder wahr noch falsch, das IF wird dann STILLSCHWEIGEND
uebersprungen, ohne dass `ALTER SERVER ROLE` je laeuft und ohne dass eine Exception entsteht -
`Invoke-DbaQuery -EnableException` wirft nur bei echten SQL-Fehlern, ein uebersprungenes IF ist
kein Fehler. Der Code vertraute bisher ausschliesslich auf "keine Exception = Erfolg", genau das
Muster, das dieses Modul schon mehrfach eingeholt hat (siehe 1.9.43.0/1.9.44.0,
`Remove-DbaDatabase` bei `Invoke-sqmRestoreDatabase`).

Fix: nach der Grant-/Revoke-Anweisung wird `IS_SRVROLEMEMBER()` explizit nachgeprueft; weicht das
Ergebnis vom erwarteten Zustand ab (inkl. `NULL`), wirft die Funktion jetzt einen expliziten
Fehler mit der vermuteten Ursache, statt faelschlich Erfolg zu meldem. Regressionsgetestet gegen
DEV01 (normaler Grant+Revoke-Rundlauf funktioniert weiterhin unveraendert), NULL-Verhalten von
`IS_SRVROLEMEMBER()` fuer einen nicht aufloesbaren Login separat verifiziert.

## [1.9.59.0] — 2026-08-05

### Fix: sysadmin-Grant scheiterte trotz deaktivierter Policy - alle Server-Trigger statt nur eine Policy deaktivieren

Nachtrag zu 1.9.53.0/1.9.54.0: auf DWP1W02SQLT0001 manuell vorab deaktiviert getestet ("New
Login_Enforce Passwort Policy" aus, unser Code also gar nicht im Spiel) - der Grant scheiterte
trotzdem identisch am selben Trigger-Rollback. Damit war ausgeschlossen, dass es an unserer
`DisablePolicy`-Logik liegt: entweder eine ZWEITE, aktive Policy mit demselben Auswertungsmodus,
oder der Trigger-Mechanismus selbst - in beiden Faellen hilft das gezielte Deaktivieren einer
einzelnen benannten Policy nicht.

Gegen DEV01 mit einem synthetischen Test-Trigger (FOR ALTER_LOGIN, CREATE_LOGIN, ROLLBACK)
nachgestellt und verifiziert, dass ein Policy-unabhaengiger Trigger genau den gemeldeten Fehler
reproduziert ("The transaction ended in the trigger. The batch has been aborted." bzw. "Die
Transaktion endete mit dem Trigger.").

Fix: `Invoke-sqmTempSysadminAction` deaktiviert jetzt zusaetzlich (Default `-DisableServerTriggers
$true`) ALLE aktuell aktivierten serverweiten DDL-Trigger fuer die Dauer der Aktion und stellt in
einem finally-Block GENAU den vorherigen Zustand wieder her (kein pauschales "alle wieder an") -
unabhaengig davon, welche/wie viele Policies aktiv sind oder ob der Trigger CREATE LOGIN,
ALTER SERVER ROLE oder etwas anderes abfaengt. Die bisherige `DisablePolicy`-Logik bleibt als
zweite, unabhaengige Absicherung bestehen. Ein fehlgeschlagenes Wiederaktivieren eines Triggers
wird zusaetzlich als Eventlog-Fehler eskaliert (Governance-relevant).

### Neu: SQL-Logins UND `dbcreator`-Rolle zusaetzlich zu Windows-Logins/sysadmin

`Grant-sqmTemporarySysadmin`/`Invoke-sqmTempSysadminAction` unterstuetzten bisher ausschliesslich
Windows-/AD-Logins und ausschliesslich die sysadmin-Rolle. Neu:

- Neuer Parameter `-Role` ('sysadmin' Default, oder 'dbcreator') auf beiden Funktionen - die
  ALTER SERVER ROLE-Anweisung ist jetzt parametrisiert statt fest auf `[sysadmin]` verdrahtet.
- Bereits vorhandene SQL-Auth-Logins koennen jetzt ebenfalls temporaer eine Rolle erhalten (nicht
  nur Windows-/AD-Logins) - automatisches Anlegen bei Fehlen (`-CreateLoginIfMissing`) bleibt auf
  Windows-/AD-Logins beschraenkt (CREATE LOGIN ... FROM WINDOWS ergibt fuer SQL-Logins keinen
  Sinn ohne Kennwortvorgabe), mit klarer Fehlermeldung statt stillschweigendem Fehlschlag.
- Job-Namen enthalten jetzt die Rolle (`sqmTempDbcreator_...` statt nur `sqmTempSysadmin_...`),
  damit z.B. ein temporaeres sysadmin und ein temporaeres dbcreator fuer denselben Login
  nebeneinander bestehen koennen.

Verifiziert gegen DEV01: `-Role dbcreator` fuer einen bestehenden SQL-Login (`sqmTestLogin`) im
vollen Grant+Revoke-Rundlauf (inkl. Trigger-Deaktivierung/-Wiederherstellung), sowie
`Grant-sqmTemporarySysadmin` akzeptiert einen bloßen SQL-Loginnamen jetzt ohne den frueheren
Windows-Format-Fehler.

## [1.9.58.0] — 2026-08-05

### Fix: `Install.ps1` scheiterte unter PowerShell 5.1 beim Lesen des dbatools-Versions-Caps

Nachtrag zu 1.9.55.0: `Select-Object -ExpandProperty MaximumVersion` auf einem
`RequiredModules`-Eintrag (eine Hashtable) warf unter echtem `powershell.exe` 5.1 "Die
MaximumVersion-Eigenschaft kann nicht gefunden werden." - `-ExpandProperty` findet Hashtable-Keys
in Windows PowerShell 5.1 nicht (Adapter-Unterschied), waehrend derselbe Code unter PowerShell 7
klaglos durchlief. Genau die Art Bug, die beim Entwickeln/Testen unter `pwsh` unsichtbar bleibt -
der Import-Test des pre-push-Hooks laeuft zwar unter echtem PS 5.1, fuehrt `Install.ps1` selbst
aber nicht aus, daher ist das durchgerutscht.

Fix: direkter Punkt-Zugriff (`.MaximumVersion`) auf das per `Select-Object -First 1` gefilterte
Objekt statt `-ExpandProperty` - funktioniert in beiden PowerShell-Versionen. Gesamte
dbatools-Versionspruefung end-to-end unter echtem `powershell.exe` 5.1 (5.1.26100.8875)
nachgestellt und verifiziert (Cap-Ermittlung, installierte Version, PSGallery-Vergleich).

## [1.9.57.0] — 2026-08-05

### Neu: `DbatoolsSharePath`-Konfigurationsschluessel fuer die dbatools-Freigabe

Nachtrag zu 1.9.56.0: der Pfad zur FI-TS-Freigabe mit der dbatools + dbatools.library-Baseline
wurde bisher implizit aus `-Source` hergeleitet (Geschwisterordner `Modules` neben `Tools`) -
funktioniert nur, wenn diese Ordnerkonvention exakt so vorliegt, und laesst sich nicht explizit
setzen/uebersteuern.

Neu: `Set-sqmConfig -DbatoolsSharePath '<Pfad>'` (neutraler Default `$null`, FI-TS-Default
`W:\75084-Datenbanken\MSSQL\SQLSources\Modules` - analog zum bereits vorhandenen
`SsrsInstallerPath`). `Install.ps1` Schritt 5b liest diesen Key jetzt vorrangig (direkt aus
`config.json`, da das Modul an dieser Stelle noch nicht importiert ist - dbatools muss zuerst da
sein) und faellt nur auf die bisherige Herleitung zurueck, wenn der Key noch nicht gesetzt ist.
Nach erfolgreichem Modulimport wird ein neu ermittelter Pfad automatisch in die Konfiguration
zurueckgeschrieben (Schritt 6a) - kuenftige Installationen und andere Modulfunktionen finden ihn
dann direkt ueber `Get-sqmConfig`, ohne ihn erneut herzuleiten.

Verifiziert: Default leer ausserhalb FI-TS, `Set-sqmConfig` persistiert korrekt nach
`config.json`, Wert bleibt nach einem frischen Modul-Reimport erhalten. Direktes
config.json-Parsing (Schluessel fehlt / ist `null` / ist gesetzt) fuer alle drei Faelle geprueft.

## [1.9.56.0] — 2026-08-05

### Fix: dbatools-Update in FITS-Umgebungen von PSGallery auf Freigabelaufwerk-Sideload umgestellt

Nachtrag zu 1.9.55.0: der dortige PSGallery-basierte Versionscheck ist fuer FI-TS-gehostete
Instanzen (wie DWP1W02SQLT0001) der falsche Weg - PSGallery ist auf einer abgeschotteten
Produktivinstanz nicht erreichbar. Unter `<SQLSources>\Modules` (Geschwisterordner von `Tools`,
wo `sqmSQLTool` selbst per UNC-Installation herkommt) liegt dort bereits ein von FI-TS gepflegtes,
fertiges Ordnerpaar `dbatools` + `dbatools.library` (das binaere Begleitmodul von dbatools 2.x).

Fix: Schritt 5b erkennt eine FITS-Installation jetzt VOR dem PSGallery-Zweig (gleiche Erkennung
wie die bestehende FI-TS-Konfiguration in Schritt 7 - `$isFitsInstall` wird jetzt einmalig
berechnet und in beiden Schritten wiederverwendet statt dupliziert). Ist der abgeleitete
`Modules`-Pfad relativ zu `-Source` vorhanden und enthaelt beide Ordner, werden `dbatools` und
`dbatools.library` per `robocopy /MIR` in den Ziel-Scope gespiegelt - PSGallery bleibt der Weg
fuer alle anderen (Nicht-FITS-)Umgebungen. Pfad-Ableitung gegen die reale
`InstallSourcePath`-Konfiguration von DWP1W02SQLT0001 verifiziert
(`\\tsclient\W\75084-Datenbanken\MSSQL\SQLSources\Tools\sqmSQLTool-main` ->
`...\SQLSources\Modules`, exakter Treffer).

## [1.9.55.0] — 2026-08-05

### Neu: `Grant-sqmTemporarySysadmin` fragt standardmaessig nicht mehr interaktiv nach

`ConfirmImpact = 'High'` liess PowerShell bei jedem Aufruf automatisch die "Moechten Sie diesen
Vorgang ausfuehren?"-Rueckfrage einblenden (Default `$ConfirmPreference = 'High'`) - Reibung bei
ticketbasierten oder skriptgesteuerten Aufrufen (z.B. aus einer Automatisierung ohne interaktive
Session, wo die Abfrage schlicht haengen bleiben wuerde). `-TicketNumber` ist bereits der Nachweis
einer bewussten Entscheidung.

Fix: `$ConfirmPreference = 'None'` intern gesetzt - `ConfirmImpact = 'High'` bleibt als Metadatum
bestehen (weiterhin zurecht als hochriskante Aktion dokumentiert), aber es wird nicht mehr
automatisch nachgefragt. `-WhatIf` funktioniert unveraendert; wer die Rueckfrage bewusst will,
kann `-Confirm` explizit anhaengen. Verifiziert gegen DEV01: `-WhatIf` zeigt weiterhin die Absicht
ohne Aenderung, ein echter Aufruf ohne `-Confirm` laeuft ohne Prompt/Haengenbleiben durch.

### Neu: `Install.ps1` erkennt und aktualisiert veraltete dbatools-Installationen

Auf DWP1W02SQLT0001 stand seit 2022 unbemerkt dbatools 1.1.95 - mehrere Major-Versionen veraltet,
sehr wahrscheinlich Ursache fuer eine abweichende `Get-DbaPbmPolicy`-Rueckgabeform, die aeltere
Codepfade in `Set-sqmSqlPolicyState` nicht abdeckten. Die bisherige Pruefung war rein binaer
("Ordner vorhanden -> ok") und haette das nie aufgedeckt, unabhaengig davon wie alt die Version war.

Fix: Schritt 5b prueft jetzt zusaetzlich die installierte Version gegen die auf PSGallery neueste
verfuegbare (innerhalb des bestehenden `MaximumVersion`-Caps aus `RequiredModules`, liest also den
Cap direkt aus `sqmSQLTool.psd1` statt ihn zu duplizieren) und aktualisiert bei Rueckstand
automatisch. Ist PSGallery nicht erreichbar (typisch fuer eine abgeschottete Produktivinstanz),
wird die erkannte installierte Version als Warnung ausgegeben statt stillschweigend als "ok"
durchzugehen. Verifiziert (Versionserkennung + PSGallery-Vergleich) gegen die hier installierte
dbatools 2.8.2 - erkannte korrekt 2.8.4 als neuere verfuegbare Version.

## [1.9.54.0] — 2026-08-05

### Fix: `Invoke-sqmTempSysadminAction` - Fehlschlag der Policy-Deaktivierung war unsichtbar

Nachtrag zu 1.9.53.0: auf DWP1W02SQLT0001 (`DefaultPolicy` korrekt auf 'New Login_Enforce
Passwort Policy' gesetzt, passend zum dort per `sp_syspolicy_add_policy` angelegten Server/Login-
Facet und dem serverweiten `syspolicy_server_trigger FOR ALTER_LOGIN, CREATE_LOGIN` - `ALTER SERVER
ROLE ADD MEMBER` loest intern ebenfalls ein `ALTER_LOGIN`-Ereignis aus, der Trigger sollte also
weiterhin feuern) schlug der sysadmin-Grant trotz 1.9.53.0 weiterhin fehl.

`Set-sqmSqlPolicyState -State Disable` wurde bisher mit `-ContinueOnError` aufgerufen: schlaegt das
Deaktivieren selbst fehl (z.B. Berechtigung, dbatools/SMO-Eigenheit), wurde das bisher komplett
stillschweigend uebersprungen - kein Log-Eintrag, keine Warnung. Der anschliessende sysadmin-Grant
lief dann gegen die weiterhin aktive Policy und scheiterte am selben Trigger-Rollback wie ganz ohne
Deaktivierungsversuch, ohne dass aus dem Log je erkennbar war, WARUM die Deaktivierung nicht griff.

Fix: der Rueckgabewert von `Set-sqmSqlPolicyState` wird jetzt in jedem Fall ausgewertet - bei
Status ungleich 'Success' wird eine WARNUNG mit der eigentlichen Fehlermeldung geloggt, bevor der
Grant/Revoke-Versuch trotzdem weiterlaeuft. Regressionstest (Grant + Revoke Rundlauf) erneut gegen
DEV01 verifiziert.

## [1.9.53.0] — 2026-08-05

### Fix: `Invoke-sqmTempSysadminAction` scheiterte auf Instanzen mit "On Change: Prevent"-PBM-Policy an ALTER SERVER ROLE

Auf DWP1W02SQLT0001 (DWPBANK-PROD) schlug `Grant-sqmTemporarySysadmin` fehl mit "The transaction
ended in the trigger. The batch has been aborted." - Ursache: der eingebaute
`syspolicy_server_trigger` (Policy-Based Management) fing die `ALTER SERVER ROLE [sysadmin] ADD
MEMBER`-Anweisung ab und rollte sie zurueck, weil dort eine Policy mit Auswertungsmodus
"On Change: Prevent" aktiv ist. Kein Kennwortrichtlinien-Thema (der betroffene Login ist ohnehin
ein Windows-/AD-Login, fuer den SQL Server gar keine Kennwortrichtlinie fuehrt) - dieser
serverweite Trigger kann JEDE `DDL_SERVER_LEVEL_EVENTS`-Anweisung abfangen.

Der Bug: die vorhandene Policy-Deaktivierung (`DefaultPolicy` via `Set-sqmSqlPolicyState`) war nur
um das optionale `CREATE LOGIN` gelegt, nicht um `ALTER SERVER ROLE ADD/DROP MEMBER` oder
`DROP LOGIN` - also nicht um die eigentliche sysadmin-Vergabe/-Entziehung selbst. Schwerwiegender
als der Grant-Fehlschlag: der automatische Revoke-Job Tage spaeter waere auf einer solchen Instanz
genauso gescheitert und haette sich (Job wird bei Fehler bewusst NICHT geloescht) nicht selbst
entfernt - der Login waere unbefristet sysadmin geblieben.

Fix: die Policy-Deaktivierung umschliesst jetzt die GESAMTE Grant-/Revoke-Aktion (Login-Anlage +
Rollenaenderung + optionales Login-Entfernen), garantiert wieder aktiviert per `finally` auch bei
Fehlern. Regressionstest (Grant + Revoke Rundlauf) gegen DEV01 verifiziert - DEV01 hat selbst keine
PBM-Policy konfiguriert, das eigentliche Trigger-Szenario liess sich also nur indirekt bestaetigen
(Root Cause + Fix-Scope, nicht der volle Fehlerfall selbst).

## [1.9.52.0] — 2026-08-05

### Neu: `Get-sqmLoginSettings` mit sysadmin-Mitgliedschaft und Sicherheitsampel (RiskLevel/RiskIcon)

Bisher zeigte der Report nur die rohen Kennwort-Einstellungen, ohne einzuordnen, wie kritisch eine
Abweichung tatsaechlich ist - ein deaktivierter Kennwortablauf bei einem sysadmin-Login ist ein
ganz anderes Risiko als bei einem eingeschraenkten Konto.

Neu: `IsSysAdmin` (Mitgliedschaft in der festen Serverrolle sysadmin, via `sys.server_role_members`
+ `sys.server_principals` - gilt fuer SQL- UND Windows-Logins/-Gruppen gleichermassen) sowie ein
daraus abgeleitetes `RiskLevel` ('Critical' / 'Warning' / 'OK' / 'N/A') mit kompaktem `RiskIcon`
(🔴/🟡/🟢/⚪) fuer eine schnelle visuelle Einordnung, wenn Text in der Tabelle/dem Report zu lang
wird: Kennwort-Richtlinie oder -Ablauf deaktiviert bei einem sysadmin-Login ist Critical, beim
Nicht-sysadmin nur Warning, ohne Abweichung OK. Gilt nur fuer SQL-Logins - bei Windows-Logins/
-Gruppen greift die Kennwortrichtlinie von AD statt SQL Server, dort N/A statt eines falschen
Befundes (unabhaengig von deren sysadmin-Mitgliedschaft, die durchaus haeufig ist, z.B. die
SQL-Dienstkonten selbst).

Gegen DEV01 verifiziert: `dev`/`sa` (sysadmin, Policy+Expiration aus) → Critical, `sqmTestLogin`
(kein sysadmin, gleiche Einstellungen) → Warning, alle Windows-Logins/-Gruppen (inkl. sysadmin-
Mitgliedern wie den SQL-Dienstkonten) → N/A statt Fehlklassifikation.

## [1.9.51.0] — 2026-08-05

### Fix: `Start-sqmToolGui.cmd` - fragilen zweiten Elevation-Hop entfernt

Nachtrag zu 1.9.50.0: auf DEV03 direkt aus einer bereits elevated Shell gestartet lief
`Start-sqmToolGui.ps1` (`powershell -File ...`) einwandfrei durch - der UAC-Doppelklick-Weg
brach aber weiterhin kommentarlos ab. Eingrenzung damit auf die Elevation-Kette selbst: der
bisherige Weg elevierte `cmd.exe` (`Start-Process cmd.exe -ArgumentList '/c "..."' -Verb RunAs`),
das dann `Start-sqmToolGui.cmd` von vorn komplett neu durchlief (zweiter `net session`-Check,
dann erst der eigentliche `powershell -File`-Aufruf) - irgendwo in diesem zweiten Hop brach es ab,
ohne dass unsere eigene Fehlerbehandlung in `Start-sqmToolGui.ps1` je erreicht wurde (die griff ja
erst NACH diesem Hop).

Fix: `powershell.exe` wird jetzt direkt elevated (`Start-Process powershell.exe -ArgumentList
'... -File "..."' -Verb RunAs`), nicht mehr ueber ein sich selbst neu aufrufendes `cmd.exe`. Der
elevated Pfad ist damit strukturell identisch zu dem bereits erfolgreich getesteten manuellen
Aufruf aus einer elevated Shell - nur die Elevation selbst kommt jetzt per UAC statt manuell.

## [1.9.50.0] — 2026-08-05

### Fix: `Start-sqmToolGui.cmd` konnte auf DEV03 nach dem UAC-"Zulassen" kommentarlos beenden

Funktionierte in der Produktionsumgebung, auf DEV03 dagegen: UAC-Abfrage erscheint, kurzes
Fensteraufblitzen, dann nichts mehr - ohne Fehlermeldung. Ursache liess sich von hier aus nicht
live nachstellen (kein interaktiver Desktop-Zugriff, eigene Tool-Sessions laufen nicht elevated),
aber der bisherige Code hatte eine bekannte Luecke: das `try { Import-Module ...; Show-sqmToolGui }
catch {...}` in der alten `-Command`-Zeile faengt zuverlaessig nur SYNCHRONE Fehler ab (Modul fehlt,
Fehler waehrend des GUI-Aufbaus vor `ShowDialog()`). Eine Ausnahme, die dagegen WAEHREND der
`ShowDialog()`-Message-Loop auftritt (z.B. in einem Event-Handler beim Befuellen der Parameterfelder),
erreicht dieses `catch` nicht zuverlaessig - unter `powershell.exe` als WinForms-Host greift dafuer
.NETs eigene Unhandled-Exception-Policy fuer den UI-Thread, die den Prozess je nach Konfiguration
kommentarlos beenden kann, ohne dass die Ausnahme je den aufrufenden try/catch erreicht. Das erklaert
genau das beobachtete Bild: kurzes Aufblitzen, dann Ende, keine Fehlermeldung.

Fix: Die Startlogik ist jetzt in einer eigenen `Start-sqmToolGui.ps1` (liegt neben dem `.cmd`,
wird von `Install.ps1` mit ausgeliefert) statt als gequoteter `-Command`-Einzeiler. Sie setzt
`[Application]::SetUnhandledExceptionMode('CatchException')` + einen `ThreadException`-Handler,
damit auch asynchrone GUI-Ausnahmen sicher abgefangen werden - jeder Fehler (synchron oder aus der
Message-Loop) wird jetzt nach `%ProgramData%\sqmSQLTool\gui-launch.log` geschrieben UND als
MessageBox angezeigt, statt den Prozess wortlos zu beenden. `-WindowStyle Minimized` vorerst auf
`Normal` zurueckgesetzt (ein sichtbares Fenster ist beim Verifizieren dieses Fixes wichtiger als das
AV/EDR-Argument fuer ein verstecktes Fenster) - kann zurueckgestellt werden, sobald bestaetigt ist,
dass das Problem behoben ist.

## [1.9.49.0] — 2026-08-05

### `Show-sqmToolGui` vergroessert - mehr Platz fuer die Hilfe-Anzeige

Der Help-Button schreibt `Get-Help -Full` in dasselbe "Output"-Panel wie die
Kommando-Ausgabe (unterste Zeile des rechten TableLayoutPanel) - bei der bisherigen
Fenstergroesse (1150x720) und dem 55/45-Split zugunsten von "Parameters" blieb dafuer
wenig Raum, obwohl Bildschirmaufloesungen heute deutlich mehr hergeben.

Standardgroesse von 1150x720 auf 1400x900 erhoeht (Minimum 900x560 -> 1000x650), und der
Hoehen-Split der unteren beiden Prozent-Zeilen von 55% Parameters / 45% Output auf 40%/60%
zugunsten von Output gedreht - die Parameter-Liste bleibt ohnehin scrollbar (`paramPanel.AutoScroll`)
und braucht selten mehr als eine Handvoll Zeilen, waehrend `Get-Help -Full`-Text schnell laenger wird.

## [1.9.48.0] — 2026-08-05

### Neu: eigenes Icon fuer die Startmenue-Verknuepfung der GUI

`Assets\sqmSQLTool.ico` (neu, 16/32/48/256px, PNG-in-ICO) - ein einfaches, im Marken-Farbschema
von powershelldba.de gehaltenes Datenbank-Zylinder-Symbol (dunkles Navy-Badge, Akzentblau
`#2e86c1`/`#5dade2`) statt des Standard-`.cmd`-Icons. `Install.ps1` kopiert die Datei bei einer
`AllUsers`-Installation zusammen mit dem Launcher nach `C:\Program Files\sqmSQLTool` und setzt
sie als `IconLocation` der Startmenue-Verknuepfung. `Assets\` ist vom robocopy-Modul-Payload
(Schritt 4) ausgenommen - die Datei wird gezielt fuer den Launcher kopiert, nicht als Modulinhalt.

Kein automatisches Anheften an Start: der fruehere Trick (`FolderItem.InvokeVerb('pintostartscreen')`
ueber `Shell.Application`) wurde von Microsoft fuer Desktop-Verknuepfungen seit Windows 10 2004 /
Windows 11 entfernt und liefe hier nur als stiller No-Op, ohne unterstuetzte Ersatz-API. Install.ps1
gibt daher nur einen Hinweis auf den einmaligen manuellen Schritt aus (Rechtsklick > "An Start
anheften"), statt eine Automatisierung vorzutaeuschen, die auf dieser OS-Version nichts bewirkt.

## [1.9.47.0] — 2026-08-05

### Neu: `Get-sqmLoginSettings` zeigt jetzt Kennwort-Richtlinie, Kennwortablauf und "Kennwort muss geaendert werden"

Bisher fehlten in der Ausgabe die Kennwort-bezogenen Einstellungen eines SQL-Logins
komplett - man musste dafuer separat `sys.sql_logins`/`LOGINPROPERTY()` abfragen.

Neu (per LEFT JOIN `sys.sql_logins` + `LOGINPROPERTY()`, zusaetzlich zu den bisherigen
Spalten): `PasswordPolicyEnforced` (CHECK_POLICY), `PasswordExpirationEnforced`
(CHECK_EXPIRATION), `PasswordExpired` (Kennwort aktuell abgelaufen), `MustChangePassword`
("Benutzer muss Kennwort bei naechster Anmeldung aendern") und `DaysUntilExpiration`.
Bei Windows-Logins/-Gruppen sind diese Felder `$null` (kein `sys.sql_logins`-Eintrag,
Kennwortrichtlinie liegt dort bei AD) - `Invoke-DbaQuery` liefert das ohne `-As PSObject`
als `[DBNull]`, nicht als PowerShell-`$null`; ein direktes `[bool]`-Cast waere daher auf
einen `[DBNull]`-Wert gelaufen und mit einer Ausnahme gescheitert. Gegen DEV01 verifiziert:
SQL-Logins liefern die echten Werte, Windows-Logins bleiben leer statt zu fehlern.

## [1.9.46.0] — 2026-08-05

### Neu: Doppelklick-Start fuer `Show-sqmToolGui` (elevated) + AllUsers-Startmenue-Eintrag

Bisher musste die GUI manuell in einer PowerShell-Session gestartet werden
(`Import-Module sqmSQLTool; Show-sqmToolGui`). Viele der darueber aufrufbaren Funktionen
(`Invoke-sqmNtfsSetup`, Eventlog-Quellen, SQL-Agent-Jobs) aendern lokale Systemzustaende
und brauchen dafuer Adminrechte - ein einfacher Doppelklick ohne Elevation waere nur
eingeschraenkt nutzbar gewesen.

Neu: `Start-sqmToolGui.cmd` (Repo-Root, analog zu `Install.cmd`) prueft `net session` und
relauncht sich bei Bedarf per UAC selbst elevated, startet dann `Show-sqmToolGui` in einem
minimierten PowerShell-Fenster (bewusst `-WindowStyle Minimized` statt `Hidden` - ein
komplett verstecktes PowerShell-Fenster ist ein klassisches AV/EDR-Alarmsignal auf
ueberwachten SQL-Servern). Schlaegt der Modul-Import fehl, zeigt eine MessageBox den
Fehler statt wortlos im minimierten Fenster zu verschwinden.

`Install.ps1` kopiert den Launcher bei einer `AllUsers`-Installation zusaetzlich nach
`C:\Program Files\sqmSQLTool\Start-sqmToolGui.cmd` (bewusst ausserhalb des per
`robocopy /PURGE` verwalteten Modul-Zielordners) und legt eine AllUsers-Startmenue-
Verknuepfung `sqmSQLTool GUI.lnk` an - nicht fatal, falls das fehlschlaegt (die GUI bleibt
weiterhin manuell startbar).

## [1.9.45.0] — 2026-08-04

### Fix: `Invoke-sqmUserDatabaseBackup` legte ein neues Backupverzeichnis an, konnte aber danach nicht hineinschreiben

Zeigte die Server-Eigenschaft `BackupDirectory` auf einen noch nicht existierenden Pfad (z.B. nach
einer Umstellung waehrend eines Instanz-Setups, ohne dass fuer den neuen Pfad je `Invoke-sqmNtfsSetup`
gelaufen ist), legte `New-Item` das Verzeichnis zwar erfolgreich unter der aufrufenden Identitaet an
- ein neu angelegter Ordner erbt NTFS-Rechte aber nur, wenn ein Vorfahre bereits eine vererbbare ACE
fuer das SQL-Dienstkonto hat. `BACKUP DATABASE` laeuft dagegen als SQL-Dienstkonto und scheiterte
danach mit "Cannot open backup device ... Operating system error 5(Access is denied.)", obwohl das
Verzeichnis sichtbar vorhanden war.

Fix: Nach dem Anlegen eines neuen Backupverzeichnisses vergibt die Funktion jetzt automatisch
`Modify`-Rechte fuer das/die SQL-Dienstkonto(s) auf diesem Verzeichnis (ueber `Invoke-sqmNtfsSetup
-Directory $BackupPath -Permission Modify -SkipBackup`), bevor der eigentliche Backup-Lauf startet.
Schlaegt das Setzen der Rechte selbst fehl (z.B. Dienstkonto nicht ermittelbar), wird das nur als
Warnung geloggt - das Backup wird trotzdem versucht und liefert im Fehlerfall die eigentliche
SQL-Fehlermeldung.

### Fix: `Show-sqmToolGui` forderte bei Funktionen mit mehreren Parameter-Sets alle sich gegenseitig ausschliessenden Pflichtparameter gleichzeitig

Bei `Invoke-sqmRestoreDatabase` z.B. ist `-BackupFile` nur im Parameter-Set `SingleFile` und
`-BackupFiles` nur im Set `Sequence` Mandatory - beides sind Alternativen, nicht zwei zusaetzliche
Pflichtfelder. Die bisherige Pruefung vor `Run` markierte einen Parameter aber bereits als Pflichtfeld,
sobald IRGENDEINES seiner `ParameterAttribute`-Objekte `Mandatory = $true` gesetzt hatte - unabhaengig
vom Parameter-Set. Dadurch verlangte der Dialog `-BackupFile` UND `-BackupFiles` gleichzeitig ausgefuellt,
obwohl `Invoke-sqmRestoreDatabase` bei beiden gesetzt sofort mit "Parameter set cannot be resolved"
fehlgeschlagen waere - der Restore liess sich ueber die GUI faktisch nie starten.

Fix: Die Validierung nutzt jetzt `Command.ParameterSets` und laesst `Run` zu, sobald FUER MINDESTENS
EIN Parameter-Set alle seine Pflichtparameter ausgefuellt sind (genau wie PowerShell selbst beim
Binden entscheidet), statt die Vereinigung aller Pflichtparameter ueber alle Sets hinweg zu verlangen.
Die Hinweis-Meldung bei fehlenden Angaben zeigt bei mehreren Parameter-Sets jede noch unvollstaendige
Kombination einzeln an, damit klar ist, dass EINE davon ausreicht.

## [1.9.44.0] — 2026-08-04

### Fix: `Invoke-sqmRestoreDatabase` meldete einen fehlgeschlagenen Secondary-Drop faelschlich als Erfolg

Nachtrag zu 1.9.43.0: In einem realen AG-Restore (sfcsdbs103ihz/sfcsdbs104ihz, Datenbank
`AlwaysOnTest`) lief der Secondary-Drop zwar an, `Remove-DbaDatabase` scheiterte dabei aber mit
"Cannot drop the database 'AlwaysOnTest', because it does not exist or you do not have
permission." - ohne eine Exception zu werfen, auch nicht mit `-EnableException`. `Remove-DbaDatabase`
faengt einen fehlgeschlagenen Drop pro Datenbank intern ab und packt den rohen SQL-Fehlertext
lediglich in die `Status`-Eigenschaft des Rueckgabeobjekts. Der bisherige Code werteten diesen
Rueckgabewert nicht aus und meldete "RemoveFromSecondary: Success", obwohl der Drop nachweislich
fehlgeschlagen war.

Zusaetzlich verwendete die vorausgehende Existenzpruefung eine von dbatools ueber die
PowerShell-Session hinweg gecachte SMO-Verbindung (`Connect-DbaInstance` ohne
`-NonPooledConnection`): deren `.Databases`-Collection kann den Stand von vor dem eigentlichen Drop
zeigen, selbst wenn sich die Datenbank auf dem Server laengst geaendert hat.

Fix: `Connect-DbaInstance` fuer die Existenzpruefung nutzt jetzt `-NonPooledConnection` fuer eine
frische Sicht. Der Rueckgabewert von `Remove-DbaDatabase` wird ausgewertet: `Status -eq 'Dropped'`
gilt als Erfolg, `Status -match 'does not exist'` gilt als bereits erreichtes Ziel (Datenbank ist
weg, kein Fehler), jeder andere Status (z.B. ein echtes Berechtigungsproblem) wird als `Failed`
gemeldet statt verschluckt zu werden.

## [1.9.43.0] — 2026-08-04

### Fix: `Invoke-sqmRestoreDatabase` liess bei AG-Restore stale Datenbank auf Secondary zurueck

Der Secondary-Cleanup-Schritt (nach `Remove-DbaAgDatabase` auf dem Primary) pruefte vor dem
`Remove-DbaDatabase`-Aufruf zusaetzlich `.IsAccessible` der Datenbank auf dem sekundaeren Knoten.
Nach dem Entfernen aus der AG liegt die dort verbleibende Kopie aber typischerweise im Status
RESTORING - `IsAccessible` ist dann `$false`, obwohl die Datenbank sehr wohl existiert. Der Code
interpretierte das faelschlich als "nicht vorhanden" und uebersprang den Drop komplett (inklusive
irrefuehrender VERBOSE-Meldung). Beim anschliessenden Wiedereinfuegen in die AG
(`Add-DbaAgDatabase -SeedingMode Automatic`) schlug das Seeding dadurch mit
"Database With Name Already Exists" fehl - die Secondaries blieben ohne die neu restaurierte
Datenbank zurueck, obwohl `RejoinAG` scheinbar der einzige fehlgeschlagene Schritt war.

Fix: Existenzpruefung auf dem Secondary vor dem Drop prueft nur noch, ob die Datenbank ueberhaupt
vorhanden ist (`$secondaryServer.Databases[$finalDbName]`), nicht mehr zusaetzlich `IsAccessible`.

## [1.9.42.0] — 2026-08-03

### Fix: `Invoke-sqmMonitoringKey` schrieb/las den falschen Registry-Pfad

Die Quelldatei war auf `HKLM:\<RegistryBase>\dtcSoftware\sqmSQLTool` zurueckgefallen, obwohl die
reale System-Center-Konvention beim Kunden `HKLM:\SYSTEM\FITS\Systemcenter` lautet, mit den Werten
`SQL` (0/1/2 - None/Standard/Full, kundenabhaengig und manuell zu setzen) und
`SQLFreeSpaceVersion` (Standard/Cluster, per `-AutoDetectSQLFreeSpaceVersion` ueber die
AG-Zugehoerigkeit automatisch erkennbar) direkt unter diesem Schluessel. Die gebaute/verteilte
Kopie in `bin/Public` hatte weiterhin den richtigen Pfad - nur die Quelle war betroffen.

Fix: `$regSubKey` wieder auf `$RegistryBase\FITS\SystemCenter` gesetzt. Neuer Pester-Test
(`Invoke-sqmMonitoringKey.Tests.ps1`, komplett gemockt) haelt den Pfad fest und schlaegt
nachweislich fehl, sobald der alte `dtcSoftware\sqmSQLTool`-Pfad zurueckkommt.

## [1.9.41.0] — 2026-08-03

### Fix: CI-Testfehler bei `Repair-sqmServerName` (Write-Error unter $ErrorActionPreference='Stop')

Der GitHub-Actions-Job "Import & Pester (PowerShell 7)" schlug bei `Repair-sqmServerName.Tests.ps1`
fehl: `pwsh`-Steps in GitHub Actions laufen mit `$ErrorActionPreference = 'Stop'`. Die Catch-Bloecke
riefen `Write-Error` ohne eigenes `-ErrorAction` auf - unter geerbtem `Stop` wurde daraus ein
TERMINIERENDER Fehler statt einer reinen Meldung. Im inneren Catch (sp_addserver-Fehlschlag) brach
das die Ausfuehrung ab, bevor `return $result` erreicht wurde; der Fehler wanderte in den aeusseren
Catch, dessen eigener `Write-Error`-Aufruf dann komplett unbehandelt aus der Funktion entkam - der
Test scheiterte nicht an der Assertion, sondern weil `Repair-sqmServerName` selbst eine Exception
warf, statt wie dokumentiert ein Ergebnisobjekt mit `Status = 'Error'` zurueckzugeben. Lokal (ohne
`Stop`-Preference) blieb das unbemerkt, weil `Write-Error` dort nur eine nicht-terminierende Meldung
schreibt.

Fix: Alle betroffenen `Write-Error`-Aufrufe (`Repair-sqmServerName`, sowie `Get-sqmSsasDeploymentMode`
und `Set-sqmSsasDeploymentMode` mit demselben Muster) bekommen jetzt explizit `-ErrorAction Continue`,
damit sie unabhaengig von der geerbten Preference des Aufrufers immer nur melden statt abzubrechen -
mit `$ErrorActionPreference = 'Stop'` reproduziert und verifiziert, komplette Testsuite (202 Tests)
weiterhin gruen.

## [1.9.40.0] — 2026-08-03

### Fix: `Invoke-sqmSplunkConfiguration` meldete "neu gestartet", obwohl der Neustart fehlgeschlagen war

Praxisfall auf `HLB1W01AWSA0087`: `Restart-Service -Name SplunkForwarder -Force` warf "Cannot stop
SplunkForwarder service", der Dienst blieb danach im Status `Stopped`. Im Log stand trotzdem
"Dienst 'SplunkForwarder' neu gestartet." und das Endergebnis meldete `Status = Success` - weil
`Restart-Service` ohne `-ErrorAction Stop` aufgerufen wurde und `_sqmSplunk_LocalCore` mit
`$ErrorActionPreference = 'Continue'` laeuft: der nicht-terminierende Fehler landete nie im
`catch`-Block, die Ausfuehrung lief einfach zur naechsten Zeile durch.

Fix: `Restart-Service` bekommt jetzt `-ErrorAction Stop`, damit ein fehlgeschlagener Stop-Schritt
tatsaechlich im `catch` ankommt und korrekt als Fehler geloggt wird. Zusaetzlich versucht die
Funktion in diesem Fall, den Dienst per `Start-Service` nachzustarten - `Restart-Service` kann ihn
bereits gestoppt haben, bevor der Fehler auftrat, und ohne Nachstart-Versuch waere er stehen
geblieben, obwohl er vorher lief.

## [1.9.39.0] — 2026-08-03

### Fix: `Invoke-sqmSplunkConfiguration` liess veraltete Pfade nach SQL-Versionswechsel im Environment stehen

Die Funktion hat gesetzte `MSSQLn_Log`-Variablen grundsaetzlich nie ueberschrieben. Wurde eine
Instanz auf eine neue SQL-Version aktualisiert (z.B. neues ErrorLog-Verzeichnis wie
`MSSQL16.MSSQLSERVER` statt `MSSQL15.MSSQLSERVER`) oder komplett neu installiert, blieb der alte,
nicht mehr existierende Pfad in der Umgebungsvariable stehen - Splunk ueberwachte damit dauerhaft
einen toten Pfad und meldete Fehlalarme.

Fix: Vor dem "nicht ueberschreiben" wird jetzt geprueft, ob der gespeicherte Pfad noch existiert
(`Test-Path`). Existiert er nicht mehr, gilt die Variable als veraltet und wird mit dem aktuell
ermittelten ErrorLog-Pfad der Instanz aktualisiert - eine noch gueltige, unveraenderte Variable
wird weiterhin nicht angefasst. Zusaetzlich werden `MSSQLn_Log`-Variablen entfernt, deren Ordinalzahl
groesser ist als die Anzahl aktuell installierter Instanzen (verwaist, z.B. nach Deinstallation
statt In-Place-Upgrade einer Instanz). Die Instanznamen werden vor der Nummerierung sortiert, damit
die Ordinalzahl bei unveraendertem Instanzbestand stabil bleibt. `-Mode Test` meldet veraltete und
verwaiste Variablen jetzt ebenfalls, ohne etwas zu aendern.

## [1.9.38.0] — 2026-08-03

### Neu: `Repair-sqmServerName`

Nach einer Windows-Hostname-/FQDN-Aenderung (Umbenennung, VM-Klon, Rechenzentrums-Umzug) meldet
Windows sofort den neuen Namen, waehrend SQL Server den ALTEN Namen weiter als "lokalen Server"
in `sys.servers` fuehrt (`@@SERVERNAME` / `SERVERPROPERTY('ServerName')`). Der Drift faellt oft
erst auf, wenn Replikation, Linked-Server-Loopbacks, SSRS oder Zertifikate mit dem falschen Namen
fehlschlagen - bislang gab es dafuer keine sqmSQLTool-Funktion.

Die neue Funktion vergleicht den registrierten Namen mit dem aus `MachineName`/`InstanceName`
berechneten Soll-Namen und korrigiert ihn per `sp_dropserver`/`sp_addserver`. Vor der Aenderung
prueft sie Failover-Cluster-Mitgliedschaft (`IsClustered`), AlwaysOn-AG-Mitgliedschaft
(`sys.availability_replicas`) und Replikationsrollen (`sys.databases`: Distributor/Publisher/
Subscriber) - in all diesen Faellen haengen andere Objekte am alten Namen, deshalb wird ohne
`-Force` abgebrochen (Status `Blocked`). Unterstuetzt `-WhatIf`; weist nach erfolgreicher
Aenderung darauf hin, dass ein Dienst-Neustart noetig ist, bis `@@SERVERNAME` den neuen Wert
liefert (kein automatischer Neustart).

## [1.9.37.0] — 2026-08-03

### Fix: `Set-sqmSsasDeploymentMode` schlug mit "Invalid query" fehl bei `-InstanceName` im SSMS-Format

Wurde die Instanz wie in SSMS ueblich als `"Server\Instanz"` angegeben (z. B. `HLESDSQL001\APSM`,
per Copy-Paste aus der Verbindungsleiste), baute die Funktion daraus den Dienstnamen
`MSOLAP$HLESDSQL001\APSM` und damit die WQL-Abfrage `SELECT * FROM Win32_Service WHERE
Name='MSOLAP$HLESDSQL001\APSM'`. Der Backslash ist in WQL-String-Literalen ein Escape-Zeichen -
`\A` ist keine gueltige Escape-Sequenz, `Get-CimInstance` bricht deshalb mit "Invalid query" ab.

Fix: Ein Server-Praefix vor dem letzten Backslash wird jetzt automatisch entfernt, es zaehlt nur
der Instanzname dahinter (Windows-Dienstnamen enthalten ohnehin nie den Servernamen).

### Neu: `Get-sqmSsasDeploymentMode`

Rein lesendes Gegenstueck zu `Set-sqmSsasDeploymentMode` - liefert den aktuellen `DeploymentMode`
(Multidimensional/Tabular/SharePoint) einer SSAS-Instanz aus `msmdsrv.ini`, ohne etwas zu aendern.
Akzeptiert ebenfalls `"Server\Instanz"` als `-InstanceName`.

## [1.9.36.0] — 2026-08-03

### Fix: `Invoke-sqmRestoreTest` fragte immer nach `-DatabaseName`, auch wenn `-BackupFile` schon angegeben war

`-DatabaseName` war unbedingt `Mandatory = $true` - PowerShell fragte den Namen deshalb immer
interaktiv ab, selbst wenn `-BackupFile` bereits mitgegeben war und der Name damit laengst im
Backup selbst steht. `Invoke-sqmRestoreDatabase` loest genau diesen Fall schon immer selbst (per
`RESTORE HEADERONLY`), `Invoke-sqmRestoreTest` hatte diese Angleichung nie bekommen.

Fix: `-DatabaseName` ist jetzt nur noch dann erforderlich, wenn `-BackupFile` FEHLT - dort dient
der Name als Suchschluessel fuer die msdb-Sicherungshistorie (`Get-DbaDbBackupHistory`) und es
gibt keinen anderen Weg, das passende Backup zu finden. Ist `-BackupFile` gegeben, wird der Name
bei Bedarf automatisch aus dem Backup-Header gelesen (`RESTORE HEADERONLY`), analog zu
`Invoke-sqmRestoreDatabase`. Fehlen sowohl `-DatabaseName` als auch `-BackupFile`, wird das jetzt
als klare Ablehnung (`Status = 'Rejected'`) gemeldet, bevor ueberhaupt eine Verbindung aufgebaut
wird - statt PowerShell interaktiv nach dem Parameter fragen zu lassen.

## [1.9.35.0] — 2026-08-03

### Fix: `Invoke-sqmRestoreDatabase` protokollierte "Restore erfolgreich", ohne dass ueberhaupt restored wurde

Vorfall auf `SFCSDBS103IHZ` (AG `LFCS20DBSQL1`, Restore aus `F:\DB_Transfer_Prod\*.bak`): das
Log zeigte fuer alle vier Laeufe (amb, custom, arena, amb) durchgehend "Success" - inklusive
"Restore von ... erfolgreich" und "erfolgreich in AG aufgenommen". Eine Gegenprobe direkt in SQL
Server (`msdb.dbo.restorehistory`, letzter Eintrag pro Datenbank ueber `ROW_NUMBER() OVER
(PARTITION BY d.Name ORDER BY r.restore_date DESC)`) zeigte aber: das `restore_date` war eine
Woche alt - es hatte an diesem Tag ueberhaupt keinen tatsaechlichen `RESTORE`-Befehl gegeben. Die
Datenbanken blieben ausserdem im Modus RESTRICTED_USER stehen.

Drei zusammenhaengende Bugs im selben Codepfad, die sich gegenseitig verdeckt haben:

1. **AG-Erkennung wirkungslos.** Die Bedingung vor `Remove-DbaAgDatabase` pruefte
   `if (-not $agDbCheck)` - eine Variable, die seit dem Refactoring in 1.9.27.0 (Abloesung durch
   `Get-sqmDatabaseAgMembership`/`$agMembership`) nirgends mehr zugewiesen wurde und damit immer
   `$null` war. Die Bedingung war folglich IMMER wahr, `Remove-DbaAgDatabase` lief nie - die
   Datenbanken blieben aller Wahrscheinlichkeit nach die ganze Zeit ueber live Mitglied der AG.
   Fix: `$agDbCheck` durch `$agMembership.IsAgDatabase` (die tatsaechlich zu Laufbeginn ermittelte
   Live-Mitgliedschaft) ersetzt.

2. **Der eigentliche `RESTORE`-Befehl wurde von SQL Server mutmasslich abgelehnt** - mit exakt dem
   seit 1.9.27.0 bekannten Fehler "RESTORE cannot operate on database ... because it is configured
   for database mirroring or has joined an availability group", weil die Datenbank wegen Bug 1
   noch in der AG steckte.

3. **Diese Ablehnung wurde vom Code nie bemerkt**, weil praktisch KEIN verschachtelter
   dbatools-Aufruf in dieser Funktion `-EnableException` gesetzt hatte (nur `-ErrorAction Stop`).
   dbatools-Funktionen (PSFramework `Stop-Function`) melden interne Ablehnungen ohne
   `-EnableException` per Default nur als Warning und geben `$null` zurueck - OHNE eine
   terminierende Exception zu werfen. `-ErrorAction Stop` allein greift dabei nicht, weil kein
   reguraerer PowerShell-Fehlerdatensatz entsteht. Das eigene try/catch um `Restore-DbaDatabase`
   sah dadurch nie einen Fehler, protokollierte "Restore erfolgreich" und liess `$restoreSucceeded`
   auf `$true` stehen - obwohl `$restoreResult` in Wahrheit leer war. Alle nachfolgenden Schritte
   (User-Import, Orphan-Repair, Owner setzen, AG-Rejoin) liefen anschliessend anstandslos gegen die
   UNVERAENDERTE Alt-Datenbank durch, da sie selbst keine RESTORE-spezifische Sperre verletzen -
   der Fehlschlag blieb dadurch komplett unsichtbar. Das RESTRICTED_USER blieb vermutlich Rest
   eines frueheren, echten Restore-Versuchs (der Backup-Quelle in genau diesem Modus, siehe unten)
   liegen und wurde nie zurueckgesetzt, weil ja nie ein neuer Restore lief, der das haette tun
   koennen.

   Fix: `-EnableException` an jeden verschachtelten dbatools-Aufruf ergaenzt, der bislang nur
   `-ErrorAction Stop` gesetzt hatte (`Restore-DbaDatabase`, `Export-DbaUser`,
   `Repair-DbaDbOrphanUser`, `Set-DbaDbOwner`, `Remove-DbaAgDatabase`, `Remove-DbaDatabase`,
   `Add-DbaAgDatabase`, `Set-DbaAgReplica`, `Get-DbaAgReplica`, alle betroffenen
   `Invoke-DbaQuery`-Aufrufe) - passend zum bereits etablierten Muster im Rest des Moduls (siehe
   z.B. `Get-sqmDatabaseAgMembership`, `Test-sqmBackupIntegrity`). `Connect-DbaInstance` bewusst
   ausgenommen (kennt laut fruehester Erfahrung in diesem Modul kein `-EnableException`, wirft aber
   ohnehin echte Exceptions bei Verbindungsfehlern). Zusaetzlich wird das Rueckgabeobjekt von
   `Restore-DbaDatabase` jetzt selbst geprueft (`if (-not $restoreResult) { throw ... }`) statt sich
   allein darauf zu verlassen, dass nichts geworfen wurde.

Zusaetzlich, unabhaengig von den drei Bugs oben: nach einem tatsaechlich erfolgreichen Restore
wird jetzt immer der TATSAECHLICHE Live-Zustand (`sys.databases.user_access_desc`) abgefragt und
bei Abweichung von MULTI_USER zurueckgesetzt - vorher hing dieser Ruecksprung an der eigenen
`$wasSingleUser`-Fahne, die nur gesetzt wird, wenn die Funktion SELBST vor dem Restore
SINGLE_USER erzwungen hatte. `RESTORE DATABASE` uebernimmt aber den User-Access-Modus, der zum
Zeitpunkt der Datensicherung im Backup selbst galt (Boot-Page der Datenbank) - stand die
Quelldatenbank beim Sichern in RESTRICTED_USER (ueblich bei einer Migrations-Sicherung wie unter
`F:\DB_Transfer_Prod\`), kaeme eine wiederhergestellte Kopie in genau diesem Modus wieder hoch,
unabhaengig davon, ob `$wasSingleUser` je `$true` war - und ein sysadmin-Login (unter dem diese
Funktion laut NOTES laufen muss) koennte sich trotzdem weiter verbinden, sodass der Zustand
unbemerkt bliebe.

## [1.9.34.0] — 2026-07-31

### Fix: `Get-sqmADMemberGroups` fand auf einer echten Kunden-Domaene (LDAP-Fallback) weiterhin 0 Gruppen, obwohl der Account nachweislich Mitglied war

Nach dem Fix in 1.9.33.0 (LDAP-Fallback lief jetzt ueberhaupt an) blieb das Ergebnis auf
`BP.PROD.BANK.LBBW.SKO.DE` trotzdem bei 0 - ohne jede Fehlermeldung. Gegenprobe mit
`Get-sqmADGroupMembers` (die andere Richtung: "wer ist Mitglied dieser Gruppe") fand den
getesteten Account anstandslos per LDAP als Mitglied einer bekannten Gruppe. Zwei Bugs in
`Find-ParentGroups` (LDAP-Zweig) gefunden und behoben:

1. Der DN des gesuchten Members wurde roh in einen Gruppen-Suchfilter eingesetzt
   (`(member=$memberDN)`). Enthaelt der DN Zeichen, die im Filter anders escaped werden
   muessen als im DN selbst - z.B. Kommas bei `CN=Nachname, Vorname` (Standard-
   Namenskonvention in dieser Umgebung) - liefert die Suche lautlos 0 Treffer, keine
   Exception. Fix: `memberOf`-Attribut direkt vom gefundenen User-Objekt lesen (derselbe
   Rueckverweis-Mechanismus wie `Get-ADPrincipalGroupMembership`), kein DN-in-Filter mehr
   noetig.
2. Pro gefundener Gruppe wurde `InvokeGet("groupScope")` aufgerufen - kein echtes
   LDAP-Attribut (das AD-Schema kennt nur `groupType`; `groupScope` ist eine berechnete
   Eigenschaft des PowerShell-AD-Moduls). Ein ungueltiger Attributname wirft eine Exception,
   die den kompletten Gruppen-Datensatz (inklusive `SamAccountName`) aus der Ergebnisliste
   riss, bevor er hinzugefuegt wurde - selbst wenn die Suche selbst Treffer fand. Fix: jedes
   Attribut einzeln tolerant lesen (gleiches Muster wie bereits in
   `Get-sqmADGroupMembersRecursive` verwendet), `groupType` statt `groupScope`.

## [1.9.33.0] — 2026-07-31

### Fix: `Get-sqmADMemberGroups` und `Get-sqmADGroupMembersRecursive` lieferten auf Servern ohne ActiveDirectory-Modul stumm 0 Ergebnisse

Auf einer echten Kunden-Domaene (`BP.PROD.BANK.LBBW.SKO.DE`) meldeten beide Funktionen
"0 Groups"/"0 Members" ohne jede Fehlermeldung, auch nicht im Log. Ursache: der LDAP-Fallback
steckte im `catch`-Block des ActiveDirectory-Modul-Pfads:

```
try {
    if (Get-Module -ListAvailable -Name ActiveDirectory) { ... AD-Cmdlet-Pfad ... }
}
catch { ... LDAP-Fallback ... }
```

Ist das ActiveDirectory-Modul (RSAT) auf dem Zielserver schlicht nicht installiert, ist die
`if`-Bedingung einfach `$false` - das wirft **keine Exception**, der `catch`-Block (und damit
der komplette LDAP-Fallback) lief also nie an. Reproduziert im Log: nach der korrekt
aufgeloesten Domain kam sofort "0 Groups found", ohne einen einzigen Eintrag dazwischen.

Betraf `Get-sqmADMemberGroups` (`Find-ParentGroups`) und `Get-sqmADGroupMembersRecursive`
(`Expand-GroupMembers`) identisch. `Get-sqmADGroupMembers` war nicht betroffen - dort war der
Fallback bereits ueber ein explizites `$methodUsed`-Flag verdrahtet, nicht ueber `catch`.

Fix: beide Helper-Funktionen tragen jetzt dasselbe `$usedAdModule`-Flag-Muster. Der
LDAP-Fallback laeuft jetzt sowohl wenn das AD-Modul fehlt als auch wenn es eine Exception
wirft. Zusaetzlich werden beide Fehlerfaelle jetzt explizit als WARNING geloggt statt komplett
stumm zu bleiben.

## [1.9.32.0] — 2026-07-29

### Fix: `Get-sqmAgentJobScheduleReport` oeffnete den HTML-Bericht nicht automatisch

Alle anderen Report-Funktionen des Moduls unterstuetzen den Standard-Mechanismus zum
automatischen Oeffnen des erzeugten HTML-Berichts (`-NoOpen`-Switch plus Aufruf von
`Invoke-sqmOpenReport` nach dem Schreiben der Datei). `Get-sqmAgentJobScheduleReport` hatte
diesen Baustein noch nicht - der Bericht wurde erzeugt, aber nie geoeffnet. Jetzt konsistent
mit z.B. `Get-sqmDeadlockReport` und `Get-sqmWaitStatistics`.

## [1.9.31.0] — 2026-07-29

### Fix: erfolgreich gelaufene Jobs wurden im Schedule-Report als "Failed" gemeldet

`Get-sqmAgentJobScheduleReport` hatte drei nachweisbare Fehler in der Statusermittlung, alle gegen
eine echte SQL Server 2022-Instanz reproduziert:

1. **Ein Job, der noch nie gelaufen ist (oder dessen Historie vollstaendig purgiert wurde),
   wurde als "Failed" gemeldet statt als "noch nie gelaufen".** Die T-SQL-Anweisung
   `CASE WHEN jh.run_status = 1 THEN 'Success' ELSE 'Failed' END` faellt bei `run_status = NULL`
   (kein Historieneintrag vorhanden) in den ELSE-Zweig, weil `NULL = 1` in SQL weder wahr noch
   falsch, sondern UNKNOWN ist. Reproduziert: ein frisch angelegter, noch nie gestarteter Job
   lieferte `LastRunStatus = Failed`.

2. **`MAX()` auf die Ergebnis-Strings 'Success'/'Failed' aggregierte alphabetisch, nicht
   zeitlich** - 'Success' > 'Failed'. Ein Job, dessen tatsaechlich LETZTER Lauf fehlgeschlagen
   ist, aber irgendwann vorher einmal erfolgreich war, wurde als 'Success' gemeldet.
   Reproduziert: Lauf 1 erfolgreich, Lauf 2 (der spaetere) mit absichtlichem Fehler - die alte
   Abfrage lieferte weiterhin `Success`.

3. **Ein Job mit zwei oder mehr Zeitplaenen wurde durch den JOIN auf `sysjobschedules` und
   `sysschedules` vervielfacht** (2 Zeitplaene x N Historienzeilen), wodurch die GROUP BY-Abfrage
   mehrere Zeilen statt einer je Job lieferte. `$jobHistoryData | Where-Object JobName -eq ...`
   ergab dadurch ein Array statt eines einzelnen Datensatzes, und Felder wie `LastRunDate` und
   `LastRunStatus` wurden faelschlich als Arrays weiterverarbeitet. Reproduziert: `LastExecution`
   zeigte "Never" (die `[string]`-Konvertierung eines Arrays mit zwei Datumswerten ergibt einen
   durch Leerzeichen getrennten String, den `TryParse` als Ganzzahl ablehnt), `Schedule` zeigte
   "No Schedule" trotz zweier vorhandener Zeitplaene, `LastStatus` wurde zu `{Success, Success}`
   statt eines einzelnen Werts.

Die Abfrage trennt jetzt beide Fragen technisch voneinander: eine CTE mit
`ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC)` liefert genau eine Zeile je
Job - den tatsaechlich letzten Lauf. `instance_id` ist SQL Agents eigener, garantiert monoton
steigender Zaehler und damit zuverlaessiger als ein Vergleich von `run_date`/`run_time`. Die
Zeitplaene werden separat auf einen reprsentativen Zeitplan je Job reduziert (samt Gesamtzahl,
falls mehrere existieren, sichtbar als "(+1 weitere(r) Zeitplan/Zeitplaene)"), statt die Historie
zu vervielfachen. Ein Job ohne Historie bekommt jetzt den eigenen Status `Never Run` statt
`Failed` - er zaehlt in der Zusammenfassung weder als Erfolg noch als Fehlschlag.

**Getestet** gegen SQL Server 2022 auf DEV01 mit drei praeparierten Faellen (nie gelaufen, ein
Zeitplan mit Erfolg, zwei Zeitplaene, sowie ein Job mit Erfolg gefolgt von einem tatsaechlichen
Fehlschlag) - alle drei zeigen jetzt den korrekten Status. Dazu fuenf neue Pester-Tests
(`tests/Unit/Public/Get-sqmAgentJobScheduleReport.Tests.ps1`), die die Statusableitung ohne
Serverzugriff nachbilden; der entscheidende Test wurde per Mutation gegengeprueft (mit dem alten
Verhalten wieder eingebaut schlaegt er fehl). Volle Suite: 195 Tests, keine Fehlschlaege.

## [1.9.30.0] — 2026-07-29

### Neu: Datenbank-Modus (Kompatibilitaetsgrad) im Setup-Report

Die Datenbanktabelle in `Invoke-sqmSetupReport` hat eine Spalte "Datenbank-Modus" bekommen, und der
SERVER-Abschnitt weist den Standard der Instanz aus. Ausgegeben wird die SQL Server-Version, fuer
die der Grad steht, nicht nur die nackte Zahl: `2019 (150)` statt `150`. Die Zahl allein sagt nur
denen etwas, die die Tabelle auswendig koennen, dabei entscheidet genau dieser Wert darueber,
welches Verhalten und welcher Abfrageoptimierer fuer die Datenbank tatsaechlich gelten.

Abgedeckt sind 2000 bis 2025 (80 bis 170). Liegt eine Datenbank unter dem Stand ihrer Instanz, wird
das ausdruecklich vermerkt, denn genau diese Konstellation faellt sonst niemandem auf:

```
sqmCompatTest    Full    2019 (150), niedriger als die Instanz: 2022 (160)
```

Der Standard der Instanz wird aus dem Kompatibilitaetsgrad von `model` gelesen, also aus dem Wert,
den neu angelegte Datenbanken erhalten.

## [1.9.29.0] — 2026-07-28

### Fix: der Splunk-Status beschrieb den falschen Server

`Invoke-sqmSplunkConfiguration -Mode Test` wurde ohne Zielangabe aufgerufen und prueft damit den
Rechner, auf dem der Bericht ERZEUGT wird. Bei einem Bericht ueber eine entfernte Instanz stand im
Ergebnis also der Zustand einer voellig anderen Maschine, ohne dass das erkennbar war - im
Protokoll sichtbar als "=== DEV03 ===" waehrend ueber DEV01 berichtet wurde.

Laeuft die berichtete Instanz auf dem lokalen Rechner, wird weiterhin lokal geprueft. Sonst wird der
Zielrechner ueber `-ComputerList` adressiert. Zusaetzlich wird das Ergebnis jetzt streng bewertet:
schlaegt die Remoteverbindung fehl, liefert die Funktion trotzdem ein Objekt mit
`IsConfigured = $false` zurueck. Das allein auszuwerten hiesse, "nicht erreichbar" als "nicht
konfiguriert" zu melden. Gemeldet wird deshalb nur dann ein Zustand, wenn die Antwort auch
nachweislich vom gefragten Rechner kommt und einen auswertbaren Status hat, sonst
"Nicht ermittelbar" mit Grund.

### Neu: Abschnitt CLUSTER & HOCHVERFUEGBARKEIT

Vollstaendig ueber die SQL-Verbindung, ohne WinRM, und damit garantiert von der berichteten
Instanz:

- Failover Cluster (FCI) ja/nein, bei ja mit virtuellem Namen, aktivem Knoten und allen Knoten aus
  `sys.dm_os_cluster_nodes` samt Status
- AlwaysOn aktiviert ja/nein
- WSFC-Name, Quorumtyp und -zustand aus `sys.dm_hadr_cluster`, dazu alle Clustermitglieder aus
  `sys.dm_hadr_cluster_members` mit Typ, Zustand und Stimmenzahl - auch die Knoten, auf denen diese
  Instanz gar nicht laeuft
- jede Availability Group mit allen Replikaten: Rolle, Verfuegbarkeitsmodus, Failovermodus und
  Synchronisierungszustand
- alle Listener mit DNS-Name und Port

Damit beantwortet der Bericht auch die Frage nach weiteren Knoten, ohne dass man sich dafuer auf
einen der beteiligten Server verbinden muss.

**Getestet** gegen SQL 2022 auf DEV01: Einzelinstanz ohne AlwaysOn wird korrekt als solche
ausgewiesen, der Splunk-Abschnitt meldet nicht mehr faelschlich den lokalen Rechner. Der Cluster-
und AG-Zweig selbst konnte mangels verfuegbarem Cluster nicht durchgespielt werden.

## [1.9.28.0] — 2026-07-28

### Fix: Sicherungen wurden als fehlend gemeldet, obwohl gesichert wurde

Die Kachel "Backup Jobs" in `Invoke-sqmSetupReport` bewertete ausschliesslich SQL Agent-Jobs, deren
Name `backup` oder `bkp` enthaelt. Wird ueber ein externes Werkzeug gesichert - TDP/TSM, ein
zentraler Backupserver, ein Scheduler ausserhalb des SQL Servers - gibt es solche Jobs nicht, und
der Bericht meldete `NO BACKUP JOBS`, obwohl jede Nacht sauber gesichert wurde.

Die Bewertung kommt jetzt aus `msdb.dbo.backupset`, also aus der tatsaechlichen Sicherungshistorie.
Dort steht jede Sicherung, unabhaengig davon, wer sie ausgeloest hat, auch die ueber Virtual Device
Interface laufenden Sicherungen von TDP/TSM. Gemeldet wird, wie viele Datenbanken ueberhaupt keine
Vollsicherung haben (rot, mit Namen) beziehungsweise aelter als sieben Tage sind (orange), sonst
gruen mit dem Alter der aeltesten Sicherung. Die Agent-Jobs stehen weiterhin als Zusatzinformation
dabei, nur nicht mehr als Bewertungsgrundlage.

Der Fehler ging in beide Richtungen: bei der Pruefung gegen eine Testinstanz meldete die alte Logik
"OK (5 jobs)", waehrend 11 von 20 Datenbanken tatsaechlich nie gesichert worden waren.

### Fix: falsches Dienstkonto fuer den SQL-Dienst

Die Dienstkonten wurden ueber `Get-Service` und `Get-CimInstance Win32_Service` **ohne**
`-ComputerName` gelesen. Beides fragt damit den Rechner ab, auf dem das Skript laeuft: bei einem
Bericht ueber eine entfernte Instanz wurde also das Konto des lokalen Rechners ausgewiesen. Auf
einem Host mit mehreren Instanzen kam durch `Select-Object -First 1` zusaetzlich eine beliebige
davon heraus.

Gelesen wird jetzt `sys.dm_server_services`. Die DMV liefert genau die Dienste der verbundenen
Instanz, ohne WinRM, samt Status und Starttyp.

### Neu im Bericht

Abschnitt **SERVER**: Collation, Edition und Produktversion, Anzahl logischer Prozessoren nebst
Sockelzahl und Scheduler, sowie der OS-Arbeitsspeicher. Alles aus `SERVERPROPERTY` und
`sys.dm_os_sys_info`, also ueber die SQL-Verbindung und damit unabhaengig von WinRM.

Abschnitt **INSTALLIERTE KOMPONENTEN**: Volltextsuche (SQL-seitig sicher feststellbar), Integration
Services, Analysis Services und Reporting Services sowie der Monitoring-Registry-Schluessel aus
`Invoke-sqmMonitoringKey`. Die letzten vier sind Hostangaben und brauchen WinRM. Ist das nicht
moeglich, steht dort ausdruecklich **"nicht ermittelbar"** samt Grund, nicht "nicht installiert" -
fuer SSIS und SSRS wird ersatzweise geprueft, ob ein SSISDB- beziehungsweise ReportServer-Katalog
auf dieser Instanz liegt, was ebenfalls als Indiz und nicht als Nachweis benannt wird.

**Getestet** gegen SQL 2022 auf DEV01 (Windows, ohne WinRM-Zugriff, also der Fallback-Pfad) und
gegen SQL 2022 unter Linux im Container. Dienstkonten kommen nachweislich von der Zielinstanz
(`NT Service\MSSQLSERVER`), nicht mehr vom ausfuehrenden Rechner.

## [1.9.27.1] — 2026-07-28

### Fix: -Confirm:$false an Export-DbaUser hat jeden Restore verhindert

`Invoke-sqmRestoreDatabase` ist beim User-Export gescheitert und hat den Lauf danach beendet, ohne
dass ein Restore stattgefunden hat:

```
UserExport  Failed  Fehler beim Export der User: Es wurde kein Parameter gefunden,
                    der dem Parameternamen "Confirm" entspricht.
```

Ursache war 1.9.26.0 ("pass -Confirm:$false to every nested dbatools cmdlet explicitly"): der
Parameter wurde pauschal an jeden genesteten dbatools-Aufruf gehaengt. `Export-DbaUser` unterstuetzt
ShouldProcess aber nicht (geprueft gegen dbatools 2.8.2), und der Aufruf schlaegt damit sofort mit
einer ParameterBindingException fehl. Da der `catch` des User-Exports den Lauf per `return`
beendet, war der Restore als Ganzes blockiert - die Meldung liess das nur nicht erkennen.

`-Confirm:$false` entfaellt an dieser Stelle. Unterdrueckte Rueckfragen laufen jetzt zusaetzlich
zentral ueber `$ConfirmPreference = 'None'` im begin-Block, das wirkt auf jedes Cmdlet unabhaengig
davon, ob es den Parameter ueberhaupt kennt, und ist gegen kuenftige dbatools-Versionen robust. Die
uebrigen acht Aufrufstellen wurden geprueft, dort ist `-Confirm` jeweils vorhanden
(`Remove-DbaAgDatabase`, `Remove-DbaDatabase`, `Repair-DbaDbOrphanUser`, `Set-DbaDbOwner`,
`Set-DbaAgReplica`, `Add-DbaAgDatabase`, `Set-sqmSqlPolicyState`).

Ein neuer Test scannt die Datei per AST und meldet jeden Befehl, der `-Confirm` erhaelt, obwohl das
aufgeloeste Cmdlet den Parameter nicht kennt. Per Mutation gegengeprueft: mit dem alten Aufruf
wieder eingebaut schlaegt er fehl.

**Getestet gegen eine echte Instanz (DEV01, SQL 2022, ohne AlwaysOn), unter Windows PowerShell
5.1:** Backup mit definiertem Inhalt gezogen, Datenbank danach veraendert, `Invoke-sqmRestoreDatabase`
ausgefuehrt, Inhalt exakt auf den Backup-Stand zurueck, acht Schritte ohne Fehlschlag
(UserExport, RestoreStep, UserImport, FixOrphans, RemoveOrphanWindowsLogins, SetDbOwner),
Datenbank danach ONLINE und MULTI_USER.

## [1.9.27.0] — 2026-07-28

### Fix: AG-Erkennung konnte "nicht ermittelbar" nicht von "keine AG" unterscheiden

`Invoke-sqmRestoreDatabase` ist bei einer Datenbank, die nachweislich Mitglied einer Availability
Group war, in den Standalone-Pfad gelaufen. Es hat das Entfernen aus der AG uebersprungen und ist
erst mehrere Schritte spaeter an den Operationen gescheitert, die SQL Server bei einer AG-Datenbank
grundsaetzlich ablehnt:

```
[Invoke-DbaQuery] The operation cannot be performed on database "amb" because it is involved in
a database mirroring session or an availability group. ALTER DATABASE statement failed.
[Restore-DbaDatabase] RESTORE cannot operate on database 'amb' because it is configured for
database mirroring or has joined an availability group.
```

Ursache war die Erkennung selbst:

```powershell
$agDbCheck = Get-DbaAgDatabase -SqlInstance $SqlInstance -Database $finalDbName -ErrorAction SilentlyContinue
if ($agDbCheck) { ... }
```

Fehlende Rechte (`VIEW ANY DEFINITION`), eine stolpernde SMO-Enumeration oder eine Verbindung zu
einer anderen Instanz als gemeint liefern alle dasselbe leere Ergebnis wie eine echte
Standalone-Datenbank. Der unterdrueckte Fehler machte aus "konnte ich nicht feststellen"
stillschweigend ein "ist in keiner AG" - und ausgerechnet daran haengt der Schritt, der den Restore
ueberhaupt erst moeglich macht.

Neu ist die private Hilfsfunktion `Get-sqmDatabaseAgMembership`. Sie fragt direkt die
Katalogsichten (`sys.availability_databases_cluster` fuer die Mitgliedschaft, clusterweit von jedem
Replikat lesbar, und `sys.dm_hadr_availability_replica_states` fuer die aktuelle Primary) und
beantwortet drei Zustaende statt zwei: AlwaysOn nicht aktiviert, aktiviert aber kein Mitglied, und
nicht ermittelbar. Der dritte Fall wirft jetzt, statt den Lauf auf einer falschen Annahme
fortzusetzen. Steht die Mitgliedschaft per Katalogsicht fest, laesst sich das SMO-AG-Objekt aber
nicht laden, bricht die Funktion ebenfalls ab, statt die Datenbank am Ende standalone
zurueckzulassen.

### Primary-Rueckfall zeigte auf die verbundene Instanz statt auf die Primary

War `AvailabilityGroup.PrimaryReplicaServerName` leer (etwa waehrend eines Failovers), fiel die
Funktion auf die verbundene Instanz zurueck. Ist das ein Sekundaerreplikat, scheitern Restore und
`ALTER DATABASE` dort aus demselben Grund erneut. Jetzt wird zuerst die per DMV ermittelte Primary
verwendet und erst danach, mit deutlicher Warnung, die verbundene Instanz.

### Weniger Rauschen im Log auf Einzelinstanzen

Die Pruefung "hat die Instanz genau eine AG, der die Datenbank beitreten soll" rief
`Get-DbaAvailabilityGroup` auch dann auf, wenn AlwaysOn auf der Instanz gar nicht aktiviert ist.
Das erzeugte bei jedem Restore auf einer Einzelinstanz die Warnung "Availability Group (HADR) is
not configured for the instance", die im Betrieb wie ein Problem aussieht, aber der Normalzustand
ist. Der Aufruf entfaellt jetzt in diesem Fall.

**Getestet:** Erkennung auf einer Instanz ohne AlwaysOn (sauberes "nein", kein Abbruch), Fehlerfall
auf einer nicht erreichbaren Instanz (Ausnahme statt stillem "nein"), beide Katalogabfragen gegen
SQL 2022, sowie der vollstaendige Standalone-Pfad von `Invoke-sqmRestoreDatabase` bis zum
Restore-Schritt. Der AG-Pfad selbst liess sich mangels verfuegbarer Availability Group nicht
durchspielen.

Dazu acht neue Pester-Tests in `tests/Unit/Public/Invoke-sqmRestoreDatabase.Tests.ps1`, die alle
sechs Zustaende der Erkennung abdecken und festhalten, dass der Lauf abbricht, BEVOR User-Export
oder Restore anlaufen, wenn die AG-Zugehoerigkeit nicht ermittelbar ist. Der entscheidende Test
wurde per Mutation gegengeprueft: mit dem alten stillen Fallback wieder eingebaut schlaegt er fehl.
Die vollstaendige Suite laeuft mit 189 Tests ohne Fehlschlag durch.

## [1.9.26.2] — 2026-07-28

### Fix: doppelte Parameterbindung brach 11 Aufrufe unter Windows PowerShell 5.1 ab

Elf Aufrufstellen in fuenf Funktionen splatteten eine Hashtable, die bereits
`ErrorAction = 'Stop'` trug, und setzten am selben Aufruf zusaetzlich ein explizites
`-ErrorAction`. Windows PowerShell 5.1 lehnt das mit `ParameterBindingException`
(`ParameterAlreadyBound`) ab, PowerShell 7 toleriert es stillschweigend — der Fehler ueberlebt
also jeden Test unter PS 7 und schlaegt erst auf der Zielplattform zu, die das Manifest mit
`PowerShellVersion = '5.1'` deklariert. Derselbe Fehler hatte in `sqmDataTransfer` 0.1.17.1
jeden regulaeren Resume-Lauf abgebrochen.

Betroffen waren `Set-sqmSsrsConfiguration` (4), `Set-sqmSsrsHttpsCertificate` (4),
`Install-sqmSsrsReportServer` (1), `Copy-sqmLogins` (1) und `Get-sqmLongRunningQueries` (1).
Bei den drei SSRS-Funktionen existierte die Splat-Hashtable praktisch nur, um `ErrorAction` zu
transportieren; dort ist der Schluessel entfallen, das explizite `-ErrorAction` je Aufruf bleibt.
Bei `Copy-sqmLogins` und `Get-sqmLongRunningQueries` wird umgekehrt der redundante explizite
Parameter weggelassen, weil dort weitere Aufrufstellen auf dem Hashtable-Wert aufsetzen.

Am gravierendsten war `Copy-sqmLogins`: die Ermittlung des `sa`-Kontos ueber die well-known SID
`0x01` — die dafuer sorgt, dass auch ein **umbenanntes** `sa` vom Login-Abgleich ausgeschlossen
wird — stand in einem `try` mit leerem `catch { }`. Unter PowerShell 5.1 scheiterte die Bindung,
der leere catch verschluckte den Fehler, und ein umbenanntes `sa` wurde ohne jede Meldung in den
Abgleich aufgenommen.

### Fix: `isset` in Install-sqmSsrsReportServer war kein PowerShell

Die Aufraeumzeile der SSRS-Vorhandenseinspruefung lautete `if (isset $checkSession)`. `isset`
ist PHP und im Modul nirgends definiert, der Aufruf warf also zwingend. Da er im selben `try`
stand wie die Pruefung selbst, landete jeder Lauf im `catch` und das Ergebnis war immer
"SSRS ist nicht installiert" — unter PowerShell 7 wegen `isset`, unter 5.1 schon eine Zeile
frueher wegen der doppelten Bindung. Korrigiert zu `if ($checkSession)`.

### Stille catch-Bloecke an zwei sicherheitsrelevanten Stellen protokollieren jetzt

Beide oben genannten Fehler konnten nur deshalb unbemerkt bleiben, weil ein leerer bzw.
pauschaler `catch` sie in ein harmlos aussehendes Ergebnis verwandelt hat. Die `sa`-Erkennung in
`Copy-sqmLogins` und die Vorhandenseinspruefung in `Install-sqmSsrsReportServer` setzen im
Fehlerfall jetzt eine WARNING ab, die benennt, welche Annahme stattdessen gilt. Das Verhalten
selbst bleibt unveraendert.

### Neu: Tools/Test-DuplicateParameterBinding.ps1

AST-basierte Pruefung, die genau dieses Muster modulweit findet — inklusive nachtraeglicher
Index-Zuweisungen (`$p['ErrorAction'] = 'Stop'`), aller Common Parameter und der
Parameter-Abkuerzungen (`-ea`, `-wa`). Haengt im Pre-Push-Hook und als eigener Schritt in der CI.
Ein reiner Import-Test findet diese Fehlerklasse nicht, da sie erst zur Aufrufzeit auftritt.

## [1.9.26.1] — 2026-07-17

### Fix: DiskFreeSpaceThresholdPct fehlte ausserhalb der kundenspezifischen Umgebung

`DiskFreeSpaceThresholdPct` wurde ausschliesslich in einem kundenspezifischen Konfigurationsblock
gesetzt und fehlte in den neutralen Standardwerten — obwohl `Set-sqmConfig` den Schluessel als
Parameter anbietet. Fuer alle Nutzer ausserhalb dieser Umgebung (also jeden, der ueber die
PSGallery installiert) existierte er damit gar nicht im Config-Store:
`Get-sqmConfig -Key 'DiskFreeSpaceThresholdPct'` lief in den Nicht-gefunden-Zweig, warnte und
lieferte `$null`, was `[int]$null` zu **0** machte.

- **`Get-sqmDiskInfoByDriveLetter`** war betroffen: mit Schwellwert 0 ist `$freePercent -lt 0`
  nie wahr, `$extendNeededGB` blieb also fuer jedes Laufwerk auf 0. Die Berechnung "wie viele GB
  muss erweitert werden" war ausserhalb dieser kundenspezifischen Umgebung still wirkungslos.
- **`Get-sqmServerHardwareReport`** fing den Wert bereits per `if ($diskThreshold -le 0) { 10 }`
  ab (zwei Stellen) und war inhaltlich korrekt — setzte aber die ueberfluessige Warnung ab.
- Die Warnung listete zudem bei jedem Aufruf saemtliche Konfigurationsschluessel ins Log.

Der Schluessel steht jetzt mit Default `10` in den neutralen Standardwerten, analog zu den
uebrigen `Check*`-Grenzwerten. Der Config-Store hat damit ausserhalb dieser Umgebung 32 statt 31
Schluessel.

## [1.9.26.0] — 2026-07-16

### Fix: Get-sqmWaitStatistics wies Leerlauf als Wartezeit aus

**BEHAVIOUR CHANGE:** Die Idle-Liste stammte aus einer Zeit vor SQL 2016 und kannte weder
`SOS_WORK_DISPATCHER` (2019+) noch `QDS_*` (2016+), `PREEMPTIVE_XE_DISPATCHER` oder
`MEMORY_ALLOCATION_EXT`. Trotz `IncludeIdle=False` landeten die im Report — und weil sie
dauerhaft im Leerlauf mitlaufen, dominieren sie jede Summe. Auf einer echten 2022er
Kundeninstanz (Top 25, 66.845.984 Sek. gesamt):

- `SOS_WORK_DISPATCHER` allein **88,3 %** der ausgewiesenen Wartezeit, dazu `QDS_*` mit 3,4 %.
- Damit war `WaitTimePct` wertlos: der eigentliche Befund — `CXCONSUMER`/`CXPACKET`/`CXSYNC_PORT` —
  erschien als harmlose 6,6 %.

Die Liste folgt jetzt der etablierten SQLskills-Ignore-Liste (Paul Randal), inklusive der Typen aus
2016/2017/2019 (`QDS_*`, `SOS_WORK_DISPATCHER`, `PARALLEL_REDO_*`, `PVS_PREALLOCATE`,
`PREEMPTIVE_XE_*`). Auf demselben Datensatz bleiben statt 66.845.984 noch **4.945.737 Sek.** echte
Wartezeit uebrig, und Parallelismus steht mit **88,6 %** da, wo er hingehoert.

Die Idle-Typen behalten ihre Kategorie und Empfehlung — mit `-IncludeIdle` sind sie weiterhin
sinnvoll beschriftet, nur eben nicht mehr im Default-Report.

`CXSYNC_PORT` wird als `Parallelism` gefuehrt statt als `Other`; mit 17,8 % der bereinigten
Wartezeit gehoert es zum Befund und nicht in die Restkategorie.

### Fix: Get-sqmWaitStatistics feuerte Empfehlungen auf die blosse Summe

**BEHAVIOUR CHANGE:** Die Recommendation-Spalte bewertete kumulierte Summen. Die wachsen aber allein
mit der Uptime, nicht mit dem Problem. Auf derselben Instanz:

- `PAGEIOLATCH_SH` mit **2,05 ms** Durchschnitt -> "Disk I/O bottleneck". 2 ms ist gesundes Storage.
- `SOS_SCHEDULER_YIELD` mit **0,12 ms** Durchschnitt -> "CPU pressure". Der instanzweite
  Signal-Wait-Anteil lag bei **2,7 %**, also weit weg von CPU-Druck.

Empfehlungen haengen jetzt an Schwellwerten, je nach dem, was den Wait-Typ tatsaechlich verraet:

- **`MinAvgWaitMs`** — Durchschnittsdauer, fuer I/O, Locks, Latches, Netzwerk.
  `PAGEIOLATCH_*` ab 10 ms, `WRITELOG` ab 5 ms, `LCK_M_*` ab 500 ms.
- **`MinWaitPct`** — Anteil an der bereinigten Wartezeit, fuer Parallelismus und Memory. Dort sind
  viele kurze Waits normal; weh tun sie erst in der Masse. Eine Durchschnittsschwelle haette hier
  genau den echten Befund verschluckt (`CXPACKET` liegt bei 2,31 ms).
- **`MinSignalWaitPct`** — instanzweiter Signal-Wait-Anteil, fuer `SOS_SCHEDULER_YIELD`. Das ist das
  etablierte Mass fuer CPU-Druck; die absolute Summe sieht auf jeder Instanz mit genug Uptime gross aus.
- Ohne Schwellwert wird immer gemeldet — `THREADPOOL` ist nie harmlos.

Unterschreitet ein Wait seinen Schwellwert, bleibt die Zelle **nicht leer**, sondern nennt den
gemessenen Wert und die Schwelle ("Unauffaellig: Durchschnitt 2,05 ms liegt unter dem Schwellwert
von 10 ms"). Sonst raet der Leser, ob "unauffaellig" oder "nicht bewertet" gemeint ist.

Neue Spalte **`SignalWaitPct`** je Wait, damit der Report die CPU-Bewertung selbst belegt. Der
instanzweite Anteil steht im Log.

## [1.9.25.0] — 2026-07-16

### Feature: Get-sqmLoginPermissions — Logins mit ihren Datenbankberechtigungen

Login-zentrierter Berechtigungsreport: Serverrollen und explizite Serverrechte, dazu je Datenbank
der zugeordnete User mit seinen Datenbankrollen und GRANT/DENY-Rechten. Eine flache Zeile je
Berechtigung, damit sich das Ergebnis filtern und nach CSV/HTML exportieren laesst.

- Die Zuordnung Login -> DB-User laeuft ueber die **SID, nicht ueber den Namen**. Beide duerfen
  abweichen, und sie tun es in der Praxis: auf der Testinstanz haengt am Login `sqmTestLogin` der
  User `sqmTestUser`. Ein Namensabgleich haette diese Berechtigung schlicht nicht gefunden.
- DB-User ohne passenden Login werden mit `-IncludeOrphanedUsers` als verwaist ausgewiesen
  (`IsOrphaned`), inklusive ihrer Rechte — sonst verschwindet genau der Fall, der sicherheitlich
  interessant ist.
- Alle UNION-Spalten tragen explizites `COLLATE DATABASE_DEFAULT`. Ohne das bricht die Abfrage mit
  einem Sortierungskonflikt ab, weil `sys.database_principals.name` (sysname,
  `Latin1_General_CI_AS_KS_WS`) und `permission_name` (`Latin1_General_CI_AS`) unterschiedlich
  sortieren. Auf der Testinstanz war das reproduzierbar.
- Nicht erreichbare oder offline Datenbanken werden mit Warnung uebersprungen statt den Lauf zu
  killen.

### Feature: Get-sqmLoginLastAccess — letzter Zugriff je Login, mit Quelle und Konfidenz

SQL Server speichert einen "letzten Login" **nirgends** persistent. Die Funktion sammelt deshalb nur,
was die Instanz wirklich belegen kann, und liefert zu jedem Wert `Source` und `Confidence` mit:

- `Live` — `sys.dm_exec_sessions`, also nur bestehende Sessions. Jeder Dienstneustart setzt das
  zurueck, weiter als `sqlserver_start_time` kann die Quelle nie zurueckblicken. Der Wert wird als
  `CoverageSince` mitgegeben, damit ein leeres Ergebnis einordenbar bleibt.
- `ErrorLog` — erfolgreiche Anmeldungen im Fehlerprotokoll. Nur verfuegbar bei `AuditLevel` 1 oder 3;
  der **Default 2 protokolliert ausschliesslich Fehlversuche** und liefert hier nichts. Wird erkannt
  und gemeldet, statt stillschweigend leer zu bleiben.
- Ohne Nachweis: `LastAccess = $null`, `Confidence = 'Unknown'` plus `Note`. Das heisst
  "nicht belegbar", **nicht** "nie benutzt" — die Unterscheidung wird bewusst nicht eingeebnet.

Der ErrorLog-Parser ist sprachneutral: die Vorlagen fuer 18453/18454 kommen aus `sys.messages` der
Instanz und werden zur Regex gebaut (`ConvertTo-sqmMessageRegex`, privat). Noetig, weil die Meldungen
lokalisiert sind — Englisch quotet einfach (`user 'x'`), Deutsch doppelt (`Benutzer "x"`), und die
Platzhalter unterscheiden sich (`%.*ls` vs `%1!`). Eine fest verdrahtete Regex haette auf jeder
deutschen Instanz still nichts gefunden. Gegen die echten Vorlagen in Englisch, Deutsch und
Franzoesisch geprueft, inkl. Namen mit Backslash und Apostroph; die Fehlermeldung 18456 matcht die
Erfolgs-Regex nachweislich nicht.

`DaysSince` rechnet gegen `GETDATE()` der Instanz, nicht gegen die Uhr des Clients — bei Zeitversatz
kamen sonst negative Werte heraus (auf der Testinstanz reproduziert).

Windows-**Gruppen**logins bekommen einen Hinweis: Mitglieder verbinden sich mit ihrem eigenen
AD-Konto, die Session wird nie der Gruppe zugeordnet. Ein leerer Wert ist dort erwartbar.

### Fix: Invoke-sqmLoginAudit meldete aktive Logins als "nie verwendet"

**BEHAVIOUR CHANGE:** Die Abfrage lieferte `NULL AS LastLogin` — eine feste Konstante, keine Spalte.
Damit war die Inaktivitaetspruefung tot und jeder Login fiel in den `elseif`-Zweig. Folge:

- **Falsch positiv:** jeder aktivierte SQL-Login, der aelter als die Schwelle war, wurde als
  "seit X Tagen nie verwendet" gemeldet — auch wenn er in derselben Sekunde verbunden war. Ein
  gestern benutzter und ein nie benutzter Login waren nicht unterscheidbar.
- **Falsch negativ:** Windows-Logins bekamen nie einen Inaktivitaetsbefund, weil der Zweig auf
  `SQL_LOGIN` filterte. Ein seit Jahren toter Domaenen-Account blieb unauffaellig.

Neu: der letzte Zugriff kommt aus `Get-sqmLoginLastAccess`. `Inactive` wird nur noch gemeldet, wenn
der Zugriff **belegt** und aelter als die Schwelle ist — mit Datum und Quelle im Befund. Der
Befundtyp `NeverUsed` entfaellt ersatzlos; er war nicht belegbar.

Reicht die Datenlage grundsaetzlich nicht, meldet der Report das **einmal pro Instanz**
(`NoAccessTracking`) statt pro Login. Ein Report, der auf einer Standardinstanz jeden Login
anmeckert, uebertoent jeden echten Befund — die Luecke gehoert zur Instanz, nicht zum Login.
Neuer Schalter `-SkipAccessCheck` fuer Konten ohne `VIEW SERVER STATE` / `xp_readerrorlog`.
### Fix: letzter `HHmsqm`-Rest in `Private\`

`Test-sqmLoggingPath` trug die Formatzeichenfolge `yyyyMMddHHmsqmfff` noch. Der Sweep in 1.9.24.1
hatte nur `Public\` geprueft, deshalb blieb sie stehen. Auswirkung gering — der Name enthaelt
zusaetzlich `Get-Random`, und die Datei wird sofort wieder geloescht —, aber es ist derselbe Defekt.

## [1.9.24.1] — 2026-07-16

### Fix: corrupted timestamp format string in 19 functions, and lost report paths in Invoke-sqmQueryStore

- The .NET format string `yyyyMMdd_HHmsqm` appeared in 21 places across 19 functions in `Public\` —
  the residue of a search/replace for the `sqm` module prefix that ate the `mss` of `HHmmss`. It is
  a legal format string, so nothing ever threw: `m` is minutes without zero-padding, `s` is seconds
  without zero-padding, `q` is not a format specifier and is emitted literally. `18:12:05` became
  `1812q1` instead of `181205` — seconds effectively lost, minutes unpadded, a stray `q` in the
  filename. All 21 now read `yyyyMMdd_HHmmss`, matching the sibling functions that were never
  corrupted.
- **This was not only cosmetic.** `Invoke-sqmRestoreDatabase` (pre-restore safety backup) and
  `Invoke-sqmUserDatabaseBackup` used the broken stamp for `.bak` FILENAMES. Because the format
  collapses `HHmmss` to a value that no longer distinguishes seconds, two backups of the same
  database inside the same minute produced an identical filename and the second silently overwrote
  the first — including the safety backup taken immediately before a restore.
- `Invoke-sqmQueryStore` additionally wrote both of its reports to the wrong place. Lines 603/641
  interpolated `"$baseFile_TopQueries.csv"` and `"$baseFile_Issues.txt"`; an underscore is a legal
  character in a PowerShell variable name, so these parsed as the single, undefined variables
  `$baseFile_TopQueries` / `$baseFile_Issues`, expanded to empty, and the paths became literally
  `.csv` and `.txt` in the process's current directory. `$OutputPath` was ignored (the directory was
  created and left empty) and every database in the loop overwrote the previous one's file. Now
  `"${baseFile}_..."`, the brace form already used on the adjacent line 598.
- Both defects share a failure mode: legal syntax, no exception, wrong output. The QueryStore log
  line had been printing `gespeichert: .csv` all along.
- Verified: no occurrence of `HHmsqm` remains under `Public\`; no bare `$var_suffix` interpolation
  remains; all files in `Public\` parse without errors and retain their UTF-8 BOM.

## [1.9.24.0] — 2026-07-15

### Feature: Invoke-sqmRestoreTest — evidence is now localized (en-US / de-DE)

**BEHAVIOUR CHANGE:** the evidence report used to be German unconditionally. It now follows the
module configuration key `Language`, whose default is `en-US` — so after this update the report is
**English by default**. German output: `Set-sqmConfig -Language de-DE` (once per machine; the value
is persisted). Everything else is unaffected — only this function's TXT/HTML evidence is localized.

- First function in the module to actually use the localization infrastructure. `Get-sqmString`,
  `_s`, `Private\Strings\de-DE.psd1` and `en-US.psd1` have shipped for a while but were used by
  0 of 153 functions; the `Language` default of `en-US` was therefore never exercised. Restore-test
  evidence is the natural first candidate: it is the output most likely to be handed to an
  international auditor.
- 36 new string keys per language file (`RestoreTest_*`). Verified that both files carry all keys
  and that every key used in code exists in both.
- Number formatting follows the report language, not the OS. Format-sqmFileSize/-TimeSpan format via
  `"{0:N2}"` against the CURRENT culture, so on a German Windows an English report would have read
  "213,08 MB" — which an English reader parses as 213 THOUSAND. The thread culture is now set to
  the report language around the formatting and restored in a `finally`, so a failure cannot leave
  the session's culture altered. Verified: en-US gives "213.08 MB", de-DE gives "213,08 MB", and
  the session culture is unchanged afterwards.
- The TXT label column width is now computed rather than hardcoded. Translated labels differ in
  length ("Datenmenge (Backup)" vs "Data volume (backup)"), and the previously fixed padding would
  have broken the alignment in whichever language it was not written for.

## [1.9.23.1] — 2026-07-15

### Fix: Invoke-sqmRestoreTest reported "0 B" for data volume and throughput in a real environment

- Reported from a production environment: the evidence showed 0 B for data volume and throughput
  even though the restore itself succeeded. Not reproducible on the lab instance, where
  Restore-DbaDatabase returns BackupSize as a dbatools Size object.
- Root cause: the size was read as `[long]$row.BackupSize.Byte`, guarded only by
  `if ($row.BackupSize)`. That guard passes for ANY non-null value, but `.Byte` only exists on the
  dbatools Size object. Where dbatools hands back a plain numeric value (or $null) instead -
  version- and code-path-dependent - `.Byte` resolves to $null, `[long]$null` is 0, and the
  measurement silently became 0 B. A restore test that documents "0 B" is worthless as evidence,
  and it failed silently: Status still said Success.
- `ConvertTo-sqmSizeBytes` now handles all shapes: Size object (.Byte), plain numeric value,
  numeric string, $null, and anything unusable. Verified against each.
- Added a fallback: if the restore result yields no usable size, it is read from the backup header
  (RESTORE HEADERONLY), where BackupSize/CompressedBackupSize are plain Int64 and independent of
  how dbatools types them. Deduplicated by BackupSetGUID, because every stripe of a striped backup
  reports the same set with the same total size - summing naively would multiply the data volume.
  The chain case (Full/Diff/Log) has distinct GUIDs and still sums correctly.
- If the size cannot be determined at all, the evidence now says "nicht ermittelbar" instead of
  "0 B", the physical-size note says "unbekannt" instead of claiming (un)compressed, and an ERROR
  is logged. An unknown number must not masquerade as a measured zero.
- The result object carries `SizeSource` (`RestoreResult`, `BackupHeader`, `Unknown`) so the origin
  of the number is visible.

## [1.9.23.0] — 2026-07-15

### Feature: Invoke-sqmRestoreTest — auditable restore test (success, data volume, throughput, duration)

- New function for the recurring "prove your restores work" obligation: restores a backup into a
  copy under a different name, measures the restore and writes the evidence as TXT + HTML into
  `<OutputPath>\RestoreTest` (default `C:\System\WinSrvLog\MSSQL\RestoreTest`), using the module's
  standard report helpers (ConvertTo-sqmHtmlReport, Get-sqmReportReference, Invoke-sqmOpenReport).
- Deliberately a separate function rather than an extension of Invoke-sqmRestoreDatabase, and with
  NO AlwaysOn handling: a restore test produces a throwaway copy, which must never be joined to an
  availability group. Invoke-sqmRestoreDatabase remains the AG-aware productive restore.
- Safety model - a restore test must never destroy existing data:
  - The target name must start with `RestoreTest_` (rejected before a connection is even opened),
    and must differ from the source database name.
  - An existing target aborts the run unless `-AllowReplaceExistingTestDatabase` is given; only
    then is WITH REPLACE used, and only for a `RestoreTest_`-prefixed name.
  - If the target does not exist, the restore runs WITHOUT REPLACE, so SQL Server itself refuses
    to overwrite anything should the name unexpectedly be taken.
  - `-ReplaceDbNameInFile` renames the physical files, so the restore can never write over the
    source database's data files.
  - The `RestoreTest_` prefix is a code constant, not a config key - a settable guard is no guard.
  - The optional `-RemoveTestDatabase` drop re-checks the prefix independently.
- The test database is KEPT by default (customers frequently want to test against the copy);
  `-RemoveTestDatabase` cleans up.
- Duration and throughput are measured as wall-clock time around the restore, NOT taken from
  dbatools' `DatabaseRestoreTime`: that value only has whole-second resolution. Verified on DEV01 -
  SQL reported 00:00:01 for a restore that actually took 2.42s, which would have inflated the
  documented throughput from a true 94 MB/s to 228 MB/s. The SQL-reported value is still carried in
  the result object as `SqlReportedRestoreTime` for reference.
- Data volume is reported as BackupSize (logical), formatted via Format-sqmFileSize (auto-scales to
  MB/GB/TB). For compressed backups CompressedBackupSize (physically read bytes) is reported
  alongside, since the two differ substantially and the distinction matters when the throughput
  figure is questioned.
- Evidence retention: new module config key `RestoreTestRetentionMonths` (default 12), overridable
  per run via `-RetentionMonths`; 0 keeps evidence forever. The cleanup only ever touches files
  matching this function's own naming pattern (`RestoreTest_*` AND extension `.txt`/`.html`), so
  pointing `-OutputPath` at a shared directory cannot delete unrelated files. It runs after the
  current evidence has been written, so a failing cleanup cannot cost the new report.

### Feature: Invoke-sqmRestoreTest — the backup to restore is determined automatically (Ola-ready)

- `-BackupFile` is now OPTIONAL. Without it the newest FULL backup is looked up automatically:
  msdb backup history first (Get-DbaDbBackupHistory -LastFull), directory scan as fallback.
  `-IncludeChain` restores the whole chain (last full + diff + subsequent logs) instead.
- This is what makes the recurring restore test usable with Ola Hallengren at all. Ola timestamps
  every backup file, so the fixed path baked into the job wrapper would have been dead after the
  next backup run - and possibly already deleted by Ola's @CleanupTime. New-sqmRestoreTestJob now
  omits `-BackupFile` from the generated wrapper unless one was explicitly given, so every run
  resolves the current backup itself.
- msdb is preferred because it reports the path SQL Server actually wrote, independent of Ola's
  @DirectoryStructure/@FileName. Verified on DEV01, whose structure is `<DB>\FULL\` - i.e. WITHOUT
  the server-name level Ola's default would produce - which is exactly why a scan with hardcoded
  assumptions is the wrong primary source.
- The scan exists for what msdb cannot answer: Ola's own sp_delete_backuphistory job purges the
  history, and a test running on a different instance than the backup has no history at all. It
  goes through Get-DbaFile (xp_dirtree on the instance), not Get-ChildItem - the backup files sit
  on the SQL Server's disk, not the executing machine. Get-DbaFile returns no timestamp, so
  ordering comes from the timestamp IN the file name; with Ola's `_FULL_yyyyMMdd_HHmmss` scheme
  lexicographic order equals chronological order. Files are grouped by that timestamp so a striped
  backup returns all its parts.
- `-IncludeChain` only works via msdb: the LSN relationship cannot be read off file names, so the
  scan can only ever return a full backup. It logs a warning and degrades to full-only rather than
  silently pretending a chain was tested.
- The evidence records which backup was used AND how it was found (`BackupSource`: BackupHistory /
  DirectoryScan / Parameter) - an auditor must be able to see which backup a measurement refers to.
- Verified end to end against a real Ola installation on DEV01: newest of two same-day fulls picked
  correctly, chain resolved as Full+Log, scan fallback picked the right file after the history was
  removed, and an unknown database fails with a clear message instead of a confusing restore error.

### Fix: Invoke-sqmRestoreTest — evidence claimed "komprimiert gelesen" for uncompressed backups

- The report printed the physical size with a hardcoded "(komprimiert gelesen)" note. Ola on DEV01
  writes uncompressed backups by default, so the evidence stated 213,08 MB "komprimiert gelesen"
  next to an identical logical size - a plainly false statement in a document that goes to auditors.
- Compression is now derived (physical < logical) and the note reads "unkomprimiert" accordingly.

### Feature: New-sqmRestoreTestJob — scheduled SQL Agent job for the recurring restore test

- Generates a wrapper under the module's jobs folder and creates an Agent job running
  Invoke-sqmRestoreTest, following New-sqmRestoreDatabaseJob's pattern (own arg-line builder with
  single-quote escaping rather than the private _CreateCmdExecJobStep helper, which appends
  `-Verbose -ContinueOnError` - parameters Invoke-sqmRestoreTest does not have - and quotes with
  double quotes, interpolating `$` in paths).
- Unlike New-sqmRestoreDatabaseJob (on-demand restore, deliberately unscheduled), a restore test is
  a recurring obligation, so this job IS scheduled: Monthly on the 1st at 02:00 by default,
  matching the usual audit cadence. `-ScheduleType Weekly/Daily`, `-NoSchedule` for manual starts.
  `-ScheduleDayOfMonth` is capped at 28 so the schedule also fires in February.
- A job run drops the test database by default (`-RemoveTestDatabase` is baked into the wrapper):
  an unattended recurring job would otherwise leave a full-size copy behind on every run until the
  volume fills up. `-KeepTestDatabase` opts out.
- `-SqlCredential` creates job/step/schedule from a workstation but is deliberately NOT embedded
  into the generated wrapper - the job runs under the SQL Agent service account's Windows identity;
  a password in a script on disk would be the wrong trade.
- The `RestoreTest_` prefix rule is validated at job-creation time, so an invalid
  `-TestDatabaseName` fails immediately instead of at the first scheduled run months later.
- The generated step uses `-Confirm:$false -EnableException -NoOpen`, so a failure makes the Agent
  job go red (a restore test that silently does nothing is worse than none: no evidence while
  everyone assumes the obligation is covered), and no browser is launched in a session-less context.

## [1.9.22.0] — 2026-07-14

### Fix: EventLog.SourceExists() SecurityException aborted the whole run under low-privilege accounts

- Verified New-sqmRestoreDatabaseJob + Invoke-sqmRestoreDatabase end to end as a real SQL Agent
  job on a standalone test instance (DEV01), running as NT SERVICE\SQLSERVERAGENT. The restore
  itself worked (export → restore → user re-import → orphan repair → owner=sa, data verified), but
  the run initially failed in the `begin` block with
  "Ausnahme beim Aufrufen von SourceExists ... Protokolle, auf die kein Zugriff moeglich war:
  Security" - a `System.Security.SecurityException`.
- Root cause: `[System.Diagnostics.EventLog]::SourceExists()` scans ALL event logs - including the
  Security log, which requires elevated rights - when the source does not yet exist. Under a
  low-privilege account (e.g. the SQL Agent service account running the function's own Agent job)
  that throws. In both `Invoke-sqmRestoreDatabase` (since 1.9.14.0) and `Repair-sqmAlwaysOnDatabases`
  the `SourceExists()` call sat OUTSIDE the try/catch (only the `New-EventLog` inside was guarded),
  so the exception aborted the entire operation. It only surfaced on machines where the
  `sqmAlwaysOn` event source did not already exist (on servers where a prior elevated run created
  it, `SourceExists()` returns immediately and never scans Security) - which is why it wasn't seen
  before on established production servers.
- Both functions now wrap the `SourceExists()`/`New-EventLog` block in try/catch. Event-log
  integration is best-effort; if the source can't be checked or created, a WARNING is logged and
  the restore/repair continues. The later `Write-EventLog` calls were already
  `-ErrorAction SilentlyContinue`.
- The other functions using `SourceExists()` (Compare-sqmAlwaysOnLogins, Compare-sqmAlwaysOnRoles,
  Sync-sqmLoginsToAlwaysOn, Invoke-sqmTempSysadminAction) already had it inside try/catch and were
  not affected.

### Fix: Get-sqmSpnReport — AlwaysOn-listener SPN check never actually ran (undefined $connParams)

- The AlwaysOn-listener SPN check queried the instance via `Invoke-DbaQuery @connParams`, but
  `$connParams` was never defined anywhere in the function - Get-sqmSpnReport is otherwise purely
  WMI/CIM/registry- and setspn-based and had no SQL-connection concept. The splat of a
  non-existent variable meant `Invoke-DbaQuery` was called without its mandatory `-SqlInstance`,
  always threw a parameter-binding error, and the surrounding try/catch swallowed it as a
  WARNING - so the entire "check AG listener SPNs" feature (documented in the function's help)
  had silently never worked.
- Added a `-SqlCredential` parameter and now build `$connParams` properly for the listener query:
  the SQL target is the host name for a default instance or Host\Instance for a named instance,
  with `-SqlCredential` forwarded when supplied. The block is guarded by a check for
  `Invoke-DbaQuery` (dbatools) and skips cleanly (with a VERBOSE note) when dbatools isn't present,
  since the core setspn-based report doesn't need it.

## [1.9.21.0] — 2026-07-14

### Feature: New-sqmRestoreDatabaseJob — generate an on-demand SQL Agent job for a restore

- New function that creates a SQL Agent job which runs `Invoke-sqmRestoreDatabase` with the given
  parameters baked into a generated wrapper script (same wrapper/CmdExec pattern as
  `New-sqmAlwaysOnRepairJob` / `New-sqmAutoLoginSyncJob`). Lets a restore run on the SQL server
  itself as the Agent service account instead of interactively from a remote workstation.
- Deliberately created **without a schedule** - a restore is on-demand, not recurring - so the job
  is started manually (`Start-DbaAgentJob`) or via the function's `-StartJob` switch.
- Mirrors the restore-relevant parameters of `Invoke-sqmRestoreDatabase` (`-BackupFile` /
  `-BackupFiles`, `-DatabaseName`, `-NewDatabaseName`, file-path overrides, `-BackupBeforeRestore`,
  `-NoUserExport`, `-KeepAlwaysOn`, `-AvailabilityGroupName`, `-WithNoRecovery`,
  `-ContinueWithNoRecovery`, `-ForceSingleUser`, `-NoRejoinAvailabilityGroup`) plus job-management
  parameters (`-JobName`, `-StepName`, `-Force`, `-StartJob`). The generated step uses
  `-Confirm:$false -EnableException` so a restore failure makes the Agent job fail visibly.
- Follows the module's existing job-auth convention: no SQL credential is embedded in the wrapper;
  the job connects to the target via the Agent service account's Windows identity (which must be
  sysadmin on the target, and on all replicas for an AG database).
- Registered in `FunctionsToExport` and the GUI category map (Backup & Recovery).

## [1.9.20.0] — 2026-07-14

### Fix: Invoke-sqmRestoreDatabase — UserExport failing after 1.9.19.0's working-instance change

- Found live while testing 1.9.19.0 against an AG database run directly on the Primary:
  `Export-DbaUser` failed with a generic SMO "exception occurred while trying to enumerate the
  collection" / "exception occurred while executing a Transact-SQL statement" error that did not
  happen before that change.
- Suspected cause: `AvailabilityGroup.PrimaryReplicaServerName` can report the AG replica under a
  different string form than the `-SqlInstance` value the caller passed in (FQDN vs short name,
  different casing) even when it is the exact same machine - a pure formatting difference that can
  still break Kerberos delegation for the permission-enumeration queries `Export-DbaUser` needs.
  Since 1.9.19.0 started using that resolved name (`$workInstance`) instead of the caller's
  original string for every operation, this surfaced for the first time.
- The resolved primary name is now compared to `-SqlInstance` by short hostname (case-insensitive,
  domain suffix stripped) rather than exact string equality; when they refer to the same machine,
  the caller's original `-SqlInstance` string is kept for `$workInstance` instead of substituting
  the AG-reported name, avoiding the format mismatch entirely.
- Added an unconditional DEBUG log line recording both raw strings compared, so a recurrence gives
  concrete evidence instead of requiring another guess.

## [1.9.19.0] — 2026-07-14

### Fix: Invoke-sqmRestoreDatabase — every operation now always targets the Primary for an AG database

- Restructured so the "working instance" for a run is resolved exactly once, right after AG
  detection, instead of being decided ad hoc (and inconsistently) at each step:
  - For an AG-managed database, the working instance is always the AG's Primary replica
    (`AvailabilityGroup.PrimaryReplicaServerName`) - restoring or altering a database against a
    Secondary was never meaningful. Previously, `Restore-DbaDatabase` and every step downstream of
    it (user import, orphan-user repair, stale-login removal, owner assignment, the MULTI_USER
    revert) ran against whatever instance the function happened to be called with, which only
    worked by coincidence when that happened to be the Primary.
  - For a non-AG database, the working instance is simply the given `-SqlInstance` - unchanged.
  - AG membership/topology itself is still discovered via the given `-SqlInstance` (that view is
    available cluster-wide from any replica), but everything else - the database-exists/
    already-single-user check, the optional pre-restore backup, user export, single-user mode, the
    restore, and all post-restore cleanup - now consistently uses the resolved working instance.
- `-BackupBeforeRestore` no longer excludes AG-managed databases. It now behaves identically
  whether or not the database is AG-managed, always running against the working instance -
  previously it silently did nothing for an AG database regardless of whether the switch was
  passed, which was confusing.
- The temporary PBM policy disable/re-enable (around user export/import) now also targets the
  working instance, for the same reason - it needs to apply wherever the actual DDL runs.

## [1.9.18.0] — 2026-07-14

### Fix: Invoke-sqmRestoreDatabase — replaced the 1.9.17.0 fallback with the actual root-cause fix

- The `$primaryInstance` null bug fixed in 1.9.17.0 was patched with a fallback rather than fixed
  at the source. Root cause: primary-replica detection filtered `Get-DbaAgReplica`'s results by
  `Role -eq 'Primary'`, but that per-replica `Role` value can transiently report something other
  than exactly `'Primary'` (e.g. `'Resolving'`), so the filter can come back empty. This had
  always been a latent bug in the original code - it just never surfaced when the function
  happened to be run directly against the actual primary replica, which was the case for every
  prior successful use of this function. It only got hit once a run went through a path where
  that wasn't guaranteed.
- Replaced the whole `Get-DbaAgReplica | Where-Object Role -eq 'Primary'/'Secondary'` pattern
  (used both to determine the primary in the AG-removal step and to find secondaries for the
  seeding-mode check in the rejoin step) with `AvailabilityGroup.PrimaryReplicaServerName` - a
  dedicated SMO property on the AG object itself, and the authoritative source for "which replica
  is primary" rather than something inferred from possibly-transient per-replica state. Secondaries
  are now simply "every replica whose name isn't the primary", removing the dependency on `Role`
  matching an exact string entirely.

## [1.9.17.0] — 2026-07-14

### Fix: Invoke-sqmRestoreDatabase — rejoin failed with "Cannot bind parameter 'SqlInstance' because it is null"

- Found live while testing 1.9.16.0: if `Get-DbaAgReplica` didn't return a replica with
  `Role -eq 'Primary'` (e.g. AG mid-transition, or SMO reporting a non-'Primary' role like
  'Resolving'/'Unknown' at query time), `$primaryReplica` was `$null`, and
  `$primaryReplica.Name -ne $SqlInstance` evaluated true (comparing `$null` to a real string),
  so `$primaryInstance` was set to `$null` instead of falling back to the connected instance.
  Every later AG operation using `$primaryInstance` - including the rejoin step - then failed with
  "Cannot bind parameter 'SqlInstance' because it is null".
- `$primaryInstance` can no longer end up `$null`: if the primary replica can't be positively
  identified, it now falls back to the connected `$SqlInstance` with a clear WARNING logged,
  instead of crashing on a null-parameter bind.

## [1.9.16.0] — 2026-07-14

### Fix: Invoke-sqmRestoreDatabase — AG rejoin could still be skipped by a later cleanup-step failure

- Traced through the "was AG member at start -> does it get rejoined" path end to end. In the
  normal case it already worked, but found a gap: with `-EnableException`, if any of the
  non-critical post-restore cleanup steps (6-9: user re-import, orphan-user repair, stale
  Windows-login removal, owner assignment) threw, the exception propagated straight past the AG
  rejoin step (10) to the outer catch, so a database that was successfully restored could still
  end up left outside the AG with no rejoin attempt at all.
- Moved the AG-rejoin step into the function's `finally` block, gated by a new `$restoreSucceeded`
  flag (set only once the restore itself has actually completed). `finally` in PowerShell always
  runs even when an exception is rethrown from `catch`, so the rejoin is now guaranteed to be
  attempted whenever the database was AG-managed and the restore succeeded - regardless of what
  happens in the cleanup steps afterward. (If the restore itself failed or never ran,
  `$restoreSucceeded` stays false and rejoin is correctly skipped, since attempting to add a
  possibly broken/missing database back into the AG would be wrong.)
- Fixed an adjacent bug this reshuffle made more likely to hit: `$finalDbName` was only ever
  assigned at the start of the restore step, so if the function failed earlier (e.g. AG removal)
  after `$wasSingleUser` was already set (possible since 1.9.14.0's already-SINGLE_USER-at-start
  check runs even earlier), the `finally` block's MULTI_USER revert referenced `$null` and would
  have produced a broken `ALTER DATABASE [] SET MULTI_USER;`. `$finalDbName` now defaults to
  `$DatabaseName` from the start of the run.

### Feature: Invoke-sqmRestoreDatabase — a restored database must always end up on AlwaysOn

- Policy change: previously, a database that was NOT an AG member before the restore was always
  left standalone afterward, even on an instance that has an AG - AG membership only ever
  happened for databases that were already AG members (or via the new `-AvailabilityGroupName`
  override from earlier in 1.9.14.0). That's backwards for an environment where every database on
  an AG-capable instance must be on AlwaysOn, including a database being restored/deployed there
  for the very first time.
- The AG-membership check (previously nested inside "if the database already exists") now always
  runs, so it also applies to a brand-new database name that has never existed on the instance
  before - not just to databases that already existed standalone. When the database is not
  currently an AG member and `-AvailabilityGroupName` wasn't given: if the instance has exactly
  one Availability Group, the restored database is automatically added to it (with seeding); with
  zero AGs there's nothing to join and it correctly stays standalone; with more than one AG the
  run aborts and requires `-AvailabilityGroupName` to disambiguate, rather than guessing.
- `-KeepAlwaysOn` now doubles as the deliberate opt-out for this auto-join, for a restore that must
  genuinely stay standalone (e.g. a scratch/test copy) even though the instance has an AG.

## [1.9.15.0] — 2026-07-14

### Feature: Get-sqmSpnReport — copy-paste-ready setspn commands + clipboard hand-off for the AD team

- Each per-instance report now includes a clean, comment-free "commands only" block (just the
  missing `setspn -S` commands plus a trailing `setspn -L` verification command) that can be
  selected and copied as-is, in addition to the existing annotated command list.
- Across all computers/instances processed in a single call, every missing-SPN command is now
  also collected into one dedicated hand-off file (`SpnReport_SetSpnCommands_<Timestamp>.txt`)
  and copied directly to the Windows clipboard (`Set-Clipboard`) - ready to paste straight into an
  email or ticket for the AD team, with `setspn -L` check commands for every affected (deduped)
  account appended at the end. Clipboard failures (e.g. non-interactive session) are logged as a
  WARNING without blocking the run; the file is still written either way.

## [1.9.14.0] — 2026-07-14

### Fix: Invoke-sqmRestoreDatabase — AG rejoin/reseed could be silently lost after a partial failure

- Follow-up to 1.9.13.0: rejoin was still not happening in practice for a database that a
  *previous, incompletely finished* run had already removed from the AG. Root cause: AG
  membership is auto-detected live at the start of the run (`Get-DbaAgDatabase`); once a database
  has actually been removed from the AG, it no longer shows up as an AG member, so a retry would
  silently skip secondary cleanup and the rejoin/reseed step entirely - with no error, since as
  far as the function could tell, it was never an AG database to begin with.
- Added `-AvailabilityGroupName` to force AG-aware handling regardless of current live
  membership, for exactly this retry scenario (or restoring a brand-new database straight into an
  existing AG). The AG-removal step now tolerates the database already not being a member (skips
  `Remove-DbaAgDatabase` gracefully) while still cleaning up secondaries and performing the
  rejoin/reseed at the end.
- The rejoin step now always writes to the Windows Application Event Log (source "sqmAlwaysOn",
  same source `Repair-sqmAlwaysOnDatabases` already creates) on both success and failure, so a
  failed reseed is visible to monitoring/alerting even if nobody inspects the returned result
  objects - this is exactly the kind of failure that must never go unnoticed.
- Added an unconditional trace log line before the rejoin decision (AG-membership/KeepAlwaysOn/
  NoRejoinAvailabilityGroup state) so a future "why didn't it rejoin" question can be answered
  from the log instead of guessing.
- Fixed a related gap in the 1.9.13.0 single-user reordering: it only accounted for single-user
  mode that *this function itself* set in an earlier run. If the database was already found in
  SINGLE_USER/RESTRICTED_USER mode when the run starts (e.g. left over from a previous interrupted
  restore) with another session holding the one connection slot, `Export-DbaUser` would still fail
  immediately with the same "database is already open and can only have one user at a time"
  error, since it can't get a connection either. The database is now checked via
  `$targetDb.UserAccess` immediately after connecting and, if not `Multiple`, reset to MULTI_USER
  right away (disconnecting whatever was holding it) before anything else runs.

## [1.9.13.0] — 2026-07-14

### Fix: Invoke-sqmRestoreDatabase — AG secondaries not seeded, Export-DbaUser single-user conflict

- Rejoining the AG after a restore (which is what triggers `Add-DbaAgDatabase`'s automatic
  seeding of the secondaries) was gated behind an opt-in `-RejoinAvailabilityGroup` switch, so by
  default a restored AG database was left standalone and the secondaries never got the database
  back at all. Replaced with `-NoRejoinAvailabilityGroup`: rejoining (and therefore reseeding the
  secondaries) is now the default for any database that was removed from an AG for the restore.
- Fixed `Export-DbaUser` failing with "Database '\<db\>' is already open and can only have one user
  at a time" (surfaced as a WARNING, silently producing an incomplete/empty user export). The
  database was being switched to `SINGLE_USER` *before* the user export step, but `Export-DbaUser`
  opens its own SMO connection to script out users/permissions, which collides with single-user
  mode. Single-user is now applied after the user export instead, right before the AG-removal/
  restore steps that actually need it.
- Corrected the AlwaysOn-Betriebs-Tools.md description, which incorrectly claimed `-KeepAlwaysOn`
  triggers AG rejoin+reseeding after restore (it actually aborts the restore if the database is
  still an AG member).

## [1.9.12.0] — 2026-07-14

### Feature: Compare-sqmServerConfiguration — per-login database mapping/roles, instance default language

- `-CompareLogins` now also compares, per login, which databases it is mapped into as a database
  user and which `db_*` roles it holds there (via `Get-DbaDbUser` + `Get-DbaDbRoleMember`) - the
  standard post-migration login check beyond just the server-level SID/default-DB/roles
  comparison already added in 1.9.11.0. A database where the mapping is missing entirely on one
  side is Critical (broken access); a role-set difference where both sides are mapped is Warning.
  Reported as one summary row per affected login, listing only the databases that actually
  differ.
- Instance property comparison now also includes the server's default language and default
  full-text language configuration (`sys.configurations` 'default language' /
  'default full-text language', via SMO `Configuration.DefaultLanguage` /
  `DefaultFullTextLanguage`), complementing the already-existing per-login default language check.

## [1.9.11.0] — 2026-07-14

### Feature: Compare-sqmServerConfiguration — Logins, migration-relevant objects, HTML report

- `Compare-sqmServerConfiguration` previously only diffed a handful of sp_configure/instance
  properties and (optionally) database name/owner/recovery model/collation, and returned raw
  objects with no report. Extended for post-migration verification:
  - New `-CompareLogins` switch: compares server logins between Source/Target (existence, SID,
    default database/language, disabled state, server-role membership, and password hash for SQL
    logins), with `-IncludeSystemLogins`, `-Login`, `-ExcludeLogin` filters matching the
    conventions of `Compare-sqmAlwaysOnLogins`.
  - New `-IncludeMigrationObjects` switch: compares Linked Servers, Credentials, SQL Agent Jobs,
    Endpoints, and Database Mail profiles between the two instances.
  - Instance property comparison extended with `ProductLevel`, `HostPlatform`, `IsClustered`,
    `IsHadrEnabled`, `XpCmdShell`, `ClrEnabled`, `ErrorLogPath`, `MasterDBPath`.
  - Every finding now carries a `Status` (OK/Warning/Critical) — missing logins/objects and SID or
    password-hash mismatches are Critical, most config drift is Warning.
  - Added TXT + HTML report output (shared `ConvertTo-sqmHtmlReport` theme) with `-OutputPath`,
    `-NoOpen`, `-NoReport`, auto-opened like the other Compare-* functions.
  - Fixed a latent bug in `-CompareDatabases`: the system-database filter checked
    `-not $_.IsSystemObject`, but the helper's returned object never carried that property (always
    `$null`), so master/model/msdb/tempdb were never actually excluded from the comparison.

### Feature: Set-sqmSsasDeploymentMode

- New function to correct an SSAS instance that was installed with the wrong SERVERMODE
  (Tabular vs. Multidimensional). Locates `msmdsrv.ini` via the service command line, backs it
  up, and updates the `<DeploymentMode>` element (0 = Multidimensional, 2 = Tabular), optionally
  restarting the service. Refuses to proceed when existing database folders are found under the
  instance's Data directory (the two modes use incompatible storage formats) unless `-Force` is
  passed. Supports `-WhatIf`/`-Confirm`.

## [1.9.9.1] — 2026-07-12

### Fix: Get-sqmCertificateReport always reported "Database Master Key: FEHLT"

- The DMK-encryption-status query selected `is_master_key_encrypted_by_server` from
  `sys.symmetric_keys`, but that column actually lives on `sys.databases` - the query always
  failed silently (caught by `-ErrorAction SilentlyContinue`), so `HasDatabaseMasterKey` and
  `DmkEncryptedBySmk` were always `$false` regardless of the real server state. Found while
  generating demo reports against DEV01 for the website. Fixed by joining `sys.symmetric_keys`
  (existence/modify_date) with `sys.databases` (encryption flag).

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
- Background: `Sync-sqmLoginsToAlwaysOn` failed in certain customer environments with "Policy 'New
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
  (`sqm BackupExclude - SYNC` by default, or using a customer-specific job-name prefix where one
  is configured). The job runs every 30 minutes via a `pwsh` CmdExec step and calls
  `Sync-sqmBackupExcludeTable -SqlInstance '.'`. Ensures `IsActive` changes from
  `Show-sqmBackupExcludeForm` are propagated to all AG secondaries without manual intervention.
  The job is updated on `-Update`; with `-CreateSyncJob $false` it is not created. Job name is
  derived from the configured job-name prefix (a customer-specific prefix is reused where set,
  otherwise the standard prefix applies). AG propagation: secondaries also get the sync job
  (recursive call with `CreateSyncJob = $CreateSyncJob` set).

**`New-sqmOlaUsrDbBackupJob`** — fixed a configuration bug (v1.8.4.0)
- Fix: `Set-sqmConfig` previously wrote the entire `$globalConfig` to `config.json`, which meant
  that on machines using a customer-specific job-name prefix, the OlaHH job names from an earlier
  default-prefix session could overwrite the customer-specific names. Fix (A): `Set-sqmConfig`
  now only saves explicitly passed keys (merge). Fix (B): in `sqmSQLTool.psm1`, `config.json` is
  loaded before the customer-specific configuration block - the customer-specific override always
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
