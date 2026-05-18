<#
.SYNOPSIS
    Aktualisiert Statistiken in einer oder mehreren Datenbanken.

.DESCRIPTION
    Fuehrt UPDATE STATISTICS mit konfigurierbaren Optionen aus (Scan?Prozentsatz, nur geaenderte Statistiken, etc.).
    Kann auf bestimmte Datenbanken, Tabellen oder Statistiken eingeschraenkt werden.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER Database
    Datenbankname oder Wildcard-Muster.

.PARAMETER Table
    Tabellenname oder Wildcard-Muster.

.PARAMETER Statistics
    Statistikname oder Wildcard-Muster.

.PARAMETER SamplePercent
    Prozentsatz der Zeilen, der fuer das Update verwendet wird (0 = Vollscan). Standard: 0.

.PARAMETER OnlyModified
    Nur Statistiken aktualisieren, die seit der letzten Aktualisierung geaendert wurden. Standard: $true.

.PARAMETER Index
    Statistiken, die mit einem Index verbunden sind, werden ebenfalls aktualisiert. Standard: $true.

.PARAMETER WhatIf
    Zeigt, welche Statistiken betroffen waeren.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 10

.NOTES
    Verwendet dbatools (Update-DbaDbStatistic).
#>
function Invoke-sqmUpdateStatistics {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        [string]$SqlInstance = $env:COMPUTERNAME,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,
        [Parameter(Mandatory = $false)]
        [string]$Database = '*',
        [Parameter(Mandatory = $false)]
        [string]$Table = '*',
        [Parameter(Mandatory = $false)]
        [string]$Statistics = '*',
        [Parameter(Mandatory = $false)]
        [int]$SamplePercent = 0,
        [Parameter(Mandatory = $false)]
        [bool]$OnlyModified = $true,
        [Parameter(Mandatory = $false)]
        [bool]$Index = $true,
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin {
        $functionName = $MyInvocation.MyCommand.Name
        if (-not (Get-Module -ListAvailable -Name dbatools)) {
            throw "dbatools-Modul nicht gefunden."
        }
    }

    process {
        try {
            $params = @{
                SqlInstance      = $SqlInstance
                SqlCredential    = $SqlCredential
                Database         = $Database
                Table            = $Table
                Statistic        = $Statistics
                SamplePercent    = $SamplePercent
                OnlyModified     = $OnlyModified
                Index            = $Index
                EnableException  = $EnableException
            }
            if ($PSCmdlet.ShouldProcess("UpdateStatistics on $SqlInstance", "Update")) {
                $result = Update-DbaDbStatistic @params
                $result | ForEach-Object {
                    [PSCustomObject]@{
                        Database   = $_.Database
                        Table      = $_.Table
                        Statistic  = $_.Statistic
                        Status     = 'Success'
                        Message    = "Updated"
                    }
                }
            } else {
                Write-Verbose "WhatIf: UpdateStatistics would be executed on $SqlInstance"
            }
        }
        catch {
            Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw }
        }
    }
}