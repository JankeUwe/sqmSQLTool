# sqmSQLTool — Changelog

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
