#Requires -Version 5.1
<#
.SYNOPSIS
    Lokales Release-Signing fuer sqmSQLTool via SignPath.io API.

.DESCRIPTION
    Packt das Modul als ZIP, sendet es an SignPath.io zum Signieren
    und entpackt die signierten Dateien zurueck ins Modul-Verzeichnis.

    Voraussetzung: SignPath PowerShell-Modul installiert.
      Install-Module SignPath -Force

    API Token: in $env:SIGNPATH_API_TOKEN setzen oder per Parameter uebergeben.
    Nie den Token direkt in dieses Script schreiben!

.PARAMETER ApiToken
    SignPath API Token. Standard: $env:SIGNPATH_API_TOKEN

.PARAMETER Version
    Versionsnummer fuer den ZIP-Dateinamen. Standard: aus sqmSQLTool.psd1

.PARAMETER SkipInstall
    SignPath-Modul nicht automatisch installieren.

.EXAMPLE
    # Token als Umgebungsvariable (empfohlen)
    $env:SIGNPATH_API_TOKEN = "IhrToken"
    .\Sign-Release.ps1

.EXAMPLE
    # Token direkt uebergeben
    .\Sign-Release.ps1 -ApiToken "IhrToken"

.EXAMPLE
    # Bestimmte Version
    .\Sign-Release.ps1 -Version "1.4.0"
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$ApiToken = $env:SIGNPATH_API_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OrganizationId    = 'f531b274-6178-4db9-a51d-9b6c56113aaa'
$ProjectSlug       = 'sqmSQLTool'
$SigningPolicySlug = '_Release_Signing'
$ModuleRoot        = $PSScriptRoot
$DistDir           = Join-Path $ModuleRoot 'dist'
$TempDir           = Join-Path $env:TEMP 'sqmSQLTool_signing'

# ---------------------------------------------------------------------------
# Token pruefen
# ---------------------------------------------------------------------------
if (-not $ApiToken) {
    Write-Error @'
Kein API Token angegeben!

Bitte einen der folgenden Wege nutzen:
  1. Umgebungsvariable: $env:SIGNPATH_API_TOKEN = "IhrToken"
  2. Parameter:        .\Sign-Release.ps1 -ApiToken "IhrToken"

Token generieren unter: https://app.signpath.io -> My Profile -> API Token
'@
    exit 1
}

# ---------------------------------------------------------------------------
# SignPath-Modul installieren (falls noetig)
# ---------------------------------------------------------------------------
if (-not $SkipInstall) {
    if (-not (Get-Module -ListAvailable -Name SignPath)) {
        Write-Host 'SignPath PowerShell-Modul wird installiert...' -ForegroundColor Cyan
        Install-Module SignPath -Force -Scope CurrentUser
    }
}
Import-Module SignPath -ErrorAction Stop

# ---------------------------------------------------------------------------
# Version aus PSD1 lesen
# ---------------------------------------------------------------------------
if (-not $Version) {
    $psd1    = Import-PowerShellDataFile (Join-Path $ModuleRoot 'sqmSQLTool.psd1')
    $Version = $psd1.ModuleVersion
}
Write-Host "Version: $Version" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Modul als ZIP packen
# ---------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Path $DistDir -Force
$null = New-Item -ItemType Directory -Path $TempDir -Force

$zipName = "sqmSQLTool-v$Version.zip"
$zipPath = Join-Path $DistDir $zipName
$signedZip = Join-Path $TempDir "sqmSQLTool-v$Version-signed.zip"

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
if (Test-Path $signedZip) { Remove-Item $signedZip -Force }

Write-Host 'Packe Modul-Dateien...' -ForegroundColor Cyan

$exclude = @('.git', 'dist', '.github', 'Tests', '*.log', $zipName)
$files   = Get-ChildItem $ModuleRoot -Recurse -File | Where-Object {
    $rel = $_.FullName.Replace("$ModuleRoot\", '')
    -not ($exclude | Where-Object { $rel -like "$_*" -or $rel -like "*\$_\*" })
}

Compress-Archive -Path $files.FullName -DestinationPath $zipPath -Force
Write-Host "  $($files.Count) Dateien -> $zipPath" -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Signing Request einreichen
# ---------------------------------------------------------------------------
Write-Host 'Sende Signing Request an SignPath.io...' -ForegroundColor Cyan
Write-Host "  Projekt     : $ProjectSlug" -ForegroundColor Gray
Write-Host "  Policy      : $SigningPolicySlug" -ForegroundColor Gray
Write-Host "  Organisation: $OrganizationId" -ForegroundColor Gray

Submit-SigningRequest `
    -InputArtifactPath  $zipPath `
    -OutputArtifactPath $signedZip `
    -ApiToken           $ApiToken `
    -OrganizationId     $OrganizationId `
    -ProjectSlug        $ProjectSlug `
    -SigningPolicySlug  $SigningPolicySlug `
    -WaitForCompletion

Write-Host "Signiertes ZIP: $signedZip" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Signierte Dateien zurueck ins Modul-Verzeichnis entpacken
# ---------------------------------------------------------------------------
Write-Host 'Entpacke signierte Dateien...' -ForegroundColor Cyan

$extractDir = Join-Path $TempDir 'extracted'
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
Expand-Archive -Path $signedZip -DestinationPath $extractDir -Force

# Nur .ps1 / .psm1 / .psd1 zurueckkopieren (signierte Dateien)
$signedFiles = Get-ChildItem $extractDir -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }

foreach ($sf in $signedFiles) {
    $rel  = $sf.FullName.Replace("$extractDir\", '')
    $dest = Join-Path $ModuleRoot $rel
    if (Test-Path $dest) {
        Copy-Item $sf.FullName -Destination $dest -Force
    }
}

Write-Host "  $($signedFiles.Count) Dateien signiert und zurueckkopiert." -ForegroundColor Gray

# Signatur stichprobenartig pruefen
$checkFile = Join-Path $ModuleRoot 'sqmSQLTool.psd1'
$sig       = Get-AuthenticodeSignature $checkFile
Write-Host ""
Write-Host "Signatur-Check ($($sig.SignerCertificate.Subject)):" -ForegroundColor Cyan
Write-Host "  Status: $($sig.Status)" -ForegroundColor $(if ($sig.Status -eq 'Valid') { 'Green' } else { 'Yellow' })

Write-Host ""
Write-Host "Fertig! Signiertes ZIP: $signedZip" -ForegroundColor Green
Write-Host "Naechster Schritt: git add . && git commit -m 'Release v$Version (signed)'" -ForegroundColor Cyan
