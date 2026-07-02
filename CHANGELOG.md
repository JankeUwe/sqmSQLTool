# sqmSQLTool — Changelog

## [1.8.13.0] — 2026-07-02

### Bugfix (kritisch)

**`New-sqmOlaUsrDbBackupJob`** — IsActive-Polaritaet in der Exclude-Abfrage invertiert
- Die in v1.8.11.0 gefixte Abfrage filterte auf `e.IsActive = 1`, um Ausschluesse zu
  bilden. Tatsaechliche Bedeutung von `IsActive` in `sqm_BackupExclude`: `IsActive=1`
  heisst "diese Datenbank soll gesichert werden" (Default fuer neu entdeckte
  Datenbanken, siehe `Sync-sqmBackupExcludeTable`), `IsActive=0` heisst "nicht sichern".
  Mit `WHERE IsActive = 1` wurden also genau die zu sichernden Datenbanken
  ausgeschlossen und die explizit stillgelegten (`IsActive=0`) gesichert — Polaritaet
  komplett invertiert.
- Fix: Filter auf `e.IsActive = 0` korrigiert.
- Verifiziert auf DEV02: echter FULL-Lauf sichert jetzt exakt die 9 Datenbanken mit
  `IsActive=1` (`AlwaysOnTest, amazon, DeadlockCollector, dtcSN, OperationsManagerDW,
  pdRessourcen, ReportServerTempDB, Solutioninfo, SolutioninfoSTA`) und uebersprang
  korrekt die 3 mit `IsActive=0` (`SSISDB, TestDB, ReportServer`).
- `Sync-sqmBackupExcludeTable` (Default `IsActive=1` fuer neue Datenbanken) war von
  Anfang an korrekt und musste NICHT geaendert werden — der Fehler lag ausschliesslich
  in der Leserichtung dieser einen Abfrage.

## [1.8.12.0] — 2026-07-02

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — expliziter `-BackupDirectory` wurde ueberschrieben
- Bisher wurde an JEDEN ermittelten Backup-Pfad `\Usr-db` angehaengt, auch wenn
  der Aufrufer `-BackupDirectory` explizit als vollstaendigen Zielpfad uebergeben
  hat. Fix: `\Usr-db` wird nur noch an automatisch ermittelte Pfade (Registry /
  `sqlSrv.BackupDirectory` / Default) angehaengt; ein explizit gesetzter
  `-BackupDirectory` wird unveraendert als Zielpfad verwendet.
- Verifiziert auf DEV02: `-BackupDirectory "C:\Temp\ExplicitTestPath"` ergibt
  exakt diesen Pfad ohne Suffix.

## [1.8.11.0] — 2026-07-02

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — Exclude-Prefix `!` war nie gueltige Ola-Syntax
- Ursache eines echten Produktionsvorfalls (BLBNBGFATDBA3, `DatabaseBackup`-Job
  schlug fehl): der in v1.8.6.0 eingefuehrte `!`-Prefix fuer Exclusions
  (`USER_DATABASES,!db1,!db2`) wird von Ola Hallengrens `MaintenanceSolution.sql`
  nirgends ausgewertet — dort wird ausschliesslich `-db1` als Exclude-Marker
  erkannt (`DatabaseItem LIKE '-%'`). Alle `!`-Eintraege wurden dadurch als
  positive (nicht existierende) Datenbanknamen interpretiert: Exclusions griffen
  nie, und die daraus resultierende lange "do not exist"-Warnliste sprengte das
  2047-Zeichen-Limit von `RAISERROR('%s', ...)`, wodurch die eigentliche
  Fehlermeldung im Job-Verlauf unsichtbar wurde.
- Fix: Prefix auf `-` korrigiert. Zusaetzlich Filter `EXISTS (SELECT 1 FROM
  sys.databases ...)`, sodass nur Datenbanken, die auf der jeweiligen Instanz
  tatsaechlich existieren, in die Exclude-Liste aufgenommen werden — verhindert
  erneutes Anwachsen der "do not exist"-Liste bei einer instanzuebergreifend
  gepflegten `sqm_BackupExclude`-Tabelle.
- Verifiziert auf DEV02: kompletter FULL-Backup-Lauf ueber die neu generierte
  Prozedur, 0 "do not exist"-Meldungen, alle aktiven Exclusions korrekt
  uebersprungen.

## [1.8.10.0] — 2026-07-02

### Bugfix

**`Show-sqmBackupExcludeForm`** — Job-Details im Info-Panel wieder korrekt
- `Load-JobInfo` parste `@Databases`, `@Directory` etc. bisher aus dem Step-Command.
  Nach Umstellung auf Prozedur-Architektur (v1.8.7) enthaelt der Step nur noch
  `EXEC master.dbo.[sqm_Run_...]` — die Parameter stecken im Prozedurkoerper.
- Fix: Proc-Name per Regex aus Step-Command extrahieren, dann
  `OBJECT_DEFINITION()` abfragen und daraus parsen. Fallback auf Step-Command
  fuer aeltere Jobs ohne Prozedur.
- `@Databases` im ExcludeTable-Modus wird aus dem `DECLARE`-Statement gelesen
  (statt aus `@Databases = @Databases` im EXECUTE-Aufruf).

## [1.8.9.0] — 2026-07-01

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — Drei Laufzeitfehler behoben
- `CREATE/DROP PROCEDURE master.dbo.[name]` war ungueltiges SQL (Database-Prefix
  in DDL-Statements nicht erlaubt). Fix: Prefix entfernt; `-Database master` auf
  der Invoke-DbaQuery-Verbindung setzt den Kontext korrekt.
- `Set-DbaAgentJobStep -StepId` existiert im dbatools-Parameter-Set nicht.
  Fix: `-StepName` verwendet (Backup-Jobs: `"DatabaseBackup $StepSuffix"`,
  Sync-Job: `'Sync sqm_BackupExclude'`).

