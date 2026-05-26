<#
.SYNOPSIS
    Konfiguriert den TCP-Port einer SQL Server-Instanz ueber die Registry.

.DESCRIPTION
    Setzt den statischen TCP-Port fuer eine SQL Server-Instanz.
    Der Port wird aus BasePort und PortIncrement berechnet:
        - Default-Instanz (MSSQLSERVER): Port = BasePort
        - Named Instance:                Port = BasePort + (InstanzNummer * PortIncrement)

    Die Instanznummer wird aus dem Instanznamen extrahiert wenn moeglich
    (z.B. INST01 -> 1, INST02 -> 2). Ist keine Zahl im Namen enthalten,
    wird eine fortlaufende Nummer anhand der Registry-Reihenfolge vergeben.

    Aenderungen werden erst nach Neustart des SQL Server-Dienstes aktiv.
    Die Funktion startet den Dienst NICHT automatisch neu.

.PARAMETER SqlInstance
    Name der SQL-Instanz (z.B. "MSSQLSERVER" fuer Default, "INST01" fuer Named Instance).
    Darf auch als SERVERNAME\INSTANZNAME angegeben werden - der Servername wird ignoriert.

.PARAMETER BasePort
    Basisport. Standard: 1433.

.PARAMETER PortIncrement
    Schrittweite pro Instanz. Standard: 10.

.PARAMETER InstanceNumber
    Optionale explizite Instanznummer (ueberschreibt Auto-Erkennung aus Instanzname).

.OUTPUTS
    [PSCustomObject] mit:
        SqlInstance  : Instanzname
        Port         : Berechneter Port
        PreviousPort : Port vor der Aenderung
        Status       : AlreadySet | Changed | Error
        Message      : Detailmeldung

.EXAMPLE
    Set-sqmTcpPort -SqlInstance 'MSSQLSERVER' -BasePort 1433

.EXAMPLE
    Set-sqmTcpPort -SqlInstance 'INST01' -BasePort 1433 -PortIncrement 10

.NOTES
    Voraussetzungen : Lokale Administratorrechte, SQL Server installiert.
    Registry-Pfad   : HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\
                      <InstanceRegPath>\MSSQLServer\SuperSocketNetLib\Tcp\IPAll
    Nach Aenderung muss der SQL Server-Dienst neu gestartet werden.
#>
function Set-sqmTcpPort
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1024, 65535)]
        [int]$BasePort = 1433,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$PortIncrement = 10,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 99)]
        [int]$InstanceNumber = -1
    )

    $functionName = $MyInvocation.MyCommand.Name

    # Serverprafix entfernen (SERVERNAME\INST01 -> INST01)
    if ($SqlInstance -match '\\(.+)$') { $SqlInstance = $Matches[1] }
    $instanceUpper = $SqlInstance.ToUpper()

    $result = [PSCustomObject]@{
        SqlInstance  = $instanceUpper
        Port         = $null
        PreviousPort = $null
        Status       = 'Error'
        Message      = $null
    }

    function _Log { param([string]$Msg, [string]$Level = 'INFO')
        Write-Verbose "[$functionName] $Msg"
        try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
    }

    try
    {
        # --- Instanznummer bestimmen ---
        if ($InstanceNumber -ge 0)
        {
            $instNum = $InstanceNumber
        }
        elseif ($instanceUpper -eq 'MSSQLSERVER')
        {
            $instNum = 0
        }
        else
        {
            # Zahl aus Instanzname extrahieren (INST01 -> 1, SQL02 -> 2)
            if ($instanceUpper -match '(\d+)$')
            {
                $instNum = [int]$Matches[1]
            }
            else
            {
                # Fallback: Position in der Registry-Liste
                $instNames = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' `
                    -ErrorAction SilentlyContinue).PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS' } |
                    Select-Object -ExpandProperty Name
                $idx = [Array]::IndexOf($instNames, $instanceUpper)
                $instNum = if ($idx -ge 0) { $idx } else { 1 }
            }
        }

        $targetPort = $BasePort + ($instNum * $PortIncrement)
        $result.Port = $targetPort

        _Log "Instanz: $instanceUpper | InstanzNr: $instNum | Zielport: $targetPort"

        # --- Registry-Pfad ermitteln ---
        $instanceRegKey = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' `
            -ErrorAction Stop).$instanceUpper

        if (-not $instanceRegKey)
        {
            $result.Message = "Instanz '$instanceUpper' nicht in Registry gefunden."
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        $tcpRegPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceRegKey\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"

        if (-not (Test-Path $tcpRegPath))
        {
            $result.Message = "TCP-Registry-Pfad nicht gefunden: $tcpRegPath"
            _Log $result.Message 'ERROR'
            Write-Error $result.Message
            return $result
        }

        # --- Aktuellen Port lesen ---
        $currentProps = Get-ItemProperty -Path $tcpRegPath -ErrorAction Stop
        $currentPort  = $currentProps.TcpPort
        $result.PreviousPort = $currentPort

        _Log "Aktueller Port: '$currentPort' | Zielport: $targetPort"

        # --- Idempotenz-Pruefung ---
        if ($currentPort -eq $targetPort.ToString())
        {
            $result.Status  = 'AlreadySet'
            $result.Message = "Port $targetPort ist bereits konfiguriert - keine Aenderung noetig."
            _Log $result.Message 'INFO'
            Write-Verbose $result.Message
            return $result
        }

        # --- Port setzen ---
        Set-ItemProperty -Path $tcpRegPath -Name 'TcpPort'        -Value $targetPort.ToString() -ErrorAction Stop
        Set-ItemProperty -Path $tcpRegPath -Name 'TcpDynamicPorts' -Value ''                    -ErrorAction Stop

        $result.Status  = 'Changed'
        $result.Message = "TCP-Port fuer '$instanceUpper' von '$currentPort' auf $targetPort geaendert. " +
                          "Dienst-Neustart erforderlich."
        _Log $result.Message 'INFO'
        Write-Host "  OK: $($result.Message)" -ForegroundColor Green
    }
    catch
    {
        $result.Message = "Fehler beim Setzen des TCP-Ports: $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
