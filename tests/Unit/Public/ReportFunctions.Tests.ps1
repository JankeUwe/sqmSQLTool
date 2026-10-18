#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer fuenf Berichtsfunktionen: Get-sqmAutoGrowthReport, Get-sqmAgentJobHistory,
    Get-sqmLongRunningQueries, Get-sqmConnectionStats und Get-sqmErrorLog.
.DESCRIPTION
    dbatools und SMO sind gemockt. Geprueft werden Einordnung/Bewertung, Filter, die gebauten
    Abfragen und das Schreiben der Berichtsdateien.
    Get-sqmAutoGrowthReport: Regressionstests fuer drei Fehler (bis 1.9.184.0): Logdateien lagen nicht in
    den Dateigruppen und wurden nie geprueft, SMO-Dateien haben keine Eigenschaft 'Type' (alle Dateien
    galten als Log) und GrowthType 'None' wurde als Prozent-Wachstum gemeldet.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
    $script:TestDir = New-TempTestDirectory

    function script:New-SmoFile
    {
        param([string]$Name, [string]$GrowthType, [double]$Growth, [double]$SizeKB = 102400, [double]$MaxSizeKB = -1)
        [pscustomobject]@{ Name = $Name; FileName = "D:\data\$Name"; GrowthType = $GrowthType; Growth = $Growth; Size = $SizeKB; MaxSize = $MaxSizeKB }
    }
}

