<#
.SYNOPSIS
    Prueft ob SQL Server Max Server Memory korrekt konfiguriert ist.

.DESCRIPTION
    Liest den aktuellen "max server memory (MB)"-Wert und vergleicht ihn
    mit der Empfehlung (90% des physischen RAM).

    Sonderwert 2147483647 (= 2^31 - 1) bedeutet "nicht konfiguriert" (SQL-Standard-Default).

    Status-Auswertung:
        OK          : Konfigurierter Wert liegt im Toleranzbereich (>=85% und <=95% RAM)
        TooHigh     : Konfiguriert aber oberhalb 95% RAM (Risiko fuer OS)
        TooLow      : Konfiguriert aber unterhalb 85% RAM (SQL Server unterversorgt)
        Unconfigured: Wert ist 2147483647 - Standard-Default, kein expliziter Wert gesetzt

.PARAMETER SqlInstance
    SQL Server-Instanzname. Z.B. "MSSQLSERVER" oder "SERVER\INST01".

.PARAMETER RecommendedPct
    Empfohlener Prozentsatz des RAM fuer SQL Server. Standard: 90.

.OUTPUTS
    [PSCustomObject] mit:
        SqlInstance      : Instanzname
        CurrentMaxMemMB  : Aktuell konfigurierter Wert (MB)
        RecommendedMB    : Empfohlener Wert (MB)
        TotalRamMB       : Gesamter physischer RAM (MB)
        Status           : OK | TooHigh | TooLow | Unconfigured | Error
        Message          : Detailmeldung

.EXAMPLE
    Test-sqmMaxMemory -SqlInstance 'MSSQLSERVER'

.EXAMPLE
    Test-sqmMaxMemory -SqlInstance 'SQL01\INST01' | Where-Object { $_.Status -ne 'OK' }

.NOTES
    Rein lesender Zugriff. Zum Setzen: Set-DbaMaxMemory (dbaTools).
    Toleranzbereich: 85% - 95% des RAM.
#>
function Test-sqmMaxMemory
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [ValidateRange(70, 99)]
        [int]$RecommendedPct = 90
    )

    $functionName = $MyInvocation.MyCommand.Name

    $result = [PSCustomObject]@{
        SqlInstance     = $SqlInstance
        CurrentMaxMemMB = $null
        RecommendedMB   = $null
        TotalRamMB      = $null
        Status          = 'Error'
        Message         = $null
    }

    function _Log { param([string]$Msg, [string]$Level = 'INFO')
        Write-Verbose "[$functionName] $Msg"
        try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
    }

    try
    {
        # --- RAM ermitteln ---
        $totalRamMB = [math]::Round(
            (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB
        )
        $recommendedMB = [math]::Round($totalRamMB * ($RecommendedPct / 100))
        $result.TotalRamMB    = $totalRamMB
        $result.RecommendedMB = $recommendedMB

        _Log "RAM gesamt: $totalRamMB MB | Empfehlung ($RecommendedPct%): $recommendedMB MB"

        # --- Max Memory lesen (dbaTools) ---
        $memInfo = Get-DbaMaxMemory -SqlInstance $SqlInstance -ErrorAction Stop
        $currentMB = [int]$memInfo.MaxValue
        $result.CurrentMaxMemMB = $currentMB

        _Log "Aktuelle Max Memory: $currentMB MB"

        # --- Auswertung ---
        $unconfiguredValue = 2147483647
        $lowerBound = [math]::Round($totalRamMB * 0.85)
        $upperBound = [math]::Round($totalRamMB * 0.95)

        if ($currentMB -eq $unconfiguredValue)
        {
            $result.Status  = 'Unconfigured'
            $result.Message = "Max Server Memory ist nicht konfiguriert (Default-Wert 2147483647). " +
                              "Empfehlung: $recommendedMB MB ($RecommendedPct% von $totalRamMB MB RAM)"
            _Log $result.Message 'WARNING'
        }
        elseif ($currentMB -gt $upperBound)
        {
            $result.Status  = 'TooHigh'
            $result.Message = "Max Server Memory $currentMB MB ist zu hoch (>95% RAM). " +
                              "Empfehlung: $recommendedMB MB (Obergrenze: $upperBound MB)"
            _Log $result.Message 'WARNING'
        }
        elseif ($currentMB -lt $lowerBound)
        {
            $result.Status  = 'TooLow'
            $result.Message = "Max Server Memory $currentMB MB ist zu niedrig (<85% RAM). " +
                              "Empfehlung: $recommendedMB MB (Untergrenze: $lowerBound MB)"
            _Log $result.Message 'WARNING'
        }
        else
        {
            $result.Status  = 'OK'
            $result.Message = "Max Server Memory $currentMB MB OK (Empfehlung: $recommendedMB MB, " +
                              "Toleranz: $lowerBound - $upperBound MB)"
            _Log $result.Message 'INFO'
        }
    }
    catch
    {
        $result.Message = "Fehler beim Lesen von Max Server Memory: $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
