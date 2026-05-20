@echo off
:: sqmSQLTool Installer
:: Runs Install.ps1 with ExecutionPolicy Bypass (recommended for cross-domain shares)
::
:: Usage:
::   Install.cmd                   -> auto-detect: AllUsers if Admin, CurrentUser otherwise
::   Install.cmd AllUsers          -> installs system-wide (requires Admin)
::   Install.cmd CurrentUser       -> installs for current user only
::   Install.cmd AllUsers "D:\Modules\sqmSQLTool"  -> system-wide, custom path

setlocal

set "SCRIPT_DIR=%~dp0"
set "SCOPE=%~1"
set "DESTINATION=%~2"

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
