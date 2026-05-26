<#
.SYNOPSIS
    Prueft ob ein JDBC-, ODBC- oder DB2-Treiber auf dem System installiert ist.

.DESCRIPTION
    Treiber-Erkennung je nach Typ:

    ODBC:
        - Get-OdbcDriver (Windows PowerShell / CIM)
        - Registry: HKLM:\SOFTWARE\ODBC\ODBCINST.INI\<TreiberName>

    JDBC:
        - Suche nach Microsoft JDBC Driver .jar-Dateien in bekannten Pfaden:
          %ProgramFiles%\Microsoft JDBC Driver*\sqljdbc_*\
          %ProgramFiles(x86)%\Microsoft JDBC Driver*\
          Tomcat-Lib, JBoss-Lib, WildFly-Lib (falls vorhanden)

    DB2:
        - Registry: HKLM:\SOFTWARE\IBM\DB2
        - Get-OdbcDriver fuer IBM DB2 ODBC DRIVER
        - db2cli.exe im PATH oder %ProgramFiles%\IBM\SQLLIB\BIN\

.PARAMETER DriverType
    Art des Treibers: JDBC | ODBC | DB2. Mandatory.

.PARAMETER DriverName
    Optionaler spezifischer Treibername fuer die Suche.
    ODBC: z.B. "ODBC Driver 17 for SQL Server"
    JDBC: z.B. "mssql-jdbc-12.4.0.jre11.jar"
    DB2:  z.B. "IBM DB2 ODBC DRIVER"

.OUTPUTS
    [PSCustomObject] mit:
        DriverType  : JDBC | ODBC | DB2
        DriverName  : Gefundener Treibername
        Installed   : $true wenn gefunden
        Version     : Versionsnummer (wenn ermittelbar)
        Path        : Installationspfad
        Status      : Found | NotFound | Error
        Message     : Detailmeldung

.EXAMPLE
    Test-sqmDriverInstalled -DriverType ODBC

.EXAMPLE
    Test-sqmDriverInstalled -DriverType ODBC -DriverName 'ODBC Driver 18 for SQL Server'

.EXAMPLE
    Test-sqmDriverInstalled -DriverType JDBC

.EXAMPLE
    Test-sqmDriverInstalled -DriverType DB2

.NOTES
    Rein lesender Zugriff - keine Aenderungen am System.
    Zum Installieren: Install-sqmOdbcDriver, Install-sqmJdbcDriver, Install-sqmDb2Driver
