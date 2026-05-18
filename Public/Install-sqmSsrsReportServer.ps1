<#
.SYNOPSIS
    Installiert SQL Server Reporting Services 2022 von einem Network Share
    und konfiguriert die Instanz anschliessend vollautomatisch.

.DESCRIPTION
    Fuehrt folgende Schritte der Reihe nach aus:

    [1] Voraussetzungen pruefen
        - Administratorrechte auf dem Zielrechner
        - Installer (.exe oder .msi) im konfigurierten Share (SsrsInstallerPath) auffindbar
        - SSRS noch nicht installiert (ueberspringbar mit -Force)

    [2] Installation
        - Kopiert den Installer in ein lokales Temp-Verzeichnis (UNC-Pfade werden
          nicht direkt als Prozess-Start unterstuetzt)
        - Fuehrt den Installer silent aus:
            SQLServerReportingServices.exe
                /quiet /IAcceptLicenseTerms /Edition=<Edition> /IAcceptLicenseTerms
        - Wertet den Exit Code aus (0 = OK, 3010 = Neustart empfohlen)
        - Wartet danach bis zu 60 Sekunden auf den SSRS-WMI-Namespace (Dienst-Startup)

    [3] Konfiguration
        - Ruft Set-sqmSsrsConfiguration mit allen uebergebenen Konfigurations-
          Parametern auf (Splatting). Nicht uebergebene Parameter verwenden die
          Standardwerte von Set-sqmSsrsConfiguration.

    Der Installer-Pfad wird bevorzugt aus dem Parameter -InstallerPath gelesen.
    Fehlt der Parameter, wird Get-sqmConfig -Key 'SsrsInstallerPath' verwendet.
    Ist auch dieser nicht gesetzt, wird ein Fehler ausgeloest.

.PARAMETER ComputerName
    Zielrechner. Standard: $env:COMPUTERNAME (Lokal).
    Remote-Installation via WinRM / PsRemoting wird unterstuetzt.

.PARAMETER InstallerPath
    Vollstaendiger UNC- oder lokaler Pfad zur Installationsdatei
    (SQLServerReportingServices.exe oder .msi).
    ueberschreibt Get-sqmConfig -Key 'SsrsInstallerPath'.

.PARAMETER Edition
    Lizenz-Edition fuer den Silent-Parameter /Edition.
    Gueltige Werte: Eval, Developer, Expr, Web, Standard, Enterprise.
    Standard: 'Developer'.

.PARAMETER ProductKey
    Produktschluessel (25 Zeichen). Wenn angegeben, wird statt -Edition der
    Parameter /IAcceptLicenseTerms /PID:<Key> verwendet.

.PARAMETER Force
    Installation auch dann durchfuehren, wenn SSRS bereits installiert ist.

.PARAMETER SkipConfiguration
    Nur installieren, Set-sqmSsrsConfiguration nicht aufrufen.

.PARAMETER InstanceName
    SSRS-Instanzname. Wird an Set-sqmSsrsConfiguration weitergereicht.
    Standard: 'MSSQLSERVER'.

.PARAMETER DatabaseServer
    SQL Server fuer die ReportServer-Datenbank.
    Wird an Set-sqmSsrsConfiguration weitergereicht.

.PARAMETER DatabaseName
    Name der ReportServer-Datenbank. Standard: 'ReportServer'.

.PARAMETER ReportServerUrl
    URL fuer den ReportServer Web Service.
    Standard: 'http://+:80/ReportServer'.

.PARAMETER ReportsUrl
    URL fuer das Reports-Portal. Standard: 'http://+:80/Reports'.

.PARAMETER ServiceAccount
    Windows-Dienstkonto fuer SSRS.

.PARAMETER ServiceAccountPassword
    Kennwort fuer -ServiceAccount (SecureString).

.PARAMETER DatabaseAuthType
    Authentifizierung fuer die DB-Verbindung: 'Windows' oder 'SQL'.

.PARAMETER DatabaseCredential
    PSCredential fuer SQL-Authentifizierung (nur bei -DatabaseAuthType SQL).

.PARAMETER EncryptionKeyFile
    Pfad fuer das Encryption Key Backup (.snk).

