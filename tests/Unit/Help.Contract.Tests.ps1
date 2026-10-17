#Requires -Modules Pester
<#
.SYNOPSIS
    Vertragstests fuer alle exportierten Funktionen: Hilfe und Parametertypen.
.DESCRIPTION
    Gilt fuer jede Funktion, auch fuer solche ohne eigene Verhaltenstests:
    - jede Funktion hat einen Synopsis-Text,
    - Parameter, die ein Credential oder Passwort tragen, sind PSCredential bzw. SecureString und
      nie ein String (sonst landen Kennwoerter im Klartext in History und Logs).
    Die Hilfe-Luecken (Description/Beispiel/Parameterbeschreibung) sind in $knownHelpGaps festgehalten:
    der Test schlaegt fehl, sobald eine NEUE Funktion mit solchen Luecken dazukommt, und auch, sobald
    eine Luecke geschlossen wurde und aus der Liste entfernt werden kann.
#>

BeforeDiscovery {
    $env:SQMSQLTOOL_SKIP_AUTO_UPDATE = '1'
    . "$PSScriptRoot\..\TestHelpers.ps1"
    Import-sqmTestModule
    $script:cmds = Get-Command -Module sqmSQLTool -CommandType Function | Sort-Object Name
    $script:cases = $script:cmds | ForEach-Object { @{ Name = $_.Name } }
}

BeforeAll {
    . "$PSScriptRoot\..\TestHelpers.ps1"
    Import-sqmTestModule
    # Stand 1.9.183.0: Funktionen ohne .DESCRIPTION bzw. ohne .EXAMPLE
    $script:knownHelpGaps = @{
        Description = @('Add-sqmDatabaseToAG', 'Get-sqmBlockingReport', 'Get-sqmSaLogin', 'Get-sqmServerHardwareReport',
                        'Get-sqmSpnReport', 'Invoke-sqmSetupReport', 'New-sqmAlwaysOnRepairJob')
        Example     = @('Add-sqmDatabaseToAG', 'Copy-sqmToCentralPath', 'Get-sqmBlockingReport', 'Get-sqmSaLogin',
                        'Get-sqmServerHardwareReport', 'Get-sqmSpnReport', 'Invoke-sqmLogging', 'Invoke-sqmSetupReport',
                        'New-sqmSetupReport', 'Test-sqmOlaInstallation', 'Write-sqmSetupEvent')
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Hilfe und Parametertypen (alle exportierten Funktionen)' {
    It '<Name> hat einen Synopsis-Text' -ForEach $script:cases {
        $h = Get-Help $Name
        $h.Synopsis | Should -Not -BeNullOrEmpty
        $h.Synopsis.Trim() | Should -Not -Be $Name
    }

    It '<Name>: Credential-Parameter sind PSCredential, Passwort-Parameter nie String' -ForEach $script:cases {
        $bad = foreach ($p in (Get-Command $Name).Parameters.Values)
        {
            if ($p.Name -match 'Credential$' -and $p.Name -ne 'CredentialName' -and $p.ParameterType.Name -notmatch 'PSCredential') { "$($p.Name) [$($p.ParameterType.Name)]" }
            if ($p.Name -match 'Password|Passwort|Secret|Token' -and $p.ParameterType.Name -eq 'String') { "$($p.Name) [String]" }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'neue Funktionen haben Description und mindestens ein Beispiel (bekannte Luecken ausgenommen)' {
        $noDesc = foreach ($c in $script:cmds) { if (-not (Get-Help $c.Name).Description -and $c.Name -notin $script:knownHelpGaps.Description) { $c.Name } }
        $noEx   = foreach ($c in $script:cmds) { if (-not (Get-Help $c.Name).examples -and $c.Name -notin $script:knownHelpGaps.Example) { $c.Name } }
        $noDesc | Should -BeNullOrEmpty
        $noEx | Should -BeNullOrEmpty
    }

    It 'die Liste der bekannten Hilfe-Luecken enthaelt nichts, was schon behoben ist' {
        $fixedDesc = $script:knownHelpGaps.Description | Where-Object { (Get-Help $_).Description }
        $fixedEx   = $script:knownHelpGaps.Example | Where-Object { (Get-Help $_).examples }
        $fixedDesc | Should -BeNullOrEmpty
        $fixedEx | Should -BeNullOrEmpty
    }
}
