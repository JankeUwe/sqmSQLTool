# Standort-Profil (`sqmSQLTool.site.json`)

Umgebungsspezifische Vorgaben wie Agent-Job-Namen, Freigabepfade fuer eine dbatools-Baseline,
einen Monitoring-Account oder den Registry-Pfad fuer das Monitoring stehen nicht im Modulcode.
Sie kommen aus einer optionalen JSON-Datei, die **nicht** versioniert wird (`.gitignore`).

## Suchreihenfolge

1. `<Modulordner>\sqmSQLTool.site.json` - `Install.ps1` kopiert die Datei aus der
   Installationsquelle mit, wenn sie dort neben `Install.ps1` liegt.
   `Update-sqmModule` (UNC/Verzeichnis) legt hier ein Profil ab, das in einem uebergeordneten
   Ordner der Update-Quelle liegt.
2. `%ProgramData%\MSSQLTools\sqmSQLTool.site.json` - maschinenweit, gilt fuer alle Benutzer und
   ueberlebt Modul-Updates aus Quellen ohne Profil. `Install.ps1` legt die Datei hier ab, sobald
   die Installationsquelle ein Profil enthaelt.

Die erste gefundene Datei gilt.

`Install.ps1` sucht in dieser Reihenfolge: Quellordner, **jeder uebergeordnete Ordner der Quelle**,
`%ProgramData%\MSSQLTools`. Empfohlen: das Profil einmal auf der Freigabe **neben den Modulordner**
legen (z. B. `<Freigabe>\...\sqmSQLTool.site.json` neben `<Freigabe>\...\sqmSQLTool\`). Dann muss
keine neue Modulversion das Profil enthalten. Ein Profil aus der Quelle ersetzt die Kopie unter
`%ProgramData%`. `Install.ps1` gibt aus, welches Profil gilt bzw. welche Pfade ohne Treffer geprueft
wurden.

## Aufbau

```json
{
  "Name": "Beispiel-Standort",
  "Detection": {
    "ModulePathPatterns": [ "S:\\*", "\\\\tsclient\\S\\*" ],
    "UserDnsDomains": [ "CORP.EXAMPLE" ],
    "UserDomains": [ "CORP" ]
  },
  "Defaults": {
    "MonitoringRegistrySubKey": "Example\\SystemCenter"
  },
  "Config": {
    "OlaJobNameFull": "SITE Backup - USER_DATABASES - FULL",
    "OlaJobNameBackupExcludeSync": "SITE BackupExclude - SYNC",
    "DbatoolsSharePath": "S:\\SQLAdmin\\Modules",
    "DefaultMonitoringUser": "%USERDOMAIN%\\svc_monitoring",
    "CheckProfile": "Site"
  },
  "DbatoolsShareCandidates": [ "S:\\SQLAdmin\\Modules", "\\\\tsclient\\S\\SQLAdmin\\Modules" ],
  "DbatoolsLegacyShareCandidates": [ "S:\\SQLSources\\Modules" ],
  "Install": {
    "SourcePatterns": [ "S:\\*", "\\\\tsclient\\S\\*" ],
    "Config": {
      "OlaJobNameFull": "SITE-UserDatabases-FULL",
      "DefaultPolicy": "My Login Policy",
      "CheckProfile": "Site"
    }
  }
}
```

| Abschnitt | Wirkung |
|---|---|
| `Detection` | Wann `Config` gilt: Modulpfad passt auf ein Muster (`-like`) **oder** `USERDNSDOMAIN` / `USERDOMAIN` steht in der Liste. Ohne `Detection` gilt `Config` immer. |
| `Defaults` | Gilt immer, wenn das Profil vorhanden ist - wie ein eingebauter Standardwert. Ein Wert in `config.json` hat Vorrang. |
| `Config` | Wird beim Modulimport **nach** `config.json` gesetzt und hat Vorrang. `%VAR%` in Strings wird expandiert. |
| `DbatoolsShareCandidates`, `DbatoolsLegacyShareCandidates` | Findet der Modulimport kein dbatools im `PSModulePath`, werden diese Freigaben in dieser Reihenfolge geprueft (erster Treffer mit Unterordner `dbatools` gewinnt). `Install.ps1` prueft fuer das Sideloading: konfigurierter `DbatoolsSharePath`, dann `DbatoolsShareCandidates`, dann `<Quelle>\..\..\Modules`. |
| `Install.SourcePatterns` | Passt `-Source` von `Install.ps1` auf ein Muster, gilt die Installation als Standort-Installation (dbatools-Sideloading von der Freigabe, `Install.Config` wird per `Set-sqmConfig` gespeichert). Ohne Muster gilt jede Installation mit Profil als Standort-Installation. |
| `Install.Config` | Parameter fuer `Set-sqmConfig` nach erfolgreicher Installation (persistiert in `config.json` des installierenden Benutzers). |

## Konfigurationsschluessel ohne Profil

| Schluessel | Neutraler Standard |
|---|---|
| `OlaJobNameBackupExcludeSync` | `sqm BackupExclude - SYNC` |
| `MonitoringRegistrySubKey` | `sqmSQLTool\SystemCenter` (unter `HKLM:\<RegistryBase>`) |
| `CheckProfile` | `Auto` (Werte: `Auto`, `Site`, `Generic`; der fruehere Wert `FiTs` wird als `Site` uebernommen) |

## Hinweis fuer Updates

Wird eine neue Modulversion ohne Profil in der Quelle verteilt, bleibt ein bereits unter
`%ProgramData%\MSSQLTools` abgelegtes Profil wirksam. Fehlt das Profil ganz, gelten die neutralen
Standardwerte. Steht `CheckProfile` dann noch auf `Site` (bzw. dem frueheren Wert), warnt der
Modulimport.
