# AlwaysOn Betriebs-Tools

**sqmSQLTool v1.4.7.0** — Zusammenstellung der Funktionen für den Betrieb von AlwaysOn Availability Groups
Quelle: www.powershelldba.de · Stand: 2026-06-09 · *Interne Übersicht*

---

Diese Sammlung bündelt die Funktionen aus sqmSQLTool, die für den laufenden, täglichen Betrieb
von AlwaysOn Availability Groups gebraucht werden: Gesundheitsprüfung, kontrollierter Failover,
Listener-Migration, AG-Datenbankverwaltung, Restore innerhalb einer AG, Login-Synchronisation
und die Automatisierung dieser Aufgaben über SQL Agent Jobs. Alle Funktionen bauen auf
dbatools auf und sind sowohl unter PowerShell 5.1 als auch PowerShell 7 lauffähig.

*Distributed-AG-Funktionen sind hier bewusst nicht enthalten — Aufbau und Failover einer
Distributed AG sind Setup-/Projektaufgaben, kein Bestandteil des täglichen Betriebs.*

## Tool-Setup / Installation

Das Modul wird zentral über die Quelle bereitgestellt:

```
\\75084\Datenbanken\MSSQL\Sourcen
```

Von dort wird sqmSQLTool auf den jeweiligen SQL Server installiert bzw. aktualisiert.
Installation als Administrator auf dem Zielserver:

```powershell
# Aus der zentralen Quelle installieren
& "\\75084\Datenbanken\MSSQL\Sourcen\sqmSQLTool\Install.cmd"

# Anschliessend im PowerShell-Fenster pruefen
Import-Module sqmSQLTool
Get-Module sqmSQLTool | Select-Object Name, Version
```

Update auf eine neuere Version aus derselben Quelle: erneut `Install.cmd` ausführen.
Es gleicht den Modulinhalt vollständig ab (kopiert geänderte Dateien, entfernt verwaiste)
und dient damit als Installer **und** Updater.

```powershell
& "\\75084\Datenbanken\MSSQL\Sourcen\sqmSQLTool\Install.cmd"
```

> Hinweis: `Install.cmd` umgeht die Mark-of-the-Web-Blockade automatisch
> (lokales Staging), falls die Ausführung direkt vom UNC-Pfad per Execution Policy geblockt wird.

## Health & Monitoring

| Funktion | Zweck |
|---|---|
| `Get-sqmAlwaysOnHealthReport` | Detaillierter Gesundheitsbericht aller AGs einer Instanz (Replica-Rollen, Sync-Status, Redo-/Send-Queues). |
| `Get-sqmAlwaysOnFailoverHistory` | Ermittelt Failover-Ereignisse aus dem Windows Event Log (Rollenwechsel, Lease-/Forced-Failover). |

## Failover & Listener

| Funktion | Zweck |
|---|---|
| `Invoke-sqmFailover` | Kontrollierter AG-Failover mit Vor- und Nachprüfungen (Sync-Status, Redo-Queue, Erreichbarkeit). |
| `Move-sqmAlwaysOnListener` | Migriert einen AG-Listener von einer Availability Group zu einer anderen. |
| `Invoke-sqmListenerMigrationPrep` | Entfernt den Listener aus der AG, hält die Datenbanken dabei ONLINE (Migrationsvorbereitung). |
| `Complete-sqmListenerMigration` | Schließt die Listener-Migration nach der Vorbereitung ab. |

## Datenbanken in der AG

| Funktion | Zweck |
|---|---|
| `Add-sqmDatabaseToAG` | Fügt eine oder mehrere Datenbanken per Automatic Seeding zur AG hinzu. |
| `Remove-sqmDatabaseFromAG` | Entfernt eine oder mehrere Datenbanken aus ihrer AG. |
| `Invoke-sqmRestoreDatabase` | Kontrollierter Restore (Full / Full+Diff+Logs); erkennt AG-Mitgliedschaft automatisch und behandelt die Secondaries selbstständig. |
| `Repair-sqmAlwaysOnDatabases` | Prüft alle AG-Datenbanken auf Probleme und repariert sie (Remove → Cleanup → Add). |
| `Invoke-sqmSqlAlwaysOnAutoseeding` | Aktiviert Automatic Seeding auf allen Replicas einer AG. |

### Was dabei auf dem Secondary passiert

Der entscheidende Punkt im AG-Betrieb: Datenbankoperationen werden **immer auf dem Primary
gestartet**, das Werkzeug kümmert sich um die Secondaries. Manuelles Eingreifen auf einem
Secondary ist nicht nötig und meist sogar schädlich (z. B. das eigenmächtige Anlegen von
Logins oder Datenbanken auf einem Read-Only-Secondary).

- **Add-sqmDatabaseToAG** — Auf jedem Secondary wird eine ggf. **bereits vorhandene
  gleichnamige Datenbank zuerst gelöscht** (Drop), damit Automatic Seeding eine saubere Kopie
  ziehen kann. Anschließend überträgt Automatic Seeding die Datenbank vom Primary auf alle
  Secondaries; eine manuelle Restore-Kette auf dem Secondary entfällt. Voraussetzung: Recovery
  Model FULL und Automatic Seeding auf allen Replicas aktiv.

