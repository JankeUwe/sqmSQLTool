<#
.SYNOPSIS
    Prueft ob die Anzahl der TempDB-Datendateien der empfohlenen CPU-Anzahl entspricht.

.DESCRIPTION
    Liest die Anzahl der TempDB-Datendateien (Typ = Rows, ohne Log) per SMO und
    vergleicht sie mit der Anzahl der CPU-Kerne des Servers (max 8 gemaess
    Microsoft-Empfehlung).

    Hintergrund: Zu wenige TempDB-Dateien koennen zu PAGELATCH-Konflikten auf
    der Allocation-Seite fuehren. Microsoft empfiehlt eine Datei pro
    logischem Kern, maximal 8.

    Gibt ein PSCustomObject mit aktuellem Wert, empfohlenem Wert und Status zurueck.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung.

.PARAMETER MaxFiles
    Maximale empfohlene Dateianzahl. Standard: 8 (Microsoft-Empfehlung).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt Write-Error.

.OUTPUTS
    [PSCustomObject] mit den Feldern:
        SqlInstance      : Instanzname
        CurrentFileCount : Aktuell vorhandene TempDB-Datendateien
        RecommendedCount : Empfohlene Anzahl (CPU-Kerne, max MaxFiles)
        LogicalCores     : Ermittelte logische CPU-Kerne
        Status           : OK | Warning | Error
        Message          : Detailmeldung

.EXAMPLE
    Test-sqmTempDbFileCount -SqlInstance "SQL01"

.EXAMPLE
    Test-sqmTempDbFileCount -SqlInstance "SQL01\INST1" -MaxFiles 4

.NOTES
    Empfehlung: 1 Datendatei pro logischem Kern, max 8.
    Alle Datendateien sollten gleich gross sein (Autogrowth identisch).
    Nur Datendateien (FileType = RowData) werden gezaehlt, keine Logdateien.
#>
function Test-sqmTempDbFileCount
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 64)]
        [int]$MaxFiles = 8,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
        {
            $SqlInstance = $env:COMPUTERNAME
        }
        Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        try
        {
            [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo')

            $server = New-Object Microsoft.SqlServer.Management.Smo.Server($SqlInstance)
            if ($SqlCredential)
            {
                $server.ConnectionContext.LoginSecure    = $false
                $server.ConnectionContext.Login          = $SqlCredential.UserName
                $server.ConnectionContext.SecurePassword = $SqlCredential.Password
            }

            # Logische CPU-Kerne ermitteln (max MaxFiles)
            $logicalCores = ($server.Processors | Measure-Object).Count
            if ($logicalCores -eq 0)
            {
                # Fallback: WMI lokal
                $logicalCores = (Get-CimInstance Win32_Processor |
                    Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            }
            $recommendedCount = [Math]::Min($logicalCores, $MaxFiles)

            # TempDB Datendateien zaehlen (nur RowData, kein Log)
            $tempDb    = $server.Databases['tempdb']
            $dataFiles = $tempDb.FileGroups | ForEach-Object { $_.Files } |
                         Where-Object { $_.UsedSpace -ge 0 }   # alle DataFiles
            $fileCount = ($dataFiles | Measure-Object).Count

            if ($fileCount -eq $recommendedCount)
            {
                $status  = 'OK'
                $message = "TempDB Datendateien: $fileCount - entspricht empfohlenem Wert ($recommendedCount bei $logicalCores logischen Kernen)."
                Write-Host "  OK   $message" -ForegroundColor Green
            }
            else
            {
                $status  = 'Warning'
                $message = "TempDB Datendateien: $fileCount - empfohlen sind $recommendedCount ($logicalCores logische Kerne, max $MaxFiles). Bitte anpassen."
                Write-Host "  WARN $message" -ForegroundColor Yellow
            }

            Invoke-sqmLogging -Message $message -FunctionName $functionName -Level $(if ($status -eq 'OK') { 'INFO' } else { 'WARNING' })

            return [PSCustomObject]@{
                SqlInstance      = $SqlInstance
                CurrentFileCount = $fileCount
                RecommendedCount = $recommendedCount
                LogicalCores     = $logicalCores
                Status           = $status
                Message          = $message
            }
        }
        catch
        {
            $errMsg = "Fehler in $functionName auf ${SqlInstance}: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw }
            Write-Error $errMsg
            return [PSCustomObject]@{
                SqlInstance      = $SqlInstance
                CurrentFileCount = $null
                RecommendedCount = $null
                LogicalCores     = $null
                Status           = 'Error'
                Message          = $errMsg
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level 'INFO'
    }
}
