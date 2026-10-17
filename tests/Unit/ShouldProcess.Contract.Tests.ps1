#Requires -Modules Pester
<#
.SYNOPSIS
    Vertragstests: zustandsaendernde Funktionen muessen -WhatIf unterstuetzen.
.DESCRIPTION
    Eine Funktion mit Verb Set/Remove/Install/... die nichts ueber ShouldProcess meldet, kann
    nicht per -WhatIf trocken geprobt werden. Der Vertragstest scannt alle Public-Funktionen per AST;
    die Verhaltenstests pruefen fuer Set-sqmTcpPort, Install-sqmOdbcDriver und Uninstall-sqmJdbcDriver,
    dass -WhatIf wirklich nichts veraendert.
#>

BeforeAll {
    . "$PSScriptRoot\..\TestHelpers.ps1"
    Import-sqmTestModule
    $script:publicDir = Join-Path (Get-Module sqmSQLTool).ModuleBase 'Public'
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'ShouldProcess contract' {
    It 'state-changing verbs declare SupportsShouldProcess (except documented ones)' {
        # Aendern keinen Systemzustand: erzeugen nur ein Passwort bzw. eine Berichtsdatei im Zielordner.
        $allowList = @('New-sqmRandomSaPassword', 'New-sqmSetupReport')
        $stateVerbs = 'Set', 'Remove', 'New', 'Add', 'Stop', 'Start', 'Restore', 'Move', 'Install',
                      'Uninstall', 'Enable', 'Disable', 'Grant', 'Revoke', 'Sync', 'Update'
        $missing = foreach ($file in Get-ChildItem $script:publicDir -Filter '*.ps1') {
            $errs = $null; $tok = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tok, [ref]$errs)
            $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                Select-Object -First 1
            if (-not $fn) { continue }
            if (($fn.Name -split '-')[0] -notin $stateVerbs) { continue }
            if ($fn.Name -in $allowList) { continue }
            if ($fn.Extent.Text -notmatch 'SupportsShouldProcess') { $fn.Name }
        }
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'Set-sqmTcpPort -WhatIf' {
    BeforeEach {
        InModuleScope sqmSQLTool {
            Mock Test-Path { $true }
            Mock Get-ItemProperty { [pscustomobject]@{ INST01 = 'MSSQL16.INST01'; TcpPort = '1433' } }
            Mock Set-ItemProperty { }
            Mock Invoke-sqmLogging { }
        }
    }

    It 'meldet WhatIf und schreibt nichts in die Registry' {
        InModuleScope sqmSQLTool {
            $r = Set-sqmTcpPort -SqlInstance 'INST01' -WhatIf
            $r.Status | Should -Be 'WhatIf'
            $r.Port | Should -Be 1443
            Should -Invoke Set-ItemProperty -Times 0 -Exactly
        }
    }

    It 'setzt ohne -WhatIf beide Registry-Werte' {
        InModuleScope sqmSQLTool {
            $r = Set-sqmTcpPort -SqlInstance 'INST01'
            $r.Status | Should -Be 'Changed'
            Should -Invoke Set-ItemProperty -Times 2 -Exactly
        }
    }
}

Describe 'Install-sqmOdbcDriver -WhatIf' {
    It 'startet den Installer nicht' {
        $msi = Join-Path $TestDrive 'msodbcsql.msi'
        Set-Content -Path $msi -Value 'dummy'
        InModuleScope sqmSQLTool -Parameters @{ Msi = $msi } {
            param($Msi)
            Mock Test-sqmDriverInstalled { [pscustomobject]@{ Installed = $false } }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Invoke-sqmLogging { }
            $r = Install-sqmOdbcDriver -SourcePath $Msi -WhatIf
            $r.Status | Should -Be 'WhatIf'
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }
}

Describe 'Uninstall-sqmJdbcDriver -WhatIf' {
    It 'laesst die JAR-Datei liegen' {
        $dir = Join-Path $TestDrive 'jdbc'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $jar = Join-Path $dir 'mssql-jdbc-12.4.0.jre8.jar'
        Set-Content -Path $jar -Value 'dummy'

        # Die Suchpfade sind fest verdrahtet (u.a. C:\jdbc); daher Get-Item/Get-ChildItem auf das Testverzeichnis umbiegen.
        InModuleScope sqmSQLTool -Parameters @{ Dir = $dir; Jar = $jar } {
            param($Dir, $Jar)
            Mock Get-Item { [pscustomobject]@{ FullName = $Dir } }
            Mock Get-ChildItem { [pscustomobject]@{ FullName = $Jar } } -ParameterFilter { $Filter -eq 'mssql-jdbc*.jar' }
            $r = Uninstall-sqmJdbcDriver -WhatIf
            $r.Status | Should -Be 'WhatIf'
        }
        Test-Path $jar | Should -BeTrue
    }
}
