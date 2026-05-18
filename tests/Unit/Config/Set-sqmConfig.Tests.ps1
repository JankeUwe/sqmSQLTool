#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Set-sqmConfig
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
    # Testpfad vorbereiten
    $script:TestDir = New-TempTestDirectory
    $script:ConfigFile = Join-Path $env:APPDATA 'MSSQLTools\config.json'
    # Backup bestehender Konfiguration
    $script:ConfigBackup = if (Test-Path $script:ConfigFile) {
        Get-Content $script:ConfigFile -Raw
    } else { $null }
}

AfterAll {
    # Konfiguration wiederherstellen
    if ($script:ConfigBackup) {
        Set-Content $script:ConfigFile -Value $script:ConfigBackup -Encoding UTF8
    } elseif (Test-Path $script:ConfigFile) {
        Remove-Item $script:ConfigFile -Force
    }
    # Testverzeichnis aufraumen
    if (Test-Path $script:TestDir) { Remove-Item $script:TestDir -Recurse -Force }
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Set-sqmConfig' {

    Context 'OutputPath setzen' {
        It 'Setzt OutputPath auf ein existierendes Verzeichnis' {
            { Set-sqmConfig -OutputPath $script:TestDir } | Should -Not -Throw
            Get-sqmConfig -Key 'OutputPath' | Should -Be $script:TestDir
        }

        It 'Wirft Fehler bei nicht erstellbarem Pfad' {
            { Set-sqmConfig -OutputPath 'Z:\GibtEsNicht\Pfad\Test' -ErrorAction Stop } |
                Should -Throw
        }
    }

    Context 'LogPath setzen' {
        It 'Setzt LogPath auf ein existierendes Verzeichnis' {
            { Set-sqmConfig -LogPath $script:TestDir } | Should -Not -Throw
            Get-sqmConfig -Key 'LogPath' | Should -Be $script:TestDir
        }
    }

    Context 'Ola Job-Namen setzen' {
        It 'Setzt OlaJobNameFull' {
            Set-sqmConfig -OlaJobNameFull 'MyOrg-UserDatabases-FULL'
            Get-sqmConfig -Key 'OlaJobNameFull' | Should -Be 'MyOrg-UserDatabases-FULL'
        }

        It 'Setzt OlaJobNameDiff' {
            Set-sqmConfig -OlaJobNameDiff 'MyOrg-UserDatabases-DIFF'
            Get-sqmConfig -Key 'OlaJobNameDiff' | Should -Be 'MyOrg-UserDatabases-DIFF'
        }

        It 'Setzt OlaJobNameLog' {
            Set-sqmConfig -OlaJobNameLog 'MyOrg-UserDatabases-LOG'
            Get-sqmConfig -Key 'OlaJobNameLog' | Should -Be 'MyOrg-UserDatabases-LOG'
        }
    }

    Context 'Persistenz' {
        It 'Schreibt Konfiguration in JSON-Datei' {
            Set-sqmConfig -OutputPath $script:TestDir
            $script:ConfigFile | Should -Exist
        }

        It 'JSON-Datei enthaelt gesetzten Wert' {
            Set-sqmConfig -OutputPath $script:TestDir
            $json = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
            $json.OutputPath | Should -Be $script:TestDir
        }
    }
}
