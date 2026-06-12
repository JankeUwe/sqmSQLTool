# sqmSQLTool Complete User Manual

**Version:** 2.0 | **Functions:** 129 | **Date:** 2026-06-12

---

## Contents

- 14. Active Directory Integration (4 functions)
- 10. Reporting & Analysis (5 functions)
- 3. Backup & Recovery (10 functions)
- 7. Configuration Management (7 functions)
- 17. SSRS Configuration (3 functions)
- 5. Login & User Security (8 functions)
- 12. Server Configuration Testing (5 functions)
- 4. Monitoring & Health Checks (8 functions)
- 8. Storage & Disk Management (6 functions)
- 11. Module & Update Management (6 functions)
- 16. SQL Drivers & Tools Installation (6 functions)
- 19. External Systems Integration (3 functions)
- 13. SQL Agent & Proxy Jobs (4 functions)
- 1. Always On & Availability Groups (18 functions)
- 18. SSIS Configuration (2 functions)
- 21. Analysis Services (SSAS) (1 functions)
- 2. Performance Analysis & Optimization (10 functions)
- 6. Certificates & TLS Security (8 functions)
- 15. Extended Events & Diagnostics (3 functions)
- 9. Database Maintenance (5 functions)
- 22. Monitoring & Registry (3 functions)
- 20. Script Execution & Deployment (3 functions)

---

## 14. Active Directory Integration

### Get-sqmADAccountStatus

Checks the status of an Active Directory user account.

**Parameters:** -SamAccountName, -DomainController

**Example:**

```powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe'
```n
### Get-sqmADGroupMembers

Lists all members of an Active Directory group.

**Parameters:** -GroupName, -Domain

**Example:**

```powershell
Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"
```n
### Get-sqmHpuAllowGroup

Searches for the HPU allow group in Active Directory based on configurable domain/group mappings.

**Example:**

```powershell
Get-sqmHpuAllowGroup
```n
### Remove-sqmAdOrphanLogin

Removes Windows logins whose Active Directory account no longer exists (AD orphans).

**Parameters:** -SqlInstance, -SqlCredential, -ExcludeLogin, -AdModuleAction, -BackupPath, -SkipBackup, -EnableException

**Example:**

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -WhatIf
    Lists exactly which AD-orphaned logins would be removed, without changing anything.
```n
## 10. Reporting & Analysis

### Export-sqmDatabaseDocumentation

Creates structured HTML and CSV documentation for all databases on a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -IncludeSystemDatabases, -IncludeFileDetails, -IncludeUsers, -IncludeObjectSummary, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Export-sqmDatabaseDocumentation
```n
### Get-sqmAutoGrowthReport

Creates an AutoGrowth configuration report for all database files on a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -IncludeSystem, -Detailed, -EnableException

**Example:**

```powershell
Get-sqmAutoGrowthReport -SqlInstance "SQL01"
```n
### Get-sqmServerHardwareReport

Erstellt einen HTML-Hardware-Konfigurationsbericht fuer einen oder mehrere Server.

**Parameters:** -ComputerName, -ReportPath, -OutputFormat, -NoOpen, -PassThru, -EnableException

**Example:**

```powershell
# Lokalen Server analysieren - Report wird automatisch im Browser geoeffnet
    Get-sqmServerHardwareReport
```n
### Invoke-sqmInstanceInventory

Creates a complete inventory of a SQL Server instance as a structured report (TXT + CSV).

**Parameters:** -SqlInstance, -SqlCredential, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Invoke-sqmInstanceInventory
```n
### Invoke-sqmSetupReport

Professional SQL Server Setup Report with critical issues, security, and database overview.

**Parameters:** -SqlInstance, -SqlCredential, -OutputPath, -PassThru, -NoOpen

**Example:**

```powershell
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

            # Splunk Status (via Invoke-sqmSplunkConfiguration -Test)
            $splunkStatus = 'Not configured'
            try
            {
                $splunkResult = Invoke-sqmSplunkConfiguration -Mode Test -ErrorAction SilentlyContinue
                if ($splunkResult)
                {
                    if ($splunkResult.IsConfigured)
                    {
                        $splunkStatus = "Configured (service: $($splunkResult.ServiceStatus))"
                    }
                    else
                    {
                        $splunkStatus = 'Not configured'
                    }
                }
            }
            catch
            {
                $splunkStatus = 'Error checking Splunk'
            }

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
                -SplunkStatus $splunkStatus `
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

            Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

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
```n
## 3. Backup & Recovery

### Get-sqmOperationStatus

Displays progress and estimated remaining time for active backup, restore and AutoSeed operations.

**Parameters:** -SqlInstance, -SqlCredential, -OperationType, -Continuous, -RefreshSeconds, -EnableException

**Example:**

```powershell
# Show all active operations on the local instance
Get-sqmOperationStatus
```n
### Invoke-sqmRestoreDatabase

Restores a database from a backup file, with support for single-server and AlwaysOn environments.

**Parameters:** -SqlInstance, -SqlCredential, -BackupFile, -BackupFiles, -DatabaseName, -NewDatabaseName, -NewDatabaseFilePath, -NewLogFilePath, -BackupBeforeRestore, -NoUserExport, -KeepAlwaysOn, -WithNoRecovery, -ContinueWithNoRecovery, -ForceSingleUser, -RejoinAvailabilityGroup, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
# Simple restore of a full backup file
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\AdventureWorks.bak" -DatabaseName "AdventureWorks"
```n
### Invoke-sqmUserDatabaseBackup

Backs up user databases on a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -All, -BackupPath, -UseExcludeTable, -CheckPreferredReplica, -MailTo, -MailProfile, -MailOnSuccess, -EnableException

**Example:**

```powershell
# Back up all user databases on the current computer
Invoke-sqmUserDatabaseBackup -All
```n
### New-sqmBackupMaintenanceJob

Creates a SQL Agent job with two steps that implement the full dynamic backup maintenance workflow.

**Parameters:** -SqlInstance, -SqlCredential, -JobName, -BackupType, -BackupPath, -ScheduleTime, -ScheduleDays, -ScheduleIntervalMinutes, -JobCategory, -UseExcludeTable, -CheckPreferredReplica, -IncludeSystemDatabases, -MailTo, -MailProfile, -MailOnSuccess, -OperatorName, -Update, -EnableException, -WhatIf, -Confirm

**Example:**

```powershell
# Weekly FULL backup Sunday 20:00 with all features
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL `
	    -UseExcludeTable -CheckPreferredReplica `
	    -MailTo "dba@company.com" -MailProfile "DBA-Mail"