AfterAll {
    Remove-Variable -Name SqmQueries, SqmArgs, SqmLog -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmAutoGrowthReport' {
    BeforeEach {
        $global:SqmArgs = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { 'SQL01' }
        Mock -ModuleName sqmSQLTool Get-DbaDatabase {
            $global:SqmArgs.Add("ExcludeSystem=$([bool]$ExcludeSystem);Database=$($Database -join ',')")
            [pscustomobject]@{
                Name = 'Sales'; IsAccessible = $true
                FileGroups = @([pscustomobject]@{ Files = @(
                            (New-SmoFile 'Sales_ok'      'KB'      262144)     # 256 MB
                            (New-SmoFile 'Sales_small'   'KB'      8192)       # 8 MB
                            (New-SmoFile 'Sales_big'     'KB'      2097152)    # 2048 MB
                            (New-SmoFile 'Sales_pct'     'Percent' 10)
                            (New-SmoFile 'Sales_fixed'   'None'    0 -MaxSizeKB 204800)
                        ) })
                LogFiles   = @(
                    (New-SmoFile 'Sales_log'   'KB' 262144)                       # unbegrenzt
                    (New-SmoFile 'Sales_log2'  'KB' 262144 -MaxSizeKB 10485760)   # begrenzt
                )
            }
            [pscustomobject]@{ Name = 'Closed'; IsAccessible = $false; FileGroups = @(); LogFiles = @() }
        }
    }

    It 'meldet Daten- UND Logdateien, mit Dateityp aus der Herkunft' {
        $r = Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport
        $r.Count | Should -Be 7
        ($r | Where-Object FileName -eq 'Sales_ok').FileType | Should -Be 'Data'
        ($r | Where-Object FileName -eq 'Sales_log').FileType | Should -Be 'Log'
        ($r | Where-Object FileType -eq 'Log').Count | Should -Be 2
    }

    It 'bewertet Wachstum in MB: ok, zu klein, sehr gross' {
        $r = Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport
        $ok = $r | Where-Object FileName -eq 'Sales_ok'
        $ok.Status | Should -Be 'OK'
        $ok.GrowthValue | Should -Be 256
        $ok.Assessment | Should -Be 'OK - Best Practice'
        $small = $r | Where-Object FileName -eq 'Sales_small'
        $small.Status | Should -Be 'Warning'
        $small.Assessment | Should -Match 'zu klein'
        $big = $r | Where-Object FileName -eq 'Sales_big'
        $big.Status | Should -Be 'Info'
        $big.Assessment | Should -Match 'sehr gross'
    }

    It 'Prozent-Wachstum ist eine Warnung' {
        $pct = Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport | Where-Object FileName -eq 'Sales_pct'
        $pct.GrowthType | Should -Be 'Percent'
        $pct.Status | Should -Be 'Warning'
    }

    It 'GrowthType None (feste Groesse) ist weder Prozent noch Warnung' {
        $fixed = Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport | Where-Object FileName -eq 'Sales_fixed'
        $fixed.GrowthType | Should -Be 'None'
        $fixed.Status | Should -Be 'Info'
        $fixed.Assessment | Should -Match 'Autogrowth deaktiviert'
        $fixed.Assessment | Should -Not -Match 'Prozent'
    }

    It 'warnt vor einer Logdatei ohne Obergrenze, nicht aber vor einer begrenzten' {
        $r = Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport
        $unl = $r | Where-Object FileName -eq 'Sales_log'
        $unl.Status | Should -Be 'Warning'
        $unl.Assessment | Should -Match 'unbegrenzt'
        $unl.MaxSizeMB | Should -Be 'Unlimited'
        $lim = $r | Where-Object FileName -eq 'Sales_log2'
        $lim.Status | Should -Be 'OK'
        $lim.MaxSizeMB | Should -Be 10240
    }

    It 'ueberspringt nicht zugaengliche Datenbanken' {
        (Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport).DatabaseName | Select-Object -Unique | Should -Be 'Sales'
    }

    It '-Detailed ergaenzt den physischen Pfad' {
        $d = Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport -Detailed | Select-Object -First 1
        $d.PhysicalName | Should -Be 'D:\data\Sales_ok'
        (Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport | Select-Object -First 1).PSObject.Properties.Name | Should -Not -Contain 'PhysicalName'
    }

    It 'reicht -Database weiter und schliesst Systemdatenbanken nur ohne -IncludeSystem aus' {
        Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -Database 'Sales' -NoReport | Out-Null
        Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -IncludeSystem -NoReport | Out-Null
        $global:SqmArgs[0] | Should -Be 'ExcludeSystem=True;Database=Sales'
        $global:SqmArgs[1] | Should -Be 'ExcludeSystem=False;Database='
    }

    It 'schreibt TXT und HTML, mit -NoReport oder -WhatIf nichts' {
        $out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -OutputPath $out -NoReport | Out-Null
        Test-Path $out | Should -BeFalse
        Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -OutputPath $out -WhatIf | Out-Null
        Test-Path $out | Should -BeFalse
        Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -OutputPath $out -NoOpen | Out-Null
        @(Get-ChildItem $out -Filter 'AutoGrowthReport_SQL01_*.txt').Count | Should -Be 1
        @(Get-ChildItem $out -Filter 'AutoGrowthReport_SQL01_*.html').Count | Should -Be 1
    }

    It 'meldet Fehler als Error bzw. wirft mit -EnableException' {
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { throw 'nicht erreichbar' }
        Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        { Get-sqmAutoGrowthReport -SqlInstance 'SQL01' -NoReport -EnableException } | Should -Throw '*nicht erreichbar*'
    }
}

