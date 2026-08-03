#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer den Registry-Pfad von Invoke-sqmMonitoringKey.

.DESCRIPTION
    Hintergrund: die Quelldatei ist zwischenzeitlich auf den Pfad
    "HKLM:\<RegistryBase>\dtcSoftware\sqmSQLTool" zurueckgefallen, obwohl die reale
    System-Center-Konvention beim Kunden "HKLM:\SYSTEM\FITS\Systemcenter" ist, mit den Werten
    SQL (0/1/2, kundenabhaengig, manuell) und SQLFreeSpaceVersion (Standard/Cluster,
    per -AutoDetectSQLFreeSpaceVersion erkennbar) direkt unter diesem Schluessel. Die
    gebaute/verteilte Kopie in bin/Public hatte weiterhin den richtigen Pfad - dieser Test haelt
    den korrekten Pfad in der Quelle fest, damit das nicht nochmal auseinanderlaeuft.

    Alle Registry-Zugriffe sind gemockt - es wird nie in die echte HKLM geschrieben oder aus ihr
    gelesen, auch nicht auf einer Entwicklermaschine, auf der der Schluessel bereits real gepflegt
    wird.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmMonitoringKey' {

    It 'schreibt unter HKLM:\RegistryBase\FITS\SystemCenter, nicht dem alten dtcSoftware-sqmSQLTool-Pfad' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }

            $usedPaths = [System.Collections.Generic.List[string]]::new()
            Mock Test-Path { $usedPaths.Add($Path); $false } -ParameterFilter { $Path -like 'HKLM:*' }
            Mock New-Item { [PSCustomObject]@{ } } -ParameterFilter { $Path -like 'HKLM:*' }
            Mock Set-ItemProperty { $usedPaths.Add($Path) } -ParameterFilter { $Path -like 'HKLM:*' }
            Mock Get-ItemProperty { [PSCustomObject]@{ SQL = 2; SQLFreeSpaceVersion = 'Standard'; TSM = $null } } -ParameterFilter { $Path -like 'HKLM:*' }

            Invoke-sqmMonitoringKey -Operation Set -SQL Full -Confirm:$false | Out-Null

            $usedPaths | Should -Not -BeNullOrEmpty
            foreach ($p in $usedPaths) { $p | Should -Be 'HKLM:\System\FITS\SystemCenter' }
            $usedPaths | Should -Not -Contain 'HKLM:\System\dtcSoftware\sqmSQLTool'
        }
    }

    It 'meldet den vollen Pfad HKLM:\System\FITS\SystemCenter im Ergebnisobjekt (Operation Get, Standard-RegistryBase)' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Test-Path { $false } -ParameterFilter { $Path -like 'HKLM:*' }

            $result = Invoke-sqmMonitoringKey -Operation Get

            $result.RegistryPath | Should -Be 'HKLM:\System\FITS\SystemCenter'
        }
    }
}