```n
### Set-sqmBackupExcludePermission

Grants SELECT, INSERT, and UPDATE permissions on master.dbo.sqm_BackupExclude to a login.

**Parameters:** -SqlInstance, -SqlCredential, -LoginName, -EnableException

**Example:**

```powershell
# Grant permissions to a Windows group on the local instance
Set-sqmBackupExcludePermission -LoginName "CONTOSO\DBA-Team"
```n
### Sync-sqmBackupExcludeTable

Creates and synchronises the backup exclude table in the master database.

**Parameters:** -SqlInstance, -SqlCredential, -IncludeSystemDatabases, -EnableException

**Example:**

```powershell
# Synchronise on the local instance – user databases only
Sync-sqmBackupExcludeTable
```n
### Test-sqmBackupIntegrity

Verifies one or more backup files using RESTORE VERIFYONLY.

**Parameters:** -SqlInstance, -SqlCredential, -BackupPath, -FileListOnly, -EnableException

**Example:**

```powershell
Test-sqmBackupIntegrity -SqlInstance "SQL01" -BackupPath "D:\Backup\AdventureWorks.bak"
```n
## 7. Configuration Management

### Compare-sqmServerConfiguration

Compares important configuration settings between two SQL Server instances.

**Parameters:** -SourceInstance, -TargetInstance, -SqlCredential, -CompareDatabases, -EnableException

**Example:**

```powershell
Compare-sqmServerConfiguration -SourceInstance "SQL01" -TargetInstance "SQL02"
```n
### Export-sqmServerConfiguration

Exports all SQL Server configuration settings to a JSON snapshot file.

**Parameters:** -SqlInstance, -SqlCredential, -OutputPath, -Label, -IncludeDatabases, -EnableException

**Example:**

```powershell
# Create a snapshot before making configuration changes
$snap = Export-sqmServerConfiguration -SqlInstance "SQL01" -Label "before MaxMemory change"
Write-Host "Snapshot saved to: $($snap.SnapshotPath)"
```n
### Invoke-sqmConfigRollback

Restores SQL Server configuration from a previously exported snapshot.

**Parameters:** -SqlInstance, -SqlCredential, -SnapshotPath, -Category, -WhatIf, -Force, -EnableException

**Example:**

```powershell
# Preview what would be restored
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -WhatIf
```n
### Set-sqmConfig

Sets one or more configuration values for the MSSQLTools module.

**Parameters:** -LogPath, -OutputPath, -CentralPath, -OlaJobNameFull, -OlaJobNameDiff, -OlaJobNameLog, -OlaJobNameIndexOpt, -OlaJobNameIntUserDb, -OlaJobNameIntSysDb, -OlaJobNameSysDbBackup, -TsmManagementClasses, -HpuDomainGroupMap, -SsrsInstallerPath, -CheckProfile, -CheckCostThresholdMin, -CheckTempDbMaxFiles, -CheckDiskBlockSize, -Language, -PassThru

**Example:**

```powershell
Set-sqmConfig -LogPath "D:\Logs" -OlaJobNameFull "Prod-FULL"
```n
### Get-sqmConfig

Returns the current module configuration.

**Parameters:** -Key

**Example:**

```powershell
Get-sqmConfig
```n
### Set-sqmTcpPort

Konfiguriert den TCP-Port einer SQL Server-Instanz ueber die Registry.

**Parameters:** -SqlInstance, -BasePort, -PortIncrement, -InstanceNumber

**Example:**

```powershell
Set-sqmTcpPort -SqlInstance 'MSSQLSERVER' -BasePort 1433
```n
### Invoke-sqmCollationChange

Automatically changes the server collation of a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -NewCollation, -IncludeUserDatabases, -BackupBeforeChange, -ExcludeDatabase, -ServiceName, -StartupTimeoutSeconds, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Invoke-sqmCollationChange -NewCollation "Latin1_General_CI_AS"
```n
## 17. SSRS Configuration

### Set-sqmSsrsHttpsCertificate

Binds a Windows certificate to SSRS or Power BI Report Server for HTTPS access.

**Parameters:** -ComputerName, -Thumbprint, -Port, -InstanceName, -IPAddress, -RequireSSL, -Credential, -WhatIf, -Confirm

**Example:**

```powershell
Set-sqmSsrsHttpsCertificate -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"

		Binds the specified certificate to SSRS on the local machine on port 443.
		The SSRS instance is auto-detected.
```n
## 5. Login & User Security

### Copy-sqmLogins

Copies logins from a source SQL Server instance to a target instance.

**Parameters:** -Source, -Destination, -SqlCredential, -SourceCredential, -DestinationCredential, -Login, -ExcludeLogin, -IncludeSystemLogins, -DisablePolicy, -AdjustAuthMode, -RestartServiceIfRequired, -Force, -AdModuleAction, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02'

    Copies all non-system logins. Policy is disabled/re-enabled,
    AD check and orphan repair run automatically.
```n
### Get-sqmADAccountStatus

Checks the status of an Active Directory user account.

**Parameters:** -SamAccountName, -DomainController

**Example:**

```powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe'
```n
### Get-sqmADGroupMembers

Lists all members of an Active Directory group.

**Parameters:** -GroupName, -Domain

**Example:**

```powershell
Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"
```n
### Get-sqmLoginSettings

Zeigt alle Logins mit Default-Datenbank und Spracheinstellung.

**Parameters:** -SqlInstance, -SqlCredential, -LoginType, -ExcludeSystemLogins, -DefaultDatabase, -DefaultLanguage, -OutputPath, -ContinueOnError, -EnableException

**Example:**

```powershell
Get-sqmLoginSettings
```n
### Get-sqmSysadminAccounts

Retrieves all logins with sysadmin rights on a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -ExcludeLogin, -ExcludeSysAccounts, -IncludeDisabled, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Get-sqmSysadminAccounts
```n
### Invoke-sqmSaObfuscation

Obfuscates the SA account on a SQL Server instance by renaming it, disabling it, and setting a random password.

**Parameters:** -SqlInstance, -SqlCredential, -NewName, -PasswordLength, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Invoke-sqmSaObfuscation -SqlInstance "SQL01"
```n
### Remove-sqmAdOrphanLogin

Removes Windows logins whose Active Directory account no longer exists (AD orphans).

**Parameters:** -SqlInstance, -SqlCredential, -ExcludeLogin, -AdModuleAction, -BackupPath, -SkipBackup, -EnableException

**Example:**

```powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -WhatIf
    Lists exactly which AD-orphaned logins would be removed, without changing anything.