## [1.8.8.0] — 2026-07-01

### Erweiterungen

**`New-sqmOlaUsrDbBackupJob`** — Neue Defaults + Auto-Setup bei -UseExcludeTable
- Standard-Aufruf ohne -Full/-Diff/-Log legt jetzt automatisch FULL + LOG an
  (statt Fehler). Info-Meldung im Log.
- Default FULL: 21:15 Uhr, EveryDay (vorher 20:00 / Sunday).
- Default LOG: alle 15 Minuten, EveryDay (vorher einmalig um 00:00).
- Mit -UseExcludeTable (nur auf Primary): ruft automatisch
  Sync-sqmBackupExcludeTable + Register-sqmBackupExcludeTrigger auf.
  Admin-Setup reduziert sich auf einen einzigen Aufruf.

## [1.8.7.0] — 2026-07-01

### Erweiterung

**`New-sqmOlaUsrDbBackupJob`** — Hilfsprozedur in master statt Inline-T-SQL im Job-Step
- Umstellung: Job-Step enthaelt nur noch `EXEC master.dbo.[sqm_Run_{JobName}]`.
  Der eigentliche Backup-Code wird als gespeicherte Prozedur in master angelegt.
  Proc-Name wird aus dem Job-Namen abgeleitet (Sonderzeichen → Unterstrich).
  Ergebnis im Agent-Fenster: Job-Step ist auf einen Blick lesbar.
  Prozedur wird bei jedem Aufruf (auch `-Update`) frisch DROP+CREATE'd.
  Bei AlwaysOn-Propagation erhalten die Secondaries ebenfalls ihre eigene Proc.

## [1.8.6.0] — 2026-07-01

### Bugfix

**`New-sqmOlaUsrDbBackupJob`** — UseExcludeTable Job-Step-SQL korrigiert
- Fix: Job-Step verwendete `@ExcludeDatabases` als Ola-Parameter — dieser existiert nicht.
  Ola's `DatabaseBackup` kennt nur `@Databases` mit `!`-Prefix-Syntax fuer Ausschluesse
  (`USER_DATABASES,!db1,!db2`). Dynamisches SQL via `sp_executesql` entfernt;
  Step baut jetzt direkt `@Databases = @Databases + ',' + @Exclusions` zusammen.
- Fix: `FOR XML PATH ... .value()` im Agent-Job-Step schlug mit QUOTED_IDENTIFIER-Fehler
  fehl wenn die Session-Option nicht gesetzt war. `SET QUOTED_IDENTIFIER ON;` an den
  Anfang des Step-SQL gesetzt.

## [1.8.5.0] — 2026-07-01

### Erweiterungen

**`New-sqmOlaUsrDbBackupJob`**
- Neu: Parameter `-CreateSyncJob` (`[bool]`, Default `$true`).
  Wenn `-UseExcludeTable` aktiv ist, wird automatisch ein SQL Agent Job
  (`sqm BackupExclude - SYNC` bzw. `FITS BackupExclude - SYNC` in FI-TS-Umgebungen) angelegt.
  Der Job laeuft alle 30 Minuten via `pwsh`-CmdExec-Step und ruft
  `Sync-sqmBackupExcludeTable -SqlInstance '.'` auf. Stellt sicher, dass `IsActive`-Aenderungen
  aus `Show-sqmBackupExcludeForm` ohne manuellen Eingriff auf alle AG-Secondaries propagiert werden.
  Der Job wird bei `-Update` aktualisiert; bei `-CreateSyncJob $false` wird er nicht angelegt.
  Job-Name leitet sich aus dem FULL-Job-Praefix ab (`FITS *` → FITS, sonst Standard).
  AG-Propagation: Secundaries erhalten ebenfalls den Sync-Job (rekursiver Aufruf mit gesetztem
  `CreateSyncJob = $CreateSyncJob`).

**`New-sqmOlaUsrDbBackupJob`** — Konfigurationsfehler behoben (v1.8.4.0)
- Fix: `Set-sqmConfig` schrieb zuvor die gesamte `$globalConfig` in `config.json`, wodurch
  auf FI-TS-Maschinen die OlaHH-Jobnamen aus einer frueheren Non-FITS-Session die FITS-Namen
  ueberschrieben. Fix (A): `Set-sqmConfig` speichert nur explizit uebergebene Keys (Merge).
  Fix (B): In `sqmSQLTool.psm1` wird `config.json` vor dem FI-TS-Block geladen —
  FI-TS-Override gewinnt immer.

## [1.8.3.0] — 2026-06-29

### Bugfixes & Erweiterungen

**`Sync-sqmLoginsToAlwaysOn`**
- Fix: Primary-Replica-Erkennung schlaegt auf Secondary-Instanzen nicht mehr fehl.
  `sys.dm_hadr_availability_replica_states.role_desc` liefert NULL/RESOLVING wenn von
  einer Secondary abgefragt — Umstieg auf `sys.dm_hadr_availability_group_states.primary_replica`,
  das auf jeder Replica den aktuellen Primary enthaelt.
- Fix: `Write-EventLog`-Fehler (AccessDenied) leckte auf die Konsole, weil der Setter eine
  non-terminating Exception wirft, die `catch { }` nicht abfaengt.
  `-ErrorAction SilentlyContinue` ergaenzt (EventId 9002 / 9003).

**`Invoke-sqmCollationChange`**
- Fix: `PropertyAssignmentException` bei `ProcessStartInfo.CreateNoNewWindow = $true` entfernt.
  Die Property kann nicht gesetzt werden wenn `UseShellExecute` noch nicht evaluiert wurde.
  Redundant: bei `UseShellExecute = $false` + `RedirectStandard* = $true` entsteht ohnehin
  kein Konsolenfenster.

