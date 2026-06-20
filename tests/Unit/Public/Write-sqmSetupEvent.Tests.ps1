#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Write-sqmSetupEvent und New-sqmSetupReport (animierter Ablauf-Report).
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory
}

AfterAll {
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Write-sqmSetupEvent' {

    It 'Funktion existiert' {
        Get-Command Write-sqmSetupEvent | Should -Not -BeNullOrEmpty
    }

    It 'Ist ein No-Op ohne -Path (kein Fehler, keine Datei)' {
        { Write-sqmSetupEvent -Phase 'install' -Title 'x' } | Should -Not -Throw
    }

    It 'Schreibt eine gueltige JSON-Zeile je Aufruf' {
        $f = Join-Path $script:TestDir 'a.jsonl'
        Write-sqmSetupEvent -Path $f -Phase 'copy' -Step 'copy-sources' -State 'start' -Title 'Quellen'
        Write-sqmSetupEvent -Path $f -Phase 'copy' -Step 'copy-sources' -State 'done' -Title 'Fertig'
        $lines = Get-Content $f
        $lines.Count | Should -Be 2
        foreach ($l in $lines) { { $l | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw }
        ($lines[0] | ConvertFrom-Json).phase | Should -Be 'copy'
        ($lines[0] | ConvertFrom-Json).state | Should -Be 'start'
    }

    It 'Setzt eine Default-Visualisierung je Phase' {
        $f = Join-Path $script:TestDir 'b.jsonl'
        Write-sqmSetupEvent -Path $f -Phase 'copy' -Title 'x'
        Write-sqmSetupEvent -Path $f -Phase 'preinstall' -Title 'y'
        $ev = Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json }
        $ev[0].viz | Should -Be 'flow-arrows'
        $ev[1].viz | Should -Be 'disk-format'
    }

    It 'Schluckt Fehler (ungueltiger Pfad bricht nicht ab)' {
        { Write-sqmSetupEvent -Path 'Z:\nonexistent\deep\path\evt.jsonl' -Phase 'install' -Title 'x' } | Should -Not -Throw
    }
}

Describe 'New-sqmSetupReport' {

    It 'Funktion existiert' {
        Get-Command New-sqmSetupReport | Should -Not -BeNullOrEmpty
    }

    It 'Gibt $null zurueck wenn die Eventdatei fehlt' {
        New-sqmSetupReport -EventPath (Join-Path $script:TestDir 'missing.jsonl') | Should -BeNullOrEmpty
    }

    It 'Erzeugt eine eigenstaendige HTML-Datei aus Events' {
        $f = Join-Path $script:TestDir 'run.jsonl'
        Write-sqmSetupEvent -Path $f -Phase 'install' -Step 'install' -State 'start' -Title 'Installation'
        Write-sqmSetupEvent -Path $f -Phase 'install' -Step 'install' -State 'done' -Title 'Fertig'
        $out = Join-Path $script:TestDir 'run.html'
        $res = New-sqmSetupReport -EventPath $f -OutputPath $out -Title 'Test' -Server 'SRV'
        $res | Should -Be $out
        Test-Path $out | Should -Be $true
        $html = Get-Content $out -Raw
        $html | Should -Match 'JSON\.parse'
        $html | Should -Match 'Installation'
        # offline: kein externer Resource-Load
        $html | Should -Not -Match 'https?://'
    }

    It 'Filtert kaputte JSON-Zeilen heraus' {
        $f = Join-Path $script:TestDir 'broken.jsonl'
        Write-sqmSetupEvent -Path $f -Phase 'install' -Title 'gut'
        Add-Content -LiteralPath $f -Value '{ kaputt' -Encoding UTF8
        $out = Join-Path $script:TestDir 'broken.html'
        New-sqmSetupReport -EventPath $f -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw
        $html | Should -Not -Match 'kaputt'
        ([regex]::Matches($html, '"phase"')).Count | Should -Be 1
    }
}

Describe 'New-sqmAvailabilityGroup -EventLog' {
    BeforeAll {
        Mock -ModuleName sqmSQLTool Connect-DbaInstance { New-MockSqlInstance -Name 'SQL01' }
        Mock -ModuleName sqmSQLTool Get-WmiObject { $null }
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Start-Sleep { }
        Mock -ModuleName sqmSQLTool Invoke-DbaQuery {
            if ($Query -match 'hadr enabled')            { return [PSCustomObject]@{ value_in_use = 1 } }
            if ($Query -match 'sys.endpoints')           { return [PSCustomObject]@{ name = 'HADR_Endpoint' } }
            if ($Query -match 'sys.availability_groups') { return [PSCustomObject]@{ name = 'TestAG' } }
            return @()
        }
    }

    It 'Schreibt AlwaysOn-Events in die EventLog-Datei' {
        $f = Join-Path $script:TestDir 'ag.jsonl'
        New-sqmAvailabilityGroup -SqlInstance 'SQL01' -SecondaryReplica 'SQL02' `
            -AvailabilityGroupName 'TestAG' -EventLog $f -Confirm:$false | Out-Null
        Test-Path $f | Should -Be $true
        $ev = Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json }
        ($ev | Where-Object { $_.phase -eq 'alwayson' }).Count | Should -BeGreaterThan 0
    }
}