```n
### Set-sqmDatabaseOwner

Sets the owner of one or more databases to a uniform login.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -ExcludeDatabase, -OwnerLogin, -IncludeSystemDatabases, -Force, -OutputPath, -ContinueOnError, -EnableException

**Example:**

```powershell
# Set sa account on all user databases
    Set-sqmDatabaseOwner -SqlInstance "SQL01"
```n
## 12. Server Configuration Testing

### Get-sqmClusterInfo

Retrieves information about a Windows Failover Cluster: cluster name, nodes and roles including IP addresses.

**Parameters:** -ClusterName, -IncludeCoreGroup, -NoAutoInstall, -EnableException

**Example:**

```powershell
$info = Get-sqmClusterInfo -ClusterName "MYCLUSTER"
    if (-not $info.Success) { Write-Error $info.ErrorMessage; return }
    $info.ClusterName
    $info.Nodes | Format-Table
    $info.Roles | Where-Object OwnerNode -eq "Node1" | Select Name, IPAddresses
```n
### Get-sqmPerfCounters

Reads SQL Server performance counters from sys.dm_os_performance_counters.

**Parameters:** -SqlInstance, -SqlCredential, -Category, -TopN, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmPerfCounters -SqlInstance "SQL01"
```n
### Get-sqmSpnReport

Checks the registered SPNs for SQL Server instances (default and named instances).

**Parameters:** -ComputerName, -InstanceFilter, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Get-sqmSpnReport

    Checks all SQL Server instances on the local computer.
```n
### Test-sqmSQLFirewall

Tests whether the firewall and network allow a TCP connection to SQL Server.

**Parameters:** -Server, -Port, -Instance, -TimeoutSeconds, -ContinueOnError, -EnableException

**Example:**

```powershell
Test-sqmSQLFirewall -Server "SQL01"

    Tests the default instance on TCP port 1433.
```n
### Test-sqmSqlInstanceInstalled

Prueft ob eine SQL Server-Instanz auf dem lokalen System installiert ist.

**Parameters:** -InstanceName

**Example:**

```powershell
Test-sqmSqlInstanceInstalled
    # Prueft Default-Instanz MSSQLSERVER
```n
## 4. Monitoring & Health Checks

### Get-sqmBlockingReport

Retrieves current blocking chains on a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -MinWaitSeconds, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmBlockingReport
```n
### Get-sqmConnectionStats

Analyzes active SQL Server connections and connection statistics.

**Parameters:** -SqlInstance, -SqlCredential, -GroupBy, -TopN, -IncludeSystemConnections, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmConnectionStats -SqlInstance "SQL01"
```n
### Get-sqmDatabaseHealth

Aggregated health report for all databases on an instance.

**Parameters:** -SqlInstance, -SqlCredential, -MaxCheckDbAgeDays, -MaxVlfCount, -HistoryDays, -ExcludeDatabase, -IncludeSystemDatabases, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Get-sqmDatabaseHealth
```n
### Get-sqmDeadlockReport

Reads and analyzes deadlock events from the System Health Extended Event session.

**Parameters:** -SqlInstance, -SqlCredential, -StartTime, -EndTime, -MaxDeadlocks, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmDeadlockReport
```n
### Get-sqmLongRunningQueries

Identifies long-running queries on a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -MinDurationSeconds, -MinCpuMs, -ExcludeWaitType, -IncludeSystemSessions, -IncludeQueryPlan, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmLongRunningQueries
```n
### Get-sqmServerSetting

Reads one or all server properties from a SQL Server instance.

**Parameters:** -SqlInstance, -SqlCredential, -Name, -All, -DefaultValue, -EnableException

**Example:**

```powershell
# Read BackupDirectory from the local server
$backupPath = Get-sqmServerSetting -Name "BackupDirectory"
```n
### Get-sqmSQLInstanceCheck

Checks a SQL Server instance against best practices.

**Parameters:** -SqlInstance, -SqlCredential, -Detailed, -EnableException

**Example:**

```powershell
Get-sqmSQLInstanceCheck
```n
### Invoke-sqmLoginAudit

Comprehensive audit of all SQL Server logins on one or more instances.

**Parameters:** -SqlInstance, -SqlCredential, -InactivityThresholdDays, -MaxPasswordAgeDays, -MaxPasswordAgeDaysSysadmin, -ExcludeLogin, -IncludeSystemLogins, -CheckPolicyNonSysadmin, -CheckPolicySysadmin, -ReportBuiltInAdmins, -CheckAdOrphans, -GenerateHtmlReport, -HtmlReportTemplate, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Invoke-sqmLoginAudit
```n
## 8. Storage & Disk Management

### Copy-sqmNTFSPermissions

Copies NTFS permissions (ACLs) from a source path to a destination path.

**Parameters:** -SourcePath, -DestinationPath, -Recurse, -CreateMissingFolders, -IncludeSystemAndHidden

**Example:**

```powershell
Copy-sqmNTFSPermissions -SourcePath "D:\" -DestinationPath "E:\" -Recurse
    Copies all permissions from D: to E: (recursively).
```n
### Get-sqmDiskBlockSize

Prueft die NTFS-Blockgroesse (Cluster-Groesse) von Laufwerken auf 64KB.

**Parameters:** -Drive, -SqlInstance, -ComputerName, -RecommendedBlockSize, -EnableException

**Example:**

```powershell
# Einzelne Laufwerke pruefen
    Get-sqmDiskBlockSize -Drive 'F', 'G', 'H'
```n
### Get-sqmDiskInfoByDriveLetter

Returns disk information for a given drive letter.

**Parameters:** -DriveLetter, -NoClipboard

**Example:**

```powershell
Get-sqmDiskInfoByDriveLetter -DriveLetter "C"

    Returns disk information for drive C: and copies it to the clipboard.
```n
### Get-sqmOrphanedFiles

Finds MDF/LDF/NDF database files that are not assigned to any database.

**Parameters:** -SqlInstance, -SqlCredential, -SearchPath, -FileExtension, -Recurse, -EnableException

**Example:**

```powershell
Get-sqmOrphanedFiles -SqlInstance "SQL01"
```n
## 11. Module & Update Management

### Install-sqmAdModule

Ensures that the ActiveDirectory PowerShell module (RSAT) is installed.

**Parameters:** -SkipIfPresent, -ContinueOnError, -EnableException, -WhatIf, -Confirm

**Example:**

```powershell
Install-sqmAdModule

    Checks whether the AD module is present and installs it if necessary.
