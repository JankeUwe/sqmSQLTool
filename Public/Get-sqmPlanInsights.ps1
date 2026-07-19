<#
.SYNOPSIS
  Parse SQL Server ShowPlan XML (.sqlplan / .xml) and output advanced performance insights.

.DESCRIPTION
  Get-sqmPlanInsights acts as an automated query tuning consultant. It parses execution
  plans to identify Cardinality Estimation (CE) mismatches, TempDB spills, SARGability
  violations, implicit conversions, and parameter sniffing risks. v9 adds CE model
  version reporting (legacy CE 70 detection) and query/table hint detection.

  v10 is a correctness overhaul:
  - Seek/scan/lookup access classification fixed at the root: showplan XML represents
    all three as <IndexScan>, distinguished by <SeekPredicates> and Lookup="1"; the
    old ./sp:IndexSeek branch could never match, so every seek reported as a scan.
  - CE "LikelyContributors" made lookup- and rebind-aware (lookup volume = outer join
    input, not a scan; inner-side seeks scale with executions).
  - Seek-predicate renderer rewritten: equality keys (<Prefix ScanType="EQ">) render
    as "column = value"; GT/GE/LT/LE ScanTypes honoured on range seeks (GE/LE pairs
    collapse to BETWEEN, GT/LT pairs correctly refuse it); end-only ranges handled;
    double-bracketed names fixed (Table/Schema/Database attributes arrive pre-bracketed).
  - Clustering-key columns no longer reported as INCLUDE gaps (implicitly present in
    every nonclustered index).
  - Batch-qualified statement identity: StatementId restarts per <Batch>, so
    multi-batch plans key statements as "batch.statement" (e.g. 2.1) in the CE model
    grid, hint signals, and the chooser.
  - Wait stats and the spill-marker scan scoped to the chosen statement (no more
    cross-statement bleed); memory-grant suggestion gated on non-zero values.
  - Column-side vs parameter-side CONVERT_IMPLICIT distinction throughout:
    parameter-side conversions are converted once and don't block seeks, so they
    report as "usually benign" instead of raising the non-SARGable alarm.
  - New always-visible "Access predicates" section: healthy plans display their
    rendered seek/residual predicates too (previously only visible when CE was wrong).
  - Multi-statement chooser reworked: sniffing evidence (compiled<>runtime mismatch)
    first, then ACTUAL elapsed time from QueryTimeStats, then estimated subtree cost;
    the old runtime-parameter-count tiebreaker favoured auto-parameterized trivial
    statements over expensive unparameterized ones. The report states why a statement
    was chosen, lists the others ranked by the same keys, and a new -Statement
    parameter overrides the selection (e.g. -Statement "2.1").
  - Top-operators grid shows a shortened Object column ([Table] ([Index])) so the
    object survives console-width truncation.
  - -OutFile bundles are stamped with the run date/time (plan_yyyyMMdd_HHmmss.json);
    wait-stats section prints an explicit empty state.
  - Fixed the auto-generated OPTIMIZE FOR mitigation scripts producing invalid T-SQL
    for string-typed sniffed parameters: ParameterCompiledValue/RuntimeValue for an
    nvarchar/varchar parameter arrive pre-quoted from the plan XML (N'value'), and
    the generator was unconditionally re-wrapping them in another N'...', producing
    N'N'value''. Numeric parameters were unaffected (they arrive unquoted).

  Two primary modes of operation:
    1. Offline File Parsing   - Analyze a static .xml or .sqlplan file.
    2. Telemetry & Regression - Connect to the database to append real-time Query Store
                                metrics to the analysis, and automatically generate
                                plan-forcing scripts if regressions are found.

    License: MIT. See LICENCE in dbastuff folder - https://github.com/rafinnerty/dbaStuff

.PARAMETER Path
  Path to the .sqlplan or .xml execution plan file to analyze.

.PARAMETER ServerInstance
  Target SQL Server instance for optional Query Store telemetry / database inspection.

.PARAMETER Database
  Target database (required with -ServerInstance / -InspectDatabase).

.PARAMETER InspectDatabase
  Connect to the database to inspect existing indexes, statistics staleness, and
  missing-index coverage. Requires -ServerInstance and -Database.

.PARAMETER SqlCredential
  PSCredential for SQL Server Authentication (passed through to dbatools).

.PARAMETER Statement
  Analyse a specific statement in a multi-statement plan instead of the
  automatically chosen one. Use the batch-qualified key printed in the report
  and the CE model grid (e.g. -Statement "1.1"). If the key is not found, the
  available keys are listed and automatic selection is used.

.PARAMETER OutFile
  Emit a self-contained sqlplan-insights JSON bundle (plan XML + analysis summary +
  live-database inspection, including any Query Store regressions) to this path, for
  loading into the HTML Plan Visualizer. Pair with -InspectDatabase to populate the
  index / statistics / coverage / Query Store sections.

.PARAMETER ShowAllHeuristicMatches
  List every matching operator for heuristic sections instead of deduplicated/grouped findings.

.PARAMETER CEMismatchRatio
  Cardinality estimate mismatch ratio threshold (default 10).

.PARAMETER CEMinRows
  Minimum row count before a CE mismatch is flagged (default 10).

.EXAMPLE
  Get-sqmPlanInsights -Path ".\Execution plan.xml"
  Standard offline file analysis.

.EXAMPLE
  Get-sqmPlanInsights -Path ".\Execution plan.xml" -ServerInstance "PROD-SQL-01" -Database "StackOverflow2013" -InspectDatabase
  File analysis plus Query Store telemetry and a live missing-index / index coverage check.

.EXAMPLE
  Get-sqmPlanInsights -Path ".\Execution plan.xml" -ServerInstance "PROD-SQL-01" -Database "StackOverflow2013" -InspectDatabase -OutFile ".\plan.json"
  As above, and writes a JSON bundle you can open directly in the HTML Plan Visualizer.

.EXAMPLE
  $cred = Get-Credential
  Get-sqmPlanInsights -ServerInstance "192.168.1.195" -Database "StackOverflow" -SqlCredential $cred
  Connect using SQL Server Authentication (via dbatools) instead of integrated security.

.EXAMPLE
  Get-sqmPlanInsights -Path ".\Execution plan.xml" -ShowAllHeuristicMatches
  Show every matching operator for heuristic sections rather than grouped summaries.

.EXAMPLE
  Get-sqmPlanInsights -Path ".\Execution plan.xml" -CEMismatchRatio 5 -CEMinRows 50
  Tighten CE mismatch sensitivity: flag operators with a >5x estimate ratio and at least 50 rows.

