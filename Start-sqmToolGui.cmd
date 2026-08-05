@echo off
:: sqmSQLTool GUI - Doppelklick-Start
:: Startet Show-sqmToolGui elevated: viele GUI-Funktionen (z.B. Invoke-sqmNtfsSetup,
:: Eventlog-Quellen registrieren) brauchen lokale Adminrechte. Relauncht sich bei Bedarf
:: per UAC selbst - kein CurrentUser-Zweig, die GUI braucht ohnehin immer Adminrechte.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo sqmSQLTool GUI - Adminrechte erforderlich, UAC-Abfrage wird gestartet ...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process cmd.exe -ArgumentList '/c ""%~f0""' -Verb RunAs"
    exit /b 0
)

:: Start-sqmToolGui.ps1 (Begleitdatei, liegt neben diesem .cmd) macht den Start robust: fing
:: bisher nur den Import-Module-Fehler ab, nicht aber Ausnahmen, die WAEHREND der
:: ShowDialog()-Message-Loop auftreten - genau das kann unter powershell.exe je nach
:: .NET-Unhandled-Exception-Policy den Prozess kommentarlos beenden (Fenster blitzt kurz auf,
:: dann nichts mehr). Start-sqmToolGui.ps1 setzt SetUnhandledExceptionMode + einen
:: ThreadException-Handler und schreibt jeden Fehler zusaetzlich nach
:: %ProgramData%\sqmSQLTool\gui-launch.log.
:: -WindowStyle Normal (nicht Minimized/Hidden), solange dieser Fehlerpfad noch nicht auf allen
:: Zielmaschinen verifiziert ist - ein sichtbares Fenster ist beim Debuggen wichtiger als das
:: sonst berechtigte AV/EDR-Argument fuer ein verstecktes Fenster.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "%~dp0Start-sqmToolGui.ps1"

exit /b 0
