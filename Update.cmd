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

:: Erster Versuch: direkt vom (ggf. Remote-) Skriptverzeichnis
call :RUN_UPDATE "%SCRIPT_DIR%Update.ps1"

:: ---------------------------------------------------------------
:: Fallback: schlaegt die Ausfuehrung vom Remote-Laufwerk fehl
:: (GPO RemoteSigned ignoriert -ExecutionPolicy Bypass, Mark-of-the-Web
:: blockiert das unsignierte .ps1), dann Bootstrap lokal stagen und
:: von dort starten. "type > datei" erzeugt eine frische Datei NUR aus dem
:: Hauptstream - der Zone.Identifier-ADS (MOTW) wird dabei nicht uebernommen.
:: Update.ps1 liest das Modul ohnehin aus -RepositoryPath, daher kein -Source noetig.
:: ---------------------------------------------------------------
if not "%ERRORLEVEL%"=="0" (
    echo.
    echo  Ausfuehrung vom Quellverzeichnis fehlgeschlagen (Execution Policy / Signatur).
    echo  Fallback: stage Bootstrap lokal und starte erneut ...

    set "BOOT_DIR=%TEMP%\sqmSQLTool_boot"
    if not exist "!BOOT_DIR!" md "!BOOT_DIR!"
    type "%SCRIPT_DIR%Update.ps1" > "!BOOT_DIR!\Update.ps1"

    call :RUN_UPDATE "!BOOT_DIR!\Update.ps1"

    rmdir /s /q "!BOOT_DIR!" >nul 2>&1
)

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
