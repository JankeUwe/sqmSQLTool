#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Konfigurationspruefungen und zwei kleine Hilfsfunktionen:
    Test-sqmMaxDop, Test-sqmMaxMemory, Test-sqmCostThreshold, Test-sqmTempDbFileCount,
    New-sqmRandomSaPassword, Get-sqmSupportedCollations.
    dbatools, SMO und WMI werden gemockt; getestet wird die Auswertung (Schwellen, Status, Fehlerpfad).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    # Get-WmiObject gibt es in PowerShell 7 nicht; fuer den Mock braucht es ein Kommando im Modul.
    InModuleScope sqmSQLTool {
        if (-not (Get-Command Get-WmiObject -ErrorAction SilentlyContinue))
        {
            ${function:script:Get-WmiObject} = { param($Class, $ComputerName, $ErrorAction) }
        }
    }
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    if ($script:TestDir -and (Test-Path $script:TestDir)) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Test-sqmMaxDop' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
    }

    It 'OK wenn MAXDOP = min(8, CPUs)' {
        Mock -ModuleName sqmSQLTool Get-WmiObject { [pscustomobject]@{ NumberOfLogicalProcessors = 16 } }
        Mock -ModuleName sqmSQLTool Get-DbaSpConfigure { [pscustomobject]@{ RunningValue = 8 } }
        $r = Test-sqmMaxDop -SqlInstance 'SQL01'
        $r.Status | Should -Be 'OK'
        $r.RecommendedDop | Should -Be 8
    }

    It 'bei weniger als 8 CPUs ist die CPU-Zahl die Empfehlung' {
        Mock -ModuleName sqmSQLTool Get-WmiObject { [pscustomobject]@{ NumberOfLogicalProcessors = 4 } }
        Mock -ModuleName sqmSQLTool Get-DbaSpConfigure { [pscustomobject]@{ RunningValue = 4 } }
        (Test-sqmMaxDop -SqlInstance 'SQL01').Status | Should -Be 'OK'
    }

    It 'Unconfigured bei MAXDOP 0' {
        Mock -ModuleName sqmSQLTool Get-WmiObject { [pscustomobject]@{ NumberOfLogicalProcessors = 8 } }
        Mock -ModuleName sqmSQLTool Get-DbaSpConfigure { [pscustomobject]@{ RunningValue = 0 } }
        (Test-sqmMaxDop -SqlInstance 'SQL01').Status | Should -Be 'Unconfigured'
    }

    It 'Suboptimal und Richtung der Abweichung' {
        Mock -ModuleName sqmSQLTool Get-WmiObject { [pscustomobject]@{ NumberOfLogicalProcessors = 16 } }
        Mock -ModuleName sqmSQLTool Get-DbaSpConfigure { [pscustomobject]@{ RunningValue = 2 } }
        $low = Test-sqmMaxDop -SqlInstance 'SQL01'
        $low.Status | Should -Be 'Suboptimal'
        $low.Message | Should -Match 'zu niedrig'

        Mock -ModuleName sqmSQLTool Get-DbaSpConfigure { [pscustomobject]@{ RunningValue = 16 } }
        (Test-sqmMaxDop -SqlInstance 'SQL01').Message | Should -Match 'zu hoch'
    }

    It 'Status Error, wenn dbatools fehlschlaegt' {
        Mock -ModuleName sqmSQLTool Get-WmiObject { [pscustomobject]@{ NumberOfLogicalProcessors = 8 } }
        Mock -ModuleName sqmSQLTool Get-DbaSpConfigure { throw 'Verbindung verweigert' }
        $r = Test-sqmMaxDop -SqlInstance 'SQL01' -ErrorAction SilentlyContinue
        $r.Status | Should -Be 'Error'
        $r.Message | Should -Match 'Verbindung verweigert'
    }
}

