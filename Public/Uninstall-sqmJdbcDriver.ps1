function Uninstall-sqmJdbcDriver {
    <#
    .SYNOPSIS
        Deinstalliert den Microsoft JDBC Driver for SQL Server.
    .DESCRIPTION
        Entfernt vorhandene mssql-jdbc*.jar Dateien aus dem Standard-Installationsverzeichnis
        des Microsoft JDBC Driver for SQL Server. Da JDBC als JAR-Datei deployed wird
        (kein MSI), genuegt das Loeschen der JAR-Dateien als Deinstallation.
        Optionale Bereinigung des CLASSPATH-Eintrags.
    .PARAMETER RemoveClassPath
        Entfernt den CLASSPATH-Systemeintrag wenn vorhanden. Standard: $false.
    .EXAMPLE
        Uninstall-sqmJdbcDriver
    .EXAMPLE
        Uninstall-sqmJdbcDriver -RemoveClassPath
    .NOTES
        Erfordert lokale Administratorrechte fuer das Loeschen in Program Files.
    #>
    [CmdletBinding()]
    param(
        [switch]$RemoveClassPath
    )

    $ErrorActionPreference = 'Stop'

    # Suchpfade fuer JDBC-Installation
    $searchRoots = @(
        "$env:ProgramFiles\Microsoft JDBC Driver*",
        "${env:ProgramFiles(x86)}\Microsoft JDBC Driver*",
        'C:\jdbc'
    )

    $removed   = @()
    $notFound  = $true

    foreach ($root in $searchRoots) {
        try {
            $dirs = Get-Item -Path $root -ErrorAction SilentlyContinue
            foreach ($dir in $dirs) {
                $jars = Get-ChildItem -Path $dir.FullName -Filter 'mssql-jdbc*.jar' -Recurse -ErrorAction SilentlyContinue
                foreach ($jar in $jars) {
                    Remove-Item -LiteralPath $jar.FullName -Force -ErrorAction Stop
                    $removed += $jar.FullName
                    $notFound = $false
                }
                # Leeres Verzeichnis entfernen wenn moeglich
                try {
                    $remaining = Get-ChildItem -Path $dir.FullName -ErrorAction SilentlyContinue
                    if (-not $remaining) {
                        Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
            }
        } catch { }
    }

    if ($notFound) {
        return [PSCustomObject]@{
            Status  = 'NotFound'
            Message = 'Kein installierter JDBC-Treiber (mssql-jdbc*.jar) gefunden.'
        }
    }

    # Optional: CLASSPATH-Systemeintrag bereinigen
    if ($RemoveClassPath) {
        try {
            $cp = [Environment]::GetEnvironmentVariable('CLASSPATH', [EnvironmentVariableTarget]::Machine)
            if ($cp) {
                $parts    = $cp -split ';' | Where-Object { $_ -notmatch 'mssql-jdbc' -and $_ -ne '' }
                $newCp    = $parts -join ';'
                [Environment]::SetEnvironmentVariable('CLASSPATH', $newCp, [EnvironmentVariableTarget]::Machine)
            }
        } catch { }
    }

    return [PSCustomObject]@{
        Status  = 'Uninstalled'
        Message = "OK: $($removed.Count) JAR-Datei(en) entfernt.`n  " + ($removed -join "`n  ")
    }
}
