#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer den Registry-Pfad von Invoke-sqmMonitoringKey.

.DESCRIPTION
    Hintergrund: die Quelldatei ist zwischenzeitlich auf den Pfad
    "HKLM:\<RegistryBase>\dtcSoftware\sqmSQLTool" zurueckgefallen, obwohl die reale
    System-Center-Konvention beim Kunden ein fester Schluessel unter HKLM:\SYSTEM ist, mit den
    Werten SQL (0/1/2, kundenabhaengig, manuell) und SQLFreeSpaceVersion (Standard/Cluster,
    per -AutoDetectSQLFreeSpaceVersion erkennbar) direkt unter diesem Schluessel. Der
    Unterschluessel kommt aus der Modulkonfiguration (MonitoringRegistrySubKey, neutraler
    Standard 'sqmSQLTool\SystemCenter', ein Standort-Profil setzt den Kundenpfad) - diese Tests
    halten fest, dass der konfigurierte Pfad verwendet wird und nicht der alte dtcSoftware-Pfad.

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

    It 'schreibt unter dem konfigurierten MonitoringRegistrySubKey, nicht dem alten dtcSoftware-sqmSQLTool-Pfad' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            $saved = $script:sqmModuleConfig['MonitoringRegistrySubKey']
            try {
                $script:sqmModuleConfig['MonitoringRegistrySubKey'] = 'SiteMonitoring\SystemCenter'

                $usedPaths = [System.Collections.Generic.List[string]]::new()
                Mock Test-Path { $usedPaths.Add($Path); $false } -ParameterFilter { $Path -like 'HKLM:*' }
                Mock New-Item { [PSCustomObject]@{ } } -ParameterFilter { $Path -like 'HKLM:*' }
                Mock Set-ItemProperty { $usedPaths.Add($Path) } -ParameterFilter { $Path -like 'HKLM:*' }
                Mock Get-ItemProperty { [PSCustomObject]@{ SQL = 2; SQLFreeSpaceVersion = 'Standard'; TSM = $null } } -ParameterFilter { $Path -like 'HKLM:*' }

                Invoke-sqmMonitoringKey -Operation Set -SQL Full -Confirm:$false | Out-Null

                $usedPaths | Should -Not -BeNullOrEmpty
                foreach ($p in $usedPaths) { $p | Should -Be 'HKLM:\System\SiteMonitoring\SystemCenter' }
                $usedPaths | Should -Not -Contain 'HKLM:\System\dtcSoftware\sqmSQLTool'
            }
            finally { $script:sqmModuleConfig['MonitoringRegistrySubKey'] = $saved }
        }
    }

    It 'nutzt ohne Standort-Profil den neutralen Standard HKLM:\System\sqmSQLTool\SystemCenter (Operation Get)' {
        InModuleScope sqmSQLTool {
            Mock Invoke-sqmLogging { }
            Mock Test-Path { $false } -ParameterFilter { $Path -like 'HKLM:*' }
            $saved = $script:sqmModuleConfig['MonitoringRegistrySubKey']
            try {
                $script:sqmModuleConfig['MonitoringRegistrySubKey'] = 'sqmSQLTool\SystemCenter'

                $result = Invoke-sqmMonitoringKey -Operation Get

                $result.RegistryPath | Should -Be 'HKLM:\System\sqmSQLTool\SystemCenter'
            }
            finally { $script:sqmModuleConfig['MonitoringRegistrySubKey'] = $saved }
        }
    }
}
