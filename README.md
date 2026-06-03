# sqmSQLTool

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/sqmSQLTool?label=PowerShell%20Gallery&logo=powershell&logoColor=white)](https://www.powershellgallery.com/packages/sqmSQLTool)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/JankeUwe/sqmSQLTool?style=social)](https://github.com/JankeUwe/sqmSQLTool)

PowerShell-Modul für SQL Server Administration — entwickelt von [dtcSoftware](https://www.powershelldba.de) (Uwe Janke).

## 🎯 Übersicht

**sqmSQLTool** ist ein umfassendes PowerShell-Modul mit **100+ Funktionen** für die professionelle SQL Server-Administration. Es baut auf [dbatools](https://dbatools.io) auf und erweitert diese um betriebsspezifische Automatisierungen.

**Ideal für:**
- SQL Server DBAs
- System Administratoren
- Automation Engineers
- Enterprise Umgebungen (besonders AlwaysOn, High Availability)

## 📋 Anforderungen

- **PowerShell** 5.1+ (Windows PowerShell oder PowerShell 7+)
- **.NET Framework** 4.5+
- **dbatools** (wird automatisch installiert)
- **Windows** (SQL Server Administration)

## ⚡ Quick Start

### Installation (One-Liner)
```powershell
# Aus PowerShell Gallery (empfohlen)
Install-Module -Name sqmSQLTool -Repository PSGallery -Scope CurrentUser

# Oder als Admin für alle Benutzer
Install-Module -Name sqmSQLTool -Repository PSGallery -Scope AllUsers

# Importieren
Import-Module sqmSQLTool
```

### Erste Schritte
```powershell
# Verfügbare Funktionen anzeigen
Get-Command -Module sqmSQLTool | Select-Object Name, Synopsis

# Datenbank-Health prüfen
Get-sqmDatabaseHealth -SqlInstance "YOUR_SERVER"

# Disk-Space Report erzeugen
Get-sqmDiskSpaceReport -SqlInstance "YOUR_SERVER"

# AlwaysOn AG Status
Get-sqmAgHealthReport -SqlInstance "YOUR_SERVER"
```

### Help & Dokumentation
```powershell
# Hilfe zu einer Funktion
Get-Help Get-sqmDatabaseHealth -Full

# Online Help (GitHub)
Get-Help Get-sqmDatabaseHealth -Online
```

## Installation

```powershell
# Modul installieren
.\Install.ps1

# Oder manuell ins PSModulePath kopieren und importieren
Import-Module sqmSQLTool
```

## Funktionsübersicht

### Analyse & Reporting
| Funktion | Beschreibung |
|----------|-------------|
| `Get-sqmDatabaseHealth` | Umfassender Datenbankgesundheits-Report |
| `Get-sqmBlockingReport` | Blocking-Analyse mit historischen Daten |
| `Get-sqmDeadlockReport` | Deadlock-Analyse aus Extended Events |
| `Get-sqmLongRunningQueries` | Lang laufende Abfragen |
| `Get-sqmWaitStatistics` | Wait-Statistiken |
| `Get-sqmMissingIndexes` | Fehlende Index-Empfehlungen |
| `Get-sqmIndexFragmentation` | Index-Fragmentierung |
| `Get-sqmAutoGrowthReport` | Auto-Growth-Ereignisse |
| `Get-sqmConnectionStats` | Verbindungsstatistiken |
| `Get-sqmPerfCounters` | Performance Counter |

### AlwaysOn / High Availability
| Funktion | Beschreibung |
|----------|-------------|
| `Get-sqmAgHealthReport` | Availability Group Health Report |
| `Get-sqmClusterInfo` | Cluster-Informationen |
| `Invoke-sqmAddDatabaseToAG` | Datenbank zu AG hinzufügen |
| `Remove-sqmDatabaseFromAG` | Datenbank aus AG entfernen |
| `Invoke-sqmFailover` | Manueller AG-Failover |
| `Invoke-sqmSqlAlwaysOnAutoseeding` | Automatic Seeding konfigurieren |
| `Sync-sqmAgNode` | AG-Node-Synchronisation |
| `Repair-sqmAlwaysOnDatabases` | AG-Datenbanken reparieren |
| `New-sqmAlwaysOnRepairJob` | Repair-Job anlegen |

### Sicherheit & Compliance
| Funktion | Beschreibung |
|----------|-------------|
| `Get-sqmSysadminAccounts` | Sysadmin-Konten prüfen |
| `Get-sqmCertificateReport` | Zertifikat-Report |
| `Get-sqmSpnReport` | SPN-Analyse |
| `Get-sqmADAccountStatus` | AD-Konto-Status |
| `Invoke-sqmLoginAudit` | Login-Audit |
| `Invoke-sqmSaObfuscation` | SA-Konto absichern |
| `Install-sqmCertificate` | Zertifikat installieren |
| `New-sqmCertificateRequest` | Zertifikat-Request erstellen |
| `New-sqmSqlCertificate` | SQL Server Zertifikat erstellen |
| `Get-sqmHpuAllowGroup` | HPU-Gruppen-Berechtigungen |

### Backup & Restore
| Funktion | Beschreibung |
|----------|-------------|
| `Invoke-sqmRestoreDatabase` | Datenbank-Restore (vollständig/differenziell/Log) |
| `Invoke-sqmUserDatabaseBackup` | Ad-hoc Backup |
| `Test-sqmBackupIntegrity` | Backup-Integrität prüfen |

### Wartung & Optimierung
| Funktion | Beschreibung |
|----------|-------------|
| `Install-sqmOlaMaintenanceSolution` | Ola Hallengren Maintenance Solution |
| `New-sqmOlaMaintenanceJobs` | Ola-Jobs anlegen |
| `New-sqmOlaSysDbBackupJob` | System-DB-Backup-Job |
| `New-sqmOlaUsrDbBackupJob` | User-DB-Backup-Job |
| `Test-sqmOlaInstallation` | Ola-Installation prüfen |
| `Invoke-sqmUpdateStatistics` | Statistiken aktualisieren |
| `Invoke-sqmLogShrink` | Log-Shrink (mit Sicherheitsprüfung) |
| `Get-sqmTempDbRecommendation` | TempDB-Empfehlungen |

### Konfiguration & Setup
| Funktion | Beschreibung |
|----------|-------------|
| `Get-sqmConfig` / `Set-sqmConfig` | Modul-Konfiguration |
| `Get-sqmServerSetting` | SQL Server Einstellungen lesen |
| `Invoke-sqmSetDatabaseRecoveryMode` | Recovery Model setzen |
| `Set-sqmDatabaseOwner` | Datenbankbesitzer setzen |
| `Invoke-sqmFormatDrive64k` | Laufwerk mit 64K-Cluster formatieren |
| `Invoke-sqmCollationChange` | Collation ändern |
| `Set-sqmSqlPolicyState` | Policy-Zustand setzen |

### Monitoring & Diagnostik
| Funktion | Beschreibung |
|----------|-------------|
| `Get-sqmSQLInstanceCheck` | Instanz-Gesamtcheck |
| `Invoke-sqmInstanceInventory` | Inventur aller Instanzen |
| `Get-sqmOperationStatus` | Laufende Operationen |
| `Invoke-sqmPerfBaseline` | Performance-Baseline erstellen |
| `Invoke-sqmPatchAnalysis` | Patch-Stand analysieren |
| `Invoke-sqmMonitoringKey` | Monitoring-Key prüfen |
| `Test-sqmSQLFirewall` | Firewall-Erreichbarkeit testen |
| `Invoke-sqmExtendedEvents` | Extended Events Sessions |
| `Invoke-sqmQueryStore` | Query Store Analyse |

### SSRS / SSIS / SSAS
| Funktion | Beschreibung |
|----------|-------------|
| `Install-sqmSsrsReportServer` | SSRS Installation |
| `Set-sqmSsrsConfiguration` | SSRS konfigurieren |
| `Invoke-sqmSsisConfiguration` | SSIS konfigurieren |
| `Test-sqmSsasDirectoryPermissions` | SSAS Verzeichnisrechte |

### TSM / Backup-Manager
| Funktion | Beschreibung |
|----------|-------------|
| `Get-sqmTsmConfiguration` | TSM-Konfiguration lesen |
| `Invoke-sqmTsmConfiguration` | TSM konfigurieren |
| `Test-sqmTsmConnection` | TSM-Verbindung testen |

### Splunk Integration
| Funktion | Beschreibung |
|----------|-------------|
| `Invoke-sqmSplunkConfiguration` | Splunk-Integration konfigurieren |

### Sonstiges
| Funktion | Beschreibung |
|----------|-------------|
| `Export-sqmDatabaseDocumentation` | Datenbankdokumentation exportieren |
| `Find-sqmDatabaseObject` | Datenbankobjekte suchen |
| `Get-sqmLinkedServerUsage` | Linked Server Nutzung |
| `Get-sqmOrphanedFiles` | Verwaiste Dateien |
| `Get-sqmDiskSpaceReport` | Festplattenplatz-Report |
| `Copy-sqmToCentralPath` | Dateien in zentralen Pfad kopieren |
| `Copy-sqmLogins` | Logins zwischen Instanzen kopieren |
| `Invoke-sqmPerfBaseline` | Performance Baseline |

## Mehr Informationen

- **Dokumentation & Befehlsreferenz:** [powershelldba.de/tools/befehls-referenz](https://www.powershelldba.de/tools/befehls-referenz)
- **Website:** [www.powershelldba.de](https://www.powershelldba.de)
- **PowerShell Gallery:** [powershellgallery.com/profiles/JankeUwe](https://www.powershellgallery.com/profiles/JankeUwe)
- **Alle Projekte:** [github.com/JankeUwe](https://github.com/JankeUwe)
- Entwickler: Uwe Janke, Senior SQL Server DBA | dtcSoftware

## 💬 Support & Community

### Probleme oder Fragen?
- **GitHub Issues:** [github.com/JankeUwe/sqmSQLTool/issues](https://github.com/JankeUwe/sqmSQLTool/issues) — Bug Reports, Feature Requests
- **GitHub Discussions:** [github.com/JankeUwe/sqmSQLTool/discussions](https://github.com/JankeUwe/sqmSQLTool/discussions) — Q&A, Tipps, Best Practices
- **Stack Overflow:** Tag mit `[powershell]` + `[sql-server]`
- **Email:** uwejanke@googlemail.com

### Community-Kanäle
- **Reddit:** [/r/PowerShell](https://reddit.com/r/PowerShell), [/r/mssql](https://reddit.com/r/mssql)
- **Slack:** [sqlcommunity.slack.com](https://sqlcommunity.slack.com) (#powershell, #sql-server)
- **LinkedIn:** [@uwejanke](https://linkedin.com/in/uwejanke) — Follow für Updates

## 🤝 Beitragen

Wir freuen uns über Beiträge! So kannst du helfen:

1. **Bugs melden:** [Issues](https://github.com/JankeUwe/sqmSQLTool/issues) erstellen
2. **Features vorschlagen:** [Discussions](https://github.com/JankeUwe/sqmSQLTool/discussions)
3. **Code beitragen:** Pull Requests sind willkommen
4. **Dokumentation:** Hilf bei Übersetzungen oder verbesserter Dokumentation
5. **Feedback:** Erzähl uns, wie du das Tool nutzt!

**Entwickler-Setup:**
```powershell
# Repository klonen
git clone https://github.com/JankeUwe/sqmSQLTool.git
cd sqmSQLTool

# Abhängigkeiten installieren
Install-Module -Name dbatools, Pester -Force

# Tests ausführen
Invoke-Pester .\Tests\ -Verbose
```

## 📈 Roadmap

- [x] v1.0.0 — Initiale Veröffentlichung
- [x] v1.4.0+ — AlwaysOn Erweiterungen, Performance Reports
- [ ] v2.0.0 — PowerShell 7+ Optimierungen, zusätzliche DBaaS-Unterstützung
- [ ] Code Signing — Zertifikat für LBBW (AllSigned Policy)
- [ ] Multilingual Support — Deutsche & Englische UI

## Lizenz

Copyright (c) 2026 dtcSoftware. All rights reserved.
