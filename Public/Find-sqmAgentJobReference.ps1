<#
.SYNOPSIS
    Finds SQL Agent jobs whose steps execute a given stored procedure, contain a given piece of
    query text, or run against a given database.

.DESCRIPTION
    Answers the question "is there an Agent job that runs this?" - before a stored procedure is
    dropped or renamed, before a database is decommissioned, and when a table changes at night
    although no application is supposed to touch it.

    All job steps of the instance are read once from msdb.dbo.sysjobsteps and matched in
    PowerShell, deliberately NOT with a server side "command LIKE '%name%'":

      - LIKE treats '_' and '[' as pattern characters. Searching for 'usp_Load_Sales' with LIKE
        also matches 'uspXLoadYSales' - a procedure name with underscores is the normal case, so
        the server side search produces false hits exactly where it is used most.
      - LIKE has no word boundary. Searching for 'sp_Load' also hits 'sp_LoadArchive'.
      - The same read has to serve several questions (which database, called or only mentioned,
        inside a comment or not), and that classification is not expressible in a LIKE.

    Every job step is one row of msdb.dbo.sysjobsteps and the command is usually a few hundred
    bytes; reading them all costs one query and no scan of user data.

    The result is one row per MATCHING JOB STEP (not one row per occurrence), with the location
    of the most meaningful occurrence and the total number of occurrences.

    Each hit is rated instead of just being reported, because a text match alone does not prove
    that the job calls anything:

      CallType 'Execute'   - the name stands behind EXEC/EXECUTE (optionally schema- or
                             database-qualified, optionally with a return variable). This is a
                             real call.
      CallType 'Reference' - the name appears somewhere else in the command: as a table in a
                             SELECT, inside dynamic SQL, in a job step that only greps a log,
                             or as part of a longer statement.
      CallType 'Text'      - the row was produced by -SearchText, not by an object name.
      InComment $true      - the occurrence is inside a '--' or '/* */' comment, so it is
                             documentation and not a call. Comment detection does not parse
                             string literals, so a '--' inside a string is treated as a comment;
                             that is why InComment is reported and never used to drop a row.

    Which database a step works against is taken from three sources: the step's own
    database_name (TSQL steps), a 'USE <db>' inside the command, and the database part of any
    three-part name (db.schema.object). For CmdExec and PowerShell steps the sqlcmd '-d <db>'
    and '-Database <db>' arguments are read as well. -Database matches against all of them.

