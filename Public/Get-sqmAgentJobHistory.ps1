<#
.SYNOPSIS
    Zeigt die Ausfuehrungshistorie von SQL Agent Jobs an.

.DESCRIPTION
    Liefert die letzte(n) Ausfuehrung(en) aller oder ausgewaehlter SQL Agent Jobs.
    Kann nach Jobnamen, Status (Erfolg/Fehler) und Zeitraum filtern.
    Standardmaessig werden die letzten 7 Tage angezeigt.

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER JobName
    Name oder Wildcard-Muster (z.B. '*Backup*') zum Filtern von Jobs.

.PARAMETER Status
    'Success', 'Failure', 'Retry' oder 'Cancelled'. Standard: alle.

.PARAMETER Since
    Zeigt History ab diesem Datum. Standard: heute - 7 Tage.

.PARAMETER LastX
    Statt Zeitraum: Anzahl der letzten Ausfuehrungen pro Job (z.B. -LastX 5).

.PARAMETER OutputPath
    Export als CSV (optional). Wenn angegeben, wird eine CSV-Datei erstellt.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Get-sqmAgentJobHistory

.EXAMPLE
    Get-sqmAgentJobHistory -JobName '*Backup*' -Status Failure -Since (Get-Date).AddDays(-1)

.NOTES
    Erfordert dbatools und Invoke-sqmLogging.
#>
function Get-sqmAgentJobHistory {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$SqlInstance = $env:COMPUTERNAME,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,
        [Parameter(Mandatory = $false)]
        [string]$JobName = '*',
        [Parameter(Mandatory = $false)]
        [ValidateSet('Success', 'Failure', 'Retry', 'Cancelled')]
        [string]$Status,
        [Parameter(Mandatory = $false)]
        [datetime]$Since = (Get-Date).AddDays(-7),
        [Parameter(Mandatory = $false)]
        [int]$LastX,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin {
        $functionName = $MyInvocation.MyCommand.Name
        if (-not $script:dbatoolsAvailable) {
            $errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }
        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Status-Werte auf dbatools OutcomeType-Begriffe mappen
        $outcomeMap = @{
            'Success'   = 'Succeeded'
            'Failure'   = 'Failed'
            'Retry'     = 'Retry'
            'Cancelled' = 'Cancelled'
        }
    }

    process {
        try {
            # Get-DbaAgentJob unterstuetzt keine Wildcards im -Job-Parameter.
            # Daher: alle Jobs laden und anschliessend per -like filtern.
            $allJobs = Get-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
                                       -ErrorAction Stop

            $jobs = if ($JobName -eq '*') {
                $allJobs
            } else {
                $allJobs | Where-Object { $_.Name -like $JobName }
            }

            if (-not $jobs) {
                Invoke-sqmLogging -Message "Keine Jobs auf '$SqlInstance' gefunden (Filter: '$JobName')." `
                                  -FunctionName $functionName -Level "WARNING"
                return $allResults
            }

            foreach ($job in $jobs) {
                # -StartDate ist der korrekte dbatools-Parametername (nicht -Since)
                $histParams = @{
                    SqlInstance   = $SqlInstance
                    SqlCredential = $SqlCredential
                    Job           = $job.Name
                    StartDate     = $Since
                    ErrorAction   = 'Stop'
                }
                if ($Status) {
                    $histParams['OutcomeType'] = $outcomeMap[$Status]
                }

                $history = Get-DbaAgentJobHistory @histParams

                if ($LastX -and $LastX -gt 0) {
                    $history = $history | Select-Object -First $LastX
                }

                foreach ($step in $history) {
                    # Duration: dbatools kann TimeSpan oder formatierten String liefern
                    $durationStr = if ($step.Duration -is [timespan]) {
                        "$($step.Duration.Hours)h $($step.Duration.Minutes)m $($step.Duration.Seconds)s"
                    } else {
                        [string]$step.Duration
                    }

                    $allResults.Add([PSCustomObject]@{
                        JobName     = $job.Name
                        StepName    = $step.StepName
                        RunDate     = $step.RunDate
                        Outcome     = $step.Status
                        Message     = $step.Message
                        Duration    = $durationStr
                        SqlInstance = $SqlInstance
                    })
                }
            }

            if ($OutputPath) {
                $allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Force
                Invoke-sqmLogging -Message "CSV exportiert nach $OutputPath" -FunctionName $functionName -Level "INFO"
            }
            return $allResults
        }
        catch {
            $errMsg = "Fehler auf '$SqlInstance': $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw }
            return $null
        }
    }
}
