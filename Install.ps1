<#
.SYNOPSIS
    Installs the sqmSQLTool module into the PowerShell module path.

.DESCRIPTION
    Copies the module to either the system-wide module path (requires Admin)
    or the current user's personal module path (no Admin rights needed).

    The default scope is determined automatically:
      - Running as Administrator  -> AllUsers  ($env:ProgramFiles\WindowsPowerShell\Modules)
      - Running as normal user    -> CurrentUser ($HOME\Documents\WindowsPowerShell\Modules)
    Pass -Scope explicitly to override this behaviour.

.PARAMETER Scope
    Installation scope:
      CurrentUser  — installs to $HOME\Documents\WindowsPowerShell\Modules
      AllUsers     — installs to $env:ProgramFiles\WindowsPowerShell\Modules (requires Admin)
    Default: AllUsers when running as Administrator, CurrentUser otherwise.

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
    Uses robocopy /COPY:DAT to copy the module data. Note: /COPY:DAT does NOT strip
    the Zone.Identifier ADS (Mark-of-the-Web) - the subsequent Unblock-File pass on all
    destination files is what removes it.
#>
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope       = '',          # auto-detected below
    [string]$Source      = $PSScriptRoot,
    [string]$Destination = ''
)

# ---------------------------------------------------------------------------
# 0. Scope auto-detect: Admin -> AllUsers, sonst CurrentUser
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
             [Security.Principal.WindowsBuiltInRole]'Administrator')

if ($Scope -eq '') {
    $Scope = if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }
    Write-Host "Auto-detected Scope: $Scope" -ForegroundColor Cyan
}

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
# 2. Doppel-Installation erkennen und warnen
# ---------------------------------------------------------------------------
$docsPath_     = [Environment]::GetFolderPath('MyDocuments')
$pathUser      = Join-Path $docsPath_ "WindowsPowerShell\Modules\sqmSQLTool"
$pathAllUsers  = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmSQLTool"
$existsUser    = Test-Path $pathUser
$existsAll     = Test-Path $pathAllUsers

if ($existsUser -and $existsAll -and $Scope -eq 'AllUsers') {
    # Running as Admin installing AllUsers — remove the CurrentUser copy automatically
    Write-Host "Both installations detected. Removing CurrentUser copy..." -ForegroundColor Yellow
    Write-Host "  $pathUser" -ForegroundColor Gray
    Remove-Item $pathUser -Recurse -Force
    Write-Host "CurrentUser installation removed." -ForegroundColor Green
    Write-Host ""
    $existsUser = $false

} elseif ($existsUser -and $existsAll) {
    # CurrentUser install, both exist — warn, cannot auto-remove AllUsers without Admin
    Write-Warning "sqmSQLTool is installed in BOTH locations:"
    Write-Warning "  CurrentUser : $pathUser"
    Write-Warning "  AllUsers    : $pathAllUsers"
    Write-Warning "PowerShell loads the CurrentUser version — the AllUsers copy is ignored."
    Write-Warning "To remove the AllUsers copy (requires Admin):"
    Write-Warning "  Remove-Item '$pathAllUsers' -Recurse -Force"
    Write-Host ""

} elseif ($Scope -eq 'CurrentUser' -and $existsAll) {
    Write-Warning "An AllUsers installation already exists at: $pathAllUsers"
    Write-Warning "After this install, PowerShell will load the CurrentUser version and ignore AllUsers."
    Write-Host ""

} elseif ($Scope -eq 'AllUsers' -and $existsUser) {
    # Running as Admin — remove the CurrentUser copy automatically
    Write-Host "CurrentUser installation detected. Removing to avoid conflicts..." -ForegroundColor Yellow
    Write-Host "  $pathUser" -ForegroundColor Gray
    Remove-Item $pathUser -Recurse -Force
    Write-Host "CurrentUser installation removed." -ForegroundColor Green
    Write-Host ""
    $existsUser = $false
}