Describe 'Get-sqmAgentJobHistory' {
    BeforeEach {
        $global:SqmArgs = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Get-DbaAgentJob { @([pscustomobject]@{ Name = 'A_Load' }, [pscustomobject]@{ Name = 'B_Backup' }) }
        Mock -ModuleName sqmSQLTool Get-DbaAgentJobHistory {
            $global:SqmArgs.Add("Job=${Job};Outcome=${OutcomeType};Start=$($StartDate.ToString('yyyy-MM-dd'))")
            1..3 | ForEach-Object {
                [pscustomobject]@{ StepName = "Step$_"; RunDate = (Get-Date '2026-10-10').AddHours($_); Status = if ($_ -eq 2) { 'Failed' } else { 'Succeeded' }
                    Message = 'Meldung <b>x</b>'; Duration = [timespan]::FromSeconds(65 * $_) }
            }
        }
    }

    It 'liest die Historie jedes passenden Jobs; -JobName filtert per Wildcard' {
        $all = @(Get-sqmAgentJobHistory -SqlInstance 'SQL01' -OutputPath '')
        $all.Count | Should -Be 6
        ($all.JobName | Select-Object -Unique) | Should -Be @('A_Load', 'B_Backup')
        $a = @(Get-sqmAgentJobHistory -SqlInstance 'SQL01' -JobName 'A_*' -OutputPath '')
        ($a.JobName | Select-Object -Unique) | Should -Be 'A_Load'
    }

    It '<Status> wird als OutcomeType <Expected> an dbatools uebergeben' -ForEach @(
        @{ Status = 'Success'; Expected = 'Succeeded' }
        @{ Status = 'Failure'; Expected = 'Failed' }
        @{ Status = 'Retry'; Expected = 'Retry' }
        @{ Status = 'Cancelled'; Expected = 'Cancelled' }
    ) {
        Get-sqmAgentJobHistory -SqlInstance 'SQL01' -JobName 'A_*' -Status $Status -OutputPath '' | Out-Null
        $global:SqmArgs[0] | Should -Match "Outcome=$Expected;"
    }

    It 'ohne -Status wird kein OutcomeType gesetzt; -Since steuert StartDate' {
        Get-sqmAgentJobHistory -SqlInstance 'SQL01' -JobName 'A_*' -Since ([datetime]'2026-01-02') -OutputPath '' | Out-Null
        $global:SqmArgs[0] | Should -Be 'Job=A_Load;Outcome=;Start=2026-01-02'
    }

    It '-LastX begrenzt je Job' {
        @(Get-sqmAgentJobHistory -SqlInstance 'SQL01' -LastX 2 -OutputPath '').Count | Should -Be 4
    }

    It 'formatiert die Dauer als Stunden, Minuten, Sekunden' {
        $r = @(Get-sqmAgentJobHistory -SqlInstance 'SQL01' -JobName 'A_*' -OutputPath '')
        $r[0].Duration | Should -Be '0h 1m 5s'
        $r[2].Duration | Should -Be '0h 3m 15s'
    }

    It 'schreibt CSV und HTML mit HTML-kodierten Meldungen' {
        $base = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Get-sqmAgentJobHistory -SqlInstance 'SQL01' -JobName 'A_*' -OutputPath "$base\hist.csv" -NoOpen | Out-Null
        Test-Path "$base\hist.csv" | Should -BeTrue
        $html = Get-Content "$base\hist.html" -Raw
        $html | Should -Match '&lt;b&gt;x&lt;/b&gt;'
        $html | Should -Not -Match '<b>x</b>'
        (Import-Csv "$base\hist.csv").Count | Should -Be 3
    }

    It 'ohne -OutputPath-Wert entstehen keine Dateien' {
        $before = @(Get-ChildItem $script:TestDir -Recurse -File).Count
        Get-sqmAgentJobHistory -SqlInstance 'SQL01' -OutputPath '' | Out-Null
        @(Get-ChildItem $script:TestDir -Recurse -File).Count | Should -Be $before
    }

    It 'gibt bei einem dbatools-Fehler $null zurueck bzw. wirft mit -EnableException' {
        Mock -ModuleName sqmSQLTool Get-DbaAgentJob { throw 'Agent nicht erreichbar' }
        Get-sqmAgentJobHistory -SqlInstance 'SQL01' -OutputPath '' | Should -BeNullOrEmpty
        { Get-sqmAgentJobHistory -SqlInstance 'SQL01' -OutputPath '' -EnableException } | Should -Throw '*Agent nicht erreichbar*'
    }

    It 'lehnt unbekannte Status-Werte ab' {
        { Get-sqmAgentJobHistory -SqlInstance 'SQL01' -Status 'Egal' } | Should -Throw
    }
}

