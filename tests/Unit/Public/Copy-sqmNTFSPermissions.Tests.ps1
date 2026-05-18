#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Copy-sqmNTFSPermissions
    Keine SQL-Abhaengigkeit — vollstaendig ohne Mock testbar.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    # Testverzeichnisse aufbauen
    $script:SrcDir  = New-TempTestDirectory
    $script:DstDir  = New-TempTestDirectory
    $script:SubDir  = New-Item -ItemType Directory -Path (Join-Path $script:SrcDir 'Sub') -Force

    # Testdateien anlegen
    'TestInhalt1' | Set-Content (Join-Path $script:SrcDir 'file1.txt')
    'TestInhalt2' | Set-Content (Join-Path $script:SrcDir 'file2.txt')
    'SubInhalt'   | Set-Content (Join-Path $script:SrcDir 'Sub\sub1.txt')

    # Spiegelstruktur im Ziel anlegen (ACL-Kopie erfordert existierende Zieldateien)
    'TestInhalt1' | Set-Content (Join-Path $script:DstDir 'file1.txt')
    'TestInhalt2' | Set-Content (Join-Path $script:DstDir 'file2.txt')
    New-Item -ItemType Directory -Path (Join-Path $script:DstDir 'Sub') -Force | Out-Null
    'SubInhalt'   | Set-Content (Join-Path $script:DstDir 'Sub\sub1.txt')
}

AfterAll {
    if (Test-Path $script:SrcDir) { Remove-Item $script:SrcDir -Recurse -Force }
    if (Test-Path $script:DstDir) { Remove-Item $script:DstDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Copy-sqmNTFSPermissions' {

    Context 'Parameter-Validierung' {
        It 'Wirft Fehler wenn SourcePath nicht existiert' {
            { Copy-sqmNTFSPermissions -SourcePath 'C:\GibtEsNicht\Pfad' -DestinationPath $script:DstDir -ErrorAction Stop } |
                Should -Throw
        }

        It 'Wirft Fehler wenn DestinationPath nicht existiert und -CreateMissingFolders nicht gesetzt' {
            { Copy-sqmNTFSPermissions -SourcePath $script:SrcDir -DestinationPath 'C:\GibtEsNicht\Ziel' -ErrorAction Stop } |
                Should -Throw
        }

        It 'SourcePath ist Pflichtparameter' {
            $cmd = Get-Command Copy-sqmNTFSPermissions
            $cmd.Parameters['SourcePath'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory | Should -Be $true
        }

        It 'DestinationPath ist Pflichtparameter' {
            $cmd = Get-Command Copy-sqmNTFSPermissions
            $cmd.Parameters['DestinationPath'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory | Should -Be $true
        }
    }

    Context 'WhatIf' {
        It 'Fuehrt keine Aenderungen durch bei -WhatIf' {
            # Ziel-ACL vor dem WhatIf merken
            $aclBefore = (Get-Acl (Join-Path $script:DstDir 'file1.txt')).Sddl
            Copy-sqmNTFSPermissions -SourcePath $script:SrcDir -DestinationPath $script:DstDir -WhatIf
            $aclAfter = (Get-Acl (Join-Path $script:DstDir 'file1.txt')).Sddl
            $aclAfter | Should -Be $aclBefore
        }
    }

    Context 'Einfache ACL-Kopie (nicht rekursiv)' {
        It 'Laeuft ohne Fehler durch' {
            { Copy-sqmNTFSPermissions -SourcePath $script:SrcDir -DestinationPath $script:DstDir } |
                Should -Not -Throw
        }
    }

    Context 'Rekursive ACL-Kopie' {
        It 'Laeuft ohne Fehler durch' {
            { Copy-sqmNTFSPermissions -SourcePath $script:SrcDir -DestinationPath $script:DstDir -Recurse } |
                Should -Not -Throw
        }
    }

    Context 'CreateMissingFolders' {
        It 'Erstellt fehlenden Zielordner automatisch' {
            $newDst = Join-Path $env:TEMP "sqmTest_NewDst_$(Get-Random)"
            try {
                Copy-sqmNTFSPermissions -SourcePath $script:SrcDir -DestinationPath $newDst -CreateMissingFolders
                $newDst | Should -Exist
            } finally {
                if (Test-Path $newDst) { Remove-Item $newDst -Recurse -Force }
            }
        }
    }

    Context 'SupportsShouldProcess' {
        It 'Funktion unterstuetzt ShouldProcess' {
            $cmd = Get-Command Copy-sqmNTFSPermissions
            $cmd.Parameters.ContainsKey('WhatIf') | Should -Be $true
            $cmd.Parameters.ContainsKey('Confirm') | Should -Be $true
        }
    }
}
