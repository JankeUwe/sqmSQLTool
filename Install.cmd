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

if "%DESTINATION%"=="" (
    if "%SCOPE%"=="" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install.ps1"
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install.ps1" -Scope "%SCOPE%"
    )
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install.ps1" -Scope "%SCOPE%" -Destination "%DESTINATION%"
)

endlocal
pause
