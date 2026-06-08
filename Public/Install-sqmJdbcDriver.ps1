<#
.SYNOPSIS
    Installiert den Microsoft JDBC Driver for SQL Server.

.DESCRIPTION
    Prueft ob der JDBC-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled).
    Bei Bedarf: Kopiert die .jar-Datei aus dem SourcePath in den Zielpfad
    und setzt optional die CLASSPATH-Umgebungsvariable.

    Unterstuetzte Installer-Formate:
        - .jar  : Direkte Kopie
        - .exe  : Microsoft-Installer, wird still ausgefuehrt (/quiet /passive)
        - .zip  : Extraktion, dann .jar kopieren

.PARAMETER SourcePath
    Quellpfad wo der JDBC-Installer oder die .jar liegt.
    Z.B.: \\srv\Treiber\JDBC oder C:\Downloads\sqljdbc_12.4

.PARAMETER DestinationPath
    Zielpfad fuer die .jar-Datei.
    Standard: C:\Program Files\Microsoft JDBC Driver for SQL Server\

.PARAMETER UpdateClassPath
    Wenn $true: CLASSPATH-Systemumgebungsvariable wird um den Zielpfad erweitert.
    Standard: $false

.OUTPUTS
    [PSCustomObject] mit:
        Status   : AlreadyInstalled | Installed | Error
        Version  : Erkannte Treiberversion
        Path     : Installationspfad
        Message  : Detailmeldung

.EXAMPLE
    Install-sqmJdbcDriver -SourcePath '\\srv\Treiber\JDBC'

.EXAMPLE
    Install-sqmJdbcDriver -SourcePath 'C:\Downloads\jdbc' -UpdateClassPath $true

.NOTES
    Voraussetzungen: Lokale Administratorrechte.
    Download: https://learn.microsoft.com/de-de/sql/connect/jdbc/download-microsoft-jdbc-driver-for-sql-server
#>
function Install-sqmJdbcDriver
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourcePath,

        [Parameter(Mandatory = $false)]
        [string]$DestinationPath = 'C:\Program Files\Microsoft JDBC Driver for SQL Server',

        [Parameter(Mandatory = $false)]
        [bool]$UpdateClassPath = $false
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
        $check = Test-sqmDriverInstalled -DriverType JDBC
        if ($check.Installed)
        {
            $result.Status  = 'AlreadyInstalled'
            $result.Version = $check.Version
            $result.Path    = $check.Path
            $result.Message = "JDBC-Treiber bereits vorhanden: '$($check.DriverName)'" +
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

        _Log "Suche JDBC-Installer in: $SourcePath"

        # .jar direkt oder in Unterordnern suchen
        $jarFile = Get-ChildItem -Path $SourcePath -Filter 'mssql-jdbc*.jar' -Recurse `
                      -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1

        $exeFile = Get-ChildItem -Path $SourcePath -Filter 'sqljdbc*.exe' `
                      -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1

        if ($exeFile)
        {
            # Microsoft Self-Extractor ausfuehren
            _Log "Fuehre JDBC-Installer aus: $($exeFile.FullName)"
            $proc = Start-Process -FilePath $exeFile.FullName -ArgumentList '/quiet', '/passive' `
                        -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -ne 0)
            {
                $result.Message = "JDBC-Installer fehlgeschlagen (ExitCode $($proc.ExitCode)): $($exeFile.FullName)"
                _Log $result.Message 'ERROR'
                Write-Error $result.Message
                return $result
            }
            _Log "Installer abgeschlossen (ExitCode 0)."

            # Ergebnis erneut pruefen
            $check2 = Test-sqmDriverInstalled -DriverType JDBC
            $result.Status  = 'Installed'
            $result.Version = $check2.Version
            $result.Path    = $check2.Path
            $result.Message = "JDBC-Treiber installiert via Installer." +
                              $(if ($check2.Version) { " v$($check2.Version)" } else { '' })
        }
        elseif ($jarFile)
        {
            # .jar direkt kopieren
            if (-not (Test-Path $DestinationPath))
            {
                New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
                _Log "Zielverzeichnis erstellt: $DestinationPath"
            }

            $destJar = Join-Path $DestinationPath $jarFile.Name
            Copy-Item -Path $jarFile.FullName -Destination $destJar -Force -ErrorAction Stop
            _Log "JAR kopiert: $destJar"

            # Version aus Dateiname
            $version = $null
            if ($jarFile.Name -match 'mssql-jdbc-(\d+\.\d+\.\d+)') { $version = $Matches[1] }

            $result.Status  = 'Installed'
            $result.Version = $version
            $result.Path    = $destJar
            $result.Message = "JDBC-Treiber installiert: '$($jarFile.Name)'" +
                              $(if ($version) { " v$version" } else { '' }) +
                              " -> $destJar"

            # CLASSPATH setzen wenn gewuenscht
            if ($UpdateClassPath)
            {
                $current = [System.Environment]::GetEnvironmentVariable('CLASSPATH', 'Machine')
                if ($current -notlike "*$DestinationPath*")
                {
                    $new = if ($current) { "$current;$DestinationPath" } else { $DestinationPath }
                    [System.Environment]::SetEnvironmentVariable('CLASSPATH', $new, 'Machine')
                    _Log "CLASSPATH um '$DestinationPath' erweitert."
                    $result.Message += " | CLASSPATH aktualisiert."
                }
            }
        }
        else
        {
            $result.Message = "Kein JDBC-Installer (.exe) oder .jar-Datei in '$SourcePath' gefunden."
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        _Log $result.Message 'INFO'
        Write-Host "  OK: $($result.Message)" -ForegroundColor Green
    }
    catch
    {
        $result.Status  = 'Error'
        $result.Message = "JDBC-Installation fehlgeschlagen: $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
