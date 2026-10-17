#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer das Standort-Profil (sqmSQLTool.site.json).

.DESCRIPTION
    Standortspezifische Werte (Job-Namen, Freigabepfade, Monitoring-Account, ...) stehen nicht
    im Code, sondern in einem optionalen, nicht versionierten Standort-Profil. Geprueft wird:
      - Ohne Profil (oeffentliche Installation) gelten die neutralen Standardwerte.
      - Mit simuliertem Profil werden Detection, Config und Defaults angewendet.
      - Der dbatools-Fallback durchsucht die Profil-Freigaben in fester Reihenfolge:
        DbatoolsShareCandidates (neu) vor DbatoolsLegacyShareCandidates.
      - Der fruehere CheckProfile-Wert 'FiTs' wird weiter akzeptiert.
      - Im Code stehen keine Kundenkennungen.

    Profil-Tests laufen in einem eigenen PowerShell-Prozess mit einer Modulkopie im
    TEMP-Verzeichnis - das echte %ProgramData%\MSSQLTools wird nie beschrieben.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
    Import-sqmTestModule

    $script:PsExe = (Get-Process -Id $PID).Path

    # Modulkopie mit optionalem Standort-Profil anlegen, in neuem Prozess importieren und
    # das Ergebnis (Konfiguration, PSModulePath-Spitze, dbatools-Pfad) als JSON zurueckgeben.
    function Invoke-SiteProfileImport {
        param(
            [hashtable]$SiteProfile,
            [switch]$WithFakeDbatoolsShares
        )
        $root = Join-Path ([IO.Path]::GetTempPath()) ("sqmSiteTest_" + [guid]::NewGuid().ToString('N'))
        $modDir = Join-Path $root 'sqmSQLTool'
        New-Item -ItemType Directory -Path $modDir -Force | Out-Null
        foreach ($item in @('sqmSQLTool.psm1', 'sqmSQLTool.psd1', 'Public', 'Private', 'jobs', 'Tools', 'Assets')) {
            $src = Join-Path $script:ModuleRoot $item
            if (Test-Path $src) { Copy-Item -Path $src -Destination $modDir -Recurse -Force }
        }

        $shares = @{}
        if ($WithFakeDbatoolsShares) {
            # new1 fehlt, new2 + legacy1 haben ein (Fake-)dbatools - new2 muss gewinnen
            foreach ($name in 'new1', 'new2', 'legacy1') { $shares[$name] = Join-Path $root "share_$name" }
            foreach ($name in 'new2', 'legacy1') {
                $fake = Join-Path $shares[$name] 'dbatools'
                New-Item -ItemType Directory -Path $fake -Force | Out-Null
                Set-Content -Path (Join-Path $fake 'dbatools.psm1') -Value "function Get-FakeDbaShare { '$name' }"
            }
            $SiteProfile['DbatoolsShareCandidates']       = @($shares['new1'], $shares['new2'])
            $SiteProfile['DbatoolsLegacyShareCandidates'] = @($shares['legacy1'])
        }
        if ($SiteProfile) {
            $SiteProfile | ConvertTo-Json -Depth 5 |
                Set-Content -Path (Join-Path $modDir 'sqmSQLTool.site.json') -Encoding UTF8
        }

        $script = @"
`$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = '1'
if ('$([bool]$WithFakeDbatoolsShares)' -eq 'True') {
    # Kein echtes dbatools erreichbar machen, damit der Freigabe-Fallback greift
    `$env:PSModulePath = (`$env:PSModulePath -split ';' | Where-Object { -not (Test-Path (Join-Path `$_ 'dbatools')) }) -join ';'
}
Import-Module '$modDir\sqmSQLTool.psm1' -Force -WarningAction SilentlyContinue -DisableNameChecking
`$cfg = Get-sqmConfig
[PSCustomObject]@{
    OlaJobNameFull              = `$cfg['OlaJobNameFull']
    OlaJobNameBackupExcludeSync = `$cfg['OlaJobNameBackupExcludeSync']
    MonitoringRegistrySubKey    = `$cfg['MonitoringRegistrySubKey']
    DefaultMonitoringUser       = `$cfg['DefaultMonitoringUser']
    CheckProfile                = `$cfg['CheckProfile']
    DbatoolsSharePath           = `$cfg['DbatoolsSharePath']
    PSModulePathHead            = (`$env:PSModulePath -split ';')[0]
    FakeDbaShare                = if (Get-Command Get-FakeDbaShare -ErrorAction SilentlyContinue) { Get-FakeDbaShare } else { `$null }
} | ConvertTo-Json -Compress
"@
        $scriptFile = Join-Path $root 'run.ps1'
        Set-Content -Path $scriptFile -Value $script -Encoding UTF8
        try {
            $out = & $script:PsExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptFile 2>$null
            $json = @($out) | Where-Object { $_ -like '{*' } | Select-Object -Last 1
            [PSCustomObject]@{ Result = ($json | ConvertFrom-Json); Root = $root; Shares = $shares }
        }
        finally {
            Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Standort-Profil' {

    It 'ohne Profil gelten die neutralen Standardwerte' {
        $r = (Invoke-SiteProfileImport).Result
        $r | Should -Not -BeNullOrEmpty
        $r.OlaJobNameBackupExcludeSync | Should -Be 'sqm BackupExclude - SYNC'
        $r.MonitoringRegistrySubKey    | Should -Be 'sqmSQLTool\SystemCenter'
        $r.CheckProfile                | Should -Be 'Auto'
    }

    It 'wendet Config an, wenn Detection.ModulePathPatterns passt (inkl. %VAR%-Expansion und FiTs-Alias)' {
        $siteProf = @{
            Detection = @{ ModulePathPatterns = @("$([IO.Path]::GetTempPath())sqmSiteTest_*") }
            Defaults  = @{ MonitoringRegistrySubKey = 'SiteMon\SystemCenter' }
            Config    = @{
                OlaJobNameFull              = 'SITE Backup - USER_DATABASES - FULL'
                OlaJobNameBackupExcludeSync = 'SITE BackupExclude - SYNC'
                DefaultMonitoringUser       = '%USERDOMAIN%\monuser'
                CheckProfile                = 'FiTs'
            }
        }
        $r = (Invoke-SiteProfileImport -SiteProfile $siteProf).Result
        $r.OlaJobNameFull              | Should -Be 'SITE Backup - USER_DATABASES - FULL'
        $r.OlaJobNameBackupExcludeSync | Should -Be 'SITE BackupExclude - SYNC'
        $r.MonitoringRegistrySubKey    | Should -Be 'SiteMon\SystemCenter'
        $r.DefaultMonitoringUser       | Should -Be "$env:USERDOMAIN\monuser"
        $r.CheckProfile                | Should -Be 'Site'
    }

    It 'wendet Config NICHT an, wenn Detection nicht passt (Defaults gelten trotzdem)' {
        $siteProf = @{
            Detection = @{ ModulePathPatterns = @('Q:\NoSuchDrive\*'); UserDomains = @('NO-SUCH-DOMAIN-X') }
            Defaults  = @{ MonitoringRegistrySubKey = 'SiteMon\SystemCenter' }
            Config    = @{ OlaJobNameFull = 'SITE Backup - USER_DATABASES - FULL' }
        }
        $r = (Invoke-SiteProfileImport -SiteProfile $siteProf).Result
        $r.OlaJobNameFull           | Should -Not -Be 'SITE Backup - USER_DATABASES - FULL'
        $r.MonitoringRegistrySubKey | Should -Be 'SiteMon\SystemCenter'
    }

    It 'dbatools-Fallback: erster vorhandener neuer Pfad vor Legacy-Pfad' {
        $siteProf = @{ Detection = @{ ModulePathPatterns = @('Q:\NoSuchDrive\*') } }
        $run = Invoke-SiteProfileImport -SiteProfile $siteProf -WithFakeDbatoolsShares
        $run.Result.PSModulePathHead | Should -Be $run.Shares['new2']
        $run.Result.FakeDbaShare     | Should -Be 'new2'
    }
}

Describe 'Set-sqmConfig -CheckProfile' {
    It 'akzeptiert den frueheren Wert FiTs und speichert Site' {
        InModuleScope sqmSQLTool {
            $configFile = Join-Path $env:APPDATA 'MSSQLTools\config.json'
            $backup = if (Test-Path $configFile) { Get-Content $configFile -Raw } else { $null }
            $saved = $script:sqmModuleConfig['CheckProfile']
            try {
                Set-sqmConfig -CheckProfile 'FiTs' -Confirm:$false
                $script:sqmModuleConfig['CheckProfile'] | Should -Be 'Site'
                (Get-Content $configFile -Raw | ConvertFrom-Json).CheckProfile | Should -Be 'Site'
            }
            finally {
                $script:sqmModuleConfig['CheckProfile'] = $saved
                if ($null -ne $backup) { Set-Content -Path $configFile -Value $backup -NoNewline }
                else { Remove-Item $configFile -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

Describe 'Keine Kundenkennungen im Code' {
    It 'Code-Dateien enthalten keine Kundennamen, Kundenpfade oder Kundendomaenen' {
        # Muster zusammengesetzt, damit diese Datei sich nicht selbst meldet
        $markers = @(('FI' + '-TS'), ('750' + '84'), ('\bFI' + 'TS\b'), ('OFFICE' + 'LAN'), ('izt' + '0504'), ('DWP' + '1W'), ('SUEB' + '0'))
        $pattern = $markers -join '|'
        $files = Get-ChildItem -Path $script:ModuleRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.cmd', '*.json' |
            Where-Object { $_.FullName -notmatch '\\(bin|\.git|Docs)\\' -and $_.Name -ne 'sqmSQLTool.site.json' }
        $hits = foreach ($f in $files) {
            Select-String -Path $f.FullName -Pattern $pattern -CaseSensitive |
                ForEach-Object { "$($f.Name):$($_.LineNumber)" }
        }
        $hits | Should -BeNullOrEmpty
    }
}