.PARAMETER EncryptionKeyPassword
    Kennwort fuer das Key Backup (SecureString).

.PARAMETER SkipDatabase
    Datenbankkonfiguration in Set-sqmSsrsConfiguration ueberspringen.

.PARAMETER SkipUrls
    URL-Konfiguration in Set-sqmSsrsConfiguration ueberspringen.

.PARAMETER SkipServiceAccount
    Dienstkonto-Konfiguration in Set-sqmSsrsConfiguration ueberspringen.

.PARAMETER SkipEncryptionKeyBackup
    Key-Backup in Set-sqmSsrsConfiguration ueberspringen.

.PARAMETER Credential
    PSCredential fuer die WinRM-Verbindung zum Zielrechner (Remote-Betrieb).

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer den Konfigurationsbericht.

.PARAMETER WmiWaitSeconds
    Maximale Wartezeit in Sekunden auf den SSRS-WMI-Namespace nach der
    Installation. Standard: 60.

.PARAMETER ContinueOnError
    Konfigurationsfehler nicht als Abbruch werten.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.OUTPUTS
    [PSCustomObject] mit den Feldern:
        ComputerName, InstallerUsed, Edition, InstallExitCode,
        RebootRequired, InstallResult, ConfigResult, OverallStatus, Message

.EXAMPLE
    Install-sqmSsrsReportServer

    Installiert SSRS mit dem in sqmConfig hinterlegten Installer-Pfad,
    Edition Developer, anschliessend Vollkonfiguration mit Standardwerten.

