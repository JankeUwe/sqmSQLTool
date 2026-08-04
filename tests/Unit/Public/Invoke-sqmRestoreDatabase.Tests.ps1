#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die AG-Erkennung von Invoke-sqmRestoreDatabase und die private
    Hilfsfunktion Get-sqmDatabaseAgMembership. Alle SQL-Zugriffe sind gemockt.

.DESCRIPTION
    Hintergrund (1.9.27.0): die Erkennung lief ueber
    "Get-DbaAgDatabase ... -ErrorAction SilentlyContinue" und konnte damit "die Datenbank ist in
    keiner AG" nicht von "ich konnte es nicht feststellen" unterscheiden. Fehlende Rechte, eine
    stolpernde SMO-Enumeration oder die falsche Instanz lieferten dasselbe leere Ergebnis wie eine
    echte Standalone-Datenbank. Die Funktion uebersprang daraufhin das Entfernen aus der AG und
    scheiterte erst Schritte spaeter an ALTER DATABASE und RESTORE.

    Diese Tests halten genau diese Unterscheidung fest. Der wichtigste Fall ist
    "Mitgliedschaftsabfrage schlaegt fehl -> Ausnahme": geht der jemals wieder verloren, ist der
    Fehler von 2026-07-28 zurueck.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmDatabaseAgMembership' {

    It 'meldet HadrEnabled=false und bricht NICHT ab, wenn AlwaysOn nicht aktiviert ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery { [PSCustomObject]@{ HadrEnabled = 0 } }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.HadrEnabled  | Should -BeFalse
            $r.IsAgDatabase | Should -BeFalse
            $r.AvailabilityGroupName | Should -BeNullOrEmpty
        }
    }

    It 'meldet IsAgDatabase=false, wenn AlwaysOn aktiv ist, die Datenbank aber kein Mitglied ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { @() }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.HadrEnabled  | Should -BeTrue
            $r.IsAgDatabase | Should -BeFalse
        }
    }

    It 'erkennt die Mitgliedschaft samt AG-Name und Primary' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { [PSCustomObject]@{ AvailabilityGroupName = 'AG_Prod' } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } -MockWith { [PSCustomObject]@{ PrimaryReplica = 'NODE1' } }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.IsAgDatabase          | Should -BeTrue
            $r.AvailabilityGroupName | Should -Be 'AG_Prod'
            $r.PrimaryReplica        | Should -Be 'NODE1'
        }
    }

    It 'WIRFT, wenn die Mitgliedschaftsabfrage fehlschlaegt, statt "keine AG" zu melden' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { throw 'The SELECT permission was denied' }

            { Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb' } |
                Should -Throw -ExpectedMessage '*konnte nicht ermittelt werden*'
        }
    }

    It 'WIRFT, wenn schon der AlwaysOn-Status nicht ermittelbar ist' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery { throw 'Verbindung fehlgeschlagen' }

            { Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb' } |
                Should -Throw -ExpectedMessage '*konnte nicht ermittelt werden*'
        }
    }

    It 'liefert die Mitgliedschaft auch dann, wenn nur die Primary-Abfrage fehlschlaegt' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'IsHadrEnabled' } -MockWith { [PSCustomObject]@{ HadrEnabled = 1 } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'availability_databases_cluster' } -MockWith { [PSCustomObject]@{ AvailabilityGroupName = 'AG_Prod' } }
            Mock Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_availability_replica_states' } -MockWith { throw 'VIEW SERVER STATE denied' }

            $r = Get-sqmDatabaseAgMembership -SqlInstance 'SQL01' -Database 'amb'

            $r.IsAgDatabase   | Should -BeTrue
            $r.PrimaryReplica | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-sqmRestoreDatabase - AG-Erkennung' {

    It 'verwendet Get-sqmDatabaseAgMembership und nicht mehr Get-DbaAgDatabase' {
        $source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1" -Raw
        $source | Should -Match 'Get-sqmDatabaseAgMembership'
        # Get-DbaAgDatabase darf fuer die Erkennung nicht mehr verwendet werden - der Aufruf mit
        # unterdruecktem Fehler war die Ursache des Fehlverhaltens.
        $source | Should -Not -Match 'Get-DbaAgDatabase\s+-SqlInstance'
    }

    It 'uebergibt -Confirm nur an Befehle, die ShouldProcess ueberhaupt unterstuetzen' {
        # Regression 1.9.27.1: -Confirm:$false wurde pauschal an JEDES genestete dbatools-Cmdlet
        # gehaengt. Export-DbaUser unterstuetzt ShouldProcess nicht (dbatools 2.8.2) und scheiterte
        # mit "Es wurde kein Parameter gefunden, der dem Parameternamen 'Confirm' entspricht".
        # Da der catch des User-Exports den Lauf per return beendet, lief der Restore danach
        # ueberhaupt nicht mehr - ohne dass die Meldung erkennen liess, woran es lag.
        $path = "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $commands = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)

        $offenders = @()
        foreach ($command in $commands)
        {
            $name = $command.GetCommandName()
            if (-not $name) { continue }

            $passesConfirm = $command.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Confirm'
            }
            if (-not $passesConfirm) { continue }

            # Nur beurteilen, was hier auch aufloesbar ist - ein unbekannter Name sagt nichts aus.
            $resolved = Get-Command $name -ErrorAction SilentlyContinue
            if ($resolved -and -not $resolved.Parameters.ContainsKey('Confirm'))
            {
                $offenders += "$name (Zeile $($command.Extent.StartLineNumber))"
            }
        }

        ($offenders -join ', ') | Should -BeNullOrEmpty
    }

    It 'bricht ab, bevor irgendetwas passiert, wenn die AG-Zugehoerigkeit nicht ermittelbar ist' {
        InModuleScope sqmSQLTool {
            $fakeBackup = Join-Path ([System.IO.Path]::GetTempPath()) 'sqmRestoreTest_dummy.bak'
            Set-Content -Path $fakeBackup -Value 'dummy' -Encoding Ascii

            Mock Invoke-sqmLogging { }
            Mock Connect-DbaInstance { [PSCustomObject]@{ Name = 'SQL01' } }
            Mock Get-sqmDatabaseAgMembership { throw 'AG-Mitgliedschaft von "amb" konnte nicht ermittelt werden' }
            Mock Export-DbaUser { }
            Mock Restore-DbaDatabase { }

            {
                Invoke-sqmRestoreDatabase -SqlInstance 'SQL01' -BackupFile $fakeBackup `
                    -DatabaseName 'amb' -EnableException -Confirm:$false
            } | Should -Throw

            # Entscheidend: kein Schritt darf gelaufen sein. Genau das war der Fehler - der Lauf
            # kam bis zum User-Export und zum Restore, bevor SQL Server ihn abgewiesen hat.
            Should -Invoke Export-DbaUser -Times 0
            Should -Invoke Restore-DbaDatabase -Times 0

            Remove-Item $fakeBackup -ErrorAction SilentlyContinue
        }
    }

    It 'prueft vor Remove-DbaAgDatabase die lebende Mitgliedschaft, nicht eine nie zugewiesene Variable' {
        # Regression 1.9.35.0: "if (-not $agDbCheck)" - $agDbCheck wurde seit dem Refactoring auf
        # Get-sqmDatabaseAgMembership (1.9.27.0) nirgends mehr zugewiesen und wertete damit IMMER
        # als $null. Die Bedingung war dadurch permanent wahr, Remove-DbaAgDatabase lief nie -
        # selbst wenn die Datenbank nachweislich noch AG-Mitglied war.
        $source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1" -Raw
        $source | Should -Not -Match '\$agDbCheck'
        $source | Should -Match '\(-not \$agMembership\.IsAgDatabase\)'
    }

    It 'nimmt den Multi-User-Reset am Ende nicht nur vor, wenn die Funktion selbst SINGLE_USER gesetzt hatte' {
        # Regression 1.9.35.0: RESTORE DATABASE uebernimmt den User-Access-Modus, der zum
        # Zeitpunkt der Sicherung im Backup selbst galt (Boot-Page). War die Quelldatenbank beim
        # Backup in RESTRICTED_USER (z.B. waehrend einer Migration), kam die wiederhergestellte
        # Kopie in genau diesem Modus wieder hoch - auch wenn diese Funktion selbst nie
        # SINGLE_USER gesetzt hatte ($wasSingleUser blieb $false). Der alte Reset-Schritt haengte
        # ausschliesslich an dieser Fahne und lief in diesem Fall nie. Der Fix fragt stattdessen
        # den tatsaechlichen Live-Zustand ab.
        $source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1" -Raw
        $source | Should -Match 'user_access_desc'
        $source | Should -Not -Match 'if\s*\(\$wasSingleUser\)\s*\r?\n\s*\{\s*\r?\n\s*\$setMultiUserAction'
    }

    It 'gibt jedem verschachtelten dbatools-Aufruf, der -ErrorAction Stop erwartet, auch -EnableException mit' {
        # Regression 1.9.35.0: Restore-DbaDatabase (und praktisch jeder andere genestete
        # dbatools-Aufruf in dieser Funktion) hatte nur -ErrorAction Stop, kein -EnableException.
        # dbatools-Funktionen melden interne Ablehnungen (z.B. "RESTORE cannot operate on database
        # ... because it is ... an availability group") ohne -EnableException per PSFramework
        # Stop-Function nur als Warning und geben $null zurueck - OHNE eine terminierende Exception.
        # -ErrorAction Stop allein faengt das nicht ab. Ein echter Lauf protokollierte dadurch
        # "Restore erfolgreich" fuer vier Datenbanken, obwohl msdb.dbo.restorehistory keinen
        # einzigen neuen Eintrag zeigte - der Restore war nie gelaufen, das eigene try/catch hat es
        # nie bemerkt. Jeder Cmdlet-Name unten unterstuetzt -EnableException laut
        # Get-Command <Name> | Select -Expand Parameters (dbatools 2.8.2) - nur Connect-DbaInstance
        # kennt den Parameter nicht (siehe Invoke-sqmDeployScripts weiter oben im Changelog) und
        # bleibt bewusst bei -ErrorAction Stop allein.
        $path = "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)

        # 1) Direkte Cmdlet-Aufrufe mit -ErrorAction (Stop) als Parameter
        $commands = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
        $mustSupportEnableException = @(
            'Invoke-DbaQuery', 'Restore-DbaDatabase', 'Export-DbaUser', 'Repair-DbaDbOrphanUser',
            'Set-DbaDbOwner', 'Remove-DbaAgDatabase', 'Remove-DbaDatabase', 'Add-DbaAgDatabase',
            'Set-DbaAgReplica', 'Get-DbaAgReplica', 'Backup-DbaDatabase'
        )

        $offenders = @()
        foreach ($command in $commands)
        {
            $name = $command.GetCommandName()
            if ($name -notin $mustSupportEnableException) { continue }

            # Nur echtes "-ErrorAction Stop" (bzw. 'Stop') zaehlt - ein bewusstes
            # "-ErrorAction SilentlyContinue" (z.B. Best-Effort-Cleanup) soll TOLERANT bleiben und
            # braucht kein -EnableException.
            $elements = $command.CommandElements
            $hasErrorActionStop = $false
            for ($i = 0; $i -lt $elements.Count; $i++)
            {
                $el = $elements[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -like 'ErrorA*')
                {
                    $valueText = if ($el.Argument) { $el.Argument.Extent.Text } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1].Extent.Text } else { '' }
                    if ($valueText -match "^'?Stop'?$")
                    {
                        $hasErrorActionStop = $true
                    }
                }
            }
            if (-not $hasErrorActionStop) { continue }

            $hasEnableException = $command.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'EnableException'
            }
            if (-not $hasEnableException)
            {
                $offenders += "$name (Zeile $($command.Extent.StartLineNumber))"
            }
        }

        # 2) Gesplattete Aufrufe (@restoreParams, @backupParams) - dort steckt ErrorAction/EnableException
        # in der Hashtable-Definition, nicht am Aufruf selbst.
        $hashAssignments = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Right.Extent.Text -match '^@\{' }, $true)
        foreach ($assign in $hashAssignments)
        {
            $text = $assign.Extent.Text
            if ($text -notmatch "ErrorAction\s*=\s*'Stop'") { continue }
            if ($text -notmatch 'EnableException\s*=\s*\$true')
            {
                $offenders += "Splat-Hashtable ohne EnableException (Zeile $($assign.Extent.StartLineNumber))"
            }
        }

        ($offenders -join ', ') | Should -BeNullOrEmpty
    }

    It 'prueft nach Restore-DbaDatabase zusaetzlich das Rueckgabeobjekt, statt sich allein auf "keine Exception" zu verlassen' {
        # Regression 1.9.35.0: Defense in depth zusaetzlich zu -EnableException.
        $source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1" -Raw
        $source | Should -Match '\$restoreResult\s*=\s*Restore-DbaDatabase'
        $source | Should -Match 'if\s*\(-not \$restoreResult\)'
    }

    It 'loescht die Datenbank auf dem Secondary auch dann, wenn sie dort nicht IsAccessible ist' {
        # Regression 1.9.43.0: Nach Remove-DbaAgDatabase liegt die verbliebene Kopie auf dem
        # Secondary typischerweise im Status RESTORING - IsAccessible ist dann $false, obwohl die
        # Datenbank existiert. Die alte Bedingung "$db -and $db.IsAccessible" wertete das
        # faelschlich als "nicht vorhanden" und liess den Drop komplett aus. Beim naechsten
        # Add-DbaAgDatabase/Automatic-Seeding schlug das dann mit "Database With Name Already
        # Exists" fehl, ohne dass RemoveFromSecondary je als fehlgeschlagen auftauchte.
        $source = Get-Content "$PSScriptRoot\..\..\..\Public\Invoke-sqmRestoreDatabase.ps1" -Raw
        $source | Should -Not -Match '\$secondaryServer\.Databases\[\$finalDbName\]\s*-and\s*\$secondaryServer\.Databases\[\$finalDbName\]\.IsAccessible'
        $source | Should -Match 'if\s*\(\$secondaryServer\.Databases\[\$finalDbName\]\)'
    }
}
