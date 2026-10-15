#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Grant-sqmVolumeAccess. Kein Mock - echtes icacls auf einem Ordnerbaum im TestDrive
    (unterbrochene Vererbung, Junction, geschuetzte Datei). Laeuft ohne erhoehte Sitzung, weil der
    Testbenutzer Besitzer der Ordner ist. Der TestDrive liegt auf dem Systemlaufwerk; die Sperre wird
    dafuer ueber $env:SystemDrive umgangen.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    $script:realSystemDrive = $env:SystemDrive

    function script:Get-SidAces
    {
        param ([string]$LiteralPath, [string]$Sid)
        @((Get-Acl -LiteralPath $LiteralPath).Access |
            Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $Sid })
    }

    function script:New-Tree
    {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $tree = Join-Path $root 'Tree'
        New-Item -ItemType Directory "$tree\A\B", "$tree\Prot\Sub\Prot2\Deep", "$root\Outside" -Force | Out-Null
        'x' | Set-Content "$tree\A\B\x.bak"
        'y' | Set-Content "$tree\Prot\Sub\Prot2\Deep\y.mdf"
        'p' | Set-Content "$tree\A\pf.txt"
        & icacls "$tree\Prot" /inheritance:d | Out-Null
        & icacls "$tree\Prot\Sub\Prot2" /inheritance:d | Out-Null
        & icacls "$tree\A\pf.txt" /inheritance:d | Out-Null
        & cmd.exe /c mklink /J "$tree\Junction" "$root\Outside" | Out-Null
        [PSCustomObject]@{ Tree = $tree; Outside = "$root\Outside" }
    }
}