Describe 'Test-sqmMaxMemory' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        # 64 GB RAM, eine Instanz: Empfehlung 90 % = 58982 MB, Toleranz 85-95 % = 55706 - 62259 MB
        Mock -ModuleName sqmSQLTool Get-WmiObject { [pscustomobject]@{ TotalPhysicalMemory = [int64]64GB } }
    }

    It '<Name>: <Value> MB ergibt Status <Expected>' -ForEach @(
        @{ Name = 'Default-Wert';  Value = 2147483647; Expected = 'Unconfigured' }
        @{ Name = 'zu hoch';       Value = 65536;      Expected = 'TooHigh' }
        @{ Name = 'zu niedrig';    Value = 32768;      Expected = 'TooLow' }
        @{ Name = 'Empfehlung';    Value = 58982;      Expected = 'OK' }
        @{ Name = 'untere Grenze'; Value = 55706;      Expected = 'OK' }
        @{ Name = 'obere Grenze';  Value = 62259;      Expected = 'OK' }
    ) {
        Mock -ModuleName sqmSQLTool Get-DbaMaxMemory { [pscustomobject]@{ MaxValue = $Value } } -ParameterFilter { $true }
        $r = Test-sqmMaxMemory -SqlInstance 'SQL01' -InstanceCount 1
        $r.Status | Should -Be $Expected
        $r.RecommendedMB | Should -Be 58982
    }

    It 'teilt das Budget auf mehrere Instanzen auf' {
        Mock -ModuleName sqmSQLTool Get-DbaMaxMemory { [pscustomobject]@{ MaxValue = 29491 } }
        $r = Test-sqmMaxMemory -SqlInstance 'SQL01' -InstanceCount 2
        $r.RecommendedMB | Should -Be 29491
        $r.Status | Should -Be 'OK'
    }

    It 'ermittelt die Instanzzahl selbst, wenn sie nicht angegeben ist' {
        Mock -ModuleName sqmSQLTool Get-sqmHostEngineInstanceCount { 2 }
        Mock -ModuleName sqmSQLTool Get-DbaMaxMemory { [pscustomobject]@{ MaxValue = 29491 } }
        $r = Test-sqmMaxMemory -SqlInstance 'SQL01'
        $r.InstanceCount | Should -Be 2
        Should -Invoke -ModuleName sqmSQLTool Get-sqmHostEngineInstanceCount -Times 1 -Exactly
    }

    It 'lehnt RecommendedPct ausserhalb 70-99 ab' {
        { Test-sqmMaxMemory -SqlInstance 'SQL01' -RecommendedPct 50 -InstanceCount 1 } | Should -Throw
    }
}

Describe 'Test-sqmCostThreshold' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { $null }
        Mock -ModuleName sqmSQLTool Write-Host { }
    }

    It '<Value> bei Minimum <Min> ergibt <Expected>' -ForEach @(
        @{ Value = 5;  Min = 50; Expected = 'Warning' }
        @{ Value = 50; Min = 50; Expected = 'OK' }
        @{ Value = 80; Min = 50; Expected = 'OK' }
        @{ Value = 25; Min = 20; Expected = 'OK' }
    ) {
        $fake = [pscustomobject]@{ Configuration = [pscustomobject]@{ CostThresholdForParallelism = [pscustomobject]@{ RunValue = $Value } } }
        Mock -ModuleName sqmSQLTool New-Object { $fake } -ParameterFilter { $TypeName -like '*Smo.Server' }
        $r = Test-sqmCostThreshold -SqlInstance 'SQL01' -MinRecommendedValue $Min
        $r.Status | Should -Be $Expected
        $r.CurrentValue | Should -Be $Value
    }

    It 'nimmt das Minimum aus der Modulkonfiguration, wenn kein Parameter gesetzt ist' {
        Mock -ModuleName sqmSQLTool Get-sqmConfig { 30 } -ParameterFilter { $Key -eq 'CheckCostThresholdMin' }
        $fake = [pscustomobject]@{ Configuration = [pscustomobject]@{ CostThresholdForParallelism = [pscustomobject]@{ RunValue = 35 } } }
        Mock -ModuleName sqmSQLTool New-Object { $fake } -ParameterFilter { $TypeName -like '*Smo.Server' }
        $r = Test-sqmCostThreshold -SqlInstance 'SQL01'
        $r.RecommendedMinValue | Should -Be 30
        $r.Status | Should -Be 'OK'
    }

    It 'liefert Status Error bzw. wirft mit -EnableException' {
        Mock -ModuleName sqmSQLTool New-Object { throw 'kein Zugriff' } -ParameterFilter { $TypeName -like '*Smo.Server' }
        (Test-sqmCostThreshold -SqlInstance 'SQL01' -ErrorAction SilentlyContinue).Status | Should -Be 'Error'
        { Test-sqmCostThreshold -SqlInstance 'SQL01' -EnableException } | Should -Throw '*kein Zugriff*'
    }
}

