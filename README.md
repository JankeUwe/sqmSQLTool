# sqmSQLTool
PowerShell SQL Admin Toolset
---
---
tags: [projekt]
status: aktiv
erstellt: 2026-04-29
version: 1.0.0
---

# PowerShell Toolbox für SQL-Admins

## Ziel

PowerShell-Modul `sqmSQLTool` (dtcSoftware) — eine umfassende Toolbox für SQL-Administratoren, aufgebaut auf dbaTools. Auch Admins mit geringem PowerShell-Wissen können damit komplexe SQL Server Aufgaben sicher und standardkonform durchführen.

## Quellcode

`C:\CCM\sqmSQLTool\`

| Pfad | Inhalt |
|---|---|
| `sqmSQLTool.psm1` | Modul-Root, Konfigurationsinitialisierung |
| `sqmSQLTool.psd1` / `bin\sqmSQLTool.psd1` | Modul-Manifest (Version 1.0.0) |
| `Public\*.ps1` | ~48 exportierte Funktionen |
| `Private\` | Interne Hilfsfunktionen (Logging) |
| `bin\` | Build-Output |
| `*.TempPoint.ps1` | Work-in-Progress Dateien (noch nicht fertig) |

## Status

Version 1.0.0 — Erstellt April 2026. Aktiv in Entwicklung. Mehrere Funktionen noch als `.TempPoint` in Bearbeitung.

## Technischer Stand

### Voraussetzungen
- PowerShell 5.1+, .NET 4.5+
- dbaTools (Pflicht-Abhängigkeit im Manifest)
- Erstellt mit SAPIEN PowerShell Studio 2021

### Modulkonfiguration (`Set-sqmConfig`)

Persistiert in `%APPDATA%\MSSQLTools\config.json`:

| Parameter | Standard (FI-TS) |
|---|---|
| `LogPath` | `C:\System\WinSrvLog\MSSQL` |
| `OutputPath` | `C:\System\WinSrvLog\MSSQL` |
| `CentralPath` | `C:\System\WinSrvLog\MSSQL` |
| `OlaJobNameFull` | `FITS-UserDatabases-FULL` |
| `OlaJobNameDiff` | `FITS-UserDatabases-DIFF` |
| `OlaJobNameLog` | `FITS-UserDatabases-LOG` |
| `OlaJobNameIndexOpt` | `FITS IndexOptimize - USER_DATABASES` |
| `OlaJobNameSysDbBackup` | `FITS-SystemDatabases-FULL` |

---

## Funktionsübersicht (75 Public Functions)

### AlwaysOn

| Funktion | Beschreibung |
|---|---|
| `Get-sqmAgHealthReport` | Detaillierter Zustandsbericht aller AG-Verfügbarkeitsgruppen |
| `Invoke-sqmFailover` | Kontrollierter AG-Failover mit Pre-/Post-Checks (Redo-Queue, SyncState) |
| `Invoke-sqmSqlAlwaysOnAutoseeding` | Aktiviert Automatic Seeding auf allen AG-Replikaten |
| `Invoke-sqmAddDatabaseToAG` | Fügt Datenbanken per AutoSeed zur AG hinzu |
| `Remove-sqmDatabaseFromAG` | Entfernt Datenbanken aus einer AG |
| `Repair-sqmAlwaysOnDatabases` | Prüft und repariert AlwaysOn-Datenbanken (Remove → Cleanup → Add) |
| `New-sqmAlwaysOnRepairJob` | Erstellt SQL Agent Job für automatische AG-Reparatur |
| `Sync-sqmAgNode` | Synchronisiert SQL Server Objekte vom Primary auf alle Replikate |

### Backup & Restore

| Funktion | Beschreibung |
|---|---|
| `Invoke-sqmUserDatabaseBackup` | Benutzerdatenbank-Backup |
| `Invoke-sqmRestoreDatabase` | Restore mit Unterstützung für Single-Server und AlwaysOn |
| `Test-sqmBackupIntegrity` | Prüft Backup-Dateien via `RESTORE VERIFYONLY` |

### Sicherheit & Logins

| Funktion | Beschreibung |
|---|---|
| `Invoke-sqmLoginAudit` | Umfassender Audit aller SQL Server Logins |
| `Get-sqmSysadminAccounts` | Alle Logins mit Sysadmin-Rechten |
| `Get-sqmADAccountStatus` | AD-Konten-Status für SQL Service Accounts und Logins prüfen |
| `Copy-sqmLogins` | Logins von Quell- auf Zielinstanz kopieren |
| `Invoke-sqmSaObfuscation` | SA-Konto verschleiern (Umbenennung + Status) |
| `Set-sqmDatabaseOwner` | Einheitlichen Datenbank-Owner setzen |
| `Set-sqmSqlPolicyState` | Policy-Based Management Policies aktivieren/deaktivieren |
| `Test-sqmSQLFirewall` | SQL Server Firewall-Regeln auf Erreichbarkeit prüfen |
| `Get-sqmSpnReport` | SPN-Bericht für SQL Service Accounts — fehlende/doppelte SPNs |
| `Get-sqmHpuAllowGroup` | HPU-Allow-Gruppe für einen Server aus konfiguriertem Domain-Mapping ermitteln |

### Performance & Analyse

| Funktion | Beschreibung |
|---|---|
| `Get-sqmWaitStatistics` | Wait Statistics aus `sys.dm_os_wait_stats` — Top-N mit Kategorie + Empfehlung, Snapshot-Vergleich |
| `Get-sqmPerfCounters` | Performance Counter aus `sys.dm_os_performance_counters` — PLE, BHR, Batch Req, Locks, Memory |
| `Get-sqmConnectionStats` | Aktive Verbindungen analysiert und gruppiert (Application/Login/Host/Database) |
| `Invoke-sqmPerfBaseline` | Performance-Baselines erfassen (Capture), vergleichen (Compare) und auflisten (List) |
| `Get-sqmIndexFragmentation` | Index-Fragmentierungsanalyse |
| `Get-sqmMissingIndexes` | Fehlende Index-Empfehlungen aus DMV-Cache |
| `Get-sqmBlockingReport` | Aktuelle Blockierungsketten ermitteln |
| `Get-sqmDeadlockReport` | Deadlock-Ereignisse aus System Health XEvent Session |
| `Get-sqmLongRunningQueries` | Lang laufende Queries ermitteln |
| `Invoke-sqmExtendedEvents` | Extended Events Sitzungen verwalten (Start/Stop/Query) |
| `Invoke-sqmQueryStore` | Query Store Analyse und Top-Regressed-Queries |
| `Get-sqmTempDbRecommendation` | TempDB Konfigurationsanalyse + Optimierungsempfehlungen |
| `Get-sqmAutoGrowthReport` | AutoGrowth-Bericht |
| `Invoke-sqmUpdateStatistics` | Statistiken aktualisieren |

### Instanz-Management

| Funktion | Beschreibung |
|---|---|
| `Get-sqmSQLInstanceCheck` | Best Practice Check einer Instanz |
| `Get-sqmServerSetting` | Server-Properties auslesen |
| `Compare-sqmServerConfiguration` | Konfigurationsvergleich zweier Instanzen |
| `Invoke-sqmInstanceInventory` | Vollständige Instanz-Inventarisierung (TXT + CSV) |
| `Invoke-sqmPatchAnalysis` | CU/SP-Patchstand prüfen — Vergleich gegen eingebettete Build-Referenztabelle, Pipeline-fähig |
| `Get-sqmClusterInfo` | Cluster-Informationen: Nodes, Rollen, IPs |
| `Get-sqmDiskSpaceReport` | Freier Speicherplatz auf SQL-relevanten Volumes |
| `Invoke-sqmCollationChange` | Server-Collation automatisch umstellen |
| `Invoke-sqmFormatDrive64k` | Datenträger mit 64k Cluster-Size für SQL Server formatieren |

### Datenbank-Management

| Funktion | Beschreibung |
|---|---|
| `Get-sqmDatabaseHealth` | Gesundheitszustand aller Datenbanken |
| `Export-sqmDatabaseDocumentation` | HTML + CSV Dokumentation aller Datenbanken |
| `Find-sqmDatabaseObject` | Datenbankobjekte instanzweit suchen |
| `Get-sqmLinkedServerUsage` | Welche Objekte nutzen Linked Server? |
| `Get-sqmOrphanedFiles` | Verwaiste MDF/LDF/NDF-Dateien finden (Dateisystem vs. sys.master_files) |
| `Invoke-sqmLogShrink` | Transaktionslog (LDF) shrink |
| `Invoke-sqmSetDatabaseRecoveryMode` | Recovery-Modus ändern |

### Wartung / Ola Hallengren

| Funktion | Beschreibung |
|---|---|
| `Install-sqmOlaMaintenanceSolution` | Ola Hallengren Maintenance Solution installieren/updaten |
| `New-sqmOlaMaintenanceJobs` | Drei SQL Agent Jobs für Ola-Wartung erstellen |
| `New-sqmOlaSysDbBackupJob` | SQL Agent Job für System-DB Backup erstellen |
| `New-sqmOlaUsrDbBackupJob` | SQL Agent Job für User-DB Backup erstellen |
| `Test-sqmOlaInstallation` | Prüft ob Ola Solution installiert ist |

### Zertifikate

| Funktion | Beschreibung |
|---|---|
| `Get-sqmCertificateReport` | Bericht über Zertifikate und Ablaufdaten |
| `Install-sqmCertificate` | Zertifikat (selbstsigniert oder CA) in SQL Server installieren |
| `New-sqmCertificateRequest` | CSR + Bestelldatenblatt erstellen |
| `New-sqmSqlCertificate` | Selbstsigniertes Zertifikat als Erneuerung erstellen |

### Services (SSIS / SSRS / SSAS / TSM)

| Funktion | Beschreibung |
|---|---|
| `Invoke-sqmSsisConfiguration` | SSIS vollautomatisch konfigurieren |
| `Install-sqmSsrsReportServer` | SSRS vollautomatisch installieren |
| `Set-sqmSsrsConfiguration` | SSRS vollautomatisch konfigurieren |
| `Test-sqmSsasDirectoryPermissions` | SSAS-Verzeichnis NTFS-Rechte prüfen und korrigieren |
| `Invoke-sqmTsmConfiguration` | TSM Client-Optionsdatei `dsm.opt` konfigurieren |
| `Get-sqmTsmConfiguration` | TSM-Konfiguration auslesen |
| `Test-sqmTsmConnection` | TSM-Verbindung testen |

### Splunk

| Funktion | Beschreibung |
|---|---|
| `Invoke-sqmSplunkConfiguration` | Splunk Universal Forwarder konfigurieren — lokal, Remote via AD-OU oder Computerliste, WhatIf-Modus |

### NTFS & Sicherheit (Kandidat)

| Funktion | Beschreibung |
|---|---|
| `Invoke-sqmNtfsSetup` | NTFS-Rechte auf SQL Server Verzeichnissen setzen — Verzeichnisse + Dienstkonten automatisch per SMO/WMI ermittelt. Backup → Set → Restore in einem Aufruf. Basiert auf [[02 Projekte/NTFS Rechteverwaltung/NTFS Rechteverwaltung.md]] |

### Konfiguration

| Funktion | Beschreibung |
|---|---|
| `Set-sqmConfig` | Modulkonfiguration setzen (Pfade, Ola-Job-Namen, TSM-Klassen, Sprache, SSRS-Installer-Pfad) |
| `Get-sqmConfig` | Modulkonfiguration ausgeben |

### Monitoring & Hilfs-Funktionen

| Funktion | Beschreibung |
|---|---|
| `Get-sqmAgentJobHistory` | SQL Agent Job Ausführungshistorie |
| `Get-sqmOperationStatus` | Fortschritt und ETA für Backup/Restore/AutoSeed Operationen |
| `Invoke-sqmMonitoringKey` | Monitoring-Key setzen |
| `Copy-sqmToCentralPath` | Dateien in konfigurierten CentralPath kopieren |
| `Install-sqmAdModule` | ActiveDirectory RSAT-Modul sicherstellen |

---

## Work in Progress (.TempPoint Dateien)

Noch nicht fertiggestellte Funktionen (`.TempPoint.ps1` = werden beim Modulimport nicht geladen):

- `Get-sqmConfig` — Modulkonfiguration ausgeben
- `Get-sqmOperationStatus` — Fortschrittsanzeige
- `Set-sqmSsrsConfiguration` — SSRS Konfiguration
- `Invoke-sqmAddDatabaseToAvailabilityGroup` — Veraltet, wird durch `Invoke-sqmAddDatabaseToAG` ersetzt
- `Invoke-sqmRemoveDatabaseFromAvailabilityGroup` — Veraltet, wird durch `Remove-sqmDatabaseFromAG` ersetzt
- `Copy-sqmToCentralPath` — Datei-Kopierhilfsfunktion
- `Private\Invoke-sqmLogging` — Logging-Engine
- `Private\Test-sqmLoggingPath` — Logging-Pfadprüfung

## Kandidaten für Integration (aus bestehenden Projekten)

| Kandidat | Funktion | Quelle |
|---|---|---|
| `Invoke-sqmNtfsSetup` | NTFS-Rechteverwaltung für SQL Verzeichnisse | [[02 Projekte/NTFS Rechteverwaltung/NTFS Rechteverwaltung.md]] |
| ~~`Invoke-sqmSplunkConfiguration`~~ | ✅ Integriert (2026-05-12) | [[02 Projekte/Splunk Automation.md]] |
| `Invoke-sqmSqlUpgradeBackup` | Inplace Upgrade Sicherung | [[02 Projekte/Inplace Setup Installation.md]] |
| `Invoke-sqmSqlUpgradeRestore` | Inplace Upgrade Wiederherstellung | [[02 Projekte/Inplace Setup Installation.md]] |
| `Invoke-sqmAlwaysOnSetup` | AG-Setup ohne WinForms GUI — für Scripting-Szenarien | [[02 Projekte/AlwaysOn Setup Automation.md]] |
| `Invoke-sqmReportDeployment` | SSRS-Reports per CLI deployen (ohne GUI-Tool) | [[02 Projekte/Report Deployment.md]] |

## Kandidaten für Neuentwicklung

| Kandidat | Funktion | Priorität |
|---|---|---|
| `Invoke-sqmPostInstallConfig` | Standard-Härtung nach Neuinstallation: Max Memory, MAXDOP, Cost Threshold, Surface Area | Hoch |
| `Get-sqmOrphanedUsers` | Verwaiste DB-User nach Migration finden und reparieren | Hoch |
| `Get-sqmVlf` | VLF-Analyse — hohe VLF-Anzahl erkennen und Empfehlung ausgeben | Mittel |
| `Get-sqmPatchLevel` | Aktuellen CU-Stand prüfen, Vergleich mit aktuellem MS-Patchstand | Mittel |
| `Get-sqmSqlErrorLog` | Errorlog nach bekannten Problemmustern filtern (I/O, Memory Pressure, Verbindungsfehler) | Mittel |

## Nächste Schritte

- [ ] TempPoint-Dateien fertigstellen (Logging-Engine als Basis für alle anderen)
- [ ] `Invoke-sqmNtfsSetup` aus NtfsPermissions.ps1 integrieren
- [x] `Invoke-sqmSplunkConfiguration` aus SetSplunk integrieren — **erledigt 2026-05-12**
- [ ] `Invoke-sqmAlwaysOnSetup` aus AlwaysOnSetup.ps1 als CLI-Variante integrieren
- [ ] `Invoke-sqmReportDeployment` aus ReportDeployment integrieren
- [ ] `Invoke-sqmPostInstallConfig` entwickeln (Standard-Härtung nach Neuinstallation)
- [ ] `Get-sqmOrphanedUsers` entwickeln (fehlender letzter Schritt nach Migration)
- [ ] `Get-sqmVlf` entwickeln (VLF-Analyse)
- [ ] `Get-sqmSqlErrorLog` entwickeln (Errorlog nach Problemmustern filtern)
- [ ] Build-Tabelle in `Invoke-sqmPatchAnalysis` auf aktuellem Stand halten (SQL 2016 EOL 2026-07-14)
- [ ] Praxistest der Kern-Funktionen in  Testumgebung
- [ ] Modul auf powershelldba.de Website verlinken / dokumentieren
- [ ] GUI-Wrapper für die wichtigsten Funktionen evaluieren

## Notizen