**`Get-sqmSQLInstanceCheck`**
- Neu: Check **Instance Collation** (Status `Info`) — meldet `server.Collation` in jedem Lauf.
- Neu: Check **Database Collation vs. Instance** (nur mit `-Detailed`) — listet alle
  Benutzerdatenbanken, deren Collation von der Instanz-Collation abweicht, als `Warning`.

**`Compare-sqmServerConfiguration`**
- Neu: **Collation (Instance)** wird jetzt immer im Report ausgegeben (`Category = "Collation"`),
  nicht nur bei Abweichung — wichtig fuer Migrationschecks.

## [1.8.2.0] — 2026-06-26

### ✨ Temporäre Sysadmin-Rechte: AD-Login-Anlage, Cleanup & AlwaysOn

Erweiterung von `Grant-sqmTemporarySysadmin` / `Invoke-sqmTempSysadminAction`:

- **Login wird bei Bedarf angelegt** — fehlt der Login, legt das Tool ihn per
  `CREATE LOGIN [DOMAIN\Konto] FROM WINDOWS` an (statt wie bisher abzubrechen).
- **Nur AD-Logins** — `Grant-sqmTemporarySysadmin` weist Nicht-Windows-Logins ab;
  Existenzprüfung auf `type IN ('U','G')` beschränkt (keine SQL-/Zertifikats-Logins).
- **PBM-Policy-Handling beim Anlegen** — ist `DefaultPolicy` konfiguriert, wird diese
  Policy vor dem Anlegen via `Set-sqmSqlPolicyState -State Disable` deaktiviert und
  danach wieder aktiviert (steuerbar über `-DisablePolicy`, Default `$true`).
- **Selbst angelegter Login wird nach Ablauf entfernt** — neuer Schalter `-RemoveLogin`
  in `Invoke-sqmTempSysadminAction`: beim Entzug `DROP LOGIN`, aber als Sicherheitsnetz
  **nur**, wenn der Login an keiner weiteren festen Serverrolle (außer `public`) hängt.
  Bereits zuvor vorhandene Logins bleiben grundsätzlich bestehen.
- **AlwaysOn-fähig (Default)** — ist die Instanz Teil einer AG, werden Login-Anlage,
  sysadmin-Vergabe und Entzug/Cleanup auf **allen Replicas** ausgeführt. Jede Replica
  erhält eigene, lokal arbeitende, selbstlöschende Jobs → failover-robust. Abschaltbar
  über `-PrimaryOnly`; einzelne Replicas via `-SkipSecondaryServers` überspringbar.
- `Grant-sqmTemporarySysadmin` liefert jetzt **ein Ergebnisobjekt je Replica**
  (inkl. `LoginExisted`); neue Event-IDs 9003 (Login angelegt), 9004 (Drop übersprungen),
  9005 (Login entfernt).

## [1.8.1.0] — 2026-06-26

### ✨ Temporäre Sysadmin-Rechte mit automatischem Entzug

Für Patch-/Installationssituationen: ein Login zeitlich befristet zum **sysadmin** machen,
danach automatischer Entzug über einen **selbstlöschenden SQL-Agent-Job**.

- **`Grant-sqmTemporarySysadmin`** — vergibt sysadmin für `-Days` Tage. Ohne `-StartDate`
  **sofort** (inline) + Revoke-Job auf heute+X; mit `-StartDate` ein Grant-Job auf das Startdatum
  und ein Revoke-Job auf Startdatum+X. Optionale **`-TicketNumber`** (Auftragsnummer) fürs Log.
  `ConfirmImpact='High'` + `-WhatIf`.
- **`Invoke-sqmTempSysadminAction`** — führt `ALTER SERVER ROLE [sysadmin] ADD|DROP MEMBER`
  aus, protokolliert in **Modul-Logfile + Windows Event Log** (Source `sqmSQLTool`, inkl.
  Auftragsnummer) und **löscht bei Erfolg den aufrufenden Job** (`sp_delete_job`). Bei Fehler
  bleibt der Job (als fehlgeschlagen) erhalten. Auch für **manuellen vorzeitigen Entzug** nutzbar.
- One-Time-Jobs (`sp_add_schedule @freq_type=1`); Job-Steps rufen das Modul per `Import-Module sqmSQLTool`
  (Modulname, kein hardcodierter Pfad) auf. Revoke-Job läuft unter dem SQL-Agent-Dienstkonto.

## [1.8.0.0] — 2026-06-26

### ✨ Quellenbewusstes Auto-Update beim Import

Das Auto-Update (`AutoUpdate=$true`) erkennt eine neue Version und aktualisiert jetzt
**automatisch von der zuletzt verwendeten Installationsquelle** — für **alle** Quellen
(bisher nur UNC automatisch, PSGallery/GitHub nur Hinweis):

- **Quelle wird gemerkt**: `Install.ps1` speichert nach der Installation Typ + Pfad der Quelle
  (`Set-sqmConfig -InstallSourceType/-InstallSourcePath`). PSGallery-Installs werden zur Laufzeit
  via `Get-InstalledModule` erkannt (neue private `Get-sqmInstallSource`).
- **Quellenlogik „letzte Quelle, sonst Fallback"**: `Test-sqmModuleUpdate` prüft zuerst die letzte
  Quelle; ist sie unbekannt/nicht erreichbar, greift die Kette PSGallery→GitHub→UNC.
- **Automatisches Update je Quelle**: `Update-sqmModule` ist ein Dispatcher —
  PSGallery → `Install-Module -Force` (Scope automatisch AllUsers/CurrentUser),
  GitHub → Release-ZIP laden + entpacken (neue `Update-sqmFromGitHub`),
  UNC/LocalDir → Datei-Copy mit Backup (gemeinsame `Copy-sqmModuleFiles`).
