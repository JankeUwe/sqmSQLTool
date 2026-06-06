<#
.SYNOPSIS
    Professional SQL Server Setup Report with critical issues, security, and database overview.

.DESCRIPTION
    Comprehensive setup report including:
    - CRITICAL ISSUES (SA, Backups, MaxMemory)
    - SECURITY (Sysadmins, Logins with roles, CLR, xp_cmdshell)
    - INFRASTRUCTURE (Service Accounts, SPNs, Splunk)
    - CONFIGURATION (MAXDOP, Cost Threshold, TempDB)
    - DATABASES (DBOs, Recovery Models, Last Backups)

.PARAMETER SqlInstance
    SQL Server instance. Default: local computer name.

.PARAMETER SqlCredential
    Credentials for SQL connection.

.PARAMETER OutputPath
    Output path for HTML report.

.PARAMETER PassThru
    Return the file path.

.PARAMETER NoOpen
    Don't open the report in browser.

.EXAMPLE
    Invoke-sqmSetupReport -SqlInstance "SQL01"

#>
function Invoke-sqmSetupReport
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SqlInstance,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [switch]$PassThru,
        [Parameter(Mandatory = $false)]
        [switch]$NoOpen
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
        {
            $SqlInstance = $env:COMPUTERNAME
        }

        if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath))
        {
            $OutputPath = Get-sqmConfig -Key 'OutputPath'
            if (-not $OutputPath) { $OutputPath = "C:\System\WinSrvLog\MSSQL" }
        }

        Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        try
        {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $safeInstance = $SqlInstance -replace '[\\:]', '_'
            $datestamp = Get-Date -Format 'yyyyMMdd_HHmm'
            $server = $null

            # Connect to SQL Server
            try
            {
                $server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
            }
            catch
            {
                throw "Verbindung zu $SqlInstance fehlgeschlagen: $($_.Exception.Message)"
            }

            # ==========================================
            # CRITICAL ISSUES
            # ==========================================

            # SA Account Status
            $saLogin = Get-DbaLogin -SqlInstance $server -Login 'sa' -ErrorAction SilentlyContinue
            if (-not $saLogin)
            {
                $saSid = '0x01'
                $saLogin = Get-DbaLogin -SqlInstance $server | Where-Object { $_.SID -eq $saSid }
            }
            $saName = if ($saLogin) { $saLogin.Name } else { 'NOT FOUND' }
            $saDisabled = if ($saLogin) { $saLogin.IsDisabled } else { $null }
            $saIsRenamed = ($saName -ne 'sa')
            $saStatus = if ($saIsRenamed -and $saDisabled) { 'OK (renamed & disabled)' } elseif ($saIsRenamed) { 'OK (renamed)' } elseif ($saDisabled) { 'WARNING (disabled only)' } else { 'CRITICAL (not renamed)' }
            $saStatusColor = if ($saName -ne 'sa' -or $saDisabled) { 'green' } else { 'red' }

            # Backup Jobs Status
            $backupJobs = Get-DbaAgentJob -SqlInstance $server -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*backup*' -or $_.Name -like '*bkp*' }
            $backupJobCount = @($backupJobs).Count
            $backupJobsEnabled = @($backupJobs | Where-Object { $_.IsEnabled }).Count
            $backupJobStatus = if ($backupJobCount -eq 0) { 'NO BACKUP JOBS' } elseif ($backupJobsEnabled -eq $backupJobCount) { "OK ($backupJobCount jobs)" } else { "WARNING ($backupJobsEnabled/$backupJobCount enabled)" }
            $backupStatusColor = if ($backupJobCount -gt 0 -and $backupJobsEnabled -eq $backupJobCount) { 'green' } else { 'orange' }

            # Max Memory (synchronized with Test-sqmMaxMemory logic)
            $maxMem = $server.Configuration.MaxServerMemory.ConfigValue
            $totalMem = [math]::Round($server.PhysicalMemory / 1024, 0)
            $unconfiguredValue = 2147483647
            $lowerBound = [math]::Round($totalMem * 0.85)
            $upperBound = [math]::Round($totalMem * 0.95)

            if ($maxMem -eq $unconfiguredValue)
            {
                $maxMemStatus = "NOT CONFIGURED (default)"
                $maxMemColor = 'orange'
            }
            elseif ($maxMem -gt $upperBound)
            {
                $maxMemStatus = "TOO HIGH ($maxMem MB > $upperBound MB)"
                $maxMemColor = 'orange'
            }
            elseif ($maxMem -lt $lowerBound)
            {
                $maxMemStatus = "TOO LOW ($maxMem MB < $lowerBound MB)"
                $maxMemColor = 'orange'
            }
            else
            {
                $maxMemStatus = "OK ($maxMem MB)"
                $maxMemColor = 'green'
            }

            # ==========================================
            # SECURITY CHECKS
            # ==========================================

            # Sysadmin Accounts
            $sysadmins = @()
            try
            {
                $sysadmins = @(Get-DbaLogin -SqlInstance $server | Where-Object { $_.IsSysAdmin -eq $true } | Select-Object -ExpandProperty Name)
            }
            catch { }
            $sysadminList = if ($sysadmins.Count -gt 0) { $sysadmins -join ', ' } else { 'None' }

            # Logins with Server Roles (only server-level roles)
            $advancedLogins = @()
            try
            {
                $serverRoles = @('sysadmin', 'serveradmin', 'securityadmin', 'processadmin', 'dbcreator', 'diskadmin')
                $allLogins = Get-DbaLogin -SqlInstance $server -ErrorAction SilentlyContinue
                foreach ($login in $allLogins)
                {
                    $roles = @()
                    foreach ($role in $serverRoles)
                    {
                        try
                        {
                            $query = "SELECT IS_SRVROLEMEMBER('$role', '$($login.Name)') AS IsMember"
                            $result = Invoke-DbaQuery -SqlInstance $server -Query $query -ErrorAction SilentlyContinue
                            if ($result -and $result.IsMember -eq 1)
                            {
                                $roles += $role
                            }
                        }
                        catch { }
                    }
                    if ($roles.Count -gt 0)
                    {
                        $advancedLogins += "$($login.Name) [$($roles -join ', ')]"
                    }
                }
            }
            catch { }
            $advancedLoginList = if ($advancedLogins.Count -gt 0) { $advancedLogins -join ' | ' } else { 'None with server roles' }

            # CLR Status
            $clrEnabled = $server.Configuration.IsSqlClrEnabled.ConfigValue
            $clrStatus = if ($clrEnabled) { 'ENABLED (check if needed)' } else { 'OK (disabled)' }
            $clrColor = if ($clrEnabled) { 'orange' } else { 'green' }

            # xp_cmdshell Status
            $xpCmdEnabled = $server.Configuration.XPCmdShell.ConfigValue
            $xpStatus = if ($xpCmdEnabled) { 'ENABLED (security risk)' } else { 'OK (disabled)' }
            $xpColor = if ($xpCmdEnabled) { 'orange' } else { 'green' }

            # ==========================================
            # SERVICE ACCOUNTS & INFRASTRUCTURE
            # ==========================================

            # Service Accounts
            $serviceAccounts = @()
            try
            {
                # SQL Server Service
                $sqlSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "MSSQL|SQL Server" -and $_.Name -notmatch "Agent|Browser" } | Select-Object -First 1
                if ($sqlSvc)
                {
                    $svcInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($sqlSvc.Name)'" -ErrorAction SilentlyContinue
                    if ($svcInfo)
                    {
                        $serviceAccounts += "SQL Server: $($svcInfo.StartName)"
                    }
                }

                # SQL Agent Service
                $agentSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "SQLSERVERAGENT|SQLAgent" } | Select-Object -First 1
                if ($agentSvc)
                {
                    $svcInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($agentSvc.Name)'" -ErrorAction SilentlyContinue
                    if ($svcInfo)
                    {
                        $serviceAccounts += "SQL Agent: $($svcInfo.StartName)"
                    }
                }
            }
            catch { }
            $serviceAccountList = if ($serviceAccounts.Count -gt 0) { $serviceAccounts -join ' | ' } else { 'Unable to determine' }

            # SPN Status (List all SPNs)
            $spnList = 'Not checked'
            $spnDetails = @()
            try
            {
                $spnReport = Get-sqmSpnReport -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue
                if ($spnReport -and $spnReport.DetailRows)
                {
                    foreach ($row in $spnReport.DetailRows)
                    {
                        $spnDetails += "$($row.SPN) [$($row.Status)]"
                    }
                    $spnList = if ($spnDetails.Count -gt 0) { $spnDetails -join ' | ' } else { 'No SPNs found' }
                }
            }
            catch
            {
                $spnList = 'Error retrieving SPNs'
            }

            # Splunk Status (Config + Service Test)
            $splunkOk = 'Not configured'
            try
            {
                $splunkTest = Invoke-sqmSplunkConfiguration -Test -ErrorAction SilentlyContinue
                if ($splunkTest)
                {
                    $splunkOk = 'Configured'
                }
            }
            catch { }

            # ==========================================
            # CONFIGURATION
            # ==========================================

            # MAXDOP
            $maxdop = $server.Configuration.MaxDegreeOfParallelism.ConfigValue
            $cpuCount = $server.Processors
            $recommendedMaxdop = if ($cpuCount -le 4) { $cpuCount } elseif ($cpuCount -le 8) { 4 } elseif ($cpuCount -le 16) { 8 } else { 16 }
            $maxdopStatus = if ($maxdop -ge 2 -and $maxdop -le $recommendedMaxdop) { "OK ($maxdop)" } else { "CHECK ($maxdop, recommended $recommendedMaxdop)" }

            # Cost Threshold
            $ctp = $server.Configuration.CostThresholdForParallelism.ConfigValue
            $ctpStatus = if ($ctp -ge 50) { "OK ($ctp)" } else { "WARNING ($ctp, recommended >= 50)" }

            # TempDB
            $tempdb = Get-DbaDatabase -SqlInstance $server -Database 'tempdb'
            $tempdbFileCount = $tempdb.FileGroups.Files.Count
            $idealCount = [Math]::Min($cpuCount, 8)
            $tempdbStatus = if ($tempdbFileCount -eq $idealCount) { "OK ($tempdbFileCount files)" } else { "CHECK ($tempdbFileCount files, ideal $idealCount)" }

            # ==========================================
            # DATABASES
            # ==========================================

            $databases = @()
            try
            {
                $allDbs = Get-DbaDatabase -SqlInstance $server -ExcludeSystem
                foreach ($db in $allDbs)
                {
                    $dbo = $db.Owner
                    $lastBackup = $db.LastFullBackupDate
                    $daysAgo = if ($lastBackup) { (New-TimeSpan -Start $lastBackup -End (Get-Date)).Days } else { -1 }
                    $backupStatus = if ($daysAgo -lt 0) { 'Never' } elseif ($daysAgo -eq 0) { 'Today' } elseif ($daysAgo -le 7) { "$daysAgo days" } else { "$daysAgo days ⚠️" }

                    $databases += [PSCustomObject]@{
                        Name           = $db.Name
                        Recovery       = $db.RecoveryModel
                        DBO            = $dbo
                        LastFullBackup = $backupStatus
                    }
                }
            }
            catch { }

            # ==========================================
            # BUILD HTML
            # ==========================================

            $html = _Build-ModernReportHtml `
                -SqlInstance $SqlInstance `
                -Timestamp $timestamp `
                -SAStatus $saStatus `
                -SAStatusColor $saStatusColor `
                -SAName $saName `
                -BackupStatus $backupJobStatus `
                -BackupStatusColor $backupStatusColor `
                -MaxMemStatus $maxMemStatus `
                -MaxMemColor $maxMemColor `
                -Sysadmins $sysadminList `
                -AdvancedLogins $advancedLoginList `
                -CLRStatus $clrStatus `
                -CLRColor $clrColor `
                -XPStatus $xpStatus `
                -XPColor $xpColor `
                -ServiceAccounts $serviceAccountList `
                -SPNList $spnList `
                -SplunkStatus $splunkOk `
                -MAXDOP $maxdopStatus `
                -CostThreshold $ctpStatus `
                -TempDB $tempdbStatus `
                -Databases $databases

            # ==========================================
            # SAVE REPORT
            # ==========================================

            if (-not (Test-Path $OutputPath))
            {
                $null = New-Item -ItemType Directory -Path $OutputPath -Force
            }

            $htmlFile = Join-Path $OutputPath "sqmSetupReport_${safeInstance}_${datestamp}.html"
            $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

            if (-not $NoOpen -and $htmlFile)
            {
                Start-Process $htmlFile
            }

            Invoke-sqmLogging -Message "Report erstellt: $htmlFile" -FunctionName $functionName -Level 'INFO'
            Write-Host "`n✅ Setup-Report: $htmlFile`n" -ForegroundColor Green

            Copy-sqmToCentralPath -Path $htmlFile

            if ($PassThru) { return $htmlFile }
        }
        catch
        {
            $errMsg = "Fehler: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            Write-Error $errMsg
        }
    }
}

