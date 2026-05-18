# Integration Tests

Diese Tests erfordern eine echte SQL Server Instanz und werden **nicht** im normalen CI-Lauf ausgeführt.

## Voraussetzungen

- SQL Server 2019 oder neuer, lokal erreichbar
- dbatools installiert
- Ausführung als Administrator

## Aufruf

```powershell
# Integration Tests separat ausführen
Invoke-Pester -Path .\tests\Integration -Output Detailed
```

## Konvention

- Jede Testdatei definiert am Anfang `$script:TestInstance` (Standard: `$env:COMPUTERNAME`)
- Tests dürfen **keine Produktionsdaten** verändern — nur dedizierte Testdatenbanken (`sqmTest_*`)
- Cleanup in `AfterAll` ist Pflicht