- **Remove-sqmDatabaseFromAG** — Die Datenbank wird zuerst aus der AG herausgelöst und danach
  **auf allen Secondary-Replicas gelöscht**. Auf dem Primary bleibt sie als normale, eigenständige
  Datenbank ONLINE bestehen. Ergebnis: keine verwaisten „Restoring"-Datenbanken auf den
  Secondaries.

- **Invoke-sqmRestoreDatabase** — Gehört die Zieldatenbank zu einer AG, wird sie **vor dem
  Restore automatisch aus der AG entfernt und auf den Secondaries gelöscht**. Vor dem Restore
  werden die Datenbank-User exportiert (zur späteren Wiederherstellung) und optional ein Backup
  des Originals erstellt. Nach dem Restore auf dem Primary werden User wiederhergestellt,
  verwaiste User repariert, nicht mehr existierende Windows-Logins entfernt und der DB-Owner auf
  das SA-Konto gesetzt. Mit `-KeepAlwaysOn` wird die Datenbank danach wieder in die AG aufgenommen —
  die Secondaries werden dann erneut per Automatic Seeding versorgt. Eine evtl. konfigurierte
  PBM-Policy wird für den Vorgang temporär deaktiviert und danach wieder aktiviert.

## Logins synchron halten

| Funktion | Zweck |
|---|---|
| `Sync-sqmLoginsToAlwaysOn` | Synchronisiert Logins vom Primary zu allen Secondary-Replicas. |
| `Compare-sqmAlwaysOnLogins` | Vergleicht Logins aller Replicas (Vorhandensein, Default-DB, Sprache, Passwort-Hash, SID). |
| `Compare-sqmAlwaysOnRoles` | Vergleicht Server-Rollen-Mitgliedschaft aller Replicas (fixe + benutzerdefinierte Rollen; sysadmin-Abweichung = Critical). |
| `Sync-sqmAgNode` | Synchronisiert weitere Serverobjekte (Logins, Jobs u. a.) vom Primary zu allen Secondaries. |

### `-Force`: bestehende Logins aktualisieren — ohne Self-Lockout

Ohne `-Force` legt die Sync **nur neue Logins** an; Unterschiede bei Passwort, Sprache oder
Default-DB bestehender Logins werden **nicht** übertragen. Mit `-Force` werden bestehende
Logins überschrieben (Passwort-Hash, Sprache, Default-DB).

Ein Aussperren ist dabei ausgeschlossen: Bei aktivem `SafeForceMode` (Default) schließt die
Funktion pro Secondary dynamisch alle **sysadmin-Logins** (inkl. umbenanntes `sa`), das
**SQL-Agent-Dienstkonto** sowie `NT SERVICE\*`, `NT AUTHORITY\*`, `BUILTIN\*`, `##MS_*` und `dbo`
vom Überschreiben aus. Optional erzeugt `-BackupLogins` vorher pro Secondary ein Rollback-Skript.

### Tote AD-Konten

Die Sync prüft jedes Windows-Login vor dem Kopieren gegen das Active Directory:

- **AD-Konto existiert** → Login wird übertragen.
- **AD-Konto gelöscht** → Status `AdOrphan`: das Login wird **nicht** auf die Secondaries
  übertragen und im Ergebnis gemeldet.
- **AD nicht erreichbar** → Status `AdQueryFailed`: konservativ übersprungen.

Tote AD-Logins werden also nicht weiterverteilt, aber auch **nicht automatisch gelöscht** — die
Sync kopiert, sie spiegelt nicht mit Löschung. Zum Sichtbarmachen bestehender Leichen dient
`Invoke-sqmLoginAudit -CheckAdOrphans` (auch als Job-Option, siehe unten). Voraussetzung für die
AD-Prüfung: das RSAT-ActiveDirectory-Modul und AD-Leserechte des ausführenden Kontos.

## Automatisierung (SQL Agent Jobs)

| Funktion | Zweck |
|---|---|
| `New-sqmAutoLoginSyncJob` | Erstellt einen Agent-Job, der Logins regelmäßig automatisch synchronisiert. |
| `New-sqmAutoLoginCompareJob` | Erstellt einen Agent-Job, der Logins regelmäßig vergleicht und bei Drift auf Fail geht. |
| `New-sqmAlwaysOnRepairJob` | Erstellt einen Agent-Job, der `Repair-sqmAlwaysOnDatabases` regelmäßig ausführt (Auto-Repair). |

### Praxisbeispiele: Login-Sync-Job

`New-sqmAutoLoginSyncJob` legt den Sync als SQL Agent Job auf dem **Primary** an. Die Defaults
sind für den Dauerbetrieb ausgelegt: ein laufender Job soll die Secondaries vollständig synchron
halten, nicht nur neue Logins anlegen.

