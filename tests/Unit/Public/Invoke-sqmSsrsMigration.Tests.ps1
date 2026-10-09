#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Invoke-sqmSsrsMigration und die SSRS-REST-Helfer.
    Invoke-sqmSsrsRest wird durch einen kleinen Fake-Report-Server ersetzt (Katalog im Speicher,
    Quelle und Ziel getrennt). Getestet wird die Entscheidungslogik: Plan, Abhaengigkeiten,
    Reihenfolge, die Payload-Details, die die echte API verlangt (beim Livetest gegen SSRS 2022
    ermittelt), und dass AssessOnly/WhatIf nichts schreiben.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:TestDir = New-TempTestDirectory

    # Fake-Report-Server. Die Mock-Bodies laufen im Modulkontext, deshalb liegt der Zustand global.
    $global:SsrsFake = $null
    function global:New-SsrsFakeServer
    {
        $src = @{}
        $add = {
            param ($Path, $Type, $Extra)
            $o = [ordered]@{ Id = [guid]::NewGuid().ToString(); Name = ($Path -split '/')[-1]; Path = $Path; Type = $Type; Hidden = $false; Description = ''; ContentType = '' }
            if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
            $src[$Path] = [PSCustomObject]$o
            $src[$Path]
        }
        $null = & $add '/' 'Folder'
        $null = & $add '/Data Sources' 'Folder'
        $null = & $add '/Finanz' 'Folder'
        $null = & $add '/Finanz/Berichte' 'Folder'
        $ds = & $add '/Data Sources/SalesDB' 'DataSource'
        $set = & $add '/Finanz/Kunden' 'DataSet'
        $rep = & $add '/Finanz/Berichte/Umsatz' 'Report'
        $emb = & $add '/Finanz/Berichte/Eingebettet' 'Report'
        $lnk = & $add '/Finanz/Umsatz Link' 'LinkedReport'

        $global:SsrsFake = @{
            Src        = $src
            Dst        = @{ '/' = [PSCustomObject]@{ Id = 'dst-root'; Name = ''; Path = '/'; Type = 'Folder' } }
            Writes     = [System.Collections.Generic.List[object]]::new()
            DsDef      = @{
                $ds.Id = [PSCustomObject]@{
                    Id = $ds.Id; Name = 'SalesDB'; ConnectionString = 'Data Source=SQLOLD;Initial Catalog=Sales'
                    DataSourceType = 'SQL'; CredentialRetrieval = 'store'; IsEnabled = $true; IsConnectionStringOverridden = $true
                    CredentialsInServer = [PSCustomObject]@{ UserName = 'rpt_reader'; Password = $null; UseAsWindowsCredentials = $false; ImpersonateAuthenticatedUser = $false }
                }
            }
            ReportDs   = @{
                $rep.Id = @([PSCustomObject]@{ Name = 'SalesDB'; IsReference = $true; Path = '/Data Sources/SalesDB'; CredentialRetrieval = 'prompt' })
                $emb.Id = @([PSCustomObject]@{
                        Name = 'Embedded'; IsReference = $false; ConnectionString = 'Data Source=SQLOLD;Initial Catalog=master'
                        DataSourceType = 'SQL'; CredentialRetrieval = 'store'; IsConnectionStringOverridden = $false
                        CredentialsInServer = [PSCustomObject]@{ UserName = 'rpt_reader'; Password = $null; UseAsWindowsCredentials = $false; ImpersonateAuthenticatedUser = $false }
                    })
            }
            ReportSets = @{ $rep.Id = @([PSCustomObject]@{ Name = 'Kunden'; Path = '/Finanz/Kunden' }) }
            SetDs      = @{ $set.Id = @([PSCustomObject]@{ Name = 'DataSetDataSource'; IsReference = $true; Path = '/Data Sources/SalesDB' }) }
            Links      = @{ $lnk.Id = '/Finanz/Berichte/Umsatz' }
            Policies   = @{ $src['/Finanz/Berichte'].Id = [PSCustomObject]@{ InheritParentPolicy = $false; Policies = @([PSCustomObject]@{ GroupUserName = 'DOM\Controlling'; Roles = @([PSCustomObject]@{ Name = 'Browser'; Description = '' }) }) } }
            Content    = @{
                $rep.Id = '<Report><DataSources><DataSource Name="SalesDB"><DataSourceReference>/Data Sources/SalesDB</DataSourceReference></DataSource></DataSources><DataSets><DataSet Name="K"><SharedDataSet><SharedDataSetReference>/Finanz/Kunden</SharedDataSetReference></SharedDataSet></DataSet></DataSets></Report>'
                $emb.Id = '<Report><DataSources><DataSource Name="Embedded"><ConnectionProperties><ConnectString>x</ConnectString></ConnectionProperties></DataSource></DataSources></Report>'
                $set.Id = '<SharedDataSet><DataSet><Query><DataSourceReference>/Data Sources/SalesDB</DataSourceReference></Query></DataSet></SharedDataSet>'
            }
            Subs       = @([PSCustomObject]@{ Report = '/Finanz/Berichte/Umsatz'; Description = 'Monatsmail'; Owner = 'DOM\chef'; DeliveryExtension = 'Report Server Email'; IsDataDriven = $false; LastStatus = 'Mail sent' })
        }
    }

    function global:Invoke-SsrsFakeRest
    {
        param ([string]$Uri, [string]$Method = 'GET', $Body, [string]$OutFile)
        if (-not $Method) { $Method = 'GET' }
        $f = $global:SsrsFake
        $isSrc = $Uri -like 'http://src/*'
        $cat = $f.Dst
        if ($isSrc) { $cat = $f.Src }
        $rel = [System.Uri]::UnescapeDataString(($Uri -replace '^http://[^/]+/Reports/api/v2\.0/', ''))
        $notFound = {
            $ex = New-Object System.Exception("HTTP 404 $rel")
            $ex.Data['StatusCode'] = 404
            throw $ex
        }
        $byId = { param ($Id) $cat.Values | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

        if ($Method -ne 'GET')
        {
            $parsed = $Body
            if ($Body -is [string]) { $parsed = $Body | ConvertFrom-Json }
            elseif ($null -ne $Body) { $parsed = ($Body | ConvertTo-Json -Depth 15) | ConvertFrom-Json }
            $f.Writes.Add([PSCustomObject]@{ Side = $(if ($isSrc) { 'Src' } else { 'Dst' }); Method = $Method; Rel = $rel; Body = $parsed })
            if ($Method -eq 'POST')
            {
                $type = 'Folder'
                if ($parsed.'@odata.type') { $type = ([string]$parsed.'@odata.type') -replace '^#Model\.', '' }
                $path = [string]$parsed.Path
                if ($rel -eq 'LinkedReports') { $path = ($path.TrimEnd('/') + '/' + $parsed.Name) }
                $o = [PSCustomObject]@{ Id = [guid]::NewGuid().ToString(); Name = $parsed.Name; Path = $path; Type = $type }
                $cat[$path] = $o
                return $o
            }
            return $null
        }

        if ($rel -eq 'System') { return [PSCustomObject]@{ ProductName = 'Fake SSRS'; ProductVersion = '16.0' } }
        if ($rel -eq 'Subscriptions') { return [PSCustomObject]@{ value = @($f.Subs) } }

        if ($rel -match "^(Folders|CatalogItems)\(Path='(.*)'\)(/CatalogItems)?$")
        {
            $p = $Matches[2].Replace("''", "'")
            if (-not $cat.ContainsKey($p)) { & $notFound }
            if ($Matches[3])
            {
                $prefix = $p.TrimEnd('/') + '/'
                $children = @($cat.Values | Where-Object { $_.Path -ne $p -and $_.Path.StartsWith($prefix) -and $_.Path.Substring($prefix.Length) -notmatch '/' })
                return [PSCustomObject]@{ value = $children }
            }
            return $cat[$p]
        }
        if ($rel -match '^CatalogItems\(([^)]+)\)/Content/\$value$')
        {
            $c = $f.Content[$Matches[1]]
            if ($null -eq $c) { $c = 'binary' }
            [System.IO.File]::WriteAllText($OutFile, $c)
            return
        }
        if ($rel -match '^DataSources\(([^)]+)\)$') { return $f.DsDef[$Matches[1]] }
        if ($rel -match '^Reports\(([^)]+)\)/DataSources$')
        {
            $v = $f.ReportDs[$Matches[1]]
            if ($null -eq $v -and -not $isSrc)
            {
                # Ziel: zuletzt per PUT gesetzte Bindung zurueckgeben
                $put = $f.Writes | Where-Object { $_.Method -eq 'PUT' -and $_.Rel -eq $rel } | Select-Object -Last 1
                if ($put) { $v = @($put.Body) }
            }
            return [PSCustomObject]@{ value = @($v) }
        }
        if ($rel -match '^Reports\(([^)]+)\)/SharedDataSets$') { return [PSCustomObject]@{ value = @($f.ReportSets[$Matches[1]]) } }
        if ($rel -match '^DataSets\(([^)]+)\)/DataSources$') { return [PSCustomObject]@{ value = @($f.SetDs[$Matches[1]]) } }
        if ($rel -match '^LinkedReports\(([^)]+)\)$') { return [PSCustomObject]@{ Link = $f.Links[$Matches[1]] } }
        if ($rel -match '^CatalogItems\(([^)]+)\)/Policies$')
        {
            $pol = $f.Policies[$Matches[1]]
            if ($pol) { return $pol }
            return [PSCustomObject]@{ InheritParentPolicy = $true; Policies = @() }
        }
        throw "Fake: unbekannter Aufruf $Method $rel"
    }

    $script:Base = @{
        SourceReportServer      = 'http://src/Reports'
        DestinationReportServer = 'http://dst/ReportServer'
        SourceFolder            = '/Finanz'
        NoReport                = $true
        Confirm                 = $false
    }
}

