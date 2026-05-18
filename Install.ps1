#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installiert das sqmSQLTool-Modul in den systemweiten PowerShell-Modulpfad.
.NOTES
    Aufruf direkt:     .\Install.ps1
    Aufruf vom Share:  Install.cmd   (empfohlen bei cross-domain Shares)
    Optionaler Zielpfad: .\Install.ps1 -Destination "D:\Modules\sqmSQLTool"
#>
param(
    [string]$Source      = $PSScriptRoot,
    [string]$Destination = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmSQLTool"
)

# ---------------------------------------------------------------------------
# 1. Modul in Zielpfad kopieren
#    /COPY:DAT  -> keine Alternate Data Streams kopieren (kein Zone.Identifier)
#    /XD .git   -> git-Verzeichnis ausschliessen
#    /XF        -> Meta-Dateien ausschliessen
# ---------------------------------------------------------------------------
Write-Host "Kopiere nach: $Destination" -ForegroundColor Cyan
robocopy $Source $Destination /E /PURGE /NJH /NJS /NDL /COPY:DAT /XD .git /XF .gitignore README.md LICENSE Install.cmd

# ---------------------------------------------------------------------------
# 2. Zone.Identifier auf dem ZIEL entfernen
#    (Dateien von cross-domain Shares bekommen Zone 3 "Internet" - auch ohne ADS)
# ---------------------------------------------------------------------------
Write-Host "Entsperre Dateien im Zielverzeichnis..." -ForegroundColor Cyan
Get-ChildItem -Path $Destination -Recurse -File | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
}

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
