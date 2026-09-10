#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Find-sqmAgentJobReference.
    Invoke-DbaQuery wird gemockt und liefert eine feste Menge von msdb-Jobstep-Zeilen; getestet
    wird die Trefferlogik (Wortgrenze, Unterstrich, Kommentar, EXEC vs. Erwaehnung,
    Datenbankaufloesung, Filter).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    function New-JobStepRow {
        param(
            [string]$JobName = 'Nightly Load',
            [int]$JobEnabled = 1,
            [int]$StepId = 1,
            [string]$StepName = 'Step 1',
            [string]$Subsystem = 'TSQL',
            $StepDatabase = 'Sales',
            [string]$Command = 'EXEC dbo.usp_LoadSales;',
            [int]$ScheduleCount = 1,
            [int]$ActiveScheduleCount = 1,
            $NextRunKey = 20260908220000,
            $JobLastRunStatus = 1,
            $JobLastRunDate = 20260907,
            $JobLastRunTime = 220000,
            $StepLastRunOutcome = 1,
            $StepLastRunDate = 20260907,
            $StepLastRunTime = 220000
        )
        [PSCustomObject]@{
            JobName             = $JobName
            JobEnabled          = $JobEnabled
            JobOwner            = 'sa'
            JobCategory         = 'Database Maintenance'
            ScheduleCount       = $ScheduleCount
            ActiveScheduleCount = $ActiveScheduleCount
            NextRunKey          = $NextRunKey
            JobLastRunStatus    = $JobLastRunStatus
            JobLastRunDate      = $JobLastRunDate
            JobLastRunTime      = $JobLastRunTime
            StepId              = $StepId
            StepName            = $StepName
            Subsystem           = $Subsystem
            StepDatabase        = $StepDatabase
            StepLastRunOutcome  = $StepLastRunOutcome
            StepLastRunDate     = $StepLastRunDate
            StepLastRunTime     = $StepLastRunTime
            Command             = $Command
        }
    }

    # Ein Satz Jobsteps, der die Faelle abdeckt, an denen eine reine LIKE-Suche scheitert.
    function New-StandardJobStepSet {
        @(
            New-JobStepRow -JobName 'Nightly Load' -StepId 1 -StepName 'Load' `
                -Command 'EXEC dbo.usp_LoadSales;'

            New-JobStepRow -JobName 'Nightly Load' -StepId 2 -StepName 'Bracketed' `
                -Command "DECLARE @rc INT;`r`nEXECUTE @rc = [dbo].[usp_LoadSales];"

            New-JobStepRow -JobName 'Cross DB' -StepId 1 -StepName 'Archive' -StepDatabase 'master' `
                -Command 'EXEC Archive.dbo.usp_LoadSales;'

            New-JobStepRow -JobName 'Only Mentioned' -StepId 1 -StepName 'Check' `
                -Command "SELECT name FROM sys.objects WHERE name = 'usp_LoadSales';"

            New-JobStepRow -JobName 'Commented Out' -StepId 1 -StepName 'Old' `
                -Command "/* EXEC dbo.usp_LoadSales */`r`nSELECT 1;"

            # Unterstrich-Falle: LIKE '%usp_LoadSales%' wuerde das hier finden.
            New-JobStepRow -JobName 'Underscore Trap' -StepId 1 -StepName 'Trap' `
                -Command 'EXEC dbo.uspXLoadYSales;'

            # Praefix-Falle: eine laengere Prozedur mit demselben Namensanfang.
            New-JobStepRow -JobName 'Prefix Trap' -StepId 1 -StepName 'Trap' `
                -Command 'EXEC dbo.usp_LoadSalesArchive;'

            New-JobStepRow -JobName 'Disabled Job' -JobEnabled 0 -StepId 1 -StepName 'Load' `
                -Command 'EXEC dbo.usp_LoadSales;'

            New-JobStepRow -JobName 'Via sqlcmd' -StepId 1 -StepName 'Shell' -Subsystem 'CmdExec' `
                -StepDatabase $null `
                -Command 'sqlcmd -S SQL01 -d Warehouse -Q "EXEC dbo.usp_LoadSales"'

            New-JobStepRow -JobName 'Via PowerShell' -StepId 1 -StepName 'PS' -Subsystem 'PowerShell' `
                -StepDatabase $null `
                -Command 'Invoke-DbaQuery -SqlInstance SQL01 -Database Reporting -Query "EXEC dbo.usp_Refresh"'

            New-JobStepRow -JobName 'Use Statement' -StepId 1 -StepName 'Use' -StepDatabase 'master' `
                -Command "USE [Reporting];`r`nGO`r`nEXEC dbo.usp_Refresh;"

            New-JobStepRow -JobName 'Package' -StepId 1 -StepName 'SSIS' -Subsystem 'SSIS' `
                -StepDatabase $null `
                -Command '/ISSERVER "\SSISDB\Sales\usp_LoadSales.dtsx" /SERVER SQL01'

            New-JobStepRow -JobName 'Truncate Job' -StepId 1 -StepName 'Clean' -StepDatabase 'Staging' `
                -Command "TRUNCATE TABLE dbo.Import;`r`nEXEC dbo.usp_LoadSales;"

            New-JobStepRow -JobName 'Other Schema' -StepId 1 -StepName 'Load' `
                -Command 'EXEC etl.usp_LoadSales;'
        )
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Find-sqmAgentJobReference' {

    Context 'Parameter-Validierung' {
        It 'Funktion existiert' {
            Get-Command Find-sqmAgentJobReference | Should -Not -BeNullOrEmpty
        }

        It '<_> Parameter existiert' -ForEach @(
            'SqlInstance', 'SqlCredential', 'ObjectName', 'SearchText', 'RegexSearch', 'Database',
            'JobName', 'Subsystem', 'ExcludeDisabledJobs', 'IncludeCommand', 'VerifyObject',
            'EnableException'
        ) {
            (Get-Command Find-sqmAgentJobReference).Parameters.ContainsKey($_) | Should -Be $true
        }

        It 'Lehnt ein unbekanntes Subsystem ab' {
            { Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -Subsystem 'Nonsense' } | Should -Throw
        }

        It 'Lehnt einen ungueltigen regulaeren Ausdruck ab' {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
            { Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -SearchText '[unclosed' -RegexSearch } |
                Should -Throw
        }
    }

    Context 'Objektsuche' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-StandardJobStepSet }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Findet den EXEC-Aufruf und meldet ihn als Execute' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.JobName -eq 'Nightly Load' -and $_.StepId -eq 1 }
            $hit | Should -Not -BeNullOrEmpty
            $hit.CallType | Should -Be 'Execute'
            $hit.InComment | Should -Be $false
            $hit.MatchedObject | Should -Be 'usp_LoadSales'
        }

        It 'Findet den Aufruf auch in eckigen Klammern und mit Rueckgabevariable' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.StepName -eq 'Bracketed' }
            $hit | Should -Not -BeNullOrEmpty
            $hit.CallType | Should -Be 'Execute'
            $hit.MatchedObject | Should -Be 'usp_LoadSales'
        }

        It 'Behandelt den Unterstrich als Zeichen, nicht als LIKE-Platzhalter' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            ($r | Where-Object { $_.JobName -eq 'Underscore Trap' }) | Should -BeNullOrEmpty
        }

        It 'Trifft nicht auf einen laengeren Namen mit gleichem Anfang' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            ($r | Where-Object { $_.JobName -eq 'Prefix Trap' }) | Should -BeNullOrEmpty
        }

        It 'Meldet eine blosse Erwaehnung als Reference, nicht als Execute' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.JobName -eq 'Only Mentioned' }
            $hit.CallType | Should -Be 'Reference'
            $hit.InComment | Should -Be $false
        }

        It 'Kennzeichnet eine auskommentierte Fundstelle' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.JobName -eq 'Commented Out' }
            $hit | Should -Not -BeNullOrEmpty
            $hit.InComment | Should -Be $true
        }

        It 'Unterstuetzt Wildcards im Objektnamen' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_Load*' -EnableException)
            ($r | Where-Object { $_.JobName -eq 'Prefix Trap' }) | Should -Not -BeNullOrEmpty
            ($r | Where-Object { $_.JobName -eq 'Underscore Trap' }) | Should -BeNullOrEmpty
        }

        It 'Beschraenkt auf das angegebene Schema' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'etl.usp_LoadSales' -EnableException)
            @($r).Count | Should -Be 1
            $r[0].JobName | Should -Be 'Other Schema'
        }

        It 'Meldet Zeilennummer und Fundzeile' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.StepName -eq 'Bracketed' }
            $hit.MatchLine | Should -Be 2
            $hit.LineText | Should -Match 'EXECUTE @rc'
        }
    }

    Context 'Datenbankaufloesung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-StandardJobStepSet }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Nimmt die Datenbank des Steps, wenn der Aufruf nicht qualifiziert ist' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.JobName -eq 'Nightly Load' -and $_.StepId -eq 1 }
            $hit.ResolvedDatabase | Should -Be 'Sales'
        }

        It 'Nimmt bei dreiteiligem Namen die Datenbank aus dem Aufruf, nicht die des Steps' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.JobName -eq 'Cross DB' }
            $hit.StepDatabase | Should -Be 'master'
            $hit.ResolvedDatabase | Should -Be 'Archive'
        }

        It 'Liest die Datenbank aus einem sqlcmd -d Argument' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -Database 'Warehouse' -EnableException)
            @($r).Count | Should -Be 1
            $r[0].JobName | Should -Be 'Via sqlcmd'
        }

        It 'Liest die Datenbank aus einem -Database Argument eines PowerShell-Steps' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -Database 'Reporting' -EnableException)
            @($r).JobName | Should -Contain 'Via PowerShell'
        }

        It 'Liest die Datenbank aus einer USE-Anweisung' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -Database 'Reporting' -EnableException)
            @($r).JobName | Should -Contain 'Use Statement'
        }

        It 'Der Datenbankteil eines dreiteiligen -ObjectName wirkt als Datenbankfilter' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'Archive.dbo.usp_LoadSales' -EnableException)
            @($r).Count | Should -Be 1
            $r[0].JobName | Should -Be 'Cross DB'
        }
    }

    Context 'Filter' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-StandardJobStepSet }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Deaktivierte Jobs sind standardmaessig enthalten' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            ($r | Where-Object { $_.JobName -eq 'Disabled Job' }) | Should -Not -BeNullOrEmpty
        }

        It 'ExcludeDisabledJobs entfernt sie' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' `
                    -ExcludeDisabledJobs -EnableException)
            ($r | Where-Object { $_.JobName -eq 'Disabled Job' }) | Should -BeNullOrEmpty
        }

        It 'SSIS-Steps werden standardmaessig nicht durchsucht' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            ($r | Where-Object { $_.JobName -eq 'Package' }) | Should -BeNullOrEmpty
        }

        It 'Subsystem All schliesst SSIS-Steps ein' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' `
                    -Subsystem 'All' -EnableException)
            ($r | Where-Object { $_.JobName -eq 'Package' }) | Should -Not -BeNullOrEmpty
        }

        It 'JobName filtert auf den Job' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' `
                    -JobName 'Nightly*' -EnableException)
            @($r).Count | Should -Be 2
            (@($r).JobName | Select-Object -Unique) | Should -Be 'Nightly Load'
        }

        It 'SearchText findet freien Text' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -SearchText 'TRUNCATE TABLE' -EnableException)
            @($r).Count | Should -Be 1
            $r[0].JobName | Should -Be 'Truncate Job'
            $r[0].CallType | Should -Be 'Text'
        }

        It 'SearchText und ObjectName wirken zusammen als UND' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' `
                    -SearchText 'TRUNCATE TABLE' -EnableException)
            @($r).Count | Should -Be 1
            $r[0].JobName | Should -Be 'Truncate Job'
            $r[0].MatchType | Should -Be 'Object+Text'
        }

        It 'RegexSearch behandelt SearchText als regulaeren Ausdruck' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -SearchText 'TRUNCATE\s+TABLE\s+dbo\.\w+' `
                    -RegexSearch -EnableException)
            @($r).Count | Should -Be 1
            $r[0].JobName | Should -Be 'Truncate Job'
        }
    }

    Context 'Ausgabe' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { New-StandardJobStepSet }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Rechnet die msdb-Ganzzahlen in echte Zeitstempel um' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $hit = $r | Where-Object { $_.JobName -eq 'Nightly Load' -and $_.StepId -eq 1 }
            $hit.JobLastRunDate | Should -Be ([datetime]'2026-09-07 22:00:00')
            $hit.NextRunDate | Should -Be ([datetime]'2026-09-08 22:00:00')
            $hit.JobLastRunOutcome | Should -Be 'Succeeded'
            $hit.IsScheduled | Should -Be $true
        }

        It 'Ein nie gelaufener Step wird nicht als Failed gemeldet' {
            # msdb speichert "nie gelaufen" als last_run_outcome = 0 / last_run_date = 0, und 0
            # ist zugleich der Code fuer Failed (auf DEV01 mit acht Ola-Jobs ohne Historie belegt).
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-JobStepRow -JobName 'Never Ran' -StepLastRunOutcome 0 -StepLastRunDate 0 `
                        -StepLastRunTime 0 -JobLastRunStatus $null -JobLastRunDate 0 -JobLastRunTime 0 `
                        -NextRunKey $null)
            }
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $r[0].StepLastRunOutcome | Should -Be 'NeverRun'
            $r[0].StepLastRunDate | Should -BeNullOrEmpty
            $r[0].JobLastRunOutcome | Should -Be 'NeverRun'
            $r[0].NextRunDate | Should -BeNullOrEmpty
        }

        It 'Ein wirklich fehlgeschlagener Lauf bleibt Failed' {
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                @(New-JobStepRow -JobName 'Failed Job' -StepLastRunOutcome 0 -StepLastRunDate 20260907 `
                        -StepLastRunTime 220000 -JobLastRunStatus 0)
            }
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $r[0].StepLastRunOutcome | Should -Be 'Failed'
            $r[0].JobLastRunOutcome | Should -Be 'Failed'
        }

        It 'Liefert ohne IncludeCommand nur die Vorschau' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException)
            $r[0].PSObject.Properties.Name | Should -Not -Contain 'Command'
            $r[0].CommandPreview | Should -Not -BeNullOrEmpty
        }

        It 'IncludeCommand haengt das vollstaendige Kommando an' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' `
                    -IncludeCommand -EnableException)
            $r[0].PSObject.Properties.Name | Should -Contain 'Command'
            $r[0].Command | Should -Be 'EXEC dbo.usp_LoadSales;'
        }

        It 'Fragt jede Instanz einzeln ab und markiert die Herkunft' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'SQL01', 'SQL02' -ObjectName 'usp_LoadSales' -EnableException)
            (@($r).SqlInstance | Select-Object -Unique | Sort-Object) | Should -Be @('SQL01', 'SQL02')
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 2
        }
    }

    Context 'VerifyObject' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'sysjobsteps') {
                    @(
                        New-JobStepRow -JobName 'Nightly Load' -StepId 1 -Command 'EXEC dbo.usp_LoadSales;'
                        New-JobStepRow -JobName 'Second Job' -StepId 1 -Command 'EXEC dbo.usp_LoadSales;'
                    )
                }
                else {
                    @([PSCustomObject]@{ ObjectType = 'SQL_STORED_PROCEDURE' })
                }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Meldet ein vorhandenes Objekt mit Typ' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' `
                    -VerifyObject -EnableException)
            $r[0].ObjectExists | Should -Be $true
            $r[0].ObjectType | Should -Be 'SQL_STORED_PROCEDURE'
        }

        It 'Schlaegt dieselbe Datenbank/Objekt-Kombination nur einmal nach' {
            Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' `
                -VerifyObject -EnableException | Out-Null
            # 1x sysjobsteps + 1x sys.objects, obwohl zwei Jobs dasselbe Objekt aufrufen
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 2
        }

        It 'Ohne VerifyObject wird sys.objects nicht abgefragt' {
            Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException | Out-Null
            Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -Exactly 1
        }
    }

    Context 'VerifyObject bei fehlendem Objekt' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
                if ($Query -match 'sysjobsteps') {
                    @(New-JobStepRow -JobName 'Broken Job' -StepId 1 -Command 'EXEC dbo.usp_Gone;')
                }
                else { @() }
            }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Meldet einen Aufruf eines nicht mehr vorhandenen Objekts' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_Gone' `
                    -VerifyObject -EnableException)
            @($r).Count | Should -Be 1
            $r[0].CallType | Should -Be 'Execute'
            $r[0].ObjectExists | Should -Be $false
        }
    }

    Context 'Fehlerbehandlung' {
        BeforeAll {
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'Login failed' }
            InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
        }

        It 'Wirft mit EnableException' {
            { Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales' -EnableException } |
                Should -Throw
        }

        It 'Ohne EnableException wird protokolliert und leer zurueckgegeben' {
            $r = @(Find-sqmAgentJobReference -SqlInstance 'TESTSERVER' -ObjectName 'usp_LoadSales')
            @($r).Count | Should -Be 0
            Should -Invoke -ModuleName sqmSQLTool Invoke-sqmLogging -ParameterFilter { $Level -eq 'ERROR' }
        }
    }
}