#>
function Test-sqmDriverInstalled
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('JDBC', 'ODBC', 'DB2')]
        [string]$DriverType,

        [Parameter(Mandatory = $false)]
        [string]$DriverName
    )

    $functionName = $MyInvocation.MyCommand.Name

    $result = [PSCustomObject]@{
        DriverType  = $DriverType
        DriverName  = $null
        Installed   = $false
        Version     = $null
        Path        = $null
        Status      = 'NotFound'
        Message     = $null
    }

    function _Log { param([string]$Msg, [string]$Level = 'INFO')
        Write-Verbose "[$functionName] $Msg"
        try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
    }

    try
    {
        switch ($DriverType)
        {
            'ODBC'
            {
                _Log "Suche ODBC-Treiber (DriverName='$DriverName')..."

                # Alle ODBC-Treiber aus CIM lesen
                $allDrivers = Get-OdbcDriver -ErrorAction SilentlyContinue

                if ($DriverName -and $DriverName -ne '')
                {
                    $found = $allDrivers | Where-Object { $_.Name -like "*$DriverName*" }
                }
                else
                {
                    # Suche nach bekannten Microsoft SQL ODBC Treibern (neueste zuerst)
                    $found = $allDrivers | Where-Object { $_.Name -match 'ODBC Driver \d+ for SQL Server' } |
                             Sort-Object Name -Descending | Select-Object -First 1
                }

                if ($found)
                {
                    $found = @($found)[0]
                    # Version aus Registry lesen
                    $regPath = "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\$($found.Name)"
                    $regKey  = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                    $drvPath = if ($regKey) { $regKey.Driver } else { $null }
                    $version = $null
                    if ($drvPath -and (Test-Path $drvPath))
                    {
                        $version = (Get-Item $drvPath -ErrorAction SilentlyContinue).VersionInfo.FileVersion
                    }

                    $result.DriverName = $found.Name
                    $result.Installed  = $true
                    $result.Version    = $version
                    $result.Path       = $drvPath
                    $result.Status     = 'Found'
                    $result.Message    = "ODBC-Treiber gefunden: '$($found.Name)'" +
                                        $(if ($version) { " v$version" } else { '' })
                }
                else
                {
                    $result.Message = if ($DriverName) {
                        "ODBC-Treiber '$DriverName' nicht gefunden."
                    } else {
                        "Kein Microsoft SQL Server ODBC-Treiber gefunden."
                    }
                }
            }

            'JDBC'
            {
                _Log "Suche JDBC-Treiber (DriverName='$DriverName')..."

                $searchPaths = @(
                    (Join-Path $env:ProgramFiles 'Microsoft JDBC Driver*'),
                    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft JDBC Driver*'),
                    'C:\Program Files\Microsoft JDBC Driver*',
                    'C:\jdbc\*',
                    'C:\tomcat*\lib',
                    'C:\Program Files\Apache*\lib'
                )

                $jarPattern = if ($DriverName -and $DriverName -ne '') { $DriverName } else { 'mssql-jdbc*.jar' }
                $foundJar   = $null

                foreach ($pathPattern in $searchPaths)
                {
                    try
                    {
                        $jars = Get-ChildItem -Path $pathPattern -Filter $jarPattern -Recurse `
                                    -ErrorAction SilentlyContinue -Force |
                                Sort-Object Name -Descending | Select-Object -First 1
                        if ($jars)
                        {
                            $foundJar = $jars
                            break
                        }
                    }
                    catch { }
                }

                if ($foundJar)
                {
                    # Version aus Dateiname extrahieren (mssql-jdbc-12.4.0.jre11.jar)
                    $version = $null
                    if ($foundJar.Name -match 'mssql-jdbc-(\d+\.\d+\.\d+)')
                    {
                        $version = $Matches[1]
                    }

                    $result.DriverName = $foundJar.Name
                    $result.Installed  = $true
                    $result.Version    = $version
                    $result.Path       = $foundJar.FullName
                    $result.Status     = 'Found'
                    $result.Message    = "JDBC-Treiber gefunden: '$($foundJar.Name)'" +
                                        $(if ($version) { " v$version" } else { '' }) +
                                        " in '$($foundJar.DirectoryName)'"
                }
                else
                {
                    $result.Message = "Microsoft JDBC Driver (.jar) nicht gefunden."
                }
            }

            'DB2'
            {
                _Log "Suche DB2-Treiber (DriverName='$DriverName')..."

                $db2Found   = $false
                $db2Name    = $null
                $db2Version = $null
                $db2Path    = $null

                # 1. Registry IBM\DB2
                $db2RegBase = 'HKLM:\SOFTWARE\IBM\DB2'
                if (Test-Path $db2RegBase)
                {
                    $db2Reg  = Get-ItemProperty -Path $db2RegBase -ErrorAction SilentlyContinue
                    $db2Path = if ($db2Reg) { $db2Reg.DB2PATH } else { $null }
                    $db2Name = 'IBM DB2 Client'

                    # Version aus INSTPROF oder default
                    $versionReg = Get-ChildItem $db2RegBase -ErrorAction SilentlyContinue |
                                  Where-Object { $_.PSChildName -match 'GLOBAL_PROFILE' } |
                                  Select-Object -First 1
                    if ($versionReg)
                    {
                        $vProps  = Get-ItemProperty $versionReg.PSPath -ErrorAction SilentlyContinue
                        $db2Version = $vProps.DB2_VERSION
                    }
                    $db2Found = $true
                }

                # 2. ODBC-Treiber "IBM DB2 ODBC DRIVER"
                if (-not $db2Found)
                {
                    $odbcPattern = if ($DriverName -and $DriverName -ne '') { $DriverName } else { 'IBM DB2*' }
                    $db2Odbc     = Get-OdbcDriver -ErrorAction SilentlyContinue |
                                   Where-Object { $_.Name -like $odbcPattern } |
                                   Select-Object -First 1
                    if ($db2Odbc)
                    {
                        $db2Found = $true
                        $db2Name  = $db2Odbc.Name
                        $regPath  = "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\$($db2Odbc.Name)"
                        $regKey   = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                        $db2Path  = if ($regKey) { $regKey.Driver } else { $null }
                    }
                }

                # 3. db2cli.exe im Dateisystem
                if (-not $db2Found)
                {
                    $cliPaths = @(
                        'C:\Program Files\IBM\SQLLIB\BIN\db2cli.exe',
                        'C:\Program Files (x86)\IBM\SQLLIB\BIN\db2cli.exe'
                    )
                    foreach ($cliPath in $cliPaths)
                    {
                        if (Test-Path $cliPath)
                        {
                            $db2Found = $true
                            $db2Name  = 'IBM DB2 CLI'
                            $db2Path  = $cliPath
                            break
                        }
                    }
                }

                if ($db2Found)
                {
                    $result.DriverName = $db2Name
                    $result.Installed  = $true
                    $result.Version    = $db2Version
                    $result.Path       = $db2Path
                    $result.Status     = 'Found'
                    $result.Message    = "DB2-Treiber gefunden: '$db2Name'" +
                                        $(if ($db2Version) { " v$db2Version" } else { '' }) +
                                        $(if ($db2Path)    { " in '$db2Path'" } else { '' })
                }
                else
                {
                    $result.Message = "Kein IBM DB2-Treiber gefunden."
                }
            }
        }

        if (-not $result.Installed)
        {
            $result.Status = 'NotFound'
        }

        _Log $result.Message $(if ($result.Installed) { 'INFO' } else { 'WARNING' })
    }
    catch
    {
        $result.Status  = 'Error'
        $result.Message = "Fehler bei Treiberpruefung ($DriverType): $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
