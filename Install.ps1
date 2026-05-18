<#
.SYNOPSIS
    Installs the sqmSQLTool module into the PowerShell module path.

.DESCRIPTION
    Copies the module to either the system-wide module path (requires Admin)
    or the current user's personal module path (no Admin rights needed).

    The default is CurrentUser — no elevation required.

.PARAMETER Scope
    Installation scope:
      CurrentUser  — installs to $HOME\Documents\WindowsPowerShell\Modules  (default, no Admin needed)
      AllUsers     — installs to $env:ProgramFiles\WindowsPowerShell\Modules (requires Admin)

.PARAMETER Source
    Source directory of the module. Defaults to the script's own directory.

.PARAMETER Destination
    Explicit destination path. Overrides -Scope when specified.

.EXAMPLE
    .\Install.ps1
    Installs for the current user — no Admin rights required.

.EXAMPLE
    .\Install.cmd
    Recommended when running from a cross-domain share (handles execution policy).

.EXAMPLE
    .\Install.ps1 -Scope AllUsers
    Installs system-wide — requires Admin rights.

.NOTES
    Uses robocopy /COPY:DAT to avoid copying Zone.Identifier ADS from network shares.
    Runs Unblock-File on all destination files afterwards.
#>
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope       = 'CurrentUser',
    [string]$Source      = $PSScriptRoot,
    [string]$Destination = ''
)

# ---------------------------------------------------------------------------
# 1. Zielpfad bestimmen
# ---------------------------------------------------------------------------
if (-not $Destination) {
    if ($Scope -eq 'AllUsers') {
        $Destination = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmSQLTool"
    } else {
        $docsPath    = [Environment]::GetFolderPath('MyDocuments')
        $Destination = Join-Path $docsPath "WindowsPowerShell\Modules\sqmSQLTool"
    }
}

# ---------------------------------------------------------------------------
# 2. Admin-Check nur bei AllUsers
# ---------------------------------------------------------------------------
if ($Scope -eq 'AllUsers') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]'Administrator')
    if (-not $isAdmin) {
        Write-Warning "Scope 'AllUsers' requires Administrator rights."
        Write-Warning "Run Install.cmd as Administrator, or use:  .\Install.ps1  (installs for current user only)"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 3. Modul kopieren
#    /COPY:DAT  -> no Alternate Data Streams (no Zone.Identifier)
#    /XD .git   -> exclude git directory
#    /XF        -> exclude meta files
# ---------------------------------------------------------------------------
Write-Host "Installing sqmSQLTool to: $Destination" -ForegroundColor Cyan
robocopy $Source $Destination /E /PURGE /NJH /NJS /NDL /COPY:DAT `
    /XD .git tests bin `
    /XF .gitignore README.md LICENSE `
          Install.cmd Update.cmd Install.ps1 Update.ps1 `
          "*.TempPoint.*" "*.RestorePoint.*" "*.psproj" "*.psproj.psbuild" "*.psprojs" `
          "desktop.ini" "Tester.ps1" "Test-Module*.ps1" `
          "coverage.xml" "testresults.xml"

# ---------------------------------------------------------------------------
# 4. Zone.Identifier auf dem Ziel entfernen
# ---------------------------------------------------------------------------
Write-Host "Unblocking files..." -ForegroundColor Cyan
Get-ChildItem -Path $Destination -Recurse -File | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5. Import testen
# ---------------------------------------------------------------------------
Write-Host "Testing module import..." -ForegroundColor Cyan
try {
    Import-Module sqmSQLTool -Force -ErrorAction Stop
    $version = (Get-Module sqmSQLTool).Version
    Write-Host "sqmSQLTool v$version successfully loaded." -ForegroundColor Green
    Write-Host "Scope: $Scope  |  Path: $Destination" -ForegroundColor Gray
} catch {
    Write-Warning "Import failed: $_"
}
