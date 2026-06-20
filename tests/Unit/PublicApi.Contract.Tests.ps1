#Requires -Modules Pester
<#
.SYNOPSIS
    Contract tests that protect downstream consumers of sqmSQLTool.
.DESCRIPTION
    sqmSQLTool is the shared core for other projects (notably SQLSetupTool). Removing or
    renaming a function that those projects call breaks them silently. These tests freeze the
    consumed surface and the manifest/export consistency so such regressions fail in CI.
#>

BeforeAll {
    . "$PSScriptRoot\..\TestHelpers.ps1"
    Import-sqmTestModule
    $script:exported   = (Get-Command -Module sqmSQLTool -CommandType Function).Name
    $script:moduleRoot = (Get-Module sqmSQLTool).ModuleBase
}

AfterAll {
    if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
    $env:MSSQLTOOLS_SKIP_AUTO_UPDATE = $null
}

Describe 'Public API contract (downstream consumers)' {
    # Functions called by SQLSetupTool\Modules\*.psm1 and Start-SqlSetup.ps1.
    # If any of these is removed/renamed, the SQL Server Setup Tool breaks.
    # Keep in sync with real consumers when intentionally changing the API.
    $consumerApi = @(
        'Invoke-sqmFormatDrive64k', 'Get-sqmHpuAllowGroup', 'Test-sqmSqlInstanceInstalled',
        'Get-sqmDiskBlockSize', 'Invoke-sqmSetDatabaseRecoveryMode', 'Invoke-sqmMonitoringKey',
        'Get-sqmSQLInstanceCheck', 'Install-sqmOlaMaintenanceSolution', 'New-sqmOlaMaintenanceJobs',
        'New-sqmOlaSysDbBackupJob', 'New-sqmOlaUsrDbBackupJob', 'Invoke-sqmSplunkConfiguration',
        'Enable-sqmMonitoringAccess', 'Set-sqmTcpPort', 'Invoke-sqmSaObfuscation',
        'Invoke-sqmSetupReport', 'New-sqmSetupReport', 'Write-sqmSetupEvent',
        'Invoke-sqmAlwaysOnSetup', 'Install-sqmSsrsReportServer', 'Set-sqmSsrsConfiguration',
        'Install-sqmJdbcDriver', 'Install-sqmOdbcDriver', 'Install-sqmDb2Driver',
        'Test-sqmDriverInstalled', 'Uninstall-sqmJdbcDriver', 'Uninstall-sqmOdbcDriver',
        'Uninstall-sqmDb2Driver'
    )

    It 'still exports <_>' -ForEach $consumerApi {
        $script:exported | Should -Contain $_
    }
}

Describe 'Manifest export consistency' {
    It 'every function in FunctionsToExport resolves to a loaded command' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:moduleRoot 'sqmSQLTool.psd1')
        foreach ($fn in $manifest.FunctionsToExport)
        {
            Get-Command $fn -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty -Because "$fn is declared in FunctionsToExport"
        }
    }
}

Describe 'UTF-8 BOM on Public scripts' {
    It 'all Public/*.ps1 start with a UTF-8 BOM (required by PS 5.1)' {
        $bad = @()
        Get-ChildItem (Join-Path $script:moduleRoot 'Public') -Filter *.ps1 | ForEach-Object {
            $b = [System.IO.File]::ReadAllBytes($_.FullName)
            if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF))
            {
                $bad += $_.Name
            }
        }
        $bad | Should -BeNullOrEmpty
    }
}