- **Throttle**: On-Import-Check max. alle `UpdateCheckIntervalHours` (Default 24) via Marker-Datei —
  keine Netz-Calls bei jedem Import. Skip weiterhin über `SQMSQLTOOL_SKIP_AUTO_UPDATE=1`.
- Robust: Fehler beim Update (z. B. AllUsers ohne Adminrechte) brechen den Import **nie** ab.
- Neue Config-Keys: `InstallSourceType`, `InstallSourcePath`, `UpdateCheckIntervalHours`.

## [1.7.9.0] — 2026-06-26

### ✨ Get-sqmADGroupMembersRecursive — echter Anzeigename

- Für **User-Accounts** wird jetzt das echte AD-Attribut **`displayName`** aufgelöst (via `Get-ADUser`),
  statt nur den CN/Namen aus `Get-ADGroupMember` zu zeigen (der bei vielen Konten dem Login entspricht).
  Die `DisplayName`-Spalte zeigt damit den Personennamen. Fallback-Kette: `displayName` → CN/Name → `sAMAccountName`.
- **LDAP-Fallback-Pfad gehärtet:** Fehlte das `displayName`-Attribut, warf `InvokeGet` eine Exception und der
  Member ging verloren. Jetzt tolerantes Lesen mit derselben Fallback-Kette.

## [1.7.8.1] — 2026-06-25

### 🔧 Installer — dbatools-Abhängigkeit absichern

- **`Install.ps1`** stellt jetzt die Pflicht-Abhängigkeit **`dbatools` im selben Scope** sicher,
  bevor der Import-Test läuft. Bisher setzte der Installer voraus, dass dbatools bereits vorhanden
  ist → auf einem **frischen Server ohne dbatools** schlug der Import-Test fehl. Bei `-Scope AllUsers`
  wird dbatools systemweit installiert (kein Scope-Mismatch mehr, bei dem ein AllUsers-Modul ein nur
  in CurrentUser liegendes dbatools in fremden/Admin-Sessions nicht findet). Fehlt dbatools, wird es
  von der PSGallery nachinstalliert (TLS 1.2 + NuGet-Provider werden mit gesetzt).

## [1.7.8.0] — 2026-06-25

### 🐛 Kritischer Fix — TrustServerCertificate griff nie (modulweit)

- **`sqmSQLTool.psm1`**: Der Aufruf `Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true -Scope Session`
  verwendete den Parameter **`-Scope`, den `Set-DbatoolsConfig` (dbatools 2.8.x) nicht besitzt**. Die dadurch
  geworfene Exception wurde vom umgebenden `catch` still verschluckt (nur Write-Verbose), sodass
  `sql.connection.trustcert` **nie gesetzt** wurde. Folge: Gegen **SQL Server 2022 über TCP** schlug
  praktisch **jede** dbatools-Verbindung mit „The certificate chain was issued by an authority that is not
  trusted" fehl. Fix: `-Scope Session` entfernt (die Einstellung gilt ohnehin sessionweit).

### 🐛 Fixes — Get-sqmServerUtilization (gegen SQL 2022 live verifiziert)

- Datei war ohne UTF-8-BOM/CRLF gespeichert → PS 5.1 las Box-/Sonderzeichen falsch (Parse-Fehler). Jetzt BOM+CRLF.
- Ungültige Format-Interpolation `$($x:N0)` → `.ToString('N0')`.
- DMV-Queries korrigiert: `COUNT(*) FILTER(...)` (PostgreSQL) → `SUM(CASE...)`; Ring-Buffer-CPU via **XML**
  (`record.value(...)`) statt `JSON_VALUE`; Memory-Snapshot als ein Resultset (CROSS JOIN).
- Einzeiliges DMV-Resultat: `$result[0].Spalte` griff bei einem DataRow die erste *Spalte* statt der Zeile
  (→ 0-Werte). Jetzt `@($result)[0]` + `ISNULL(...)` in SQL gegen DBNull.

## [1.7.7.0] — 2026-06-25

### ✨ Neu / Erweiterung — Invoke-sqmTsmConfiguration

Die TSM-Konfiguration kann jetzt reale Umgebungen abbilden, in denen INCLUDE/EXCLUDE
in eine ausgelagerte Datei (INCLEXCL, z. B. `ie_dsm.opt`) ausgelagert sind:

- **`-UseInclExclFile`**: löst die `INCLEXCL`-Option aus der `dsm.opt` auf und schreibt
  den verwalteten Block in die referenzierte Include/Exclude-Datei statt in die `dsm.opt`.
- **`-InclExclPath`**: Zieldatei explizit angeben (wird bei Bedarf neu angelegt).
- **`-ExcludePatterns`**: eigene EXCLUDE-Patterns statt der fixen drei SQL-Typen.
- **`-IncludeRule`** (`@{ Path=...; ManagementClass=... }`): pro Pfad eine eigene
  Managementklasse (z. B. 365-Tage für ein `01Year`-Verzeichnis).
- **ManagementClass-Validierung gelockert**: `ValidateSet` → `ValidatePattern '^MC_[A-Za-z0-9._]+$'`.
  Real eingesetzte Klassen wie `MC_B_2.2_15.15.NA_IMG` oder `MC_B_NL_NL_365.365.NA` werden
  nicht mehr abgelehnt. **Rückwärtskompatibel**: bisher gültige Aufrufe bleiben gültig.
- Ergebnisobjekt um **`TargetFile`** erweitert (tatsächlich geschriebene Datei).

### 🔧 Hinweis

Liegt eine `dsm.opt`/ie-Datei unter Kontrolle eines Hersteller-TSM-Konfigurators, kann
dieser den verwalteten Block überschreiben — ggf. erneut ausführen.

## [1.7.6.0] — 2026-06-25

### ✨ Neu