.NOTES
  - Requires the 'dbatools' module if connecting to a database for telemetry/inspection.
  - Missing-index suggestions are intelligently merged to prevent bloat.
  - Parameter sniffing test scripts (OPTION RECOMPILE, OPTIMIZE FOR) are auto-generated.
  - AI was used A LOT to create this script - resistance is futile, etc.

  CE Severity Scoring (v6 — revised per Joe Chang feedback)
  --------------------------------------------------------
  The predecessor used (1 + $estCost) as a severity multiplier. Joe Chang pointed out this
  was fundamentally flawed: the optimizer's cost model is page-weighted, not row-weighted.
  For the same number of rows touched, actual CPU difference between a fat clustered index
  scan and a narrow nonclustered scan is modest — but estimated cost differs enormously due
  to page-count ratio. Using $estCost therefore injected the optimizer's own page bias into
  a metric designed to critique the optimizer's decisions.

  v6 replaces this with a three-factor, runtime-evidence-only model:

      $severity = $baseSeverity * ($cpuVolumeWeight + 1) * $wasteMultiplier
      $baseSeverity    - log-scaled CE mismatch ratio x row magnitude. How badly did the
                         optimizer guess, and at what scale?
      $cpuVolumeWeight - Log10($touchedRows + 1), where $touchedRows prefers RowsRead
                         (actual physical rows evaluated) over ActRows. Reflects true CPU
                         work independent of page cost.
      $wasteMultiplier - 1 + Log10(RowsRead / ActRows). Penalises operators that scan large
                         numbers of rows through residual predicates but pass very few — the
                         "rows scanned not meeting predicates" signal Joe highlighted.

  $estCost is not referenced anywhere in this formula. Severity is now entirely a function
  of runtime evidence.
  Origin
  ------
  Adapted from Get-SqlPlanInsights in rafinnerty/dbaStuff (https://github.com/rafinnerty/dbaStuff),
  MIT License, Copyright (c) 2026 Richard Armstrong-Finnerty. Used with the author's permission.
  See THIRD-PARTY-NOTICES.md in the module root for the full license text.
  Parsing/heuristic logic is unmodified from the upstream v10; only the function name, this
  attribution note, and the dbatools-availability check below were adapted for sqmSQLTool.
#>

function Get-sqmPlanInsights {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [string]$Path = '',

    [int]$TopOperators = 15,

    # Cardinality estimate mismatch thresholds
    [double]$CEMismatchRatio = 10,
    [double]$CEMinRows = 10,

    # Lookup call volume heuristic
    [double]$LookupCallsThreshold = 10000,

    # Optional: DB inspection
    [string]$ServerInstance,
    [string]$Database,
    [switch]$InspectDatabase,
    [pscredential]$SqlCredential, # <--- NEW: For SQL Authentication

    # v10: analyse a specific statement instead of the auto-chosen one.
    # Accepts the batch-qualified key shown in the report (e.g. "1.1"), or the
    # plain StatementId for single-batch plans.
    [string]$Statement = '',

    # Output: emit a sqlplan-insights JSON bundle for the HTML Plan Visualizer
    [string]$OutFile = '',


    # Diagnostics
    [switch]$IncludeOperatorRows,
    [switch]$SanityCheck,

    # Output: show each matching operator (ungrouped) for heuristic sections
    [switch]$ShowAllHeuristicMatches,

    # Debug SARGability detection
    [switch]$DebugSargability
  )

  Write-Output 'v10'

  $functionName = $MyInvocation.MyCommand.Name
  try { Invoke-sqmLogging -Message ("Starte " + $functionName + " -Path " + $Path) -FunctionName $functionName -Level "INFO" } catch { }

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "No plan file specified. Use -Path to supply a .sqlplan or .xml file."
  }

  # IMPORTANT: when calling .NET APIs like XmlDocument.Load(), relative paths are resolved using
  # the process working directory (often C:\Windows\System32), NOT PowerShell's current location.
  # Resolve to a full filesystem path first to avoid surprising file-not-found errors.
  $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  if (-not (Test-Path -LiteralPath $resolvedPath)) { throw "File not found: $resolvedPath" }

  $xml = New-Object System.Xml.XmlDocument
  $xml.PreserveWhitespace = $false
  $xml.Load($resolvedPath)
  $nsUri = $xml.DocumentElement.NamespaceURI
  if ([string]::IsNullOrWhiteSpace($nsUri)) { throw "Could not detect ShowPlan XML namespace. Is this a SQL Server plan file?" }

  $nsm = New-Object System.Xml.XmlNamespaceManager ($xml.NameTable)
  $nsm.AddNamespace("sp",$nsUri)

  $rootForSelect = $xml

  # v10: StatementId restarts inside every <Batch>, so a .sqlplan captured
  # from a script with GO separators yields colliding ids — three batches all
  # reporting "StatementId 1" in the CE model grid, hint signals, and the
  # statement chooser. Key statements as "<batchOrdinal>.<StatementId>" whenever
  # the file contains more than one batch; single-batch plans keep the plain id
  # so existing output and regression baselines are unchanged.
  $script:v13BatchNodes = @($xml.SelectNodes("//sp:Batch",$nsm))
  $script:v13MultiBatch = ($script:v13BatchNodes.Count -gt 1)
  $script:v13BatchOrdinals = @{}
  for ($bi = 0; $bi -lt $script:v13BatchNodes.Count; $bi++) {
    $script:v13BatchOrdinals[$script:v13BatchNodes[$bi]] = ($bi + 1)
  }
  function Get-StmtKey ($stmtNode) {
    if (-not $stmtNode) { return "" }
    $sid = [string]$stmtNode.GetAttribute("StatementId")
    if (-not $script:v13MultiBatch) { return $sid }
    $b = $stmtNode.SelectSingleNode("ancestor::sp:Batch[1]",$nsm)
    $bo = if ($b -ne $null -and $script:v13BatchOrdinals.ContainsKey($b)) { $script:v13BatchOrdinals[$b] } else { "?" }
    return ("{0}.{1}" -f $bo,$sid)
  }

  function Normalize-XPath ([string]$xpath) {
    if ([string]::IsNullOrWhiteSpace($xpath)) { return $xpath }
    # When we scope $rootForSelect to a <StmtSimple>, absolute XPaths (starting with / or //)
    # still evaluate from the document root. Rewrite them to be relative to the chosen statement.
    if ($xpath.StartsWith('//')) { return '.' + $xpath }
    if ($xpath.StartsWith('/')) { return '.' + $xpath }
    return $xpath
  }

  function Select-Nodes ([string]$xpath) { $rootForSelect.SelectNodes((Normalize-XPath $xpath),$nsm) }
  function Select-Single ([string]$xpath) { $rootForSelect.SelectSingleNode((Normalize-XPath $xpath),$nsm) }

  function To-DoubleOrNull ([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $t = $s.Trim()

    # ShowPlan often wraps numeric params in parentheses: (10000)
    $t = $t.Trim('(',')').Trim()

    # Strip quotes / N'...' (still wont parse datetimes, by design)
    if ($t -match "^[Nn]?'.*'$") {
      $t = $t -replace "^[Nn]?'",""
      $t = $t.TrimEnd("'")
      $t = $t.Trim()
    }

    # Only parse if it looks numeric
    if ($t -notmatch '^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$') { return $null }

    try { return [double]$t } catch { return $null }
  }

  function To-IntOrNull ([string]$s) { if ([string]::IsNullOrWhiteSpace($s)) { return $null }; try { [int]$s } catch { $null } }

  # --- v9: CE model version per statement (flags legacy CE 70 / CE-vs-compat mismatch) ---
  function Get-PlanCEModelInfo {
    param([xml]$PlanXml,[System.Xml.XmlNamespaceManager]$NsMgr)
    $out = New-Object System.Collections.Generic.List[object]
    # Match any statement element carrying the attribute (StmtSimple/StmtCond/StmtCursor)
    $stmtsCE = $PlanXml.SelectNodes('//sp:*[@CardinalityEstimationModelVersion]',$NsMgr)
    foreach ($s in $stmtsCE) {
      $ceVersion = To-IntOrNull ($s.GetAttribute('CardinalityEstimationModelVersion'))
      if ($null -eq $ceVersion) { continue }
      $sid = Get-StmtKey $s   # v10: batch-qualified
      $compat = $null
      # Newer schemas put DatabaseCompatLevel on the statement element; older on QueryPlan.
      if ($s.HasAttribute('DatabaseCompatLevel')) {
        $compat = To-IntOrNull ($s.GetAttribute('DatabaseCompatLevel'))
      } else {
        $qp = $s.SelectSingleNode('.//sp:QueryPlan',$NsMgr)
        if ($qp -and $qp.HasAttribute('DatabaseCompatLevel')) { $compat = To-IntOrNull ($qp.GetAttribute('DatabaseCompatLevel')) }
      }
      $signal = 'modern CE'; $note = $null
      if ($ceVersion -eq 70) {
        $signal = 'LEGACY CE (70)'
        $note = 'Compiled under the pre-2014 estimator. CE feedback and most IQP features do not apply. Source is one of: LEGACY_CARDINALITY_ESTIMATION db-scoped config, USE HINT in the query, trace flag 9481, or compat level 110 or lower.'
      }
      elseif ($compat -and ($ceVersion -ne $compat)) {
        $signal = 'CE/compat mismatch'
        $note = "CE model $ceVersion under compat level $compat - a hint, db-scoped config, or trace flag is pinning the estimator to a different version than the database default."
      }
      $out.Add([pscustomobject]@{ StatementId = $sid; CEVersion = $ceVersion; CompatLevel = $compat; Signal = $signal; Note = $note })
    }
    return $out
  }

  # --- v9: query/table hint detection ("the optimizer is being told, not choosing") ---
  function Get-PlanHintSignals {
    param([xml]$PlanXml,[System.Xml.XmlNamespaceManager]$NsMgr)
    $out = New-Object System.Collections.Generic.List[object]
    $stmtsH = $PlanXml.SelectNodes('//sp:*[@StatementText]',$NsMgr)
    foreach ($s in $stmtsH) {
      $sid = Get-StmtKey $s   # v10: batch-qualified
      $text = $s.GetAttribute('StatementText')
      if ([string]::IsNullOrWhiteSpace($text)) { continue }

      # OPTION(...) clause: anchor to the final closing paren of the statement tail,
      # because USE HINT('...') nests parens inside the clause body.
      $optionMatch = [regex]::Match($text,'(?is)\bOPTION\s*\((?<body>.+)\)\s*;?\s*$')
      if ($optionMatch.Success) {
        $body = $optionMatch.Groups['body'].Value
        $optionPatterns = [ordered]@{
          'MAXDOP'                  = '(?i)\bMAXDOP\s+(\d+)'
          'USE HINT'                = "(?i)USE\s+HINT\s*\(\s*'([^']+)'\s*\)"
          'FORCE ORDER'             = '(?i)\bFORCE\s+ORDER\b'
          'OPTIMIZE FOR'            = '(?i)\bOPTIMIZE\s+FOR\b'
          'RECOMPILE'               = '(?i)\bRECOMPILE\b'
          'KEEPFIXED PLAN'          = '(?i)\bKEEPFIXED\s+PLAN\b'
          'KEEP PLAN'               = '(?i)\bKEEP\s+PLAN\b'
          'HASH/ORDER GROUP'        = '(?i)\b(HASH|ORDER)\s+GROUP\b'
          'CONCAT/HASH/MERGE UNION' = '(?i)\b(CONCAT|HASH|MERGE)\s+UNION\b'
          'JOIN strategy (OPTION)'  = '(?i)\b(LOOP|MERGE|HASH)\s+JOIN\b'
          'GRANT PERCENT'           = '(?i)\b(MIN|MAX)_GRANT_PERCENT\s*=\s*[\d.]+'
          'MAXRECURSION'            = '(?i)\bMAXRECURSION\s+\d+'
          'FAST N'                  = '(?i)\bFAST\s+\d+'
        }
        foreach ($hintName in $optionPatterns.Keys) {
          foreach ($m in [regex]::Matches($body,$optionPatterns[$hintName])) {
            $implication = switch ($hintName) {
              'USE HINT'               { "Hint '$($m.Groups[1].Value)' active - check its specific effect (CE version, optimizer behaviour) before tuning." }
              'MAXDOP'                 { "Parallelism pinned to DOP $($m.Groups[1].Value) - instance/db MAXDOP and cost threshold are being overridden." }
              'FORCE ORDER'            { 'Join order frozen to textual order - the optimizer cannot reorder even when estimates say it should.' }
              'JOIN strategy (OPTION)' { 'Join algorithm mandated for ALL joins in the statement - alternatives are off the table regardless of row counts.' }
              'OPTIMIZE FOR'           { 'Plan compiled for specified/unknown parameter values - actual runtime values may be a poor fit (deliberate sniffing control).' }
              'RECOMPILE'              { 'Fresh plan every execution - no plan reuse, no plan cache evidence, compile CPU on every run.' }
              default                  { 'Optimizer behaviour constrained by explicit hint.' }
            }
            $out.Add([pscustomobject]@{ StatementId = $sid; Source = 'OPTION clause'; Hint = $hintName; Detail = $m.Value.Trim(); Implication = $implication })
          }
        }
      }

      # Inline ANSI join hints: force the algorithm AND implicitly force join order.
      $inlineJoin = '(?i)\b(INNER|LEFT(\s+OUTER)?|RIGHT(\s+OUTER)?|FULL(\s+OUTER)?)\s+(HASH|LOOP|MERGE|REMOTE)\s+JOIN\b'
      foreach ($m in [regex]::Matches($text,$inlineJoin)) {
        $out.Add([pscustomobject]@{ StatementId = $sid; Source = 'Inline join hint'; Hint = (($m.Value -replace '\s+',' ').ToUpper()); Detail = ($m.Value -replace '\s+',' '); Implication = 'Forces the join algorithm AND the join order for the whole statement (inline join hints imply FORCE ORDER).' })
      }
    }

    # Table/index hints that survive into plan XML - catches WITH (FORCESEEK/FORCESCAN/INDEX(...))
    # and NOEXPAND even when statement text is truncated or the hint is buried inside a view.
    $attrHints = @(
      @{ Attr = 'ForcedIndex';  Hint = 'INDEX(...) table hint'; Note = 'Access path pinned to a named index - optimizer cannot pick a better one.' }
      @{ Attr = 'ForceSeek';    Hint = 'FORCESEEK';             Note = 'Seek mandated - a scan may actually be cheaper for this predicate.' }
      @{ Attr = 'ForceScan';    Hint = 'FORCESCAN';             Note = 'Scan mandated - seek plans are off the table.' }
      @{ Attr = 'NoExpandHint'; Hint = 'NOEXPAND';              Note = 'Indexed view used as-is; base table plans not considered.' }
    )
    foreach ($h in $attrHints) {
      $hintNodes = $PlanXml.SelectNodes(("//sp:*[@{0}='true' or @{0}='1']" -f $h.Attr),$NsMgr)
      foreach ($node in $hintNodes) {
        $relOp = $node.SelectSingleNode('ancestor-or-self::sp:RelOp[1]',$NsMgr)
        $nodeId = if ($relOp) { $relOp.GetAttribute('NodeId') } else { $null }
        $obj = $node.SelectSingleNode('.//sp:Object',$NsMgr)
        $objName = if ($obj) { (@($obj.GetAttribute('Database'),$obj.GetAttribute('Schema'),$obj.GetAttribute('Table'),$obj.GetAttribute('Index')) | Where-Object { $_ }) -join '.' } else { $null }
        $out.Add([pscustomobject]@{ StatementId = $null; Source = "Plan XML (NodeId $nodeId)"; Hint = $h.Hint; Detail = $objName; Implication = $h.Note })
      }
    }
    return $out
  }

  # --- statement selection (when plan contains multiple statements) ---
  # v10: the old sort was ParamMismatchCount desc, RuntimeParamCount desc, Cost
  # desc. RuntimeParamCount rewarded auto-parameterized statements — and
  # eligibility for simple parameterization correlates with being cheap and
  # single-table, so trivial statements beat expensive unparameterized ones
  # (Beast2: the 3ms COUNT_BIG with @1-@3 outranked the 852ms spilled join with
  # zero parameters). New order: sniffing evidence first (compiled<>runtime
  # mismatch), then ACTUAL elapsed time from QueryTimeStats when present
  # (estimates lie; z7 was "cheap" at cost 1180 while burning 437s CPU), then
  # estimated subtree cost as the fallback for estimated plans. A -Statement
  # parameter overrides the whole thing.
  $chosenStmt = $null
  $chosenStmtSummary = $null
  $chosenStmtReason = $null
  $stmtNodes = $xml.SelectNodes("//sp:StmtSimple",$nsm)
  if ($stmtNodes -and @($stmtNodes).Count -gt 1) {
    $stmtScores = foreach ($s in $stmtNodes) {
      $sid = Get-StmtKey $s   # v10: batch-qualified
      $cost = To-DoubleOrNull ($s.GetAttribute("StatementSubTreeCost"))
      $qts = $s.SelectSingleNode(".//sp:QueryTimeStats",$nsm)
      $elapsedMs = if ($qts) { To-DoubleOrNull ($qts.GetAttribute("ElapsedTime")) } else { $null }
      $cpuMs = if ($qts) { To-DoubleOrNull ($qts.GetAttribute("CpuTime")) } else { $null }
      $pNodes = $s.SelectNodes(".//sp:ParameterList/sp:ColumnReference",$nsm)
      $mismatchCount = 0
      foreach ($p in $pNodes) {
        $cv = $p.GetAttribute("ParameterCompiledValue")
        $rv = $p.GetAttribute("ParameterRuntimeValue")
        if (-not [string]::IsNullOrWhiteSpace($rv) -and -not [string]::IsNullOrWhiteSpace($cv) -and $rv -ne $cv) { $mismatchCount++ }
      }
      [pscustomobject]@{
        StatementId = $sid
        Cost = $cost
        ElapsedMs = $elapsedMs
        CpuMs = $cpuMs
        ParamMismatchCount = $mismatchCount
        Node = $s
      }
    }

    $chosen = $null
    if (-not [string]::IsNullOrWhiteSpace($Statement)) {
      $chosen = @($stmtScores | Where-Object { $_.StatementId -eq $Statement.Trim() }) | Select-Object -First 1
      if ($chosen) {
        $chosenStmtReason = "user-specified via -Statement"
      } else {
        Write-Warning ("[-Statement] '{0}' not found. Available: {1}. Falling back to automatic selection." -f $Statement, (($stmtScores | ForEach-Object { $_.StatementId }) -join ", "))
      }
    }
    if (-not $chosen) {
      $chosen = $stmtScores |
        Sort-Object `
          @{ Expression = 'ParamMismatchCount'; Descending = $true },
          @{ Expression = { if ($null -ne $_.ElapsedMs) { $_.ElapsedMs } else { -1 } }; Descending = $true },
          @{ Expression = { if ($null -ne $_.Cost) { $_.Cost } else { -1 } }; Descending = $true } |
        Select-Object -First 1
      if (-not $chosenStmtReason) {
        if ($chosen.ParamMismatchCount -gt 0) {
          $chosenStmtReason = ("compiled/runtime mismatch on {0} parameter(s)" -f $chosen.ParamMismatchCount)
        } elseif ($null -ne $chosen.ElapsedMs) {
          $chosenStmtReason = ("highest actual elapsed time, {0:N0} ms, of {1} statements" -f $chosen.ElapsedMs, @($stmtScores).Count)
        } else {
          $chosenStmtReason = ("highest estimated subtree cost, {0:N2}, of {1} statements" -f $chosen.Cost, @($stmtScores).Count)
        }
      }
    }
    $chosenStmt = $chosen.Node
    # Compact overview of the statements NOT chosen, so the override is discoverable.
    # v10: ranked by the same keys as the chooser (mismatch, actual elapsed, est
    # cost) instead of file order, so the list reads as "next most interesting first".
    $script:otherStmtSummary = ($stmtScores |
      Where-Object { $_.StatementId -ne $chosen.StatementId } |
      Sort-Object `
        @{ Expression = 'ParamMismatchCount'; Descending = $true },
        @{ Expression = { if ($null -ne $_.ElapsedMs) { $_.ElapsedMs } else { -1 } }; Descending = $true },
        @{ Expression = { if ($null -ne $_.Cost) { $_.Cost } else { -1 } }; Descending = $true } |
      ForEach-Object {
      if ($null -ne $_.ElapsedMs) { ("{0} ({1:N0} ms)" -f $_.StatementId, $_.ElapsedMs) }
      elseif ($null -ne $_.Cost)  { ("{0} (est cost {1:N2})" -f $_.StatementId, $_.Cost) }
      else                        { $_.StatementId }
    }) -join ", "
  } elseif ($stmtNodes -and @($stmtNodes).Count -eq 1) {
    $chosenStmt = $stmtNodes[0]
    $script:otherStmtSummary = $null
  }

  if ($chosenStmt) {
    $chosenStmtId = Get-StmtKey $chosenStmt   # v10: batch-qualified
    $chosenStmtText = $chosenStmt.GetAttribute("StatementText")

    # --- NEW: Extract Hashes for Query Store ---
    $queryHash = $chosenStmt.GetAttribute("QueryHash")
    $queryPlanHash = $chosenStmt.GetAttribute("QueryPlanHash")
    if ($chosenStmtText -and $chosenStmtText.Length -gt 220) { $chosenStmtText = $chosenStmtText.Substring(0,220) + "..." }
    $chosenStmtSummary = [pscustomobject]@{ StatementId = $chosenStmtId; StatementText = $chosenStmtText }
    # Scope all subsequent XPath queries to the chosen statement
    $rootForSelect = $chosenStmt
  }

  # --- numeric formatting helpers ---
  # Row counts: 0 decimal places
  function F0 ($v) {
    if ($null -eq $v) { return "" }
    if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { return "" }
    try { return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture,"{0:0}",[double]$v)) }
    catch { return "$v" }
  }

  # Non-row numeric values (costs, ratios, ms, KB, etc.): 2 decimal places
  function F2 ($v) {
    if ($null -eq $v) { return "" }
    if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { return "" }
    try { return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture,"{0:0.00}",[double]$v)) }
    catch { return "$v" }
  }

  # Back-compat alias: F3 was used throughout the script before F2 was added.
  # It intentionally delegates to F2 (2 decimal places). Kept as an alias to avoid
  # renaming every call site; do NOT change it to 3 decimal places without a full audit.
  function F3 ($v) { return (F2 $v) }

  # v10: Object names are printed as a separate "NodeId : Object" key below each
  # Top-operators grid rather than as a grid column - Format-Table -AutoSize sizes
  # columns to their widest value and silently drops trailing columns (including
  # Object) once the row is wider than the console reports, regardless of -Wrap.
  # A plain Write-Host list has no such width ceiling.
  function ShortObjectName ($obj) {
    if ([string]::IsNullOrWhiteSpace($obj) -or $obj -like '(via:*') { return $null }
    return [regex]::Replace($obj,'\[[^\]]+\]\.\[[^\]]+\]\.(\[[^\]]+\])','$1')
  }
  function Write-ObjectKey ($rows) {
    $entries = @($rows) | ForEach-Object {
      $o = ShortObjectName $_.Object
      if ($null -ne $o) { [pscustomobject]@{ NodeId = $_.NodeId; Object = $o } }
    }
    if (@($entries).Count -gt 0) {
      Write-Host "  Object key (NodeId : Object):" -ForegroundColor DarkGray
      foreach ($e in $entries) {
        Write-Host ("    {0,3} : {1}" -f $e.NodeId, $e.Object) -ForegroundColor DarkGray
      }
    }
  }


  function Get-ScalarString ($node) {
    if (-not $node) { return $null }
    $so = $node.SelectSingleNode(".//sp:ScalarOperator",$nsm)
    if ($so) {
      $ss = $so.GetAttribute("ScalarString")
      if (-not [string]::IsNullOrWhiteSpace($ss)) { return $ss }
    }
    return $null
  }

  function Get-WarningsText ($relOpNode) {
    $warningsNode = $relOpNode.SelectSingleNode(".//sp:Warnings",$nsm)
    if (-not $warningsNode) { return $null }
    $warnFlags = @()
    foreach ($attr in $warningsNode.Attributes) {
      if ($attr.Value -eq "true") { $warnFlags += $attr.Name }
    }
    if ($warnFlags.Count -gt 0) { return ($warnFlags -join ",") }
    return $null
  }

  function Get-StatementInfo ($relOpNode) {
    $stmt = $relOpNode.SelectSingleNode("ancestor::sp:StmtSimple[1]",$nsm)
    if (-not $stmt) { return $null }
    $text = $stmt.GetAttribute("StatementText")
    if ($text -and $text.Length -gt 220) { $text = $text.Substring(0,220) + "..." }
    return [pscustomobject]@{
      StatementId = Get-StmtKey $stmt   # v10: batch-qualified
      StatementText = $text
    }
  }

  # Bubbles up to 2 distinct objects from the subtree so operational nodes have context in summary grids
  # Strict scoping: only return objects that belong DIRECTLY to this operator.
 # Hybrid scoping: Returns direct objects if present. Otherwise, returns downstream objects as "(via: ...)".
  # Hybrid scoping: Native PowerShell Array implementation (bulletproof)
  # Targeted Hybrid scoping: Only allows Join operators to inherit downstream table names.
  function Get-ObjectNames ($relOpNode,[int]$max = 2) {
    $objs = $relOpNode.SelectNodes(".//sp:Object",$nsm)
    if (-not $objs -or @($objs).Count -eq 0) { return "" }

    $currentNodeId = [string]$relOpNode.GetAttribute("NodeId")
    $physOp = [string]$relOpNode.GetAttribute("PhysicalOp")

    $directNames = @()
    $childNames = @()

    # Only bubble up downstream objects for Join operators to reduce noise
    $allowDownstream = ($physOp -match "Join|Nested Loops|Hash Match")

    foreach ($o in $objs) {
      $db = $o.GetAttribute("Database")
      $schema = $o.GetAttribute("Schema")
      $table = $o.GetAttribute("Table")
      $index = $o.GetAttribute("Index")

      $base = (@($db,$schema,$table) | Where-Object { $_ -and $_ -ne "" }) -join "."
      if ([string]::IsNullOrWhiteSpace($base)) { continue }
      if ($index -and $index -ne "") { $base = "$base ($index)" }

      # Check if this object belongs directly to the current RelOp
      $nearestRelOp = $o.SelectSingleNode("ancestor::sp:RelOp[1]", $nsm)
      $nearId = if ($nearestRelOp) { [string]$nearestRelOp.GetAttribute("NodeId") } else { "" }

      if ($nearId -eq $currentNodeId) {
          if ($directNames -notcontains $base) { $directNames += $base }
      } elseif ($allowDownstream) {
          if ($childNames -notcontains $base) { $childNames += $base }
      }
    }

    # 1. Access nodes (Scan/Seek) get direct assignment
    if ($directNames.Count -gt 0) {
        $lim = if ($directNames.Count -gt $max) { $max } else { $directNames.Count }
        return ($directNames[0..($lim - 1)] -join " | ")
    }

    # 2. Joins show downstream context; all other operational nodes stay cleanly blank
    if ($childNames.Count -gt 0) {
        $lim = if ($childNames.Count -gt $max) { $max } else { $childNames.Count }
        return "(via: " + ($childNames[0..($lim - 1)] -join " | ") + ")"
    }

    return ""
  }

  function Get-RunTimeSum ($relOpNode) {
    $rt = $relOpNode.SelectNodes("./sp:RunTimeInformation/sp:RunTimeCountersPerThread",$nsm)
    if (-not $rt -or @($rt).Count -eq 0) { return $null }

    # Use arrays for keys to avoid "Collection was modified..." edge cases
    $sum = [ordered]@{
      ActualRows = 0
      ActualExecutions = 0
      ActualRowsRead = 0
      ActualRebinds = 0
      ActualRewinds = 0
      ActualEndOfScans = 0
    }
    $keys = @($sum.Keys)

    $has = @{}
    foreach ($k in $keys) { $has[$k] = $false }

    # Collect per-thread ActualRows for readability/skew analysis
    $threadRows = @()

    foreach ($t in $rt) {
      $thr = To-IntOrNull ($t.GetAttribute("Thread"))
      $ar = To-DoubleOrNull ($t.GetAttribute("ActualRows"))
      if ($thr -ne $null -and $ar -ne $null) {
        $threadRows += [pscustomobject]@{ Thread = $thr; ActualRows = [double]$ar }
      }

      foreach ($k in $keys) {
        $v = $t.GetAttribute($k)
        if (-not [string]::IsNullOrWhiteSpace($v)) {
          $sum[$k] += [double]$v
          $has[$k] = $true
        }
      }
    }

    # Aggregate per-thread rows by Thread id (ShowPlan can emit multiple counters for the same Thread)
    # This prevents duplicate thread IDs in output and makes skew math stable/readable.
    if ($threadRows -and @($threadRows).Count -gt 0) {
      $rowsByThread = @{}
      foreach ($tr in @($threadRows)) {
        $tid = [int]$tr.Thread
        $rowsByThread[$tid] = ($rowsByThread[$tid] + [double]$tr.ActualRows)
      }
      $threadRowsAgg = @()
      foreach ($k in @($rowsByThread.Keys | Sort-Object)) {
        $threadRowsAgg += [pscustomobject]@{ Thread = [int]$k; ActualRows = [double]$rowsByThread[$k] }
      }
      $threadRows = $threadRowsAgg
    }

    # --- ActualRows aggregation nuance (parallel plans) ---
    # ShowPlan records counters per thread. In parallel plans:
    #  - "Work" rows = sum(ActualRows) across worker threads (useful to spot wasted work / overshoot)
    #  - "Out" rows  = best-effort output rows (coordinator Thread=0) but only trusted for some operators
    $t0 = $null
    foreach ($t in $rt) {
      if ($t.GetAttribute("Thread") -eq "0") { $t0 = $t; break }
    }

    $phys = $relOpNode.GetAttribute("PhysicalOp")
    $log = $relOpNode.GetAttribute("LogicalOp")
    $par = $relOpNode.GetAttribute("Parallel")

    $trustT0 = $false
    if ($par -eq "false") { $trustT0 = $true }
    elseif ($phys -eq "Parallelism" -and $log -match "Gather Streams") { $trustT0 = $true }

    $sumActualRowsWork = $sum.ActualRows
    $sumActualRowsOut = $null
    if ($trustT0 -and $t0 -ne $null) {
      $v0 = $t0.GetAttribute("ActualRows")
      if (-not [string]::IsNullOrWhiteSpace($v0)) { $sumActualRowsOut = [double]$v0 }
    }

    # Per-thread skew metrics (workers only, exclude Thread=0)
    $workers = $threadRows | Where-Object { $_.Thread -ne 0 }
    if (@($workers | Where-Object { $_.ActualRows -gt 0 }).Count -gt 0) { $workers = $workers | Where-Object { $_.ActualRows -gt 0 } }
    $wCount = @($workers).Count
    $minW = $null; $maxW = $null; $avgW = $null; $skewMaxAvg = $null; $skewMaxMin = $null
    if ($wCount -gt 0) {
      $mW = $workers | Measure-Object -Property ActualRows -Minimum -Maximum -Average
      $minW = [double]$mW.Minimum
      $maxW = [double]$mW.Maximum
      $avgW = [double]$mW.Average
      if ($avgW -gt 0) { $skewMaxAvg = ($maxW / $avgW) }
      if ($minW -gt 0) { $skewMaxMin = ($maxW / $minW) }
    }

    $o = [ordered]@{}
    foreach ($k in $keys) { if ($has[$k]) { $o[$k] = $sum[$k] } }

    # Preserve both interpretations
    $o['ActualRowsWork'] = $sumActualRowsWork
    $o['ActualRowsOut'] = $sumActualRowsOut

    # Back-compat: prefer Out where trusted, otherwise fall back to Work
    $o['ActualRows'] = $(if ($sumActualRowsOut -ne $null) { $sumActualRowsOut } else { $sumActualRowsWork })

    # Per-thread detail for readability
    $o['ThreadRows'] = $threadRows
    $o['WorkerThreadCount'] = $wCount
    $o['ThreadMinRows'] = $minW
    $o['ThreadMaxRows'] = $maxW
    $o['ThreadAvgRows'] = $avgW
    $o['ThreadSkewMaxAvg'] = $skewMaxAvg
    $o['ThreadSkewMaxMin'] = $skewMaxMin
    return [pscustomobject]$o
  }

  # Returns $true when the first argument of $fnName(...) in $expr is a column reference
  # (4-part [db].[schema].[table].[col] or aliased [table].[col] form).
  # Parameters (@name) and internal expressions ([ExprNNNN]) are NOT column refs.
  # This is used to distinguish ISNULL(column, default) — non-SARGable —
  # from ISNULL(@param, default) or ISNULL([Expr1003], default) — fine.
  function Test-FunctionWrapsColumn ([string]$expr,[string]$fnName) {
    # Find the opening paren of the function
    $pattern = "(?i)\b" + [regex]::Escape($fnName) + "\s*\("
    $m = [regex]::Match($expr, $pattern)
    if (-not $m.Success) { return $false }

    # Walk forward from the char after '(' to extract the first argument
    $start = $m.Index + $m.Length
    $depth = 1
    $i = $start
    $len = $expr.Length
    while ($i -lt $len -and $depth -gt 0) {
      $c = $expr[$i]
      if     ($c -eq '(') { $depth++ }
      elseif ($c -eq ')') { $depth-- }
      elseif ($c -eq ',' -and $depth -eq 1) { break }   # end of first arg
      $i++
    }
    $firstArg = $expr.Substring($start, $i - $start).Trim()

    # A column reference: [db].[schema].[table].[col] or [table].[col] style,
    # but NOT @parameter and NOT [ExprNNNN] (single bracketed token with only digits after Expr)
    $isParam      = $firstArg -match '^\s*@'
    $isInternalExpr = $firstArg -match '^\s*\[Expr\d+\]'
    $hasColRef    = ($firstArg -match '\[[^\]]+\]\.\[[^\]]+\]\.\[[^\]]+\]\.\[[^\]]+\]') -or
                    ($firstArg -match '\[(?!@)[^\]]+\]\.\[[^\]]+\]')

    return (-not $isParam -and -not $isInternalExpr -and $hasColRef)
  }

  # v10: distinguish column-side CONVERT_IMPLICIT (wraps a column reference —
  # blocks seeks, skews CE) from parameter-side (wraps a parameter/variable —
  # converted once per query, usually benign for seekability). Beast2 fixture:
  # CONVERT_IMPLICIT(int,[@1],0) is parameter-side yet was reported with the
  # same severity as a seek-killing column conversion.
  # Returns 'column', 'parameter', or $null (no CONVERT_IMPLICIT found).
  # Any column-side occurrence wins over parameter-side ones in the same string.
  function Get-ConvertImplicitSide ([string]$expr) {
    if ([string]::IsNullOrWhiteSpace($expr)) { return $null }
    $side = $null
    $needle = "CONVERT_IMPLICIT("
    $idx = 0
    while (($idx = $expr.IndexOf($needle,$idx,[System.StringComparison]::OrdinalIgnoreCase)) -ge 0) {
      $start = $idx + $needle.Length
      $depth = 1; $i = $start
      while ($i -lt $expr.Length -and $depth -gt 0) {
        $ch = $expr[$i]
        if ($ch -eq '(') { $depth++ } elseif ($ch -eq ')') { $depth-- }
        $i++
      }
      $inner = $expr.Substring($start, [math]::Max(0, $i - 1 - $start))
      # Column refs render multi-part: [table].[col] / [db].[schema].[table].[col]
      # (contains "].["); parameters/variables render single-part: [@1], [@Loc].
      if ($inner -match '\](?:\s+as\s+\[[^\]]+\])?\.\[') { return 'column' }
      elseif ($inner -match '\[@') { $side = 'parameter' }
      $idx = $i
    }
    return $side
  }

  function Get-NonSargableFlags ([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $flags = @()
    if ($s -match "TRY_CONVERT\(") { $flags += "try_convert()" }
    if ($s -match "TRY_CAST\(") { $flags += "try_cast()" }
    if ($s -match "CONVERT\(" -or $s -match "Convert\(") { $flags += "convert()" }
    if ($s -match "CONVERT_IMPLICIT") {
      # v10: side-aware flag
      if ((Get-ConvertImplicitSide $s) -eq 'parameter') { $flags += "convert_implicit-param" } else { $flags += "convert_implicit" }
    }

    # ISNULL: only flag when the first argument is a column reference (4-part or 2-part),
    # i.e. ISNULL(table.column, ...) — non-SARGable.
    # ISNULL(@param, default) or ISNULL([Expr1003], default) on the value side is fine.
    if ($s -match "(?i)\bISNULL\s*\(") {
      if (Test-FunctionWrapsColumn $s "ISNULL") { $flags += "isnull()" }
    }

    if ($s -match "ABS\(") { $flags += "abs()" }
    if ($s -match "LEFT\(" -or $s -match "RIGHT\(" -or $s -match "SUBSTRING\(") { $flags += "string-fn" }
    if ($s -match "LOWER\(" -or $s -match "UPPER\(") { $flags += "case-fn" }
    if ($s -match "(?i)(YEAR|MONTH|DAY|DATEPART|DATENAME)\(") { $flags += "date-fn" }
    if ($s -match "(?i)LIKE\s+N?'%[^']*'") { $flags += "leading-wildcard" }
    if ($flags.Count -gt 0) { return ($flags -join ",") }
    return $null
  }


  # Build a clearer seek predicate when the ShowPlan exposes RangeColumns + RangeExpressions
  # (e.g. show: [Users].[Id] = [Posts].[OwnerUserId]) instead of only the expression side.
  function Get-SeekPredicatePretty ($ixNode) {
    if (-not $ixNode) { return $null }

    function Format-ColumnRef ($cr) {
      if (-not $cr) { return $null }
      $d = $cr.GetAttribute("Database")
      $s = $cr.GetAttribute("Schema")
      $t = $cr.GetAttribute("Table")
      $c = $cr.GetAttribute("Column")
      # v10: Database/Schema/Table attributes arrive pre-bracketed in showplan
      # XML (Table="[Posts]") while Column does not; strip before re-wrapping or
      # names render double-bracketed ([[Posts]]).
      $parts = @($d,$s,$t,$c) | Where-Object { $_ -and $_ -ne "" } | ForEach-Object { $_.Trim('[',']') }
      if ($parts.Count -eq 0) { return $null }
      return "[" + ($parts -join "].[") + "]"
    }

    $preds = $ixNode.SelectNodes(".//sp:SeekPredicateNew | .//sp:SeekPredicate",$nsm)
    if (-not $preds -or @($preds).Count -eq 0) { return $null }

    $clauses = @()
    foreach ($p in @($preds)) {
      $sk = $p.SelectSingleNode(".//sp:SeekKeys",$nsm)
      if (-not $sk) { continue }

      # v10: equality seeks (the common case under nested loops) are expressed
      # as <Prefix ScanType="EQ">, not StartRange/EndRange. The old code never
      # handled Prefix, so the pretty renderer returned null and the display fell
      # back to the raw ScalarString — showing only the probe value ("[u].[Id]")
      # without the indexed column it probes into.
      $prefix = $sk.SelectSingleNode("./sp:Prefix",$nsm)
      if ($prefix) {
        $pCols = @($prefix.SelectNodes("./sp:RangeColumns/sp:ColumnReference",$nsm))
        $pExprs = @($prefix.SelectNodes("./sp:RangeExpressions/sp:ScalarOperator",$nsm))
        if ($pCols.Count -gt 0 -and $pCols.Count -eq $pExprs.Count) {
          for ($i = 0; $i -lt $pCols.Count; $i++) {
            $col = Format-ColumnRef $pCols[$i]
            $val = $pExprs[$i].GetAttribute("ScalarString")
            if (-not [string]::IsNullOrWhiteSpace($col) -and -not [string]::IsNullOrWhiteSpace($val)) {
              $clauses += ("{0} = {1}" -f $col,$val)
            }
          }
        }
      }

      # Range portion — honour ScanType (GT vs GE, LT vs LE) instead of assuming >=.
      $startNode = $sk.SelectSingleNode("./sp:StartRange",$nsm)
      $endNode = $sk.SelectSingleNode("./sp:EndRange",$nsm)
      $startCols = @($sk.SelectNodes("./sp:StartRange/sp:RangeColumns/sp:ColumnReference",$nsm))
      $startExprs = @($sk.SelectNodes("./sp:StartRange/sp:RangeExpressions/sp:ScalarOperator",$nsm))
      $endCols = @($sk.SelectNodes("./sp:EndRange/sp:RangeColumns/sp:ColumnReference",$nsm))
      $endExprs = @($sk.SelectNodes("./sp:EndRange/sp:RangeExpressions/sp:ScalarOperator",$nsm))
      $startOpMap = @{ 'GE' = '>='; 'GT' = '>'; 'EQ' = '=' }
      $endOpMap   = @{ 'LE' = '<='; 'LT' = '<'; 'EQ' = '=' }

      # Only render the 1:1 simple case cleanly; fall back to ScalarString elsewhere.
      if ($startCols.Count -eq 1 -and $startExprs.Count -eq 1) {
        $col = Format-ColumnRef $startCols[0]
        $start = $startExprs[0].GetAttribute("ScalarString")
        $sOp = $startOpMap[[string]$startNode.GetAttribute("ScanType")]
        if (-not $sOp) { $sOp = '>=' }

        if (-not [string]::IsNullOrWhiteSpace($col) -and -not [string]::IsNullOrWhiteSpace($start)) {
          $emitted = $false
          if ($endCols.Count -eq 1 -and $endExprs.Count -eq 1) {
            $endCol = Format-ColumnRef $endCols[0]
            $end = $endExprs[0].GetAttribute("ScalarString")
            $eOp = $endOpMap[[string]$endNode.GetAttribute("ScanType")]
            if (-not $eOp) { $eOp = '<=' }

            if ($endCol -eq $col -and -not [string]::IsNullOrWhiteSpace($end)) {
              if ($end -eq $start -and $sOp -eq '>=' -and $eOp -eq '<=') {
                $clauses += ("{0} = {1}" -f $col,$start)
              } elseif ($sOp -eq '>=' -and $eOp -eq '<=') {
                $clauses += ("{0} BETWEEN {1} AND {2}" -f $col,$start,$end)
              } else {
                $clauses += ("{0} {1} {2} AND {0} {3} {4}" -f $col,$sOp,$start,$eOp,$end)
              }
              $emitted = $true
            }
          }
          if (-not $emitted) { $clauses += ("{0} {1} {2}" -f $col,$sOp,$start) }
        }
      }
      elseif ($endCols.Count -eq 1 -and $endExprs.Count -eq 1) {
        # End-only range (e.g., col <= value / col < value)
        $endCol = Format-ColumnRef $endCols[0]
        $end = $endExprs[0].GetAttribute("ScalarString")
        $eOp = $endOpMap[[string]$endNode.GetAttribute("ScanType")]
        if (-not $eOp) { $eOp = '<=' }
        if (-not [string]::IsNullOrWhiteSpace($endCol) -and -not [string]::IsNullOrWhiteSpace($end)) {
          $clauses += ("{0} {1} {2}" -f $endCol,$eOp,$end)
        }
      }
    }

    if ($clauses.Count -gt 0) { return ($clauses -join " AND ") }
    return $null
  }
  function Get-AccessDetails ($relOpNode) {
    # v10 fix: showplan XML has NO <IndexSeek> element. Seeks, scans, and key/RID
    # lookups are ALL represented as <IndexScan>; a seek is distinguished by the
    # presence of <SeekPredicates>, and a lookup by Lookup="1"/"true". The old
    # ./sp:IndexSeek branch could never match, so every seek was classified
    # "Index Scan" — which then tripped the "scan (predicate may not be seekable)"
    # CE heuristic on genuine seeks and key lookups.
    $ixScan = $relOpNode.SelectSingleNode("./sp:IndexScan",$nsm)
    $tblScan = $relOpNode.SelectSingleNode("./sp:TableScan",$nsm)

    $seekPred = $null
    $residualPred = $null
    $kind = $null

    if ($ixScan) {
      $seekPred = Get-SeekPredicatePretty $ixScan
      if (-not $seekPred) { $seekPred = Get-ScalarString ($ixScan.SelectSingleNode(".//sp:SeekPredicates",$nsm)) }
      $residualPred = Get-ScalarString ($ixScan.SelectSingleNode(".//sp:Predicate",$nsm))

      $lookupAttr = $ixScan.GetAttribute("Lookup")
      if ($lookupAttr -eq '1' -or $lookupAttr -eq 'true') {
        $physOp = $relOpNode.GetAttribute("PhysicalOp")
        $kind = if ($physOp -match "RID") { "RID Lookup" } else { "Key Lookup" }
      }
      elseif ($seekPred) { $kind = "Index Seek" }
      else { $kind = "Index Scan" }
    }
    elseif ($tblScan) {
      $kind = "Table Scan"
      $residualPred = Get-ScalarString ($tblScan.SelectSingleNode(".//sp:Predicate",$nsm))
    }

    return [pscustomobject]@{
      AccessType = $kind
      SeekPredicate = $seekPred
      Residual = $residualPred
    }
  }

  # For operators that don't have a seek/scan, give a useful category so "Access" isn't blank
  function Get-AccessCategory ($physicalOp,$accessType) {
    if ($accessType) { return $accessType }
    if ($physicalOp -match "Nested Loops|Hash Match|Merge Join") { return "Join" }
    if ($physicalOp -match "Spool") { return "Spool" }
    if ($physicalOp -match "Sort") { return "Sort" }
    if ($physicalOp -match "Aggregate") { return "Aggregate" }
    if ($physicalOp -match "Parallelism") { return "Exchange" }
    if ($physicalOp -match "Compute Scalar") { return "Compute" }
    if ($physicalOp -match "Segment") { return "Segment" }
    return "Other"
  }

  function Get-JoinDetails ($relOpNode) {
    $joinPred = $null
    $hash = $relOpNode.SelectSingleNode(".//sp:Hash",$nsm)
    if ($hash) {
      $joinPred = Get-ScalarString ($hash.SelectSingleNode(".//sp:ProbeResidual",$nsm))
      if (-not $joinPred) { $joinPred = Get-ScalarString ($hash.SelectSingleNode(".//sp:HashKeysBuild",$nsm)) }
      if (-not $joinPred) { $joinPred = Get-ScalarString ($hash.SelectSingleNode(".//sp:HashKeysProbe",$nsm)) }
    }
    $nl = $relOpNode.SelectSingleNode(".//sp:NestedLoops",$nsm)
    if ($nl -and -not $joinPred) { $joinPred = Get-ScalarString ($nl.SelectSingleNode(".//sp:Predicate",$nsm)) }
    $mj = $relOpNode.SelectSingleNode(".//sp:Merge",$nsm)
    if ($mj -and -not $joinPred) { $joinPred = Get-ScalarString ($mj.SelectSingleNode(".//sp:Residual",$nsm)) }
    return $joinPred
  }

  function Get-SortKeys ($relOpNode) {
    $sort = $relOpNode.SelectSingleNode(".//sp:Sort",$nsm)
    if (-not $sort) { return $null }

    $keyRefs = $sort.SelectNodes(".//sp:OrderByColumn/sp:ColumnReference",$nsm)
    if (-not $keyRefs -or @($keyRefs).Count -eq 0) { $keyRefs = $sort.SelectNodes(".//sp:SortColumn/sp:ColumnReference",$nsm) }
    if (-not $keyRefs -or @($keyRefs).Count -eq 0) { return $null }

    $keys = @()
    foreach ($kr in $keyRefs) {
      $c = $kr.GetAttribute("Column")
      $t = $kr.GetAttribute("Table")
      $s = $kr.GetAttribute("Schema")
      $d = $kr.GetAttribute("Database")
      $txt = (@($d,$s,$t,$c) | Where-Object { $_ -and $_ -ne "" }) -join "."
      if ($txt) { $keys += $txt }
    }
    if ($keys.Count -gt 0) { return ($keys -join ", ") }
    return $null
  }

  # -----------------------------
  # Useful links (always printed)
  # -----------------------------
  $referenceLinks = [pscustomobject]@{
    "Cardinality estimation (Microsoft)" = "https://learn.microsoft.com/en-us/sql/relational-databases/performance/cardinality-estimation-sql-server?view=sql-server-ver17"
    "CE Feedback (Microsoft IQP)" = "https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing-cardinality-estimation-feedback?view=sql-server-ver17"
    "Implicit conversion is a SARGability problem (Erik Darling)" = "https://erikdarling.com/implicit-conversion-is-a-sargability-problem/"
    "Why implicit conversions aren't SARGable (Erik Darling)" = "https://erikdarling.com/sargability-week-why-implicit-conversions-arent-sargable/"
    "Bad guesses -> bad choices (Erik Darling)" = "https://erikdarling.com/bad-guesses-and-bad-choices-better-living-through-indexes/"
    "SSMS hides missing indexes (Brent Ozar)" = "https://www.brentozar.com/archive/2018/07/management-studio-hides-missing-indexes-from-you/"
    "Missing index recs aren't perfect (Brent Ozar)" = "https://www.brentozar.com/archive/2017/08/missing-index-recommendations-arent-perfect/"
    "Expensive key lookups (Brent Ozar)" = "https://www.brentozar.com/blitzcache/expensive-key-lookups/"
    "Expensive sorts (Brent Ozar)" = "https://www.brentozar.com/blitzcache/expensive-sorts/"
  }

  # -----------------------------
  # Plan-level info
  # -----------------------------
  $qp = Select-Single "//sp:QueryPlan"
  $dop = $null
  if ($qp) { $dop = To-IntOrNull ($qp.GetAttribute("DegreeOfParallelism")) }

  # Observed DOP (best-effort) from runtime thread counters.
  # We compute TWO observations:
  #  - observed(maxRuntime): max worker-thread count across all runtime operators (most practical / robust).
  #  - observed(parallelism): max worker-thread count across Parallelism (exchange) operators *only when they expose worker threads*.
  # Preferred observed DOP:
  #  - If any Parallelism operator exposes >1 worker threads, prefer observed(parallelism).
  #  - Otherwise, fall back to observed(maxRuntime).
  $dopObserved = $null
  $dopObservedParallelism = $null
  $dopObservedMaxRuntime = $null
  try {
    function Get-ThreadTeamSize ([System.Xml.XmlNode]$relOp) {
      if (-not $relOp) { return $null }
      $threads = $relOp.SelectNodes("./sp:RunTimeInformation/sp:RunTimeCountersPerThread",$nsm)
      if (-not $threads -or @($threads).Count -eq 0) { return $null }

      $ids = @()
      foreach ($t in @($threads)) {
        $tid = To-IntOrNull ($t.GetAttribute("Thread"))
        if ($tid -ne $null) { $ids += $tid }
      }
      if ($ids.Count -eq 0) { return $null }

      $uniq = @($ids | Sort-Object -Unique)
      # Exclude coordinator Thread=0 when there are other worker threads
      if ($uniq.Count -gt 1 -and ($uniq -contains 0)) { $uniq = @($uniq | Where-Object { $_ -ne 0 }) }
      return $uniq.Count
    }

    $runtimeOps = Select-Nodes ("//sp:RelOp[sp:RunTimeInformation/sp:RunTimeCountersPerThread]")
    if ($runtimeOps -and @($runtimeOps).Count -gt 0) {
      $dopObservedMaxRuntime = 1
      foreach ($r in @($runtimeOps)) {
        $sz = Get-ThreadTeamSize $r
        if ($sz -ne $null -and $sz -gt $dopObservedMaxRuntime) { $dopObservedMaxRuntime = $sz }
      }

      $parOps = Select-Nodes ("//sp:RelOp[@PhysicalOp='Parallelism' and sp:RunTimeInformation/sp:RunTimeCountersPerThread]")
      if ($parOps -and @($parOps).Count -gt 0) {
        $dopObservedParallelism = 1
        foreach ($r in @($parOps)) {
          $sz = Get-ThreadTeamSize $r
          if ($sz -ne $null -and $sz -gt $dopObservedParallelism) { $dopObservedParallelism = $sz }
        }
        # Only treat it as a meaningful observation if > 1
        if ($dopObservedParallelism -le 1) { $dopObservedParallelism = $null }
      }

      if ($dopObservedParallelism -ne $null -and $dopObservedParallelism -gt 1) {
        $dopObserved = $dopObservedParallelism
      } else {
        $dopObserved = $dopObservedMaxRuntime
      }
    } else {
      $dopObserved = $null
      $dopObservedParallelism = $null
      $dopObservedMaxRuntime = $null
    }
  } catch {
    $dopObserved = $null
    $dopObservedParallelism = $null
    $dopObservedMaxRuntime = $null
  }

  $mg = Select-Single "//sp:MemoryGrantInfo"
  $memoryGrantInfo = $null
  if ($mg) {
    $memoryGrantInfo = [pscustomobject]@{
      RequestedKB = To-DoubleOrNull ($mg.GetAttribute("RequestedMemory"))
      GrantedKB = To-DoubleOrNull ($mg.GetAttribute("GrantedMemory"))
      UsedKB = To-DoubleOrNull ($mg.GetAttribute("UsedMemory"))
      MaxUsedKB = To-DoubleOrNull ($mg.GetAttribute("MaxUsedMemory"))
      GrantWaitMS = To-DoubleOrNull ($mg.GetAttribute("GrantWaitTime"))
      FeedbackAdjusted = $mg.GetAttribute("IsMemoryGrantFeedbackAdjusted")
    }
  }

  $xmlText = $xml.OuterXml
  # v10: scan for spill markers in the CHOSEN STATEMENT only. $xmlText is the
  # whole file (kept as-is for the -OutFile bundle), so in multi-batch plans the
  # old scan reported spills belonging to statements this report isn't about,
  # contradicting the per-operator spill section ("none detected") below.
  $stmtScopedXmlText = if ($rootForSelect -is [System.Xml.XmlDocument]) { $xmlText } else { $rootForSelect.OuterXml }
  $spillSignals = @("SpillLevel","HashSpillDetails","SortSpillDetails","Spilled","SpillToTempDb")
  $spillLikely = @($spillSignals | Where-Object { $stmtScopedXmlText -match $_ } | Select-Object -Unique)

  # -----------------------------
  # Operator rows (RelOp)
  # -----------------------------
  $relOps = Select-Nodes "//sp:RelOp"

  # --- MOVED UP FOR INDENTATION LOGIC ---
  function Get-NearestRelOpAncestor ($node) {
    $p = $node.ParentNode
    while ($p -and $p.LocalName -ne 'RelOp') { $p = $p.ParentNode }
    return $p
  }

  function Get-DirectChildRelOps ($relOpNode) {
    $kids = @()
    $desc = $relOpNode.SelectNodes(".//*[local-name()='RelOp']",$nsm)
    if (-not $desc -or @($desc).Count -eq 0) { return $kids }
    foreach ($d in $desc) {
      if ($d -eq $relOpNode) { continue }
      $nearest = Get-NearestRelOpAncestor $d
      if ($nearest -eq $relOpNode) { $kids += $d }
    }
    return $kids
  }

  # --- NEW: Find max depth for reversed (left-to-right) indentation ---
  # --- NEW: Calculate Bottom-Up Height for Perfect Left-to-Right Flow ---
  $nodeHeightMap = @{}
  
  function Get-NodeHeight([System.Xml.XmlNode]$node) {
      $id = $node.GetAttribute("NodeId")
      if ([string]::IsNullOrWhiteSpace($id)) { return 0 }
      if ($nodeHeightMap.ContainsKey($id)) { return $nodeHeightMap[$id] }

      $kids = Get-DirectChildRelOps $node
      if (-not $kids -or @($kids).Count -eq 0) {
          $nodeHeightMap[$id] = 0
          return 0
      }

      $maxKidHeight = -1
      foreach ($k in $kids) {
          $h = Get-NodeHeight $k
          if ($h -gt $maxKidHeight) { $maxKidHeight = $h }
      }

      $myHeight = $maxKidHeight + 1
      $nodeHeightMap[$id] = $myHeight
      return $myHeight
  }

  # Prime the height map for all operators
  foreach ($op in $relOps) {
      [void](Get-NodeHeight $op)
  }

  $operatorRows = @(
    foreach ($op in $relOps) {
      $nodeIdString = $op.GetAttribute("NodeId")
      $nodeId = To-IntOrNull $nodeIdString
      $physical = $op.GetAttribute("PhysicalOp")
      $logical = $op.GetAttribute("LogicalOp")

      # v9 fix: in raw showplan XML a key lookup is PhysicalOp="Clustered Index Seek"
      # with Lookup="true"/"1" on the IndexScan element. The string "Key Lookup" is
      # an SSMS rendering and never appears in the XML, so matching on PhysicalOp
      # alone can never find one in a .sqlplan file.
      $isLookup = $false
      $lookupAttr = $op.GetAttribute("Lookup")
      if ($lookupAttr -eq '1' -or $lookupAttr -eq 'true') { $isLookup = $true }
      if (-not $isLookup) {
        $lookupProbe = $op.SelectSingleNode("./sp:IndexScan[@Lookup='1' or @Lookup='true']", $nsm)
        if ($lookupProbe) { $isLookup = $true }
      }

      # --- UPDATED: Left-to-Right Funnel Indentation ---
      # --- UPDATED: Left-to-Right Funnel Indentation with Node Leaders ---
      $reversedDepth = if ($nodeIdString -and $nodeHeightMap.ContainsKey($nodeIdString)) { $nodeHeightMap[$nodeIdString] } else { 0 }
      
      # Define operators that dictate major execution phases
      $isLeader = $physical -match "Hash Match|Nested Loops|Merge Join|Sort"
      
      if ($reversedDepth -eq 0) {
          # Leaf nodes (origin points)
          $displayPhysical = $physical
      } elseif ($isLeader) {
          # Node Leaders act as anchors for the eyes
          $indent = ("  " * $reversedDepth)
          $displayPhysical = $indent + ">> " + $physical.ToUpper() + " <<"
      } else {
          # Standard flowing operators
          $indent = ("  " * $reversedDepth) + "-> "
          $displayPhysical = $indent + $physical
      }
      if ($isLookup) { $displayPhysical = $displayPhysical + " (Key Lookup)" }



      $estRows = To-DoubleOrNull ($op.GetAttribute("EstimateRows"))
      $estCost = To-DoubleOrNull ($op.GetAttribute("EstimatedTotalSubtreeCost"))

      $warn = Get-WarningsText $op
      $st = Get-StatementInfo $op

      $rt = Get-RunTimeSum $op
      $actRows = $null; $actRowsOut = $null; $actRowsWork = $null
      $threadRows = $null; $workerThreads = $null; $tMin = $null; $tMax = $null; $tAvg = $null; $tSkewMA = $null; $tSkewMM = $null
      $execs = $null; $rowsRead = $null; $rebinds = $null; $rewinds = $null
      if ($rt) {
        if ($rt.PSObject.Properties.Name -contains "ActualRows") { $actRows = [double]$rt.ActualRows }
        if ($rt.PSObject.Properties.Name -contains "ActualRowsOut") { $actRowsOut = if ($rt.ActualRowsOut -ne $null -and $rt.ActualRowsOut -ne '') { [double]$rt.ActualRowsOut } else { $null } }
        if ($rt.PSObject.Properties.Name -contains "ActualRowsWork") { $actRowsWork = if ($rt.ActualRowsWork -ne $null -and $rt.ActualRowsWork -ne '') { [double]$rt.ActualRowsWork } else { $null } }
        if ($rt.PSObject.Properties.Name -contains "ThreadRows") { $threadRows = $rt.ThreadRows }
        if ($rt.PSObject.Properties.Name -contains "WorkerThreadCount") { $workerThreads = [int]$rt.WorkerThreadCount }
        if ($rt.PSObject.Properties.Name -contains "ThreadMinRows") { $tMin = $rt.ThreadMinRows }
        if ($rt.PSObject.Properties.Name -contains "ThreadMaxRows") { $tMax = $rt.ThreadMaxRows }
        if ($rt.PSObject.Properties.Name -contains "ThreadAvgRows") { $tAvg = $rt.ThreadAvgRows }
        if ($rt.PSObject.Properties.Name -contains "ThreadSkewMaxAvg") { $tSkewMA = $rt.ThreadSkewMaxAvg }
        if ($rt.PSObject.Properties.Name -contains "ThreadSkewMaxMin") { $tSkewMM = $rt.ThreadSkewMaxMin }
        if ($rt.PSObject.Properties.Name -contains "ActualExecutions") { $execs = [double]$rt.ActualExecutions }
        if ($rt.PSObject.Properties.Name -contains "ActualRowsRead") { $rowsRead = [double]$rt.ActualRowsRead }
        if ($rt.PSObject.Properties.Name -contains "ActualRebinds") { $rebinds = [double]$rt.ActualRebinds }
        if ($rt.PSObject.Properties.Name -contains "ActualRewinds") { $rewinds = [double]$rt.ActualRewinds }
      }

      $executed = $null
      if ($execs -ne $null) { $executed = ($execs -gt 0) }

      $ratio = $null
      $direction = $null
      if ($estRows -ne $null -and $actRows -ne $null -and $estRows -ge 0 -and $actRows -ge 0) {
        if ($estRows -eq 0 -and $actRows -eq 0) { $ratio = 1.0 }
        elseif (($estRows -eq 0 -and $actRows -gt 0) -or ($actRows -eq 0 -and $estRows -gt 0)) { $ratio = [double]::PositiveInfinity }
        elseif ($estRows -gt 0 -and $actRows -gt 0) {
          $ratio = [math]::Max($estRows / $actRows,$actRows / $estRows)
          $direction = if ($actRows -gt $estRows) { "under-est" } else { "over-est" }
        }
      }

      $severity = $null
      if ($ratio -ne $null -and $ratio -ne [double]::PositiveInfinity -and $estRows -ne $null -and $actRows -ne $null) {
    
    # 1. Base Scale: How big is the mismatch?
    $scale = [math]::Log10([math]::Max($estRows, $actRows) + 1)
    $baseSeverity = [math]::Log10($ratio) * ($scale + 1)

    # 2. True Volume: How many rows did the CPU actually have to touch?
    # Prefer RowsRead (the real physical work), fallback to ActRows.
    $touchedRows = if ($rowsRead -ne $null -and $rowsRead -gt 0) { $rowsRead }
                   elseif ($actRows -gt 0) { $actRows }
                   else { $estRows }
    
    # Use a log scale so massive tables don't entirely break the math, but still carry heavy weight
    $cpuVolumeWeight = [math]::Log10($touchedRows + 1)

    # 3. Wasted Work Penalty: The "Joe Chang" factor.
    # Heavily penalize operators that read millions of rows just to filter them out via residual predicates.
    $wasteMultiplier = 1.0
    if ($rowsRead -ne $null -and $actRows -ne $null -and $actRows -gt 0) {
        $wasteRatio = $rowsRead / $actRows
        if ($wasteRatio -gt 1) {
            # Logarithmic penalty: 10x waste = +1 multiplier, 100x waste = +2 multiplier
            $wasteMultiplier = 1.0 + [math]::Log10($wasteRatio)
        }
    }

    # 4. Final Severity: Mismatch Size * CPU Volume * Wasted Work Penalty
    # Note: We completely removed $estCost to ignore the optimizer's I/O bias.
    $severity = ($baseSeverity * ($cpuVolumeWeight + 1) * $wasteMultiplier)
}

      $access = Get-AccessDetails $op
      $predNode = $op.SelectSingleNode(
        "./sp:Predicate | ./sp:Filter/sp:Predicate | ./sp:IndexScan/sp:Predicate | ./sp:TableScan/sp:Predicate",
        $nsm
      )
      $predCtx = Get-ScalarString $predNode
      $joinPred = (Get-JoinDetails $op)
      $nonSarg = Get-NonSargableFlags ($predCtx + " " + $access.SeekPredicate + " " + $access.Residual + " " + $joinPred)

      if ($DebugSargability) {
        Write-Host "DEBUG SARG: NodeId=$nodeId, Physical=$physical" -ForegroundColor DarkYellow
        Write-Host "  Predicate: $predCtx" -ForegroundColor Gray
        Write-Host "  SeekPredicate: $($access.SeekPredicate)" -ForegroundColor Gray
        Write-Host "  Residual: $($access.Residual)" -ForegroundColor Gray
        Write-Host "  NonSarg Result: $nonSarg" -ForegroundColor Cyan
      }

      $objNames = Get-ObjectNames $op 2
      $accessCategory = Get-AccessCategory $physical $access.AccessType


      # RowsRead can appear on many non-access operators in runtime counters; for readability
      # only surface it for true access operators (Scan/Seek/Lookup). Otherwise leave it blank.
      if ($rowsRead -ne $null) {
        $readOps = @('Index Scan','Clustered Index Scan','Index Seek','Clustered Index Seek','Table Scan','Key Lookup','RID Lookup')
        if ($readOps -notcontains $physical) { $rowsRead = $null }
      }
      [pscustomobject]@{
        NodeId = $nodeId
        StatementId = if ($st) { $st.StatementId } else { "" }
        StatementText = if ($st) { $st.StatementText } else { "" }

        PhysicalOp = $physical
        LogicalOp = $logical
        IsLookup = $isLookup



        PhysicalOpDisplay = $displayPhysical





        EstRows = $estRows
        ActRows = $actRows
        ActRowsOut = $actRowsOut
        ActRowsWork = $actRowsWork
        ThreadRows = $threadRows
        WorkerThreads = $workerThreads
        ThreadMinRows = $tMin
        ThreadMaxRows = $tMax
        ThreadAvgRows = $tAvg
        ThreadSkewMaxAvg = $tSkewMA
        ThreadSkewMaxMin = $tSkewMM
        RowsRead = $rowsRead
        Execs = $execs
        Rebinds = $rebinds
        Rewinds = $rewinds
        Executed = $executed

        Ratio = $ratio
        Direction = $direction
        Severity = $severity

        EstCost = $estCost
        Object = $objNames
        Warnings = $warn

        Access = $accessCategory
        SeekPredicate = $access.SeekPredicate
        Residual = $access.Residual
        Predicate = $predCtx
        NonSargableHints = $nonSarg

        HasConvertImplicit = if ($nonSarg -and $nonSarg -match 'convert_implicit(?!-param)') { $true } else { $false }
        HasParamConvertImplicit = if ($nonSarg -and $nonSarg -match 'convert_implicit-param') { $true } else { $false }  # v10

        SortKeys = (Get-SortKeys $op)
        JoinPredicate = $joinPred
      }
    }
  )
  

  # -----------------------------
  # Sort/order support suggestions (heuristic)
  #   Goal: when we see a Sort with explicit keys, suggest an index that could provide that order.
  #   If -InspectDatabase is used, also check whether an existing index already provides the order.
  # -----------------------------

  function Parse-SortKeyToken ([string]$token) {
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    $t = $token.Trim()
    # Token format produced by Get-SortKeys: db.schema.table.column (best effort)
    $parts = $t -split '\.'
    if ($parts.Count -lt 2) { return $null }
    $col = $parts[-1]
    $table = $null
    if ($parts.Count -ge 4) {
      $table = ($parts[0..($parts.Count-2)] | Select-Object -Last 3) -join '.'
    } elseif ($parts.Count -eq 3) {
      $table = ($parts[0..1] -join '.')
    } else {
      $table = $parts[0]
    }
    return [pscustomobject]@{ Table = $table; Column = $col }
  }

  function Normalize-FullTable ([string]$t) {
  if ([string]::IsNullOrWhiteSpace($t)) { return $null }
  # Accept tokens like db.schema.table or [db].[schema].[table] and normalize to bracketed multipart names.
  $raw = $t.Trim()
  $p = $raw -split '\.'
  $p = $p | ForEach-Object { $_.Trim().Trim('[',']') } | Where-Object { $_ -ne '' }
  if ($p.Count -eq 3) {
    return ('[{0}].[{1}].[{2}]' -f $p[0],$p[1],$p[2])
  }
  if ($p.Count -eq 2) {
    return ('[{0}].[{1}]' -f $p[0],$p[1])
  }
  # If we can't confidently normalize, return the raw token.
  return $raw
}

  function Index-KeyPrefixMatches ([string]$indexKeyCols,[string[]]$wantedCols) {
    if ([string]::IsNullOrWhiteSpace($indexKeyCols)) { return $false }
    if (-not $wantedCols -or $wantedCols.Count -eq 0) { return $false }
    # indexKeyCols format from inspection: [Col] ASC, [Col2] DESC ...
    $idxCols = @()
    foreach ($seg in ($indexKeyCols -split ',\s*')) {
      $m = [regex]::Match($seg,'\[([^\]]+)\]')
      if ($m.Success) { $idxCols += $m.Groups[1].Value }
    }
    if ($idxCols.Count -lt $wantedCols.Count) { return $false }
    for ($i=0; $i -lt $wantedCols.Count; $i++) {
      if ($idxCols[$i] -ne $wantedCols[$i]) { return $false }
    }
    return $true
  }

  # Capture the ORDER BY keys required by Sort operators. We'll later compare these against
  # existing indexes if -InspectDatabase was requested.
  $sortOrderNeeds = @()
  $sortOpsForHints = @($operatorRows | Where-Object { $_.PhysicalOp -match '^Sort$' -and -not [string]::IsNullOrWhiteSpace($_.SortKeys) })
  if ($sortOpsForHints.Count -gt 0) {
    $byTableCols = @{}
    $byTableNodeIds = @{}
    foreach ($sop in $sortOpsForHints) {
      $sopNodeId = $sop.NodeId
      foreach ($tok in @($sop.SortKeys -split ',\s*')) {
        $x = Parse-SortKeyToken $tok
        if (-not $x) { continue }
        $tbl = Normalize-FullTable $x.Table
        if (-not $tbl) { continue }

        if (-not $byTableCols.ContainsKey($tbl)) {
          $byTableCols[$tbl] = New-Object System.Collections.Generic.List[string]
          $byTableNodeIds[$tbl] = New-Object 'System.Collections.Generic.HashSet[int]'
        }

        if (-not $byTableCols[$tbl].Contains($x.Column)) { [void]$byTableCols[$tbl].Add($x.Column) }
        if ($null -ne $sopNodeId -and $sopNodeId -ne '') { [void]$byTableNodeIds[$tbl].Add([int]$sopNodeId) }
      }
    }

    foreach ($k in $byTableCols.Keys) {
      $cols = @($byTableCols[$k])
      if ($cols.Count -gt 0) {
        $nodeIds = @()
        if ($byTableNodeIds.ContainsKey($k)) { $nodeIds = @($byTableNodeIds[$k] | Sort-Object) }
        $sortOrderNeeds += [pscustomobject]@{ FullTable = $k; Columns = $cols; SortNodeIds = $nodeIds }
      }
    }
  }

$sortIndexSuggestions = @() # populated later (after optional database inspection)
# Build a best-effort map of referenced columns per table in this statement (for INCLUDE suggestions).
# We only use this for "example CREATE INDEX" output; always validate in context.
$refColsByTable = @{}
try {
  $colRefs = Select-Nodes "//sp:ColumnReference"
  foreach ($cr in @($colRefs)) {
    $db = $cr.GetAttribute("Database")
    $schema = $cr.GetAttribute("Schema")
    $table = $cr.GetAttribute("Table")
    $col = $cr.GetAttribute("Column")

    if ([string]::IsNullOrWhiteSpace($table) -or [string]::IsNullOrWhiteSpace($col)) { continue }

    $db = if ($db) { $db.Trim().Trim('[',']') } else { $null }
    $schema = if ($schema) { $schema.Trim().Trim('[',']') } else { $null }
    $table = $table.Trim().Trim('[',']')
    $col = $col.Trim().Trim('[',']')

    $key =
      if ($db -and $schema) { ('[{0}].[{1}].[{2}]' -f $db,$schema,$table) }
      elseif ($schema)      { ('[{0}].[{1}]' -f $schema,$table) }
      else                  { ('[{0}]' -f $table) }

    if (-not $refColsByTable.ContainsKey($key)) {
      $refColsByTable[$key] = New-Object 'System.Collections.Generic.HashSet[string]'
    }
    [void]$refColsByTable[$key].Add($col)
  }
} catch {
  # best effort only
}

  # -----------------------------
  # Expression implicit conversions (Compute Scalar)
  #   These are usually NOT SARGability issues, but can indicate datatype mismatches or add CPU.
  # -----------------------------
  $expressionConvertImplicit = @()
  try {
    $computeScalarOps = Select-Nodes "//sp:RelOp[@PhysicalOp='Compute Scalar' or @LogicalOp='Compute Scalar']"
    foreach ($opNode in @($computeScalarOps)) {
      $nid = $opNode.GetAttribute("NodeId")
      if ([string]::IsNullOrWhiteSpace($nid)) { continue }
      # Skip if we already flagged a predicate-level CONVERT_IMPLICIT for this node
      $row = $operatorRows | Where-Object { $_.NodeId -eq [int]$nid } | Select-Object -First 1
      if ($row -and $row.HasConvertImplicit) { continue }

      $so = $opNode.SelectSingleNode(".//sp:ScalarOperator[contains(@ScalarString,'CONVERT_IMPLICIT')]",$nsm)
      if ($so) {
        $s = $so.GetAttribute("ScalarString")
        if ($s -and $s.Length -gt 220) { $s = $s.Substring(0,220) + "..." }
        $expressionConvertImplicit += [pscustomobject]@{
          NodeId = [int]$nid
          Operator = "Compute Scalar"
          Expression = $s
        }
      }
    }
  } catch {
    # best-effort only
  }


  # -----------------------------
  # -----------------------------
  # Estimated self-cost (delta) per operator
  #   EstSelfCost = EstTotalSubtreeCost - max(child EstTotalSubtreeCost)
  # Notes:
  # - ShowPlan XML does not always use a <Children> container. Child <RelOp> nodes
  #   are typically nested under the physical operator element (e.g. <Top>, <Sort>, <NestedLoops>, etc.).
  # - We treat a RelOp's "children" as descendant RelOps whose nearest ancestor RelOp is the current node.
  # - NodeIds can repeat across statements, so we key by StatementId|NodeId.
  # -----------------------------

  $costByKey = @{}
  foreach ($r in $operatorRows) {
    if ($r.NodeId -ne $null -and $r.EstCost -ne $null) {
      $k = ("{0}|{1}" -f [string]$r.StatementId,[string]$r.NodeId)
      $costByKey[$k] = [double]$r.EstCost
    }
  }

  $childMaxByKey = @{}
  $hasKidsByKey = @{}
  foreach ($op in $relOps) {
    $nodeIdKey = $op.GetAttribute("NodeId")
    if ([string]::IsNullOrWhiteSpace($nodeIdKey)) { continue }

    $stInfo = Get-StatementInfo $op
    $stmtIdKey = if ($stInfo) { [string]$stInfo.StatementId } else { "" }

    $kids = Get-DirectChildRelOps $op
    if (-not $kids -or @($kids).Count -eq 0) { continue }

    $pkTmp = ("{0}|{1}" -f $stmtIdKey,[string]$nodeIdKey)
    $hasKidsByKey[$pkTmp] = $true

    $maxChild = $null
    foreach ($k in $kids) {
      $cid = $k.GetAttribute("NodeId")
      if ([string]::IsNullOrWhiteSpace($cid)) { continue }

      $ck = ("{0}|{1}" -f $stmtIdKey,[string]$cid)
      if ($costByKey.ContainsKey($ck)) {
        $c = [double]$costByKey[$ck]
        if ($maxChild -eq $null -or $c -gt $maxChild) { $maxChild = $c }
      }
    }

    if ($maxChild -ne $null) {
      $pk = ("{0}|{1}" -f $stmtIdKey,[string]$nodeIdKey)
      $childMaxByKey[$pk] = $maxChild
    }
  }

  foreach ($r in $operatorRows) {
    if ($r.NodeId -eq $null -or $r.EstCost -eq $null) {
      $r | Add-Member -NotePropertyName HasKids -NotePropertyValue $false -Force
      $r | Add-Member -NotePropertyName EstSelfCost -NotePropertyValue $null -Force
      continue
    }

    $pk = ("{0}|{1}" -f [string]$r.StatementId,[string]$r.NodeId)
    $tot = [double]$r.EstCost
    $childMax = $null
    if ($childMaxByKey.ContainsKey($pk)) { $childMax = [double]$childMaxByKey[$pk] }

    $hasKids = $false
    if ($hasKidsByKey.ContainsKey($pk)) { $hasKids = [bool]$hasKidsByKey[$pk] }

    $self = if ($childMax -eq $null) {
      if ($hasKids) { 0.0 } else { $tot }
    } else {
      [math]::Max(0.0,($tot - $childMax))
    }
    $r | Add-Member -NotePropertyName HasKids -NotePropertyValue $hasKids -Force
    $r | Add-Member -NotePropertyName EstSelfCost -NotePropertyValue $self -Force
  }

  # Runtime stats presence (actual vs estimated plan)
  # -----------------------------
  $hasRuntimeStats = (@($operatorRows | Where-Object { $_.ActRows -ne $null -or $_.RowsRead -ne $null -or $_.Execs -ne $null }).Count -gt 0)


  # -----------------------------
  # Parameter sensitivity / sniffing hints (from plan XML)
  # -----------------------------
  $parameterSensitivity = @()
  $hasParameterSensitivePlan = $false
  $qpPsp = Select-Single ("//sp:QueryPlan[@ParameterSensitivePlan='true']")

  if ($qpPsp) { $hasParameterSensitivePlan = $true }

  $paramNodes = Select-Nodes ("//sp:ParameterList/sp:ColumnReference")

  foreach ($p in $paramNodes) {
    $name = $p.GetAttribute("Column")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $p.GetAttribute("Parameter") }
    $compiled = $p.GetAttribute("ParameterCompiledValue")
    $runtime = $p.GetAttribute("ParameterRuntimeValue")
    $ptype = $p.GetAttribute("ParameterDataType")
    if ([string]::IsNullOrWhiteSpace($ptype)) { $ptype = $p.GetAttribute("ParameterType") }

    $cNum = To-DoubleOrNull $compiled
    $rNum = To-DoubleOrNull $runtime

    $ratio = $null
    if ($cNum -ne $null -and $rNum -ne $null -and $cNum -ne 0) {
      $ratio = [math]::Abs($rNum / $cNum)
      if ($ratio -lt 1) { $ratio = 1 / $ratio }
    }

    $parameterSensitivity += [pscustomobject]@{
      Name = $name
      DataType = $ptype
      CompiledValue = $compiled
      RuntimeValue = $runtime
      ValueRatio = $ratio
    }
  }

  # High-risk parameter sensitivity candidates (needs both compiled + runtime values)
  $psIssues = @($parameterSensitivity | Where-Object {
      $_.RuntimeValue -and $_.CompiledValue -and $_.ValueRatio -ne $null -and $_.ValueRatio -ge 2
    })

  # Potential multi-column stats candidates from predicates (per table)
  function Get-ColumnRefsFromExpr ([string]$expr) {
    $out = @()
    if ([string]::IsNullOrWhiteSpace($expr)) { return $out }
    $re = [regex]'\[(?<db>[^\]]+)\]\.\[(?<sch>[^\]]+)\]\.\[(?<tbl>[^\]]+)\]\.\[(?<col>[^\]]+)\]'
    foreach ($m in $re.Matches($expr)) {
      $fullTable = "[{0}].[{1}].[{2}]" -f $m.Groups["db"].Value,$m.Groups["sch"].Value,$m.Groups["tbl"].Value
      $col = "[{0}]" -f $m.Groups["col"].Value
      $out += [pscustomobject]@{ FullTable = $fullTable; Column = $col }
    }
    return $out
  }

  $multiColPredicateCandidates = @()
  foreach ($op in $operatorRows) {
    $expr = $op.SeekPredicate
    if ([string]::IsNullOrWhiteSpace($expr)) { $expr = $op.Predicate }
    if ([string]::IsNullOrWhiteSpace($expr)) { $expr = $op.Residual }

    $refs = Get-ColumnRefsFromExpr $expr
    if ($refs.Count -eq 0) { continue }

    foreach ($g in ($refs | Group-Object FullTable)) {
      $cols = @($g.Group.Column | Select-Object -Unique)
      if ($cols.Count -ge 2) {
        $multiColPredicateCandidates += [pscustomobject]@{
          FullTable = $g.Name
          Columns = $cols
          ColumnsText = ($cols -join ", ")
          NodeId = $op.NodeId
          StatementId = $op.StatementId
          SamplePredicate = if ($expr.Length -gt 220) { $expr.Substring(0,220) + "..." } else { $expr }
        }
      }
    }
  }
  # -----------------------------
  # Views
  # -----------------------------
  $topOps = $operatorRows | Where-Object { $_.EstCost -ne $null } | Sort-Object EstCost -Descending | Select-Object -First $TopOperators

  $topSelfOps = $operatorRows | Where-Object { $_.EstSelfCost -ne $null } | Sort-Object EstSelfCost -Descending | Select-Object -First $TopOperators
  $readsHeavyOps = $operatorRows | Where-Object { $_.RowsRead -ne $null -and $_.RowsRead -gt 0 } | Sort-Object RowsRead -Descending | Select-Object -First $TopOperators

  $keyLookups = $operatorRows |
  Where-Object { $_.IsLookup -or $_.PhysicalOp -match "Key Lookup|RID Lookup" } |
  ForEach-Object {
    # LookupCalls = number of times the lookup operator executed.
    # For a Key Lookup, ActualExecutions (Execs) is the correct volume metric —
    # it counts how many rows the outer Nested Loop drove into the lookup.
    # ActRows * Execs would double-count because ActRows IS the per-execution output.
    $calls = $null
    if ($_.Execs -ne $null)          { $calls = $_.Execs }
    elseif ($_.ActRows -ne $null)    { $calls = $_.ActRows }
    elseif ($_.EstRows -ne $null)    { $calls = $_.EstRows }
    $_ | Add-Member -NotePropertyName LookupCalls -NotePropertyValue $calls -Force
    $_
  } | Sort-Object LookupCalls -Descending

  $sortOps = $operatorRows | Where-Object { $_.PhysicalOp -match "Sort" -or $_.LogicalOp -match "Sort" } | Sort-Object EstCost -Descending
  $parallelOps = $operatorRows | Where-Object { $_.PhysicalOp -match "Parallelism" }

  # -----------------------------
  # Cardinality issues (more useful + grouped summary)
  # -----------------------------
  $cardinalityIssues =
  $operatorRows |
  Where-Object {
    $_.ActRows -ne $null -and $_.EstRows -ne $null -and
    $_.Executed -ne $false -and
    $_.ActRows -gt 0 -and $_.EstRows -gt 0 -and
    $_.Ratio -ne $null -and
    $_.Ratio -ge $CEMismatchRatio -and
    ([math]::Max($_.ActRows,$_.EstRows) -ge $CEMinRows)
  } |
  ForEach-Object {
    $likely = @()
    if ($_.HasConvertImplicit) { $likely += "implicit conversion (CONVERT_IMPLICIT, column-side)" }
    elseif ($_.HasParamConvertImplicit) { $likely += "parameter-side implicit conversion (converted once; usually benign)" }  # v10
    if ($_.NonSargableHints) {
      $hints = $_.NonSargableHints -split ","
      foreach ($h in $hints) {
        switch ($h) {
          "convert_implicit" { }        # v10: reported via HasConvertImplicit line above
          "convert_implicit-param" { }  # v10: reported via HasParamConvertImplicit line above
          "leading-wildcard" { $likely += "leading-wildcard LIKE" }
          "date-fn" { $likely += "date function on column" }
          "string-fn" { $likely += "string function on column" }
          "case-fn" { $likely += "UPPER/LOWER on column" }
          default { $likely += "non-sargable ($h)" }
        }
      }
    }
    # v10 fix: with Access now classified correctly, only flag genuine scans as
    # "may not be seekable". Lookups and inner-side seeks under nested loops get
    # honest attributions — their row volume is rebind count, not a scan — keeping
    # this section consistent with the Key/RID lookup grid (LookupCalls).
    if ($_.IsLookup -or $_.Access -match "Lookup") {
      $likely += "key/RID lookup: row volume = outer join input (rebinds, not a scan)"
      if (-not [string]::IsNullOrWhiteSpace($_.Residual)) { $likely += "residual predicate evaluated per lookup call" }
    }
    elseif ($_.Access -eq "Index Seek") {
      if ($_.Execs -ne $null -and $_.Execs -gt 1) {
        $likely += ("inner-side seek: actual rows scale with outer input ({0:N0} executions)" -f $_.Execs)
      }
      elseif (-not [string]::IsNullOrWhiteSpace($_.Residual)) {
        $likely += "seek with residual predicate: residual selectivity may be misestimated"
      }
    }
    elseif ($_.Access -match "Scan") { $likely += "scan (predicate may not be seekable)" }
    if ($_.PhysicalOp -match "Nested Loops|Hash Match|Merge Join") { $likely += "join choice sensitive to CE" }
    if ($_.RowsRead -ne $null -and $_.ActRows -ne $null -and $_.RowsRead -gt ($_.ActRows * 10)) { $likely += "high read-to-return ratio" }
    if ($_.Rebinds -ne $null -and $_.Rebinds -gt 0) { $likely += "rebinds (possible repeated inner work)" }
    if ($_.Warnings) { $likely += "warnings ($($_.Warnings))" }

    $_ | Add-Member -NotePropertyName LikelyContributors -NotePropertyValue (($likely | Select-Object -Unique) -join "; ") -Force
    $_
  } |
  Sort-Object Severity -Descending |
  Select-Object -First 50

  $ceStatementSummary = $cardinalityIssues |
  Group-Object StatementId |
  ForEach-Object {
    $worst = $_.Group | Sort-Object Severity -Descending | Select-Object -First 1
    [pscustomobject]@{
      StatementId = $_.Name
      WorstNodeId = $worst.NodeId
      WorstRatio = $worst.Ratio
      WorstSeverity = $worst.Severity
      NodesFlagged = $_.Count
      StatementText = $worst.StatementText
    }
  } | Sort-Object WorstSeverity -Descending | Select-Object -First 10

  # -----------------------------
  # Missing index suggestions (robust XPath)
  # -----------------------------
  $missingIndexGroups = Select-Nodes "//sp:MissingIndexGroup"
  if (-not $missingIndexGroups -or @($missingIndexGroups).Count -eq 0) {
    # fallback (very defensive)
    $missingIndexGroups = Select-Nodes "//*[local-name()='MissingIndexGroup']"
  }

  $missingIndexes = @(
    foreach ($g in $missingIndexGroups) {
      $impact = To-DoubleOrNull ($g.GetAttribute("Impact"))
      $mi = $g.SelectSingleNode(".//sp:MissingIndex",$nsm)
      if (-not $mi) { continue }

      $db = $mi.GetAttribute("Database")
      $schema = $mi.GetAttribute("Schema")
      $table = $mi.GetAttribute("Table")
      $fullTable = (@($db,$schema,$table) | Where-Object { $_ -and $_ -ne "" }) -join "."

      $equalityCols = @()
      $inequalityCols = @()
      $includeCols = @()

      foreach ($cg in $mi.SelectNodes(".//sp:ColumnGroup",$nsm)) {
        $usage = $cg.GetAttribute("Usage")
        $cols = @()
        foreach ($c in $cg.SelectNodes(".//sp:Column",$nsm)) { $cols += ($c.GetAttribute("Name") -replace '^\[|\]$','') }
        switch ($usage) {
          "EQUALITY" { $equalityCols += $cols }
          "INEQUALITY" { $inequalityCols += $cols }
          "INCLUDE" { $includeCols += $cols }
        }
      }

      $keyCols = @()
      if ($equalityCols.Count -gt 0) { $keyCols += $equalityCols }
      if ($inequalityCols.Count -gt 0) { $keyCols += $inequalityCols }

      $safeTable = ($table -replace '[\[\]]','')
      $ixName = "IX_Tune_{0}_{1}" -f $safeTable,([guid]::NewGuid().ToString("N").Substring(0,8))

      $keySql = ($keyCols | ForEach-Object { "[{0}]" -f $_ }) -join ", "
      $incSql = ($includeCols | ForEach-Object { "[{0}]" -f $_ }) -join ", "

      $createSql = if ($includeCols.Count -gt 0 -and $incSql -ne "") {
        "CREATE INDEX [$ixName] ON $fullTable ($keySql) INCLUDE ($incSql);"
      } else {
        "CREATE INDEX [$ixName] ON $fullTable ($keySql);"
      }

      [pscustomobject]@{
        Impact = $impact
        FullTable = $fullTable
        EqualityCols = $equalityCols
        InequalityCols = $inequalityCols
        IncludeCols = $includeCols
        EqualityText = ($equalityCols | ForEach-Object { "[{0}]" -f $_ }) -join ", "
        InequalityText = ($inequalityCols | ForEach-Object { "[{0}]" -f $_ }) -join ", "
        IncludeText = ($includeCols | ForEach-Object { "[{0}]" -f $_ }) -join ", "
        SuggestedSql = $createSql
        Signature = "{0}|{1}|{2}|{3}" -f $fullTable,($equalityCols -join ","),($inequalityCols -join ","),($includeCols -join ",")
      }
    }
  )

  $missingIndexes = @($missingIndexes | Sort-Object Impact -Descending)

  # --- Smart Missing Index Merger ---
  # Groups recommendations by Table + Key Columns. If multiple recs have the same keys 
  # but different INCLUDEs, it merges them into a single superset index to prevent index bloat.
  $missingIndexDuplicates = @() # Kept empty so the legacy suggestions engine doesn't trip
  
  $mergedIndexes = @()
  $miGroups = $missingIndexes | Group-Object { $_.FullTable + "|" + ($_.EqualityCols -join ",") + "|" + ($_.InequalityCols -join ",") }

  foreach ($g in $miGroups) {
      $base = $g.Group[0]
      $mergedIncludes = New-Object System.Collections.Generic.HashSet[string]
      $maxImpact = 0

      foreach ($mi in $g.Group) {
          if ($mi.Impact -gt $maxImpact) { $maxImpact = $mi.Impact }
          if ($mi.IncludeCols) {
              foreach ($inc in $mi.IncludeCols) { [void]$mergedIncludes.Add($inc) }
          }
      }

      $incArray = @($mergedIncludes | Sort-Object)
      $incSql = ($incArray | ForEach-Object { "[{0}]" -f $_ }) -join ", "
      
      $safeTable = $base.FullTable.Split('.')[-1].Trim('[', ']')
      $ixName = "IX_Tune_{0}_{1}" -f $safeTable,([guid]::NewGuid().ToString("N").Substring(0,8))

      $keySql = @()
      if ($base.EqualityCols.Count -gt 0) { $keySql += ($base.EqualityCols | ForEach-Object { "[{0}]" -f $_ }) }
      if ($base.InequalityCols.Count -gt 0) { $keySql += ($base.InequalityCols | ForEach-Object { "[{0}]" -f $_ }) }
      $keySqlStr = ($keySql -join ", ")

      $createSql = if ($incArray.Count -gt 0) {
          "CREATE INDEX [$ixName] ON $($base.FullTable) ($keySqlStr) INCLUDE ($incSql);"
      } else {
          "CREATE INDEX [$ixName] ON $($base.FullTable) ($keySqlStr);"
      }

      $mergedIndexes += [pscustomobject]@{
          Impact = $maxImpact
          FullTable = $base.FullTable
          EqualityText = $base.EqualityText
          InequalityText = $base.InequalityText
          IncludeText = $incSql
          SuggestedSql = $createSql
          MergedCount = $g.Group.Count
      }
  }

  $missingIndexesUnique = $mergedIndexes | Sort-Object Impact -Descending
  $missingIndexesUniqueCount = @($missingIndexesUnique).Count


  # -----------------------------
  # DBA-focused heuristics
  # -----------------------------
  $joinChecks = @()
  foreach ($op in $operatorRows | Where-Object { $_.LogicalOp -match "Join" -or $_.PhysicalOp -match "Join|Nested Loops|Hash Match|Merge Join|Adaptive Join" }) {
    $rows = if ($op.ActRows -ne $null) { $op.ActRows } else { $op.EstRows }
    $execs = if ($op.Execs -ne $null -and $op.Execs -gt 0) { $op.Execs } else { $null }

    # Heuristic threshold: nested loops becomes suspicious when output is large.
    # 10k was noisy for OLTP-ish workloads; default to 100k to reduce false positives.
    if ($op.PhysicalOp -eq "Nested Loops" -and $rows -ne $null -and $rows -ge 100000) {
      $joinChecks += [pscustomobject]@{
        NodeId = $op.NodeId
        Join = $op.PhysicalOp
        Signal = "large join output"
        Rows = $rows
        Execs = $execs
        Object = $op.Object
        Detail = "Nested Loops with output rows $rows. If outer input is large, consider Hash/Merge join or indexing to support seeks."
      }
    }
    if ($op.PhysicalOp -eq "Merge Join" -and $sortOps.Count -gt 0) {
      $joinChecks += [pscustomobject]@{
        NodeId = $op.NodeId
        Join = $op.PhysicalOp
        Signal = "merge join + sort(s)"
        Rows = $rows
        Execs = $execs
        Object = $op.Object
        Detail = "Merge Join often wants ordered inputs. Sorts present; consider indexes on join keys to provide order and avoid sorts."
      }
    }
    if ($op.PhysicalOp -eq "Hash Match" -and $rows -ne $null -and $rows -ge 200000) {
      $joinChecks += [pscustomobject]@{
        NodeId = $op.NodeId
        Join = $op.PhysicalOp
        Signal = "large hash join"
        Rows = $rows
        Execs = $execs
        Object = $op.Object
        Detail = "Hash join with output rows $rows. Check memory grant, spills, and predicate selectivity."
      }
    }
    if ($op.PhysicalOp -eq "Adaptive Join") {
      $joinChecks += [pscustomobject]@{
        NodeId = $op.NodeId
        Join = $op.PhysicalOp
        Signal = "adaptive join"
        Rows = $rows
        Execs = $execs
        Object = $op.Object
        Detail = "Adaptive Join chosen. Ensure statistics are good; parameter sensitivity can push it to a suboptimal join type. If CE mismatches exist, the join algorithm can flip across executions."
      }
    }
  }
  $joinChecks = @($joinChecks | Sort-Object NodeId -Unique)



  # Many-to-many Merge Join detection (ShowPlan attribute)
  $manyToManyMergeSignals = @()
  try {
    $m2mMergeNodes = Select-Nodes (".//sp:RelOp[@PhysicalOp='Merge Join']//sp:Merge[@ManyToMany='true' or @ManyToMany='1']")
    foreach ($m in @($m2mMergeNodes)) {
      $rel = $m.SelectSingleNode("ancestor::sp:RelOp[1]",$nsm)
      if ($rel -ne $null) {
        $nid = [int]$rel.GetAttribute("NodeId")
        $manyToManyMergeSignals += [pscustomobject]@{
          NodeId = $nid
          Join = "Merge Join"
          Signal = "many-to-many merge join"
          Detail = "Many-to-many Merge Join detected. This can build worktables and amplify rows/memory. Consider join keys/order, indexes, and predicate selectivity."
        }
      }
    }
  } catch {}

  if (@($manyToManyMergeSignals).Count -gt 0) {
    # Add to joinChecks (avoid duplicates)
    $joinChecks += $manyToManyMergeSignals
    $joinChecks = @($joinChecks | Sort-Object NodeId -Unique)
  }

  # Spill detection (operator-level) from Warnings subtree with Quantification
  $spillSignals = @()
  try {
    $spillRelOps = Select-Nodes (".//sp:RelOp[.//sp:Warnings//*[contains(translate(local-name(),'SPILL','spill'),'spill')]]")
    foreach ($r in @($spillRelOps)) {
      $nid = [int]$r.GetAttribute("NodeId")
      $phys = $r.GetAttribute("PhysicalOp")
      if ($phys -notmatch '(?i)sort' -and $phys -notmatch '(?i)hash match') { continue }
      
      $warnNodes = $r.SelectNodes(".//sp:Warnings//*",$nsm)
      $names = @()
      $maxPages = 0
      $maxLevel = 0

      foreach ($wn in @($warnNodes)) {
        $ln = $wn.LocalName
        if ($ln -match "(?i)spill") { 
            $names += $ln 
            $p = To-DoubleOrNull ($wn.GetAttribute("SpilledPages"))
            $l = To-DoubleOrNull ($wn.GetAttribute("SpillLevel"))
            if ($p -gt $maxPages) { $maxPages = $p }
            if ($l -gt $maxLevel) { $maxLevel = $l }
        }
      }
      $names = @($names | Sort-Object -Unique)
      
      $detail = ""
      if ($maxPages -gt 0) {
          $mb = [math]::Round(($maxPages * 8) / 1024, 2)
          $detail = "Spilled $maxPages pages (~$mb MB) at Level $maxLevel. "
          
          if ($maxPages -gt 5000) {
              $detail += "SEVERE. Try OPTION (MIN_GRANT_PERCENT = 5) or higher to force a larger memory grant."
          } else {
              $detail += "Mild spill. Check if statistics are outdated causing an under-estimate."
          }
      } else {
          $detail = "Warnings: " + ($names -join ", ")
      }

      $spillSignals += [pscustomobject]@{
        NodeId = $nid
        Operator = $phys
        Signal = "spill to tempdb"
        Detail = $detail
      }
    }
  } catch {}

  # Parallelism skew detection (ActualRows imbalance across threads)
  $parallelSkewSignals = @()
  $skewScanned = 0
  try {
    $rtRelOps = Select-Nodes (".//sp:RelOp[sp:RunTimeInformation/sp:RunTimeCountersPerThread]")
    foreach ($r in @($rtRelOps)) {
      $threads = $r.SelectNodes("./sp:RunTimeInformation/sp:RunTimeCountersPerThread",$nsm)
      if ($threads -eq $null) { continue }
      $rows = @()
      foreach ($t in @($threads)) {
        $ar = $t.GetAttribute("ActualRows")
        if ($ar -ne $null -and $ar -ne "") { $rows += [double]$ar }
      }
      if ($rows.Count -lt 2) { continue }
      $skewScanned++
      $total = ($rows | Measure-Object -Sum).Sum
      if ($total -lt 5000) { continue } # ignore tiny ops
      $max = ($rows | Measure-Object -Maximum).Maximum
      $avg = $total / $rows.Count
      $ratio = if ($avg -gt 0) { $max / $avg } else { $null }
      if ($ratio -ne $null -and $ratio -ge 5) {
        $parallelSkewSignals += [pscustomobject]@{
          NodeId = [int]$r.GetAttribute("NodeId")
          Operator = $r.GetAttribute("PhysicalOp")
          Signal = "parallelism skew"
          Detail = ("Max thread rows {0}, Avg {1}, SkewRatio {2}" -f (F0 $max),(F0 $avg),(F2 $ratio))
          SkewRatio = $ratio
          TotalRows = $total
          Threads = $rows.Count
        }
      }
    }
  } catch {}

  # PlanAffectingConvert / implicit conversion signals
  $planAffectingConvertSignals = @()
  try {
    $pacs = Select-Nodes (".//sp:PlanAffectingConvert")
    foreach ($pac in @($pacs)) {
      $issue = $pac.GetAttribute("ConvertIssue")
      if ([string]::IsNullOrWhiteSpace($issue)) { $issue = $pac.GetAttribute("ConvertIssueType") }
      $expr = $pac.GetAttribute("Expression")
      if ([string]::IsNullOrWhiteSpace($expr)) { $expr = $pac.InnerText }
      if ($expr -and $expr.Length -gt 220) { $expr = $expr.Substring(0,220) + "..." }
      $planAffectingConvertSignals += [pscustomobject]@{
        StatementId = $chosenStmtId
        Issue = $issue
        Expression = $expr
        Detail = "Plan-affecting convert detected. Check parameter/column datatypes and implicit conversions (can hurt seeks and cardinality estimation)."
      }
    }
  } catch {}

  # Operator red flags
  $operatorRedFlags = @()
  foreach ($op in $operatorRows) {
    $rows = if ($op.ActRows -ne $null) { $op.ActRows } else { $op.EstRows }

    if ($op.PhysicalOp -match "Sort" -and $rows -ne $null -and $rows -ge 100000) {
      $operatorRedFlags += [pscustomobject]@{ NodeId = $op.NodeId; Operator = $op.PhysicalOp; Signal = "large sort"; Rows = $rows; Execs = $op.Execs; Object = $op.Object; Detail = "Sort on ~$rows rows. Consider index/order, reduce rowset, or memory grant/spill review." }
    }
    if ($op.PhysicalOp -match "Spool") {
      $operatorRedFlags += [pscustomobject]@{ NodeId = $op.NodeId; Operator = $op.PhysicalOp; Signal = "spool"; Rows = $rows; Execs = $op.Execs; Object = $op.Object; Detail = "Spool can indicate repeated work. Check Execs, joins, correlated subqueries, and indexing." }
    }
    if ($op.PhysicalOp -match "Table Spool" -and $op.Execs -ne $null -and $op.Execs -ge 1000) {
      $operatorRedFlags += [pscustomobject]@{ NodeId = $op.NodeId; Operator = $op.PhysicalOp; Signal = "high rebinds"; Rows = $rows; Execs = $op.Execs; Object = $op.Object; Detail = "Table Spool with Execs=$($op.Execs). Investigate nested loops rebinds / parameter sensitivity." }
    }
    if ($op.PhysicalOp -match "Hash Match" -and $rows -ne $null -and $rows -ge 200000) {
      $operatorRedFlags += [pscustomobject]@{ NodeId = $op.NodeId; Operator = $op.PhysicalOp; Signal = "large hash"; Rows = $rows; Execs = $op.Execs; Object = $op.Object; Detail = "Hash operator on ~$rows rows. Check memory grant and spills/tempdb." }
    }
    if ($op.PhysicalOp -match "Bitmap") {
      $operatorRedFlags += [pscustomobject]@{ NodeId = $op.NodeId; Operator = $op.PhysicalOp; Signal = "bitmap / index intersection"; Rows = $rows; Execs = $op.Execs; Object = $op.Object; Detail = "Bitmap usage can indicate index intersection. A composite index may be better." }
    }
  }
  $operatorRedFlags = @($operatorRedFlags | Sort-Object NodeId)

  # Predicate SARGability checks (heuristic)
  $rawSargIssues = @()
  
  function Add-SargIssue ([int]$nodeId,[string]$kind,[string]$expr) {
    if ([string]::IsNullOrWhiteSpace($expr)) { return }
    $short = if ($expr.Length -gt 220) { $expr.Substring(0,220) + "..." } else { $expr }
    $cleanKind = $kind -replace "\s*\(non-SARGable\)\s*","" -replace "\s*\(often non-SARGable\)\s*","" -replace "\s*\(non-SARGable likely\)\s*",""
    $rawSargIssues += [pscustomobject]@{ NodeId = $nodeId; Issue = $cleanKind; Expression = $short }
  }

  foreach ($op in $operatorRows) {
    foreach ($field in @("SeekPredicate","Predicate","Residual")) {
      $expr = $op.$field
      if ([string]::IsNullOrWhiteSpace($expr)) { continue }

      if ($expr -match "CONVERT_IMPLICIT") {
        $ciSide = Get-ConvertImplicitSide $expr   # v10
        $ciLabel = if ($ciSide -eq 'parameter') { "implicit conversion (parameter-side, usually benign)" } else { "implicit conversion (column-side)" }
        Add-SargIssue $op.NodeId $ciLabel $expr
      }
      if ($expr -match "(?i)\bLIKE\s+N?'%[^']*'") { Add-SargIssue $op.NodeId "leading wildcard LIKE" $expr }
      if ($expr -match "(?i)\b(UPPER|LOWER|SUBSTRING|LEFT|RIGHT|DATEADD|DATEDIFF|DATEPART|DATENAME|YEAR|MONTH|DAY|TRY_CONVERT|TRY_CAST|CONVERT|CAST)\s*\(") { Add-SargIssue $op.NodeId "function on column" $expr }
    }
  }

  $scalarOps = Select-Nodes ("//sp:ScalarOperator[@ScalarString]")
  $searchParam = @($parameterSensitivity | Where-Object { $_.Name -match "@Search" } | Select-Object -First 1)
  $searchVal = $null
  if ($searchParam) { $searchVal = if (-not [string]::IsNullOrWhiteSpace($searchParam.RuntimeValue)) { $searchParam.RuntimeValue } else { $searchParam.CompiledValue } }
  $searchLeadingWildcard = $false
  if ($searchVal -and ($searchVal -match "(?i)N?'%")) { $searchLeadingWildcard = $true }

  foreach ($soNode in $scalarOps) {
    $expr = $soNode.GetAttribute("ScalarString")
    if ([string]::IsNullOrWhiteSpace($expr)) { continue }

    $rel = $soNode.SelectSingleNode("ancestor::sp:RelOp[1]",$nsm)
    $nid = if ($rel) { To-IntOrNull ($rel.GetAttribute("NodeId")) } else { 0 }
    if ($nid -eq $null) { $nid = 0 }

    if ($expr -match "CONVERT_IMPLICIT") {
      $ciSide = Get-ConvertImplicitSide $expr   # v10
      $ciLabel = if ($ciSide -eq 'parameter') { "implicit conversion (parameter-side, usually benign)" } else { "implicit conversion (column-side)" }
      Add-SargIssue $nid $ciLabel $expr
    }

    if (($expr -match "(?i)\blike\s*\[?@Search\]?") -and $searchLeadingWildcard) {
      Add-SargIssue $nid "leading wildcard LIKE via @Search" ($expr + "  -- @Search=" + $searchVal)
    }

    if ($expr -match "(?i)\bLIKE\s+N?'%[^']*'") {
      Add-SargIssue $nid "leading wildcard LIKE" $expr
    }

    $hasColRef = ($expr -match "\[[^\]]+\]\.\[[^\]]+\]\.\[[^\]]+\]\.\[[^\]]+\]" -or $expr -match "\[(?!@)[^\]]+\]\.\[[^\]]+\]")
    if ($hasColRef -and ($expr -match "(?i)\b(UPPER|LOWER|SUBSTRING|LEFT|RIGHT|DATEADD|DATEDIFF|DATEPART|DATENAME|YEAR|MONTH|DAY|TRY_CONVERT|TRY_CAST|CONVERT|CAST|ISNULL|COALESCE)\s*\(")) {
      if ($expr -match "(?i)\b(CONVERT|CAST)\s*\([^)]*(\[[^\]]+\]\.\[[^\]]+\]\.\[[^\]]+\]\.\[[^\]]+\]|\[(?!@)[^\]]+\]\.\[[^\]]+\])(\s+as\s+\[(?!@)[^\]]+\]\.\[[^\]]+\])?") {
        Add-SargIssue $nid "convert/cast on column" $expr
      } elseif ($expr -match "(?i)\bISNULL\s*\(" -or $expr -match "(?i)\bCOALESCE\s*\(") {
        # Only flag ISNULL/COALESCE when they wrap a column as their first argument.
        # ISNULL(@param, default) or ISNULL([Expr1003], default) is value-side and SARGable.
        $isNullWrapsCol    = ($expr -match "(?i)\bISNULL\s*\(")    -and (Test-FunctionWrapsColumn $expr "ISNULL")
        $coalesceWrapsCol  = ($expr -match "(?i)\bCOALESCE\s*\(")  -and (Test-FunctionWrapsColumn $expr "COALESCE")
        if ($isNullWrapsCol -or $coalesceWrapsCol) {
          Add-SargIssue $nid "function on column" $expr
        }
      } else {
        Add-SargIssue $nid "function on column" $expr
      }
    }
  }

  foreach ($op in $operatorRows) {
    if (-not [string]::IsNullOrWhiteSpace($op.NonSargableHints)) {
      $hints = $op.NonSargableHints -split ","
      foreach ($h in $hints) {
        $h = $h.Trim()
        if (-not [string]::IsNullOrWhiteSpace($h)) {
          $expr = $op.Predicate
          if ([string]::IsNullOrWhiteSpace($expr)) { $expr = $op.Residual }
          if ([string]::IsNullOrWhiteSpace($expr)) { $expr = $op.SeekPredicate }
          if ([string]::IsNullOrWhiteSpace($expr)) { $expr = $op.JoinPredicate }

          # Prevent blank expressions from bubbling
          if ([string]::IsNullOrWhiteSpace($expr)) { continue }

          $short = if ($expr -and $expr.Length -gt 220) { $expr.Substring(0,220) + "..." } else { $expr }

          $issue = switch ($h) {
            "leading-wildcard" { "leading wildcard LIKE" }
            "date-fn" { "date function on column" }
            "string-fn" { "string function on column" }
            "case-fn" { "UPPER/LOWER on column" }
            "isnull()" {
              # Re-verify: only report if ISNULL actually wraps a column (not a param/Expr).
              # Get-NonSargableFlags already does this check, but the hint may have been
              # produced before Test-FunctionWrapsColumn was available in older cached rows.
              if (Test-FunctionWrapsColumn $expr "ISNULL") { "ISNULL on column (non-SARGable)" }
              else { $null }   # value-side ISNULL — suppress
            }
            "abs()" { "ABS() on column" }
            "try_convert()" { "TRY_CONVERT on column" }
            "try_cast()" { "TRY_CAST on column" }
            "convert()" { "CONVERT on column" }
            "convert_implicit" { "implicit conversion (column-side)" }
            "convert_implicit-param" { "implicit conversion (parameter-side, usually benign)" }   # v10
            default { "non-sargable ($h)" }
          }

          if ([string]::IsNullOrWhiteSpace($issue)) { continue }   # suppressed hint

          $rawSargIssues += [pscustomobject]@{ NodeId = $op.NodeId; Issue = $issue; Expression = $short }
        }
      }
    }
  }

  # Smart Deduplication: Group by Expression to eliminate bubbling and combine overlapping issues
  $sargMerged = @()
  foreach ($g in ($rawSargIssues | Group-Object Expression)) {
      $nodes = ($g.Group | Select-Object -ExpandProperty NodeId | Sort-Object -Unique) -join ", "
      $issues = ($g.Group | Select-Object -ExpandProperty Issue | Sort-Object -Unique) -join "; "
      $sargMerged += [pscustomobject]@{
          NodeIds = $nodes
          Issues = $issues
          Expression = $g.Name
      }
  }
  $sargabilityIssues = $sargMerged | Sort-Object NodeIds

  # Index intersection signals (heuristic):
  $indexIntersectionSignals = @()
  foreach ($op in $operatorRows | Where-Object { $_.PhysicalOp -match "Bitmap" -or $_.LogicalOp -match "Bitmap" }) {
    $indexIntersectionSignals += [pscustomobject]@{ NodeId = $op.NodeId; Operator = $op.PhysicalOp; Detail = "Bitmap present; may indicate index intersection. Consider a composite index that matches predicates/join keys." }
  }
  # Also detect bitmap filters embedded under other operators (e.g., Hash Match with Bitmap)
  $bitmapRelOps = Select-Nodes ("//sp:Bitmap/ancestor::sp:RelOp[1]")
  foreach ($r in $bitmapRelOps) {
    $nid = To-IntOrNull ($r.GetAttribute("NodeId"))
    if ($nid -eq $null) { continue }
    if (-not ($indexIntersectionSignals | Where-Object { $_.NodeId -eq $nid })) {
      $opName = $r.GetAttribute("PhysicalOp")
      if ([string]::IsNullOrWhiteSpace($opName)) { $opName = $r.GetAttribute("LogicalOp") }
      $indexIntersectionSignals += [pscustomobject]@{ NodeId = $nid; Operator = $opName; Detail = "Bitmap filter detected under this operator; may indicate index intersection/bitmap filtering." }
    }
  }

  # Also detect bitmap filtering expressed as PROBE(Opt_Bitmap...) in ScalarString (common with Hash Match)
  $probeNodes = Select-Nodes ("//sp:ScalarOperator[@ScalarString]")
  foreach ($pNode in $probeNodes) {
    $expr = $pNode.GetAttribute("ScalarString")
    if ([string]::IsNullOrWhiteSpace($expr)) { continue }
    if ($expr -match "(?i)\bPROBE\s*\(" -or $expr -match "Opt_Bitmap") {
      $rel = $pNode.SelectSingleNode("ancestor::sp:RelOp[1]",$nsm)
      $nid = $null
      if ($rel) { $nid = To-IntOrNull ($rel.GetAttribute("NodeId")) }
      if ($nid -eq $null) { $nid = 0 }
      if (-not ($indexIntersectionSignals | Where-Object { $_.NodeId -eq $nid })) {
        $indexIntersectionSignals += [pscustomobject]@{ NodeId = $nid; Operator = "(scalar predicate)"; Detail = "PROBE()/Opt_Bitmap detected in predicate; indicates bitmap filtering / index intersection behavior." }
      }
    }
  }



  # Rewrite hints (DBA-friendly, but still heuristic)
  $rewriteHints = New-Object System.Collections.Generic.List[string]
  if ($operatorRows | Where-Object { $_.PhysicalOp -match "TopN Sort" }) { $rewriteHints.Add("TopN Sort detected. Consider an index that matches the ORDER BY (and filters) to avoid sorting.") }
  $winRowMode = $operatorRows | Where-Object { $_.PhysicalOp -match "Window Spool|Sequence Project|Segment" }
  $winBatch   = $operatorRows | Where-Object { $_.PhysicalOp -match "Window Aggregate" }
  if ($winRowMode) { $rewriteHints.Add("Row-mode windowing pattern detected (Segment / Sequence Project / Window Spool). Consider indexing to support ORDER BY / PARTITION BY, or rewrite to reduce windowed rows.") }
  if ($winBatch)   { $rewriteHints.Add("Batch-mode Window Aggregate detected. This is the efficient replacement for the row-mode Window Spool pattern (enabled by a columnstore index or batch-mode-on-rowstore). Verify it isn't spilling and that the input row volume feeding it is controlled.") }
  if ($operatorRows | Where-Object { $_.PhysicalOp -match "Table Spool|Index Spool" }) { $rewriteHints.Add("Spool detected. Often caused by nested loops rebinds/correlation. Consider rewriting correlated subqueries, adding supporting indexes, or forcing a better join strategy.") }
  # v10: parameter-side-only conversions are not a non-SARGability problem; don't
  # raise the rewrite alarm for them.
  $hardSargIssues = @($sargabilityIssues | Where-Object {
    @(($_.Issues -split ';\s*') | Where-Object { $_ -and $_ -notmatch 'parameter-side' }).Count -gt 0
  })
  if ($hardSargIssues.Count -gt 0) { $rewriteHints.Add("Non-SARGable predicate signals found. Fix datatype mismatches, avoid functions on filtered columns, and avoid leading-wildcard LIKE when possible.") }
  if (@($indexIntersectionSignals).Count -gt 0) { $rewriteHints.Add("Bitmap/index-intersection signals found. A composite index may outperform intersection of multiple single-column indexes.") }
  if ($psIssues.Count -gt 0) { $rewriteHints.Add("Parameter sensitivity signals found. Consider (RECOMPILE), OPTIMIZE FOR, or alternative query shapes to reduce plan variance.") }

  # If we saw large sorts/hashes AND missing-index recommendations exist, tie them together for DBAs
  $largeSortFlag = @($operatorRedFlags | Where-Object { $_.Operator -match "^Sort$" -and $_.Signal -match "large sort" }).Count -gt 0
  if ($largeSortFlag -and @($missingIndexes).Count -gt 0) {
    $topMi = @($missingIndexes | Sort-Object Impact -Descending | Select-Object -First 2)
    $miSummary = ($topMi | ForEach-Object {
        $keys = @()
        if (-not [string]::IsNullOrWhiteSpace($_.EqualityText)) { $keys += $_.EqualityText }
        if (-not [string]::IsNullOrWhiteSpace($_.InequalityText)) { $keys += $_.InequalityText }
        $inc = if (-not [string]::IsNullOrWhiteSpace($_.IncludeText)) { " INCLUDE (" + $_.IncludeText + ")" } else { "" }
        ("{0} ON ({1}){2}" -f $_.FullTable,(($keys -join ", ") -replace "\s+"," "),$inc)
      }) -join "; "
    $rewriteHints.Add("Large sorts detected. Review missing-index recommendations that may eliminate sort/scan. Top candidates: $miSummary")
  }

  # -----------------------------
  # Suggestions
  # -----------------------------
  $suggestions = New-Object System.Collections.Generic.List[string]
  if (@($missingIndexes).Count -gt 0) {
    if (@($missingIndexes).Count -gt 1) { $suggestions.Add("Multiple missing-index suggestions found in XML ($(@($missingIndexes).Count)). Validate + de-dupe/merge before creating anything.") }
    else { $suggestions.Add("Missing index suggestion found in plan XML. Validate against workload + existing indexes (SSMS can hide/show inconsistently).") }
  }
  if (@($missingIndexDuplicates).Count -gt 0) { $suggestions.Add("Duplicate missing-index signatures found. Dedupe/merge before creating indexes.") }
  if ($cardinalityIssues.Count -gt 0) { $suggestions.Add("Cardinality mismatches found. Focus on highest Severity first; check stats, datatypes, predicates, and parameter sniffing patterns.") }
  if ($keyLookups.Count -gt 0) {
    $painful = $keyLookups | Where-Object { $_.LookupCalls -ne $null -and $_.LookupCalls -ge $LookupCallsThreshold }
    if ($painful.Count -gt 0) { $suggestions.Add("High-volume lookups detected (calls above threshold). Consider covering indexes or reducing selected columns.") }
    else { $suggestions.Add("Lookups detected. Review LookupCalls before changing indexes.") }
  }
  if ($sortOps.Count -gt 0) { $suggestions.Add("Sort operators present. Review SortKeys and ORDER BY; consider indexes/persisted computed columns, and memory grant/spills.") }
  if ($parallelOps.Count -gt 0) { $suggestions.Add("Parallelism present. If unstable, check skew/CXPACKET/CXCONSUMER, MAXDOP, and cost threshold.") }
  if ($memoryGrantInfo -and (
        ($null -ne $memoryGrantInfo.RequestedKB -and $memoryGrantInfo.RequestedKB -gt 0) -or
        ($null -ne $memoryGrantInfo.GrantedKB   -and $memoryGrantInfo.GrantedKB   -gt 0) -or
        ($null -ne $memoryGrantInfo.UsedKB      -and $memoryGrantInfo.UsedKB      -gt 0) -or
        ($null -ne $memoryGrantInfo.MaxUsedKB   -and $memoryGrantInfo.MaxUsedKB   -gt 0)
      )) { $suggestions.Add("Memory grant info present. Compare Granted vs Used/MaxUsed to spot spills or wasted grants.") }  # v10: require a non-zero value; all-zero grants have nothing to compare
  if (@($spillSignals).Count -gt 0) { $suggestions.Add("Spills detected in plan warnings. Investigate Sort/Hash spills, memory grants, and tempdb pressure.") }
  if (@($parallelSkewSignals).Count -gt 0) { $suggestions.Add("Parallelism skew detected (thread row imbalance). Investigate data distribution, join keys, and exchanges; consider different join/order or filtered/composite indexes.") }
  if (@($manyToManyMergeSignals).Count -gt 0) { $suggestions.Add("Many-to-many Merge Join detected. Check join predicates and indexing; this can amplify work via worktables and large memory use.") }
  if (@($planAffectingConvertSignals).Count -gt 0) { $suggestions.Add("Plan-affecting implicit conversions detected. Align datatypes (parameters/columns) to avoid conversion, CE issues, and non-seekable predicates.") }
  if (-not $hasRuntimeStats) { $suggestions.Add("Plan appears to lack runtime statistics (ActualRows/RowsRead/Execs). If possible capture an actual execution plan for better diagnostics.") }
  if ($spillLikely.Count -gt 0) { $suggestions.Add("Spill markers detected in plan XML. Investigate memory grants, hash/sort inputs, and tempdb.") }
  if ($hasParameterSensitivePlan) { $suggestions.Add("Parameter Sensitive Plan optimization detected. If performance varies by parameter, review PSP behavior and plan variants.") }
  if ($psIssues.Count -gt 0) { $suggestions.Add("Parameter sensitivity signals found (compiled vs runtime values differ). Consider parameter sniffing mitigations (OPTION(RECOMPILE), OPTIMIZE FOR, plan guides, or rewriting).") }
  if (@($joinChecks).Count -gt 0) { $suggestions.Add("Join strategy checks flagged potential issues. Review join types, input sizes, and supporting indexes.") }
  if (@($operatorRedFlags).Count -gt 0) { $suggestions.Add("Operator red flags detected (heuristic). Review spools/sorts/hashes and rebind patterns.") }
  if (@($sargabilityIssues | Where-Object {
        @(($_.Issues -split ';\s*') | Where-Object { $_ -and $_ -notmatch 'parameter-side' }).Count -gt 0
      }).Count -gt 0) { $suggestions.Add("Non-SARGable predicate signals detected. Review implicit conversions, functions on columns, and leading-wildcard LIKE patterns.") }  # v10: exclude parameter-side-only rows
  if (@($indexIntersectionSignals).Count -gt 0) { $suggestions.Add("Bitmap/index-intersection signals detected. Consider composite indexes that match predicates/join keys.") }

  # --- v9: CE model + hint signals (whole document, all statements) ---
  $ceModelInfo = @(Get-PlanCEModelInfo -PlanXml $xml -NsMgr $nsm)
  $hintSignals = @(Get-PlanHintSignals -PlanXml $xml -NsMgr $nsm)
  if (@($ceModelInfo | Where-Object { $_.CEVersion -eq 70 }).Count -gt 0) { $suggestions.Add("Plan compiled under legacy CE (model 70). CE feedback and most IQP features do not apply; identify the source (db-scoped config, USE HINT, TF 9481, or compat level) before chasing estimate quality.") }
  if (@($hintSignals).Count -gt 0) {
    $suggestions.Add("Query/table hints detected. Plan shape was mandated, not chosen by the optimizer - fix the underlying reason the hint was added before trusting what this plan appears to 'prefer'.")
    if (@($hintSignals | Where-Object { $_.Hint -match 'JOIN' }).Count -gt 0) { $suggestions.Add("Note: join algorithm/order is hint-forced, so any 'review join types' findings above reflect the mandated shape, not an optimizer choice.") }
  }

  $predicateConvertCount = @($operatorRows | Where-Object { $_.HasConvertImplicit }).Count
  $paramConvertCount = @($operatorRows | Where-Object { $_.HasParamConvertImplicit }).Count   # v10
  if ($predicateConvertCount -gt 0) {
    $suggestions.Add("Predicate implicit conversion(s) detected (CONVERT_IMPLICIT, column-side). These can prevent seeks and skew cardinality; align datatypes (parameters/columns) where possible.")
  }
  elseif ($paramConvertCount -gt 0) {
    # v10: parameter-side only — converted once per query, seek preserved; informational.
    $suggestions.Add("Parameter-side implicit conversion(s) detected (CONVERT_IMPLICIT on a parameter/variable). Usually benign for seeks; still worth aligning parameter datatypes with column types.")
  }
  if (@($expressionConvertImplicit).Count -gt 0) {
    $suggestions.Add("Expression implicit conversions detected in Compute Scalar. Usually not a seek blocker, but can add CPU or indicate upstream datatype mismatches.")
  }

  # -----------------------------
  # Optional: InspectDatabase (indexes/usage)
  # -----------------------------
  $dbInspection = $null
  $qsRegressions = @()
  $qsForcePlanScripts = @()
  if ($InspectDatabase) {
    if ([string]::IsNullOrWhiteSpace($ServerInstance) -or [string]::IsNullOrWhiteSpace($Database)) {
      throw "When using -InspectDatabase, you must supply -ServerInstance and -Database."
    }
    if (-not $script:dbatoolsAvailable) {
      $msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
      try { Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR" } catch { }
      throw $msg
    }

    # --- UPDATED: Connection via dbatools ---
    $connectParams = @{
        SqlInstance            = $ServerInstance
        Database               = $Database
        TrustServerCertificate = $true
        ErrorAction            = 'Stop'
    }

    # dbatools uses SqlCredential for SQL Authentication
    if ($SqlCredential) {
        $connectParams.SqlCredential = $SqlCredential
    }

    # Establish the SMO connection
    $smoServer = Connect-DbaInstance @connectParams

    # Extract the underlying .NET SqlConnection so the rest of your DataReader logic works unmodified
    $conn = $smoServer.ConnectionContext.SqlConnectionObject
    if ($conn.State -ne 'Open') { 
        $conn.Open() 
    }
    try {
      # --- v9: live compatibility level (authoritative; many actual plans omit DatabaseCompatLevel) ---
      $liveCompatLevel = $null
      try {
        $compatCmd = $conn.CreateCommand()
        $compatCmd.CommandText = "SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME();"
        $liveCompatLevel = [int]$compatCmd.ExecuteScalar()
        $compatCmd.Dispose()
      } catch { Write-Verbose ("Could not read compatibility_level: {0}" -f $_.Exception.Message) }

      # Determine target tables: from missing index recs + top expensive ops
      $targetTables = New-Object System.Collections.Generic.HashSet[string]
      foreach ($mi in $missingIndexes) {
        if ($mi.FullTable) { [void]$targetTables.Add($mi.FullTable) }
      }
      foreach ($op in ($topOps | Select-Object -First 25)) {
        if ($op.Object) {
          # object strings can be "db.schema.table (ix) | db.schema.table (ix)"
          $parts = $op.Object -split "\s+\|\s+"
          foreach ($p in $parts) {
            # strip "(index)" suffix
            $base = ($p -replace "\s+\(.*\)$","").Trim()
            if ($base -match "^\[.*\]\.\[.*\]\.\[.*\]$") { [void]$targetTables.Add($base) }
          }
        }
      }

      $tablesList = @($targetTables)
      $tableRows = @()

      if ($tablesList.Count -gt 0) {
        # Pass tables via table variable (avoid dynamic SQL & quoting headaches)
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 120

        $cmd.CommandText = @"
DECLARE @t TABLE (FullTable sysname NOT NULL);
-- filled by client

;WITH tgt AS (
  SELECT FullTable,
         DbName   = PARSENAME(FullTable,3),
         SchName  = PARSENAME(FullTable,2),
         ObjName  = PARSENAME(FullTable,1)
  FROM @t
),
obj AS (
  SELECT t.FullTable, o.object_id, s.name AS SchemaName, o.name AS TableName
  FROM tgt t
  JOIN sys.schemas s ON s.name = REPLACE(REPLACE(t.SchName,'[',''),']','')
  JOIN sys.objects o ON o.schema_id = s.schema_id AND o.name = REPLACE(REPLACE(t.ObjName,'[',''),']','')
  WHERE o.type = 'U'
)
SELECT
  o.FullTable,
  o.SchemaName,
  o.TableName,
  i.name  AS IndexName,
  i.index_id,
  i.type_desc,
  i.is_unique,
  i.is_primary_key,
  i.has_filter,
  i.filter_definition,

  kc.KeyCols,
  ic.IncludeCols,

  -- basic usage (optional; may be NULL if never used since last restart)
  us.user_seeks,
  us.user_scans,
  us.user_lookups,
  us.user_updates

FROM obj o
JOIN sys.indexes i
  ON i.object_id = o.object_id
 AND i.index_id > 0

OUTER APPLY
(
    SELECT
        KeyCols = STUFF((
            SELECT
                ', ' + QUOTENAME(c.name) + CASE WHEN ix.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
            FROM sys.index_columns AS ix
            JOIN sys.columns       AS c
              ON c.object_id = ix.object_id
             AND c.column_id = ix.column_id
            WHERE ix.object_id = i.object_id
              AND ix.index_id  = i.index_id
              AND ix.is_included_column = 0
              AND ix.key_ordinal > 0
            ORDER BY ix.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.','nvarchar(max)'), 1, 2, '')
) AS kc

OUTER APPLY
(
    SELECT
        IncludeCols = STUFF((
            SELECT
                ', ' + QUOTENAME(c.name)
            FROM sys.index_columns AS ix
            JOIN sys.columns       AS c
              ON c.object_id = ix.object_id
             AND c.column_id = ix.column_id
            WHERE ix.object_id = i.object_id
              AND ix.index_id  = i.index_id
              AND ix.is_included_column = 1
            ORDER BY ix.index_column_id
            FOR XML PATH(''), TYPE
        ).value('.','nvarchar(max)'), 1, 2, '')
) AS ic

LEFT JOIN sys.dm_db_index_usage_stats us
  ON us.database_id = DB_ID()
 AND us.object_id   = i.object_id
 AND us.index_id    = i.index_id

ORDER BY o.FullTable, i.index_id;
"@


        # Fill @t with parameters by sending a batch that inserts values then runs the query
        # Build client-side inserts safely using parameters
        $insertSql = "DECLARE @t TABLE (FullTable sysname NOT NULL);" + "`n"
        $pIndex = 0
        foreach ($t in $tablesList) {
          $pn = "@p$pIndex"
          $insertSql += "INSERT INTO @t(FullTable) VALUES ($pn);" + "`n"
          $p = $cmd.Parameters.Add($pn,[System.Data.SqlDbType]::NVarChar,512)
          $p.Value = $t
          $pIndex++
        }
        $cmd.CommandText = $insertSql + "`n" + ($cmd.CommandText -replace "DECLARE @t TABLE \(FullTable sysname NOT NULL\);\s*-- filled by client","")

        $r = $cmd.ExecuteReader()
        while ($r.Read()) {
          $tableRows += [pscustomobject]@{
            FullTable = $r["FullTable"]
            IndexName = $r["IndexName"]
            IndexId = $r["index_id"]
            TypeDesc = $r["type_desc"]
            IsUnique = $r["is_unique"]
            IsPrimaryKey = $r["is_primary_key"]
            HasFilter = $r["has_filter"]
            Filter = $r["filter_definition"]
            KeyCols = $r["KeyCols"]
            IncludeCols = $r["IncludeCols"]
            UserSeeks = $r["user_seeks"]
            UserScans = $r["user_scans"]
            UserLookups = $r["user_lookups"]
            UserUpdates = $r["user_updates"]
          }
        }
        $r.Close()
      }


      # -----------------------------
      # Stats inspection (staleness + definition) for target tables
      # -----------------------------
      $statsRows = @()
      $staleStats = @()
      $multiColStatsOpportunities = @()

      if ($tablesList.Count -gt 0) {
        $cmdStats = $conn.CreateCommand()
        $cmdStats.CommandTimeout = 120

        $cmdStats.CommandText = @"
DECLARE @t TABLE (FullTable sysname NOT NULL);
-- filled by client

;WITH tgt AS (
  SELECT FullTable,
         SchName  = PARSENAME(FullTable,2),
         ObjName  = PARSENAME(FullTable,1)
  FROM @t
),
obj AS (
  SELECT t.FullTable, o.object_id, s.name AS SchemaName, o.name AS TableName
  FROM tgt t
  JOIN sys.schemas s ON s.name = REPLACE(REPLACE(t.SchName,'[',''),']','')
  JOIN sys.objects o ON o.schema_id = s.schema_id AND o.name = REPLACE(REPLACE(t.ObjName,'[',''),']','')
  WHERE o.type = 'U'
)
SELECT
  o.FullTable,
  st.name AS StatsName,
  st.stats_id,
  st.auto_created,
  st.user_created,
  st.no_recompute,
  sp.last_updated,
  sp.[rows],
  sp.rows_sampled,
  sp.modification_counter,
  StatsCols =
    STUFF((
      SELECT ',' + QUOTENAME(c.name)
      FROM sys.stats_columns sc
      JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
      WHERE sc.object_id = st.object_id AND sc.stats_id = st.stats_id
      ORDER BY sc.stats_column_id
      FOR XML PATH(''), TYPE).value('.','nvarchar(max)')
    ,1,1,'')
FROM obj o
JOIN sys.stats st ON st.object_id = o.object_id
OUTER APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) sp
ORDER BY o.FullTable, st.name;
"@

        # Fill @t (reuse same tables list)
        $insertSql2 = "DECLARE @t TABLE (FullTable sysname NOT NULL);" + "`n"
        $pIndex2 = 0
        foreach ($t in $tablesList) {
          $pn = "@p$pIndex2"
          $insertSql2 += "INSERT INTO @t(FullTable) VALUES ($pn);" + "`n"
          $p = $cmdStats.Parameters.Add($pn,[System.Data.SqlDbType]::NVarChar,512)
          $p.Value = $t
          $pIndex2++
        }
        $cmdStats.CommandText = $insertSql2 + "`n" + ($cmdStats.CommandText -replace "DECLARE @t TABLE \(FullTable sysname NOT NULL\);\s*-- filled by client","")

        $r2 = $cmdStats.ExecuteReader()
        while ($r2.Read()) {
          $statsRows += [pscustomobject]@{
            FullTable = $r2["FullTable"]
            StatsName = $r2["StatsName"]
            StatsId = $r2["stats_id"]
            AutoCreated = [bool]$r2["auto_created"]
            UserCreated = [bool]$r2["user_created"]
            NoRecompute = [bool]$r2["no_recompute"]
            LastUpdated = $r2["last_updated"]
            Rows = $r2["rows"]
            RowsSampled = $r2["rows_sampled"]
            ModificationCounter = $r2["modification_counter"]
            Mods = $r2["modification_counter"]
            StatsCols = $r2["StatsCols"]
          }
        }
        $r2.Close()

        # Heuristic stale-stats detection
        foreach ($s in $statsRows) {
          $rows = To-DoubleOrNull ($s.Rows)
          $mods = To-DoubleOrNull ($s.ModificationCounter)
          $days = $null
          if ($s.LastUpdated -and $s.LastUpdated -is [datetime]) {
            $days = (New-TimeSpan -Start $s.LastUpdated -End (Get-Date)).TotalDays
          }

          $ratio = $null
          if ($rows -ne $null -and $rows -gt 0 -and $mods -ne $null) { $ratio = $mods / $rows }

          $isStale =
          (($mods -ne $null -and $mods -ge 500 -and $ratio -ne $null -and $ratio -ge 0.20) -or
            ($days -ne $null -and $days -ge 30 -and $mods -ne $null -and $mods -ge 1))

          if ($isStale) {
            $staleStats += [pscustomobject]@{
              FullTable = $s.FullTable
              StatsName = $s.StatsName
              StatsCols = $s.StatsCols
              LastUpdated = $s.LastUpdated
              Rows = $s.Rows
              ModificationCounter = $s.ModificationCounter
              Mods = $s.ModificationCounter
              ModRatio = $ratio
              DaysSinceUpdate = $days
            }
          }
        }

        # Multi-column stats opportunities (from predicate candidates) vs existing stats
        $existingStatsByTable = @{}
        foreach ($g in ($statsRows | Group-Object FullTable)) {
          $existingStatsByTable[$g.Name] = @($g.Group | ForEach-Object { $_.StatsCols })
        }

        foreach ($cand in ($multiColPredicateCandidates | Group-Object { $_.FullTable + "|" + $_.ColumnsText })) {
          $one = $cand.Group | Select-Object -First 1
          $tbl = $one.FullTable
          $need = $one.Columns

          $covered = $false
          if ($existingStatsByTable.ContainsKey($tbl)) {
            foreach ($colsText in $existingStatsByTable[$tbl]) {
              if ([string]::IsNullOrWhiteSpace($colsText)) { continue }
              $existingCols = $colsText -split "," | ForEach-Object { $_.Trim() }
              if ($existingCols.Count -ge $need.Count) {
                $prefix = $existingCols[0..($need.Count - 1)]
                if ((($prefix -join ",") -eq ($need -join ","))) { $covered = $true; break }
              }
            }
          }

          if (-not $covered) {
            $multiColStatsOpportunities += [pscustomobject]@{
              FullTable = $tbl
              Columns = ($need -join ", ")
              ExamplePredicate = $one.SamplePredicate
              ExampleNodeId = $one.NodeId
              StatementId = $one.StatementId
            }
          }
        }
      }


      if ($staleStats.Count -gt 0) {
        $suggestions.Add("Stale statistics candidates found on target tables. Consider updating stats before making plan/index changes.")
      }
      if ($multiColStatsOpportunities.Count -gt 0) {
        $suggestions.Add("Multi-column stats opportunities found (predicate column combos not covered by existing stats). Consider CREATE STATISTICS to improve CE.")
      }

      # Compare missing-index recs to existing indexes (simple overlap heuristic)
      $miCoverage = @()

      if (@($missingIndexes).Count -gt 0) {
        $miSigCounts = @{}
        foreach ($g in (@($missingIndexes) | Group-Object Signature)) {
          $miSigCounts[$g.Name] = $g.Count
        }

        $miSigSeen = @{}

        foreach ($mi in @($missingIndexes)) {
          $tbl = $mi.FullTable
          if (-not $tbl) { continue }

          $existing = $tableRows | Where-Object { $_.FullTable -eq $tbl }
          $needKeys = @()
          if ($mi.EqualityCols) { $needKeys += $mi.EqualityCols }
          if ($mi.InequalityCols) { $needKeys += $mi.InequalityCols }
          $needInc = @()
          if ($mi.IncludeCols) { $needInc += $mi.IncludeCols }

          $coveredBy = @()
          foreach ($ix in $existing) {
            $ixKeys = @()
            if ($ix.KeyCols) {
              # strip ASC/DESC and brackets
              $ixKeys = ($ix.KeyCols -split ",") | ForEach-Object { ($_ -replace "\s+(ASC|DESC)\s*$","").Trim() }
            }
            $ixInc = @()
            if ($ix.IncludeCols) { $ixInc = ($ix.IncludeCols -split ",") | ForEach-Object { $_.Trim() } }

            # naive check: needKeys is prefix of ixKeys (best case) OR subset (good enough)
            $needKeysQ = $needKeys | ForEach-Object { "[{0}]" -f $_ }
            $needIncQ = $needInc | ForEach-Object { "[{0}]" -f $_ }

            $keysSubset = $true
            foreach ($k in $needKeysQ) { if ($ixKeys -notcontains $k) { $keysSubset = $false; break } }

            $incSubset = $true
            foreach ($c in $needIncQ) { if ($ixInc -notcontains $c -and $ixKeys -notcontains $c) { $incSubset = $false; break } }

            if ($keysSubset -and $incSubset) { $coveredBy += $ix.IndexName }
          }

          $occ = 1
          if ($mi.Signature -and $miSigCounts.ContainsKey($mi.Signature)) { $occ = $miSigCounts[$mi.Signature] }

          if (-not $miSigSeen.ContainsKey($mi.Signature)) { $miSigSeen[$mi.Signature] = 0 }
          $miSigSeen[$mi.Signature]++
          $ord = $miSigSeen[$mi.Signature]
          $dupLabel = if ($occ -gt 1) { "dup #$ord" } else { "" }

          $miCoverage += [pscustomobject]@{
            FullTable = $tbl
            Impact = $mi.Impact
            Occurrences = $occ
            Duplicate = $dupLabel
            SuggestedKeys = (($needKeys | ForEach-Object { "[{0}]" -f $_ }) -join ", ")
            SuggestedIncludes = (($needInc | ForEach-Object { "[{0}]" -f $_ }) -join ", ")
            CoveredByExistingIndex = if ($coveredBy.Count -gt 0) { $coveredBy -join ", " } else { "" }
          }

        }

      }
      $dbInspection = [pscustomobject]@{
        ServerInstance = $ServerInstance
        Database = $Database
        CompatibilityLevel = $liveCompatLevel
        TargetTables = $tablesList
        Indexes = $tableRows
        Stats = $statsRows
        StaleStats = $staleStats
        MultiColumnStatsOpportunities = $multiColStatsOpportunities
        MissingIndexCoverage = $miCoverage
      }
    }
    finally {
      $conn.Close()
      $conn.Dispose()
    }
  }

  # --- v9: prefer the live compatibility level for CE model reporting ---
  # Many actual plans omit DatabaseCompatLevel, so when -InspectDatabase gives us the
  # authoritative value, backfill it and re-evaluate the signal. With a known compat
  # level we can also narrow the SOURCE of legacy CE instead of listing four suspects.
  # Caveat: this assumes the plan was captured from the inspected database; if the
  # .sqlplan came from elsewhere, the backfilled compat level may not apply.
  if ($dbInspection -and $null -ne $dbInspection.CompatibilityLevel) {
    $liveCompat = [int]$dbInspection.CompatibilityLevel
    foreach ($ceRow in @($ceModelInfo)) {
      if ($null -eq $ceRow.CompatLevel) {
        $ceRow.CompatLevel = $liveCompat
        if ($ceRow.CEVersion -eq 70) {
          if ($liveCompat -le 110) {
            $ceRow.Note = "Compiled under the pre-2014 estimator. Live compat level is $liveCompat (<= 110), which IS the source: raising the compatibility level moves this database to the modern CE. CE feedback and most IQP features do not apply until then."
          } else {
            $ceRow.Note = "Compiled under the pre-2014 estimator, but live compat level is $liveCompat (> 110) - so the source is LEGACY_CARDINALITY_ESTIMATION db-scoped config, a USE HINT in the query, or trace flag 9481, NOT the compat level. CE feedback and most IQP features do not apply."
          }
        }
        elseif ($ceRow.CEVersion -ne $liveCompat) {
          $ceRow.Signal = 'CE/compat mismatch'
          $ceRow.Note = "CE model $($ceRow.CEVersion) under live compat level $liveCompat - a hint, db-scoped config, or trace flag is pinning the estimator to a different version than the database default."
        }
      }
    }
  }

  # v9: CE version of the analysed (chosen) statement - the meaningful single value
  # for the bundle and trailer. First-row would report a setup statement's CE in
  # multi-statement captures, which is misleading.
  $chosenCEVersion = $null
  if ($chosenStmt) {
    $chosenCERow = @($ceModelInfo | Where-Object { [string]$_.StatementId -eq [string](Get-StmtKey $chosenStmt) }) | Select-Object -First 1   # v10: batch-qualified key on both sides
    if ($chosenCERow) { $chosenCEVersion = $chosenCERow.CEVersion }
  }
  if ($null -eq $chosenCEVersion -and @($ceModelInfo).Count -gt 0) { $chosenCEVersion = @($ceModelInfo)[0].CEVersion }

  # -----------------------------
  # Finalize sort/index suggestions now that we may have database metadata
  # -----------------------------
  if ($sortOrderNeeds -and $sortOrderNeeds.Count -gt 0) {
    foreach ($need in $sortOrderNeeds) {
      $k = $need.FullTable
      $cols = @($need.Columns)
      if (-not $k -or $cols.Count -eq 0) { continue }

      $coveringIndexNames = @()
      if ($InspectDatabase -and $dbInspection -and $dbInspection.Indexes) {
        $idxs = @($dbInspection.Indexes | Where-Object { $_.FullTable -eq $k })
        foreach ($ix in $idxs) {
          if (Index-KeyPrefixMatches $ix.KeyCols $cols) {
            $coveringIndexNames += $ix.IndexName
          }
        }
      }

      # Normalize/display covering indexes
      $coveringIndexNames = @($coveringIndexNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
      $covered = ($coveringIndexNames.Count -gt 0)
      $coveringIndexDisplay =
        if (-not $covered) { '(none)' }
        elseif ($coveringIndexNames.Count -le 3) { ($coveringIndexNames -join ', ') }
        else { ( ($coveringIndexNames | Select-Object -First 3) -join ', ' ) + (' (+' + ($coveringIndexNames.Count - 3) + ' more)') }

      $suggestedIndexSql = $null

      # Build a richer display of Sort NodeId(s) with cost/rows to make the impact obvious.
      $sortNodeDetailsDisplay = ''
      if ($need.SortNodeIds -and @($need.SortNodeIds).Count -gt 0) {
        $parts = @()
        foreach ($nid in @($need.SortNodeIds)) {
          $op = $null
          try { $op = @($sortOpsForHints | Where-Object { $_.NodeId -eq [int]$nid } | Select-Object -First 1) } catch { }
          if ($op) {
            $self = if ($op.EstSelfCost -ne $null) { "{0:N2}" -f [double]$op.EstSelfCost } else { "n/a" }

            $rowsVal = $null
            $rowsSrc = $null
            $act = $null
            $est = $null

            if ($op.ActRowsOut -ne $null -and $op.ActRowsOut -ne '') { $act = $op.ActRowsOut }
            if ($op.EstRows    -ne $null -and $op.EstRows    -ne '') { $est = $op.EstRows }

            if ($act -ne $null) { $rowsVal = $act; $rowsSrc = 'act' }
            elseif ($est -ne $null) { $rowsVal = $est; $rowsSrc = 'est' }

            # If we have both actual and estimated, show the estimate when it differs (helps spot CE issues at a glance).
            $rowsDisplay = "n/a"
            if ($rowsVal -ne $null) {
              $rowsDisplay = "{0} ({1})" -f $rowsVal,$rowsSrc
              if ($act -ne $null -and $est -ne $null) {
                try {
                  $a = [double]$act; $e = [double]$est
                  if ($a -ne 0 -and ([math]::Abs(($a-$e)/$a) -ge 0.10)) {
                    $rowsDisplay += (" (est={0})" -f $est)
                  }
                } catch {
                  if ($act.ToString() -ne $est.ToString()) { $rowsDisplay += (" (est={0})" -f $est) }
                }
              }
            }
            $parts += ("{0} (self(est)={1}, rows={2})" -f $nid,$self,$rowsDisplay)
          } else {
            $parts += ("{0}" -f $nid)
          }
        }
        $sortNodeDetailsDisplay = ($parts -join ', ')
      }

      # Best-effort INCLUDE candidates for this table (referenced columns excluding sort keys).
      $desiredIncludeCols = @()
      if ($refColsByTable -and $refColsByTable.ContainsKey($k)) { $desiredIncludeCols = @($refColsByTable[$k]) }
      $desiredIncludeCols = @($desiredIncludeCols | Where-Object { $cols -notcontains $_ } | Sort-Object -Unique)

      # If the order is already covered, warn if INCLUDE coverage differs (lookups may remain).
      $includeGapNote = ''
      if ($covered -and $InspectDatabase -and $dbInspection -and $dbInspection.Indexes -and $desiredIncludeCols.Count -gt 0) {
        $idxsForGap = @($dbInspection.Indexes | Where-Object { $_.FullTable -eq $k })
        $candidates = @($idxsForGap | Where-Object { Index-KeyPrefixMatches $_.KeyCols $cols })

        # v10: clustering-key columns live at the leaf of every nonclustered
        # index on the table, so they can never force a lookup and must not be
        # reported as INCLUDE gaps (e.g. Id on Posts under PK_Posts_Id).
        $clusteringKeyCols = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($cix in @($idxsForGap | Where-Object { $_.TypeDesc -match '^CLUSTERED' })) {
          foreach ($seg in ($cix.KeyCols -split ',\s*')) {
            $mm = [regex]::Match($seg,'\[([^\]]+)\]')
            if ($mm.Success) { [void]$clusteringKeyCols.Add($mm.Groups[1].Value) }
          }
        }

        $bestMissing = $null
        $bestIxName = $null
        foreach ($ix in $candidates) {
          # A clustered (rowstore or columnstore) index carries every column at
          # its leaf — nothing can be missing from it.
          if ($ix.TypeDesc -match '^CLUSTERED') {
            $bestMissing = @()
            $bestIxName = $ix.IndexName
            break
          }

          $avail = New-Object 'System.Collections.Generic.HashSet[string]'
          foreach ($ck in $clusteringKeyCols) { [void]$avail.Add($ck) }
          foreach ($seg in ($ix.KeyCols -split ',\s*')) {
            $mm = [regex]::Match($seg,'\[([^\]]+)\]')
            if ($mm.Success) { [void]$avail.Add($mm.Groups[1].Value) }
          }
          if ($ix.IncludeCols) {
            foreach ($seg in ($ix.IncludeCols -split ',\s*')) {
              $mm = [regex]::Match($seg,'\[([^\]]+)\]')
              if ($mm.Success) { [void]$avail.Add($mm.Groups[1].Value) }
            }
          }
          $missing = @()
          foreach ($c in $desiredIncludeCols) { if (-not $avail.Contains($c)) { $missing += $c } }
          if ($bestMissing -eq $null -or $missing.Count -lt $bestMissing.Count) {
            $bestMissing = $missing
            $bestIxName = $ix.IndexName
          }
        }
        if ($bestMissing -and $bestMissing.Count -gt 0) {
          $includeGapNote = ("Order is covered, but INCLUDE differs; may still see lookups for: {0} (e.g., on {1})." -f ($bestMissing -join ', '), $bestIxName)
        }
      }

if (-not $covered) {
  # Generate a readable, valid index name and a best-effort INCLUDE list based on referenced columns.
  $m = [regex]::Match($k,'\[(?<db>[^\]]+)\]\.\[(?<schema>[^\]]+)\]\.\[(?<table>[^\]]+)\]')
  $tableName = if ($m.Success) { $m.Groups['table'].Value } else { ($k -replace '.*\.\[','' -replace '\]$','') }
  $colSuffix = ($cols -join '_')
  $idxName = ("IX_{0}_{1}" -f $tableName,$colSuffix) -replace '[^A-Za-z0-9_]', '_' 
  $idxName = ($idxName -replace '_+','_').Trim('_')
  if ($idxName.Length -gt 120) { $idxName = $idxName.Substring(0,120) }

  $keyList = ($cols | ForEach-Object { '[' + $_ + '] ASC' }) -join ', '

  $includeCols = @($desiredIncludeCols)

  if ($includeCols.Count -gt 0) {
    $incList = ($includeCols | ForEach-Object { '[' + $_ + ']' }) -join ', '
    $suggestedIndexSql = ('CREATE INDEX {0} ON {1} ({2}) INCLUDE ({3});' -f $idxName,$k,$keyList,$incList)
  } else {
    $suggestedIndexSql = ('CREATE INDEX {0} ON {1} ({2});' -f $idxName,$k,$keyList)
  }
}

      $sortIndexSuggestions += [pscustomobject]@{
        FullTable = $k
        SortColumns = ($cols -join ', ')
        CoveredByExistingIndex = [bool]$covered
        CoveringIndexName = $coveringIndexDisplay
        SortNodeIds = @($need.SortNodeIds)
        SortNodeIdsDisplay =
          if ($need.SortNodeIds -and @($need.SortNodeIds).Count -gt 0) { (@($need.SortNodeIds) -join ', ') } else { '' }
        SortNodeDetailsDisplay = $sortNodeDetailsDisplay
        IncludeGapNote = $includeGapNote
        SuggestedCreateIndex = if ($suggestedIndexSql) { $suggestedIndexSql } else { '' }
      }
    }
  }

  # -----------------------------
  # Result object
  # -----------------------------
  $result = [pscustomobject]@{
    File = (Resolve-Path -LiteralPath $Path).Path
    NamespaceURI = $nsUri
    DegreeOfParallelism = $dop
    ObservedDegreeOfParallelism = $dopObserved
    ObservedDopParallelism = $dopObservedParallelism
    ObservedDopMaxRuntime = $dopObservedMaxRuntime
    MemoryGrantInfo = $memoryGrantInfo
    SpillSignalsFound = $spillLikely

    TopOperators = $topOps
    TopSelfOperators = $topSelfOps
    ReadsHeavyOps = $readsHeavyOps

    CardinalityIssues = $cardinalityIssues
    CEStatementSummary = $ceStatementSummary

    KeyLookups = $keyLookups
    SortOps = $sortOps
    SortIndexSuggestions = $sortIndexSuggestions
    ParallelismOps = $parallelOps

    MissingIndexes = $missingIndexes
    MissingIndexDuplicates = $missingIndexDuplicates

    ParameterSensitivity = $parameterSensitivity
    HasParameterSensitivePlan = $hasParameterSensitivePlan
    MultiColumnPredicateCandidates = $multiColPredicateCandidates
    JoinChecks = $joinChecks
    OperatorRedFlags = $operatorRedFlags
    SpillSignals = $spillSignals
    ParallelSkewSignals = $parallelSkewSignals
    ManyToManyMergeSignals = $manyToManyMergeSignals
    PlanAffectingConvertSignals = $planAffectingConvertSignals
    PredicateConvertImplicitCount = @($operatorRows | Where-Object { $_.HasConvertImplicit }).Count
    ExpressionConvertImplicit = $expressionConvertImplicit
    SargabilityIssues = $sargabilityIssues
    IndexIntersectionSignals = $indexIntersectionSignals
    CEModelInfo = $ceModelInfo
    HintSignals = $hintSignals
    RewriteHints = $rewriteHints.ToArray()


    Suggestions = $suggestions.ToArray()
    ReferenceLinks = $referenceLinks

    DbInspection = $dbInspection
  }


  if ($IncludeOperatorRows) {
    $result | Add-Member -NotePropertyName OperatorRows -NotePropertyValue $operatorRows -Force
  }

  # -----------------------------
  # Output
  # -----------------------------
  Write-Host ""
  Write-Host "=== SQL Plan Insights ===" -ForegroundColor Cyan
  Write-Host "File: $($result.File)"
  if ($chosenStmtSummary) {
    if ($chosenStmtReason) {
      Write-Host ("Statement chosen: Id={0} ({1}; use -Statement to override)" -f $chosenStmtSummary.StatementId, $chosenStmtReason) -ForegroundColor DarkCyan
      if ($script:otherStmtSummary) { Write-Host (" - Other statements in file: {0}" -f $script:otherStmtSummary) -ForegroundColor DarkGray }
    } else {
      Write-Host ("Statement chosen: Id={0}" -f $chosenStmtSummary.StatementId) -ForegroundColor DarkCyan
    }
    if ($chosenStmtSummary.StatementText) { Write-Host ("StatementText: {0}" -f $chosenStmtSummary.StatementText) -ForegroundColor DarkGray }
  }

  # --- NEW: Query Store Telemetry Bridge ---
  if ($ServerInstance -and $Database -and $queryHash -and $queryPlanHash) {
    try {
      $connectParams = @{
        SqlInstance            = $ServerInstance
        Database               = $Database
        TrustServerCertificate = $true
        ErrorAction            = 'Stop'
      }

      # dbatools uses SqlCredential for SQL Authentication
      if ($SqlCredential) {
          $connectParams.SqlCredential = $SqlCredential
      }

      # Establish the SMO connection
      $smoServer = Connect-DbaInstance @connectParams

      # Extract the underlying .NET SqlConnection so the rest of your DataReader logic works unmodified
      $conn = $smoServer.ConnectionContext.SqlConnectionObject
      if ($conn.State -ne 'Open') { 
          $conn.Open()
      }
      try {
      $cmd = $conn.CreateCommand()
      $cmd.CommandText = @"
      SELECT TOP 1
          rs.count_executions,
          CAST((rs.avg_duration / 1000.0) AS DECIMAL(18,2)) AS avg_duration_ms,
          CAST((rs.max_duration / 1000.0) AS DECIMAL(18,2)) AS max_duration_ms,
          CAST((rs.avg_cpu_time / 1000.0) AS DECIMAL(18,2)) AS avg_cpu_ms,
          rs.avg_logical_io_reads AS avg_logical_reads
      FROM sys.query_store_query qs
      JOIN sys.query_store_plan p ON qs.query_id = p.query_id
      JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
      WHERE qs.query_hash = CONVERT(VARBINARY(8), @QueryHash, 1)
        AND p.query_plan_hash = CONVERT(VARBINARY(8), @QueryPlanHash, 1)
      ORDER BY rs.last_execution_time DESC;
"@
      $p1 = $cmd.CreateParameter(); $p1.ParameterName = '@QueryHash';     $p1.Value = $queryHash;     [void]$cmd.Parameters.Add($p1)
      $p2 = $cmd.CreateParameter(); $p2.ParameterName = '@QueryPlanHash'; $p2.Value = $queryPlanHash; [void]$cmd.Parameters.Add($p2)
      $rdr = $cmd.ExecuteReader()
      if ($rdr.Read()) {
          Write-Host ""
          Write-Host "Query Store Telemetry (Recent Context):" -ForegroundColor Green
          Write-Host " - QueryHash : $queryHash | PlanHash : $queryPlanHash" -ForegroundColor DarkGray
          Write-Host (" - Executions: {0:N0}" -f $rdr["count_executions"]) -ForegroundColor Gray
          Write-Host (" - Avg CPU   : {0:N2} ms" -f $rdr["avg_cpu_ms"]) -ForegroundColor Gray
          Write-Host (" - Avg Time  : {0:N2} ms (Max: {1:N2} ms)" -f $rdr["avg_duration_ms"], $rdr["max_duration_ms"]) -ForegroundColor Gray
          Write-Host (" - Avg Reads : {0:N0} pages" -f $rdr["avg_logical_reads"]) -ForegroundColor Gray
          
          # Severity heuristics
          $execs = [long]$rdr["count_executions"]
          $cpu = [decimal]$rdr["avg_cpu_ms"]
          if ($execs -gt 1000 -and $cpu -gt 250) {
              Write-Host " [!] HIGH IMPACT: This plan burns significant CPU and runs frequently. Tuning this is a priority." -ForegroundColor Red
          }

          $rdr.Close() # Close the first reader so we can run a second query

          # --- NEW: Automated Plan Regression Detection ---
          $cmdReg = $conn.CreateCommand()
          $cmdReg.CommandText = @"
          SELECT TOP 1
              p.plan_id,
              qs.query_id,
              CAST((rs.avg_cpu_time / 1000.0) AS DECIMAL(18,2)) AS hist_avg_cpu_ms
          FROM sys.query_store_query qs
          JOIN sys.query_store_plan p ON qs.query_id = p.query_id
          JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
          WHERE qs.query_hash = CONVERT(VARBINARY(8), @QueryHash, 1)
            AND p.query_plan_hash <> CONVERT(VARBINARY(8), @QueryPlanHash, 1)
            AND (rs.avg_cpu_time / 1000.0) < (@CpuMs * 0.5) -- Look for plans at least 50% cheaper
          ORDER BY rs.avg_cpu_time ASC;
"@
          $r1 = $cmdReg.CreateParameter(); $r1.ParameterName = '@QueryHash';     $r1.Value = $queryHash;     [void]$cmdReg.Parameters.Add($r1)
          $r2 = $cmdReg.CreateParameter(); $r2.ParameterName = '@QueryPlanHash'; $r2.Value = $queryPlanHash; [void]$cmdReg.Parameters.Add($r2)
          $r3 = $cmdReg.CreateParameter(); $r3.ParameterName = '@CpuMs';         $r3.Value = $cpu;           [void]$cmdReg.Parameters.Add($r3)
          $rdrReg = $cmdReg.ExecuteReader()
          if ($rdrReg.Read()) {
              Write-Host ""
              Write-Host " [!] PLAN REGRESSION DETECTED (Query Store)" -ForegroundColor Magenta
              Write-Host (" - A historical plan (PlanId: {0}) averaged only {1:N2} ms of CPU (50%+ less than current)." -f $rdrReg["plan_id"], $rdrReg["hist_avg_cpu_ms"]) -ForegroundColor Gray
              Write-Host " - To instantly revert to the better historical plan, run:" -ForegroundColor DarkGray
              Write-Host ("   EXEC sp_query_store_force_plan @query_id = {0}, @plan_id = {1};" -f $rdrReg["query_id"], $rdrReg["plan_id"]) -ForegroundColor Cyan

              # capture for the -OutFile JSON bundle (reader still open)
              $qsRegressions += [pscustomobject]@{
                queryId         = $rdrReg["query_id"]
                objectName      = "(adhoc)"
                regressedMetric = "avg CPU (ms)"
                beforeMs        = $rdrReg["hist_avg_cpu_ms"]
                afterMs         = $cpu
                goodPlanId      = $rdrReg["plan_id"]
                badPlanId       = $null
              }
              $qsForcePlanScripts += [pscustomobject]@{
                queryId = $rdrReg["query_id"]
                planId  = $rdrReg["plan_id"]
                script  = ("EXEC sp_query_store_force_plan @query_id = {0}, @plan_id = {1};" -f $rdrReg["query_id"], $rdrReg["plan_id"])
              }
          } else {
              Write-Host " - Plan Regression Check: No cheaper historical plans found (current plan is optimal or the only plan)." -ForegroundColor DarkGray
          }
          $rdrReg.Close()
          # ------------------------------------------------

      } else {
          Write-Host ""
          Write-Host "Query Store Telemetry: No runtime stats found for this specific Plan Hash." -ForegroundColor DarkGray
      }
      } finally {
        if ($conn -and $conn.State -ne 'Closed') { $conn.Close() }
      }
    } catch {
      Write-Host ""
      Write-Host "Query Store Telemetry: Failed to connect or query QDS ($($_.Exception.Message.Substring(0,[math]::Min($_.Exception.Message.Length, 60))))..." -ForegroundColor DarkGray
    }
  }
  # -----------------------------
  # Emit sqlplan-insights JSON bundle for the HTML Plan Visualizer.
  # Placed after the Query Store step (so QS findings are folded in) but before the
  # main reporting section (so nothing downstream can prevent the file being written).
  # -----------------------------
  if ($OutFile) {
    Write-Host ""
    $outFull = $OutFile
    try {
      if ([System.IO.Path]::IsPathRooted($OutFile)) { $outFull = [System.IO.Path]::GetFullPath($OutFile) }
      else { $outFull = [System.IO.Path]::GetFullPath((Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $OutFile)) }
    } catch { $outFull = $OutFile }
    # v10: stamp the bundle filename with the run date/time so successive runs
    # don't overwrite each other (plan.json -> plan_20260713_142530.json).
    try {
      $outDir = [System.IO.Path]::GetDirectoryName($outFull)
      $outBase = [System.IO.Path]::GetFileNameWithoutExtension($outFull)
      $outExt = [System.IO.Path]::GetExtension($outFull)
      if ([string]::IsNullOrWhiteSpace($outExt)) { $outExt = ".json" }
      $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
      $outFull = [System.IO.Path]::Combine($outDir, ("{0}_{1}{2}" -f $outBase, $stamp, $outExt))
    } catch { }
    Write-Host ("[-OutFile] Writing sqlplan-insights bundle -> {0}" -f $outFull) -ForegroundColor Cyan
    try {
      if (-not $xmlText) { Write-Warning "[-OutFile] Plan XML is empty; the bundle will not load without a -Path plan." }
      # Windows PowerShell serializes [datetime] as "/Date(ms)/"; convert to ISO yyyy-MM-dd so the page shows readable dates.
      if ($result.DbInspection) {
        foreach ($coll in @('Stats','StaleStats')) {
          foreach ($st in @($result.DbInspection.$coll)) {
            if ($st -and $st.PSObject.Properties.Match('LastUpdated').Count -gt 0 -and $st.LastUpdated -is [datetime]) {
              $st.LastUpdated = $st.LastUpdated.ToString('yyyy-MM-dd')
            }
          }
        }
      }
      # Fold any captured Query Store findings into the inspection block the page renders.
      if ($result.DbInspection -and (@($qsRegressions).Count -gt 0 -or @($qsForcePlanScripts).Count -gt 0)) {
        $result.DbInspection | Add-Member -NotePropertyName QueryStore -NotePropertyValue ([pscustomobject]@{
          regressions      = $qsRegressions
          forcePlanScripts = $qsForcePlanScripts
        }) -Force
      }
      $bundle = [pscustomobject]@{
        schema            = 'sqlplan-insights/1'
        generatedAt       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        server            = $ServerInstance
        database          = $Database
        dop               = $result.DegreeOfParallelism
        inspectedDatabase = [bool]($InspectDatabase -and $result.DbInspection)
        planXml           = $xmlText
        dbInspection      = $result.DbInspection
        analysis          = [pscustomobject]@{
          cardinalityIssues = @($result.CardinalityIssues).Count
          missingIndexes    = @($result.MissingIndexes).Count
          spills            = @($result.SpillSignals).Count
          redFlags          = @($result.OperatorRedFlags).Count
          ceModelVersion    = $chosenCEVersion
          hintSignals       = @($result.HintSignals).Count
          suggestions       = @($result.Suggestions).Count
        }
      }
      $json = $bundle | ConvertTo-Json -Depth 12
      [System.IO.File]::WriteAllText($outFull, $json, (New-Object System.Text.UTF8Encoding($false)))
      if (Test-Path -LiteralPath $outFull) {
        Write-Host ("[-OutFile] Wrote {0:N0} bytes -> {1}" -f (Get-Item -LiteralPath $outFull).Length, $outFull) -ForegroundColor Green
      } else {
        Write-Warning "[-OutFile] WriteAllText reported success but no file is present at $outFull"
      }
    } catch {
      Write-Warning ("[-OutFile] Failed to write bundle: {0}" -f $_.Exception.Message)
    }
  }

  if ($SanityCheck) {
    Write-Host ("SanityCheck: missingIndexGroups={0}, missingIndexes={1}, links={2}" -f `
         (@($missingIndexGroups).Count),(@($missingIndexes).Count),($referenceLinks.PSObject.Properties.Count)) -ForegroundColor DarkCyan
  }

$mismatches = $operatorRows | Where-Object { 
    $_.ActRows -ne $null -and 
    $_.Ratio -gt $CEMismatchRatio -and 
    $_.ActRows -gt $CEMinRows 
} | Sort-Object -Property Ratio -Descending | 
Select-Object -Property NodeId, 
                        PhysicalOp, 
                        EstRows, 
                        ActRows, 
                        @{ Name = 'Ratio'; Expression = { F2 $_.Ratio } }, 
                        Object

if ($mismatches) {
    Write-Host ""
    Write-Host "Significant Cardinality Estimate Mismatches Detected:" -ForegroundColor Yellow
    $mismatches | Format-Table -AutoSize
}
else { Write-Host ""
       Write-Host "No Cardinality Estimate Mismatches Detected" -ForegroundColor Yellow}

# wait stats
# v10: use the statement-scoped selector (not $xml directly) so multi-batch
# files don't merge every statement's WaitStats into one grid with duplicate
# WaitTypes; group-by as a second line of defence and to keep totals honest.
$waitNodes = Select-Nodes "//sp:WaitStats/sp:Wait"
$waitStatsReport = @()

if ($waitNodes.Count -gt 0) {
    $waitStatsReport = @($waitNodes) | ForEach-Object {
        [pscustomobject]@{
            WaitType   = $_.GetAttribute("WaitType")
            WaitTimeMs = [double]$_.GetAttribute("WaitTimeMs")
            WaitCount  = [int]$_.GetAttribute("WaitCount")
        }
    } | Group-Object WaitType | ForEach-Object {
        $tms = ($_.Group | Measure-Object WaitTimeMs -Sum).Sum
        $cnt = ($_.Group | Measure-Object WaitCount -Sum).Sum
        [pscustomobject]@{
            WaitType   = $_.Name
            WaitTimeMs = $tms
            WaitCount  = $cnt
            AvgWaitMs  = if ($cnt -gt 0) { [math]::Round(($tms / $cnt), 3) } else { 0 }
        }
    }

    # Sort by longest wait time
    $waitStatsReport = $waitStatsReport | Sort-Object WaitTimeMs -Descending

    Write-Host ""
    Write-Host "Query Wait Statistics (Actual Plan Only):" -ForegroundColor Yellow
    $waitStatsReport | Format-Table -AutoSize
}
else {
    # v10: distinguish "no waits" from "section silently missing" — the chosen
    # statement may simply have recorded no waits, or this may be an estimated plan.
    Write-Host ""
    Write-Host "Query Wait Statistics (Actual Plan Only):" -ForegroundColor Yellow
    Write-Host " - (none recorded for the chosen statement - either no waits exceeded the capture threshold, or this is an estimated plan)" -ForegroundColor DarkGray
}

  $dopPlannedText = if ($dop -ne $null -and $dop -gt 0) { $dop } else { "n/a" }
  $dopObservedText = if ($dopObserved -ne $null -and $dopObserved -gt 0) { $dopObserved } else { "n/a" }
  $dopParText = if ($dopObservedParallelism -ne $null -and $dopObservedParallelism -gt 0) { $dopObservedParallelism } else { "n/a" }
  $dopMaxText = if ($dopObservedMaxRuntime -ne $null -and $dopObservedMaxRuntime -gt 0) { $dopObservedMaxRuntime } else { "n/a" }

  Write-Host ""
  Write-Host ("DOP: planned={0} observed={1} (parallelism={2} maxRuntime={3})" -f $dopPlannedText,$dopObservedText,$dopParText,$dopMaxText)


  $hasMGNumbers = $memoryGrantInfo -and (
    $null -ne $memoryGrantInfo.RequestedKB -or $null -ne $memoryGrantInfo.GrantedKB -or
    $null -ne $memoryGrantInfo.UsedKB -or $null -ne $memoryGrantInfo.MaxUsedKB -or
    $null -ne $memoryGrantInfo.GrantWaitMS
  )

  function F3orNA ($v) { if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { "n/a" } else { F3 $v } }
  $mgFeedback = if ($memoryGrantInfo -and -not [string]::IsNullOrWhiteSpace($memoryGrantInfo.FeedbackAdjusted)) { $memoryGrantInfo.FeedbackAdjusted } else { "n/a" }

  if ($hasMGNumbers) {
    Write-Host ("Memory grant KB: Requested={0} Granted={1} Used={2} MaxUsed={3} WaitMS={4} FeedbackAdjusted={5}" -f `
         (F3orNA $memoryGrantInfo.RequestedKB),
      (F3orNA $memoryGrantInfo.GrantedKB),
      (F3orNA $memoryGrantInfo.UsedKB),
      (F3orNA $memoryGrantInfo.MaxUsedKB),
      (F3orNA $memoryGrantInfo.GrantWaitMS),
      $mgFeedback) -ForegroundColor DarkCyan

    Write-Host ""
    # Memory grant analysis (heuristic)
    $mgGranted = $null; $mgMaxUsed = $null
    try { $mgGranted = [double]$memoryGrantInfo.GrantedKB } catch {}
    try { $mgMaxUsed = [double]$memoryGrantInfo.MaxUsedKB } catch {}
    if ($mgGranted -and $mgGranted -gt 0 -and $mgMaxUsed -ne $null) {
      $wastePct = (($mgGranted - $mgMaxUsed) / $mgGranted) * 100.0
      $underPct = 0.0
      if ($mgMaxUsed -gt $mgGranted) { $underPct = (($mgMaxUsed - $mgGranted) / $mgGranted) * 100.0 }
      $mgNotes = New-Object System.Collections.Generic.List[string]
      if ($wastePct -ge 50) { $mgNotes.Add("high grant waste") }
      if ($underPct -gt 0) { $mgNotes.Add("possible undergrant/spill risk") }
      if ($mgFeedback -ne "n/a" -and $mgFeedback -match "Adjust") { $mgNotes.Add("MG feedback active") }
      $noteText = if ($mgNotes.Count -gt 0) { (" (" + ($mgNotes -join "; ") + ")") } else { "" }
      Write-Host ("Memory grant analysis: WastePct={0}% UnderPct={1}%{2}" -f (F2 $wastePct),(F2 $underPct),$noteText)
    }
  }
  else {
    Write-Host ("Memory grant: n/a") -ForegroundColor DarkCyan
  }

  if (-not $hasRuntimeStats) {
    Write-Host ("Runtime stats: n/a (estimated plan or plan export without execution counters)") -ForegroundColor DarkCyan
  }

  if ($spillLikely.Count -gt 0) { Write-Host ("Spill markers in XML: {0}" -f ($spillLikely -join ", ")) -ForegroundColor DarkYellow }

  Write-Host ""
  Write-Host "Top operators by EstimatedTotalSubtreeCost:" -ForegroundColor Yellow
  $result.TopOperators | Sort-Object NodeId -Descending |
  Select-Object `
     @{ n = 'NodeId'; e = { $_.NodeId } },
  @{ n = 'PhysicalOp'; e = { $_.PhysicalOpDisplay } },
  @{ n = 'LogicalOp'; e = { $_.LogicalOp } },
  @{ n = 'EstCost'; e = { F2 $_.EstCost } },
  @{ n = 'SelfCost'; e = { if ($_.HasKids -and ($null -eq $_.EstSelfCost -or $_.EstSelfCost -eq '')) { '0.00' } else { F2 $_.EstSelfCost } } },
  @{ n = 'EstRows'; e = { F0 $_.EstRows } },
  @{ n = 'ActOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '') { F0 $_.ActRowsOut } else { '' } } },
  @{ n = 'ActWork'; e = { if ($_.ActRowsWork -ne $null -and $_.ActRowsWork -ne '') { F0 $_.ActRowsWork } else { '' } } },
  @{ n = 'RatioOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '' -and $_.EstRows -ne $null -and $_.EstRows -ne '' -and [double]$_.EstRows -ne 0) { F3 (([double]$_.ActRowsOut) / ([double]$_.EstRows)) } else { '' } } },
  @{ n = 'RatioWork'; e = { if ($_.ActRowsWork -ne $null -and $_.ActRowsWork -ne '' -and $_.EstRows -ne $null -and $_.EstRows -ne '' -and [double]$_.EstRows -ne 0) { F3 (([double]$_.ActRowsWork) / ([double]$_.EstRows)) } else { '' } } },
  @{ n = 'RowsRead'; e = { F0 $_.RowsRead } },
  @{ n = 'Execs'; e = { F0 $_.Execs } },
  @{ n = 'Access'; e = { $_.Access } },
  @{ n = 'Warnings'; e = { $_.Warnings } } |
  Format-Table -AutoSize
  Write-ObjectKey ($result.TopOperators | Sort-Object NodeId -Descending)

  # --- NEW: Explanatory Blurb for Top Operators ---
  Write-Host "  Note: Operators highlighted with >> << (e.g., >> SORT <<, >> HASH MATCH <<) are heavy execution nodes" -ForegroundColor DarkGray
  Write-Host "  that frequently cause TempDB spills, CPU spikes, or memory grant issues. " -ForegroundColor DarkGray
  Write-Host "  This grid is filtered to the most expensive operators, excluding trivial/zero-cost nodes (like Compute Scalars) " -ForegroundColor DarkGray
  Write-Host "  and nodes that fall below the Top N cost threshold, focusing your attention on the true bottlenecks." -ForegroundColor DarkGray
  Write-Host ""

  Write-Host ""
  Write-Host "Top operators by EstimatedSelfCost (delta):" -ForegroundColor Yellow

  # Avoid duplicating the same operators already shown in the subtree-cost list.
  $topIds = @{}
  foreach ($o in $result.TopOperators) { $topIds[$o.NodeId] = $true }

  $selfFiltered = $result.TopSelfOperators | Where-Object { -not $topIds.ContainsKey($_.NodeId) }

  if (@($selfFiltered).Count -gt 0) {
    $selfFiltered |
    Select-Object `
    @{ n = 'NodeId'; e = { $_.NodeId } },
    @{ n = 'PhysicalOp'; e = { $_.PhysicalOpDisplay } },
    @{ n = 'LogicalOp'; e = { $_.LogicalOp } },
    @{ n = 'SelfCost'; e = { if ($_.HasKids -and ($null -eq $_.EstSelfCost -or $_.EstSelfCost -eq '')) { '0.00' } else { F2 $_.EstSelfCost } } },
    @{ n = 'EstCost'; e = { F2 $_.EstCost } },
    @{ n = 'EstRows'; e = { F0 $_.EstRows } },
    @{ n = 'ActOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '') { F0 $_.ActRowsOut } else { '' } } },
    @{ n = 'ActWork'; e = { if ($_.ActRowsWork -ne $null -and $_.ActRowsWork -ne '') { F0 $_.ActRowsWork } else { '' } } },
    @{ n = 'RatioOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '' -and $_.EstRows -ne $null -and $_.EstRows -ne '' -and [double]$_.EstRows -ne 0) { F3 (([double]$_.ActRowsOut) / ([double]$_.EstRows)) } else { '' } } },
    @{ n = 'RatioWork'; e = { if ($_.ActRowsWork -ne $null -and $_.ActRowsWork -ne '' -and $_.EstRows -ne $null -and $_.EstRows -ne '' -and [double]$_.EstRows -ne 0) { F3 (([double]$_.ActRowsWork) / ([double]$_.EstRows)) } else { '' } } },
    @{ n = 'RowsRead'; e = { F0 $_.RowsRead } },
    @{ n = 'Execs'; e = { F0 $_.Execs } },
    @{ n = 'Access'; e = { $_.Access } },
    @{ n = 'Warnings'; e = { $_.Warnings } } |
    Format-Table -AutoSize
    Write-ObjectKey $selfFiltered
  } else {
    Write-Host " - (same operators as subtree-cost list; omitted)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Top operators by True CPU Volume (Actual Rows Read):" -ForegroundColor Yellow
  if (@($readsHeavyOps).Count -gt 0) {
    $readsHeavyOps |
    Select-Object `
       @{ n = 'NodeId'; e = { $_.NodeId } },
       @{ n = 'PhysicalOp'; e = { $_.PhysicalOpDisplay } },
       @{ n = 'LogicalOp'; e = { $_.LogicalOp } },
       @{ n = 'RowsRead'; e = { F0 $_.RowsRead } },
       @{ n = 'ActOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '') { F0 $_.ActRowsOut } else { '' } } },
       @{ n = 'WasteRatio'; e = { if ($_.RowsRead -gt 0 -and $_.ActRows -gt 0) { F2 ($_.RowsRead / $_.ActRows) } else { '' } } },
       @{ n = 'EstCost'; e = { F2 $_.EstCost } },
       @{ n = 'Access'; e = { $_.Access } } |
    Format-Table -AutoSize
    Write-ObjectKey $readsHeavyOps

    Write-Host "  Note: High RowsRead combined with low ActOut indicates severe residual predicate CPU burn." -ForegroundColor Gray
  } else {
    Write-Host " - (No runtime row metrics available in this plan)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Key/RID lookups (call volume):" -ForegroundColor Yellow
  if (@($keyLookups).Count -gt 0) {
    $keyLookups | Select-Object NodeId, PhysicalOp, LookupCalls, ActRows, EstRows, @{ n = 'Object'; e = { $o = ShortObjectName $_.Object; if ($null -eq $o) { '' } else { $o } } } | Format-Table -AutoSize
    $painfulLookups = @($keyLookups | Where-Object { $_.LookupCalls -ne $null -and $_.LookupCalls -ge $LookupCallsThreshold })
    if ($painfulLookups.Count -gt 0) {
      Write-Host ("  >> {0} lookup operator(s) at or above the {1:N0}-call threshold. Each call is a random clustered-index probe;" -f $painfulLookups.Count, $LookupCallsThreshold) -ForegroundColor DarkYellow
      Write-Host "  >> consider a covering index (INCLUDE the looked-up columns) or trimming the SELECT list." -ForegroundColor DarkYellow
    }
    Write-Host "  Note: LookupCalls = executions driven by the outer join input, the true volume metric for a lookup." -ForegroundColor Gray
  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }

  # -----------------------------
  # v10: Access predicates (chosen statement)
  # The pretty-rendered seek/residual predicates were previously only visible in
  # the CE details section — i.e. only when estimates were wrong. Healthy plans
  # never displayed their access predicates at all. This section always shows
  # them for data-access operators, which also lets the seek-key renderer
  # (Prefix / BETWEEN / ScanType paths) be verified on well-behaved plans.
  # -----------------------------
  Write-Host ""
  Write-Host "Access predicates (chosen statement):" -ForegroundColor Yellow
  # v10: display-shorten column references (four-part -> [Table].[Column]) so the
  # interesting part of the predicate fits inside the truncation window; the
  # underlying operator rows keep full names.
  function Shorten-PredicateForDisplay ([string]$p2) {
    if ([string]::IsNullOrWhiteSpace($p2)) { return $p2 }
    $p2 = [regex]::Replace($p2,'\[[^\]]+\]\.\[[^\]]+\]\.(\[[^\]]+\]\.\[[^\]]+\])','$1')
    if ($p2.Length -gt 110) { return ($p2.Substring(0,110) + "...") }
    return $p2
  }
  $accessPredRows = @($operatorRows |
    Where-Object { $_.Access -and ($_.SeekPredicate -or $_.Residual) } |
    Sort-Object NodeId |
    Select-Object NodeId,PhysicalOp,Access,
      @{n='SeekPredicate';e={ Shorten-PredicateForDisplay $_.SeekPredicate }},
      @{n='Residual';e={ Shorten-PredicateForDisplay $_.Residual }})
  if ($accessPredRows.Count -gt 0) {
    $accessPredRows | Format-Table -AutoSize -Wrap
    Write-Host "  Note: SeekPredicate rows are B-tree navigation (cheap); Residual rows are evaluated per row AFTER the seek (CPU burn if row counts are high)." -ForegroundColor Gray
  } else {
    Write-Host " - (none: no data-access operators with seek/residual predicates in this statement)" -ForegroundColor DarkGray
  }

  # -----------------------------
  # DBA heuristics output
  # -----------------------------

  # -----------------------------
  # DBA heuristics output
  # -----------------------------
  Write-Host ""

  # Build a quick NodeId -> operator lookup for richer heuristic summaries
  $opMap = @{}
  foreach ($r in $operatorRows) {
    if ($r.NodeId -ne $null) { $opMap["$($r.NodeId)"] = $r }
  }

  Write-Host "Join strategy sanity checks (heuristic):" -ForegroundColor Yellow
  if (@($joinChecks).Count -gt 0) {

    if (-not $ShowAllHeuristicMatches) {
      $groups = @($joinChecks | Group-Object Join,Signal)
      Write-Host (" - {0} matching operators grouped into {1} finding(s). Use -ShowAllHeuristicMatches to list each operator." -f @($joinChecks).Count,$groups.Count) -ForegroundColor DarkGray

      $joinChecksGrouped = foreach ($g in $groups) {
        $sample = $g.Group[0]
        $ids = @($g.Group | Select-Object -ExpandProperty NodeId | Sort-Object)
        $idText = ($ids -join ', ')
        if ($idText.Length -gt 60) { $idText = $idText.Substring(0,57) + '...' }

        $rowVals = @($g.Group | ForEach-Object { $_.Rows } | Where-Object { $_ -ne $null })
        $rowsMin = $null; $rowsMax = $null
        if ($rowVals.Count -gt 0) {
          $m = $rowVals | Measure-Object -Minimum -Maximum
          $rowsMin = $m.Minimum
          $rowsMax = $m.Maximum
        }

        $execVals = @($g.Group | ForEach-Object { $_.Execs } | Where-Object { $_ -ne $null })
        $execMax = $null
        if ($execVals.Count -gt 0) { $execMax = ($execVals | Measure-Object -Maximum).Maximum }

        $objs = @($g.Group | ForEach-Object { $_.Object } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $objText = ''
        if ($objs.Count -gt 0) {
          $objText = ($objs | Select-Object -First 2) -join ' | '
          if ($objs.Count -gt 2) { $objText += ' | ...' }
        }


        $opsForGroup = @($ids | ForEach-Object { $opMap["$_"] } | Where-Object { $_ -ne $null })

        $logOps = @($opsForGroup | ForEach-Object { $_.LogicalOp } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $logText = ''
        if ($logOps.Count -gt 0) {
          $logText = ($logOps | Select-Object -First 2) -join ' | '
          if ($logOps.Count -gt 2) { $logText += ' | ...' }
        }

        $costVals = @($opsForGroup | ForEach-Object { $_.EstCost } | Where-Object { $_ -ne $null })
        $costMax = $null
        if ($costVals.Count -gt 0) { $costMax = ($costVals | Measure-Object -Maximum).Maximum }

        $worstNode = ''
        if ($costVals.Count -gt 0) {
          $worst = $opsForGroup | Where-Object { $_.EstCost -ne $null } | Sort-Object EstCost -Descending | Select-Object -First 1
          if ($worst) { $worstNode = $worst.NodeId }
        }

        [pscustomobject]@{
          Count = $g.Count
          NodeIds = $idText
          Join = $sample.Join
          Signal = $sample.Signal
          RowsMin = $(if ($rowsMin -ne $null) { F0 $rowsMin } else { '' })
          RowsMax = $(if ($rowsMax -ne $null) { F0 $rowsMax } else { '' })
          ExecMax = $(if ($execMax -ne $null) { F0 $execMax } else { '' })
          EstCostMax = $(if ($costMax -ne $null) { F2 $costMax } else { '' })
          WorstNode = $worstNode
          LogicalOps = $logText
          Objects = $objText
          Detail = $sample.Detail
        }
      }

      $joinChecksGrouped |
      Sort-Object @{ Expression = 'Count'; Descending = $true },Join,Signal |
      Format-Table Count,NodeIds,Join,Signal,RowsMin,RowsMax,ExecMax,EstCostMax,WorstNode,LogicalOps,Objects -AutoSize
    } else {
      $joinChecks | Select-Object NodeId,Join,Signal,Rows,Execs,Object,Detail | Format-Table -AutoSize
    }

  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Operator red flags (heuristic):" -ForegroundColor Yellow
  if (@($operatorRedFlags).Count -gt 0) {

    if (-not $ShowAllHeuristicMatches) {
      $groups = @($operatorRedFlags | Group-Object Operator,Signal)
      Write-Host (" - {0} matching operators grouped into {1} finding(s). Use -ShowAllHeuristicMatches to list each operator." -f @($operatorRedFlags).Count,$groups.Count) -ForegroundColor DarkGray

      $operatorRedFlagsGrouped = foreach ($g in $groups) {
        $sample = $g.Group[0]
        $ids = @($g.Group | Select-Object -ExpandProperty NodeId | Sort-Object)
        $idText = ($ids -join ', ')
        if ($idText.Length -gt 60) { $idText = $idText.Substring(0,57) + '...' }

        $rowVals = @($g.Group | ForEach-Object { $_.Rows } | Where-Object { $_ -ne $null })
        $rowsMax = $null
        if ($rowVals.Count -gt 0) { $rowsMax = ($rowVals | Measure-Object -Maximum).Maximum }

        $execVals = @($g.Group | ForEach-Object { $_.Execs } | Where-Object { $_ -ne $null })
        $execMax = $null
        if ($execVals.Count -gt 0) { $execMax = ($execVals | Measure-Object -Maximum).Maximum }

        $objs = @($g.Group | ForEach-Object { $_.Object } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $objText = ''
        if ($objs.Count -gt 0) {
          $objText = ($objs | Select-Object -First 2) -join ' | '
          if ($objs.Count -gt 2) { $objText += ' | ...' }
        }


        $opsForGroup = @($ids | ForEach-Object { $opMap["$_"] } | Where-Object { $_ -ne $null })

        $logOps = @($opsForGroup | ForEach-Object { $_.LogicalOp } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $logText = ''
        if ($logOps.Count -gt 0) {
          $logText = ($logOps | Select-Object -First 2) -join ' | '
          if ($logOps.Count -gt 2) { $logText += ' | ...' }
        }

        $costVals = @($opsForGroup | ForEach-Object { $_.EstCost } | Where-Object { $_ -ne $null })
        $costMax = $null
        if ($costVals.Count -gt 0) { $costMax = ($costVals | Measure-Object -Maximum).Maximum }

        $worstNode = ''
        if ($costVals.Count -gt 0) {
          $worst = $opsForGroup | Where-Object { $_.EstCost -ne $null } | Sort-Object EstCost -Descending | Select-Object -First 1
          if ($worst) { $worstNode = $worst.NodeId }
        }

        [pscustomobject]@{
          Count = $g.Count
          NodeIds = $idText
          Operator = $sample.Operator
          Signal = $sample.Signal
          RowsMax = $(if ($rowsMax -ne $null) { F0 $rowsMax } else { '' })
          ExecMax = $(if ($execMax -ne $null) { F0 $execMax } else { '' })
          EstCostMax = $(if ($costMax -ne $null) { F2 $costMax } else { '' })
          WorstNode = $worstNode
          LogicalOps = $logText
          Objects = $objText
          Detail = $sample.Detail
        }
      }

      $operatorRedFlagsGrouped | Sort-Object @{ Expression = 'Count'; Descending = $true },Operator,Signal | Format-Table -AutoSize

    } else {
      $operatorRedFlags | Select-Object NodeId,Operator,Signal,Rows,Execs,Object,Detail | Format-Table -AutoSize
    }

  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Spill signals (from plan XML):" -ForegroundColor Yellow
  if (@($spillSignals).Count -gt 0) {
    $spillSignals | Select-Object NodeId,Operator,Signal,Detail | Sort-Object NodeId | Format-Table -AutoSize
  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Parallelism skew signals (heuristic):" -ForegroundColor Yellow
  if (@($parallelSkewSignals).Count -gt 0) {
    $parallelSkewSignals |
    Sort-Object SkewRatio -Descending |
    Select-Object NodeId,Operator,Threads,@{ n = 'TotalRows'; e = { F0 $_.TotalRows } },Signal,Detail |
    Format-Table -AutoSize
  } else {
    if ($skewScanned -gt 0) {
      Write-Host " - (none detected) Note: Scanned $skewScanned parallel operators; no high skew (ratio >= 5) found." -ForegroundColor DarkGray
    } else {
      Write-Host " - (none detected)" -ForegroundColor DarkGray
    }
  }

  Write-Host ""
  Write-Host "Many-to-many merge join signals:" -ForegroundColor Yellow
  if (@($manyToManyMergeSignals).Count -gt 0) {
    $manyToManyMergeSignals | Select-Object NodeId,Join,Signal,Detail | Format-Table -AutoSize
  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Implicit conversion signals (PlanAffectingConvert):" -ForegroundColor Yellow
  if (@($planAffectingConvertSignals).Count -gt 0) {
    $planAffectingConvertSignals | Select-Object StatementId,Issue,Expression | Format-Table -AutoSize
  } else {
    Write-Host " - (none detected) Note: SQL Server only creates PlanAffectingConvert elements when implicit conversions significantly affect plan choice." -ForegroundColor DarkGray
  }

  

  Write-Host ""
  Write-Host "Predicate CONVERT_IMPLICIT signals (heuristic):" -ForegroundColor Yellow
  # v10: show both sides with an explicit Side column; the tool now performs the
  # column-vs-parameter check the old tip asked the reader to do by hand.
  $predConvertNodes = $operatorRows |
    Where-Object { $_.HasConvertImplicit -or $_.HasParamConvertImplicit } |
    Select-Object NodeId,PhysicalOp,
      @{n='Side';e={ if ($_.HasConvertImplicit) { 'column (seek-blocking)' } else { 'parameter (usually benign)' } }},
      Object,Predicate,SeekPredicate,Residual
  if (@($predConvertNodes).Count -gt 0) {
    $predConvertNodes | Select-Object NodeId,PhysicalOp,Side,Object | Format-Table -AutoSize
    if (@($predConvertNodes | Where-Object { $_.Side -like 'column*' }).Count -gt 0) {
      Write-Host "Tip: column-side conversions block seeks and skew CE - align parameter/column datatypes to restore seeks." -ForegroundColor Gray
    } else {
      Write-Host "Tip: only parameter-side conversions found - the parameter is converted once and seeks are preserved; align datatypes anyway for hygiene." -ForegroundColor Gray
    }
  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Expression CONVERT_IMPLICIT in Compute Scalar:" -ForegroundColor Yellow
  if (@($expressionConvertImplicit).Count -gt 0) {
    $expressionConvertImplicit | Select-Object NodeId,Operator,Expression | Format-Table -AutoSize
    Write-Host "Note: compute-scalar conversions are often harmless for seekability, but can add CPU or hint at datatype mismatches upstream." -ForegroundColor Gray
  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }

Write-Host ""
  Write-Host "Predicate SARGability signals (heuristic):" -ForegroundColor Yellow
  $predCount = @($operatorRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SeekPredicate) -or -not [string]::IsNullOrWhiteSpace($_.Predicate) -or -not [string]::IsNullOrWhiteSpace($_.Residual) }).Count
  if (@($sargabilityIssues).Count -gt 0) {
    $sargabilityIssues | Select-Object NodeIds,Issues,Expression | Format-Table -AutoSize
  } else {
    if ($predCount -gt 0) {
      Write-Host " - (none detected) Note: Scanned $predCount predicate expressions; no non-SARGable patterns (CONVERT_IMPLICIT, functions on columns, leading wildcards) found." -ForegroundColor DarkGray
    } else {
      Write-Host " - (none detected) Note: No predicate expressions found to scan." -ForegroundColor DarkGray
    }
  }
  Write-Host ""
  Write-Host "Parameter sensitivity signals:" -ForegroundColor Yellow
  if ($hasParameterSensitivePlan) {
    Write-Host " - Parameter Sensitive Plan optimization detected in plan XML."
  }
  if (@($psIssues).Count -gt 0) {
    $psIssues | Select-Object Name,DataType,CompiledValue,RuntimeValue,@{ n = 'ValueRatio'; e = { F2 $_.ValueRatio } } | Format-Table -AutoSize
  } elseif (@($parameterSensitivity).Count -gt 0) {
    $parameterSensitivity | Select-Object Name,DataType,CompiledValue,RuntimeValue,@{ n = 'ValueRatio'; e = { if ($_.ValueRatio -ne $null) { F2 $_.ValueRatio } else { '' } } } | Format-Table -AutoSize
    $missingRuntime = @($parameterSensitivity | Where-Object { [string]::IsNullOrWhiteSpace($_.RuntimeValue) }).Count
    if ($missingRuntime -gt 0) {
      Write-Host " - Note: Some parameters lack ParameterRuntimeValue in this plan XML. If possible, save an *actual* plan (Include Actual Execution Plan) and re-export it." -ForegroundColor DarkGray
    } else {
      Write-Host " - Note: ValueRatio is calculated only for numeric parameters; blanks are normal for strings/dates or non-numeric formatting." -ForegroundColor DarkGray
    }

  } else {
    Write-Host " - (none detected)" -ForegroundColor DarkGray
  }
  Write-Host ""
  Write-Host "Index intersection signals (heuristic):" -ForegroundColor Yellow
  $bitmapCount = @($operatorRows | Where-Object { $_.PhysicalOp -match 'Bitmap' -or $_.LogicalOp -match 'Bitmap' }).Count
  if (@($indexIntersectionSignals).Count -gt 0) {
    $indexIntersectionSignals | Select-Object NodeId,Operator,Detail | Format-Table -AutoSize
  } else {
    Write-Host " - (none detected) Note: No bitmap operators or PROBE()/Opt_Bitmap patterns detected in plan." -ForegroundColor DarkGray
  }
  Write-Host ""
  Write-Host "Rewrite / design hints (heuristic):" -ForegroundColor Yellow
  if ($rewriteHints.Count -gt 0) {
    $rewriteHints | ForEach-Object { Write-Host " - $_" }
  } else {
    Write-Host " - (none)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Cardinality estimator model (per statement):" -ForegroundColor Yellow
  if (@($result.CEModelInfo).Count -gt 0) {
    $result.CEModelInfo | Select-Object StatementId,CEVersion,CompatLevel,Signal | Format-Table -AutoSize
    foreach ($ceRow in @($result.CEModelInfo | Where-Object Note)) {
      Write-Host ("  Note (Stmt {0}): {1}" -f $ceRow.StatementId,$ceRow.Note) -ForegroundColor Gray
    }
  } else {
    Write-Host " - (no CE model attribute found in plan - very old showplan schema)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Query/table hint signals (heuristic):" -ForegroundColor Yellow
  if (@($result.HintSignals).Count -gt 0) {
    $result.HintSignals | Select-Object StatementId,Source,Hint,Detail | Format-Table -AutoSize
    foreach ($hintRow in @($result.HintSignals)) {
      Write-Host (" - {0}: {1}" -f $hintRow.Hint,$hintRow.Implication)
    }
    Write-Host ""
    Write-Host "  >> Plan shape was mandated by hints, not chosen by the optimizer." -ForegroundColor DarkYellow
    Write-Host "  >> Treat tuning conclusions accordingly: fix the underlying reason the" -ForegroundColor DarkYellow
    Write-Host "  >> hint was added before trusting what this plan appears to 'prefer'." -ForegroundColor DarkYellow
  } else {
    Write-Host " - (none detected) Note: plan shape was chosen freely by the optimizer." -ForegroundColor DarkGray
  }

  if ($result.SortIndexSuggestions -and @($result.SortIndexSuggestions).Count -gt 0) {
    Write-Host "" 
    Write-Host "Order / sort support opportunities (heuristic):" -ForegroundColor Yellow
    $result.SortIndexSuggestions |
    Select-Object FullTable,SortColumns,CoveredByExistingIndex,CoveringIndexName |
    Format-Table -AutoSize

    Write-Host "Note: CoveredByExistingIndex means an existing index has a key prefix matching the sort columns (in order). The optimizer may still choose a different access path." -ForegroundColor Gray

    $gapNotes = @($result.SortIndexSuggestions | Where-Object { $_.CoveredByExistingIndex -and -not [string]::IsNullOrWhiteSpace($_.IncludeGapNote) })
    if ($gapNotes.Count -gt 0) {
      Write-Host "Note: Even when order is covered, missing INCLUDE columns can still force lookups." -ForegroundColor Gray
      $gapNotes | Select-Object -First 3 | ForEach-Object { Write-Host (" - " + $_.IncludeGapNote) -ForegroundColor DarkGray }
    }

    $todo = @($result.SortIndexSuggestions | Where-Object { -not $_.CoveredByExistingIndex -and -not [string]::IsNullOrWhiteSpace($_.SuggestedCreateIndex) })
    if ($todo.Count -gt 0) {
      Write-Host "" 
      Write-Host "Example CREATE INDEX statements (validate first):" -ForegroundColor DarkYellow
      $todo | Select-Object -First 3 | ForEach-Object {
        Write-Host (" - " + $_.SuggestedCreateIndex)
        $sn = if (-not [string]::IsNullOrWhiteSpace($_.SortNodeDetailsDisplay)) { $_.SortNodeDetailsDisplay } else { $_.SortNodeIdsDisplay }
        if (-not [string]::IsNullOrWhiteSpace($sn)) {
          $keys = if (-not [string]::IsNullOrWhiteSpace($_.SortColumns)) { $_.SortColumns } else { '(unknown)' }
          Write-Host ("   Note: matches Sort operator NodeId(s): {0}; sort keys: {1};if chosen, may ameliorate Sort." -f $sn,$keys) -ForegroundColor DarkGray

          # If the plan shows high memory-grant waste, sorts are common drivers; removing/reducing a Sort can reduce the required grant.
          try {
            $mgWaste = $null

            # Prefer the existing memory-grant waste calculation already done in the output section above.
            # $wastePct and $mgGranted are local to that block, so re-derive here from $memoryGrantInfo.
            if ($memoryGrantInfo -and $memoryGrantInfo.GrantedKB -ne $null -and $memoryGrantInfo.MaxUsedKB -ne $null) {
              $mgG  = $null; $mgMU = $null
              try { $mgG  = [double]$memoryGrantInfo.GrantedKB  } catch {}
              try { $mgMU = [double]$memoryGrantInfo.MaxUsedKB  } catch {}
              if ($mgG -and $mgG -gt 0 -and $mgMU -ne $null) {
                $mgWaste = (($mgG - $mgMU) / $mgG) * 100.0
              }
            }

            # Optional extra notes for this sort opportunity:
            $snLocal = $null
            try { $snLocal = $_.SortNodeIds } catch { }
            if (-not $snLocal -and $_.PSObject.Properties.Match('SortNodeId').Count -gt 0 -and $_.SortNodeId) { $snLocal = @($_.SortNodeId) }

            # High memory-grant waste can be driven by Sorts; if this recommendation targets a Sort, call it out.
            if ($snLocal -and $mgWaste -ne $null -and $mgWaste -ge 50) {
                Write-Host ("   Also: Memory grant waste is high (WastePct={0:N2}%). If an order-supporting index is used and the Sort is avoided or reduced, the memory grant may reduce." -f $mgWaste) -ForegroundColor DarkGray
            }

            # If the base table is large, remind about size/write overhead of new indexes.
            # $_ here is the current SortIndexSuggestion item (FullTable, SortColumns, SuggestedCreateIndex, etc.)
            $currentFt = $_.FullTable
            if ($InspectDatabase -and $dbInspection -and $currentFt) {
                try {
                    # Stats is an array of pscustomobject — filter by FullTable
                    $tableStats = @($dbInspection.Stats | Where-Object { $_.FullTable -eq $currentFt })
                    if ($tableStats.Count -gt 0) {
                        $approxRows2 = $tableStats[0].Rows
                        if ($approxRows2 -ge 1000000) {
                            Write-Host ("   Also: Table is large (~{0:N0} rows). This index may be large; check space and write overhead before deploying." -f $approxRows2) -ForegroundColor DarkGray
                        }
                    }
                } catch { }
            }

            # Suggested index may overlap existing ones; that's not always bad, but it can increase maintenance.
            if ($InspectDatabase -and $dbInspection -and $currentFt) {
                try {
                    # Indexes is an array of pscustomobject — filter by FullTable
                    $existingForTable = @($dbInspection.Indexes | Where-Object { $_.FullTable -eq $currentFt })
                    # Build suggested cols from the SortIndexSuggestion's SortColumns and SuggestedCreateIndex
                    $sortCols = @($_.SortColumns -split ',\s*' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
                    $overlaps = @()
                    foreach ($ex in $existingForTable) {
                        $exCols = @()
                        if ($ex.KeyCols)     { $exCols += ($ex.KeyCols     -split ',') | ForEach-Object { $_.Trim().ToLowerInvariant() } }
                        if ($ex.IncludeCols) { $exCols += ($ex.IncludeCols -split ',') | ForEach-Object { $_.Trim().ToLowerInvariant() } }
                        $exCols = $exCols | Where-Object { $_ } | Select-Object -Unique
                        if ($exCols.Count -gt 0) {
                            $common = @($sortCols | Where-Object { $exCols -contains $_ })
                            if ($common.Count -ge 2) {
                                $overlaps += [pscustomobject]@{ IndexName = $ex.IndexName; Common = $common }
                            }
                        }
                    }
                    if ($overlaps.Count -gt 0) {
                        $msg = ($overlaps | ForEach-Object { "{0} (common: {1})" -f $_.IndexName, (($_.Common | Select-Object -First 5) -join ', ') }) -join '; '
                        Write-Host ("   Also: Suggested index overlaps columns with existing index(es): {0}. Overlap is column-level; key order may differ, so a new index can still be useful for ORDER BY support." -f $msg) -ForegroundColor DarkGray
                    }
                } catch { }
            }
          } catch { }
        }
      }
      Write-Host "Tip: consider INCLUDE columns used by the query to avoid lookups (e.g., projected or joined columns)." -ForegroundColor Gray
      Write-Host "Note: new indexes can be large and add write overhead; validate with your workload and test before deploying." -ForegroundColor Gray
    }
  }

  if (@($missingIndexes).Count -gt 0) {
    Write-Host ""
    if (@($missingIndexes).Count -gt 1) {
      Write-Host ("Missing index recommendations (from plan XML) - COUNT: {0} (Unique: {1})" -f @($missingIndexes).Count,$missingIndexesUniqueCount) -ForegroundColor Yellow
    } else {
      Write-Host "Missing index recommendations (from plan XML):" -ForegroundColor Yellow
    }

    $missingIndexesUnique |
    Select-Object `
       @{ n = 'Impact'; e = { F3 $_.Impact } },
    @{ n = 'FullTable'; e = { $_.FullTable } },
    @{ n = 'Equality'; e = { $_.EqualityText } },
    @{ n = 'Inequality'; e = { $_.InequalityText } },
    @{ n = 'Include'; e = { $_.IncludeText } } |
    Format-Table -AutoSize

    if (@($missingIndexDuplicates).Count -gt 0) {
      Write-Host ""
      Write-Host "Duplicate missing-index signatures:" -ForegroundColor DarkYellow
      $missingIndexDuplicates |
      Select-Object FullTable,Count,@{ n = 'MaxImpact'; e = { F3 $_.MaxImpact } } |
      Format-Table -AutoSize
    }

    Write-Host ""
    Write-Host "Example CREATE INDEX statements (validate first):" -ForegroundColor DarkYellow
    $missingIndexesUnique | Select-Object -First 3 | ForEach-Object { Write-Host (" - " + $_.SuggestedSql) }
  }

    if ($result.HasParameterSensitivePlan) {
      Write-Host ""
      Write-Host "Parameter Sensitive Plan optimization detected (SQL Server PSP):" -ForegroundColor DarkYellow
      Write-Host " - QueryPlan has ParameterSensitivePlan=true" -ForegroundColor Gray
    }

    # $psIssues was already built and displayed in the parameter sensitivity section above.
    # Only show the automated sniffing scripts here if there are high-risk issues.
    if ($psIssues.Count -gt 0) {
      Write-Host ""
      Write-Host "Automated Mitigation Testing Scripts (Parameter Sniffing):" -ForegroundColor Green
      Write-Host "Append one of these hints to the end of your query to test a fix:" -ForegroundColor DarkGray

      Write-Host ""
      Write-Host "-- Test 1: Generate a fresh plan for the specific runtime values (High CPU penalty if executed frequently)" -ForegroundColor Cyan
      Write-Host "OPTION (RECOMPILE);"

      Write-Host ""
      Write-Host "-- Test 2: Generate an 'average' plan using density vectors (Protects against edge cases, but ignores the histogram)" -ForegroundColor Cyan
      Write-Host "OPTION (OPTIMIZE FOR UNKNOWN);"

      Write-Host ""
      Write-Host "-- Test 3: Force the optimizer to use the original Compiled Values (Reproduces the original compiled plan behavior)" -ForegroundColor Cyan
      $optForList = @()
      foreach ($p in $psIssues) {
          $cleanC = $p.CompiledValue.Trim('(',')')
          # v10 fix: string/nvarchar ParameterCompiledValue arrives ALREADY quoted from the
          # plan XML (e.g. N'999999') - only numeric values are bare and need Trim()'d parens
          # removed. Re-wrapping an already-quoted value produced invalid T-SQL: N'N'999999''.
          $val = if ($cleanC -match "^[+-]?\d+(\.\d+)?$") { $cleanC }
                 elseif ($cleanC -match "^N?'.*'$") { $cleanC }
                 else { "N'$cleanC'" }
          $optForList += "$($p.Name) = $val"
      }
      Write-Host ("OPTION (OPTIMIZE FOR ({0}));" -f ($optForList -join ", "))

      Write-Host ""
      Write-Host "-- Test 4: Force the optimizer to use the current Runtime Values (To see if the new plan is definitively better)" -ForegroundColor Cyan
      $optForRuntimeList = @()
      foreach ($p in $psIssues) {
          $cleanR = $p.RuntimeValue.Trim('(',')')
          # v10 fix: same double-quoting bug as Test 3's CompiledValue, mirrored for RuntimeValue.
          $val = if ($cleanR -match "^[+-]?\d+(\.\d+)?$") { $cleanR }
                 elseif ($cleanR -match "^N?'.*'$") { $cleanR }
                 else { "N'$cleanR'" }
          $optForRuntimeList += "$($p.Name) = $val"
      }
      Write-Host ("OPTION (OPTIMIZE FOR ({0}));" -f ($optForRuntimeList -join ", "))
    }

  if ($parallelOps.Count -gt 0) {
    Write-Host ""
    Write-Host "Parallelism operators:" -ForegroundColor Yellow
    $result.ParallelismOps |
    Select-Object `
       @{ n = 'NodeId'; e = { $_.NodeId } },
    @{ n = 'PhysicalOp'; e = { $_.PhysicalOp } },
    @{ n = 'LogicalOp'; e = { $_.LogicalOp } },
    @{ n = 'EstCost'; e = { F2 $_.EstCost } },
    @{ n = 'EstRows'; e = { F0 $_.EstRows } },
    @{ n = 'ActOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '') { F0 $_.ActRowsOut } else { '' } } },
    @{ n = 'ActWork'; e = { if ($_.ActRowsWork -ne $null -and $_.ActRowsWork -ne '') { F0 $_.ActRowsWork } else { '' } } },
    @{ n = 'Object'; e = { $_.Object } } |
    Format-Table -AutoSize
  }

  if ($cardinalityIssues.Count -gt 0) {
    Write-Host ""
    Write-Host "Inaccurate cardinality estimation (SSMS-style):" -ForegroundColor Yellow

    # Avoid repeating the same nodes already shown in the Top operators list.
    # (Top list includes EstRows/ActRows/Ratio now.)
    $ceFiltered = $cardinalityIssues | Where-Object { -not $topIds.ContainsKey($_.NodeId) }

    if (@($ceFiltered).Count -gt 0) {
      $ceFiltered |
      Select-Object -First 25 `
         @{ n = 'NodeId'; e = { $_.NodeId } },
      @{ n = 'PhysicalOp'; e = { $_.PhysicalOp } },
      @{ n = 'LogicalOp'; e = { $_.LogicalOp } },
      @{ n = 'EstRows'; e = { F0 $_.EstRows } },
      @{ n = 'ActOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '') { F0 $_.ActRowsOut } else { '' } } },
      @{ n = 'ActWork'; e = { if ($_.ActRowsWork -ne $null -and $_.ActRowsWork -ne '') { F0 $_.ActRowsWork } else { '' } } },
      @{ n = 'RatioOut'; e = { if ($_.ActRowsOut -ne $null -and $_.ActRowsOut -ne '' -and $_.EstRows -ne $null -and $_.EstRows -ne '' -and [double]$_.EstRows -ne 0) { F3 (([double]$_.ActRowsOut) / ([double]$_.EstRows)) } else { '' } } },
      @{ n = 'RatioWork'; e = { if ($_.ActRowsWork -ne $null -and $_.ActRowsWork -ne '' -and $_.EstRows -ne $null -and $_.EstRows -ne '' -and [double]$_.EstRows -ne 0) { F3 (([double]$_.ActRowsWork) / ([double]$_.EstRows)) } else { '' } } },
      @{ n = 'RatioBest'; e = { if ($_.Ratio -eq [double]::PositiveInfinity) { "inf" } else { F3 $_.Ratio } } },
      @{ n = 'EstCost'; e = { F2 $_.EstCost } },
      @{ n = 'Access'; e = { $_.Access } },
      @{ n = 'Object'; e = { $_.Object } } |
      Format-Table -AutoSize
    } else {
      Write-Host " - (all CE-mismatch nodes are already listed above in Top operators; omitted)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "CE hot spots (grouped by statement):" -ForegroundColor DarkYellow
    $result.CEStatementSummary |
    Select-Object `
       StatementId,
    @{ n = 'WorstNode'; e = { $_.WorstNodeId } },
    @{ n = 'WorstRatio'; e = { if ($_.WorstRatio -eq [double]::PositiveInfinity) { "inf" } else { F3 $_.WorstRatio } } },
    @{ n = 'WorstSeverity'; e = { F3 $_.WorstSeverity } },
    NodesFlagged,
    StatementText |
    Format-Table -AutoSize

    Write-Host ""

    Write-Host "CE details (top 5 statements, top 3 nodes each):" -ForegroundColor DarkYellow
    Write-Host "  (ActRowsOut = trusted output rows where meaningful; ActRowsWork = summed worker rows)" -ForegroundColor DarkGray

    # De-dupe repeated detail lines (e.g., same predicate repeated on Top/Parallelism above the real scan/seek).
    # $seen is reset per-statement inside the loop; Write-Once is defined once here.
    $seen = @{}
    function Write-Once ([string]$label,[string]$value) {
      if ([string]::IsNullOrWhiteSpace($value)) { return }
      $k = "$label|$value"
      if (-not $seen.ContainsKey($k)) {
        Write-Host ("{0,-18}: {1}" -f $label,$value)
        $seen[$k] = $true
      }
    }

    foreach ($stmt in ($result.CEStatementSummary | Select-Object -First 5)) {
      $isChosen = ($chosenStmtSummary -and $stmt.StatementId -eq $chosenStmtSummary.StatementId)
      if ($isChosen) {
        Write-Host ("StatementId {0}" -f $stmt.StatementId) -ForegroundColor Gray
      } else {
        Write-Host ("StatementId {0}: {1}" -f $stmt.StatementId,$stmt.StatementText) -ForegroundColor Gray
      }

      # Reset dedup tracker for each statement
      $seen = @{}

      $top = $cardinalityIssues |
      Where-Object { $_.StatementId -eq $stmt.StatementId } |
      Sort-Object Severity -Descending |
      Select-Object -First 3 |
      Group-Object NodeId | ForEach-Object { $_.Group[0] }  # deduplicate by NodeId

      foreach ($n in $top) {
        Write-Host ""
        Write-Host ("NodeId             : {0}" -f $n.NodeId)
        Write-Host ("PhysicalOp         : {0}" -f $n.PhysicalOp)
        Write-Host ("EstRows            : {0}" -f (F0 $n.EstRows))
        $actOutTxt = if ($n.ActRowsOut -ne $null -and $n.ActRowsOut -ne '') { F0 $n.ActRowsOut } else { 'n/a' }
        $actWorkTxt = if ($n.ActRowsWork -ne $null -and $n.ActRowsWork -ne '') { F0 $n.ActRowsWork } else { 'n/a' }
        Write-Host ("ActRowsOut         : {0}" -f $actOutTxt)
        Write-Host ("ActRowsWork        : {0}" -f $actWorkTxt)

        # For parallel operators where output rows aren't a single counter, show per-thread ActualRows (readable + obvious)
        if ($n.ThreadRows -and @($n.ThreadRows).Count -gt 1) {
          $workers = $n.ThreadRows | Where-Object { $_.Thread -ne 0 }
          $wCount = @($workers).Count
          if ($wCount -gt 0) {
            $m = $workers | Measure-Object -Property ActualRows -Minimum -Maximum -Average
            $min = [double]$m.Minimum; $max = [double]$m.Maximum; $avg = [double]$m.Average
            $skew = if ($avg -gt 0) { F2 ($max / $avg) } else { 'n/a' }
            Write-Host ("Threads            : {0} workers (min={1}, avg={2}, max={3}, max/avg={4})" -f $wCount,(F0 $min),(F0 $avg),(F0 $max),$skew)

            # Compact per-thread list: show up to 8 busiest threads
            $topThr = $workers | Sort-Object ActualRows -Descending | Select-Object -First 8
            $pairs = @()
            foreach ($tr in $topThr) { $pairs += ("t{0}={1}" -f $tr.Thread,(F0 $tr.ActualRows)) }
            $more = $wCount - @($topThr).Count
            $suffix = if ($more -gt 0) { " ... +$more more" } else { "" }
            Write-Host ("PerThreadRows      : {0}{1}" -f ($pairs -join "  "),$suffix)
          }
        }

        $ratioOutTxt = if ($n.ActRowsOut -ne $null -and $n.EstRows -ne $null -and [double]$n.EstRows -ne 0) { F3 (([double]$n.ActRowsOut) / ([double]$n.EstRows)) } else { 'n/a' }
        $ratioWorkTxt = if ($n.ActRowsWork -ne $null -and $n.EstRows -ne $null -and [double]$n.EstRows -ne 0) { F3 (([double]$n.ActRowsWork) / ([double]$n.EstRows)) } else { 'n/a' }
        Write-Host ("RatioOut           : {0}" -f $ratioOutTxt)
        Write-Host ("RatioWork          : {0}" -f $ratioWorkTxt)

        if (-not [string]::IsNullOrWhiteSpace($n.LikelyContributors)) {
          Write-Host ("LikelyContributors : {0}" -f $n.LikelyContributors)
        }

        # Print predicates where they are most meaningful, and avoid repeated noise.
        $isAccess = ($n.PhysicalOp -match "Scan|Seek|Lookup")
        $isFilter = ($n.PhysicalOp -match "^Filter$")
        $isJoin = ($n.PhysicalOp -match "Nested Loops|Hash Match|Merge Join")

        if ($isAccess) {
          Write-Once "SeekPredicate" $n.SeekPredicate
          # Prefer Residual for scans/seeks; only show Predicate if it's distinct
          Write-Once "Residual" $n.Residual
          if (-not [string]::IsNullOrWhiteSpace($n.Predicate) -and $n.Predicate -ne $n.Residual) {
            Write-Once "Predicate" $n.Predicate
          }
        }
        elseif ($isFilter) {
          Write-Once "Predicate" $n.Predicate
        }
        elseif ($isJoin) {
          Write-Once "JoinPredicate" $n.JoinPredicate
        }
        # else: skip Predicate fields for wrapper ops (Top / Parallelism / etc.) to avoid duplication
      }

      Write-Host ""
    }
  }

  if ($result.Suggestions.Count -gt 0) {
    Write-Host ""
    Write-Host "Suggestions:" -ForegroundColor Green
    $result.Suggestions | ForEach-Object { Write-Host " - $_" }
  }

  if ($InspectDatabase -and $result.DbInspection) {
    Write-Host ""
    Write-Host ("Database inspection: {0}\{1}" -f $result.DbInspection.ServerInstance,$result.DbInspection.Database) -ForegroundColor Cyan

    if ($result.DbInspection.TargetTables.Count -gt 0) {
      Write-Host "Target tables:" -ForegroundColor DarkCyan
      $result.DbInspection.TargetTables | ForEach-Object { Write-Host (" - " + $_) }
    }

    if ($result.DbInspection.Indexes.Count -gt 0) {
      Write-Host ""
      Write-Host "Indexes (per target table):" -ForegroundColor Yellow
      $result.DbInspection.Indexes |
      Select-Object `
         FullTable,IndexId,IndexName,TypeDesc,IsUnique,IsPrimaryKey,HasFilter,
      @{ n = 'KeyCols'; e = { $_.KeyCols } },
      @{ n = 'IncludeCols'; e = { $_.IncludeCols } },
      UserSeeks,UserScans,UserLookups,UserUpdates |
      Format-Table -AutoSize
    }

    if ($result.DbInspection.Stats.Count -gt 0) {
      Write-Host ""
      Write-Host "Statistics (per target table):" -ForegroundColor Yellow
      $result.DbInspection.Stats |
      Select-Object `
         FullTable,StatsName,
      @{ n = 'LastUpdated'; e = { $_.LastUpdated } },
      @{ n = 'Rows'; e = { $_.Rows } },
      @{ n = 'Mods'; e = { $_.ModificationCounter } },
      @{ n = 'ModRatio'; e = {
          $rows = To-DoubleOrNull $_.Rows
          $mods = To-DoubleOrNull $_.ModificationCounter
          if ($rows -and $rows -gt 0 -and $mods -ne $null) { F3 ($mods / $rows) } else { "" }
        } },
      StatsCols,AutoCreated,UserCreated,NoRecompute |
      Format-Table -AutoSize
    }

    if ($result.DbInspection.StaleStats.Count -gt 0) {
      Write-Host ""
      Write-Host "Stale statistics candidates (heuristic):" -ForegroundColor DarkYellow
      $result.DbInspection.StaleStats |
      Select-Object `
         FullTable,StatsName,
      @{ n = 'LastUpdated'; e = { $_.LastUpdated } },
      @{ n = 'Rows'; e = { $_.Rows } },
      @{ n = 'Mods'; e = { $_.ModificationCounter } },
      @{ n = 'ModRatio'; e = { F3 $_.ModRatio } },
      @{ n = 'Days'; e = { F0 $_.DaysSinceUpdate } },
      StatsCols |
      Format-Table -AutoSize
      Write-Host "Tip: consider UPDATE STATISTICS (or sp_updatestats) for the highlighted stats after validating workload/maintenance windows." -ForegroundColor Gray
    }

    if ($result.DbInspection.MultiColumnStatsOpportunities.Count -gt 0) {
      Write-Host ""
      Write-Host "Multi-column statistics opportunities (from predicates; not covered by existing stats):" -ForegroundColor DarkYellow
      $result.DbInspection.MultiColumnStatsOpportunities |
      Select-Object FullTable,Columns,StatementId,ExampleNodeId,ExamplePredicate |
      Format-Table -AutoSize
      Write-Host "Tip: multi-column stats can help cardinality estimation when multiple columns are filtered together." -ForegroundColor Gray
    }

    if (@($result.DbInspection.MissingIndexCoverage).Count -gt 0) {
      Write-Host ""
      Write-Host "Missing-index coverage check (heuristic: does an existing index already cover it?):" -ForegroundColor Yellow
      $result.DbInspection.MissingIndexCoverage |
      Select-Object `
         FullTable,
      @{ n = 'Impact'; e = { F3 $_.Impact } },
      Occurrences,Duplicate,
      SuggestedKeys,SuggestedIncludes,CoveredByExistingIndex |
      Format-Table -AutoSize

    }
  }

  Write-Host ""
  Write-Host "Useful links:" -ForegroundColor Cyan
  foreach ($p in $result.ReferenceLinks.PSObject.Properties) {
    Write-Host (" - {0}: {1}" -f $p.Name,$p.Value)
  }

  # ---- make returned object display compact by default (but keep full data) ----
  $result.PSTypeNames.Insert(0,'SqlPlanInsights.Result')

  # Add some convenience count props for display (doesn't change underlying arrays)
  $result | Add-Member -NotePropertyName TopOperatorsCount -NotePropertyValue (@($result.TopOperators).Count) -Force
  $result | Add-Member -NotePropertyName CEIssuesCount -NotePropertyValue (@($result.CardinalityIssues).Count) -Force
  $result | Add-Member -NotePropertyName MissingIndexesCount -NotePropertyValue (@($result.MissingIndexes).Count) -Force
  $result | Add-Member -NotePropertyName JoinChecksCount -NotePropertyValue (@($result.JoinChecks).Count) -Force
  $result | Add-Member -NotePropertyName RedFlagsCount -NotePropertyValue (@($result.OperatorRedFlags).Count) -Force
  $result | Add-Member -NotePropertyName SargIssuesCount -NotePropertyValue (@($result.SargabilityIssues).Count) -Force
  $result | Add-Member -NotePropertyName IndexIntersectCount -NotePropertyValue (@($result.IndexIntersectionSignals).Count) -Force
  $result | Add-Member -NotePropertyName RewriteHintsCount -NotePropertyValue (@($result.RewriteHints).Count) -Force
  $result | Add-Member -NotePropertyName SpillOpsCount -NotePropertyValue (@($result.SpillSignals).Count) -Force
  $result | Add-Member -NotePropertyName ParallelSkewCount -NotePropertyValue (@($result.ParallelSkewSignals).Count) -Force
  $result | Add-Member -NotePropertyName ManyToManyMergeCount -NotePropertyValue (@($result.ManyToManyMergeSignals).Count) -Force
  $result | Add-Member -NotePropertyName PlanConvertCount -NotePropertyValue (@($result.PlanAffectingConvertSignals).Count) -Force
  $result | Add-Member -NotePropertyName CEModelVersion -NotePropertyValue $chosenCEVersion -Force
  $result | Add-Member -NotePropertyName LegacyCECount -NotePropertyValue (@($result.CEModelInfo | Where-Object { $_.CEVersion -eq 70 }).Count) -Force
  $result | Add-Member -NotePropertyName HintSignalsCount -NotePropertyValue (@($result.HintSignals).Count) -Force
  $result | Add-Member -NotePropertyName KeyLookupsCount -NotePropertyValue (@($result.KeyLookups).Count) -Force
  $result | Add-Member -NotePropertyName SortOpsCount -NotePropertyValue (@($result.SortOps).Count) -Force
  $result | Add-Member -NotePropertyName ParallelismOpsCount -NotePropertyValue (@($result.ParallelismOps).Count) -Force
  $result | Add-Member -NotePropertyName SuggestionsCount -NotePropertyValue (@($result.Suggestions).Count) -Force
  $result | Add-Member -NotePropertyName InspectedDatabase -NotePropertyValue ([bool]($InspectDatabase -and $result.DbInspection)) -Force

  # Re-register the compact default view every run: a once-per-session guard caches
  # a stale property set when the script is updated inside a live session.
  Remove-TypeData -TypeName 'SqlPlanInsights.Result' -ErrorAction SilentlyContinue
  if ($true) {
    Update-TypeData -TypeName 'SqlPlanInsights.Result' `
       -DefaultDisplayPropertySet @(
      'File','DegreeOfParallelism','TopOperatorsCount','CEIssuesCount',
      'MissingIndexesCount','KeyLookupsCount','SortOpsCount','ParallelismOpsCount',
      'JoinChecksCount','SpillOpsCount','ParallelSkewCount','ManyToManyMergeCount','PlanConvertCount',
      'CEModelVersion','HintSignalsCount',
      'SuggestionsCount','InspectedDatabase'
    )
  }


  return $result
}