Describe 'Get-sqmLongRunningQueries' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*dm_exec_query_plan*') { return [pscustomobject]@{ query_plan = '<ShowPlanXML/>' } }
            @(
                [pscustomobject]@{ SessionId = 61; BlockingSpid = 0; DatabaseName = 'Sales'; LoginName = 'app'; HostName = 'H1'; ProgramName = 'App'; RequestStatus = 'running'; Command = 'SELECT'
                    DurationSeconds = 120; StartTime = (Get-Date); CpuMs = 5000; LogicalReads = 10; PhysicalReads = 1; Writes = 0; WaitType = 'LCK_M_X'; WaitSeconds = 1.234; WaitResource = 'KEY'
                    PercentComplete = 12.34; EstimatedCompletion = $null; OpenTransactions = 1; IsolationLevel = 'ReadCommitted'; QueryHash = [byte[]](0xAB, 0xCD); QueryPlanHash = [byte[]](0x01, 0x02)
                    PlanHandle = [byte[]](0xDE, 0xAD); CurrentStatement = "SELECT   *`r`n  FROM   t"; FullBatch = 'batch'; SessionTotalElapsedMs = 1; LastRequestStart = (Get-Date) }
                [pscustomobject]@{ SessionId = 62; BlockingSpid = 61; DatabaseName = 'Sales'; LoginName = 'app2'; HostName = 'H2'; ProgramName = 'App'; RequestStatus = 'suspended'; Command = 'UPDATE'
                    DurationSeconds = 90; StartTime = (Get-Date); CpuMs = 10; LogicalReads = 1; PhysicalReads = 0; Writes = 1; WaitType = 'WAITFOR'; WaitSeconds = 90; WaitResource = ''
                    PercentComplete = 0; EstimatedCompletion = $null; OpenTransactions = 0; IsolationLevel = 'Snapshot'; QueryHash = $null; QueryPlanHash = $null
                    PlanHandle = $null; CurrentStatement = 'WAITFOR DELAY'; FullBatch = 'x'; SessionTotalElapsedMs = 1; LastRequestStart = (Get-Date) }
                [pscustomobject]@{ SessionId = 63; BlockingSpid = 61; DatabaseName = 'Hr'; LoginName = 'app3'; HostName = 'H3'; ProgramName = 'App'; RequestStatus = 'suspended'; Command = 'DELETE'
                    DurationSeconds = 70; StartTime = (Get-Date); CpuMs = 10; LogicalReads = 1; PhysicalReads = 0; Writes = 1; WaitType = $null; WaitSeconds = 0; WaitResource = ''
                    PercentComplete = 0; EstimatedCompletion = $null; OpenTransactions = 0; IsolationLevel = 'Snapshot'; QueryHash = $null; QueryPlanHash = $null
                    PlanHandle = $null; CurrentStatement = 'DELETE'; FullBatch = 'y'; SessionTotalElapsedMs = 1; LastRequestStart = (Get-Date) }
            )
        }
    }

    It 'baut die Abfrage mit Mindestdauer, Benutzersitzungen und optionalem CPU-Filter' {
        Get-sqmLongRunningQueries -SqlInstance 'SQL01' -OutputPath '' | Out-Null
        $q = $global:SqmQueries[0]
        $q | Should -Match '>= 30'
        $q | Should -Match 'AND r\.session_id > 50'
        $q | Should -Not -Match 'r\.cpu_time >='
        $global:SqmQueries.Clear()
        Get-sqmLongRunningQueries -SqlInstance 'SQL01' -MinDurationSeconds 5 -MinCpuMs 1000 -IncludeSystemSessions -OutputPath '' | Out-Null
        $q2 = $global:SqmQueries[0]
        $q2 | Should -Match '>= 5'
        $q2 | Should -Match 'AND r\.cpu_time >= 1000'
        $q2 | Should -Not -Match 'session_id > 50'
    }

    It 'schliesst konfigurierte Wartetypen aus (WAITFOR), behaelt echte Sperren' {
        $r = @(Get-sqmLongRunningQueries -SqlInstance 'SQL01' -OutputPath '')
        $r.SessionId | Should -Be @(61, 63)
        @(Get-sqmLongRunningQueries -SqlInstance 'SQL01' -ExcludeWaitType @() -OutputPath '').Count | Should -Be 3
    }

    It 'bildet die Zeilen ab: Blocking null statt 0, Hashes als Hex, Statement ohne Zeilenumbrueche, gerundete Werte' {
        $r = @(Get-sqmLongRunningQueries -SqlInstance 'SQL01' -OutputPath '')
        $r[0].BlockingSpid | Should -BeNullOrEmpty
        $r[0].IsBlocked | Should -BeFalse
        $r[0].QueryHash | Should -Be 'ABCD'
        $r[0].QueryPlanHash | Should -Be '0102'
        $r[0].CurrentStatement | Should -Be 'SELECT * FROM t'
        $r[0].WaitSeconds | Should -Be 1.2
        $r[0].PercentComplete | Should -Be 12.3
        $r[1].BlockingSpid | Should -Be 61
        $r[1].IsBlocked | Should -BeTrue
        $r[1].QueryHash | Should -BeNullOrEmpty
    }

    It 'holt den Plan nur mit -IncludeQueryPlan und nur fuer Zeilen mit PlanHandle' {
        (Get-sqmLongRunningQueries -SqlInstance 'SQL01' -OutputPath '')[0].QueryPlanXml | Should -BeNullOrEmpty
        $global:SqmQueries.Clear()
        $r = @(Get-sqmLongRunningQueries -SqlInstance 'SQL01' -IncludeQueryPlan -OutputPath '')
        $r[0].QueryPlanXml | Should -Be '<ShowPlanXML/>'
        ($global:SqmQueries | Where-Object { $_ -like '*dm_exec_query_plan(0xDEAD)*' }).Count | Should -Be 1
        ($global:SqmQueries | Where-Object { $_ -like '*dm_exec_query_plan*' }).Count | Should -Be 1
    }

    It 'ein nicht abrufbarer Plan bricht die Auswertung nicht ab' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { if ($Query -like '*dm_exec_query_plan*') { throw 'Plan weg' }; [pscustomobject]@{
                SessionId = 61; BlockingSpid = 0; WaitType = $null; WaitSeconds = 0; PercentComplete = 0; PlanHandle = [byte[]](1, 2); CurrentStatement = 'x'; QueryHash = $null; QueryPlanHash = $null } }
        $r = @(Get-sqmLongRunningQueries -SqlInstance 'SQL01' -IncludeQueryPlan -OutputPath '')
        $r.Count | Should -Be 1
        $r[0].QueryPlanXml | Should -BeNullOrEmpty
    }

    It 'schreibt CSV (ohne FullBatch/QueryPlanXml) und HTML' {
        $out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Get-sqmLongRunningQueries -SqlInstance 'SQL01\INST1' -OutputPath $out -NoOpen | Out-Null
        $csv = Get-ChildItem $out -Filter 'LongRunning_SQL01_INST1_*.csv'
        $csv.Count | Should -Be 1
        (Import-Csv $csv.FullName | Select-Object -First 1).PSObject.Properties.Name | Should -Not -Contain 'FullBatch'
        @(Get-ChildItem $out -Filter '*.html').Count | Should -Be 1
    }

    It 'gibt bei einem Abfragefehler Error + $null aus bzw. wirft mit -EnableException' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'Timeout' }
        Get-sqmLongRunningQueries -SqlInstance 'SQL01' -OutputPath '' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        { Get-sqmLongRunningQueries -SqlInstance 'SQL01' -OutputPath '' -EnableException } | Should -Throw '*Timeout*'
    }
}

