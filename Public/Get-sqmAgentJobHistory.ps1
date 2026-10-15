<#
.SYNOPSIS
    Displays the execution history of SQL Agent jobs.

.DESCRIPTION
    Returns the last execution(s) of all or selected SQL Agent jobs.
    Can filter by job name, status (success/failure) and time range.
    By default, the last 7 days are shown.
    Writes a CSV file and an HTML report (summary per job + full history,
    failures highlighted) and returns the rows as objects.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER JobName
    Name or wildcard pattern (e.g. '*Backup*') to filter jobs.

.PARAMETER Status
    'Success', 'Failure', 'Retry' or 'Cancelled'. Default: all.

.PARAMETER Since
    Show history from this date onwards. Default: today minus 7 days.

.PARAMETER LastX
    Instead of a time range: number of last executions per job (e.g. -LastX 5).

.PARAMETER OutputPath
    Full path of the CSV file to write. Default: an auto-named file under
    <OutputPath config>\AgentJobHistory. An HTML report with the same name
    (.html) is written next to it and opened automatically.

.PARAMETER EnableException
    Throw exceptions immediately.

.PARAMETER NoOpen
    Do not open the HTML report after it has been created.

.EXAMPLE
    Get-sqmAgentJobHistory

.EXAMPLE
    Get-sqmAgentJobHistory -JobName '*Backup*' -Status Failure -Since (Get-Date).AddDays(-1)

.NOTES
    Requires dbatools and Invoke-sqmLogging.
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
        [string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) "AgentJobHistory\AgentJobHistory_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"),
        [Parameter(Mandatory = $false)]
        [switch]$EnableException,
        [Parameter(Mandatory = $false)]
        [switch]$NoOpen
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
                                       -ErrorAction Stop -EnableException

            $jobs = if ($JobName -eq '*') {
                $allJobs
            } else {
                $allJobs | Where-Object { $_.Name -like $JobName }
            }

            # Kein return hier: auch ohne Jobs wird ein (leerer) Report geschrieben.
            if (-not $jobs) {
                Invoke-sqmLogging -Message "Keine Jobs auf '$SqlInstance' gefunden (Filter: '$JobName')." `
                                  -FunctionName $functionName -Level "WARNING"
            }

            foreach ($job in @($jobs)) {
                # -StartDate ist der korrekte dbatools-Parametername (nicht -Since)
                $histParams = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Job             = $job.Name
                    StartDate       = $Since
                    ErrorAction     = 'Stop'
                    EnableException = $true
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
                # -OutputPath nennt die CSV-Datei; der HTML-Report liegt daneben mit gleichem Namen.
                # Wird eine .html-Datei angegeben, gilt dasselbe umgekehrt.
                $basePath = if ([System.IO.Path]::HasExtension($OutputPath)) {
                    Join-Path (Split-Path -Path $OutputPath -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($OutputPath))
                } else {
                    $OutputPath
                }
                $csvFile  = "$basePath.csv"
                $htmlFile = "$basePath.html"
                $parentDir = Split-Path -Path $csvFile -Parent
                if ($parentDir -and -not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
                $allResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
                Invoke-sqmLogging -Message "CSV exportiert nach $csvFile" -FunctionName $functionName -Level "INFO"

                $html = _GenerateAgentJobHistoryHtml -Results $allResults -SqlInstance $SqlInstance `
                                                     -JobName $JobName -Status $Status -Since $Since -LastX $LastX
                [System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.UTF8Encoding]::new($true))
                Invoke-sqmLogging -Message "HTML-Report erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
                Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
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