.EXAMPLE
    Install-sqmSsrsReportServer `
        -InstallerPath '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe' `
        -Edition Standard `
        -DatabaseServer 'SQL-AG-Listener' `
        -ServiceAccount 'DOMAIN\svc_ssrs' `
        -EncryptionKeyPassword (Read-Host -AsSecureString 'Key-Passwort')

.EXAMPLE
    Install-sqmSsrsReportServer -SkipConfiguration -WhatIf

    Zeigt, was installiert wuerde, ohne aenderungen vorzunehmen.

.NOTES
    Voraussetzungen : Invoke-sqmLogging, Set-sqmSsrsConfiguration, lokale Adminrechte
    Unterstuetzte Versionen: SSRS 2022 (SQLServerReportingServices.exe)
    Exit Codes      : 0 = Erfolg, 3010 = Neustart empfohlen, sonstige = Fehler
    WMI-Namespace   : root\Microsoft\SqlServer\ReportServer
#>
function Install-sqmSsrsReportServer
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param (
        # ?? Zielrechner ????????????????????????????????????????????????????
        [Parameter(Mandatory = $false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        # ?? Installer-Quelle ???????????????????????????????????????????????
        [Parameter(Mandatory = $false)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Eval', 'Developer', 'Expr', 'Web', 'Standard', 'Enterprise')]
        [string]$Edition = 'Developer',

        [Parameter(Mandatory = $false)]
        [string]$ProductKey,

        # ?? Installations-Steuerung ????????????????????????????????????????
        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$SkipConfiguration,

        [Parameter(Mandatory = $false)]
        [int]$WmiWaitSeconds = 60,

        # ?? Konfigurations-Parameter (Durchreich an Set-sqmSsrsConfiguration) ??
        [Parameter(Mandatory = $false)]
        [string]$InstanceName = 'MSSQLSERVER',

        [Parameter(Mandatory = $false)]
        [string]$DatabaseServer,

        [Parameter(Mandatory = $false)]
        [string]$DatabaseName = 'ReportServer',

        [Parameter(Mandatory = $false)]
        [string]$ReportServerUrl = 'http://+:80/ReportServer',

        [Parameter(Mandatory = $false)]
        [string]$ReportsUrl = 'http://+:80/Reports',

        [Parameter(Mandatory = $false)]
        [string]$ServiceAccount,

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$ServiceAccountPassword,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Windows', 'SQL')]
        [string]$DatabaseAuthType = 'Windows',

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$DatabaseCredential,

        [Parameter(Mandatory = $false)]
        [string]$EncryptionKeyFile,

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$EncryptionKeyPassword,

        [Parameter(Mandatory = $false)]
        [switch]$SkipDatabase,

        [Parameter(Mandatory = $false)]
        [switch]$SkipUrls,

        [Parameter(Mandatory = $false)]
        [switch]$SkipServiceAccount,

        [Parameter(Mandatory = $false)]
        [switch]$SkipEncryptionKeyBackup,

        # ?? Verbindung / Ausgabe ???????????????????????????????????????????
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = (Get-sqmConfig -Key 'OutputPath'),

        # ?? Fehlerbehandlung ???????????????????????????????????????????????
        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnError,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $isLocal      = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')

        # ?? Rueckgabe-Objekt vorab befuellen ?????????????????????????????????
        $result = [PSCustomObject]@{
            ComputerName     = $ComputerName
            InstallerUsed    = $null
            Edition          = $Edition
            InstallExitCode  = $null
            RebootRequired   = $false
            InstallResult    = 'NotStarted'
            ConfigResult     = 'Skipped'
            OverallStatus    = 'Unknown'
            Message          = $null
        }

        # ?? Hilfsfunktion: einheitliches Fehlerhandling ???????????????????
        function _Fail ([string]$msg)
        {
            Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
            $result.OverallStatus = 'Failed'
            $result.Message       = $msg
            if ($EnableException) { throw $msg }
            Write-Error $msg
            return $result
        }

        Invoke-sqmLogging -Message "Starte $functionName auf '$ComputerName'" `
                          -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        # ??????????????????????????????????????????????????????????????????
        # [1] Installer-Pfad aufloesen
        # ??????????????????????????????????????????????????????????????????
        $effectiveInstaller = $InstallerPath
        if (-not $effectiveInstaller)
        {
            $effectiveInstaller = Get-sqmConfig -Key 'SsrsInstallerPath'
        }

        if ([string]::IsNullOrWhiteSpace($effectiveInstaller))
        {
            return (_Fail ("Kein Installer-Pfad angegeben und 'SsrsInstallerPath' ist nicht in der " +
                           "Modulkonfiguration gesetzt. Bitte -InstallerPath angeben oder " +
                           "Set-sqmConfig -SsrsInstallerPath '<UNC-Pfad>' ausfuehren."))
        }

        $installerExtension = [System.IO.Path]::GetExtension($effectiveInstaller).ToLower()
        if ($installerExtension -notin @('.exe', '.msi'))
        {
            return (_Fail "Installer-Datei '$effectiveInstaller' hat keine unterstuetzte Erweiterung (.exe / .msi).")
        }

        if (-not (Test-Path -LiteralPath $effectiveInstaller))
        {
            return (_Fail "Installer-Datei nicht erreichbar: '$effectiveInstaller'")
        }

        $result.InstallerUsed = $effectiveInstaller
        Invoke-sqmLogging -Message "Installer: '$effectiveInstaller'" `
                          -FunctionName $functionName -Level 'INFO'

        # ??????????????????????????????????????????????????????????????????
        # [2] Voraussetzungen pruefen
        # ??????????????????????????????????????????????????????????????????

        # 2a. Administratorrechte (nur bei lokaler Ausfuehrung direkt pruefbar)
        if ($isLocal)
        {
            $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
            {
                return (_Fail "Keine lokalen Administratorrechte - Installation nicht moeglich. PowerShell als Administrator starten.")
            }
        }

        # 2b. Ist SSRS bereits installiert?
        $ssrsAlreadyInstalled = $false
        try
        {
            $cimParams = @{ Namespace = 'root\Microsoft\SqlServer\ReportServer'; ErrorAction = 'Stop' }
            if (-not $isLocal)
            {
                $sessionOpts         = New-CimSessionOption -Protocol Wsman
                $cimConnParams       = @{ ComputerName = $ComputerName; SessionOption = $sessionOpts }
                if ($Credential) { $cimConnParams['Credential'] = $Credential }
                $checkSession        = New-CimSession @cimConnParams -ErrorAction Stop
                $cimParams['CimSession'] = $checkSession
            }
            $nsCheck = Get-CimInstance @cimParams -ClassName '__NAMESPACE' -ErrorAction SilentlyContinue
            $ssrsAlreadyInstalled = $null -ne $nsCheck
            if (isset $checkSession) { Remove-CimSession $checkSession -ErrorAction SilentlyContinue }
        }
        catch
        {
            # Namespace nicht vorhanden = SSRS nicht installiert, das ist der Normalfall
            $ssrsAlreadyInstalled = $false
        }

        if ($ssrsAlreadyInstalled -and -not $Force)
        {
            $msg = "SSRS ist auf '$ComputerName' bereits installiert. " +
                   "Verwenden Sie -Force um die Installation trotzdem durchzufuehren."
            Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
            Write-Warning $msg
            $result.InstallResult = 'AlreadyInstalled'
            $result.OverallStatus = 'AlreadyInstalled'
            $result.Message       = $msg

            # Wenn SSRS schon da und SkipConfiguration nicht gesetzt:
            # direkt zur Konfiguration springen
            if (-not $SkipConfiguration)
            {
                Invoke-sqmLogging -Message "ueberspringe Installation - fahre direkt mit Konfiguration fort." `
                                  -FunctionName $functionName -Level 'INFO'
                # Goto Konfigurations-Block (ueber $skipInstall-Flag)
            }
            else
            {
                return $result
            }
        }

        # ??????????????????????????????????????????????????????????????????
        # [3] Installation
        # ??????????????????????????????????????????????????????????????????
        $skipInstall = ($ssrsAlreadyInstalled -and -not $Force)

        if (-not $skipInstall)
        {
            if ($PSCmdlet.ShouldProcess($ComputerName, "SSRS 2022 installieren von '$effectiveInstaller'"))
            {
                try
                {
                    # Installer in lokales Temp kopieren
                    # (UNC-Pfade koennen nicht direkt als Prozess gestartet werden)
                    $tempDir       = Join-Path $env:TEMP "SsrsInstall_$(Get-Random)"
                    $tempInstaller = Join-Path $tempDir ([System.IO.Path]::GetFileName($effectiveInstaller))
                    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

                    Invoke-sqmLogging -Message "Kopiere Installer nach '$tempInstaller'..." `
                                      -FunctionName $functionName -Level 'INFO'
                    Write-Host "  [1/2] Installer kopieren von Share..." -ForegroundColor Gray
                    Copy-Item -LiteralPath $effectiveInstaller -Destination $tempInstaller -Force -ErrorAction Stop

                    # Silent-Parameter zusammenstellen
                    # SSRS 2022 EXE: /quiet /IAcceptLicenseTerms /Edition=<X>
                    # SSRS 2022 MSI: /quiet /norestart IACCEPTLICENSETERMS=YES
                    $isMsi = $installerExtension -eq '.msi'

                    if ($isMsi)
                    {
                        $installArgs = @(
                            '/i', "`"$tempInstaller`"",
                            '/quiet',
                            '/norestart',
                            'IACCEPTLICENSETERMS=YES'
                        )
                        if ($ProductKey)
                        {
                            $installArgs += "PIDKEY=$ProductKey"
                        }
                        else
                        {
                            $installArgs += "EDITION=$Edition"
                        }
                        $installExe = 'msiexec.exe'
                    }
                    else
                    {
                        $installArgs = @(
                            '/quiet',
                            '/IAcceptLicenseTerms',
                            '/norestart'
                        )
                        if ($ProductKey)
                        {
                            $installArgs += "/PID=$ProductKey"
                        }
                        else
                        {
                            $installArgs += "/Edition=$Edition"
                        }
                        $installExe = $tempInstaller
                    }

                    $argString = $installArgs -join ' '
                    Invoke-sqmLogging -Message "Starte Installation: $installExe $argString" `
                                      -FunctionName $functionName -Level 'INFO'
                    Write-Host "  [2/2] SSRS installieren (silent)..." -ForegroundColor Gray

                    $proc = Start-Process -FilePath $installExe `
                                         -ArgumentList $installArgs `
                                         -Wait -PassThru -NoNewWindow `
                                         -ErrorAction Stop

                    $result.InstallExitCode = $proc.ExitCode

                    switch ($proc.ExitCode)
                    {
                        0
                        {
                            $result.InstallResult  = 'OK'
                            $result.RebootRequired = $false
                            Write-Host "  ? SSRS installiert (ExitCode 0)." -ForegroundColor Green
                            Invoke-sqmLogging -Message "Installation erfolgreich (ExitCode 0)." `
                                              -FunctionName $functionName -Level 'INFO'
                        }
                        3010
                        {
                            $result.InstallResult  = 'OK'
                            $result.RebootRequired = $true
                            Write-Host "  ? SSRS installiert (ExitCode 3010 - Neustart empfohlen)." -ForegroundColor Yellow
                            Write-Warning "SSRS wurde installiert, ein Neustart wird empfohlen."
                            Invoke-sqmLogging -Message "Installation erfolgreich, Neustart empfohlen (ExitCode 3010)." `
                                              -FunctionName $functionName -Level 'WARNING'
                        }
                        default
                        {
                            throw "Installer beendet mit ExitCode $($proc.ExitCode). Installation fehlgeschlagen."
                        }
                    }
                }
                catch
                {
                    $errMsg = "Installations-Fehler: $($_.Exception.Message)"
                    Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
                    $result.InstallResult = 'Failed'
                    $result.OverallStatus = 'Failed'
                    $result.Message       = $errMsg
                    if ($EnableException) { throw }
                    Write-Error $errMsg
                    return $result
                }
                finally
                {
                    if (Test-Path $tempDir)
                    {
                        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }

                # ?? WMI-Namespace abwarten ????????????????????????????????
                # SSRS-Dienst braucht nach dem Installer-Start einige Sekunden
                # bis der WMI-Provider registriert ist.
                Invoke-sqmLogging -Message "Warte auf SSRS-WMI-Namespace (max. $WmiWaitSeconds s)..." `
                                  -FunctionName $functionName -Level 'INFO'
                Write-Host "  Warte auf SSRS-WMI-Namespace..." -ForegroundColor Gray

                $wmiReady    = $false
                $waitStart   = [datetime]::UtcNow
                $wmiNs       = 'root\Microsoft\SqlServer\ReportServer'
                $wmiPollBase = @{ Namespace = $wmiNs; ClassName = '__NAMESPACE'; ErrorAction = 'SilentlyContinue' }
                if (-not $isLocal -and $checkSession)
                {
                    $wmiPollBase['CimSession'] = $checkSession
                }

                while (-not $wmiReady -and ([datetime]::UtcNow - $waitStart).TotalSeconds -lt $WmiWaitSeconds)
                {
                    Start-Sleep -Seconds 3
                    try
                    {
                        $ns      = Get-CimInstance @wmiPollBase
                        $wmiReady = $null -ne $ns
                    }
                    catch { $wmiReady = $false }
                }

                if (-not $wmiReady)
                {
                    $warnMsg = "SSRS-WMI-Namespace nach $WmiWaitSeconds s noch nicht vorhanden. " +
                               "Konfiguration wird trotzdem versucht."
                    Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level 'WARNING'
                    Write-Warning $warnMsg
                }
                else
                {
                    Invoke-sqmLogging -Message "SSRS-WMI-Namespace verfuegbar nach $([int]([datetime]::UtcNow - $waitStart).TotalSeconds) s." `
                                      -FunctionName $functionName -Level 'INFO'
                    Write-Host "  ? SSRS-WMI-Namespace bereit." -ForegroundColor Green
                }
            }
            else
            {
                # WhatIf-Pfad
                $result.InstallResult = 'WhatIf'
                Invoke-sqmLogging -Message "WhatIf: Installation wuerde gestartet werden." `
                                  -FunctionName $functionName -Level 'INFO'
            }
        }

        # ??????????????????????????????????????????????????????????????????
        # [4] Konfiguration via Set-sqmSsrsConfiguration
        # ??????????????????????????????????????????????????????????????????
        if ($SkipConfiguration)
        {
            $result.ConfigResult  = 'Skipped'
            $result.OverallStatus = $result.InstallResult
            $result.Message       = "Installation: $($result.InstallResult) | Konfiguration: uebersprungen (-SkipConfiguration)."
            Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level 'INFO'
            return $result
        }

        if ($result.InstallResult -eq 'WhatIf')
        {
            $result.ConfigResult  = 'WhatIf'
            $result.OverallStatus = 'WhatIf'
            $result.Message       = 'WhatIf: Installation und Konfiguration wuerden durchgefuehrt.'
            return $result
        }

        Write-Host ""
        Write-Host "[$ComputerName] Starte SSRS-Konfiguration..." -ForegroundColor Cyan
        Invoke-sqmLogging -Message "Starte Set-sqmSsrsConfiguration auf '$ComputerName'." `
                          -FunctionName $functionName -Level 'INFO'

        # Nur explizit uebergebene Parameter weiterreichen (kein ueberschreiben der
        # Standardwerte in Set-sqmSsrsConfiguration durch leere Werte)
        $configSplat = @{
            ComputerName   = $ComputerName
            InstanceName   = $InstanceName
            DatabaseName   = $DatabaseName
            ReportServerUrl = $ReportServerUrl
            ReportsUrl     = $ReportsUrl
            DatabaseAuthType = $DatabaseAuthType
        }

        if ($PSBoundParameters.ContainsKey('DatabaseServer')          -and $DatabaseServer)          { $configSplat['DatabaseServer']          = $DatabaseServer }
        if ($PSBoundParameters.ContainsKey('ServiceAccount')          -and $ServiceAccount)          { $configSplat['ServiceAccount']          = $ServiceAccount }
        if ($PSBoundParameters.ContainsKey('ServiceAccountPassword')  -and $ServiceAccountPassword)  { $configSplat['ServiceAccountPassword']  = $ServiceAccountPassword }
        if ($PSBoundParameters.ContainsKey('DatabaseCredential')      -and $DatabaseCredential)      { $configSplat['DatabaseCredential']      = $DatabaseCredential }
        if ($PSBoundParameters.ContainsKey('EncryptionKeyFile')       -and $EncryptionKeyFile)       { $configSplat['EncryptionKeyFile']       = $EncryptionKeyFile }
        if ($PSBoundParameters.ContainsKey('EncryptionKeyPassword')   -and $EncryptionKeyPassword)   { $configSplat['EncryptionKeyPassword']   = $EncryptionKeyPassword }
        if ($PSBoundParameters.ContainsKey('Credential')              -and $Credential)              { $configSplat['Credential']              = $Credential }
        if ($PSBoundParameters.ContainsKey('OutputPath')              -and $OutputPath)              { $configSplat['OutputPath']              = $OutputPath }

        # Skip-Schalter
        if ($SkipDatabase)            { $configSplat['SkipDatabase']            = $true }
        if ($SkipUrls)                { $configSplat['SkipUrls']                = $true }
        if ($SkipServiceAccount)      { $configSplat['SkipServiceAccount']      = $true }
        if ($SkipEncryptionKeyBackup) { $configSplat['SkipEncryptionKeyBackup'] = $true }
        if ($ContinueOnError)         { $configSplat['ContinueOnError']         = $true }
        if ($EnableException)         { $configSplat['EnableException']         = $true }

        try
        {
            $configResult = Set-sqmSsrsConfiguration @configSplat
            $result.ConfigResult = $configResult.OverallStatus

            $result.OverallStatus = switch ($true)
            {
                ($result.InstallResult -in @('OK', 'AlreadyInstalled') -and
                 $configResult.OverallStatus -eq 'Success')            { 'Success' }
                ($configResult.OverallStatus -eq 'PartialSuccess')     { 'PartialSuccess' }
                default                                                 { 'Failed' }
            }

            $result.Message = "Installation: $($result.InstallResult) | " +
                              "Konfiguration: $($configResult.OverallStatus) | " +
                              $configResult.Message
        }
        catch
        {
            $errMsg = "Konfigurationsfehler: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            $result.ConfigResult  = 'Failed'
            $result.OverallStatus = 'PartialSuccess'   # Installiert, aber Konfig fehlgeschlagen
            $result.Message       = "Installation: $($result.InstallResult) | Konfiguration: Failed | $errMsg"
            if ($EnableException) { throw }
            Write-Error $errMsg
        }

        Write-Host ""
        Write-Host "[$ComputerName] $functionName : $($result.OverallStatus)" `
                   -ForegroundColor $(if ($result.OverallStatus -eq 'Success') { 'Green' } else { 'Yellow' })

        return $result
    }
}