# ======================================================================
# HTML Builder Function
# ======================================================================

function _Build-ModernReportHtml
{
    param(
        [string]$SqlInstance,
        [string]$Timestamp,
        [string]$SAStatus,
        [string]$SAStatusColor,
        [string]$SAName,
        [string]$BackupStatus,
        [string]$BackupStatusColor,
        [string]$MaxMemStatus,
        [string]$MaxMemColor,
        [string]$Sysadmins,
        [string]$AdvancedLogins,
        [string]$CLRStatus,
        [string]$CLRColor,
        [string]$XPStatus,
        [string]$XPColor,
        [string]$ServiceAccounts,
        [string]$SPNList,
        [string]$SplunkStatus,
        [string]$MAXDOP,
        [string]$CostThreshold,
        [string]$TempDB,
        [PSCustomObject[]]$Databases
    )

    function _HtmlEncode
    {
        param([string]$Text)
        if (-not $Text) { return '' }
        $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
    }

    $dbRows = if ($Databases) {
        $Databases | ForEach-Object {
            "<tr><td>$(_HtmlEncode $_.Name)</td><td>$($_.Recovery)</td><td>$(_HtmlEncode $_.DBO)</td><td>$($_.LastFullBackup)</td></tr>"
        } | Out-String
    } else {
        '<tr><td colspan="4">No databases</td></tr>'
    }

    return @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SQL Server Setup Report - $(_HtmlEncode $SqlInstance)</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #060f20; color: #e2e8f0; font-size: 14px; line-height: 1.6; }

  .header { background: linear-gradient(160deg, #060f20 0%, #0b1e3d 100%); border-bottom: 3px solid #2e86c1; padding: 32px 40px; }
  .header h1 { font-size: 28px; font-weight: 600; color: #5dade2; margin-bottom: 8px; }
  .header .meta { color: #94a8c0; font-size: 13px; }

  .container { max-width: 1200px; margin: 0 auto; padding: 32px 40px; }

  /* Critical Issues Section */
  .section-title { font-size: 18px; font-weight: 700; color: #5dade2; margin-top: 32px; margin-bottom: 16px; border-bottom: 2px solid #1e3a5f; padding-bottom: 8px; }

  .cards-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 24px; }
  .card {
    background: #0d1f38; border-left: 4px solid; padding: 20px; border-radius: 6px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.3);
  }
  .card.green { border-left-color: #27ae60; background: rgba(39, 174, 96, 0.08); }
  .card.orange { border-left-color: #f39c12; background: rgba(243, 156, 18, 0.08); }
  .card.red { border-left-color: #e74c3c; background: rgba(231, 76, 60, 0.12); }

  .card-label { color: #94a8c0; font-size: 12px; text-transform: uppercase; font-weight: 600; letter-spacing: 0.05em; margin-bottom: 8px; }
  .card-value { color: #e2e8f0; font-size: 16px; font-weight: 600; }
  .card-detail { color: #94a8c0; font-size: 12px; margin-top: 6px; }

  /* Info Sections */
  .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin-bottom: 32px; }
  .info-block h3 { font-size: 14px; color: #5dade2; font-weight: 600; margin-bottom: 12px; text-transform: uppercase; }
  .info-block p { color: #e2e8f0; font-size: 13px; margin-bottom: 6px; word-wrap: break-word; }
  .info-label { color: #94a8c0; font-weight: 600; display: inline-block; min-width: 140px; }

  /* Database Table */
  table { width: 100%; border-collapse: collapse; background: #0d1f38; border-radius: 6px; overflow: hidden; margin-top: 16px; }
  th { background: #0b1e3d; color: #94a8c0; font-weight: 600; font-size: 12px; text-transform: uppercase; padding: 12px 16px; text-align: left; border-bottom: 1px solid #1e3a5f; }
  td { padding: 12px 16px; border-bottom: 1px solid #0f2540; color: #e2e8f0; }
  tr:hover { background: rgba(93, 173, 226, 0.06); }

  .footer { margin-top: 40px; padding-top: 24px; border-top: 1px solid #1e3a5f; color: #4a6080; font-size: 12px; }
</style>
</head>
<body>

<div class="header">
  <h1>SQL Server Setup Report</h1>
  <div class="meta">Instance: <strong>$(_HtmlEncode $SqlInstance)</strong> | Timestamp: $Timestamp</div>
</div>

<div class="container">

  <!-- CRITICAL ISSUES -->
  <div class="section-title">CRITICAL ISSUES</div>
  <div class="cards-grid">
    <div class="card $SAStatusColor">
      <div class="card-label">SA Account</div>
      <div class="card-value">$SAStatus</div>
      <div class="card-detail">Name: $(_HtmlEncode $SAName)</div>
    </div>
    <div class="card $BackupStatusColor">
      <div class="card-label">Backup Jobs</div>
      <div class="card-value">$BackupStatus</div>
      <div class="card-detail">Enable backups immediately if missing</div>
    </div>
    <div class="card $MaxMemColor">
      <div class="card-label">Max Memory</div>
      <div class="card-value">$MaxMemStatus</div>
      <div class="card-detail">Tolerance: 85-95% of RAM</div>
    </div>
  </div>

  <!-- SECURITY -->
  <div class="section-title">SECURITY</div>
  <div class="cards-grid">
    <div class="card">
      <div class="card-label">Sysadmin Accounts</div>
      <div class="card-value">$(_HtmlEncode $Sysadmins)</div>
    </div>
    <div class="card">
      <div class="card-label">Logins with Extended Roles</div>
      <div class="card-value" style="font-size: 13px;">$(_HtmlEncode $AdvancedLogins)</div>
    </div>
  </div>

  <div class="info-grid">
    <div class="info-block">
      <h3>Server-Level Features</h3>
      <p><span class="info-label">CLR:</span> $CLRStatus</p>
      <p><span class="info-label">xp_cmdshell:</span> $XPStatus</p>
    </div>
    <div class="info-block">
      <h3>Infrastructure</h3>
      <p><span class="info-label">SPNs:</span> $(_HtmlEncode $SPNList)</p>
      <p><span class="info-label">Splunk:</span> $SplunkStatus</p>
    </div>
  </div>

  <!-- SERVICE ACCOUNTS -->
  <div class="section-title">SERVICE ACCOUNTS</div>
  <div class="info-block">
    <p>$(_HtmlEncode $ServiceAccounts)</p>
  </div>

  <!-- CONFIGURATION -->
  <div class="section-title">CONFIGURATION</div>
  <div class="info-grid">
    <div class="info-block">
      <h3>Query Execution</h3>
      <p><span class="info-label">MAXDOP:</span> $MAXDOP</p>
      <p><span class="info-label">Cost Threshold:</span> $CostThreshold</p>
    </div>
    <div class="info-block">
      <h3>Tempdb</h3>
      <p><span class="info-label">Files:</span> $TempDB</p>
    </div>
  </div>

  <!-- DATABASES -->
  <div class="section-title">DATABASES</div>
  <table>
    <thead>
      <tr>
        <th>Database</th>
        <th>Recovery Model</th>
        <th>DBO Owner</th>
        <th>Last Full Backup</th>
      </tr>
    </thead>
    <tbody>
      $dbRows
    </tbody>
  </table>

  <div class="footer">
    Report generated by sqmSQLTool - Setup Report v2.0 | All times UTC
  </div>

</div>

</body>
</html>
"@
}
