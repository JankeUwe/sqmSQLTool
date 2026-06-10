@echo off
:: sqmSQLTool Updater
:: Startet Update.ps1 mit ExecutionPolicy Bypass
:: Empfohlen wenn das Modul von einem cross-domain Share aktualisiert wird
::
:: Aufruf:                    Update.cmd
:: Eigener Repository-Pfad:   Update.cmd "\\anderer\Share\sqmSQLTool"
:: Update erzwingen:          Update.cmd "" Force

setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "REPOSITORY=%~1"
set "FORCE=%~2"

:: ---------------------------------------------------------------
:: Bootstrap IMMER lokal stagen und von dort starten (kein Remote-Versuch).
:: Grund: Eine per GPO gesetzte MachinePolicy (z.B. RemoteSigned) ueberstimmt
:: -ExecutionPolicy Bypass (Process-Scope). Ein .ps1 von einem Remote-/UNC-Pfad
:: (\\tsclient\..., Netz-Share) wird dann als unsigniertes Remote-Skript
:: blockiert - der Remote-Versuch scheitert in dieser Umgebung IMMER.
:: "type > datei" erzeugt eine frische LOKALE Datei ohne Zone.Identifier (MOTW),
:: damit laeuft das unsignierte Skript unter RemoteSigned.
:: Update.ps1 liest das Modul aus -RepositoryPath; wenn REPOSITORY leer ist,
:: setzen wir es auf den tatsaechlichen Startpfad (sonst greift der hardcoded
:: Default W:\... und nicht der Share, von dem Update.cmd gestartet wurde).
:: ---------------------------------------------------------------
:: Trailing-Backslash aus SCRIPT_DIR entfernen
set "SRC_DIR=%SCRIPT_DIR%"
if "!SRC_DIR:~-1!"=="\" set "SRC_DIR=!SRC_DIR:~0,-1!"
if "%REPOSITORY%"=="" set "REPOSITORY=!SRC_DIR!"

set "BOOT_DIR=%TEMP%\sqmSQLTool_boot"
if not exist "!BOOT_DIR!" md "!BOOT_DIR!"
type "%SCRIPT_DIR%Update.ps1" > "!BOOT_DIR!\Update.ps1"

call :RUN_UPDATE "!BOOT_DIR!\Update.ps1"

rmdir /s /q "!BOOT_DIR!" >nul 2>&1

endlocal
pause
goto :EOF

:: ===============================================================
:: Subroutine: Update.ps1 mit den passenden Argumenten starten.
::   %~1 = Pfad zu Update.ps1
:: Nutzt REPOSITORY und FORCE aus dem aeusseren Scope.
:: ===============================================================
:RUN_UPDATE
set "PS1=%~1"
if "%REPOSITORY%"=="" (
    if /i "%FORCE%"=="Force" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Force
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
    )
) else (
    if /i "%FORCE%"=="Force" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RepositoryPath "%REPOSITORY%" -Force
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RepositoryPath "%REPOSITORY%"
    )
)
goto :EOF
