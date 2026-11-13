#Requires -Modules Pester
<#
.SYNOPSIS
    Tests fuer Get-sqmProviderInventory (HTML-Erzeugung und Viewer-Vorlage).
.DESCRIPTION
    Der Scan selbst braucht eine echte SQL-Instanz und ist nur manuell getestet. Hier wird geprueft,
    was ohne Instanz pruefbar ist: Parametervertrag, Einsetzen der Scan-Daten in die Vorlage
    (inklusive Schutz vor </script> im Datenblock) und die Syntax des eingebetteten JavaScripts.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Get-sqmProviderInventory' {
    It 'ist exportiert und hat die erwarteten Parameter' {
        $c = Get-Command Get-sqmProviderInventory
        foreach ($p in 'SqlInstance', 'SqlCredential', 'OutputPath', 'Application', 'ParentGroup', 'IncludeAgentJobs', 'SkipSecurity', 'SaveJson', 'NoOpen') {
            $c.Parameters.Keys | Should -Contain $p
        }
        $c.Parameters['SqlCredential'].ParameterType.Name | Should -Be 'PSCredential'
    }
}

Describe 'ConvertTo-sqmProviderInventoryHtml' {
    BeforeAll {
        $script:Json = '{"schema_version":"1.0","scan_started":"2026-11-13T08:00:00","host":{"computer_name":"TESTHOST1"},"instances":[]}'
        $script:Html = InModuleScope sqmSQLTool -Parameters @{ J = $script:Json } { param ($J) ConvertTo-sqmProviderInventoryHtml -ScanJson @($J) }
    }

    It 'laesst keinen Platzhalter stehen' {
        $script:Html | Should -Not -Match '@@[A-Z]+@@'
    }

    It 'bettet die Scan-Daten als lesbares JSON ein' {
        $m = [regex]::Match($script:Html, '<script type="application/json" id="scan-data">(.*?)</script>', 'Singleline')
        $m.Success | Should -BeTrue
        $scans = @($m.Groups[1].Value | ConvertFrom-Json)
        $scans.Count | Should -BeGreaterThan 0
        $scans[0].host.computer_name | Should -Not -BeNullOrEmpty
    }

    It 'schuetzt den Datenblock vor einem Script-Ende-Tag in Scan-Werten' {
        $evil = '{"host":{"computer_name":"X"},"note":"</script><script>alert(1)</script>","instances":[]}'
        $h = InModuleScope sqmSQLTool -Parameters @{ J = $evil } { param ($J) ConvertTo-sqmProviderInventoryHtml -ScanJson @($J) }
        ([regex]::Matches($h, '</script>')).Count | Should -Be 3
        $m = [regex]::Match($h, '<script type="application/json" id="scan-data">(.*?)</script>', 'Singleline')
        (@($m.Groups[1].Value | ConvertFrom-Json))[0].note | Should -Be '</script><script>alert(1)</script>'
    }

    It 'fasst mehrere Scans zu einem Array zusammen' {
        $two = InModuleScope sqmSQLTool -Parameters @{ J = $script:Json } { param ($J) ConvertTo-sqmProviderInventoryHtml -ScanJson @($J, $J) }
        $m = [regex]::Match($two, '<script type="application/json" id="scan-data">(.*?)</script>', 'Singleline')
        @($m.Groups[1].Value | ConvertFrom-Json).Count | Should -Be 2
    }

    # Nur wenn node vorhanden ist (sonst wuerde der Test als uebersprungen zaehlen)
    if (Get-Command node -ErrorAction SilentlyContinue) { It 'hat ein syntaktisch gueltiges JavaScript' {
        $blocks = [regex]::Matches($script:Html, '<script>(.*?)</script>', 'Singleline')
        $blocks.Count | Should -Be 1
        $js = Join-Path ([System.IO.Path]::GetTempPath()) ("pi_{0}.js" -f [guid]::NewGuid().ToString('N'))
        try
        {
            [System.IO.File]::WriteAllText($js, $blocks[0].Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))
            $out = & node --check $js 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
        }
        finally { Remove-Item -LiteralPath $js -Force -ErrorAction SilentlyContinue }
    }
    }
}
