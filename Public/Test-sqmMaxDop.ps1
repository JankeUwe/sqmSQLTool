<#
.SYNOPSIS
    Prueft ob MAXDOP (Max Degree of Parallelism) korrekt konfiguriert ist.

.DESCRIPTION
    Liest den aktuellen MAXDOP-Wert aus sys.configurations und vergleicht
    ihn mit der Microsoft-Empfehlung:
        Empfehlung: min(8, Anzahl logischer CPUs)

    Sonderwert 0 bedeutet "kein Limit" = unkonfiguriert (SQL-Default, nicht empfohlen).

    Status-Auswertung:
        OK          : MAXDOP entspricht der Empfehlung
        Suboptimal  : MAXDOP weicht von der Empfehlung ab (zu hoch oder zu niedrig, aber > 0)
        Unconfigured: MAXDOP = 0 (unbegrenzt, Standard-Default)

.PARAMETER SqlInstance
    SQL Server-Instanzname. Z.B. "MSSQLSERVER" oder "SERVER\INST01".

.OUTPUTS
    [PSCustomObject] mit:
        SqlInstance    : Instanzname
        CurrentMaxDop  : Aktuell konfigurierter MAXDOP
        RecommendedDop : Empfohlener MAXDOP
        LogicalCPUs    : Anzahl logischer CPUs
        Status         : OK | Suboptimal | Unconfigured | Error
        Message        : Detailmeldung

.EXAMPLE
    Test-sqmMaxDop -SqlInstance 'MSSQLSERVER'

.EXAMPLE
    Test-sqmMaxDop -SqlInstance 'SQL01\INST01'

.NOTES
    Rein lesender Zugriff. Zum Setzen: Set-DbaSpConfigure -Name 'max degree of parallelism'.
    Weitere Empfehlung: Cost Threshold for Parallelism auf 50 setzen.
#>
function Test-sqmMaxDop
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SqlInstance
    )

    $functionName = $MyInvocation.MyCommand.Name

    $result = [PSCustomObject]@{
        SqlInstance    = $SqlInstance
        CurrentMaxDop  = $null
        RecommendedDop = $null
        LogicalCPUs    = $null
        Status         = 'Error'
        Message        = $null
    }

    function _Log { param([string]$Msg, [string]$Level = 'INFO')
        Write-Verbose "[$functionName] $Msg"
        try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
    }

    try
    {
        # --- CPU-Anzahl ermitteln ---
        $cpuCount = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors
        $recommended = [math]::Min(8, $cpuCount)
        $result.LogicalCPUs    = $cpuCount
        $result.RecommendedDop = $recommended

        _Log "Logische CPUs: $cpuCount | Empfohlener MAXDOP: $recommended"

        # --- MAXDOP lesen (dbaTools) ---
        $cfg = Get-DbaSpConfigure -SqlInstance $SqlInstance -Name 'max degree of parallelism' -ErrorAction Stop
        $currentDop = [int]$cfg.RunningValue
        $result.CurrentMaxDop = $currentDop

        _Log "Aktueller MAXDOP: $currentDop"

        # --- Auswertung ---
        if ($currentDop -eq 0)
        {
            $result.Status  = 'Unconfigured'
            $result.Message = "MAXDOP ist 0 (unbegrenzt, kein Limit). " +
                              "Empfehlung: $recommended (min(8, $cpuCount CPUs))"
            _Log $result.Message 'WARNING'
        }
        elseif ($currentDop -eq $recommended)
        {
            $result.Status  = 'OK'
            $result.Message = "MAXDOP $currentDop entspricht der Empfehlung (min(8, $cpuCount CPUs) = $recommended)"
            _Log $result.Message 'INFO'
        }
        else
        {
            $result.Status  = 'Suboptimal'
            $direction = if ($currentDop -gt $recommended) { 'zu hoch' } else { 'zu niedrig' }
            $result.Message = "MAXDOP $currentDop ist $direction. " +
                              "Empfehlung: $recommended (min(8, $cpuCount CPUs))"
            _Log $result.Message 'WARNING'
        }
    }
    catch
    {
        $result.Message = "Fehler beim Lesen von MAXDOP: $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
