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

    The required dependency 'dbatools' is ensured automatically in the SAME scope
    before the import test (installed from the PSGallery if missing) - so a fresh
    server without dbatools installs cleanly and AllUsers installs get dbatools
    system-wide too.

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
    /XD .git tests bin Assets `
    /XF .gitignore README.md LICENSE `
          Install.cmd Install.ps1 Start-sqmToolGui.cmd Start-sqmToolGui.ps1 `
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
# 5b. dbatools-Abhaengigkeit im PASSENDEN Scope sicherstellen UND aktuell halten
#     sqmSQLTool.psd1 hat RequiredModules = @('dbatools') -> ohne dbatools
#     schlaegt der Import-Test (Schritt 6) fehl. Auf einem frischen Server ist
#     dbatools nicht vorhanden. Installation im GLEICHEN Scope wie sqmSQLTool,
#     sonst Scope-Mismatch: AllUsers-Modul wuerde ein nur in CurrentUser
#     liegendes dbatools in fremden/Admin-Sessions nicht finden.
#
#     "Vorhanden" allein reicht nicht: auf DWP1W02SQLT0001 stand seit 2022 dbatools
#     1.1.95 - ein bisher unbemerkter, mehrere Major-Versionen alter Stand, der
#     Get-DbaPbmPolicy in einer Rueckgabeform lieferte, die aeltere Annahmen im Modul
#     nicht abdeckten. Diese Pruefung war bisher rein binaer (Ordner da -> ok) und haette
#     das nie aufgedeckt. Jetzt wird zusaetzlich die auf PSGallery neueste verfuegbare
#     Version (innerhalb des MaximumVersion-Caps aus sqmSQLTool.psd1, also < dbatools 3.0)
#     ermittelt und bei Rueckstand ein Update angestossen - ist PSGallery nicht erreichbar
#     (typisch fuer eine abgeschottete Produktivinstanz), wird die erkannte installierte
#     Version wenigstens sichtbar geloggt, statt stillschweigend als "ok" durchzugehen.
#
#     FITS-Umgebung (Quelle unter W:\ bzw. \\tsclient\W\ - Citrix-Freigabelaufwerk, Erkennung wie
#     in Schritt 7 unten): PSGallery ist auf einer abgeschotteten Produktivinstanz typischerweise
#     NICHT erreichbar. Dort liegt bereits ein von FI-TS gepflegtes, fertiges Ordnerpaar
#     'dbatools' + 'dbatools.library' (das binaere Begleitmodul von dbatools 2.x) - Quelle der
#     Wahrheit ist in diesem Fall das Freigabelaufwerk, nicht PSGallery. Der Pfad dazu kommt
#     jetzt primaer aus der Konfiguration (sqmConfig-Key 'DbatoolsSharePath', siehe
#     Set-sqmConfig) statt implizit aus -Source abgeleitet zu werden - das Modul selbst ist an
#     dieser Stelle aber noch NICHT importiert (dbatools muss zuerst da sein, bevor
#     Import-Module wegen RequiredModules ueberhaupt klappt), daher wird config.json hier
#     direkt gelesen statt Get-sqmConfig aufzurufen. Ist der Key noch nicht gesetzt (erster
#     Install auf einer neuen Instanz), Fallback auf die bisherige Herleitung
#     (<SQLSources>\Modules, Geschwisterordner von Tools) - und das Ergebnis wird nach einem
#     erfolgreichen Modul-Import unten (Schritt 6a) in die Konfiguration zurueckgeschrieben,
#     damit kuenftige Installationen UND andere Modulfunktionen den Pfad direkt haben.
# ---------------------------------------------------------------------------
$isFitsInstall = ($Source -like 'W:\*') -or ($Source -like '\\tsclient\W\*')
$fitsModulesShare = $null
$dbatoolsSharePathFromConfig = $null
$sqmConfigFile = Join-Path $env:APPDATA 'MSSQLTools\config.json'
if (Test-Path $sqmConfigFile) {
    try {
        $dbatoolsSharePathFromConfig = (Get-Content $sqmConfigFile -Raw | ConvertFrom-Json).DbatoolsSharePath
    } catch { }
}
if ($isFitsInstall) {
    $candidateShare = if (-not [string]::IsNullOrWhiteSpace($dbatoolsSharePathFromConfig)) {
        $dbatoolsSharePathFromConfig
    } else {
        Join-Path (Split-Path (Split-Path $Source -Parent) -Parent) 'Modules'
    }
    if ((Test-Path (Join-Path $candidateShare 'dbatools') -PathType Container) -and
        (Test-Path (Join-Path $candidateShare 'dbatools.library') -PathType Container)) {
        $fitsModulesShare = $candidateShare
    } elseif (-not [string]::IsNullOrWhiteSpace($dbatoolsSharePathFromConfig)) {
        Write-Warning "  Konfigurierter DbatoolsSharePath '$dbatoolsSharePathFromConfig' enthaelt nicht beide erwarteten Ordner ('dbatools', 'dbatools.library') - wird ignoriert."
    }
}

$dbatoolsMaxVersion = ($PSD1 = Import-PowerShellDataFile (Join-Path $Source 'sqmSQLTool.psd1')).RequiredModules |
    Where-Object { $_.ModuleName -eq 'dbatools' } | Select-Object -ExpandProperty MaximumVersion -First 1
if (-not $dbatoolsMaxVersion) { $dbatoolsMaxVersion = '2.999.999' }

$auDbatools = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\dbatools'
$cuDbatools = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\dbatools'
$dbatoolsPathInScope = if ($Scope -eq 'AllUsers') {
    if (Test-Path $auDbatools) { $auDbatools } else { $null }         # AllUsers braucht dbatools systemweit
} else {
    if (Test-Path $cuDbatools) { $cuDbatools } elseif (Test-Path $auDbatools) { $auDbatools } else { $null }
}
$dbatoolsInScope = [bool]$dbatoolsPathInScope
$dbatoolsInstalledVersion = if ($dbatoolsInScope) {
    (Get-ChildItem -Path $dbatoolsPathInScope -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { try { [version]$_.Name } catch { $null } } |
        Sort-Object -Descending | Select-Object -First 1)
} else { $null }

Write-Host "Pruefe Abhaengigkeit 'dbatools' (Scope $Scope)..." -ForegroundColor Cyan
if ($fitsModulesShare) {
    Write-Host "  FITS-Umgebung erkannt (Quelle: $Source) - synchronisiere dbatools + dbatools.library von '$fitsModulesShare'..." -ForegroundColor Cyan
    $targetModulesRoot = if ($Scope -eq 'AllUsers') { Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules' }
    else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules' }
    $fitsSyncFailed = $false
    foreach ($modName in @('dbatools', 'dbatools.library')) {
        $srcMod = Join-Path $fitsModulesShare $modName
        $dstMod = Join-Path $targetModulesRoot $modName
        robocopy $srcMod $dstMod /MIR /NJH /NJS /NDL /COPY:DAT | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Warning "  robocopy fuer '$modName' meldete einen Fehler (Exitcode $LASTEXITCODE) - $srcMod -> $dstMod."
            $fitsSyncFailed = $true
        } else {
            Get-ChildItem -Path $dstMod -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
            }
        }
    }
    if (-not $fitsSyncFailed) {
        Write-Host "  dbatools + dbatools.library vom FI-TS-Freigabelaufwerk synchronisiert (-Scope $Scope)." -ForegroundColor Green
    } else {
        Write-Warning "  Synchronisation unvollstaendig - bitte den Zustand von '$targetModulesRoot' manuell pruefen."
    }
} elseif ($dbatoolsInScope) {
    Write-Host "  dbatools $dbatoolsInstalledVersion im passenden Scope vorhanden. Pruefe auf neuere Version..." -ForegroundColor Gray
    try {
        $latest = Find-Module dbatools -Repository PSGallery -MaximumVersion $dbatoolsMaxVersion -ErrorAction Stop |
            Sort-Object -Property { [version]$_.Version } -Descending | Select-Object -First 1
        if ($latest -and (-not $dbatoolsInstalledVersion -or [version]$latest.Version -gt $dbatoolsInstalledVersion)) {
            Write-Host "  Neuere Version verfuegbar: $($latest.Version) (installiert: $dbatoolsInstalledVersion) - aktualisiere..." -ForegroundColor Yellow
            Install-Module dbatools -Scope $Scope -RequiredVersion $latest.Version -Force -AllowClobber -ErrorAction Stop
            Write-Host "  dbatools auf $($latest.Version) aktualisiert (-Scope $Scope)." -ForegroundColor Green
        } else {
            Write-Host "  dbatools ist aktuell (innerhalb des Caps $dbatoolsMaxVersion)." -ForegroundColor Gray
        }
    } catch {
        Write-Warning "  Konnte PSGallery nicht nach einer neueren dbatools-Version abfragen (evtl. keine Internet-/PSGallery-Verbindung): $_"
        Write-Warning "  Installiert ist aktuell: dbatools $dbatoolsInstalledVersion. Bei Verdacht auf Versionsprobleme manuell pruefen/aktualisieren:"
        Write-Warning "    Update-Module dbatools -Force   (oder auf einer abgeschotteten Instanz: von einem Freigabelaufwerk/Offline-Repository sideloaden)"
    }
} else {
    Write-Host "  dbatools fehlt im Scope '$Scope' - installiere von der PSGallery..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope $Scope -Force -ErrorAction Stop | Out-Null } catch {}
        Install-Module dbatools -Scope $Scope -Force -AllowClobber -ErrorAction Stop
        Write-Host "  dbatools installiert (-Scope $Scope)." -ForegroundColor Green
    } catch {
        Write-Warning "  dbatools-Installation fehlgeschlagen: $_"
        Write-Warning "  Bitte manuell nachholen:  Install-Module dbatools -Scope $Scope -Force -AllowClobber"
    }
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
# 6a. Installationsquelle merken (fuer quellenbewusstes Auto-Update)
#     Install.ps1 installiert aus $Source -> Typ aus dem Pfad ableiten:
#     UNC-Pfad (\\...) -> 'UNC' (zusaetzlich UpdateRepository setzen), sonst 'LocalDir'.
#     (PSGallery-Installs laufen ueber Install-Module, nicht hier; die werden zur
#      Laufzeit automatisch erkannt.)
# ---------------------------------------------------------------------------
if ($importOk) {
    try {
        $srcType = if ($Source -like '\\*') { 'UNC' } else { 'LocalDir' }
        if ($srcType -eq 'UNC') {
            Set-sqmConfig -InstallSourceType $srcType -InstallSourcePath $Source -UpdateRepository $Source -ErrorAction Stop
        } else {
            Set-sqmConfig -InstallSourceType $srcType -InstallSourcePath $Source -ErrorAction Stop
        }
        Write-Host "Installationsquelle gemerkt: $srcType ($Source)" -ForegroundColor Gray
    } catch {
        Write-Warning "Installationsquelle konnte nicht gespeichert werden: $_"
    }

    # DbatoolsSharePath in die Konfiguration zurueckschreiben, wenn Schritt 5b eine FITS-
    # Freigabe gefunden hat, die dort noch nicht (oder mit einem anderen Pfad) hinterlegt war -
    # kuenftige Installationen lesen ihn dann direkt aus config.json statt ihn erneut aus
    # -Source herzuleiten, und andere Modulfunktionen koennen ihn ueber Get-sqmConfig nutzen.
    if ($fitsModulesShare -and $fitsModulesShare -ne $dbatoolsSharePathFromConfig) {
        try {
            Set-sqmConfig -DbatoolsSharePath $fitsModulesShare -ErrorAction Stop
            Write-Host "DbatoolsSharePath gemerkt: $fitsModulesShare" -ForegroundColor Gray
        } catch {
            Write-Warning "DbatoolsSharePath konnte nicht gespeichert werden: $_"
        }
    }
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
# 6c. GUI-Launcher + AllUsers-Startmenue-Verknuepfung
#     Nur bei AllUsers (Admin-Scope bereits durch Schritt 3 sichergestellt) und nur
#     wenn der Import-Test oben erfolgreich war - sonst wuerde die Verknuepfung auf ein
#     nicht lauffaehiges Modul zeigen. Start-sqmToolGui.cmd liegt bewusst NICHT im
#     Modul-Zielordner ($Destination): der wird bei jeder Neuinstallation per
#     robocopy /PURGE bereinigt (siehe Schritt 4, Start-sqmToolGui.cmd ist dort
#     explizit von /XF ausgenommen) und ist ohnehin tief unter WindowsPowerShell\Modules
#     verschachtelt. Ein eigener, stabiler Ordner unter Program Files ist das
#     naheliegende Ziel fuer einen Doppelklick-Start.
# ---------------------------------------------------------------------------
if ($importOk -and $Scope -eq 'AllUsers') {
    Write-Host "Richte GUI-Launcher ein..." -ForegroundColor Cyan
    try {
        $launcherDir  = Join-Path $env:ProgramFiles 'sqmSQLTool'
        $launcherPath = Join-Path $launcherDir 'Start-sqmToolGui.cmd'
        if (-not (Test-Path $launcherDir)) {
            New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $Source 'Start-sqmToolGui.cmd') -Destination $launcherPath -Force
        Unblock-File -Path $launcherPath -ErrorAction SilentlyContinue
        $launcherPs1Path = Join-Path $launcherDir 'Start-sqmToolGui.ps1'
        Copy-Item -Path (Join-Path $Source 'Start-sqmToolGui.ps1') -Destination $launcherPs1Path -Force
        Unblock-File -Path $launcherPs1Path -ErrorAction SilentlyContinue
        Write-Host "  Launcher kopiert nach: $launcherPath" -ForegroundColor Gray

        $iconSource = Join-Path $Source 'Assets\sqmSQLTool.ico'
        $iconPath   = Join-Path $launcherDir 'sqmSQLTool.ico'
        if (Test-Path $iconSource) {
            Copy-Item -Path $iconSource -Destination $iconPath -Force
            Unblock-File -Path $iconPath -ErrorAction SilentlyContinue
        }

        $startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        $shortcutPath = Join-Path $startMenuDir 'sqmSQLTool GUI.lnk'
        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $launcherPath
        $shortcut.WorkingDirectory = $launcherDir
        $shortcut.Description = 'sqmSQLTool GUI (elevated)'
        if (Test-Path $iconPath) { $shortcut.IconLocation = "$iconPath,0" }
        $shortcut.Save()
        Write-Host "  Startmenue-Verknuepfung (AllUsers) angelegt: $shortcutPath" -ForegroundColor Green

        # "An Start anheften" ist seit Windows 10 2004 / Windows 11 nicht mehr scriptbar - der
        # frueher gaengige Trick (FolderItem.InvokeVerb('pintostartscreen') ueber Shell.Application)
        # wurde von Microsoft fuer Desktop-Verknuepfungen entfernt und ist auf dieser OS-Version ein
        # stiller No-Op. Es gibt dafuer keine unterstuetzte Ersatz-API - deshalb hier bewusst KEIN
        # Automatisierungsversuch (der nur Erfolg vortaeuschen wuerde), sondern nur der Hinweis auf
        # den einmaligen manuellen Schritt.
        Write-Host "  Hinweis: Anheften an Start ist unter Windows 10/11 nicht automatisierbar -" -ForegroundColor Yellow
        Write-Host "           bitte einmalig manuell im Startmenue: Rechtsklick auf 'sqmSQLTool GUI' > 'An Start anheften'." -ForegroundColor Yellow
    } catch {
        Write-Warning "  GUI-Launcher/Startmenue-Verknuepfung konnte nicht eingerichtet werden: $_"
        Write-Warning "  Die GUI laesst sich trotzdem manuell starten: Import-Module sqmSQLTool; Show-sqmToolGui"
    }
}

# ---------------------------------------------------------------------------
# 7. FI-TS-Konfiguration automatisch setzen
#    Kriterium: Installation wurde von W:\ oder \\tsclient\W\ gestartet ($isFitsInstall,
#    bereits in Schritt 5b berechnet und dort auch fuer das dbatools-Sideloading genutzt).
#    Setzt alle FI-TS-Standardwerte via Set-sqmConfig (persistiert in config.json).
#    Laeuft nur wenn der Import erfolgreich war.
# ---------------------------------------------------------------------------
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
