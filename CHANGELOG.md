# sqmSQLTool — Changelog

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
