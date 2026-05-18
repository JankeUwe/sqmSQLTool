@echo off
:: sqmSQLTool Updater
:: Startet Update.ps1 mit ExecutionPolicy Bypass
:: Empfohlen wenn das Modul von einem cross-domain Share aktualisiert wird
::
:: Aufruf:                    Update.cmd
:: Eigener Repository-Pfad:   Update.cmd "\\anderer\Share\sqmSQLTool"
:: Update erzwingen:          Update.cmd "" Force

setlocal

set "SCRIPT_DIR=%~dp0"
set "REPOSITORY=%~1"
set "FORCE=%~2"

if "%REPOSITORY%"=="" (
    if /i "%FORCE%"=="Force" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Update.ps1" -Force
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Update.ps1"
    )
) else (
    if /i "%FORCE%"=="Force" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Update.ps1" -RepositoryPath "%REPOSITORY%" -Force
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Update.ps1" -RepositoryPath "%REPOSITORY%"
    )
)

endlocal
pause