```n
### Test-sqmModuleUpdate

Checks all configured update sources for a newer sqmSQLTool version.

**Parameters:** -Source, -RepositoryPath, -EnableException

**Example:**

```powershell
Test-sqmModuleUpdate
```n
### Test-sqmUpdateViaGitHub

Checks if a newer version of sqmSQLTool is available on GitHub.

**Parameters:** -Owner, -Repository, -EnableException

**Example:**

```powershell
Test-sqmUpdateViaGitHub
```n
### Test-sqmUpdateViaPSGallery

Checks if a newer version of sqmSQLTool is available on PowerShell Gallery.

**Parameters:** -ModuleName, -EnableException

**Example:**

```powershell
Test-sqmUpdateViaPSGallery
```n
### Test-sqmUpdateViaUNC

Checks if a newer version of sqmSQLTool is available on a UNC share.

**Parameters:** -RepositoryPath, -EnableException

**Example:**

```powershell
Test-sqmUpdateViaUNC
```n
### Update-sqmModule

Updates the sqmSQLTool module from GitHub, PSGallery or a UNC share.

**Parameters:** -Source, -RepositoryPath, -Destination, -Force, -EnableException

**Example:**

```powershell
Update-sqmModule
```n
## 16. SQL Drivers & Tools Installation

### Install-sqmDb2Driver

Installiert den IBM DB2 ODBC/CLI-Treiber.

**Parameters:** -SourcePath

**Example:**

```powershell
Install-sqmDb2Driver -SourcePath '\\srv\Treiber\DB2'
```n
### Install-sqmJdbcDriver

Installiert den Microsoft JDBC Driver for SQL Server.

**Parameters:** -SourcePath, -DestinationPath, -UpdateClassPath

**Example:**

```powershell
Install-sqmJdbcDriver -SourcePath '\\srv\Treiber\JDBC'
```n
### Install-sqmOdbcDriver

Installiert den Microsoft ODBC Driver for SQL Server.

**Parameters:** -SourcePath, -DriverName

**Example:**

```powershell
Install-sqmOdbcDriver -SourcePath '\\srv\Treiber\ODBC'
```n
### Uninstall-sqmDb2Driver

Deinstalliert den IBM DB2 ODBC/CLI-Treiber.

**Example:**

```powershell
Uninstall-sqmDb2Driver
```n
### Uninstall-sqmJdbcDriver

Deinstalliert den Microsoft JDBC Driver for SQL Server.

**Parameters:** -RemoveClassPath

**Example:**

```powershell
Uninstall-sqmJdbcDriver
```n
### Uninstall-sqmOdbcDriver

Deinstalliert den Microsoft ODBC Driver for SQL Server.

**Parameters:** -DriverName

**Example:**

```powershell
Uninstall-sqmOdbcDriver
```n
## 19. External Systems Integration

### Invoke-sqmSplunkConfiguration

Configures the Splunk Universal Forwarder on SQL Server hosts.

**Parameters:** -Mode, -Remote, -SearchOU, -ComputerList, -Credential, -LogPath, -LogCallback

**Example:**

```powershell
Invoke-sqmSplunkConfiguration
```n
### Test-sqmTsmConnection

Tests the connection to an IBM Spectrum Protect (TSM) server using dsmadmc.

**Parameters:** -ComputerName, -DsmadmcPath, -UserName, -Password, -ServerName, -DsmOptPath, -Credential, -EnableException

**Example:**

```powershell
Test-sqmTsmConnection
```n
## 13. SQL Agent & Proxy Jobs

### Get-sqmAgentJobHistory

Displays the execution history of SQL Agent jobs.

**Parameters:** -SqlInstance, -SqlCredential, -JobName, -Status, -Since, -LastX, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmAgentJobHistory
```n
### New-sqmAgentProxy

Erstellt einen SQL Server Credential und einen SQL Agent Proxy und verbindet beide.

**Parameters:** -SqlInstance, -SqlCredential, -CredentialName, -ProxyName, -ProxyDescription, -WindowsCredential, -WindowsUserName, -Subsystem, -Force, -EnableException

**Example:**