Describe 'Test-sqmTempDbFileCount' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Get-sqmConfig { $null }
        Mock -ModuleName sqmSQLTool Write-Host { }
    }

    BeforeAll {
        function script:New-FakeSmoServer {
            param([int]$Cores, [int]$DataFiles)
            $files = 1..$DataFiles | ForEach-Object { [pscustomobject]@{ UsedSpace = 1024 } }
            [pscustomobject]@{
                Processors = @(1..$Cores | ForEach-Object { [pscustomobject]@{} })
                Databases  = @{ tempdb = [pscustomobject]@{ FileGroups = @([pscustomobject]@{ Files = $files }) } }
            }
        }
    }

    It '<Files> Dateien bei <Cores> Kernen (max <Max>) ergibt <Expected>' -ForEach @(
        @{ Cores = 4;  Files = 4; Max = 8; Expected = 'OK' }
        @{ Cores = 16; Files = 8; Max = 8; Expected = 'OK' }
        @{ Cores = 16; Files = 4; Max = 8; Expected = 'Warning' }
        @{ Cores = 2;  Files = 8; Max = 8; Expected = 'Warning' }
        @{ Cores = 16; Files = 12; Max = 12; Expected = 'OK' }
    ) {
        $fake = New-FakeSmoServer -Cores $Cores -DataFiles $Files
        Mock -ModuleName sqmSQLTool New-Object { $fake } -ParameterFilter { $TypeName -like '*Smo.Server' }
        $r = Test-sqmTempDbFileCount -SqlInstance 'SQL01' -MaxFiles $Max
        $r.Status | Should -Be $Expected
        $r.CurrentFileCount | Should -Be $Files
        $r.RecommendedCount | Should -Be ([Math]::Min($Cores, $Max))
    }

    It 'liefert Status Error bei SMO-Fehler' {
        Mock -ModuleName sqmSQLTool New-Object { throw 'Server nicht erreichbar' } -ParameterFilter { $TypeName -like '*Smo.Server' }
        (Test-sqmTempDbFileCount -SqlInstance 'SQL01' -ErrorAction SilentlyContinue).Status | Should -Be 'Error'
    }
}

Describe 'New-sqmRandomSaPassword' {
    BeforeEach { Mock -ModuleName sqmSQLTool Invoke-sqmLogging { } }

    BeforeAll {
        function script:ConvertTo-PlainText([securestring]$s)
        {
            [System.Net.NetworkCredential]::new('', $s).Password
        }
    }

    It 'liefert ein SecureString der geforderten Laenge' {
        $pw = New-sqmRandomSaPassword -Length 24
        $pw | Should -BeOfType [securestring]
        (ConvertTo-PlainText $pw).Length | Should -Be 24
    }

    It 'enthaelt in jedem von 15 Durchlaeufen alle vier Zeichenklassen' {
        1..15 | ForEach-Object {
            $p = ConvertTo-PlainText (New-sqmRandomSaPassword -Length 12)
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -MatchExactly '[a-z]'
            $p | Should -MatchExactly '[0-9]'
            $p | Should -MatchExactly '[^A-Za-z0-9]'
        }
    }

    It 'nutzt keine verwechselbaren Zeichen (I O l i o 0 1)' {
        1..15 | ForEach-Object {
            ConvertTo-PlainText (New-sqmRandomSaPassword -Length 40) | Should -Not -MatchExactly '[IOlio01]'
        }
    }

    It 'erzeugt unterschiedliche Passwoerter' {
        $set = 1..20 | ForEach-Object { ConvertTo-PlainText (New-sqmRandomSaPassword) }
        ($set | Select-Object -Unique).Count | Should -Be 20
    }

    It 'lehnt Laengen unter 12 ab' {
        { New-sqmRandomSaPassword -Length 8 } | Should -Throw
    }

    It '-ExportPath legt auch fehlende Ordner an und schreibt keinen Klartext' {
        $path = Join-Path $script:TestDir 'neu\ordner\sa.pwd'
        $pw = New-sqmRandomSaPassword -ExportPath $path
        Test-Path $path | Should -BeTrue
        (Get-Content $path -Raw) | Should -Not -Match ([regex]::Escape((ConvertTo-PlainText $pw)))
    }
}

Describe 'Get-sqmSupportedCollations' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            @(
                [pscustomobject]@{ name = 'Latin1_General_CI_AS'; description = 'Latin1-General, case-insensitive' }
                [pscustomobject]@{ name = 'Latin1_General_BIN2';  description = 'Latin1-General, binary code point' }
                [pscustomobject]@{ name = 'SQL_Latin1_General_CP1_CI_AS'; description = 'Latin1-General, SQL' }
            )
        }
    }

    It 'liefert alle Collations ohne Filter' {
        @(Get-sqmSupportedCollations -SqlInstance 'SQL01').Count | Should -Be 3
    }

    It 'filtert per Wildcard' {
        $r = @(Get-sqmSupportedCollations -SqlInstance 'SQL01' -Filter 'Latin1_General_*')
        $r.Count | Should -Be 2
        $r.Name | Should -Not -Contain 'SQL_Latin1_General_CP1_CI_AS'
        $r[0].SqlInstance | Should -Be 'SQL01'
    }

    It 'fragt mit -EnableException ab und reicht Fehler weiter' {
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery { throw 'Login failed' }
        { Get-sqmSupportedCollations -SqlInstance 'SQL01' -EnableException } | Should -Throw '*Login failed*'
    }
}