function _GenerateAgentJobHistoryHtml {
    param(
        [PSCustomObject[]]$Results,
        [string]$SqlInstance,
        [string]$JobName,
        [string]$Status,
        [datetime]$Since,
        [int]$LastX
    )

    if (-not $Results) { $Results = @() }
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    # RunDate kommt als DbaDateTime; ohne Formatierung landet die Kultur-Darstellung im Report
    $fmtDate = { param($d) if ($d) { ([datetime]$d).ToString('yyyy-MM-dd HH:mm:ss') } else { '' } }
    $classByOutcome = @{ Succeeded = 'ok'; Failed = 'crit'; Retry = 'warn'; Canceled = 'warn'; Cancelled = 'warn' }

    # Zusammenfassung je Job: massgeblich ist die Zeile "(Job outcome)" (Schritt 0), die das
    # Gesamtergebnis eines Laufs traegt. Fehlt sie (z. B. -Status filtert nur Schritte), zaehlen
    # ersatzweise alle Zeilen des Jobs.
    $summaryRows = foreach ($grp in ($Results | Group-Object JobName | Sort-Object Name)) {
        $outcomeRows = @($grp.Group | Where-Object { $_.StepName -eq '(Job outcome)' })
        # @() aussen: ein einzelner Treffer wuerde sonst zum Skalar, PSCustomObject hat unter 5.1 kein .Count
        $basis = @(if ($outcomeRows.Count -gt 0) { $outcomeRows } else { $grp.Group })
        $last = $basis | Sort-Object RunDate -Descending | Select-Object -First 1
        $failed = @($basis | Where-Object { $_.Outcome -eq 'Failed' }).Count
        $lastClass = $classByOutcome[[string]$last.Outcome]
        $lastAttr  = if ($lastClass) { " class='$lastClass'" } else { '' }
        $failAttr  = if ($failed -gt 0) { " class='num crit'" } else { " class='num'" }
        "<tr><td>$(& $enc $grp.Name)</td><td class='num'>$($basis.Count)</td><td$failAttr>$failed</td>" +
            "<td>$(& $fmtDate $last.RunDate)</td><td$lastAttr>$(& $enc $last.Outcome)</td></tr>"
    }

    $detailRows = foreach ($r in ($Results | Sort-Object @{ Expression = 'RunDate'; Descending = $true }, JobName)) {
        $cls  = $classByOutcome[[string]$r.Outcome]
        $attr = if ($cls) { " class='$cls'" } else { '' }
        "<tr><td>$(& $fmtDate $r.RunDate)</td><td>$(& $enc $r.JobName)</td><td>$(& $enc $r.StepName)</td>" +
            "<td$attr>$(& $enc $r.Outcome)</td><td class='num'>$(& $enc $r.Duration)</td><td>$(& $enc $r.Message)</td></tr>"
    }

    $filterText = "Zeitraum: ab $($Since.ToString('yyyy-MM-dd HH:mm')) | Job-Filter: $JobName"
    if ($Status) { $filterText += " | Status: $Status" }
    if ($LastX -gt 0) { $filterText += " | Letzte $LastX Eintraege je Job" }
    $failedTotal = @($Results | Where-Object { $_.Outcome -eq 'Failed' }).Count

    $body = "<p>$(& $enc $filterText)</p>" +
        "<p>Jobs: $(@($summaryRows).Count) | Eintraege: $($Results.Count) | Fehlgeschlagen: $failedTotal</p>"
    if ($Results.Count -eq 0) {
        $body += "<p>Keine Job-Historie im Zeitraum gefunden.</p>"
    } else {
        $body += "<h3>Zusammenfassung je Job</h3>" +
            "<table><tr><th>Job</th><th class='num'>Laeufe</th><th class='num'>Fehlgeschlagen</th><th>Letzter Lauf</th><th>Letztes Ergebnis</th></tr>" +
            ($summaryRows -join '') + "</table>" +
            "<h3>Verlauf</h3>" +
            "<table><tr><th>Zeitpunkt</th><th>Job</th><th>Schritt</th><th>Ergebnis</th><th class='num'>Dauer</th><th>Meldung</th></tr>" +
            ($detailRows -join '') + "</table>"
    }

    return (ConvertTo-sqmHtmlReport -Title "SQL Agent Job-Historie - $SqlInstance" `
                                    -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $body)
}
