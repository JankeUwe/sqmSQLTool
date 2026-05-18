@echo off
:: sqmSQLTool Installer
:: Startet Install.ps1 mit ExecutionPolicy Bypass
:: Empfohlen wenn das Modul von einem cross-domain Share installiert wird
::
:: Aufruf: Install.cmd
:: Optionaler Zielpfad: Install.cmd "D:\Modules\sqmSQLTool"

setlocal

set "SCRIPT_DIR=%~dp0"
set "DESTINATION=%~1"

if "%DESTINATION%"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install.ps1" -Destination "%DESTINATION%"
)

endlocal
pause
