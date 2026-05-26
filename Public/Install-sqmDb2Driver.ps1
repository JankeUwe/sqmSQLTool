<#
.SYNOPSIS
    Installiert den IBM DB2 ODBC/CLI-Treiber.

.DESCRIPTION
    Prueft ob ein DB2-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled -DriverType DB2).
    Bei Bedarf: Fuehrt den IBM-Installer still aus.

    Unterstuetzte Installer-Formate:
        - db2_odbc_cli.exe / db2_odbc_cli_64.exe : IBM CLI-Treiber
        - setup.exe (DB2 Client)                  : Vollstaendiger IBM-Installer
        - .msi                                    : MSI-basierter Installer

    Falls der Treiber nach der Installation nicht automatisch als ODBC-Treiber
    registriert ist, wird db2cli.exe -setup -registerall ausgefuehrt.

.PARAMETER SourcePath
    Pfad zum DB2-Installer oder Verzeichnis mit dem Installer.
    Z.B.: \\srv\Treiber\DB2 oder C:\Downloads\db2_odbc_cli_64.exe

.OUTPUTS
    [PSCustomObject] mit:
        Status   : AlreadyInstalled | Installed | Error
        Version  : Erkannte Treiberversion
        Path     : Installationspfad
        Message  : Detailmeldung

.EXAMPLE
    Install-sqmDb2Driver -SourcePath '\\srv\Treiber\DB2'

.EXAMPLE
    Install-sqmDb2Driver -SourcePath 'C:\Downloads\db2_odbc_cli_64.exe'

.NOTES
    Voraussetzungen: Lokale Administratorrechte.
    IBM CLI Treiber Download: https://www.ibm.com/support/pages/db2-odbc-cli-driver-download-and-installation-information
#>
function Install-sqmDb2Driver
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourcePath
    )

    $functionName = $MyInvocation.MyCommand.Name

    $result = [PSCustomObject]@{
        Status  = 'Error'
        Version = $null
        Path    = $null
        Message = $null
    }

    function _Log { param([string]$Msg, [string]$Level = 'INFO')
        Write-Verbose "[$functionName] $Msg"
        try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
    }

    try
    {
        # --- Bereits installiert? ---
        $check = Test-sqmDriverInstalled -DriverType DB2
        if ($check.Installed)
        {
            $result.Status  = 'AlreadyInstalled'
            $result.Version = $check.Version
            $result.Path    = $check.Path
            $result.Message = "DB2-Treiber bereits vorhanden: '$($check.DriverName)'" +
                              $(if ($check.Version) { " v$($check.Version)" } else { '' })
            _Log $result.Message 'INFO'
            Write-Host "  OK: $($result.Message)" -ForegroundColor Green
            return $result
        }

        # --- Quellpfad pruefen ---
        if (-not (Test-Path $SourcePath))
        {
            $result.Message = "Quellpfad nicht erreichbar: $SourcePath"
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        # --- Installer ermitteln ---
        $installerFile = $null

        if ((Get-Item $SourcePath).PSIsContainer)
        {
            # Reihenfolge: CLI-Treiber bevorzugt vor vollem DB2-Client
            $installerFile = Get-ChildItem -Path $SourcePath `
                                -Include 'db2_odbc_cli_64.exe','db2_odbc_cli.exe','db2client*.exe','setup.exe','*.msi' `
                                -Recurse -ErrorAction SilentlyContinue |
                             Sort-Object { switch ($_.Name) {
                                 'db2_odbc_cli_64.exe' { 0 }
                                 'db2_odbc_cli.exe'    { 1 }
                                 default               { 2 }
                             }} | Select-Object -First 1
        }
        else
        {
            $installerFile = Get-Item $SourcePath -ErrorAction SilentlyContinue
        }

        if (-not $installerFile)
        {
            $result.Message = "Kein DB2-Installer in '$SourcePath' gefunden."
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        _Log "Starte DB2-Installation: $($installerFile.FullName)"

        # --- Installation ausfuehren ---
        $exitCode = $null

        if ($installerFile.Extension -eq '.msi')
        {
            $proc = Start-Process -FilePath 'msiexec.exe' `
                        -ArgumentList '/i', "`"$($installerFile.FullName)`"", '/quiet', '/norestart' `
                        -Wait -PassThru -ErrorAction Stop
            $exitCode = $proc.ExitCode
        }
        else
        {
            # IBM CLI-Treiber und DB2-Client: /silent oder -silent
            $proc = Start-Process -FilePath $installerFile.FullName `
                        -ArgumentList '/silent' `
                        -Wait -PassThru -ErrorAction Stop
            $exitCode = $proc.ExitCode
        }

        if ($exitCode -ne 0 -and $exitCode -ne 3010)
        {
            $result.Message = "DB2-Installer fehlgeschlagen (ExitCode $exitCode): $($installerFile.FullName)"
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        # --- ODBC-Treiber registrieren falls noetig ---
        $db2CliPaths = @(
            'C:\Program Files\IBM\SQLLIB\BIN\db2cli.exe',
            'C:\Program Files (x86)\IBM\SQLLIB\BIN\db2cli.exe'
        )
        foreach ($cliPath in $db2CliPaths)
        {
            if (Test-Path $cliPath)
            {
                _Log "Registriere DB2 ODBC-Treiber: $cliPath -setup -registerall"
                try
                {
                    $regProc = Start-Process -FilePath $cliPath -ArgumentList '-setup', '-registerall' `
                                   -Wait -PassThru -ErrorAction Stop
                    _Log "db2cli -setup -registerall ExitCode: $($regProc.ExitCode)"
                }
                catch
                {
                    _Log "db2cli -setup -registerall fehlgeschlagen: $($_.Exception.Message)" 'WARNING'
                }
                break
            }
        }

        # Ergebnis pruefen
        $check2 = Test-sqmDriverInstalled -DriverType DB2
        $result.Status  = 'Installed'
        $result.Version = $check2.Version
        $result.Path    = $check2.Path
        $result.Message = "DB2-Treiber erfolgreich installiert: '$($installerFile.Name)'" +
                          $(if ($check2.Version) { " v$($check2.Version)" } else { '' })

        _Log $result.Message 'INFO'
        Write-Host "  OK: $($result.Message)" -ForegroundColor Green
    }
    catch
    {
        $result.Status  = 'Error'
        $result.Message = "DB2-Installation fehlgeschlagen: $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