```powershell
# Einzeiler - Credential-Dialog erscheint automatisch
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SqlServiceAccount" `
        -ProxyName "SSIS Proxy"

    # Credential direkt uebergeben - kein Dialog
    $cred = Get-Credential "DOMAIN\SvcSSIS"
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Proxy" -WindowsCredential $cred
```n
### New-sqmAlwaysOnRepairJob

Creates a SQL Server Agent job that runs Repair-Job.ps1 (AutoRepair).

**Parameters:** -SqlInstance, -JobName, -Force

**Example:**

```powershell
New-sqmAlwaysOnRepairJob -SqlInstance "SQL01"
#>
function New-sqmAlwaysOnRepairJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmAlwaysOnRepair',
		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	process
	{
		# Setup output directory with proper permissions FIRST
		$outputPath = "C:\System\WinSrvLog\MSSQL"
		if (-not (Test-Path $outputPath)) {
			New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
		}
		# Grant permissions to SQL Agent service accounts
		@('NT SERVICE\MSSQLSERVER', 'NT SERVICE\SQLSERVERAGENT') | ForEach-Object {
			$null = icacls $outputPath /grant "$_`:F" /T /C 2>&1
		}

		# Check if job exists
		$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction SilentlyContinue
		if ($existingJob -and -not $Force)
		{
			throw "Job '$JobName' existiert bereits. -Force zum Ueberschreiben."
		}
		if ($existingJob -and $Force)
		{
			Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -Confirm:$false -ErrorAction Stop
		}

		# Create job
		$job = New-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName `
			-Description "AutoRepair: Repariert AlwaysOn-Datenbanken" -ErrorAction Stop

		# Create CmdExec job step (calls Repair-Job.ps1)
		$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
		$repairScriptPath = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\Repair-Job.ps1'
		$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$repairScriptPath`""

		$jobStep = New-DbaAgentJobStep -SqlInstance $SqlInstance -Job $JobName `
			-StepName "RunRepair" -Subsystem 'CmdExec' -Command $command -ErrorAction Stop

		# Add hourly schedule
		$schedName = "sch_$JobName"
		$schedSql = @"
DECLARE @sid INT;
WHILE EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'$schedName')
BEGIN
    SELECT TOP (1) @sid = schedule_id FROM msdb.dbo.sysschedules WHERE name = N'$schedName';
    EXEC msdb.dbo.sp_delete_schedule @schedule_id = @sid, @force_delete = 1;
END
EXEC msdb.dbo.sp_add_schedule
    @schedule_name          = N'$schedName',
    @enabled                = 1,
    @freq_type              = 4,
    @freq_interval          = 1;
EXEC msdb.dbo.sp_attach_schedule @job_name = N'$JobName', @schedule_name = N'$schedName';
"@
		$null = Invoke-DbaQuery -SqlInstance $SqlInstance -Database msdb -Query $schedSql -ErrorAction Stop

		[PSCustomObject]@{
			SqlInstance = $SqlInstance
			JobName     = $JobName
			Status      = "Success"
			Message     = "Job created"
			Timestamp   = Get-Date
		}
	}
}
```n
### New-sqmAutoLoginSyncJob

Creates a SQL Agent job that runs Sync-Job.ps1 (AutoSync).

**Parameters:** -SqlInstance, -JobName, -Force

**Example:**

```powershell
New-sqmAutoLoginSyncJob -SqlInstance "SQL01"
#>
function New-sqmAutoLoginSyncJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmAutoLoginSync',
		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	process
	{
		# Setup output directory with proper permissions FIRST
		$outputPath = "C:\System\WinSrvLog\MSSQL"
		if (-not (Test-Path $outputPath)) {
			New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
		}
		# Grant permissions to SQL Agent service accounts
		@('NT SERVICE\MSSQLSERVER', 'NT SERVICE\SQLSERVERAGENT') | ForEach-Object {
			$null = icacls $outputPath /grant "$_`:F" /T /C 2>&1
		}

		# Check if job exists
		$existingJob = Get-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -ErrorAction SilentlyContinue
		if ($existingJob -and -not $Force)
		{
			throw "Job '$JobName' existiert bereits. -Force zum Ueberschreiben."
		}
		if ($existingJob -and $Force)
		{
			Remove-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName -Confirm:$false -ErrorAction Stop
		}

		# Create job
		$job = New-DbaAgentJob -SqlInstance $SqlInstance -Job $JobName `
			-Description "AutoSync: Synchronisiert Logins ueber AlwaysOn-Replicas" -ErrorAction Stop

		# Create CmdExec job step (calls Sync-Job.ps1)
		$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
		$syncScriptPath = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\Sync-Job.ps1'
		$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$syncScriptPath`""

		$jobStep = New-DbaAgentJobStep -SqlInstance $SqlInstance -Job $JobName `
			-StepName "RunSync" -Subsystem 'CmdExec' -Command $command -ErrorAction Stop

		# Add daily schedule (2:00 AM)
		$schedName = "sch_$JobName"
		$schedSql = @"
DECLARE @sid INT;
WHILE EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'$schedName')
BEGIN
    SELECT TOP (1) @sid = schedule_id FROM msdb.dbo.sysschedules WHERE name = N'$schedName';
    EXEC msdb.dbo.sp_delete_schedule @schedule_id = @sid, @force_delete = 1;
END
EXEC msdb.dbo.sp_add_schedule
    @schedule_name          = N'$schedName',
    @enabled                = 1,
    @freq_type              = 4,
    @freq_interval          = 1,
    @active_start_time      = 020000;
EXEC msdb.dbo.sp_attach_schedule @job_name = N'$JobName', @schedule_name = N'$schedName';
"@
		$null = Invoke-DbaQuery -SqlInstance $SqlInstance -Database msdb -Query $schedSql -ErrorAction Stop

		[PSCustomObject]@{
			SqlInstance = $SqlInstance
			JobName     = $JobName
			Status      = "Success"
			Message     = "Job created"
			Timestamp   = Get-Date
		}
	}
}
```n
## 1. Always On & Availability Groups

### Add-sqmDatabaseToAG

Adds one or more databases to an Always On availability group (AutoSeed).

**Parameters:** -SqlInstance, -SqlCredential, -AvailabilityGroup, -Database, -All, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -Database "SalesDB"
```n
### Add-sqmDatabaseToDistributedAg

Adds a database to a Distributed AlwaysOn Availability Group.

**Parameters:** -SqlInstance, -AvailabilityGroupName, -DatabaseName, -SecondaryInstance, -BackupPath, -SqlCredential, -EnableException

**Example:**

```powershell
Add-sqmDatabaseToDistributedAg -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -DatabaseName "MyDb" -SecondaryInstance "DR-SQL01"
```n
### Compare-sqmAlwaysOnLogins

Vergleicht die Logins aller Replicas einer AlwaysOn Availability Group.

**Parameters:** -SqlInstance, -AvailabilityGroupName, -SqlCredential, -IncludeSystemLogins, -Login, -ExcludeLogin, -OnlyDifferences, -OutputPath, -NoOpen, -FailOnDrift, -ContinueOnError, -EnableException

**Example:**

```powershell
Compare-sqmAlwaysOnLogins -SqlInstance "SQL01"
```n
### Complete-sqmListenerMigration

Completes listener migration after cluster team recreates the listener resource.

**Parameters:** -SqlInstance, -AvailabilityGroupName, -ListenerName, -OutputPath, -EnableException

**Example:**

```powershell
# STEP 1: DBA runs Invoke-sqmListenerMigrationPrep
    # STEP 2: AD team deletes/recreates listener role (15-30 min wait)
    # STEP 3: DBA runs this function

    Complete-sqmListenerMigration -SqlInstance "SQL02" -AvailabilityGroupName "ProdAG" -ListenerName "PROD-SQL-Listener"
```n
### Export-sqmAlwaysOnConfiguration

Exports the complete AlwaysOn AG configuration for one or more SQL Server instances.

**Parameters:** -SqlInstance, -SqlCredential, -OutputPath, -NoWarning, -NoOpen, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01"
	# Exports all AGs from SQL01, warns if ReadableSecondary != NO
```n
### Get-sqmAlwaysOnFailoverHistory

Ermittelt AlwaysOn-Failover-Ereignisse aus dem Windows Event Log.

**Parameters:** -ComputerName, -SqlInstance, -SqlCredential, -AvailabilityGroup, -Since, -IncludeClusterLog, -OutputPath, -ContinueOnError, -EnableException

**Example:**

```powershell
Get-sqmAlwaysOnFailoverHistory
```n
### Get-sqmAlwaysOnHealthReport

Creates a detailed health report for all Always On availability groups on an instance.