- **Get-sqmServerUtilization**: Neue Report-Funktion für CPU/RAM-Auslastungs-Trends. Erfasst über mehrere 
  Zeitpunkte (default 6 Snapshots à 10 Sekunden = 1 Minute) Daten aus SQL-Server-DMVs: CPU %, Speichernutzung,
  Worker Threads, Kompilierungen. Berechnet Min/Max/Avg je Metrik und erzeugt Reports (TXT/CSV/HTML).
  Parameter: `-SampleCount` (default 6), `-SampleIntervalSeconds` (default 10).

## [1.7.2.0] — 2026-06-22

### 🔧 Fixes

- **Show-sqmToolGui**: Bei ShouldProcess-fähigen Befehlen war die „WhatIf (simulation)"-Checkbox
  **vorab angehakt** (`Checked = $true`/`$supportsWhatIf`). Dadurch lief „Run" bei genau diesen
  Befehlen ungewollt als reine Simulation statt echt auszuführen. Die Checkbox ist jetzt
  **standardmäßig deaktiviert** (opt-in): „Run" führt real aus, Simulation wird bewusst angehakt.

## [1.7.1.0] — 2026-06-22

### ✨ Neu

- **Get-sqmDiskSpaceReport — Bootstrap aus Backup-Historie (Methode B2)**: Neuer Schalter
  `-SeedFromBackupHistory`. Solange die Snapshot-Historie (B1) für ein Volume noch < `-MinDataPoints`
  Punkte hat, wird ersatzweise eine Wachstumsrate aus `msdb.dbo.backupset` abgeleitet: je Datenbank
  der Daten-Wachstumstrend aus den Full-Backup-Größen (lineare Regression, ab 3 Punkten) und
  proportional zur Datendatei-Größe auf die Volumes verteilt. Überbrückt die ~5-Läufe-Anlaufzeit von
  B1. Ausgewiesen mit `ForecastBasis='BackupHistory'`, Konfidenz `Low` (Report-Spalte `Boot`). Sobald
  B1 genug Snapshots hat, übernimmt wieder B1. Greift nur bei gesetztem Schalter; benötigt Lesezugriff
  auf `msdb.dbo.backupset`.

## [1.7.0.0] — 2026-06-22

### ✨ Neu

- **Get-sqmDiskSpaceReport — Wachstumsprognose neu auf Snapshot-Historie (Methode B1)**:
  Die Prognose basierte bisher ausschließlich auf AutoGrow-Events des Default Trace und blieb
  damit leer, sobald keine automatischen Dateivergrößerungen im Zeitfenster lagen (gut dimensionierte
  DBs) oder die kurze Default-Trace-Retention die Events verdrängt hatte. Stattdessen wird jetzt bei
  jedem Lauf die Volume-Belegung in eine JSON-Historie (`History\DiskHistory_<Instanz>.json`)
  geschrieben und über die letzten `-HistoryDays` Tage per **linearer Regression (Least Squares)**
  ausgewertet: `GB/Tag`, `DaysUntilFull` und eine Konfidenz (R²/Punktzahl: Low/Medium/High).
  - Misst den **tatsächlichen Verbrauchstrend** (auch Datenwachstum in vorab dimensionierten Dateien)
    und ist **mountpoint-sicher** (Auswertung je `volume_mount_point`).
  - Vor `-MinDataPoints` Läufen (Default 5) wird das Volume transparent als „Prognose sammelt noch
    Daten (n von m)" ausgewiesen statt still `n/a`.
  - Neue Parameter: `-HistoryPath`, `-MinDataPoints`, `-NoHistory`. Neue Ausgabefelder:
    `DataPoints`, `ForecastConfidence`, `ForecastBasis`. Report-Spalten: `GB/Tag`, `DaysFull`, `Konf`.
  - `-WhatIf` persistiert die Historie nicht.
  - Hinweis: Für belastbare Prognosen die Funktion regelmäßig planen (z. B. täglicher Agent-Job).

## [1.6.4.0] — 2026-06-22

### 🔧 Fixes — ungültige DMV-Spalten (gefunden per Live-Lauf + statischer DMV-Validierung gegen SQL 2022)

- **Get-sqmMissingIndexes**: Join referenzierte `mid.index_group_handle`, das es in
  `sys.dm_db_missing_index_details` nicht gibt (nur `index_handle`). Query lieferte „Ungültiger
  Spaltenname index_group_handle" → keine Ergebnisse. Join korrigiert auf
  `mid.index_handle = mig.index_handle`.
- **Get-sqmOperationStatus**: AutoSeed-Query nutzte die nicht existierenden Spalten `total_size_bytes`,
  `start_time` und `estimated_completion_time_ms` aus `sys.dm_hadr_physical_seeding_stats`. Korrigiert
  auf die realen Spalten `database_size_bytes`, `start_time_utc` und `estimate_time_complete_utc`
  (Restzeit per `DATEDIFF` in ms), per Alias auf die erwarteten Namen abgebildet.
- **Get-sqmAlwaysOnFailoverHistory**: optionale SQL-Ergänzung las `ars.role_start_time`, das es in
  `sys.dm_hadr_availability_replica_states` nicht gibt. Ersetzt durch die valide Spalte
  `current_configuration_commit_start_time_utc` (UTC-Näherung; maßgeblich bleibt das Event Log,
  EventID 1480). UTC-Vergleich und NULL-Schutz ergänzt.

## [1.6.3.0] — 2026-06-22

### 🔧 Fixes — dbatools-Parameter-/Cmdlet-Drift (gefunden per statischem Audit gegen dbatools 2.8.1, validiert gegen lokalen SQL 2022)

Mechanische Parameter-Korrekturen:
- **Invoke-sqmRestoreDatabase**: `Get-DbaDefaultPath -Type Backup` → `(Get-DbaDefaultPath …).Backup`
  (`-Type` existiert nicht; betraf den `-BackupBeforeRestore`-Pfad).
