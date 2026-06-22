# sqmSQLTool — Changelog

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