**Parameters:** -SqlInstance, -SqlCredential, -MaxRedoQueueMB, -MaxSendQueueMB, -OutputPath, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Get-sqmAgHealthReport
```n
### Get-sqmDistributedAgHealth

Creates a detailed health report for Distributed AlwaysOn Availability Groups.

**Parameters:** -SqlInstance, -SqlCredential, -OutputPath, -ContinueOnError, -EnableException

**Example:**

```powershell
Get-sqmDistributedAgHealth -SqlInstance "SQL01"
```n
### Invoke-sqmDistributedFailover

Initiates failover of a Distributed AlwaysOn AG.

**Parameters:** -SqlInstance, -SqlCredential, -AvailabilityGroupName, -Force, -Rollback, -WhatIf, -OutputPath, -EnableException

**Example:**

```powershell
Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -Force
```n
### Invoke-sqmFailover

Performs a controlled AlwaysOn AG failover with pre- and post-checks.

**Parameters:** -SqlInstance, -SqlCredential, -AvailabilityGroup, -TargetReplica, -MaxRedoQueueMB, -WaitAfterFailoverSeconds, -ContinueOnError, -EnableException

**Example:**

```powershell
Invoke-sqmFailover -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -WhatIf
```n
### Invoke-sqmSqlAlwaysOnAutoseeding

Enables Automatic Seeding on all replicas of an Always On Availability Group.

**Parameters:** -SqlInstance, -SqlCredential, -AvailabilityGroup, -All, -EnableException

**Example:**

```powershell
# Uses the current computer name as default
Invoke-sqmSqlAlwaysOnAutoseeding
```n
### Move-sqmAlwaysOnListener

Migrates an AG Listener from one Availability Group to another.

**Parameters:** -SqlInstance, -SourceAgName, -TargetAgName, -TargetInstance, -ListenerName, -SqlCredential, -WhatIf, -OutputPath, -EnableException

**Example:**

```powershell
# Move listener from Primary AG to Secondary AG (before failover)
    Move-sqmAgListener -SqlInstance "SQL01" -SourceAgName "ProductionAG" `
        -TargetAgName "DrAG" -TargetInstance "DR-SQL01"
```n
### New-sqmDistributedAvailabilityGroup

Creates a new Distributed AlwaysOn Availability Group.

**Parameters:** -PrimaryInstance, -PrimaryAgName, -SecondaryInstance, -SecondaryAgName, -SqlCredential, -EnableAutoSeed, -SeedingMode, -OutputPath, -EnableException

**Example:**

```powershell
New-sqmDistributedAvailabilityGroup `
        -PrimaryInstance   "SQL01" `
        -PrimaryAgName     "ProductionAG" `
        -PrimaryFqdn       "SQL01.domain.local" `
        -SecondaryInstance "DR-SQL01" `
        -SecondaryAgName   "DrAG" `
        -SecondaryFqdn     "DR-SQL01.domain.local" `
        -ServiceAccount    "DOMAIN\SqlServiceAccount" `
        -SeedingMode       Automatic
```n
### Prepare-sqmListenerForMigration

Prepares an AG listener for cluster-level migration without downtime.

**Parameters:** -SqlInstance, -AvailabilityGroupName, -ListenerName, -SqlCredential, -OutputPath, -EnableException

**Example:**

```powershell
# STEP 1: Prepare listener before AD team deletes it
    Invoke-sqmListenerMigrationPrep -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"

    # STEP 2: Wait 15 minutes for DNS/application timeout

    # STEP 3: AD team deletes old listener role and creates new one

    # STEP 4: You run Complete-sqmListenerMigration
```n
### Remove-sqmDatabaseFromAG

Removes one or more databases from their Always On Availability Group.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -All, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
# Remove a single database from its AG
Remove-sqmDatabaseFromAG -Database "SalesDB"
```n
### Repair-sqmAlwaysOnDatabases

Checks all AlwaysOn databases for problems and repairs them (Remove -> Cleanup -> Add).

**Parameters:** -SqlInstance, -SqlCredential, -Force, -EnableException, -WhatIf

**Example:**

```powershell
Automatically repairs all problematic AG databases.
Repair-sqmAlwaysOnDatabases
```n
### Sync-sqmLoginsToAlwaysOn

Synchronizes logins from the primary replica to all secondary replicas in an AlwaysOn Availability Group.

**Parameters:** -SqlInstance, -AvailabilityGroupName, -SqlCredential, -SourceCredential, -DestinationCredential, -Login, -ExcludeLogin, -IncludeSystemLogins, -AdjustAuthMode, -RestartServiceIfRequired, -DisablePolicy, -SkipSecondaryServers, -Force, -ForceIncludeOnly, -ForceExclude, -SafeForceMode, -BackupLogins, -BackupPath, -BackupRetentionDays, -AuditAdOrphans, -EnableException

**Example:**

```powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"
    Syncs all logins from primary to all secondaries in ProdAG.
```n
### Test-sqmDistributedAgReadiness

Tests Distributed AlwaysOn AG readiness for failover.

**Parameters:** -SqlInstance, -SqlCredential, -TargetInstance, -OutputPath, -EnableException

**Example:**

```powershell
Test-sqmDistributedAgReadiness -SqlInstance "SQL01" -TargetInstance "DR-SQL01"
```n
## 18. SSIS Configuration

### Test-sqmSSISPackageCompatibility

Validates SSIS package compatibility for SQL Server upgrades (2016 - 2025).

**Parameters:** -SqlInstance, -SqlCredential, -FolderName, -PackagePath, -Recurse, -TargetVersion, -OutputPath, -EnableException

**Example:**

```powershell
# Check deployed packages on target server
    Test-sqmSSISPackageCompatibility -SqlInstance "NewServer2025" -TargetVersion 2025
```n
## 21. Analysis Services (SSAS)

### Test-sqmSsasDirectoryPermissions

Checks and corrects NTFS permissions for SSAS directories (Data, Log, Temp, Backup).

**Parameters:** -InstanceName, -ServiceAccount, -WhatIf, -Confirm, -EnableException, -ContinueOnError

**Example:**

```powershell
Test-sqmSsasDirectoryPermissions

    Checks the directories of the default SSAS instance and corrects missing permissions.
```n
## 2. Performance Analysis & Optimization

### Get-sqmIndexFragmentation

Analyzes index fragmentation in one or more databases.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -TableName, -MinFragmentationPercent, -PageCountMin, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmIndexFragmentation -Database 'AdventureWorks' -MinFragmentationPercent 10
```n
### Get-sqmMissingIndexes

