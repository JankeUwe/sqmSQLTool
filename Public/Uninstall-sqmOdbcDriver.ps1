function Uninstall-sqmOdbcDriver {
    <#
    .SYNOPSIS
        Deinstalliert den Microsoft ODBC Driver for SQL Server.
    .DESCRIPTION
        Sucht den installierten Microsoft ODBC Driver for SQL Server in der
        Windows-Uninstall-Registry und fuehrt eine stille Deinstallation via
        msiexec /x durch. Wird typischerweise vor einer Neuinstallation einer
        neueren Version aufgerufen.
    .PARAMETER DriverName
        Optionaler Treibername fuer gezieltes Matching.
        Standard: Wildcard 'Microsoft ODBC Driver * for SQL Server'.
    .EXAMPLE
        Uninstall-sqmOdbcDriver
    .EXAMPLE
        Uninstall-sqmOdbcDriver -DriverName 'Microsoft ODBC Driver 17 for SQL Server'
    .NOTES
        Erfordert lokale Administratorrechte.
        ExitCode 1605 (nicht installiert) wird als NotFound behandelt, nicht als Fehler.
    #>
    [CmdletBinding()]
    param(
        [string]$DriverName = ''
    )

    $ErrorActionPreference = 'Stop'

    # Registry-Pfade fuer 64-bit und 32-bit Uninstall-Eintraege
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $pattern = if ($DriverName -and $DriverName -ne '') {
        [System.Text.RegularExpressions.Regex]::Escape($DriverName)
    } else {
        'Microsoft ODBC Driver \d+ for SQL Server'
    }

    $entry = $null
    foreach ($path in $uninstallPaths) {
        try {
            $found = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -match $pattern } |
                     Sort-Object { [int](($_.DisplayName -replace '\D','')) } -Descending |
                     Select-Object -First 1
            if ($found) { $entry = $found; break }
        } catch { }
    }

    if (-not $entry) {
        return [PSCustomObject]@{
            Status  = 'NotFound'
            Message = "Kein installierter ODBC-Treiber gefunden (Muster: $pattern)"
        }
    }

    $displayName   = $entry.DisplayName
    $productCode   = $entry.PSChildName  # z.B. {GUID}

    if (-not $productCode -or $productCode -notmatch '^\{[0-9A-Fa-f\-]+\}$') {
        # Fallback: UninstallString auslesen
        $uninstallStr = $entry.UninstallString
        if ($uninstallStr -match '\{[0-9A-Fa-f\-]+\}') {
            $productCode = $Matches[0]
        } else {
            return [PSCustomObject]@{
                Status  = 'Error'
                Message = "ProductCode konnte nicht ermittelt werden fuer: $displayName"
            }
        }
    }

    try {
        $proc = Start-Process -FilePath 'msiexec.exe' `
                              -ArgumentList "/x $productCode /quiet /norestart" `
                              -Wait -PassThru -ErrorAction Stop

        switch ($proc.ExitCode) {
            0     { return [PSCustomObject]@{ Status = 'Uninstalled'; Message = "OK: '$displayName' deinstalliert." } }
            1605  { return [PSCustomObject]@{ Status = 'NotFound';    Message = "Treiber war nicht installiert (ExitCode 1605)." } }
            3010  { return [PSCustomObject]@{ Status = 'Uninstalled'; Message = "OK: '$displayName' deinstalliert (Neustart empfohlen)." } }
            default {
                return [PSCustomObject]@{
                    Status  = 'Error'
                    Message = "msiexec ExitCode $($proc.ExitCode) bei Deinstallation von '$displayName'."
                }
            }
        }
    }
    catch {
        return [PSCustomObject]@{
            Status  = 'Error'
            Message = "Fehler bei Deinstallation von '$displayName': $_"
        }
    }
}