- **Test-sqmBackupIntegrity**: `Restore-DbaDatabase -FileListOnly` → `Read-DbaBackupHeader -FileList`
  (Restore-DbaDatabase kennt kein `-FileListOnly`; der Verify-Pfad nutzte bereits korrekt `-VerifyOnly`).
- **New-sqmBackupMaintenanceJob / New-sqmOlaMaintenanceJobs / New-sqmOlaSysDbBackupJob /
  New-sqmOlaUsrDbBackupJob**: `Set-DbaAgentJob -OperatorToEmail` → `-EmailOperator`.
- **Invoke-sqmDeployScripts**: `Connect-DbaInstance -EnableException` → `-ErrorAction Stop`
  (Connect-DbaInstance hat kein `-EnableException`).

Redesigns (Cmdlet existiert gar nicht):
- **Invoke-sqmUpdateStatistics**: nutzte `Update-DbaDbStatistic` — diesen Cmdlet gibt es nicht, die
  Funktion war wirkungslos. Neu implementiert über `Invoke-DbaQuery` mit echtem `UPDATE STATISTICS`;
  Zielstatistiken werden serverseitig aus `sys.stats`/`sys.dm_db_stats_properties` ermittelt, sodass
  `-OnlyModified`, `-Index`, `-Table`, `-Statistics` und `-SamplePercent` (FULLSCAN/SAMPLE) greifen.
- **Invoke-sqmConfigRollback**: `Set-DbaService -StartMode` existiert nicht. dbatools' `Get-DbaService`
  liefert CIM-Instanzen der Klasse `SqlService`; der StartMode wird jetzt über deren CIM-Methode
  `SetStartMode(UInt32)` gesetzt (Automatic=2, Manual=3, Disabled=4). Funktioniert unter PS 5.1 und 7.
- **Sync-sqmLoginsToAlwaysOn**: `Get-DbaAgentServiceAccount` existiert nicht. Das Agent-Dienstkonto
  kommt jetzt aus `sys.dm_server_services` (locale-robustes `LIKE '%Agent%'`) über die bestehende
  SQL-Verbindung.

## [1.6.2.0] — 2026-06-22

### 🔧 Fixes

