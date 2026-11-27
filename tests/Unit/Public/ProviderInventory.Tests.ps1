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

    It 'hat -AllReplicas als bool mit Standard $true' {
        $p = (Get-Command Get-sqmProviderInventory).Parameters['AllReplicas']
        $p.ParameterType.Name | Should -Be 'Boolean'
        $ast = (Get-Command Get-sqmProviderInventory).ScriptBlock.Ast
        $def = $ast.FindAll({ param ($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'AllReplicas' }, $true) | Select-Object -First 1
        $def.DefaultValue.Extent.Text | Should -Be '$true'
    }

    It 'schreibt bei Fehler (Instanz nicht erreichbar) keine HTML- und keine JSON-Datei' {
        Mock -ModuleName sqmSQLTool Invoke-sqmOpenReport { }
        $out = Join-Path $TestDrive 'pi-error'
        # Port 1 auf localhost: Verbindung wird sofort abgelehnt, kein Timeout
        $r = Get-sqmProviderInventory -SqlInstance '127.0.0.1,1' -OutputPath $out -NoOpen -SaveJson -SampleSeconds 0 `
            -ErrorVariable ev -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        $r.HtmlFile | Should -BeNullOrEmpty
        $r.JsonFile | Should -BeNullOrEmpty
        $r.ErrorCount | Should -BeGreaterThan 0
        @(Get-ChildItem -Path $out -ErrorAction SilentlyContinue).Count | Should -Be 0
        ($ev | Where-Object { "$_" -like '*No HTML file written*' }) | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName sqmSQLTool Invoke-sqmOpenReport -Times 0 -Exactly
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

Describe 'Get-sqmProviderInventoryHostInstance' {
    BeforeAll {
        $script:svc = @(
            [pscustomobject]@{ Name = 'MSSQLSERVER'; State = 'Running' },
            [pscustomobject]@{ Name = 'MSSQL$INST1'; State = 'Running' },
            [pscustomobject]@{ Name = 'MSSQL$OLD'; State = 'Stopped' },
            [pscustomobject]@{ Name = 'SQLAgent$INST1'; State = 'Running' },
            [pscustomobject]@{ Name = 'Spooler'; State = 'Running' }
        )
    }

    It 'findet alle laufenden Instanzen eines Remote-Hosts und ueberspringt gestoppte' {
        InModuleScope sqmSQLTool -Parameters @{ svc = $script:svc } {
            param($svc)
            Mock New-CimSessionOption { 'opt' } -RemoveParameterType 'Protocol'
            Mock New-CimSession { 'sess' } -RemoveParameterType 'SessionOption'
            Mock Remove-CimSession { }
            Mock Get-CimInstance { $svc } -RemoveParameterType 'CimSession'
            Mock Write-Warning { }
            $r = Get-sqmProviderInventoryHostInstance -HostName 'REMOTE01'
            @($r).Count | Should -Be 2
            $r.target | Should -Contain 'REMOTE01'
            $r.target | Should -Contain 'REMOTE01\INST1'
            $r.name | Should -Contain 'INST1'
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'OLD' }
        }
    }

    It 'faellt bei WSMan-Fehler auf DCOM zurueck' {
        InModuleScope sqmSQLTool -Parameters @{ svc = $script:svc } {
            param($svc)
            Mock New-CimSessionOption { $Protocol } -RemoveParameterType 'Protocol'
            Mock New-CimSession { if ($SessionOption -eq 'Wsman') { throw 'wsman down' }; 'sess' } -RemoveParameterType 'SessionOption'
            Mock Remove-CimSession { }
            Mock Get-CimInstance { $svc } -RemoveParameterType 'CimSession'
            Mock Write-Warning { }
            $r = Get-sqmProviderInventoryHostInstance -HostName 'REMOTE01'
            @($r).Count | Should -Be 2
            Should -Invoke New-CimSession -Times 2
        }
    }

    It 'liefert $null, wenn der Host per CIM nicht erreichbar ist' {
        InModuleScope sqmSQLTool {
            Mock New-CimSessionOption { 'opt' } -RemoveParameterType 'Protocol'
            Mock New-CimSession { throw 'nicht erreichbar' } -RemoveParameterType 'SessionOption'
            Mock Remove-CimSession { }
            Get-sqmProviderInventoryHostInstance -HostName 'REMOTE01' | Should -BeNullOrEmpty
            Should -Invoke New-CimSession -Times 2
        }
    }

    It 'liefert ein leeres Array, wenn der Host keinen SQL-Dienst hat (Listener)' {
        InModuleScope sqmSQLTool {
            Mock New-CimSessionOption { 'opt' } -RemoveParameterType 'Protocol'
            Mock New-CimSession { 'sess' } -RemoveParameterType 'SessionOption'
            Mock Remove-CimSession { }
            Mock Get-CimInstance { [pscustomobject]@{ Name = 'Spooler'; State = 'Running' } } -RemoveParameterType 'CimSession'
            $r = Get-sqmProviderInventoryHostInstance -HostName 'AGLISTENER'
            $null -ne $r | Should -BeTrue
            @($r).Count | Should -Be 0
        }
    }

    It 'nutzt lokal kein CIM-Session-Objekt und den lokalen Computernamen' {
        InModuleScope sqmSQLTool -Parameters @{ svc = $script:svc } {
            param($svc)
            Mock New-CimSession { throw 'darf nicht aufgerufen werden' }
            Mock Get-CimInstance { $svc } -RemoveParameterType 'CimSession'
            Mock Write-Warning { }
            $r = Get-sqmProviderInventoryHostInstance -HostName 'localhost'
            $r.target | Should -Contain $env:COMPUTERNAME
            $r.target | Should -Contain ($env:COMPUTERNAME + '\INST1')
            Should -Invoke New-CimSession -Times 0
        }
    }
}

Describe 'Get-sqmProviderInventoryReplicaHost' {
    BeforeAll {
        function New-TestInstance
        {
            param ([object[]]$Replicas)
            [pscustomobject]@{ connected = $true; high_availability = [pscustomobject]@{ is_hadr_enabled = $true; availability_replicas = $Replicas } }
        }
        function New-TestReplica { param ([string]$Name, $IsLocal) [pscustomobject]@{ ag_name = 'ag1'; replica_server_name = $Name; is_local = $IsLocal } }
    }

    It 'liefert die Partner-Hosts ohne das lokale Replikat' {
        $i = New-TestInstance @((New-TestReplica 'SQL01' $true), (New-TestReplica 'SQL02' $false), (New-TestReplica 'SQL03\INST1' $false))
        $r = @(InModuleScope sqmSQLTool -Parameters @{ I = $i } { param ($I) Get-sqmProviderInventoryReplicaHost -Instance @($I) -ExcludeHost 'SQL01' })
        $r.Count | Should -Be 2
        $r[0].host | Should -Be 'SQL02'
        $r[1].host | Should -Be 'SQL03'
        $r[1].replicas | Should -Be @('SQL03\INST1')
    }

    It 'ueberspringt bereits gescannte Hosts ohne Domain-Suffix und Gross-/Kleinschreibung' {
        $i = New-TestInstance @((New-TestReplica 'sql02.corp.local' $false), (New-TestReplica 'SQL04' $false))
        $r = @(InModuleScope sqmSQLTool -Parameters @{ I = $i } { param ($I) Get-sqmProviderInventoryReplicaHost -Instance @($I) -ExcludeHost 'SQL02' })
        $r.Count | Should -Be 1
        $r[0].host | Should -Be 'SQL04'
    }

    It 'fasst mehrere AGs und Instanzen je Host zusammen' {
        $a = New-TestInstance @((New-TestReplica 'SQL02\A' $false), (New-TestReplica 'SQL02\A' $false))
        $b = New-TestInstance @((New-TestReplica 'SQL02\B' $false))
        $r = @(InModuleScope sqmSQLTool -Parameters @{ A = $a; B = $b } { param ($A, $B) Get-sqmProviderInventoryReplicaHost -Instance @($A, $B) })
        $r.Count | Should -Be 1
        $r[0].replicas | Should -Be @('SQL02\A', 'SQL02\B')
    }

    It 'liefert nichts ohne AlwaysOn oder ohne Replikate' {
        $noHa = [pscustomobject]@{ connected = $true; high_availability = [pscustomobject]@{ is_hadr_enabled = $false } }
        $r = @(InModuleScope sqmSQLTool -Parameters @{ I = $noHa } { param ($I) Get-sqmProviderInventoryReplicaHost -Instance @($I, $null) })
        $r.Count | Should -Be 0
    }
}
