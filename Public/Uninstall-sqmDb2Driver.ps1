function Uninstall-sqmDb2Driver {
    <#
    .SYNOPSIS
        Deinstalliert den IBM DB2 ODBC/CLI-Treiber.
    .DESCRIPTION
        Sucht den installierten IBM DB2-Treiber in der Windows-Uninstall-Registry
        und fuehrt eine stille Deinstallation durch (msiexec /x fuer MSI-basierte
        Installationen, alternativ Setup.exe /silent /uninstall).
    .EXAMPLE
        Uninstall-sqmDb2Driver
    .NOTES
        Erfordert lokale Administratorrechte.
        Nach Deinstallation sollte der Server neu gestartet werden.
    #>
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'

    # Registry-Pfade
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    # Suche nach IBM DB2-Eintraegen
    $entry = $null
    foreach ($path in $uninstallPaths) {
        try {
            $found = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -match 'IBM\s+DB2' } |
                     Select-Object -First 1
            if ($found) { $entry = $found; break }
        } catch { }
    }

    if (-not $entry) {
        # Fallback: Direkte Setup.exe suchen
        $setupPaths = @(
            "$env:ProgramFiles\IBM\SQLLIB\setup.exe",
            "${env:ProgramFiles(x86)}\IBM\SQLLIB\setup.exe"
        )
        $setupExe = $setupPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

        if (-not $setupExe) {
            return [PSCustomObject]@{
                Status  = 'NotFound'
                Message = 'Kein installierter IBM DB2-Treiber gefunden.'
            }
        }

        try {
            $proc = Start-Process -FilePath $setupExe `
                                  -ArgumentList '/silent', '/uninstall' `
                                  -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0) {
                return [PSCustomObject]@{ Status = 'Uninstalled'; Message = 'OK: IBM DB2-Treiber via Setup.exe deinstalliert.' }
            } else {
                return [PSCustomObject]@{ Status = 'Error'; Message = "Setup.exe ExitCode $($proc.ExitCode)." }
            }
        }
        catch {
            return [PSCustomObject]@{ Status = 'Error'; Message = "Fehler bei Setup.exe Deinstallation: $_" }
        }
    }

    $displayName = $entry.DisplayName
    $productCode = $entry.PSChildName

    if (-not $productCode -or $productCode -notmatch '^\{[0-9A-Fa-f\-]+\}$') {
        $uninstallStr = $entry.UninstallString
        if ($uninstallStr -match '\{[0-9A-Fa-f\-]+\}') {
            $productCode = $Matches[0]
        } else {
            return [PSCustomObject]@{
                Status  = 'Error'
                Message = "ProductCode nicht ermittelbar fuer: $displayName"
            }
        }
    }

    try {
        $proc = Start-Process -FilePath 'msiexec.exe' `
                              -ArgumentList "/x $productCode /quiet /norestart" `
                              -Wait -PassThru -ErrorAction Stop

        switch ($proc.ExitCode) {
            0    { return [PSCustomObject]@{ Status = 'Uninstalled'; Message = "OK: '$displayName' deinstalliert." } }
            1605 { return [PSCustomObject]@{ Status = 'NotFound';    Message = 'Treiber war nicht installiert (ExitCode 1605).' } }
            3010 { return [PSCustomObject]@{ Status = 'Uninstalled'; Message = "OK: '$displayName' deinstalliert (Neustart empfohlen)." } }
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