AfterAll {
    $env:SystemDrive = $script:realSystemDrive
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Grant-sqmVolumeAccess' {
    BeforeEach {
        Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
        $env:SystemDrive = 'Z:'
    }
    AfterEach {
        $env:SystemDrive = $script:realSystemDrive
    }

    Context 'Parameter' {
        It 'verlangt -Principal oder -Account' {
            { Grant-sqmVolumeAccess -Path $TestDrive } | Should -Throw '*-Principal oder -Account*'
        }
        It 'bricht bei nicht aufloesbarem Konto ab' {
            { Grant-sqmVolumeAccess -Path $TestDrive -Account 'GIBTS-NICHT\Niemand' } | Should -Throw '*nicht aufloesen*'
        }
        It 'bietet nur die beiden bekannten Gruppen an' {
            (Get-Command Grant-sqmVolumeAccess).Parameters['Principal'].Attributes.ValidValues |
                Should -Be @('AuthenticatedUsers', 'Administrators')
        }
    }

    Context 'Ziele' {
        It 'fasst das Systemlaufwerk nie an' {
            $env:SystemDrive = $script:realSystemDrive
            $r = Grant-sqmVolumeAccess -Path $TestDrive -Principal AuthenticatedUsers -ExcludeDrive @() -Confirm:$false
            $r.Action | Should -Be 'Skipped'
            $r.Message | Should -BeLike '*Systemlaufwerk*'
        }
        It 'ueberspringt ausgeschlossene und fehlende Laufwerke' {
            $r = Grant-sqmVolumeAccess -Path 'S:\', 'Q:\gibts\nicht' -Principal AuthenticatedUsers -Confirm:$false
            $r.Action | Should -Be @('Skipped', 'Skipped')
            $r[0].Message | Should -BeLike '*ausgeschlossen*'
        }
    }

    Context 'Berechtigen' {
        BeforeAll {
            $env:SystemDrive = 'Z:'
            $script:t = New-Tree
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            $script:whatIf = Grant-sqmVolumeAccess -Path $script:t.Tree -Principal AuthenticatedUsers -ExcludeDrive @() -WhatIf
            $script:first = Grant-sqmVolumeAccess -Path $script:t.Tree -Principal AuthenticatedUsers -ExcludeDrive @() -Confirm:$false
            $script:second = Grant-sqmVolumeAccess -Path $script:t.Tree -Principal AuthenticatedUsers -ExcludeDrive @() -Confirm:$false
            $env:SystemDrive = $script:realSystemDrive
        }

        It '-WhatIf meldet Wurzel und beide Ordner mit unterbrochener Vererbung' {
            $script:whatIf.Action | Should -Be @('WhatIf', 'WhatIf', 'WhatIf')
            ($script:whatIf | Where-Object Scope -eq 'ProtectedFolder').Path | Split-Path -Leaf | Sort-Object |
                Should -Be @('Prot', 'Prot2')
        }
        It 'setzt Wurzel und geschuetzte Ordner und liest nach' {
            $script:first.Action | Should -Be @('Granted', 'Granted', 'Granted')
        }
        It 'erreicht alles unterhalb, auch unter verschachtelt geschuetzten Ordnern' {
            foreach ($p in 'A', 'A\B', 'A\B\x.bak', 'Prot', 'Prot\Sub', 'Prot\Sub\Prot2', 'Prot\Sub\Prot2\Deep', 'Prot\Sub\Prot2\Deep\y.mdf')
            {
                (Get-SidAces (Join-Path $script:t.Tree $p) 'S-1-5-11').Count | Should -Be 1 -Because $p
            }
        }
        It 'hinterlaesst auf normalen Unterordnern keine doppelte explizite ACE' {
            $aces = Get-SidAces (Join-Path $script:t.Tree 'A\B') 'S-1-5-11'
            $aces.Count | Should -Be 1
            $aces[0].IsInherited | Should -BeTrue
        }
        It 'folgt keiner Junction' {
            (Get-SidAces $script:t.Outside 'S-1-5-11').Count | Should -Be 0
        }
        It 'laesst geschuetzte Dateien ohne -IncludeFiles aus' {
            (Get-SidAces (Join-Path $script:t.Tree 'A\pf.txt') 'S-1-5-11').Count | Should -Be 0
        }
        It 'aendert beim zweiten Lauf nichts' {
            $script:second.Action | Should -Be @('AlreadyPresent', 'AlreadyPresent', 'AlreadyPresent')
        }
        It 'berechtigt mit -IncludeFiles auch geschuetzte Dateien, mehrere Principals, -Account per SID' {
            $env:SystemDrive = 'Z:'
            $r = Grant-sqmVolumeAccess -Path $script:t.Tree -Principal AuthenticatedUsers -Account 'S-1-5-32-545' -Rights Read -IncludeFiles -ExcludeDrive @() -Confirm:$false
            $file = $r | Where-Object Scope -eq 'ProtectedFile'
            ($file | Where-Object Sid -eq 'S-1-5-32-545').Action | Should -Be 'Granted'
            # RX deckt Read ab
            ($file | Where-Object Sid -eq 'S-1-5-11').Action | Should -Be 'Granted'
            ($r | Where-Object { $_.Scope -eq 'Root' -and $_.Sid -eq 'S-1-5-11' }).Action | Should -Be 'AlreadyPresent'
            (Get-SidAces (Join-Path $script:t.Tree 'A\pf.txt') 'S-1-5-32-545').Count | Should -Be 1
        }
    }

    Context 'Vererbung aus' {
        BeforeAll {
            $env:SystemDrive = 'Z:'
            $script:o = New-Tree
            Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
            $script:off = Grant-sqmVolumeAccess -Path $script:o.Tree -Principal AuthenticatedUsers -Inheritance Off -IncludeFiles -ExcludeDrive @() -Confirm:$false -WarningAction SilentlyContinue
            $env:SystemDrive = $script:realSystemDrive
        }

        It 'setzt nur die Wurzel, sucht keine Unterordner' {
            @($script:off).Count | Should -Be 1
            $script:off.Scope | Should -Be 'Root'
            $script:off.Action | Should -Be 'Granted'
            $script:off.Inheritance | Should -Be 'Off'
        }
        It 'setzt die ACE ohne Vererbungsflags' {
            $aces = Get-SidAces $script:o.Tree 'S-1-5-11'
            $aces.Count | Should -Be 1
            $aces[0].InheritanceFlags | Should -Be ([System.Security.AccessControl.InheritanceFlags]::None)
        }
        It 'aendert nichts unterhalb' {
            foreach ($p in 'A', 'A\B\x.bak', 'Prot', 'Prot\Sub')
            {
                (Get-SidAces (Join-Path $script:o.Tree $p) 'S-1-5-11').Count | Should -Be 0 -Because $p
            }
        }
        It 'zaehlt eine nicht vererbbare ACE bei -Inheritance On nicht als vorhanden' {
            $env:SystemDrive = 'Z:'
            $r = Grant-sqmVolumeAccess -Path $script:o.Tree -Principal AuthenticatedUsers -ExcludeDrive @() -Confirm:$false
            ($r | Where-Object Scope -eq 'Root').Action | Should -Be 'Granted'
            (Get-SidAces (Join-Path $script:o.Tree 'A\B') 'S-1-5-11').Count | Should -Be 1
        }
        It 'meldet AlreadyPresent fuer Off, wenn eine vererbbare ACE schon da ist' {
            $env:SystemDrive = 'Z:'
            $r = Grant-sqmVolumeAccess -Path $script:o.Tree -Principal AuthenticatedUsers -Inheritance Off -ExcludeDrive @() -Confirm:$false
            $r.Action | Should -Be 'AlreadyPresent'
        }
    }

    Context 'Fehler' {
        It 'meldet Failed, wenn icacls trotz Exitcode 0 nicht setzen durfte' {
            $env:SystemDrive = 'Z:'
            $root = Join-Path $TestDrive 'fail'
            New-Item -ItemType Directory "$root\Locked" -Force | Out-Null
            # OWNER RIGHTS nur Lesen: der Besitzer verliert sein implizites WRITE_DAC
            & icacls "$root\Locked" /inheritance:r /grant '*S-1-3-4:(OI)(CI)R' '*S-1-5-32-544:(OI)(CI)R' | Out-Null
            try
            {
                # Probe: greift die Sperre ueberhaupt? Auf dem GitHub-Runner (erhoehter Admin) setzt
                # icacls die ACE trotzdem - dann ist der Fehlerpfad hier nicht herstellbar.
                & icacls "$root\Locked" /grant '*S-1-5-19:R' 2>&1 | Out-Null
                if (Get-SidAces "$root\Locked" 'S-1-5-19')
                {
                    Set-ItResult -Skipped -Because 'ACL-Sperre greift in diesem Kontext nicht (erhoehter Prozess darf WRITE_DAC trotzdem)'
                    return
                }
                $r = Grant-sqmVolumeAccess -Path $root -Principal AuthenticatedUsers -ExcludeDrive @() -Confirm:$false
                ($r | Where-Object Scope -eq 'Root').Action | Should -Be 'Granted'
                $locked = $r | Where-Object Scope -eq 'ProtectedFolder'
                $locked.Action | Should -Be 'Failed'
                $locked.Message | Should -BeLike 'icacls:*'
            }
            finally
            {
                # Leerer Ordner: ueber FILE_DELETE_CHILD des Elternordners loeschbar
                [System.IO.Directory]::Delete("$root\Locked")
            }
        }
    }
}
