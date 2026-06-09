@echo off
:: sqmSQLTool Installer
:: Runs Install.ps1 with ExecutionPolicy Bypass (recommended for cross-domain shares).
:: Automatically re-launches elevated (UAC) when AllUsers scope is requested.
::
:: Usage:
::   Install.cmd                   -> auto-detect: AllUsers if Admin, CurrentUser otherwise
::   Install.cmd AllUsers          -> installs system-wide (auto-elevates via UAC if needed)
::   Install.cmd CurrentUser       -> installs for current user only (no elevation needed)
::   Install.cmd AllUsers "D:\Modules\sqmSQLTool"  -> system-wide, custom path

setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "SCOPE=%~1"
set "DESTINATION=%~2"

:: ---------------------------------------------------------------
:: Pruefen ob Script bereits als Administrator laeuft
:: ---------------------------------------------------------------
net session >nul 2>&1
set "IS_ADMIN=%errorlevel%"

:: ---------------------------------------------------------------
:: AllUsers (oder kein Scope) ohne Admin -> UAC-Elevation
:: Ausnahme: CurrentUser braucht keine Elevation
:: ---------------------------------------------------------------
if /i not "%SCOPE%"=="CurrentUser" (
    if "%IS_ADMIN%" neq "0" (
        echo.
        echo  sqmSQLTool - Elevation erforderlich
        echo  ============================================================
        echo  AllUsers-Installation benoetigt Administratorrechte.
        echo  Starte UAC-Abfrage ...
        echo.

        if "%DESTINATION%"=="" (
            if "%SCOPE%"=="" (
                powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
                    "Start-Process cmd.exe -ArgumentList '/c ""%~f0""' -Verb RunAs"
            ) else (
                powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
                    "Start-Process cmd.exe -ArgumentList '/c ""%~f0"" %SCOPE%' -Verb RunAs"
            )
        ) else (
            powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
                "Start-Process cmd.exe -ArgumentList '/c ""%~f0"" %SCOPE% ""%DESTINATION%""' -Verb RunAs"
        )
        exit /b 0
    )
)

:: ---------------------------------------------------------------
:: Install.ps1 ausfuehren (laeuft jetzt mit den richtigen Rechten)
:: ---------------------------------------------------------------
echo.
echo  sqmSQLTool - Installation
echo  ============================================================

:: Erster Versuch: direkt vom (ggf. Remote-) Skriptverzeichnis
call :RUN_INSTALL "%SCRIPT_DIR%Install.ps1"

:: ---------------------------------------------------------------
:: Fallback: schlaegt die Ausfuehrung vom Remote-Laufwerk fehl
:: (GPO RemoteSigned ignoriert -ExecutionPolicy Bypass, Mark-of-the-Web
:: blockiert das unsignierte .ps1), dann Bootstrap lokal stagen und
:: von dort starten. "type > datei" erzeugt eine frische Datei NUR aus dem
:: Hauptstream - der Zone.Identifier-ADS (MOTW) wird dabei nicht uebernommen.
:: ---------------------------------------------------------------
if not "%ERRORLEVEL%"=="0" (
    echo.
    echo  Ausfuehrung vom Quellverzeichnis fehlgeschlagen (Execution Policy / Signatur).
    echo  Fallback: stage Bootstrap lokal und starte erneut ...

    set "BOOT_DIR=%TEMP%\sqmSQLTool_boot"
    if not exist "!BOOT_DIR!" md "!BOOT_DIR!"
    type "%SCRIPT_DIR%Install.ps1" > "!BOOT_DIR!\Install.ps1"

    :: Trailing-Backslash aus SCRIPT_DIR entfernen (sonst Quoting-Bug bei -Source)
    set "SRC_DIR=%SCRIPT_DIR%"
    if "!SRC_DIR:~-1!"=="\" set "SRC_DIR=!SRC_DIR:~0,-1!"

    call :RUN_INSTALL "!BOOT_DIR!\Install.ps1" -Source "!SRC_DIR!"

    rmdir /s /q "!BOOT_DIR!" >nul 2>&1
)

endlocal
pause
goto :EOF

:: ===============================================================
:: Subroutine: Install.ps1 mit den passenden Argumenten starten.
::   %~1 = Pfad zu Install.ps1
::   %~2 %~3 = optionale Zusatzargumente (z.B. -Source "<pfad>")
:: ===============================================================
:RUN_INSTALL
set "PS1=%~1"
:: %2 %3 OHNE Tilde, damit die Quotes um den -Source-Pfad erhalten bleiben
set "EXTRA=%2 %3"
if "%DESTINATION%"=="" (
    if "%SCOPE%"=="" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %EXTRA%
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Scope "%SCOPE%" %EXTRA%
    )
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Scope "%SCOPE%" -Destination "%DESTINATION%" %EXTRA%
)
goto :EOF
