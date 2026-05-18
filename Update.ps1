#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Aktualisiert das sqmSQLTool-Modul aus dem zentralen Share.
.DESCRIPTION
    Prueft ob eine neuere Version im Repository verfuegbar ist, kopiert
    die Dateien ohne Zone.Identifier (kein ADS) und entblockt alle Dateien
    im Zielverzeichnis. Erstellt vor dem Update automatisch ein Backup.
.PARAMETER RepositoryPath
    Pfad zum Update-Share. Standard: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool
.PARAMETER Destination
    Zielpfad des installierten Moduls.
    Standard: %ProgramFiles%\WindowsPowerShell\Modules\sqmSQLTool
.PARAMETER Force
    Update auch ohne neuere Version erzwingen.
.NOTES
    Aufruf direkt:    .\Update.ps1
    Aufruf vom Share: Update.cmd   (empfohlen bei cross-domain Shares)
    Mit eigenem Pfad: Update.cmd "\\anderer\Share\sqmSQLTool"
#>
param(
    [string]$RepositoryPath = 'W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool',
    [string]$Destination    = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmSQLTool",
    [switch]$Force
)

# ---------------------------------------------------------------------------
# 1. Repository pruefen
# ---------------------------------------------------------------------------
if (-not (Test-Path $RepositoryPath)) {
    Write-Error "Repository nicht erreichbar: $RepositoryPath"
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Versionspruefung
# ---------------------------------------------------------------------------
$remoteVersion  = $null
$currentVersion = $null

$remoteVersionFile = Join-Path $RepositoryPath 'ModuleVersion.txt'
$remoteManifest    = Join-Path $RepositoryPath 'sqmSQLTool.psd1'
$localManifest     = Join-Path $Destination    'sqmSQLTool.psd1'

if (Test-Path $remoteVersionFile) {
    $remoteVersion = [version](Get-Content $remoteVersionFile -ErrorAction Stop).Trim()
} elseif (Test-Path $remoteManifest) {
    $remoteVersion = [version](Import-PowerShellDataFile $remoteManifest).ModuleVersion
} else {
    Write-Warning "Keine Versionsinformation im Repository gefunden. Fahre fort..."
}

if (Test-Path $localManifest) {
    $currentVersion = [version](Import-PowerShellDataFile $localManifest).ModuleVersion
}

if ($remoteVersion -and $currentVersion) {
    Write-Host "Installiert : v$currentVersion" -ForegroundColor Gray
    Write-Host "Repository  : v$remoteVersion"  -ForegroundColor Gray
    if (-not $Force -and $remoteVersion -le $currentVersion) {
        Write-Host "Bereits aktuell (v$currentVersion). Kein Update noetig." -ForegroundColor Green
        exit 0
    }
}

# ---------------------------------------------------------------------------
# 3. Backup des aktuellen Moduls
# ---------------------------------------------------------------------------
if (Test-Path $Destination) {
    $backupDir = "$Destination`_Backup_$(Get-Date -Format 'yyyyMMdd_HHmm')"
    Write-Host "Erstelle Backup: $backupDir" -ForegroundColor Cyan
    Copy-Item -Path $Destination -Destination $backupDir -Recurse -Force
}

# ---------------------------------------------------------------------------
# 4. Update kopieren — ohne ADS (kein Zone.Identifier)
# ---------------------------------------------------------------------------
Write-Host "Kopiere Update von: $RepositoryPath" -ForegroundColor Cyan
robocopy $RepositoryPath $Destination /E /NJH /NJS /NDL /COPY:DAT /XD .git /XF .gitignore README.md LICENSE Install.cmd Install.ps1 Update.cmd Update.ps1

# ---------------------------------------------------------------------------
# 5. Zone.Identifier auf dem Ziel entfernen
# ---------------------------------------------------------------------------
Write-Host "Entsperre Dateien im Zielverzeichnis..." -ForegroundColor Cyan
Get-ChildItem -Path $Destination -Recurse -File | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 6. Import testen
# ---------------------------------------------------------------------------
Write-Host "Teste Modul-Import..." -ForegroundColor Cyan
try {
    Remove-Module sqmSQLTool -ErrorAction SilentlyContinue
    Import-Module sqmSQLTool -Force -ErrorAction Stop
    $version = (Get-Module sqmSQLTool).Version
    Write-Host "sqmSQLTool v$version erfolgreich geladen." -ForegroundColor Green
} catch {
    Write-Warning "Import fehlgeschlagen: $_"
    Write-Warning "Backup verfuegbar unter: $backupDir"
}