Describe 'Get-sqmConnectionStats' {
    BeforeEach {
        $global:SqmQueries = [System.Collections.Generic.List[string]]::new()
        $global:SqmLog = @{ MaxConn = 200 }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            $global:SqmQueries.Add($Query)
            if ($Query -like '*sys.configurations*') { return [pscustomobject]@{ MaxConnections = $global:SqmLog.MaxConn } }
            $t = Get-Date
            function s($id, $login, $prog, $hst, $db, $active, $block, $wait, $waitMs, $cpu, $user = 1)
            {
                [pscustomobject]@{ session_id = $id; login_name = $login; program_name = $prog; host_name = $hst; database_name = $db; status = 'running'; cpu_time = $cpu; memory_kb = 100
                    logical_reads = 10; reads = 1; writes = 1; login_time = $t.AddMinutes(-10); is_user_process = $user; has_active_request = $active; blocking_session_id = $block
                    wait_type = $wait; wait_time_ms = $waitMs }
            }
            s 51 'app'  'WebApp'  'H1' 'Sales' 1 0  ''        0   100
            s 52 'app'  'WebApp'  'H1' 'Sales' 1 51 'LCK_M_X' 900 50
            s 53 'app'  'WebApp'  'H2' 'Sales' 0 0  ''        0   10
            s 54 'etl'  'SSIS'    'H3' 'Hr'    1 0  'CXPACKET' 20 500
            s 55 'sys'  ''        ''   'master' 0 0 ''       0   1 0
        }
    }

    It 'berechnet die Gesamtzahlen (Verbindungen, aktive Requests, blockierte, Auslastung)' {
        $r = Get-sqmConnectionStats -SqlInstance 'SQL01' -OutputPath ''
        $r.Summary.TotalConnections | Should -Be 5
        $r.Summary.ActiveRequests | Should -Be 3
        $r.Summary.BlockedSessions | Should -Be 1
        $r.Summary.UserConnections | Should -Be 4
        $r.Summary.SystemConnections | Should -Be 1
        $r.Summary.MaxConnections | Should -Be 200
        $r.Summary.ConnectionUsagePct | Should -Be 2.5
    }

    It 'max connections 0 (unbegrenzt) faellt auf 32767 zurueck' {
        $global:SqmLog.MaxConn = 0
        (Get-sqmConnectionStats -SqlInstance 'SQL01' -OutputPath '').Summary.MaxConnections | Should -Be 32767
    }

    It '-GroupBy <GroupBy> gruppiert nach dem passenden Feld' -ForEach @(
        @{ GroupBy = 'Application'; Top = 'WebApp'; TopCount = 3 }
        @{ GroupBy = 'Login'; Top = 'app'; TopCount = 3 }
        @{ GroupBy = 'Host'; Top = 'H1'; TopCount = 2 }
        @{ GroupBy = 'Database'; Top = 'Sales'; TopCount = 3 }
    ) {
        $g = (Get-sqmConnectionStats -SqlInstance 'SQL01' -GroupBy $GroupBy -OutputPath '').GroupedStats
        $g[0].GroupValue | Should -Be $Top
        $g[0].ConnectionCount | Should -Be $TopCount
    }

    It 'fasst Zaehler je Gruppe zusammen' {
        $g = (Get-sqmConnectionStats -SqlInstance 'SQL01' -GroupBy Login -OutputPath '').GroupedStats | Where-Object GroupValue -eq 'app'
        $g.ActiveRequests | Should -Be 2
        $g.BlockedSessions | Should -Be 1
        $g.TotalCpuMs | Should -Be 160
        $g.WaitTypes | Should -Be 'LCK_M_X'
    }

    It '-TopN begrenzt die Gruppen' {
        @((Get-sqmConnectionStats -SqlInstance 'SQL01' -GroupBy Login -TopN 1 -OutputPath '').GroupedStats).Count | Should -Be 1
    }

    It 'listet aktive Requests nach Wartezeit absteigend' {
        $a = (Get-sqmConnectionStats -SqlInstance 'SQL01' -OutputPath '').ActiveRequests
        $a.SessionId | Should -Be @(52, 54, 51)
        $a[0].BlockedBy | Should -Be 51
    }

    It 'filtert Systemverbindungen in der Abfrage, ausser mit -IncludeSystemConnections' {
        Get-sqmConnectionStats -SqlInstance 'SQL01' -OutputPath '' | Out-Null
        $global:SqmQueries[0] | Should -Match 'AND s\.is_user_process = 1'
        $global:SqmQueries.Clear()
        Get-sqmConnectionStats -SqlInstance 'SQL01' -IncludeSystemConnections -OutputPath '' | Out-Null
        $global:SqmQueries[0] | Should -Not -Match 'is_user_process = 1'
    }

    It 'schreibt CSV und HTML in -OutputPath' {
        $out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Get-sqmConnectionStats -SqlInstance 'SQL01' -OutputPath $out -NoOpen | Out-Null
        @(Get-ChildItem $out -Filter 'ConnectionStats_SQL01_*.csv').Count | Should -Be 1
        @(Get-ChildItem $out -Filter 'ConnectionStats_SQL01_*.html').Count | Should -Be 1
    }

    It 'wirft mit -EnableException bei Abfragefehler' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'kein Zugriff' }
        { Get-sqmConnectionStats -SqlInstance 'SQL01' -OutputPath '' -EnableException } | Should -Throw '*kein Zugriff*'
    }

    It 'lehnt -TopN ausserhalb 1-500 und unbekannte -GroupBy-Werte ab' {
        { Get-sqmConnectionStats -SqlInstance 'SQL01' -TopN 0 } | Should -Throw
        { Get-sqmConnectionStats -SqlInstance 'SQL01' -GroupBy 'Egal' } | Should -Throw
    }
}

