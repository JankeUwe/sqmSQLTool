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

:: -WindowStyle Minimized statt Hidden: ein komplett verstecktes PowerShell-Fenster ist
:: ein klassisches AV/EDR-Alarmsignal auf ueberwachten SQL-Servern. Minimiert reicht fuer
:: einen sauberen Doppelklick-Start und bleibt trotzdem nachvollziehbar sichtbar (Taskleiste).
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -Command ^
    "try { Import-Module sqmSQLTool -ErrorAction Stop; Show-sqmToolGui } catch { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(('sqmSQLTool konnte nicht geladen werden:' + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'Bitte zuerst Install.cmd AllUsers ausfuehren.'), 'sqmSQLTool GUI', 'OK', 'Error') }"

exit /b 0
