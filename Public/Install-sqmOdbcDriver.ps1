<#
.SYNOPSIS
    Installiert den Microsoft ODBC Driver for SQL Server.

.DESCRIPTION
    Prueft ob der ODBC-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled).
    Bei Bedarf: Fuehrt den Installer still aus.

    Unterstuetzte Installer-Formate:
        - .msi : msiexec /i /quiet /norestart
        - .exe : Direktausfuehrung mit /quiet /norestart

.PARAMETER SourcePath
    Pfad zum ODBC-Installer oder Verzeichnis mit dem Installer.
    Z.B.: \\srv\Treiber\ODBC oder C:\Downloads\msodbcsql.msi

.PARAMETER DriverName
    Optionaler Treibername fuer die Vorab-Pruefung via Test-sqmDriverInstalled.
    Standard: automatische Erkennung (neuester Microsoft SQL ODBC-Treiber).

.OUTPUTS
    [PSCustomObject] mit:
        Status   : AlreadyInstalled | Installed | Error
        Version  : Erkannte Treiberversion
        Path     : Treiberpfad
        Message  : Detailmeldung

.EXAMPLE
    Install-sqmOdbcDriver -SourcePath '\\srv\Treiber\ODBC'

.EXAMPLE
    Install-sqmOdbcDriver -SourcePath 'C:\Setup\msodbcsql18.msi'

.NOTES
    Voraussetzungen: Lokale Administratorrechte.
    Download: https://learn.microsoft.com/de-de/sql/connect/odbc/download-odbc-driver-for-sql-server
#>
function Install-sqmOdbcDriver
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourcePath,

        [Parameter(Mandatory = $false)]
        [string]$DriverName
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
        $checkParams = @{ DriverType = 'ODBC' }
        if ($DriverName -and $DriverName -ne '') { $checkParams['DriverName'] = $DriverName }
        $check = Test-sqmDriverInstalled @checkParams

        if ($check.Installed)
        {
            $result.Status  = 'AlreadyInstalled'
            $result.Version = $check.Version
            $result.Path    = $check.Path
            $result.Message = "ODBC-Treiber bereits vorhanden: '$($check.DriverName)'" +
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
            # Verzeichnis: nach .msi oder .exe suchen
            $installerFile = Get-ChildItem -Path $SourcePath -Include 'msodbcsql*.msi','msodbcsql*.exe' `
                                -Recurse -ErrorAction SilentlyContinue |
                             Sort-Object Name -Descending | Select-Object -First 1
        }
        else
        {
            $installerFile = Get-Item $SourcePath -ErrorAction SilentlyContinue
        }

        if (-not $installerFile)
        {
            $result.Message = "Kein ODBC-Installer (msodbcsql*.msi / *.exe) in '$SourcePath' gefunden."
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        _Log "Starte ODBC-Installation: $($installerFile.FullName)"

        # --- Installation ausfuehren ---
        $exitCode = $null

        if ($installerFile.Extension -eq '.msi')
        {
            $proc = Start-Process -FilePath 'msiexec.exe' `
                        -ArgumentList '/i', "`"$($installerFile.FullName)`"", '/quiet', '/norestart', 'IACCEPTMSODBCSQLLICENSETERMS=YES' `
                        -Wait -PassThru -ErrorAction Stop
            $exitCode = $proc.ExitCode
        }
        else
        {
            $proc = Start-Process -FilePath $installerFile.FullName `
                        -ArgumentList '/quiet', '/norestart' `
                        -Wait -PassThru -ErrorAction Stop
            $exitCode = $proc.ExitCode
        }

        # msiexec ExitCode 3010 = Erfolg, Neustart erforderlich
        if ($exitCode -ne 0 -and $exitCode -ne 3010)
        {
            $result.Message = "ODBC-Installer fehlgeschlagen (ExitCode $exitCode): $($installerFile.FullName)"
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        $restartHint = if ($exitCode -eq 3010) { ' (Neustart empfohlen)' } else { '' }

        # Ergebnis pruefen
        $check2 = Test-sqmDriverInstalled @checkParams
        $result.Status  = 'Installed'
        $result.Version = $check2.Version
        $result.Path    = $check2.Path
        $result.Message = "ODBC-Treiber erfolgreich installiert: '$($installerFile.Name)'$restartHint" +
                          $(if ($check2.Version) { " v$($check2.Version)" } else { '' })

        _Log $result.Message 'INFO'
        Write-Host "  OK: $($result.Message)" -ForegroundColor Green
    }
    catch
    {
        $result.Status  = 'Error'
        $result.Message = "ODBC-Installation fehlgeschlagen: $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
