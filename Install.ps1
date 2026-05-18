#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installiert das sqmSQLTool-Modul in den systemweiten PowerShell-Modulpfad.
.DESCRIPTION
    Entsperrt alle Skriptdateien (Unblock-File), kopiert das Modul nach
    %ProgramFiles%\WindowsPowerShell\Modules\sqmSQLTool und prueft den Import.
.NOTES
    Muss als Administrator ausgefuehrt werden.
    Aufruf: .\Install.ps1
    Optionaler Zielpfad: .\Install.ps1 -Destination "D:\Modules\sqmSQLTool"
#>
param(
    [string]$Source      = $PSScriptRoot,
    [string]$Destination = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmSQLTool"
)

# ---------------------------------------------------------------------------
# 1. Alle Dateien entsperren (entfernt Zone.Identifier ADS)
#    Verhindert "execution policy overridden" beim Import auf dem Zielserver
# ---------------------------------------------------------------------------
Write-Host "Entsperre Dateien..." -ForegroundColor Cyan
Get-ChildItem -Path $Source -Recurse -File | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 2. Modul in Zielpfad kopieren
# ---------------------------------------------------------------------------
Write-Host "Kopiere nach: $Destination" -ForegroundColor Cyan
robocopy $Source $Destination /E /PURGE /NJH /NJS /NDL /XD .git /XF .gitignore README.md LICENSE

# ---------------------------------------------------------------------------
# 3. Import testen
# ---------------------------------------------------------------------------
Write-Host "Teste Modul-Import..." -ForegroundColor Cyan
try {
    Import-Module sqmSQLTool -Force -ErrorAction Stop
    $version = (Get-Module sqmSQLTool).Version
    Write-Host "sqmSQLTool v$version erfolgreich geladen." -ForegroundColor Green
} catch {
    Write-Warning "Import fehlgeschlagen: $_"
}
