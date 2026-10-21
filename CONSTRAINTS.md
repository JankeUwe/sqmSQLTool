# Qualitaetsregeln (Quality Gate)

Pruefung: `Tools/Test-QualityGate.ps1`. Zahlen: `Tools/quality-baseline.json`.
Diese Datei beschreibt die Regeln, die Zahlen stehen nur in der Baseline.

```powershell
# Schnell (ca. 1,5 min), laeuft auch im pre-push-Hook
powershell.exe -NoProfile -File .\Tools\Test-QualityGate.ps1

# Vollstaendig mit Pester und Coverage (ca. 8 min), vor jedem Release
powershell.exe -NoProfile -File .\Tools\Test-QualityGate.ps1 -Pester
```

Das Gate laeuft unter **Windows PowerShell 5.1**, weil das Modul dort ausgeliefert wird.
Ein gruener Lauf unter pwsh beweist weniger, als er aussieht.

## Untergrenzen (Floor)

Muessen 0 sein. Sie lassen sich nicht ueber die Baseline lockern, nur durch Beheben.

| Kennzahl | Warum |
|---|---|
| `ParseErrors51` | Der 5.1-Parser findet auch PS7-only Syntax (`??`, `?.`, Ternary, `&&`). Unter pwsh unsichtbar. |
| `KeywordAsCommand` | `(if ...)` und `return if ...` parsen fehlerfrei und brechen erst zur Laufzeit mit "The term 'if' is not recognized" ab, oft nach der teuren Arbeit. |
| `DuplicateParameterBinding` | Splat-Hashtable plus gleicher Parameter explizit: PS 7 toleriert es, 5.1 bricht mit ParameterAlreadyBound ab. Pruefung: `Tools/Test-DuplicateParameterBinding.ps1`. |
| `PssaErrors` | PSScriptAnalyzer, Severity Error, mit `PSScriptAnalyzerSettings.psd1`. |
| `ManifestExportDrift` | `Public\<Verb-Noun>.ps1` muss die gleichnamige Funktion definieren und exportieren; jeder Export muss definiert sein. |
| `CustomerTerms` | Keine Kunden- oder Umgebungsnamen im oeffentlichen Repo, auch nicht in CHANGELOG oder Doku. Die Begriffsliste liegt bewusst ausserhalb des Repos (`-CustomerTermsFile`). |
| `BomMissing` | Jede `.ps1/.psm1/.psd1` mit UTF-8 BOM, sonst liest 5.1 Umlaute als ANSI. |
| `UnscopedParameterSetMix` | Ein Parameter mit benanntem `ParameterSetName` und zusaetzlich unscoped `[Parameter()]` bricht die Set-Aufloesung, sobald ein set-spezifischer Parameter dazukommt. |
| `PesterFailed` | Nur mit `-Pester`. Rote Tests werden nicht "voruebergehend" geduldet. |

## Ratsche (Ratchet)

Duerfen nicht schlechter werden als die Baseline. Kein Zielwert, nur eine Richtung.

| Kennzahl | Richtung | Bedeutung |
|---|---|---|
| `PssaWarnings` | runter | PSScriptAnalyzer Warnings |
| `EmptyCatch` | runter | leere `catch { }` in Public/Private: verschluckte Fehler |
| `SuppressMessage` | runter | stummgeschaltete Analyzer-Regeln |
| `WmiCmdlets` | runter | `Get-WmiObject` & Co., gibt es unter PS 7 nicht |
| `DbaStopWithoutException` | runter | dbatools-Aufruf mit `ErrorAction Stop` (explizit oder per Splat) ohne `EnableException`. dbatools wirft dann bei Fehlern nicht, sondern liefert nichts; der `catch` darum greift nie. Neue Aufrufe: `-EnableException` direkt am Aufruf, nicht im Splat (`Connect-DbaInstance` kennt den Parameter nicht). Bei Enumerationen ueber viele Objekte bedenken: mit `EnableException` bricht ein Fehler bei einem Objekt den ganzen Aufruf ab. |
| `PublicWithoutTest` | runter | exportierte Funktionen, die in `tests\` nirgends vorkommen |
| `BareShouldThrow` | runter | `Should -Throw` ohne `-ExpectedMessage`: beweist nicht, *warum* es wirft |
| `SkippedTests` | runter | `It -Skip`, `Set-ItResult -Skipped/-Inconclusive` |
| `CoveragePercent` | hoch | Code Coverage `Public\` (nur mit `-Pester`). Toleranz 1 Prozentpunkt: der Wert schwankt ohne Codeaenderung (29,03 / 28,49 bei identischem Stand). Die Baseline steigt nur bei Verbesserung. |

## Aendern der Baseline

- **Verschaerfen ist leise:** `-UpdateBaseline` schreibt verbesserte Werte zurueck. Nach jeder
  Verbesserung ausfuehren, sonst kann die gewonnene Luft spaeter wieder verbraucht werden.
- **Lockern ist laut:** nur mit
  `-AcceptRegression <Kennzahl> -Reason '<Begruendung>' [-ExpiresOn yyyy-MM-dd]`.
  Die Ausnahme steht mit Datum, alten und neuen Wert und Ablaufdatum (Standard 90 Tage) in der
  Baseline. Abgelaufene Ausnahmen meldet das Gate.
- Das Gate vergleicht die Baseline mit `-CompareRef` (Standard `HEAD`, im pre-push-Hook
  `origin/main`). Ein gelockerter Wert ohne passende Ausnahme laesst es fehlschlagen, auch wenn
  jemand die JSON-Datei von Hand bearbeitet hat.
- Die Baseline nie im selben Commit lockern wie das Feature, das sie verschlechtert hat. Erst
  beheben versuchen; wenn das nicht geht, die Ausnahme als eigenen Commit mit Begruendung.
- Untergrenzen werden nie gelockert. Ein Fehlalarm wird in `Test-QualityGate.ps1` behoben (mit
  Test, warum die Stelle kein Fehler ist), nicht durch Ausnehmen der Datei.

## Wo das Gate laeuft

| Wann | Was | Dauer |
|---|---|---|
| nach jeder Aenderung | Gate ohne `-Pester` | ca. 1,5 min |
| pre-push-Hook | Gate ohne `-Pester`, `-CompareRef origin/main` | ca. 1,5 min |
| vor Release / Versionssprung | Gate mit `-Pester` | ca. 8 min |
| GitHub CI | bestehende Schritte (PSSA Errors, BOM, Duplicate Binding, Pester) | |

Das Gate laeuft nicht in der CI, weil dort die Kundenbegriffsliste fehlt und PSScriptAnalyzer-
Versionen die Warnungszahl verschieben koennen.