.PARAMETER SqlInstance
    One or more SQL Server instances (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER ObjectName
    Name of the stored procedure (or any other object) to look for. Wildcards '*' and '?' are
    allowed inside the name, and the name may be qualified: 'usp_Load*', 'dbo.usp_Load',
    'Sales.dbo.usp_Load'. A schema part restricts the hit to that schema. A database part sets
    the database filter unless -Database is given explicitly.

.PARAMETER SearchText
    Free text that has to appear in the step command, e.g. 'TRUNCATE TABLE' or 'sp_send_dbmail'.
    Compared case-insensitively as a literal substring, or as a regular expression with
    -RegexSearch. Combined with -ObjectName both conditions must match (AND).

.PARAMETER RegexSearch
    Treat -SearchText as a .NET regular expression instead of a literal substring.

.PARAMETER Database
    Database the step has to work against (wildcards allowed). Can be used on its own to list
    every job step touching a database.

.PARAMETER JobName
    Restrict the search to jobs matching this name or wildcard (default: all jobs).

.PARAMETER Subsystem
    Step types to search. Default: 'TSQL', 'CmdExec', 'PowerShell' - the three that can run a
    procedure or a query. 'All' searches every subsystem including SSIS.

.PARAMETER ExcludeDisabledJobs
    Skip disabled jobs. Off by default: a disabled job still references the object and is
    usually re-enabled at some point.

.PARAMETER IncludeCommand
    Add the complete step command to the result as 'Command'. Without it only the first 300
    characters are returned as 'CommandPreview'.

.PARAMETER VerifyObject
    For each hit found via -ObjectName, check whether the object really exists in the resolved
    database (sys.objects) and report its type. Turns "the job mentions this name" into "the job
    calls a procedure that exists / that is already gone". Costs one query per distinct
    database/name pair.

.PARAMETER EnableException
    Throw exceptions immediately instead of logging and continuing with the next instance.

.EXAMPLE
    Find-sqmAgentJobReference -SqlInstance "SQL01" -ObjectName "usp_LoadSales"

    Is there a job that runs this procedure?

.EXAMPLE
    Find-sqmAgentJobReference -SqlInstance "SQL01" -ObjectName "usp_Load*" -VerifyObject |
        Where-Object CallType -eq 'Execute' |
        Format-Table JobName, StepName, ResolvedDatabase, ObjectExists

    All real calls of the load procedures, including whether the called procedure still exists.

.EXAMPLE
    Find-sqmAgentJobReference -SqlInstance "SQL01","SQL02" -Database "Sales"

    Every job step on both instances that works against the Sales database - the check before a
    database is decommissioned.

.EXAMPLE
    Find-sqmAgentJobReference -SqlInstance "SQL01" -SearchText "TRUNCATE TABLE" -IncludeCommand

    Which job empties tables at night, with the full command for review.

.NOTES
    Requires dbatools, read access to msdb and Invoke-sqmLogging.
    JobLastRunOutcome/StepLastRunOutcome return 'NeverRun' when there is no last run. msdb stores
    a job step that has never run with last_run_outcome = 0 and last_run_date = 0, and 0 is also
    the code for 'Failed' - taking the outcome at face value would report every freshly created
    job as failed.
    Only job steps stored on the instance are searched. A procedure called indirectly - from
    another procedure, from an SSIS package, from a CLR assembly or through dynamic SQL built at
    runtime - cannot be seen in the step command; Find-sqmDatabaseObject -SearchDefinition covers
    the call chain inside the databases.

.LINK
    Get-sqmAgentJobScheduleReport
    Get-sqmAgentJobHistory
    Find-sqmDatabaseObject
    Get-sqmLinkedServerUsage
#>
function Find-sqmAgentJobReference {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]$SqlInstance = $env:COMPUTERNAME,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [string]$ObjectName,

        [Parameter(Mandatory = $false)]
        [string]$SearchText,

        [Parameter(Mandatory = $false)]
        [switch]$RegexSearch,

        [Parameter(Mandatory = $false)]
        [string]$Database,

        [Parameter(Mandatory = $false)]
        [string]$JobName = '*',

        [Parameter(Mandatory = $false)]
        [ValidateSet('TSQL', 'CmdExec', 'PowerShell', 'SSIS', 'ANALYSISQUERY', 'ANALYSISCOMMAND',
                     'Snapshot', 'Distribution', 'LogReader', 'Merge', 'QueueReader', 'All')]
        [string[]]$Subsystem = @('TSQL', 'CmdExec', 'PowerShell'),

        [Parameter(Mandatory = $false)]
        [switch]$ExcludeDisabledJobs,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeCommand,

        [Parameter(Mandatory = $false)]
        [switch]$VerifyObject,

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

        if (-not $ObjectName -and -not $SearchText -and -not $Database) {
            Invoke-sqmLogging -Message "Weder -ObjectName noch -SearchText noch -Database angegeben - es werden ALLE Jobsteps der gewaehlten Subsysteme zurueckgegeben (Inventar)." `
                              -FunctionName $functionName -Level "WARNING"
        }
        if ($VerifyObject -and -not $ObjectName) {
            Invoke-sqmLogging -Message "-VerifyObject ohne -ObjectName bleibt wirkungslos (es gibt keinen Objektnamen zu pruefen)." `
                              -FunctionName $functionName -Level "WARNING"
        }

        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Ergebnisse von -VerifyObject je Instanz/Datenbank/Objekt zwischenspeichern. Ein Objekt,
        # das von zehn Jobsteps aufgerufen wird, wuerde sonst zehnmal identisch nachgeschlagen.
        $objectCache = @{ }

        $rxCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        $rxMulti = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
                   [System.Text.RegularExpressions.RegexOptions]::Singleline

        # Wildcards in einen Regex-Teilausdruck uebersetzen. .Replace() statt -replace, weil der
        # Ersatztext '$' enthaelt und -replace darin ein .NET-Ersetzungsmuster sehen wuerde.
        $wildcardToRegex = {
            param ([string]$Token)
            return [regex]::Escape($Token).Replace('\*', '[\w@#$]*').Replace('\?', '[\w@#$]')
        }

        # Identifier-Grenzen. \b genuegt nicht: der Name kann in eckigen Klammern stehen, und ']'
        # ist kein Wortzeichen - \b wuerde dort nicht greifen.
        $boundaryBefore = '(?<![\w@#$])'
        $boundaryAfter = '(?![\w@#$])'

        $objSimple = $null
        $objSchema = $null
        $objRegex = $null
        $execRegex = $null

        if ($ObjectName) {
            # Qualifizierten Namen zerlegen und dabei Klammern respektieren:
            # '[Sales].[dbo].[usp Load]' hat drei Teile, ein Punkt IN den Klammern trennt nicht.
            $parts = @([regex]::Matches($ObjectName, '\[[^\]]+\]|[^.\[\]]+') |
                       ForEach-Object { (($_.Value.Trim() -replace '^\[', '') -replace '\]$', '') } |
                       Where-Object { $_ -ne '' })

            if ($parts.Count -eq 0) {
                $errMsg = "-ObjectName '$ObjectName' enthaelt keinen verwertbaren Objektnamen."
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                throw $errMsg
            }

            $objSimple = $parts[$parts.Count - 1]
            if ($parts.Count -ge 2) { $objSchema = $parts[$parts.Count - 2] }
            if ($parts.Count -ge 3 -and -not $Database) {
                # Dreiteiliger Name ohne expliziten -Database-Filter: der Datenbankteil IST der
                # Filter. Sonst wuerde 'Sales.dbo.usp_Load' auch Treffer in Archive.dbo.usp_Load
                # liefern, obwohl der Aufrufer die Datenbank genannt hat.
                $Database = $parts[$parts.Count - 3]
                Invoke-sqmLogging -Message "Datenbankteil aus -ObjectName uebernommen: -Database '$Database'." `
                                  -FunctionName $functionName -Level "INFO"
            }

            $objCore = & $wildcardToRegex $objSimple
            $schemaPrefix = ''
            if ($objSchema) {
                $schemaPrefix = '\[?' + (& $wildcardToRegex $objSchema) + '\]?\s*\.\s*'
            }

            $objRegex = [regex]::new(
                $boundaryBefore + $schemaPrefix + '\[?' + $objCore + '\]?' + $boundaryAfter, $rxCase)

            # Aufrufform: EXEC/EXECUTE, optional mit Rueckgabevariable und bis zu zwei
            # Qualifizierern (db.schema.objekt). Der Ausdruck endet auf demselben Objektnamen wie
            # $objRegex - dadurch lassen sich beide Trefferlisten ueber die Endposition verbinden.
            $execRegex = [regex]::new(
                '\b(?:EXEC|EXECUTE)\b\s+(?:@[\w@#$]+\s*=\s*)?(?:(?:\[[^\]]+\]|[\w@#$]+)\s*\.\s*){0,2}' +
                '\[?' + $objCore + '\]?' + $boundaryAfter, $rxCase)
        }

        $textRegex = $null
        if ($SearchText) {
            if ($RegexSearch) {
                try {
                    $textRegex = [regex]::new($SearchText, $rxMulti)
                }
                catch {
                    $errMsg = "-SearchText ist kein gueltiger regulaerer Ausdruck: $($_.Exception.Message)"
                    Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                    throw $errMsg
                }
            }
            else {
                $textRegex = [regex]::new([regex]::Escape($SearchText), $rxMulti)
            }
        }

        # Kommentare, USE-Anweisungen, dreiteilige Namen und sqlcmd-/PowerShell-Datenbankargumente.
        $commentRegex = [regex]::new('/\*.*?\*/|--[^\r\n]*', $rxMulti)
        $useRegex = [regex]::new('\bUSE\s+(\[[^\]]+\]|[\w@#$]+)', $rxCase)
        $threePartRegex = [regex]::new('(\[[^\]]+\]|[\w@#$]+)\s*\.\s*(?:\[[^\]]+\]|[\w@#$]*)\s*\.\s*(?:\[[^\]]+\]|[\w@#$]+)', $rxCase)
        $sqlcmdDbRegex = [regex]::new('(?:^|\s)-d\s+"?(\[[^\]]+\]|[^\s"'']+)', $rxCase)
        $psDbRegex = [regex]::new('-Database\s+["'']?(\[[^\]]+\]|[\w@#$]+)', $rxCase)

        # Qualifizierer unmittelbar VOR dem Treffer, um die Datenbank eines dreiteiligen Aufrufs
        # genau diesem Treffer zuzuordnen statt irgendeiner im Kommando vorkommenden Datenbank.
        $qualBeforeRegex = [regex]::new('(\[[^\]]+\]|[\w@#$]+)\s*\.\s*(?:\[[^\]]+\]|[\w@#$]*)\s*\.\s*$', $rxCase)
        $qualBeforeSchemaRegex = [regex]::new('(\[[^\]]+\]|[\w@#$]+)\s*\.\s*$', $rxCase)

        $stripBrackets = {
            param ([string]$Value)
            if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
            return (($Value.Trim() -replace '^\[', '') -replace '\]$', '')
        }

        # msdb speichert Datum und Uhrzeit als getrennte Ganzzahlen (20260907 / 143000).
        $toDateTime = {
            param ($DatePart, $TimePart)
            if ($null -eq $DatePart -or $DatePart -is [DBNull]) { return $null }
            $d = [int]$DatePart
            if ($d -le 0) { return $null }
            $t = 0
            if ($null -ne $TimePart -and $TimePart -isnot [DBNull]) { $t = [int]$TimePart }
            try {
                return [datetime]::ParseExact(('{0:00000000}{1:000000}' -f $d, $t), 'yyyyMMddHHmmss', $null)
            }
            catch { return $null }
        }

        $outcomeMap = @{
            0 = 'Failed'; 1 = 'Succeeded'; 2 = 'Retry'; 3 = 'Cancelled'; 4 = 'InProgress'; 5 = 'Unknown'
        }

        $stepQuery = @'
;WITH LastJobRun AS (
    SELECT
        jh.job_id, jh.run_status, jh.run_date, jh.run_time,
        ROW_NUMBER() OVER (PARTITION BY jh.job_id ORDER BY jh.instance_id DESC) AS rn
    FROM msdb.dbo.sysjobhistory jh
    WHERE jh.step_id = 0
),
ScheduleAgg AS (
    SELECT
        sjs.job_id,
        COUNT(*) AS ScheduleCount,
        SUM(CASE WHEN ss.enabled = 1 THEN 1 ELSE 0 END) AS ActiveScheduleCount,
        MIN(CASE WHEN ss.enabled = 1 AND sjs.next_run_date > 0
                 THEN CAST(sjs.next_run_date AS BIGINT) * 1000000 + sjs.next_run_time END) AS NextRunKey
    FROM msdb.dbo.sysjobschedules sjs
    JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
    GROUP BY sjs.job_id
)
SELECT
    sj.name                           AS JobName,
    sj.enabled                        AS JobEnabled,
    SUSER_SNAME(sj.owner_sid)         AS JobOwner,
    ISNULL(sc.name, '')               AS JobCategory,
    ISNULL(sa.ScheduleCount, 0)       AS ScheduleCount,
    ISNULL(sa.ActiveScheduleCount, 0) AS ActiveScheduleCount,
    sa.NextRunKey                     AS NextRunKey,
    ljr.run_status                    AS JobLastRunStatus,
    ljr.run_date                      AS JobLastRunDate,
    ljr.run_time                      AS JobLastRunTime,
    st.step_id                        AS StepId,
    st.step_name                      AS StepName,
    st.subsystem                      AS Subsystem,
    st.database_name                  AS StepDatabase,
    st.last_run_outcome               AS StepLastRunOutcome,
    st.last_run_date                  AS StepLastRunDate,
    st.last_run_time                  AS StepLastRunTime,
    st.command                        AS Command
FROM msdb.dbo.sysjobsteps st
JOIN msdb.dbo.sysjobs sj            ON sj.job_id = st.job_id
LEFT JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
LEFT JOIN ScheduleAgg sa            ON sa.job_id = sj.job_id
LEFT JOIN LastJobRun ljr            ON ljr.job_id = sj.job_id AND ljr.rn = 1
ORDER BY sj.name, st.step_id
'@
    }

    process {
        foreach ($instance in $SqlInstance) {
            try {
                Invoke-sqmLogging -Message "Durchsuche Agent-Jobsteps auf '$instance' (Objekt: '$ObjectName', Text: '$SearchText', Datenbank: '$Database')." `
                                  -FunctionName $functionName -Level "INFO"

                $connParams = @{ SqlInstance = $instance; Database = 'msdb' }
                if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

                $rows = @(Invoke-DbaQuery @connParams -Query $stepQuery -EnableException -As PSObject)

                if ($rows.Count -eq 0) {
                    Invoke-sqmLogging -Message "Keine Agent-Jobsteps auf '$instance' vorhanden." `
                                      -FunctionName $functionName -Level "WARNING"
                    continue
                }

                foreach ($row in $rows) {
                    if ($JobName -ne '*' -and $row.JobName -notlike $JobName) { continue }

                    $jobEnabled = [bool]$row.JobEnabled
                    if ($ExcludeDisabledJobs -and -not $jobEnabled) { continue }

                    if ($Subsystem -notcontains 'All') {
                        $subMatch = $false
                        foreach ($s in $Subsystem) {
                            if ($row.Subsystem -and ([string]$row.Subsystem) -ieq $s) { $subMatch = $true; break }
                        }
                        if (-not $subMatch) { continue }
                    }

                    $command = ''
                    if ($null -ne $row.Command -and $row.Command -isnot [DBNull]) { $command = [string]$row.Command }

                    $stepDb = $null
                    if ($null -ne $row.StepDatabase -and $row.StepDatabase -isnot [DBNull]) {
                        $stepDb = ([string]$row.StepDatabase).Trim()
                        if ($stepDb -eq '') { $stepDb = $null }
                    }

                    # --------------------------------------------------------------
                    # Datenbanken bestimmen, gegen die dieser Step arbeitet.
                    # --------------------------------------------------------------
                    $referenced = [System.Collections.Generic.List[string]]::new()
                    if ($stepDb) { $referenced.Add($stepDb) }
                    foreach ($rx in @($useRegex, $sqlcmdDbRegex, $psDbRegex)) {
                        foreach ($m in $rx.Matches($command)) {
                            $db = & $stripBrackets $m.Groups[1].Value
                            if ($db -and -not ($referenced -contains $db)) { $referenced.Add($db) }
                        }
                    }
                    foreach ($m in $threePartRegex.Matches($command)) {
                        $db = & $stripBrackets $m.Groups[1].Value
                        if ($db -and -not ($referenced -contains $db)) { $referenced.Add($db) }
                    }

                    if ($Database) {
                        $dbHit = $false
                        foreach ($db in $referenced) {
                            if ($db -like $Database) { $dbHit = $true; break }
                        }
                        if (-not $dbHit) { continue }
                    }

                    # --------------------------------------------------------------
                    # Fundstellen suchen und bewerten.
                    # --------------------------------------------------------------
                    $objMatches = @()
                    if ($objRegex) {
                        $objMatches = @($objRegex.Matches($command))
                        if ($objMatches.Count -eq 0) { continue }
                    }

                    $textMatches = @()
                    if ($textRegex) {
                        $textMatches = @($textRegex.Matches($command))
                        if ($textMatches.Count -eq 0) { continue }
                    }

                    $commentRanges = @($commentRegex.Matches($command) |
                                       ForEach-Object { [PSCustomObject]@{ Start = $_.Index; End = $_.Index + $_.Length } })
                    $execEnds = @()
                    if ($execRegex) { $execEnds = @($execRegex.Matches($command) | ForEach-Object { $_.Index + $_.Length }) }

                    # Nur die aussagekraeftigste Fundstelle wird berichtet. Rangfolge: eine
                    # Fundstelle ausserhalb eines Kommentars zaehlt IMMER mehr als eine im
                    # Kommentar (auch mehr als ein auskommentiertes EXEC - der Job fuehrt es
                    # nicht aus), innerhalb derselben Kategorie schlaegt der Aufruf die blosse
                    # Erwaehnung. Daher Gewicht 2 fuer "kein Kommentar", 1 fuer "EXEC".
                    $candidates = if ($objMatches.Count -gt 0) { $objMatches } else { $textMatches }
                    $best = $null
                    $bestRank = -1
                    $bestIsExec = $false
                    $bestInComment = $false

                    foreach ($m in $candidates) {
                        $inComment = $false
                        foreach ($r in $commentRanges) {
                            if ($m.Index -ge $r.Start -and $m.Index -lt $r.End) { $inComment = $true; break }
                        }
                        $isExec = ($execEnds -contains ($m.Index + $m.Length))

                        $rank = 0
                        if (-not $inComment) { $rank += 2 }
                        if ($isExec) { $rank += 1 }

                        if ($rank -gt $bestRank) {
                            $bestRank = $rank
                            $best = $m
                            $bestIsExec = $isExec
                            $bestInComment = $inComment
                        }
                        if ($bestRank -eq 3) { break }
                    }

                    $callType = 'Text'
                    if ($objMatches.Count -gt 0) {
                        $callType = if ($bestIsExec) { 'Execute' } else { 'Reference' }
                    }

                    $matchLine = 0
                    $lineText = ''
                    if ($best) {
                        $matchLine = ([regex]::Matches($command.Substring(0, $best.Index), "`n")).Count + 1
                        $lines = $command -split "`r`n|`n|`r"
                        if ($matchLine -le $lines.Count) {
                            $lineText = $lines[$matchLine - 1].Trim()
                            if ($lineText.Length -gt 200) { $lineText = $lineText.Substring(0, 200) + '...' }
                        }
                    }

                    # --------------------------------------------------------------
                    # Datenbank des Treffers: der Qualifizierer unmittelbar davor gewinnt,
                    # sonst die Datenbank des Steps, sonst die erste referenzierte.
                    # --------------------------------------------------------------
                    $resolvedDb = $stepDb
                    if ($best -and $objMatches.Count -gt 0) {
                        $lookBackStart = [math]::Max(0, $best.Index - 200)
                        $before = $command.Substring($lookBackStart, $best.Index - $lookBackStart)
                        $qm = if ($objSchema) { $qualBeforeSchemaRegex.Match($before) } else { $qualBeforeRegex.Match($before) }
                        if ($qm.Success) {
                            $qDb = & $stripBrackets $qm.Groups[1].Value
                            if ($qDb) { $resolvedDb = $qDb }
                        }
                    }
                    if (-not $resolvedDb -and $referenced.Count -gt 0) { $resolvedDb = $referenced[0] }

                    # --------------------------------------------------------------
                    # Optional: existiert das gefundene Objekt dort ueberhaupt?
                    # --------------------------------------------------------------
                    $objectExists = $null
                    $objectType = $null
                    $matchedName = $null
                    if ($best -and $objMatches.Count -gt 0) {
                        $matchedName = & $stripBrackets (($best.Value -split '\.')[-1])
                    }

                    if ($VerifyObject -and $matchedName -and $resolvedDb) {
                        $cacheKey = "$instance|$resolvedDb|$matchedName"
                        if ($objectCache.ContainsKey($cacheKey)) {
                            $objectExists = $objectCache[$cacheKey].Exists
                            $objectType = $objectCache[$cacheKey].Type
                        }
                        else {
                            try {
                                $safeName = $matchedName -replace "'", "''"
                                $verifyQuery = "SELECT TOP 1 o.type_desc AS ObjectType FROM sys.objects o WHERE o.name = N'$safeName'"
                                $verifyParams = @{ SqlInstance = $instance; Database = $resolvedDb }
                                if ($SqlCredential) { $verifyParams['SqlCredential'] = $SqlCredential }
                                $found = @(Invoke-DbaQuery @verifyParams -Query $verifyQuery -EnableException -As PSObject)
                                $objectExists = ($found.Count -gt 0)
                                if ($objectExists) { $objectType = [string]$found[0].ObjectType }
                            }
                            catch {
                                # Datenbank offline, umbenannt oder keine Berechtigung: das ist ein
                                # Befund ueber die Pruefung, nicht ueber den Job - die Fundstelle
                                # bleibt gueltig und wird mit ObjectExists = $null gemeldet.
                                Invoke-sqmLogging -Message "Objektpruefung fuer '$matchedName' in '$resolvedDb' auf '$instance' nicht moeglich: $($_.Exception.Message)" `
                                                  -FunctionName $functionName -Level "WARNING"
                                $objectExists = $null
                            }
                            $objectCache[$cacheKey] = [PSCustomObject]@{ Exists = $objectExists; Type = $objectType }
                        }
                    }

                    $matchType = @()
                    if ($objMatches.Count -gt 0) { $matchType += 'Object' }
                    if ($textMatches.Count -gt 0) { $matchType += 'Text' }
                    if ($matchType.Count -eq 0) {
                        if ($Database) { $matchType += 'Database' } else { $matchType += 'All' }
                    }

                    $matchedTerm = $Database
                    if ($objMatches.Count -gt 0) { $matchedTerm = $ObjectName }
                    elseif ($textMatches.Count -gt 0) { $matchedTerm = $SearchText }

                    $nextRun = $null
                    if ($null -ne $row.NextRunKey -and $row.NextRunKey -isnot [DBNull]) {
                        $key = [int64]$row.NextRunKey
                        $nextRun = & $toDateTime ([int]([math]::Floor($key / 1000000))) ([int]($key % 1000000))
                    }

                    # Ein Step, der noch NIE gelaufen ist, steht in msdb mit last_run_outcome = 0
                    # und last_run_date = 0 - und 0 bedeutet sonst 'Failed'. Ohne diese Pruefung
                    # meldet jeder frisch angelegte Job einen fehlgeschlagenen letzten Lauf
                    # (gegen einen echten SQL Server verifiziert: acht Ola-Jobs ohne Historie
                    # kamen alle als 'Failed' zurueck). Der Zeitstempel entscheidet, nicht der
                    # Ergebniscode: ohne Datum gab es keinen Lauf.
                    $jobLastRun = & $toDateTime $row.JobLastRunDate $row.JobLastRunTime
                    $stepLastRun = & $toDateTime $row.StepLastRunDate $row.StepLastRunTime

                    $jobOutcome = 'NeverRun'
                    if ($jobLastRun -and $null -ne $row.JobLastRunStatus -and $row.JobLastRunStatus -isnot [DBNull]) {
                        $jobOutcome = $outcomeMap[[int]$row.JobLastRunStatus]
                    }
                    $stepOutcome = 'NeverRun'
                    if ($stepLastRun -and $null -ne $row.StepLastRunOutcome -and $row.StepLastRunOutcome -isnot [DBNull]) {
                        $stepOutcome = $outcomeMap[[int]$row.StepLastRunOutcome]
                    }

                    $matchedText = $null
                    if ($best) { $matchedText = $best.Value }

                    $preview = $command
                    if ($command.Length -gt 300) { $preview = $command.Substring(0, 300) + '...' }

                    $result = [PSCustomObject]@{
                        SqlInstance         = $instance
                        JobName             = [string]$row.JobName
                        JobEnabled          = $jobEnabled
                        JobOwner            = [string]$row.JobOwner
                        JobCategory         = [string]$row.JobCategory
                        IsScheduled         = ([int]$row.ActiveScheduleCount -gt 0)
                        ScheduleCount       = [int]$row.ScheduleCount
                        NextRunDate         = $nextRun
                        JobLastRunDate      = $jobLastRun
                        JobLastRunOutcome   = $jobOutcome
                        StepId              = [int]$row.StepId
                        StepName            = [string]$row.StepName
                        Subsystem           = [string]$row.Subsystem
                        StepDatabase        = $stepDb
                        ResolvedDatabase    = $resolvedDb
                        ReferencedDatabases = ($referenced -join ', ')
                        StepLastRunDate     = $stepLastRun
                        StepLastRunOutcome  = $stepOutcome
                        MatchType           = ($matchType -join '+')
                        MatchedTerm         = $matchedTerm
                        MatchedText         = $matchedText
                        MatchedObject       = $matchedName
                        CallType            = $callType
                        InComment           = $bestInComment
                        ObjectMatchCount    = $objMatches.Count
                        TextMatchCount      = $textMatches.Count
                        MatchLine           = $matchLine
                        LineText            = $lineText
                        ObjectExists        = $objectExists
                        ObjectType          = $objectType
                        CommandPreview      = $preview
                    }

                    if ($IncludeCommand) {
                        $result | Add-Member -MemberType NoteProperty -Name 'Command' -Value $command
                    }

                    $allResults.Add($result)
                }
            }
            catch {
                Invoke-sqmLogging -Message "Fehler auf Instanz '$instance': $($_.Exception.Message)" `
                                  -FunctionName $functionName -Level "ERROR"
                if ($EnableException) { throw }
            }
        }
    }

    end {
        $execCount = @($allResults | Where-Object { $_.CallType -eq 'Execute' }).Count
        Invoke-sqmLogging -Message "$functionName abgeschlossen: $($allResults.Count) Treffer, davon $execCount echte EXEC-Aufrufe." `
                          -FunctionName $functionName -Level "INFO"
        return $allResults
    }
}