# ---------------------------------------------------------------------------
# 3. Scope-Hinweis und Admin-Check
# ---------------------------------------------------------------------------
if ($Scope -eq 'AllUsers') {
    if (-not $isAdmin) {
        Write-Warning "Scope 'AllUsers' requires Administrator rights."
        Write-Warning "Run Install.cmd as Administrator, or use:  .\Install.ps1  (installs for current user only)"
        exit 1
    }
} else {
    # CurrentUser — Hinweis auf systemweite Installation
    Write-Host ""
    if ($isAdmin) {
        Write-Host "INFO: You are running as Administrator." -ForegroundColor Cyan
        Write-Host "      Installing for the current user only ($env:USERNAME)." -ForegroundColor Cyan
        Write-Host "      To install system-wide for ALL users, run:" -ForegroundColor Cyan
        Write-Host "        Install.cmd AllUsers" -ForegroundColor White
    } else {
        Write-Host "INFO: Installing for the current user only ($env:USERNAME)." -ForegroundColor Cyan
        Write-Host "      To install system-wide for ALL users, re-run as Administrator:" -ForegroundColor Cyan
        Write-Host "        Right-click Install.cmd > 'Run as administrator'" -ForegroundColor White
        Write-Host "        or: Install.cmd AllUsers  (in an elevated PowerShell)" -ForegroundColor White
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 4. Modul kopieren
#    /COPY:DAT  -> Data, Attributes, Timestamps (KEIN Zone.Identifier-Strip!
#                  das erledigt der Unblock-File-Schritt 5)
#    /XD .git   -> exclude git directory
#    /XF        -> exclude meta files
# ---------------------------------------------------------------------------
Write-Host "Installing sqmSQLTool to: $Destination" -ForegroundColor Cyan
robocopy $Source $Destination /E /PURGE /NJH /NJS /NDL /COPY:DAT `
    /XD .git tests bin `
    /XF .gitignore README.md LICENSE `
          Install.cmd Install.ps1 `
          "*.TempPoint.*" "*.RestorePoint.*" "*.psproj" "*.psproj.psbuild" "*.psprojs" `
          "desktop.ini" "Tester.ps1" "Test-Module*.ps1" `
          "coverage.xml" "testresults.xml"

# ---------------------------------------------------------------------------
# 5. Zone.Identifier auf dem Ziel entfernen
# ---------------------------------------------------------------------------
Write-Host "Unblocking files..." -ForegroundColor Cyan
Get-ChildItem -Path $Destination -Recurse -File | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 6. Import testen
# ---------------------------------------------------------------------------
Write-Host "Testing module import..." -ForegroundColor Cyan
$importOk = $false
try {
    # Expliziter Pfad zur .psd1 verhindert dass eine alte Version aus PSModulePath geladen wird
    $psd1Path = Join-Path $Destination "sqmSQLTool.psd1"
    Import-Module $psd1Path -Force -WarningAction SilentlyContinue -ErrorAction Stop
    $version = (Get-Module sqmSQLTool).Version
    Write-Host "sqmSQLTool v$version successfully loaded." -ForegroundColor Green
    Write-Host "Scope: $Scope  |  Path: $Destination" -ForegroundColor Gray
    $importOk = $true
} catch {
    Write-Warning "Import failed: $_"
}

# ---------------------------------------------------------------------------
# 6b. Windows Event Log Source registrieren (fuer Splunk-Integration)
#     Die Agent-Jobs (Sync/Compare) schreiben bei Fehler/Drift in das Application
#     Log unter der Source 'sqmSQLTool'. Das Anlegen der Source erfordert Adminrechte
#     und ist nur einmalig noetig. Schlaegt es fehl (CurrentUser-Install ohne Admin),
#     wird es ignoriert - die Jobs registrieren die Source sonst beim ersten Lauf.
# ---------------------------------------------------------------------------
Write-Host "Registriere Event Log Source 'sqmSQLTool'..." -ForegroundColor Cyan
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists('sqmSQLTool')) {
        New-EventLog -LogName Application -Source 'sqmSQLTool' -ErrorAction Stop
        Write-Host "  Event Log Source 'sqmSQLTool' registriert." -ForegroundColor Green
    } else {
        Write-Host "  Event Log Source 'sqmSQLTool' bereits vorhanden." -ForegroundColor Gray
    }
} catch {
    Write-Host "  Hinweis: Event Log Source konnte nicht registriert werden (keine Adminrechte?) - wird beim ersten Job-Lauf nachgeholt." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 7. FI-TS-Konfiguration automatisch setzen
#    Kriterium: Installation wurde von W:\ oder \\tsclient\W\ gestartet.
#    Setzt alle FI-TS-Standardwerte via Set-sqmConfig (persistiert in config.json).
#    Laeuft nur wenn der Import erfolgreich war.
# ---------------------------------------------------------------------------
$isFitsInstall = ($Source -like 'W:\*') -or ($Source -like '\\tsclient\W\*')
if ($importOk -and $isFitsInstall) {
    Write-Host ""
    Write-Host "FI-TS-Umgebung erkannt (Quelle: $Source)" -ForegroundColor Cyan
    Write-Host "Setze FI-TS-Standardkonfiguration..." -ForegroundColor Cyan
    try {
        Set-sqmConfig `
            -OutputPath            'C:\System\WinSrvLog\MSSQL' `
            -OlaJobNameFull        'FITS-UserDatabases-FULL' `
            -OlaJobNameDiff        'FITS-UserDatabases-DIFF' `
            -OlaJobNameLog         'FITS-UserDatabases-LOG' `
            -OlaJobNameIndexOpt    'FITS IndexOptimize - USER_DATABASES' `
            -OlaJobNameIntUserDb   'FITS IntegrityCheck - USER_DATABASES' `
            -OlaJobNameIntSysDb    'FITS IntegrityCheck - SYSTEM_DATABASES' `
            -OlaJobNameSysDbBackup 'FITS-SystemDatabases-FULL' `
            -DefaultPolicy         'New Login_Enforce Passwort Policy' `
            -CheckProfile          'FiTs' `
            -ErrorAction Stop
        Write-Host "FI-TS-Konfiguration erfolgreich gesetzt." -ForegroundColor Green
        Write-Host "  OutputPath   : C:\System\WinSrvLog\MSSQL" -ForegroundColor Gray
        Write-Host "  OlaJobs      : FITS-*" -ForegroundColor Gray
        Write-Host "  DefaultPolicy: New Login_Enforce Passwort Policy" -ForegroundColor Gray
    } catch {
        Write-Warning "FI-TS-Konfiguration konnte nicht gesetzt werden: $_"
        Write-Warning "Manuell nachholen mit: Set-sqmConfig -DefaultPolicy 'New Login_Enforce Passwort Policy' ..."
    }
} elseif ($importOk -and -not $isFitsInstall) {
    Write-Host ""
    Write-Host "Hinweis: Keine FI-TS-Umgebung erkannt." -ForegroundColor Yellow
    Write-Host "  Job-Namen und Policy manuell setzen: Set-sqmConfig -OlaJobNameFull '...' -DefaultPolicy '...'" -ForegroundColor Gray
}