AfterAll {
    Remove-Item function:\New-SsrsFakeServer, function:\Invoke-SsrsFakeRest -ErrorAction SilentlyContinue
    $global:SsrsFake = $null
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'ConvertTo-sqmSsrsApiBase' {
    It '<In> -> <Out>' -ForEach @(
        @{ In = 'SRV01'; Out = 'http://SRV01/Reports/api/v2.0' }
        @{ In = 'https://srv:8443'; Out = 'https://srv:8443/Reports/api/v2.0' }
        @{ In = 'http://srv/ReportServer'; Out = 'http://srv/Reports/api/v2.0' }
        @{ In = 'http://srv/ReportServer/'; Out = 'http://srv/Reports/api/v2.0' }
        @{ In = 'http://srv/ReportServer_INST2'; Out = 'http://srv/Reports_INST2/api/v2.0' }
        @{ In = 'http://srv/Reports'; Out = 'http://srv/Reports/api/v2.0' }
        @{ In = 'http://srv/custom/api/v2.0'; Out = 'http://srv/custom/api/v2.0' }
    ) {
        InModuleScope sqmSQLTool -Parameters @{ In = $In } { param ($In) ConvertTo-sqmSsrsApiBase -ReportServer $In } | Should -Be $Out
    }
}

Describe 'ConvertTo-sqmSsrsPathKey' {
    It 'Kodiert Leerzeichen und Umlaute, laesst Schraegstriche stehen, verdoppelt Hochkommas' {
        InModuleScope sqmSQLTool { ConvertTo-sqmSsrsPathKey -Path "/Finanz Ü/O'Neil" } |
            Should -Be "(Path='/Finanz%20%C3%9C/O%27%27Neil')"
    }
}

Describe 'Invoke-sqmSsrsMigration' {

    BeforeEach {
        New-SsrsFakeServer
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        Mock -ModuleName sqmSQLTool Invoke-sqmSsrsRest { Invoke-SsrsFakeRest -Uri $Uri -Method $Method -Body $Body -OutFile $OutFile }
    }

    Context 'Parameter' {
        It '<_> Parameter existiert' -ForEach @(
            'SourceReportServer', 'SourceCredential', 'DestinationReportServer', 'DestinationCredential', 'SourceFolder',
            'DestinationFolder', 'ItemType', 'ConnectionStringMap', 'DataSourceCredential', 'Overwrite', 'OverwriteDataSources',
            'IncludeSecurity', 'SkipDependencies', 'SkipCertificateCheck', 'AssessOnly', 'OutputPath', 'NoOpen', 'NoReport', 'EnableException'
        ) {
            (Get-Command Invoke-sqmSsrsMigration).Parameters.ContainsKey($_) | Should -Be $true
        }

        It 'Unterstuetzt WhatIf/Confirm' {
            (Get-Command Invoke-sqmSsrsMigration).Parameters.ContainsKey('WhatIf') | Should -Be $true
        }

        It 'Lehnt -DestinationFolder bei mehreren Quellordnern ab' {
            $r = Invoke-sqmSsrsMigration @script:Base -SourceFolder '/A', '/B' -DestinationFolder '/X'
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'genau einem'
        }

        It 'Lehnt denselben Server und Ordner ab' {
            $r = Invoke-sqmSsrsMigration @script:Base -DestinationReportServer 'http://src/Reports'
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match 'derselbe Report Server'
        }

        It 'Lehnt ein Ziel innerhalb des Quellordners ab' {
            $r = Invoke-sqmSsrsMigration @script:Base -DestinationReportServer 'http://src/Reports' -DestinationFolder '/Finanz/Kopie'
            $r.Reason | Should -Match 'innerhalb des Quellordners'
        }

        It 'Lehnt einen ConnectionStringMap-Eintrag ohne => ab' {
            $r = Invoke-sqmSsrsMigration @script:Base -ConnectionStringMap 'SQLOLD=SQLNEW'
            $r.Reason | Should -Match "ALT=>NEU"
        }

        It 'Meldet einen fehlenden Quellordner verstaendlich' {
            $r = Invoke-sqmSsrsMigration @script:Base -SourceFolder '/Gibts nicht'
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -Match "existiert auf .* nicht"
        }

        It 'Wirft mit -EnableException' {
            { Invoke-sqmSsrsMigration @script:Base -SourceFolder '/Gibts nicht' -EnableException } | Should -Throw '*existiert*'
        }
    }

    Context 'AssessOnly' {
        It 'Schreibt nichts und plant alle Elemente' {
            $r = Invoke-sqmSsrsMigration @script:Base -AssessOnly
            $r.Status | Should -Be 'Assessed'
            $global:SsrsFake.Writes.Count | Should -Be 0
            @($r.Items | Where-Object Action -eq 'Create').Count | Should -Be 5
        }

        It 'Nimmt die Datenquelle ausserhalb des Ordners als Abhaengigkeit mit' {
            $r = Invoke-sqmSsrsMigration @script:Base -AssessOnly
            $r.Items.SourcePath | Should -Contain '/Data Sources/SalesDB'
            ($r.Steps | Where-Object Step -eq 'Abhaengigkeiten').Status | Should -Be 'Success'
        }

        It 'Laesst Abhaengigkeiten mit -SkipDependencies weg' {
            $r = Invoke-sqmSsrsMigration @script:Base -AssessOnly -SkipDependencies
            $r.Items.SourcePath | Should -Not -Contain '/Data Sources/SalesDB'
        }

        It 'Warnt vor fehlendem gespeichertem Kennwort' {
            $r = Invoke-sqmSsrsMigration @script:Base -AssessOnly
            @($r.Steps | Where-Object { $_.Step -like 'Kennwort:*' }).Count | Should -Be 2
        }

        It 'Keine Kennwortwarnung, wenn -DataSourceCredential passt (auch mit Domaenenpraefix)' {
            $cred = New-Object System.Management.Automation.PSCredential('DOM\rpt_reader', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            $r = Invoke-sqmSsrsMigration @script:Base -AssessOnly -DataSourceCredential $cred
            @($r.Steps | Where-Object { $_.Step -like 'Kennwort:*' }).Count | Should -Be 0
        }

        It 'Listet Abonnements der migrierten Berichte' {
            $r = Invoke-sqmSsrsMigration @script:Base -AssessOnly
            $r.Subscriptions.Count | Should -Be 1
            $r.Subscriptions[0].Report | Should -Be '/Finanz/Berichte/Umsatz'
        }

        It 'Plant Skip fuer vorhandene Elemente und Overwrite mit -Overwrite' {
            $global:SsrsFake.Dst['/Finanz'] = [PSCustomObject]@{ Id = 'd1'; Name = 'Finanz'; Path = '/Finanz'; Type = 'Folder' }
            $global:SsrsFake.Dst['/Finanz/Kunden'] = [PSCustomObject]@{ Id = 'd2'; Name = 'Kunden'; Path = '/Finanz/Kunden'; Type = 'DataSet' }
            (Invoke-sqmSsrsMigration @script:Base -AssessOnly).Items | Where-Object SourcePath -eq '/Finanz/Kunden' | ForEach-Object { $_.Action | Should -Be 'Skip' }
            (Invoke-sqmSsrsMigration @script:Base -AssessOnly -Overwrite).Items | Where-Object SourcePath -eq '/Finanz/Kunden' | ForEach-Object { $_.Action | Should -Be 'Overwrite' }
        }

        It 'Meldet einen Typkonflikt als Blocked' {
            $global:SsrsFake.Dst['/Finanz'] = [PSCustomObject]@{ Id = 'd1'; Name = 'Finanz'; Path = '/Finanz'; Type = 'Folder' }
            $global:SsrsFake.Dst['/Finanz/Kunden'] = [PSCustomObject]@{ Id = 'd2'; Name = 'Kunden'; Path = '/Finanz/Kunden'; Type = 'Report' }
            $r = Invoke-sqmSsrsMigration @script:Base -AssessOnly
            $r.Status | Should -Be 'Blocked'
        }
    }

    Context 'WhatIf' {
        It 'Schreibt nichts' {
            $r = Invoke-sqmSsrsMigration @script:Base -WhatIf
            $r.Status | Should -Be 'WhatIf'
            $global:SsrsFake.Writes.Count | Should -Be 0
        }
    }

    Context 'Migration in einen anderen Ordner' {
        BeforeEach {
            $script:Cred = New-Object System.Management.Automation.PSCredential('rpt_reader', (ConvertTo-SecureString 'Geheim!1' -AsPlainText -Force))
            $script:R = Invoke-sqmSsrsMigration @script:Base -DestinationFolder '/Archiv/Finanz' -DataSourceCredential $script:Cred `
                -ConnectionStringMap 'sqlold=>SQLNEW' -IncludeSecurity -OutputPath $script:TestDir
            $script:W = @($global:SsrsFake.Writes | Where-Object Side -eq 'Dst')
        }

        It 'Laeuft durch; einziger Hinweis ist das nicht migrierte Abonnement' {
            $script:R.Status | Should -Be 'Warning'
            @($script:R.Items | Where-Object { $_.Status -notin @('Success') }).Count | Should -Be 0
            @($script:R.Steps | Where-Object { $_.Status -ne 'Success' }).Step | Should -Be 'Abonnements'
            @($global:SsrsFake.Writes | Where-Object Side -eq 'Src').Count | Should -Be 0
        }

        It 'Legt Ordner vor den Elementen an, Datenquellen vor Berichten' {
            $order = @($script:W | Where-Object Method -eq 'POST' | ForEach-Object { $_.Rel })
            $lastFolder = [array]::LastIndexOf($order, 'Folders')
            $firstItem = [array]::IndexOf($order, 'DataSources')
            $lastFolder | Should -BeLessThan $firstItem
            [array]::IndexOf($order, 'DataSources') | Should -BeLessThan ([array]::IndexOf($order, 'Reports'))
            [array]::IndexOf($order, 'DataSets') | Should -BeLessThan ([array]::IndexOf($order, 'Reports'))
        }

        It 'Legt Zwischenordner des Zielpfads an' {
            $folders = @($script:W | Where-Object Rel -eq 'Folders' | ForEach-Object { $_.Body.Path })
            $folders | Should -Contain '/Archiv'
            $folders | Should -Contain '/Archiv/Finanz'
            $folders | Should -Contain '/Archiv/Finanz/Berichte'
        }

        It 'Datenquelle: IsConnectionStringOverridden, kleingeschriebenes store, Kennwort, Mapping' {
            $ds = ($script:W | Where-Object Rel -eq 'DataSources').Body
            $ds.Path | Should -Be '/Data Sources/SalesDB'
            $ds.IsConnectionStringOverridden | Should -Be $true
            $ds.CredentialRetrieval | Should -BeExactly 'store'
            $ds.ConnectionString | Should -Be 'Data Source=SQLNEW;Initial Catalog=Sales'
            $ds.CredentialsInServer.Password | Should -Be 'Geheim!1'
        }

        It 'Verknuepfter Bericht: /LinkedReports mit Elternordner und umgehaengtem Link' {
            $lr = ($script:W | Where-Object Rel -eq 'LinkedReports').Body
            $lr.Path | Should -Be '/Archiv/Finanz'
            $lr.Link | Should -Be '/Archiv/Finanz/Berichte/Umsatz'
        }

        It 'Schreibt absolute Referenzen im RDL auf den neuen Ordner um, externe bleiben' {
            $rep = $script:W | Where-Object { $_.Rel -eq 'Reports' -and $_.Body.Name -eq 'Umsatz' }
            $xml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rep.Body.Content))
            $xml | Should -Match '<SharedDataSetReference>/Archiv/Finanz/Kunden</SharedDataSetReference>'
            $xml | Should -Match '<DataSourceReference>/Data Sources/SalesDB</DataSourceReference>'
        }

        It 'Setzt die Bindungen aus dem Quellkatalog, eingebettete mit Kennwort und Mapping' {
            $puts = @($script:W | Where-Object { $_.Method -eq 'PUT' -and $_.Rel -match '/DataSources$' })
            $puts.Count | Should -Be 3
            $embPut = $puts | Where-Object { @($_.Body)[0].Name -eq 'Embedded' }
            $e = @($embPut.Body)[0]
            $e.IsReference | Should -Be $false
            $e.ConnectionString | Should -Be 'Data Source=SQLNEW;Initial Catalog=master'
            $e.IsConnectionStringOverridden | Should -Be $true
            $e.CredentialsInServer.Password | Should -Be 'Geheim!1'
        }

        It 'Kopiert die Rechte des Ordners mit eigener Berechtigung' {
            $pol = $script:W | Where-Object { $_.Rel -match '/Policies$' }
            @($pol).Count | Should -Be 1
            $pol.Body.InheritParentPolicy | Should -Be $false
            $pol.Body.Policies[0].GroupUserName | Should -Be 'DOM\Controlling'
        }

        It 'Exportiert den Quellinhalt' {
            Test-Path (Join-Path $script:R.ExportPath 'Source\Finanz\Berichte\Umsatz.rdl') | Should -Be $true
        }
    }

    Context 'Ohne Kennwort' {
        It 'Markiert den Bericht als Warning und laesst die eingebettete Bindung weg' {
            $r = Invoke-sqmSsrsMigration @script:Base -DestinationFolder '/Archiv/Finanz' -OutputPath $script:TestDir
            ($r.Items | Where-Object SourcePath -eq '/Finanz/Berichte/Eingebettet').Status | Should -Be 'Warning'
            $r.Status | Should -Be 'Warning'
            $embPuts = @($global:SsrsFake.Writes | Where-Object { $_.Method -eq 'PUT' -and @($_.Body)[0].Name -eq 'Embedded' })
            $embPuts.Count | Should -Be 0
        }
    }

    Context 'Overwrite' {
        It 'Ueberschreibt per PATCH auf die vorhandene ID und sichert vorher' {
            $global:SsrsFake.Dst['/Finanz'] = [PSCustomObject]@{ Id = 'd1'; Name = 'Finanz'; Path = '/Finanz'; Type = 'Folder' }
            $global:SsrsFake.Dst['/Finanz/Kunden'] = [PSCustomObject]@{ Id = 'dst-set'; Name = 'Kunden'; Path = '/Finanz/Kunden'; Type = 'DataSet' }
            $global:SsrsFake.Content['dst-set'] = '<SharedDataSet>alt</SharedDataSet>'
            $r = Invoke-sqmSsrsMigration @script:Base -Overwrite -SkipDependencies -OutputPath $script:TestDir
            $patch = $global:SsrsFake.Writes | Where-Object { $_.Method -eq 'PATCH' }
            $patch.Rel | Should -Be 'DataSets(dst-set)'
            $patch.Body.PSObject.Properties.Name | Should -Not -Contain 'Path'
            Get-Content (Join-Path $r.ExportPath 'DestinationBackup\Finanz\Kunden.rsd') -Raw | Should -Match 'alt'
        }

        It 'Laesst vorhandene Datenquellen ohne -OverwriteDataSources stehen' {
            $global:SsrsFake.Dst['/Data Sources'] = [PSCustomObject]@{ Id = 'f'; Name = 'Data Sources'; Path = '/Data Sources'; Type = 'Folder' }
            $global:SsrsFake.Dst['/Data Sources/SalesDB'] = [PSCustomObject]@{ Id = 'dst-ds'; Name = 'SalesDB'; Path = '/Data Sources/SalesDB'; Type = 'DataSource' }
            $r = Invoke-sqmSsrsMigration @script:Base -Overwrite -OutputPath $script:TestDir -DestinationReportServer 'http://dst/Reports'
            ($r.Items | Where-Object SourcePath -eq '/Data Sources/SalesDB').Status | Should -Be 'Skipped'
            @($global:SsrsFake.Writes | Where-Object { $_.Rel -like 'DataSources*' }).Count | Should -Be 0
        }
    }
}