Retrieves missing index recommendations from the SQL Server DMV cache.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -MinImpactScore, -MinSeeks, -Top, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmMissingIndexes -SqlInstance "SQL01"
```n
### Get-sqmWaitStatistics

Reads and analyzes SQL Server wait statistics from sys.dm_os_wait_stats.

**Parameters:** -SqlInstance, -SqlCredential, -TopN, -IncludeIdle, -SnapshotBefore, -SaveSnapshot, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmWaitStatistics -SqlInstance "SQL01" -TopN 20
```n
### Invoke-sqmPerfBaseline

Creates, compares or lists performance baselines (wait stats + perf counters).

**Parameters:** -SqlInstance, -SqlCredential, -Action, -BaselineName, -BaselineA, -BaselineB, -OutputPath, -EnableException

**Example:**

```powershell
# Capture baseline
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -BaselineName "before_patch"
```n
### Invoke-sqmQueryStore

Configures the Query Store, reads from it, detects issues and saves reports.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -All, -Configure, -Query, -Diagnose, -OperationMode, -FlushIntervalSeconds, -IntervalLengthMinutes, -MaxStorageSizeMB, -QueryCaptureMode, -SizeBasedCleanupMode, -MaxPlansPerQuery, -TopN, -OrderBy, -LookbackHours, -MinExecutionCount, -StorageWarningPct, -MaxPlansWarning, -OutputPath, -EnableException

**Example:**

```powershell
# Report for all databases (Query + Diagnose)
    Invoke-sqmQueryStore -All
```n
### Test-sqmCostThreshold

Prueft ob CostThresholdForParallelism auf dem empfohlenen Wert liegt.

**Parameters:** -SqlInstance, -SqlCredential, -MinRecommendedValue, -EnableException

**Example:**

```powershell
Test-sqmCostThreshold -SqlInstance "SQL01"
```n
### Test-sqmMaxDop

Prueft ob MAXDOP (Max Degree of Parallelism) korrekt konfiguriert ist.

**Parameters:** -SqlInstance

**Example:**

```powershell
Test-sqmMaxDop -SqlInstance 'MSSQLSERVER'
```n
### Test-sqmMaxMemory

Prueft ob SQL Server Max Server Memory korrekt konfiguriert ist.

**Parameters:** -SqlInstance, -RecommendedPct

**Example:**

```powershell
Test-sqmMaxMemory -SqlInstance 'MSSQLSERVER'
```n
### Get-sqmTempDbRecommendation

Analyzes the TempDB configuration and provides optimization recommendations.

**Parameters:** -SqlInstance, -SqlCredential, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmTempDbRecommendation -SqlInstance "SQL01"
#>
function Get-sqmTempDbRecommendation
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
	}
	
	process
	{
		try
		{
			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
			$tempdb = $server.Databases['tempdb']
			$cpuCount = $server.Processors
			$idealFileCount = [Math]::Min($cpuCount, 8)
			
			$files = $tempdb.FileGroups[0].Files
			$fileCount = $files.Count
			$fileSizeMB = $files | ForEach-Object { [math]::Round($_.Size / 1024, 2) }
			$fileGrowth = $files.ForEach('Growth') | ForEach-Object { ($_ / 1024) } # in MB
			$growthTypes = $files.ForEach('GrowthType')
			$paths = $files.ForEach('FileName') | ForEach-Object { Split-Path $_ -Parent }
			
			# Bewertung
			$status = 'OK'
			$messages = [System.Collections.Generic.List[string]]::new()
			if ($fileCount -ne $idealFileCount)
			{
				$status = 'Warning'
				$messages.Add("Anzahl TempDB-Dateien: $fileCount (empfohlen $idealFileCount).")
			}
			$sizeDifferences = ($fileSizeMB | Select-Object -Unique).Count -gt 1
			if ($sizeDifferences)
			{
				$status = 'Warning'
				$messages.Add("TempDB-Dateien haben unterschiedliche Groessen: $($fileSizeMB -join ', ') MB.")
			}
			$hasPercent = $growthTypes -contains 'Percent'
			if ($hasPercent)
			{
				$status = 'Warning'
				$messages.Add("Autogrow in Prozent wird verwendet (MB empfohlen).")
			}
			$hasLargeGrow = $fileGrowth -gt 1024
			if ($hasLargeGrow)
			{
				$status = 'Warning'
				$messages.Add("Autogrow-Schrittweite >1024 MB: $($fileGrowth -join ', ') MB.")
			}
			$uniquePaths = $paths | Select-Object -Unique
			if ($uniquePaths.Count -eq 1)
			{
				$messages.Add("Alle TempDB-Dateien liegen auf demselben Laufwerk ($($uniquePaths[0])) - fuer optimale Leistung separate Laufwerke empfehlenswert.")
				if ($status -eq 'OK') { $status = 'Info' }
			}
			if ($messages.Count -eq 0) { $messages.Add("TempDB-Konfiguration ist optimal.") }
			
			$result = [PSCustomObject]@{
				SqlInstance	     = $SqlInstance
				Status		     = $status
				FileCount	     = $fileCount
				RecommendedCount = $idealFileCount
				FileSizesMB	     = $fileSizeMB
				GrowthMB		 = $fileGrowth
				Paths		     = $paths
				Recommendations  = ($messages -join ' ')
			}
			
			if ($OutputPath) { $result | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Force }
			return $result
		}
		catch
		{
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return $null
		}
	}
}
```n
### Test-sqmTempDbFileCount

Prueft ob die Anzahl der TempDB-Datendateien der empfohlenen CPU-Anzahl entspricht.

**Parameters:** -SqlInstance, -SqlCredential, -MaxFiles, -EnableException

**Example:**

```powershell
Test-sqmTempDbFileCount -SqlInstance "SQL01"
```n
## 6. Certificates & TLS Security

### Get-sqmCertificateReport

Creates a comprehensive report on SQL Server certificates and their expiration dates.

**Parameters:** -SqlInstance, -SqlCredential, -WarningThresholdDays, -CriticalThresholdDays, -IncludeUserDatabases, -OutputPath, -ContinueOnError, -EnableException

**Example:**

```powershell
Get-sqmCertificateReport
```n
### New-sqmSqlCertificate

Creates a new self-signed SQL Server certificate as a renewal of an existing one.

**Parameters:** -SqlInstance, -SqlCredential, -CertificateName, -Database, -NewCertificateName, -ValidityYears, -BackupPath, -BackupEncryptionPassword, -RenameOldCertificate, -BindEndpoint, -BindTde, -EnableException

**Example:**

```powershell
# Simple renewal without automatic binding
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "AG_CERT" -BackupEncryptionPassword (Read-Host -AsSecureString)
```n
### Set-sqmSqlTlsCertificate

Binds a Windows certificate from the Machine store to SQL Server as the TLS certificate.

**Parameters:** -SqlInstance, -Thumbprint, -ForceEncryption, -Restart, -WhatIf, -Confirm

**Example:**

```powershell
Set-sqmSqlTlsCertificate -SqlInstance "SQL01" -Thumbprint "A1B2C3D4E5F6..."

    Binds the specified certificate to the default instance on SQL01.
    Service restart must be performed manually.
