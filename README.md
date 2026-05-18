# sqmSQLTool

PowerShell-Modul für SQL Server Administration — entwickelt von [dtcSoftware](https://www.powershelldba.de) (Uwe Janke).

## Übersicht

sqmSQLTool ist ein umfassendes PowerShell-Modul mit 60+ Funktionen für die professionelle SQL Server-Administration. Es baut auf [dbatools](https://dbatools.io) auf und erweitert diese um betriebsspezifische Automatisierungen.

**Anforderungen:**
- PowerShell 5.1+
- .NET Framework 4.5+
- [dbatools](https://dbatools.io) (wird automatisch benötigt)

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

- Website: [www.powershelldba.de](https://www.powershelldba.de)
- Entwickler: Uwe Janke, Senior IT-Spezialist / SQL Server DBA

## Lizenz

Copyright (c) 2026 dtcSoftware. All rights reserved.