```powershell
# Täglicher Sync-Job um 02:00 Uhr (Standard).
# Force und BackupLogins sind standardmässig AN -> Passwort-/Sprach-/Default-DB-Drift
# wird mitkorrigiert, vorher Rollback-Backup je Secondary. SafeForceMode schützt
# sysadmin-/Agent-/System-Konten vor dem Überschreiben.
New-sqmAutoLoginSyncJob -SqlInstance "SQLPRIM01" -AvailabilityGroupName "ProdAG"

# Mit AD-Orphan-Meldung: meldet nach jedem Lauf verwaiste Windows-Logins
# (Sync-Log + Event Log EventId 9003 für Splunk) - nur Erkennung, KEIN Auto-Delete.
New-sqmAutoLoginSyncJob -SqlInstance "SQLPRIM01" -AvailabilityGroupName "ProdAG" -AuditAdOrphans

# Legacy-Verhalten: nur neue Logins anlegen, keine Drift-Korrektur.
New-sqmAutoLoginSyncJob -SqlInstance "SQLPRIM01" -AvailabilityGroupName "ProdAG" -Force:$false

# Aufbewahrung der Backups/Logs anpassen (Default 7 Tage, 0 = kein Aufräumen).
New-sqmAutoLoginSyncJob -SqlInstance "SQLPRIM01" -AvailabilityGroupName "ProdAG" -BackupRetentionDays 14
```

> Bestehende Sync-Jobs übernehmen die neuen Defaults **nicht** automatisch — der Job-Step ist
> beim Anlegen fest eingebacken. Mit `-Overwrite` neu erstellen, um Force/Backup/Retention/Audit
> zu aktivieren. Backups (`LoginBackup_*.sql`), Sync-Logs (`LoginSync_<AG>_*.log`) und ggf.
> Audit-Reports werden nach `-BackupRetentionDays` Tagen automatisch aufgeräumt.

### Praxisbeispiele: Auto-Repair AlwaysOn

`Repair-sqmAlwaysOnDatabases` prüft alle AG-Datenbanken auf Probleme und stellt sie über den
Ablauf **Remove → Cleanup → Add** (Re-Seeding) wieder her. Für den unbeaufsichtigten Betrieb
wird die Reparatur als SQL Agent Job eingerichtet (`New-sqmAlwaysOnRepairJob`).

Manuelle Reparatur (auf dem Primary ausführen):

```powershell
# Alle problematischen AG-Datenbanken automatisch reparieren
Repair-sqmAlwaysOnDatabases

# Reparatur erzwingen - auch fuer aktuell gesunde Datenbanken
Repair-sqmAlwaysOnDatabases -Force
```

Auto-Repair als Agent-Job einrichten:

```powershell
# Stuendlicher Repair-Job (Standard)
New-sqmAlwaysOnRepairJob

# Taeglicher Repair-Job um 02:00 Uhr
New-sqmAlwaysOnRepairJob -Schedule "FREQ=DAILY;INTERVAL=1" -StartTime "02:00:00"

# Eigener Jobname auf einer bestimmten Instanz
New-sqmAlwaysOnRepairJob -SqlInstance "SQLPRIM01" -JobName "AO-AutoRepair" -Schedule "FREQ=DAILY;INTERVAL=1" -StartTime "03:00:00"
```

> Der Job wird auf dem **Primary** angelegt und ausgeführt. Die Reparatur betrifft automatisch
> die Secondary-Replicas (Re-Seeding über Automatic Seeding). In einer FI-TS-Umgebung sollte der
> Jobname mit dem vorgegebenen Präfix beginnen.

## Konfiguration & Dokumentation

| Funktion | Zweck |
|---|---|
| `Export-sqmAlwaysOnConfiguration` | Exportiert die komplette AlwaysOn-AG-Konfiguration einer oder mehrerer Instanzen. |

---

## Typischer Betriebs-Workflow

1. **Überwachen** — `Get-sqmAlwaysOnHealthReport` regelmäßig laufen lassen;
   `Get-sqmAlwaysOnFailoverHistory` nach Auffälligkeiten prüfen.
2. **Failover** — bei Wartung oder Störung `Invoke-sqmFailover` mit integrierten Vor-/Nachprüfungen
   statt manuellem `ALTER AVAILABILITY GROUP ... FAILOVER`.
3. **Logins konsistent halten** — nach Änderungen am Primary `Sync-sqmLoginsToAlwaysOn`,
   zur Kontrolle `Compare-sqmAlwaysOnLogins` (Login-Attribute) und `Compare-sqmAlwaysOnRoles`
   (Server-Rollen-Mitgliedschaft — wird von AlwaysOn nicht mitrepliziert).
4. **Automatisieren** — wiederkehrende Aufgaben als Agent-Jobs einrichten
   (`New-sqmAutoLoginSyncJob`, `New-sqmAutoLoginCompareJob`, `New-sqmAlwaysOnRepairJob`).
   Der Compare-Job geht bei Login-Drift gezielt auf Fail und meldet dies (Operator + Windows Event Log
   für Splunk-Auswertung).
5. **Dokumentieren** — Konfiguration mit `Export-sqmAlwaysOnConfiguration` sichern.