```n
### Set-sqmSsrsHttpsCertificate

Binds a Windows certificate to SSRS or Power BI Report Server for HTTPS access.

**Parameters:** -ComputerName, -Thumbprint, -Port, -InstanceName, -IPAddress, -RequireSSL, -Credential, -WhatIf, -Confirm

**Example:**

```powershell
Set-sqmSsrsHttpsCertificate -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"

		Binds the specified certificate to SSRS on the local machine on port 443.
		The SSRS instance is auto-detected.
```n
### Get-sqmTlsStatus

Audits TLS/SSL configuration and certificate status for all SQL Server instances on one or more computers.

**Parameters:** -ComputerName, -Credential, -OutputPath, -WarnDaysBeforeExpiry

**Example:**

```powershell
Get-sqmTlsStatus

    Audits all SQL Server instances on the local computer and saves results to the default log folder.
```n
## 15. Extended Events & Diagnostics

### Get-sqmDeadlockReport

Reads and analyzes deadlock events from the System Health Extended Event session.

**Parameters:** -SqlInstance, -SqlCredential, -StartTime, -EndTime, -MaxDeadlocks, -OutputPath, -EnableException

**Example:**

```powershell
Get-sqmDeadlockReport
```n
### Invoke-sqmExtendedEvents

Manages Extended Events sessions for performance analysis on SQL Server.

**Parameters:** -SqlInstance, -SqlCredential, -SessionName, -Template, -SlowQueryThresholdMs, -WaitTypes, -TargetType, -TargetFilePath, -MaxFileSizeMB, -MaxRolloverFiles, -RingBufferMaxMB, -MaxEventsRead, -LookbackMinutes, -TopN, -OutputPath, -Create, -Start, -Stop, -Read, -Diagnose, -Drop, -EnableException

**Example:**

```powershell
# Create AllInOne session and start immediately
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Create -Start
```n
### Invoke-sqmMonitoringKey

Gets or sets monitoring registry values for the sqmSQLTool on one or more computers.

**Parameters:** -ComputerName, -Operation, -SQL, -SQLFreeSpaceVersion, -TSM, -RegistryBase, -AutoDetectSQLFreeSpaceVersion, -Credential, -ContinueOnError, -EnableException

**Example:**

```powershell
Invoke-sqmMonitoringKey
```n
## 9. Database Maintenance

### Find-sqmDatabaseObject

Searches all (or selected) databases on an instance for an object name.

**Parameters:** -SqlInstance, -SqlCredential, -ObjectName, -ObjectType, -Database, -IncludeSystem, -SearchDefinition, -EnableException

**Example:**

```powershell
Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "sp_GetOrders"
```n
### Invoke-sqmLogShrink

Shrinks the transaction log file (LDF) of one or more databases.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -All, -ShrinkTargetPercent, -MinTargetMB, -ContinueOnError, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
Invoke-sqmLogShrink -Database "MyDB" -ShrinkTargetPercent 20
```n
### Invoke-sqmSetDatabaseRecoveryMode

Changes the recovery mode of one or more user databases.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -All, -RecoveryMode, -EnableException, -Confirm, -WhatIf

**Example:**

```powershell
# Set all user databases to Full (without prompting)
Invoke-sqmSetDatabaseRecoveryMode -All -RecoveryMode Full
```n
### Invoke-sqmUpdateStatistics

Updates statistics in one or more databases.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -Table, -Statistics, -SamplePercent, -OnlyModified, -Index, -WhatIf, -EnableException

**Example:**

```powershell
Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 10
```n
### Set-sqmDatabaseOwner

Sets the owner of one or more databases to a uniform login.

**Parameters:** -SqlInstance, -SqlCredential, -Database, -ExcludeDatabase, -OwnerLogin, -IncludeSystemDatabases, -Force, -OutputPath, -ContinueOnError, -EnableException

**Example:**

```powershell
# Set sa account on all user databases
    Set-sqmDatabaseOwner -SqlInstance "SQL01"
```n
## 22. Monitoring & Registry

### Enable-sqmMonitoringAccess

Richtet einen Monitoring-Account auf allen SQL Server-Instanzen eines Computers ein.

**Parameters:** -ComputerName, -MonitoringUser, -ServerRoleName, -DatabaseRoleName, -PolicyName, -OutputPath, -SqlCredential, -ContinueOnError, -EnableException

**Example:**

```powershell
Enable-sqmMonitoringAccess -MonitoringUser "CORP\SvcMonitoring"
```n
### Invoke-sqmMonitoringKey

Gets or sets monitoring registry values for the sqmSQLTool on one or more computers.

**Parameters:** -ComputerName, -Operation, -SQL, -SQLFreeSpaceVersion, -TSM, -RegistryBase, -AutoDetectSQLFreeSpaceVersion, -Credential, -ContinueOnError, -EnableException

**Example:**

```powershell
Invoke-sqmMonitoringKey
```n
### Invoke-sqmPatchAnalysis

Compares the installed SQL Server version with known CU/SP builds.

**Parameters:** -SqlInstance, -SqlCredential, -OutputPath, -EnableException

**Example:**

```powershell
Invoke-sqmPatchAnalysis -SqlInstance "SQL01"
```n
## 20. Script Execution & Deployment

### Invoke-sqmDeployScripts

Executes numbered SQL scripts from a directory sequentially against a SQL Server database.

**Parameters:** -SqlInstance, -Database, -ScriptPath, -LogPath, -JobNumber, -QueryTimeout, -SkipBackup, -NoWrapTransaction, -SqlCredential

**Example:**

```powershell
# Basic deploy with automatic backup
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy"
```n
### Invoke-sqmSignModule

Signs all PowerShell script files in a module directory using Set-AuthenticodeSignature.

**Parameters:** -ModulePath, -CertificateThumbprint, -CertificatePath, -CertificatePassword, -TimestampServer, -IncludeExtensions, -Force

**Example:**

```powershell
# 1. Sign with a specific certificate from the store
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" `
        -CertificateThumbprint "AB12CD34EF56..."
```n
### Copy-sqmToCentralPath

Copies one or more files to the configured CentralPath.