Describe 'Get-sqmErrorLog' {
    BeforeEach {
        $global:SqmArgs = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        Mock -ModuleName sqmSQLTool Copy-sqmToCentralPath { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -like '*18456*') { [pscustomobject]@{ text = "Login failed for user '%.*ls'.%.*ls%.*ls" } }
            elseif ($Query -like '*18453*') { [pscustomobject]@{ text = "Login succeeded for user '%.*ls'. Connection made using Windows Authentication.%.*ls" } }
        }
        Mock -ModuleName sqmSQLTool Get-DbaErrorLog {
            $global:SqmArgs.Add("Instance=$("$SqlInstance");Log=${LogNumber};After=$($After)")
            if ("$SqlInstance" -eq 'DOWN') { throw 'nicht erreichbar' }
            $d = [datetime]'2026-10-10 10:00:00'
            @(
                [pscustomobject]@{ LogDate = $d.AddMinutes(1); ProcessInfo = 'Logon'; Text = "Login failed for user 'DOM\bob'. Reason: Password did not match. [CLIENT: 10.0.0.1]" }
                [pscustomobject]@{ LogDate = $d.AddMinutes(2); ProcessInfo = 'Logon'; Text = "Login succeeded for user 'DOM\alice'. Connection made using Windows Authentication. [CLIENT: <local machine>]" }
                [pscustomobject]@{ LogDate = $d.AddMinutes(3); ProcessInfo = 'spid51'; Text = 'Error: 823, Severity: 24, State: 2.' }
                [pscustomobject]@{ LogDate = $d.AddMinutes(4); ProcessInfo = 'Backup'; Text = 'Database backed up. Database: Sales, creation date(time): 2026/10/10' }
                [pscustomobject]@{ LogDate = $d.AddMinutes(5); ProcessInfo = 'Server'; Text = 'Something else entirely' }
                [pscustomobject]@{ LogDate = $d.AddMinutes(6); ProcessInfo = 'Server'; Text = '   ' }
                [pscustomobject]@{ LogDate = $d.AddMinutes(7); ProcessInfo = 'spid52'; Text = 'SQL Server detected a logical consistency error in Hr' }
            )
        }
    }

    It 'ohne Auswahl klassifiziert alle Zeilen (leere werden uebergangen), neueste zuerst' {
        $r = @(Get-sqmErrorLog -SqlInstance 'SQL01' -OutputPath '')
        $r.Count | Should -Be 6
        $r[0].LogDate | Should -BeGreaterThan $r[-1].LogDate
        ($r | Where-Object Category -eq 'FailedLogin').LoginName | Should -Be 'DOM\bob'
        ($r | Where-Object Category -eq 'SuccessfulLogin').LoginName | Should -Be 'DOM\alice'
        ($r | Where-Object Category -eq 'Backup').Count | Should -Be 1
        ($r | Where-Object Category -eq 'Corruption').Count | Should -Be 1
        ($r | Where-Object Category -eq 'Other').Count | Should -Be 1
    }

    It 'zerlegt Fehlermeldungen in Nummer, Schweregrad und Status' {
        $e = Get-sqmErrorLog -SqlInstance 'SQL01' -Errors -OutputPath ''
        $e.ErrorNumber | Should -Be 823
        $e.Severity | Should -Be 24
        $e.State | Should -Be 2
        $e.Category | Should -Be 'Error'
    }

    It '-FailedLogins, -SuccessfulLogins und -Logins waehlen die Kategorien' {
        (Get-sqmErrorLog -SqlInstance 'SQL01' -FailedLogins -OutputPath '').Category | Should -Be 'FailedLogin'
        (Get-sqmErrorLog -SqlInstance 'SQL01' -SuccessfulLogins -OutputPath '').Category | Should -Be 'SuccessfulLogin'
        @((Get-sqmErrorLog -SqlInstance 'SQL01' -Logins -OutputPath '').Category | Sort-Object) | Should -Be @('FailedLogin', 'SuccessfulLogin')
    }

    It 'mehrere Kategorien lassen sich kombinieren' {
        @((Get-sqmErrorLog -SqlInstance 'SQL01' -Backups -CorruptionEvents -OutputPath '').Category | Sort-Object) | Should -Be @('Backup', 'Corruption')
    }

    It '-Database und -Pattern filtern den Text; -Top begrenzt' {
        (Get-sqmErrorLog -SqlInstance 'SQL01' -Database 'Sales' -OutputPath '').Category | Should -Be 'Backup'
        (Get-sqmErrorLog -SqlInstance 'SQL01' -Pattern 'entirely$' -OutputPath '').Category | Should -Be 'Other'
        @(Get-sqmErrorLog -SqlInstance 'SQL01' -Top 2 -OutputPath '').Count | Should -Be 2
    }

    It 'reicht -LogNumber und -Since an Get-DbaErrorLog weiter' {
        Get-sqmErrorLog -SqlInstance 'SQL01' -LogNumber 0, 2 -Since ([datetime]'2026-10-01') -OutputPath '' | Out-Null
        $global:SqmArgs.Count | Should -Be 2
        $global:SqmArgs[0] | Should -Match 'Log=0;After=.*2026'
        $global:SqmArgs[1] | Should -Match 'Log=2;'
    }

    It 'wertet mehrere Instanzen aus und behaelt die Zuordnung' {
        $r = @(Get-sqmErrorLog -SqlInstance 'SQL01', 'SQL02' -Backups -OutputPath '')
        $r.SqlInstance | Should -Be @('SQL01', 'SQL02')
    }

    It 'eine nicht erreichbare Instanz liefert keine Zeilen, die anderen schon' {
        $r = @(Get-sqmErrorLog -SqlInstance 'DOWN', 'SQL01' -Backups -OutputPath '')
        $r.SqlInstance | Should -Be 'SQL01'
    }

    It 'schreibt CSV und HTML und kopiert sie zentral' {
        $out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Get-sqmErrorLog -SqlInstance 'SQL01' -OutputPath $out -NoOpen | Out-Null
        @(Get-ChildItem $out -Filter 'ErrorLog_*.csv').Count | Should -Be 1
        @(Get-ChildItem $out -Filter 'ErrorLog_*.html').Count | Should -Be 1
        Should -Invoke -ModuleName sqmSQLTool Copy-sqmToCentralPath -Times 1 -Exactly
    }

    It 'ohne Treffer entstehen keine Dateien' {
        $out = Join-Path $script:TestDir ([guid]::NewGuid().ToString('N'))
        Get-sqmErrorLog -SqlInstance 'SQL01' -Pattern 'gibtsnicht' -OutputPath $out | Out-Null
        Test-Path $out | Should -BeFalse
    }
}