- **Invoke-sqmRestoreDatabase**: Mehrere dbatools-Parameter passten nicht zur installierten
  Version und ließen den scharfen Lauf abbrechen:
  - `Export-DbaUser -Force` → `-Force` existiert nicht; jetzt `-FilePath` (Vollpfad) ohne `-Force`.
    (Behebt „A parameter cannot be found that matches parameter name 'Force'".)
  - `Restore-DbaDatabase -NewDatabaseName/-DatabaseFilePath/-LogFilePath` → diese Parameter gibt es
    nicht. Der (ggf. neue) Zielname läuft jetzt über `-DatabaseName` (`$finalDbName`), die physischen
    Datei-Namen/-Pfade regelt das bereits gebaute `-FileMapping`. Umbenennen + Verschieben damit
    versionsstabil.
  - User-Export-Dateiname: `$DatabaseName_` wurde als (leere) Variable interpretiert, der DB-Name
    fehlte im Namen; jetzt `${DatabaseName}` und korrektes Zeitstempelformat.
- **Invoke-sqmRestoreDatabase**: Doppelte Ergebniszeilen bei Früh-Returns (WhatIf/Fehler) behoben.
  Die `return $results` im `process`-Block sind jetzt bloße `return`; der `end`-Block gibt die Liste
  genau einmal zurück.

## [1.6.1.0] — 2026-06-22

### 🔧 Fixes

- **Invoke-sqmRestoreDatabase**: Brach bei existierender Ziel-Datenbank mit
  „A parameter cannot be found that matches parameter name 'Database'" ab. Ursache war
  `Get-DbaAvailabilityGroup -Database` (diesen Parameter gibt es nicht; der Parameter-Binding-Fehler
  ist terminierend und wird von `-ErrorAction SilentlyContinue` nicht abgefangen). AG-Mitgliedschaft
  wird jetzt über `Get-DbaAgDatabase` geprüft, das AG-Objekt über den AG-Namen nachgeladen.
- **Invoke-sqmLogging**: `-WhatIf` des Aufrufers leakte über `$WhatIfPreference` in die
  internen `Out-File`/`New-Item`-Aufrufe und erzeugte „What if: Output to File"-Rauschen, während
  gar kein Log geschrieben wurde. Beide Aufrufe laufen jetzt mit `-WhatIf:$false` (Logging ist ein
  Seitenkanal und darf nicht unter ShouldProcess fallen).

## [1.6.0.0] — 2026-06-21

### ✨ Neu

- **Invoke-sqmNtfsSetup**: Setzt NTFS-Berechtigungen für die SQL-Dienstkonten auf den
  Data/Log/TempDB/Backup-Verzeichnissen. Ermittelt Dienstkonten (Get-DbaService) und
  Verzeichnisse (Get-DbaDefaultPath + sys.master_files) automatisch, schreibt vorher ein
  ACL-Backup (SDDL je Verzeichnis), unterstützt `-WhatIf`/`-EnableException`.
  Schließt den Aufruf in SQLSetupTool\Modules\PostInstall.psm1, der bisher ins Leere lief.
- **Show-sqmToolGui**: Kleine WinForms-Oberfläche (Visual-Studio-Dark) mit allen exportierten
  Funktionen nach Kategorie gruppiert; erzeugt Parameter-Eingaben automatisch (inkl.
  Credential-Picker für PSCredential und Dropdowns für ValidateSet/Enum), Befehlsvorschau,
  Ausführen/Kopieren/Hilfe.

### 🔧 Fixes / Wartung

- **category-map.ps1** neu generiert (war Encoding-korrupt und unvollständig); deckt jetzt
  alle exportierten Funktionen ab.
- **CI**: GitHub-Actions-Workflow (PSScriptAnalyzer, BOM-Check, Import PS 5.1 + 7, Pester).
- **Tests**: Contract-Test, der die von SQLSetupTool genutzte Funktions-API einfriert.

## [1.5.1.0] — 2026-06-10

Versionssprung über das (fehlbenannte) Tag v1.5.0, damit die gesammelten Fixes 1.4.8 - 1.4.15
auf GitHub eindeutig die neueste Version sind und vom Update-Mechanismus gezogen werden.
Inhaltlich identisch mit 1.4.15.0 (siehe Einträge darunter); kein neuer Funktionscode.

## [1.4.15.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob / New-sqmAutoLoginCompareJob**: `-Overwrite` schlug fehl mit
  „A parameter cannot be found that matches parameter name 'Force'". `Remove-DbaAgentJob -Force`
  existiert nicht in jeder dbatools-Version; jetzt `-Confirm:$false` (versionsstabil, wie in
  allen anderen Job-Funktionen).

## [1.4.14.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginCompareJob**: dieselben Schedule-Fehler wie zuvor beim Sync-Job
  („SqlInstance is specified more than once", `ActiveStartTimeOfDay`, versionsabhängige
  `New-DbaAgentSchedule`-Parameter, doppelte Schedules). Zeitplan jetzt über native
  msdb-Prozeduren (`sp_add_schedule` / `sp_attach_schedule`), Duplikate vorher per
  `schedule_id` entfernt.

### ♻️ Vereinfachung

- **New-sqmAutoLoginCompareJob**: Job-Step ist jetzt zwei Zeilen - `Import-Module` plus
  `Compare-sqmAlwaysOnLogins -FailOnDrift`. Keine Hashtable, keine Pfade, kein Servername.
- **Compare-sqmAlwaysOnLogins**: neuer Schalter `-FailOnDrift`. Bei Login-Drift
  (Warning/Critical) wird Windows Event 9001 (Splunk) geschrieben und eine Ausnahme geworfen,
  sodass der SQL-Agent-Job rot wird (Drift-Alarm via OnFailure-Operator). Impliziert `-NoOpen`;
  der Report wird vorher geschrieben.

### 🌐 Sonstiges

- **Default-Ausgabesprache auf `en-US`** umgestellt (Modul-Config `Language` + Get-sqmString-
  Fallback). Betrifft alle über Get-sqmString lokalisierten Strings. Hinweis: noch hartkodiert
  deutsche Reports bleiben deutsch, bis die Mehrsprachigkeits-Migration abgeschlossen ist.

## [1.4.13.0] — 2026-06-10

### ♻️ Vereinfachung

- **Sync-sqmLoginsToAlwaysOn** läuft jetzt sinnvoll ohne jede Angabe: `Force`, `BackupLogins`
  (je $true) und `BackupRetentionDays` (7) sind Defaults. Ein bloßes `Sync-sqmLoginsToAlwaysOn`
  hält die Secondaries komplett synchron (SqlInstance = Computername, AG = erste gefundene,
  Pfade aus den Settings). Opt-out via `-Force:$false` / `-BackupLogins:$false`.
- **New-sqmAutoLoginSyncJob**: Job-Step ist jetzt nur noch zwei Zeilen - `Import-Module` plus
  der parameterlose Aufruf `Sync-sqmLoginsToAlwaysOn`. Keine Hashtable, keine Pfade, kein
  Servername, keine AG im Step.

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob**: „There are two or more schedules named …" - mehrfach vorhandene
  Schedules gleichen Namens (aus früheren Fehlversuchen) werden jetzt vor dem Anlegen per
  `schedule_id` in einer Schleife entfernt, statt per mehrdeutigem `@schedule_name`.
- **Sync-sqmLoginsToAlwaysOn**: meldet Fehlschläge per Windows Event Log (Source 'sqmSQLTool',
  EventId 9002) für Splunk - der schlanke Job-Step braucht dafür keinen eigenen throw mehr.

## [1.4.12.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob**: Zeitplan-Erstellung scheiterte versionsabhängig an
  `New-DbaAgentSchedule` („A parameter cannot be found that matches parameter name 'Force'",
  „… 'sch_…' is not a valid value for the Schedule variable"). Die Parameter dieses Cmdlets
  variieren je dbatools-Version. Der Zeitplan wird jetzt über native msdb-Prozeduren
  (`sp_add_schedule` / `sp_attach_schedule`) per `Invoke-DbaQuery` erstellt - identisch stabil
  auf jeder SQL-Server- und dbatools-Version, kein API-Raten mehr.

## [1.4.11.0] — 2026-06-10

### 🔧 Fixes

- **New-sqmAutoLoginSyncJob**: Job-Erstellung schlug fehl mit „A parameter cannot be found that
  matches parameter name 'ActiveStartTimeOfDay'". `ActiveStartTimeOfDay` ist eine SMO-Property,
  kein `New-DbaAgentSchedule`-Parameter. Zeitplan nutzt jetzt korrekt `-StartTime` (Format
  `HHMMSS`), für Weekly/Monthly `-FrequencyRecurrenceFactor`, für stündlich
  `-FrequencySubdayType Hours` / `-FrequencySubdayInterval`.

## [1.4.10.0] — 2026-06-10

### 🔧 Fixes

- **Copy-sqmLogins / AlwaysOn-Login-Sync**: umbenannte `sa` wurde nicht erkannt. Ursache war
  ein Reihenfolge-Bug - die dynamische sysadmin-Erkennung lief, bevor `$srcConnParams`
  definiert war, scheiterte still und fiel auf das Literal `'sa'` zurück. Dadurch konnte eine
  auf einem Node umbenannte `sa` in den Kopier-Batch gelangen (SID-Kollision 0x01 auf dem Ziel).
  - ConnParams/Credentials werden jetzt VOR der Erkennung aufgebaut.
  - `sa` wird zusätzlich über die well-known SID `0x01` identifiziert (namensunabhängig) und
    grundsätzlich nie kopiert - auch nicht mit `-IncludeSystemLogins`.
  - sysadmin-Abfrage in Copy-sqmLogins und Sync-sqmLoginsToAlwaysOn ergänzt um `OR sid = 0x01`.

## [1.4.9.0] — 2026-06-10

### 🔧 Fixes

- **Get-sqmBlockingReport**: `most_recent_sql_handle` korrekt aus `sys.dm_exec_connections`
  statt `sys.dm_exec_sessions` (Fehler „Invalid column name 'most_recent_sql_handle'").
- **New-sqmAutoLoginSyncJob**: `SqlInstance` wurde beim Anlegen des Zeitplans doppelt gebunden
  (Fehler „parameter 'SqlInstance' is specified more than once") - jetzt nur noch explizit.

### ♻️ Refactoring

- **New-sqmAutoLoginSyncJob**: Job-Step radikal vereinfacht. Statt ~60 Zeilen eingebackener
  Orchestrierung jetzt ein schlanker Direkt-Aufruf von `Sync-sqmLoginsToAlwaysOn`; bei Fehlern
  `throw` → SQL Agent markiert den Job als fehlgeschlagen (Operator-Benachrichtigung).
  Keine hartkodierten Pfade mehr im Step.
- **Sync-sqmLoginsToAlwaysOn**: übernimmt jetzt Retention (`-BackupRetentionDays`) und den
  AD-Orphan-Audit (`-AuditAdOrphans`, Detection-only, Event Log 9003). `-BackupPath` nimmt den
  konfigurierten Ausgabepfad (`Get-sqmDefaultOutputPath`) statt eines festen Literals - alle
  Pfade kommen aus den Settings.

## [1.4.8.0] — 2026-06-10

### ✨ Neue Features

#### Remove-sqmAdOrphanLogin
Manuelles, sicheres Entfernen von Windows-Logins, deren AD-Konto nicht mehr existiert
(„tote" AD-Logins). Bewusst nur manuell, nicht für den unbeaufsichtigten Betrieb.
- ActiveDirectory-Modul Pflicht (Default `-AdModuleAction Abort`); ohne AD keine Löschung
- System- und alle sysadmin-Logins immer ausgeschlossen, DB-Owner-Logins übersprungen
- Orphan nur bei positivem AD-„nicht vorhanden"; AD-Abfragefehler → überspringen
- Rollback-Skript (CREATE LOGIN FROM WINDOWS + Server-Rollen) vor dem Drop
- `ConfirmImpact = High`: `-WhatIf` / `-Confirm` greifen

#### New-sqmAutoLoginSyncJob — neue Optionen
- `-Force` und `-BackupLogins` standardmäßig aktiv: der laufende Job hält die Secondaries
  vollständig synchron (Passwort-/Sprach-/Default-DB-Drift), mit Rollback-Backup.
  Opt-out via `-Force:$false` / `-BackupLogins:$false`
- `-BackupRetentionDays` (Default 7): räumt Backups, Sync-Logs und Audit-Reports auf
- `-AuditAdOrphans`: meldet nach jedem Lauf verwaiste Windows-Logins (Sync-Log + Event Log
  EventId 9003 für Splunk) — nur Erkennung, kein Auto-Delete

### 🔧 Fixes

- **Login-Backup-Query**: `password_hash` aus `sys.sql_logins` statt `sys.server_principals`
  (Fehler „Invalid column name 'password_hash'" bei `-BackupLogins`)
- **Sync-sqmLoginsToAlwaysOn**: AG-Ermittlung sortiert nach `name` statt nicht existierender
  Spalte `creation_date`
- **Install.cmd / Update.cmd**: unter GPO `RemoteSigned` immer lokal stagen (Mark-of-the-Web
  entfernen), damit die Ausführung vom UNC-/`\\tsclient\`-Pfad nicht blockiert wird

## [1.4.0.0] — 2026-05-31

### ✨ Neue Features

#### Get-sqmServerHardwareReport
Umfassender HTML-Hardware-Report für lokale und Remote-Systeme:
- **RAM-Informationen**: Gesamt, Verfügbar, DIMM-Details (Hersteller, Größe)
- **CPU-Details**: Modell, Sockel, Anzahl Kerne, Takthöhe
- **Laufwerke**: Physikalische Laufwerke mit logischen Partitionen und Auslastungsbalken
- **VM-Erkennung**: Hyper-V, VMware, VirtualBox, KVM
- **Systeminfo**: Netzwerk, Betriebssystem, SQL Server Instanzen
- **Remote-Unterstützung**: CIM/WMI-basiert, öffnet Report automatisch im Browser

### 🔧 Verbesserungen

#### IntelliSense Fix (PowerShell ISE / VS Code)
- `FunctionsToExport` in `sqmSQLTool.psd1` von Wildcard-Pattern `*-sqm*` auf explizite Liste aller 103 Funktionen umgestellt
- Alle Funktionen werden sofort nach `Import-Module sqmSQLTool` in der IDE angezeigt
- Schnellere IntelliSense-Performance

#### Code Signing Setup
- SignPath.io Integration vorbereitet (Self-Signed Certificate + Workflow)
- Bewerbung für SignPath.org Community Plan eingereicht

#### 4 neue Reveal.js Präsentationen
Interaktive Präsentationen auf www.powershelldba.de/Praesentation/:
- **Performance & Diagnose** (13 Slides)
- **Security & Compliance** (12 Slides)
- **Database Health & Best Practices** (12 Slides)
- **Integration & Externe Systeme** (12 Slides)

---

## [1.3.0.0] — 2026-04-30

(Frühere Versionen nicht dokumentiert)
