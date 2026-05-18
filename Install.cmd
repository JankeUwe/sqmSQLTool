@echo off
:: sqmSQLTool Installer
:: Runs Install.ps1 with ExecutionPolicy Bypass (recommended for cross-domain shares)
::
:: Usage:
::   Install.cmd                   -> installs for current user (no Admin required)
::   Install.cmd AllUsers          -> installs system-wide (requires Admin)
::   Install.cmd AllUsers "D:\Modules\sqmSQLTool"  -> system-wide, custom path

setlocal

set "SCRIPT_DIR=%~dp0"
set "SCOPE=%~1"
set "DESTINATION=%~2"

if "%SCOPE%"=="" set "SCOPE=CurrentUser"

if "%DESTINATION%"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install.ps1" -Scope "%SCOPE%"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install.ps1" -Scope "%SCOPE%" -Destination "%DESTINATION%"
)

endlocal
pause
