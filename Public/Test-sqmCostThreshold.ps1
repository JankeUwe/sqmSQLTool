<#
.SYNOPSIS
    Prueft ob CostThresholdForParallelism auf dem empfohlenen Wert liegt.

.DESCRIPTION
    Liest den aktuellen Wert von CostThresholdForParallelism per SMO und
    vergleicht ihn mit dem konfigurierbaren Mindestwert (Standard: 50).
    Der SQL Server Default von 5 ist fuer moderne Systeme in der Regel
    zu niedrig und fuehrt zu unnoetigem parallelen Ausfuehrungsaufwand
    bei kurzen Abfragen.

    Gibt ein PSCustomObject mit Status, aktuellem Wert und Empfehlung zurueck.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung.

.PARAMETER MinRecommendedValue
    Mindestwert fuer CostThresholdForParallelism. Standard: 50.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt Write-Error.

.OUTPUTS
    [PSCustomObject] mit den Feldern:
        SqlInstance         : Instanzname
        CurrentValue        : Aktuell konfigurierter Wert
        RecommendedMinValue : Empfohlener Mindestwert
        Status              : OK | Warning | Error
        Message             : Detailmeldung

.EXAMPLE
    Test-sqmCostThreshold -SqlInstance "SQL01"

.EXAMPLE
    Test-sqmCostThreshold -SqlInstance "SQL01" -MinRecommendedValue 25

.NOTES
    Empfehlung: Wert >= 50 fuer OLTP-Systeme. Fuer Data Warehouse ggf. hoeher.
    Aenderung: ALTER SERVER CONFIGURATION SET COST THRESHOLD FOR PARALLELISM = 50
    oder: Set-sqmServerSetting -CostThresholdForParallelism 50
#>
function Test-sqmCostThreshold
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 32767)]
        [int]$MinRecommendedValue = 50,

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

        # Grenzwert aus Modulkonfiguration lesen (ueberschreibt Parameter-Default wenn nicht explizit angegeben)
        if (-not $PSBoundParameters.ContainsKey('MinRecommendedValue'))
        {
            $cfgVal = Get-sqmConfig -Key 'CheckCostThresholdMin'
            if ($null -ne $cfgVal) { $MinRecommendedValue = [int]$cfgVal }
        }

        Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance (Min: $MinRecommendedValue)" -FunctionName $functionName -Level 'INFO'
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

            $currentValue = $server.Configuration.CostThresholdForParallelism.RunValue

            if ($currentValue -ge $MinRecommendedValue)
            {
                $status  = 'OK'
                $message = "CostThresholdForParallelism ist $currentValue - empfohlener Mindestwert ($MinRecommendedValue) erreicht."
                Write-Host "  OK   $message" -ForegroundColor Green
            }
            else
            {
                $status  = 'Warning'
                $message = "CostThresholdForParallelism ist $currentValue - empfohlener Mindestwert ist $MinRecommendedValue. Bitte anpassen."
                Write-Host "  WARN $message" -ForegroundColor Yellow
            }

            Invoke-sqmLogging -Message $message -FunctionName $functionName -Level $(if ($status -eq 'OK') { 'INFO' } else { 'WARNING' })

            return [PSCustomObject]@{
                SqlInstance         = $SqlInstance
                CurrentValue        = $currentValue
                RecommendedMinValue = $MinRecommendedValue
                Status              = $status
                Message             = $message
            }
        }
        catch
        {
            $errMsg = "Fehler in $functionName auf ${SqlInstance}: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw }
            Write-Error $errMsg
            return [PSCustomObject]@{
                SqlInstance         = $SqlInstance
                CurrentValue        = $null
                RecommendedMinValue = $MinRecommendedValue
                Status              = 'Error'
                Message             = $errMsg
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level 'INFO'
    }
}
