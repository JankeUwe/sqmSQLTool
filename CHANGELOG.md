# sqmSQLTool — Changelog

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
