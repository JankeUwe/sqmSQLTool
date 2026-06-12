# sqmSQLTool Complete User Manual

**Version:** 2.0  
**Module Version:** See Get-Module sqmSQLTool  
**Language:** English  
**Last Updated:** 2026-06-12

---

## 📖 Introduction

sqmSQLTool is a comprehensive enterprise-grade PowerShell module for SQL Server administration, featuring:

- **Always On & Availability Groups** - Complete AG lifecycle management, listener migration, distributed AG setup
- **Performance Management** - Index analysis, missing indexes, wait statistics, query store integration
- **Backup & Recovery** - Automated backup jobs, restore operations, integrity verification
- **Security & Compliance** - Login management, AD integration, TLS/certificate handling, audit logging
- **Monitoring & Reporting** - Real-time health checks, blocking analysis, deadlock detection, hardware reports
- **Configuration** - Server comparison, collation changes, configuration snapshots, recovery mode management
- **SQL Agent Automation** - Proxy configuration, job creation, automated maintenance jobs

---

## 🎯 Quick Start

\\\powershell
# Import the module
Import-Module sqmSQLTool -Force

# Get module version and configuration
Get-Module sqmSQLTool
Get-sqmConfig

# Example: Check AlwaysOn health on a production instance
Get-sqmAlwaysOnHealthReport -SqlInstance "SQL-PROD-01"

# Example: List all missing indexes
Get-sqmMissingIndexes -SqlInstance "SQL-PROD-01" -Database "MyDatabase" | Export-Csv c:\reports\missing_indexes.csv
\\\

---

## 📑 Organization

This manual is organized by **business domain**, not technical verb-noun patterns:

| Category | Functions | Use Case |
|----------|-----------|----------|
| 14. Active Directory Integration | 4 | Domain-specific functions |
| 10. Reporting & Analysis | 5 | Domain-specific functions |
| 3. Backup & Recovery | 10 | Domain-specific functions |
| 7. Configuration Management | 7 | Domain-specific functions |
| 17. SSRS Configuration | 3 | Domain-specific functions |
| 5. Login & User Security | 8 | Domain-specific functions |
| 12. Server Configuration Testing | 5 | Domain-specific functions |
| 4. Monitoring & Health Checks | 8 | Domain-specific functions |
| 8. Storage & Disk Management | 6 | Domain-specific functions |
| 11. Module & Update Management | 6 | Domain-specific functions |
| 16. SQL Drivers & Tools Installation | 6 | Domain-specific functions |
| 19. External Systems Integration | 3 | Domain-specific functions |
| 13. SQL Agent & Proxy Jobs | 4 | Domain-specific functions |
| 1. Always On & Availability Groups | 18 | Domain-specific functions |
| 18. SSIS Configuration | 2 | Domain-specific functions |
| 21. Analysis Services (SSAS) | 1 | Domain-specific functions |
| 2. Performance Analysis & Optimization | 10 | Domain-specific functions |
| 6. Certificates & TLS Security | 8 | Domain-specific functions |
| 15. Extended Events & Diagnostics | 3 | Domain-specific functions |
| 9. Database Maintenance | 5 | Domain-specific functions |
| 22. Monitoring & Registry | 3 | Domain-specific functions |
| 20. Script Execution & Deployment | 3 | Domain-specific functions |

---

## 📚 Function Reference by Category

# 14. Active Directory Integration

This section covers **4 functions** related to Active Directory Integration.


## Get-sqmADAccountStatus

**Checks the status of an Active Directory user account.**

### Description

Determines the account status using the ActiveDirectory module (RSAT) with
        automatic fallback to ADSI if RSAT is not available.
        Returns a detailed PSObject with Enabled, LockedOut, PasswordExpired
        and AccountExpired.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SamAccountName | *object* | * | The SamAccountName of the AD account to check. |
| -DomainController | *object* | * | Optional target DC. Only used via the RSAT path. |

### Examples

**Example 1:**
\\\powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe'
\\\`n
**Example 2:**
\\\powershell
'jdoe','jsmith' | Get-sqmADAccountStatus
\\\`n
**Example 3:**
\\\powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe' -DomainController 'DC01'
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $SamAccountName,

        [Parameter()]
        [string] $DomainController
    )

    begin {
        #region --- Modul-Verfuegbarkeit einmalig pruefen ---
        $useRSAT = $false
        if (Get-Module -Name ActiveDirectory -ListAvailable) {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $useRSAT = $true
                Write-Verbose 'ActiveDirectory-Modul geladen (RSAT-Pfad aktiv).'
            }
            catch {
                Write-Verbose "ActiveDirectory-Modul nicht ladbar: $_  - Fallback auf ADSI."
            }
        }
        else {
            Write-Verbose 'ActiveDirectory-Modul nicht installiert - Fallback auf ADSI.'
        }

        # Hilfsfunktion: Ergebnis-Objekt erzeugen
        function New-ResultObject {
            param (
                [string]   $Sam,
                [bool]     $Enabled        = $false,
                [bool]     $LockedOut      = $false,
                [bool]     $PwdExpired     = $false,
                [bool]     $AcctExpired    = $false,
                [string]   $Source         = '',
                [string]   $ErrorMessage   = ''
            )
            [PSCustomObject]@{
                SamAccountName  = $Sam
                Enabled         = $Enabled
                LockedOut       = $LockedOut
                PasswordExpired = $PwdExpired
                AccountExpired  = $AcctExpired
                Source          = $Source
                QueryTime       = (Get-Date)
                ErrorMessage    = $ErrorMessage
            }
        }

        #region --- ADSI-Hilfsfunktion ---
        function Get-ADAccountStatusViaADSI {
            param ([string] $Sam)

            # Searcher aufbauen
            $searcher = [adsisearcher]"(sAMAccountName=$Sam)"
            $searcher.PropertiesToLoad.AddRange(@(
                'sAMAccountName',
                'userAccountControl',
                'lockoutTime',
                'pwdLastSet',
                'accountExpires',
                'msDS-UserPasswordExpiryTimeComputed'
            )) | Out-Null
            $searcher.SizeLimit = 1

            $entry = $searcher.FindOne()
            if (-not $entry) {
                throw "Konto '$Sam' wurde im Verzeichnis nicht gefunden."
            }

            $uac = [int]$entry.Properties['useraccountcontrol'][0]

            # Enabled: Bit 2 (0x0002) = disabled
            $enabled   = -not [bool]($uac -band 0x0002)

            # LockedOut: Bit 16 (0x0010) oder lockoutTime > 0
            $lockedBit = [bool]($uac -band 0x0010)
            $lockoutTimeRaw = $entry.Properties['lockouttime']
            $lockedTime = $false
            if ($lockoutTimeRaw.Count -gt 0) {
                $lt = [long]$lockoutTimeRaw[0]
                $lockedTime = ($lt -gt 0)
            }
            $lockedOut = $lockedBit -or $lockedTime

            # PasswordExpired: Bit 8388608 (0x800000) oder msDS-Attribut
            $pwdExpiredBit = [bool]($uac -band 0x800000)
            $pwdExpired = $pwdExpiredBit

            if (-not $pwdExpired) {
                $expiryRaw = $entry.Properties['msds-userpasswordexpirytimecomputed']
                if ($expiryRaw.Count -gt 0) {
                    $expiryFt = [long]$expiryRaw[0]
                    # 0 = laeuft nie ab, 9223372036854775807 = nie
                    if ($expiryFt -gt 0 -and $expiryFt -ne [long]::MaxValue) {
                        $expiryDate = [datetime]::FromFileTime($expiryFt)
                        $pwdExpired = ($expiryDate -lt (Get-Date))
                    }
                }
            }

            # AccountExpired
            $acctExpired = $false
            $acctExpiresRaw = $entry.Properties['accountexpires']
            if ($acctExpiresRaw.Count -gt 0) {
                $ae = [long]$acctExpiresRaw[0]
                # 0 und Int64.MaxValue bedeuten "laeuft nie ab"
                if ($ae -gt 0 -and $ae -ne [long]::MaxValue) {
                    $expDate = [datetime]::FromFileTime($ae)
                    $acctExpired = ($expDate -lt (Get-Date))
                }
            }

            return [PSCustomObject]@{
                Enabled         = $enabled
                LockedOut       = $lockedOut
                PasswordExpired = $pwdExpired
                AccountExpired  = $acctExpired
            }
        }
        #endregion
    }

    process {
        foreach ($sam in $SamAccountName) {
            Write-Verbose "Verarbeite Konto: $sam"

            #region --- RSAT-Pfad ---
            if ($useRSAT) {
                try {
                    $params = @{
                        Identity    = $sam
                        Properties  = @(
                            'Enabled',
                            'LockedOut',
                            'PasswordExpired',
                            'AccountExpirationDate'   # 'AccountExpired' ist keine abrufbare Property
                        )
                        ErrorAction = 'Stop'
                    }
                    if ($DomainController) { $params['Server'] = $DomainController }

                    $adUser = Get-ADUser @params

                    # AccountExpired: ExpirationDate vorhanden und in der Vergangenheit?
                    $acctExpired = ($null -ne $adUser.AccountExpirationDate) -and
                                   ($adUser.AccountExpirationDate -lt (Get-Date))

                    New-ResultObject `
                        -Sam         $sam `
                        -Enabled     ([bool]$adUser.Enabled) `
                        -LockedOut   ([bool]$adUser.LockedOut) `
                        -PwdExpired  ([bool]$adUser.PasswordExpired) `
                        -AcctExpired $acctExpired `
                        -Source      'RSAT'
                    continue
                }
                catch {
                    # Konto nicht gefunden ? direkt Fehlerobjekt, kein ADSI-Fallback
                    if ($_.Exception.GetType().Name -eq 'ADIdentityNotFoundException') {
                        New-ResultObject -Sam $sam -ErrorMessage "Konto nicht gefunden: $_" -Source 'RSAT'
                        continue
                    }
                    Write-Verbose "RSAT-Fehler fuer '$sam': $_ - Fallback auf ADSI."
                }
            }
            #endregion

            #region --- ADSI-Fallback ---
            try {
                $adsi = Get-ADAccountStatusViaADSI -Sam $sam

                New-ResultObject `
                    -Sam        $sam `
                    -Enabled    $adsi.Enabled `
                    -LockedOut  $adsi.LockedOut `
                    -PwdExpired $adsi.PasswordExpired `
                    -AcctExpired $adsi.AccountExpired `
                    -Source     'ADSI'
            }
            catch {
                New-ResultObject -Sam $sam -ErrorMessage $_.ToString() -Source 'ADSI'
            }
            #endregion
        }
    }
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmADGroupMembers

**Lists all members of an Active Directory group.**

### Description

Simple, reliable function to list members of an AD group (including nested groups).
    Useful when SQL Server access fails and you need to check group permissions.

    Supports NESTED GROUPS: Recursively resolves all members, including members of nested groups.
    Example: If GroupA contains GroupB (which contains User2), both GroupB and User2 are returned.

    Methods:
    1. Get-ADGroupMember -Recursive (if ActiveDirectory module available) — Resolves nested groups
    2. LDAP direct query (fallback, no module required) — Direct members only

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -GroupName | *object* | * | Name of the AD group. Pipeline-capable.     Format: "GroupName" or "DOMAIN\GroupName" |
| -Domain | *object* | * | Optional: AD domain (e.g., "FITS.LOCAL", "corp.de")     If not specified, auto-detects current domai |

### Returns

**Type:** PSCustomObject with GroupName, MemberCount, Members[], TxtFile, CsvFile, Status

### Examples

**Example 1:**
\\\powershell
Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"
\\\`n
**Example 2:**
\\\powershell
Get-sqmADGroupMembers -GroupName "Administrators" -Domain "FITS"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmHpuAllowGroup

**Searches for the HPU allow group in Active Directory based on configurable domain/group mappings.**

### Returns

**Type:** [string] DistinguishedName of the found group, or $null.

### Examples

**Example 1:**
\\\powershell
Get-sqmHpuAllowGroup
\\\`n
**Example 2:**
\\\powershell
Get-sqmHpuAllowGroup -EnableException
#>
function Get-sqmHpuAllowGroup
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name

    # ?? 1. Domain des lokalen Rechners ermitteln ????????????????????????????
    try
    {
        $currentDomain = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Domain
    }
    catch
    {
        $msg = "Domain konnte nicht ermittelt werden: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
        if ($EnableException) { throw $msg }
        return $null
    }

    Invoke-sqmLogging -Message "Starte $functionName. Lokale Domain: '$currentDomain'" `
                      -FunctionName $functionName -Level 'INFO'

    # ?? 2. Mapping aus der Konfiguration lesen ??????????????????????????????
    $domainGroupMap = Get-sqmConfig -Key 'HpuDomainGroupMap'

    if (-not $domainGroupMap -or $domainGroupMap.Count -eq 0)
    {
        $msg = "Konfigurationsschluessel 'HpuDomainGroupMap' ist nicht gesetzt. " +
               "Bitte Set-sqmConfig -HpuDomainGroupMap <...> ausfuehren."
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    # ?? 3. Passenden Mapping-Eintrag per Wildcard-Match suchen ?????????????
    $matchedEntry = $null
    foreach ($entry in $domainGroupMap)
    {
        if ($currentDomain -like $entry.DomainPattern)
        {
            $matchedEntry = $entry
            Invoke-sqmLogging -Message "Domain '$currentDomain' trifft Pattern '$($entry.DomainPattern)'." `
                              -FunctionName $functionName -Level 'INFO'
            break
        }
    }

    if (-not $matchedEntry)
    {
        $msg = "Kein Mapping-Eintrag fuer Domain '$currentDomain' gefunden."
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    $groupNamePattern = $matchedEntry.GroupNamePattern

    # ?? 4. AD-Suche ????????????????????????????????????????????????????????
    try
    {
        $ldapFilter = "(&(objectCategory=group)(sAMAccountName=*$groupNamePattern))"
        Invoke-sqmLogging -Message "LDAP-Filter: $ldapFilter" -FunctionName $functionName -Level 'INFO'

        $searcher                    = [adsisearcher]$ldapFilter
        $searcher.PageSize           = 20
        foreach ($prop in @('name', 'distinguishedname'))
        {
            $searcher.PropertiesToLoad.Add($prop) | Out-Null
        }

        $result = $searcher.FindOne()
    }
    catch
    {
        $msg = "AD-Suche fehlgeschlagen: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    # ?? 5. Ergebnis auswerten ???????????????????????????????????????????????
    if ($null -eq $result)
    {
        $msg = "Keine HPU-Allow-Gruppe '*$groupNamePattern' in Domain '$currentDomain' gefunden."
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    $dn = ($result.Properties['distinguishedname'])[0]
    Invoke-sqmLogging -Message "Gruppe gefunden: $dn" -FunctionName $functionName -Level 'INFO'
    return $dn
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Remove-sqmAdOrphanLogin

**Removes Windows logins whose Active Directory account no longer exists (AD orphans).**

### Description

Safe, deliberate cleanup of "dead" AD logins on a SQL Server instance. This is the manual
    counterpart to the detection-only -AuditAdOrphans option of New-sqmAutoLoginSyncJob and is
    intentionally NOT meant for unattended or scheduled use: a missing AD account can be a
    transient domain controller or trust problem, and dropping a valid login would cause an outage.

    Safety model:
    1. The ActiveDirectory module is REQUIRED. If it is missing, -AdModuleAction controls behavior
       (default 'Abort'). Without AD lookups orphans cannot be verified, so nothing is deleted.
    2. Only Windows logins (WINDOWS_LOGIN / WINDOWS_GROUP) are considered.
    3. System logins and ALL sysadmin logins are excluded from removal, always.
    4. A login is treated as an orphan ONLY when Active Directory positively reports the account as
       missing. If the AD query fails, the login is skipped (never deleted).
    5. Logins that own a database are skipped (dropping them would fail or orphan the ownership).
    6. Before removal a rollback script (CREATE LOGIN FROM WINDOWS + server role memberships) is
       written per run, unless -SkipBackup is set.
    7. Every removal honors -WhatIf / -Confirm (ConfirmImpact = High), so nothing is dropped silently.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the instance. |
| -ExcludeLogin | *object* | * | Additional logins to exclude from removal (wildcards allowed). Combined with the always-on     safet |
| -AdModuleAction | *object* | * | Behavior when the ActiveDirectory module is not present:         'Abort'   (default) - stop with an  |
| -BackupPath | *object* | * | Directory for the rollback script. Default: C:\System\WinSrvLog\MSSQL (created if missing). |
| -SkipBackup | *object* | * | Skip writing the rollback script. Not recommended. |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error status. |

### Examples

**Example 1:**
\\\powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -WhatIf
    Lists exactly which AD-orphaned logins would be removed, without changing anything.
\\\`n
**Example 2:**
\\\powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01"
    Removes confirmed AD-orphaned logins after a rollback backup, asking for confirmation per login.
\\\`n
**Example 3:**
\\\powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -ExcludeLogin 'DOMAIN\KeepThis*' -Confirm:$false
    Removes confirmed orphans (except the excluded pattern) without interactive confirmation.
\\\`n
### Best Practices

- Review audit logs after bulk changes
- Test permissions in non-prod first
- Maintain password policies compliance

---

# 10. Reporting & Analysis

This section covers **5 functions** related to Reporting & Analysis.


## Export-sqmDatabaseDocumentation

**Creates structured HTML and CSV documentation for all databases on a SQL Server instance.**

### Description

Documents per database:
    - General properties (status, recovery model, collation, owner, creation date, compatibility level)
    - Size (data, log, total in MB)
    - Filegroups and files (name, path, size, autogrow, growth type)
    - Last backup times (full, diff, log)
    - Last DBCC CHECKDB execution
    - VLF count (SQL Server 2016+)
    - Object summary (tables, views, procedures, functions, triggers)
    - Database users (name, login name, type)
    - Extended properties of the database

    Output is generated as:
    - HTML file with formatted report (self-contained, no external CSS)
    - CSV file for machine processing

    Default output path is read from the module configuration (OutputPath).
    If CentralPath is configured, files are additionally copied there.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the SQL connection. |
| -Database | *object* | * | Document specific databases only. Wildcards allowed (e.g. 'Sales*').     Default: all user database |
| -IncludeSystemDatabases | *object* | * | Include system databases (master, model, msdb, tempdb). Default: $false. |
| -IncludeFileDetails | *object* | * | Include filegroup and file details in the report. Default: $true. |
| -IncludeUsers | *object* | * | Include database users in the report. Default: $true. |
| -IncludeObjectSummary | *object* | * | Include object summary (tables, SPs, views, etc.) in the report. Default: $true. |
| -OutputPath | *object* | * | Output directory. Default: value from module configuration (Get-sqmDefaultOutputPath). |
| -ContinueOnError | *object* | * | Continue on error for an instance or database instead of aborting. |
| -EnableException | *object* | * | Throw exceptions directly (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before writing output files. |
| -WhatIf | *object* | * | Simulation: shows which files would be created without writing them. |

### Examples

**Example 1:**
\\\powershell
Export-sqmDatabaseDocumentation
\\\`n
**Example 2:**
\\\powershell
Export-sqmDatabaseDocumentation -SqlInstance "SQL01" -Database "SalesDB","HRApp" -OutputPath "D:\Reports"
\\\`n
**Example 3:**
\\\powershell
Export-sqmDatabaseDocumentation -SqlInstance "SQL01" -IncludeSystemDatabases -ContinueOnError
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmAutoGrowthReport

**Creates an AutoGrowth configuration report for all database files on a SQL Server instance.**

### Description

Analyzes all data and log files of the accessible databases and evaluates their AutoGrowth settings.
    Returns warnings for percent-based growth, growth values that are too small or too large, and
    unbounded log files.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Database | *object* | * | Restrict to specific databases (array of names). |
| -IncludeSystem | *object* | * | Include system databases. Default: $false. |
| -Detailed | *object* | * | When set, additional file properties (physical path) are included in the output. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmAutoGrowthReport -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Get-sqmAutoGrowthReport -SqlInstance "SQL01" -Detailed -IncludeSystem
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmServerHardwareReport

**Erstellt einen HTML-Hardware-Konfigurationsbericht fuer einen oder mehrere Server.**

### Description

Sammelt Systeminformationen via CIM/WMI und generiert einen detaillierten HTML-Report mit:
    - Betriebssystem (Windows-Version, Build, Laufzeit, Domain)
    - Prozessor (Modell, Sockel, physikalische/logische Kerne, Takt)
    - Arbeitsspeicher (Gesamt, frei, DIMM-Details mit Typ und Geschwindigkeit)
    - Laufwerke (physikalische Datentraeger + logische Laufwerke mit Auslastungsbalken)
    - Netzwerk (IP-Adressen, MAC-Adresse, DNS-Server, Gateway)
    - SQL Server Instanzen (Service-Name, Status, Starttyp)
    - VM-Erkennung (Hyper-V, VMware, VirtualBox, KVM/QEMU, Physisch)

    Voraussetzungen fuer Remote-Abfragen:
    - DCOM/WMI-Zugriff (Port 135 + dynamische Ports) auf dem Zielserver
    - Kein WinRM / PowerShell Remoting erforderlich

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Zielserver (ein oder mehrere). Standard: lokaler Computer.     Aliase: SqlInstance, ServerName |
| -ReportPath | *object* | * | Ausgabepfad fuer die HTML-Report-Datei(en).     Standard: %ProgramData%\sqmSQLTool\HardwareReports |
| -OutputFormat | *object* | * | Ausgabeformat: HTML (Standard), CSV, TXT oder All (alle Formate gleichzeitig).     - HTML: Interakti |
| -NoOpen | *object* | * | HTML-Datei nach dem Erstellen NICHT automatisch im Browser oeffnen. |
| -PassThru | *object* | * | Gibt den vollstaendigen Pfad der erstellten Datei(en) als String zurueck. |
| -EnableException | *object* | * | Ausnahmen sofort ausloesen statt Write-Error. |

### Returns

**Type:** Kein Output (oder Dateipfad(e) wenn -PassThru angegeben).

### Examples

**Example 1:**
\\\powershell
# Lokalen Server analysieren - Report wird automatisch im Browser geoeffnet
    Get-sqmServerHardwareReport
\\\`n
**Example 2:**
\\\powershell
# Remote-Server
    Get-sqmServerHardwareReport -ComputerName "SQL01"
\\\`n
**Example 3:**
\\\powershell
# Mehrere Server, eigener Report-Pfad
    Get-sqmServerHardwareReport -ComputerName "SQL01","SQL02","SQL03" -ReportPath "C:\Reports"
\\\`n
*Note: 3 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmInstanceInventory

**Creates a complete inventory of a SQL Server instance as a structured report (TXT + CSV).**

### Description

Documents the following areas:
    - Instance (version, edition, patch level, collation, memory, CPU, sp_configure)
    - Databases (name, status, recovery, size, last backups, owner, collation)
    - Logins (name, type, status, server roles)
    - Linked servers
    - SQL Agent jobs (name, status, owner, schedules, last execution)
    - Always On (AGs, replicas, listeners)

    Output is generated as:
    - TXT file with readable report
    - CSV file with the database list

    Default output path is read from the module configuration (OutputPath).
    If configured, files are additionally copied to CentralPath.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -OutputPath | *object* | * | Output directory for report files.     Default: value from module configuration (Get-sqmDefaultOutp |
| -ContinueOnError | *object* | * | Continue on error for an instance (otherwise abort). |
| -EnableException | *object* | * | Allow exceptions to pass through (for advanced error handling). |
| -Confirm | *object* | * | Request confirmation before creation. |
| -WhatIf | *object* | * | Test only, do not write files. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmInstanceInventory
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmInstanceInventory -SqlInstance "SQL01", "SQL02" -ContinueOnError
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmSetupReport

**Professional SQL Server Setup Report with critical issues, security, and database overview.**

### Description

Comprehensive setup report including:
    - CRITICAL ISSUES (SA, Backups, MaxMemory)
    - SECURITY (Sysadmins, Logins with roles, CLR, xp_cmdshell)
    - INFRASTRUCTURE (Service Accounts, SPNs, Splunk)
    - CONFIGURATION (MAXDOP, Cost Threshold, TempDB)
    - DATABASES (DBOs, Recovery Models, Last Backups)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: local computer name. |
| -SqlCredential | *object* | * | Credentials for SQL connection. |
| -OutputPath | *object* | * | Output path for HTML report. |
| -PassThru | *object* | * | Return the file path. |
| -NoOpen | *object* | * | Don't open the report in browser. |

### Examples

**Example 1:**
\\\powershell
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
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 3. Backup & Recovery

This section covers **10 functions** related to Backup & Recovery.


## Get-sqmOperationStatus

**Displays progress and estimated remaining time for active backup, restore and AutoSeed operations.**

### Description

The function monitors active SQL Server operations (backup, restore, AutoSeed) and calculates
the progress and estimated remaining time. It combines information from:
- Backup and restore progress: sys.dm_exec_requests
- AutoSeed progress: sys.dm_hadr_physical_seeding_stats

The function can run against a specific instance and shows all active operations by default.
Use the parameter to filter by operation type (Backup, Restore, AutoSeed).

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME) is used
by default.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | Alternative credentials. |
| -OperationType | *object* | * | Filters by operation type. Valid values: 'Backup', 'Restore', 'AutoSeed'. By default all active ope |
| -Continuous | *object* | * | When set, output is continuously refreshed (similar to 'watch'). Stop with Ctrl+C. |
| -RefreshSeconds | *object* | * | Refresh interval in seconds for continuous mode (default: 5). Only used with -Continuous. |
| -EnableException | *object* | * | Switch to allow exceptions to pass through (by default errors are logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Show all active operations on the local instance
Get-sqmOperationStatus
\\\`n
**Example 2:**
\\\powershell
# Only active AutoSeed operations on a remote instance
Get-sqmOperationStatus -SqlInstance "SQL01" -OperationType AutoSeed
\\\`n
**Example 3:**
\\\powershell
# Continuous refresh every 10 seconds
Get-sqmOperationStatus -Continuous -RefreshSeconds 10
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmRestoreDatabase

**Restores a database from a backup file, with support for single-server and AlwaysOn environments.**

### Description

The function performs a controlled database restore. It automatically detects whether the target
database belongs to an AlwaysOn availability group and removes it from the AG if so (including
deletion on secondary replicas). Database users are exported before the restore (for later
recovery). Optionally a backup of the original database can be created. After the restore,
users are recovered, orphaned users are repaired, non-existent Windows logins are removed,
and the database owner is set to the SA account (regardless of its name).

The function can also restore a sequence of backups (Full + Diff + Logs) using the `-BackupFiles`
parameter, which accepts a list of backup files in the correct order (Full, then Diff, then Logs).

Before user export and before the restore, the configured PBM policy (DefaultPolicy) is
temporarily disabled to avoid restrictions during user creation. It is re-enabled after completion.

If the database is in use before the restore, it is automatically set to single-user mode
(and switched back to multi-user after the restore).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). Default: current computer name. |
| -SqlCredential | *object* | * | Alternative credentials for the target instance. |
| -BackupFile | *object* | * | Path to the full backup file (.bak). Can also be an array for striped backups. For sequential resto |
| -BackupFiles | *object* | * | Array of backup files in order: Full, then Diff (optional), then Logs (optional). Example: @("C:\Ba |
| -DatabaseName | *object* | * | Name of the database to restore (as it appears in the backup file). Required to determine file names |
| -NewDatabaseName | *object* | * | Optional: New name for the database after the restore. If specified, logical file names are adjuste |
| -NewDatabaseFilePath | *object* | * | Optional: Target directory for database files (.mdf, .ndf). If not specified, the default directory |
| -NewLogFilePath | *object* | * | Optional: Target directory for the log file (.ldf). If not specified, the default directory of the  |
| -BackupBeforeRestore | *object* | * | Optional: Creates a full backup of the existing database before the restore (if present). The backu |
| -NoUserExport | *object* | * | Optional: Skips export of database users (users are always exported by default). The export file is |
| -KeepAlwaysOn | *object* | * | Optional: If the database is part of an AG, it is not removed from the AG. Note: Restoring an AG da |
| -WithNoRecovery | *object* | * | Optional: Performs the restore with NORECOVERY so the database remains in restoring state (for addi |
| -ContinueWithNoRecovery | *object* | * | Optional: When set, the last restore is also performed with NORECOVERY (e.g. when additional backup |
| -ForceSingleUser | *object* | * | Forces the database into single-user mode before the restore (even if no active connections are det |
| -RejoinAvailabilityGroup | *object* | * | When set and the database was part of an AG, it is automatically re-added to the AG after the resto |
| -EnableException | *object* | * | Switch to allow exceptions to pass through (by default errors are logged and returned as objects). |
| -Confirm | *object* | * | Request confirmation before critical actions (removing from AG, restore). |
| -WhatIf | *object* | * | Shows what would happen without making changes. |

### Examples

**Example 1:**
\\\powershell
# Simple restore of a full backup file
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\AdventureWorks.bak" -DatabaseName "AdventureWorks"
\\\`n
**Example 2:**
\\\powershell
# Restore with Full + Diff + Logs
$backupSequence = @(
    "D:\Backup\AdventureWorks_Full.bak",
    "D:\Backup\AdventureWorks_Diff.bak",
    "D:\Backup\AdventureWorks_Log1.trn",
    "D:\Backup\AdventureWorks_Log2.trn"
)
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFiles $backupSequence -DatabaseName "AdventureWorks"
\\\`n
**Example 3:**
\\\powershell
# Restore with new name and forced Single-User mode
Invoke-sqmRestoreDatabase -SqlInstance "SQL01" -BackupFile "D:\Backup\OldDB.bak" -DatabaseName "OldDB" -NewDatabaseName "NewDB" -ForceSingleUser
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmUserDatabaseBackup

**Backs up user databases on a SQL Server instance.**

### Description

Backs up all or selected user databases (no system databases) in full backup mode.
The target path is read from the server properties (BackupDirectory) and must end with "User-Db".

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

When -UseExcludeTable is set, the function reads the table master.dbo.sqm_BackupExclude
(created by Sync-sqmBackupExcludeTable) and skips all databases where IsActive=1 AND
IsOrphaned=0. If the table does not exist or contains no active, non-orphaned rows,
all databases are backed up normally.

When -CheckPreferredReplica is set, the function checks whether this SQL Server instance
is the preferred backup replica for any Availability Group databases before starting any
backups. If the instance is NOT the preferred replica, the job is aborted immediately and
no backups are taken.

When -MailTo is specified, a backup report is sent via SQL Server Database Mail after all
backups have completed. By default the mail is only sent when there are failures or the
job was aborted. Add -MailOnSuccess to also receive a mail on full success.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). If not specified, the current c |
| -SqlCredential | *object* | * | Alternative credentials (PSCredential). If not specified, Windows authentication is used. |
| -Database | *object* | * | Name or array of user databases to back up. Ignored when -All is set. |
| -All | *object* | * | When set, all user databases on the instance are backed up. |
| -BackupPath | *object* | * | Optional direct backup path (overrides the value from server properties). The path must end with "Us |
| -UseExcludeTable | *object* | * | When set, reads master.dbo.sqm_BackupExclude and skips databases where IsActive=1 and IsOrphaned=0. |
| -CheckPreferredReplica | *object* | * | When set, checks sys.fn_hadr_backup_is_preferred_replica() for all AG databases on this instance bef |
| -MailTo | *object* | * | Recipient email address for the backup report. When specified, a mail is sent via SQL Server Databas |
| -MailProfile | *object* | * | SQL Server Database Mail profile name to use for sending the report mail. Default: 'Default'. |
| -MailOnSuccess | *object* | * | When set together with -MailTo, a report mail is also sent when all backups succeeded (not only on e |
| -EnableException | *object* | * | Switch to propagate exceptions immediately (by default errors are logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Back up all user databases on the current computer
Invoke-sqmUserDatabaseBackup -All
\\\`n
**Example 2:**
\\\powershell
# Back up specific databases on a remote server
Invoke-sqmUserDatabaseBackup -SqlInstance "SQL01" -Database "SalesDB", "InventoryDB"
\\\`n
**Example 3:**
\\\powershell
# With an alternative path
Invoke-sqmUserDatabaseBackup -All -BackupPath "D:\Backup\User-Db"
\\\`n
*Note: 6 more examples available in function help*

### Best Practices

- Verify backup integrity with Test-sqmBackupIntegrity
- Keep backups on separate storage devices
- Test restore procedures regularly

---

## New-sqmBackupMaintenanceJob

**Creates a SQL Agent job with two steps that implement the full dynamic backup maintenance workflow.**

### Description

Creates a single SQL Agent job containing two PowerShell steps:

	Step 1 — Sync-BackupExcludeTable
	    Calls Sync-sqmBackupExcludeTable to synchronise master.dbo.sqm_BackupExclude with the
	    current set of databases on the instance. This ensures the exclude table is up-to-date
	    before the actual backup starts.

	Step 2 — Backup-UserDatabases-<BackupType>
	    Calls Invoke-sqmUserDatabaseBackup with -All and all configured options (UseExcludeTable,
	    CheckPreferredReplica, MailTo, MailProfile, MailOnSuccess, BackupPath).

	Both steps use the PowerShell subsystem so that the sqmSQLTool module is imported fresh at
	each execution. This means the job is fully self-contained and does not depend on the SQL
	Server Agent service account's PowerShell profile.

	Default schedule days per backup type (when -ScheduleDays is not specified):
	    FULL — @('Sunday')
	    DIFF — @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
	    LOG  — @('EveryDay')

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: current computer name ($env:COMPUTERNAME). |
| -SqlCredential | *object* | * | PSCredential for the SQL connection. |
| -JobName | *object* | * | Name of the SQL Agent job to create. Default: 'sqm-BackupMaintenance-FULL'. |
| -BackupType | *object* | * | Backup type: 'FULL', 'DIFF', or 'LOG'. Default: 'FULL'. |
| -BackupPath | *object* | * | Optional backup path. When specified, overrides the server default and is passed as 	-BackupPath to  |
| -ScheduleTime | *object* | * | Start time of the schedule in format 'HH:mm'. Default: '20:00'. |
| -ScheduleDays | *object* | * | Days of the week for the schedule. Valid values: 'Monday'..'Sunday', 'Weekdays', 'Weekend', 	'EveryD |
| -ScheduleIntervalMinutes | *object* | * | Repeat interval within a day in minutes (e.g. 15 = every 15 minutes). 0 = run once at 	ScheduleTime. |
| -JobCategory | *object* | * | SQL Agent job category. Default: 'Database Maintenance'. |
| -UseExcludeTable | *object* | * | When set, passes -UseExcludeTable to Invoke-sqmUserDatabaseBackup in Step 2. |
| -CheckPreferredReplica | *object* | * | When set, passes -CheckPreferredReplica to Invoke-sqmUserDatabaseBackup in Step 2. |
| -IncludeSystemDatabases | *object* | * | When set, passes -IncludeSystemDatabases to Sync-sqmBackupExcludeTable in Step 1. 	Note: system data |
| -MailTo | *object* | * | Recipient email address. Passed as -MailTo to Invoke-sqmUserDatabaseBackup in Step 2. |
| -MailProfile | *object* | * | SQL Server Database Mail profile name. Passed as -MailProfile to Invoke-sqmUserDatabaseBackup. 	Defa |
| -MailOnSuccess | *object* | * | When set, passes -MailOnSuccess to Invoke-sqmUserDatabaseBackup in Step 2 so that a report 	mail is  |
| -OperatorName | *object* | * | SQL Agent operator name for failure email notification on the job level. |
| -Update | *object* | * | When set, replaces an existing job with the same name. |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error objects. |
| -WhatIf | *object* | * | Shows what would happen without making changes. |
| -Confirm | *object* | * | Request confirmation before creating the job. |

### Examples

**Example 1:**
\\\powershell
# Weekly FULL backup Sunday 20:00 with all features
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL `
	    -UseExcludeTable -CheckPreferredReplica `
	    -MailTo "dba@company.com" -MailProfile "DBA-Mail"
\\\`n
**Example 2:**
\\\powershell
# Daily DIFF backup with exclude table
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType DIFF `
	    -UseExcludeTable -ScheduleTime "22:00"
\\\`n
**Example 3:**
\\\powershell
# LOG backup every 15 minutes
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType LOG `
	    -ScheduleIntervalMinutes 15 -UseExcludeTable
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Verify backup integrity with Test-sqmBackupIntegrity
- Keep backups on separate storage devices
- Test restore procedures regularly

---

## New-sqmOlaMaintenanceJobs

****

### Description

Creates three fully configured SQL Agent jobs on the specified SQL Server instance
    that call Ola Hallengren's IndexOptimize and DatabaseIntegrityCheck procedures.

    Prerequisite: Ola Hallengren's Maintenance Solution must be installed.
    (https://ola.hallengren.com)

    Job names are read from the module configuration (see defaults in NOTES).
    IndexOptimize uses optimized default parameters (see NOTES).

    Logging and OutputPath are controlled via the module configuration.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the SQL connection. |
| -JobCategory | *object* | * | Category for all three jobs. Default: 'Database Maintenance'. |
| -JobNameIndexOpt | *object* | * | Name of the IndexOptimize job (overrides module configuration). |
| -JobNameIntUserDb | *object* | * | Name of the IntegrityCheck job for user DBs (overrides module configuration). |
| -JobNameIntSysDb | *object* | * | Name of the IntegrityCheck job for system DBs (overrides module configuration). |
| -ScheduleTime | *object* | * | Start time for all jobs (format 'HH:mm'). Default: '23:00'. |
| -ScheduleDay | *object* | * | Day of week as SQL Agent Frequency Interval (bitmask). Default: 1 (Sunday). |
| -Databases | *object* | * | Database filter for IndexOptimize and IntegrityCheck user. Default: 'USER_DATABASES'. |
| -FragmentationLevel1 | *object* | * | Lower fragmentation threshold in percent (medium). Default: 5. |
| -FragmentationLevel2 | *object* | * | Upper fragmentation threshold in percent (high). Default: 30. |
| -MinNumberOfPages | *object* | * | Minimum page count of an index to be considered. Default: 1000. |
| -FillFactor | *object* | * | Fill factor for index rebuilds in percent. Default: 90. |
| -MaxDOP | *object* | * | MAXDOP for IndexOptimize. Default: 0 (SQL Server decides). |
| -SortInTempdb | *object* | * | Execute sort operations in TempDB. Default: 'Y'. |
| -UpdateStatistics | *object* | * | Update statistics: 'ALL', 'COLUMNS', 'INDEX', 'NONE'. Default: 'ALL'. |
| -OnlyModifiedStatistics | *object* | * | Only update modified statistics. Default: 'Y'. |
| -StatisticsSample | *object* | * | Sample size for statistics update in percent. Default: 0 (SQL Server default). |
| -LogToTable | *object* | * | Ola internal logging to CommandLog table. Default: 'Y'. |
| -CheckCommands | *object* | * | DBCC command for IntegrityCheck. Default: 'CHECKDB'. |
| -PhysicalOnly | *object* | * | Check physical consistency only (faster). Default: 'N'. |
| -NoIndex | *object* | * | Skip non-clustered indexes in IntegrityCheck. Default: 'N'. |
| -OperatorName | *object* | * | SQL Agent operator for email notification on failure. |
| -Update | *object* | * | Replace existing jobs with the same name. |
| -ContinueOnError | *object* | * | Continue with the next job on error (rarely used). |
| -EnableException | *object* | * | Throw exceptions immediately. |
| -Confirm | *object* | * | Request confirmation before creation. |
| -WhatIf | *object* | * | Shows what would happen without making changes. |

### Examples

**Example 1:**
\\\powershell
New-sqmOlaMaintenanceJobs -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
New-sqmOlaMaintenanceJobs -SqlInstance "SQL01" -ScheduleTime "22:00" -ScheduleDay 64 -OperatorName "DBAs"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## New-sqmOlaSysDbBackupJob

****

### Description

Creates a SQL Agent job that daily backs up master, model, and msdb completely.
    Backups are stored in a dedicated subdirectory \Sys-db: <BackupDirectory>\Sys-db.

    Job name is read from the module configuration (OlaJobNameSysDbBackup).
    Default: 'OlaHH-SystemDatabases-FULL'.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the SQL connection. |
| -BackupDirectory | *object* | * | Backup base directory. System databases are backed up to <BackupDirectory>\Sys-db.     Default: aut |
| -JobName | *object* | * | Name of the SQL Agent job (overrides module configuration). |
| -JobCategory | *object* | * | Job category. Default: 'Database Maintenance'. |
| -ScheduleTime | *object* | * | Start time in format 'HH:mm'. Default: '21:15'. |
| -CleanupTime | *object* | * | Age in hours after which backup files are deleted. Default: 48. 0 = no cleanup. |
| -Compress | *object* | * | Backup compression. Default: 'Y'. |
| -Verify | *object* | * | Backup verification. Default: 'Y'. |
| -CheckSum | *object* | * | Checksum calculation. Default: 'Y'. |
| -LogToTable | *object* | * | Ola internal logging to CommandLog table. Default: 'Y'. |
| -OperatorName | *object* | * | SQL Agent operator for email notification on failure. |
| -Update | *object* | * | Replace an existing job with the same name. |
| -ContinueOnError | *object* | * | Continue on error (rarely used here, but included for consistency). |
| -EnableException | *object* | * | Throw exceptions immediately. |
| -Confirm | *object* | * | Request confirmation before creation. |
| -WhatIf | *object* | * | Shows what would happen without making changes. |

### Examples

**Example 1:**
\\\powershell
New-sqmOlaSysDbBackupJob -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
New-sqmOlaSysDbBackupJob -SqlInstance "SQL01" -ScheduleTime "20:00" -OperatorName "DBAs"
\\\`n
### Best Practices

- Verify backup integrity with Test-sqmBackupIntegrity
- Keep backups on separate storage devices
- Test restore procedures regularly

---

## New-sqmOlaUsrDbBackupJob

****

### Description

Creates a separate SQL Agent job for each selected backup type (-Full, -Diff, -Log).
    Each job gets its own schedule with configurable days and start time.

    Backups are stored in <BackupDirectory>\Usr-db.
    Job names are read from the module configuration:
        OlaJobNameFull  (Default: 'OlaHH-UserDatabases-FULL')
        OlaJobNameDiff  (Default: 'OlaHH-UserDatabases-DIFF')
        OlaJobNameLog   (Default: 'OlaHH-UserDatabases-LOG')

    When -UseExcludeTable is set, the function reads master.dbo.sqm_BackupExclude
    (created by Sync-sqmBackupExcludeTable) for entries where IsActive=1 AND IsOrphaned=0.
    If entries are found, they are passed to Ola's @ExcludeDatabases parameter in the
    generated job step command. If the table does not exist or contains no matching rows,
    the -Databases parameter is used unchanged.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the SQL connection. |
| -BackupDirectory | *object* | * | Backup base directory. User databases are backed up to <BackupDirectory>\Usr-db.     Default: automa |
| -Databases | *object* | * | Database filter for Ola. E.g. 'USER_DATABASES', 'ALL_DATABASES', or     comma-separated DB names lik |
| -Full | *object* | * | Creates a FULL backup job. |
| -FullJobName | *object* | * | Overrides the job name for FULL read from the configuration. |
| -FullScheduleTime | *object* | * | Start time of the FULL job in format 'HH:mm'. Default: '20:00'. |
| -FullScheduleDays | *object* | * | Days of the week for the FULL job as an array. Valid values: 'Monday'..'Sunday', 'Weekdays', 'Weeken |
| -FullScheduleIntervalMinutes | *object* | * | Repeat interval for the FULL job in minutes (e.g. 60 = hourly).     0 = no interval, job runs once a |
| -Diff | *object* | * | Creates a DIFF backup job. |
| -DiffJobName | *object* | * | Overrides the job name for DIFF read from the configuration. |
| -DiffScheduleTime | *object* | * | Start time of the DIFF job in format 'HH:mm'. Default: '20:00'. |
| -DiffScheduleDays | *object* | * | Days of the week for the DIFF job. Default: @('Monday','Tuesday','Wednesday','Thursday','Friday','Sa |
| -DiffScheduleIntervalMinutes | *object* | * | Repeat interval for the DIFF job in minutes. 0 = once. Default: 0. |
| -Log | *object* | * | Creates a LOG backup job. |
| -LogJobName | *object* | * | Overrides the job name for LOG read from the configuration. |
| -LogScheduleTime | *object* | * | Start time of the LOG job in format 'HH:mm'. Default: '00:00'. |
| -LogScheduleDays | *object* | * | Days of the week for the LOG job. Default: @('EveryDay'). |
| -LogScheduleIntervalMinutes | *object* | * | Repeat interval for the LOG job in minutes (e.g. 15 = every 15 minutes).     0 = once at LogSchedule |
| -JobCategory | *object* | * | Category for all created jobs. Default: 'Database Maintenance'. |
| -CleanupTime | *object* | * | Age in hours after which backup files are deleted. Default: 48. 0 = no cleanup. |
| -Compress | *object* | * | Backup compression. Default: 'Y'. |
| -Verify | *object* | * | Backup verification. Default: 'Y'. |
| -CheckSum | *object* | * | Checksum calculation. Default: 'Y'. |
| -LogToTable | *object* | * | Ola internal logging to CommandLog table. Default: 'Y'. |
| -OperatorName | *object* | * | SQL Agent operator for email notification on failure. |
| -Update | *object* | * | Replace existing jobs with the same name. |
| -ContinueOnError | *object* | * | Continue with remaining jobs if one job fails. |
| -UseExcludeTable | *object* | * | When set, reads master.dbo.sqm_BackupExclude for active, non-orphaned entries and     adds them as @ |
| -EnableException | *object* | * | Throw exceptions immediately. |
| -Confirm | *object* | * | Request confirmation before creation. |
| -WhatIf | *object* | * | Shows what would happen without making changes. |

### Examples

**Example 1:**
\\\powershell
New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full
\\\`n
**Example 2:**
\\\powershell
New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -Diff -Log
\\\`n
**Example 3:**
\\\powershell
# Create FULL job that automatically excludes databases from sqm_BackupExclude
    New-sqmOlaUsrDbBackupJob -SqlInstance "SQL01" -Full -UseExcludeTable
\\\`n
*Note: 6 more examples available in function help*

### Best Practices

- Verify backup integrity with Test-sqmBackupIntegrity
- Keep backups on separate storage devices
- Test restore procedures regularly

---

## Set-sqmBackupExcludePermission

**Grants SELECT, INSERT, and UPDATE permissions on master.dbo.sqm_BackupExclude to a login.**

### Description

Ensures that the specified Windows group or SQL login has the necessary permissions
to read and modify the backup exclude table master.dbo.sqm_BackupExclude.

The function performs the following steps:
  1. Verifies that master.dbo.sqm_BackupExclude exists — if not, an error is thrown
     with the hint to run Sync-sqmBackupExcludeTable first.
  2. Checks whether the login already exists on the SQL Server instance.
     If not, it is created automatically via New-DbaLogin.
  3. Ensures the login has a corresponding database user in master.
     If not, the user is created via New-DbaDbUser.
  4. Grants SELECT, INSERT, and UPDATE on master.dbo.sqm_BackupExclude to the user.

If SqlInstance is not specified, the current computer name ($env:COMPUTERNAME) is used.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). If not specified, the current c |
| -SqlCredential | *object* | * | Alternative credentials (PSCredential). If not specified, Windows authentication is used. |
| -LoginName | *object* | * | The Windows group (e.g. "DOMAIN\DBA-Team") or SQL login to grant permissions to. This parameter is m |
| -EnableException | *object* | * | Switch to propagate exceptions immediately (by default errors are logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Grant permissions to a Windows group on the local instance
Set-sqmBackupExcludePermission -LoginName "CONTOSO\DBA-Team"
\\\`n
**Example 2:**
\\\powershell
# Grant permissions to a SQL login on a remote instance
Set-sqmBackupExcludePermission -SqlInstance "SQL01" -LoginName "svc_backup"
\\\`n
**Example 3:**
\\\powershell
# Preview what would happen without making any changes
Set-sqmBackupExcludePermission -SqlInstance "SQL01" -LoginName "CONTOSO\DBA-Team" -WhatIf
\\\`n
### Best Practices

- Verify backup integrity with Test-sqmBackupIntegrity
- Keep backups on separate storage devices
- Test restore procedures regularly

---

## Sync-sqmBackupExcludeTable

**Creates and synchronises the backup exclude table in the master database.**

### Description

Ensures the table master.dbo.sqm_BackupExclude exists on the target SQL Server instance.
If the table does not exist it is created automatically.

After the table has been created or verified, the function synchronises its content
with the current list of databases on the server:
  - Databases not yet in the table are inserted (IsActive=1, IsOrphaned=0).
  - Databases that are in the table but no longer exist on the server are marked
    IsOrphaned=1 (the row is never deleted).
  - Orphaned entries whose database has reappeared on the server are reset to
    IsOrphaned=0.
  - tempdb is always skipped, regardless of any switch.

In addition, a history table master.dbo.sqm_BackupExclude_History and an audit trigger
dbo.trg_sqm_BackupExclude_Audit are created automatically if they do not yet exist.
The trigger records every INSERT and every change to IsActive or IsOrphaned.

If SqlInstance is not specified, the current computer name ($env:COMPUTERNAME) is used.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). If not specified, the current c |
| -SqlCredential | *object* | * | Alternative credentials (PSCredential). If not specified, Windows authentication is used. |
| -IncludeSystemDatabases | *object* | * | When set, the system databases master, model, and msdb are also inserted into the exclude table. tem |
| -EnableException | *object* | * | Switch to propagate exceptions immediately (by default errors are logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Synchronise on the local instance – user databases only
Sync-sqmBackupExcludeTable
\\\`n
**Example 2:**
\\\powershell
# Synchronise on a remote instance including system databases
Sync-sqmBackupExcludeTable -SqlInstance "SQL01" -IncludeSystemDatabases
\\\`n
**Example 3:**
\\\powershell
# Preview what would change without making any modifications
Sync-sqmBackupExcludeTable -SqlInstance "SQL01" -WhatIf
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Verify backup integrity with Test-sqmBackupIntegrity
- Keep backups on separate storage devices
- Test restore procedures regularly

---

## Test-sqmBackupIntegrity

**Verifies one or more backup files using RESTORE VERIFYONLY.**

### Description

Executes RESTORE VERIFYONLY on a backup file (local or optionally remote).
    Returns $true if the check was successful, otherwise $false.
    Can verify multiple files in sequence (e.g. stripes).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance on which the verification runs (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -BackupPath | *object* | * | Path to the backup file (.bak) on the server (local path, not UNC). Can be an array.     If not spe |
| -FileListOnly | *object* | * | When $true, only lists the files contained in the backup (without VerifyOnly). |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Test-sqmBackupIntegrity -SqlInstance "SQL01" -BackupPath "D:\Backup\AdventureWorks.bak"
\\\`n
### Best Practices

- Verify backup integrity with Test-sqmBackupIntegrity
- Keep backups on separate storage devices
- Test restore procedures regularly

---

# 7. Configuration Management

This section covers **7 functions** related to Configuration Management.


## Compare-sqmServerConfiguration

**Compares important configuration settings between two SQL Server instances.**

### Description

Displays differences in the following areas: sp_configure, instance properties (Collation, Version, MaxMemory), database settings (optional). Output as a list with old/new values.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SourceInstance | *object* | * | Source instance (reference). |
| -TargetInstance | *object* | * | Target instance (server to compare). Mandatory. |
| -SqlCredential | *object* | * | PSCredential for both instances (if identical). For different credentials, separate parameters are r |
| -CompareDatabases | *object* | * | When set, databases (Name, Owner, RecoveryModel, Collation) are compared. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Compare-sqmServerConfiguration -SourceInstance "SQL01" -TargetInstance "SQL02"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Export-sqmServerConfiguration

**Exports all SQL Server configuration settings to a JSON snapshot file.**

### Description

This function reads comprehensive configuration data from a SQL Server instance
and saves it as a JSON snapshot with timestamp. The snapshot can be used for
documentation, comparison, or rollback purposes.

Captured settings include:
- sp_configure values (MaxServerMemory, MAXDOP, xp_cmdshell, etc.)
- Instance properties (BackupDirectory, DefaultFile, DefaultLog, Collation, etc.)
- Service configuration (SQL Server, Agent, SSRS, SSIS start mode and accounts)
- Startup parameters (registry trace flags, etc.)
- TempDB configuration
- Database Mail profiles (if configured)
- Linked Servers
- Database overview (optional, slower)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL Server instance (default: $env:COMPUTERNAME). |
| -SqlCredential | *object* | * | Optional alternative credentials (PSCredential object). |
| -OutputPath | *object* | * | Path where JSON snapshot will be saved. Default: $env:ProgramData\sqmSQLTool\Snapshots |
| -Label | *object* | * | Optional descriptive label for this snapshot (e.g., "before MaxMemory change"). Included in the JSON |
| -IncludeDatabases | *object* | * | When set, includes database-level settings (slower operation). |
| -EnableException | *object* | * | Switch to allow exceptions to pass through (default: errors logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Create a snapshot before making configuration changes
$snap = Export-sqmServerConfiguration -SqlInstance "SQL01" -Label "before MaxMemory change"
Write-Host "Snapshot saved to: $($snap.SnapshotPath)"
\\\`n
**Example 2:**
\\\powershell
# Export with custom output path
Export-sqmServerConfiguration -SqlInstance "SQL01" `
  -OutputPath "C:\Backups\SQLSnapshots" `
  -Label "production-baseline"
\\\`n
**Example 3:**
\\\powershell
# Full export including databases
Export-sqmServerConfiguration -SqlInstance "SQL01" `
  -IncludeDatabases `
  -Label "complete-inventory"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmConfigRollback

**Restores SQL Server configuration from a previously exported snapshot.**

### Description

This function reads a JSON snapshot (created by Export-sqmServerConfiguration)
and applies those settings back to a SQL Server instance. It supports a
comprehensive rollback of configuration changes.

Supported rollback operations:
- sp_configure values (most settings; some require SQL restart)
- Instance properties (BackupDirectory, DefaultFile, DefaultLog)
- Service start mode (requires local admin on the server)
- Database Mail profiles
- Linked Server settings (limited, via T-SQL)

The function supports -WhatIf to preview changes before applying them.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL Server instance (default: $env:COMPUTERNAME). |
| -SqlCredential | *object* | * | Optional alternative credentials (PSCredential object). |
| -SnapshotPath | *object* | * | Full path to the JSON snapshot file to restore from. Required parameter. |
| -Category | *object* | * | Limit rollback to specific categories. Valid values: 'SpConfigure', 'InstanceProperties', 'Services' |
| -WhatIf | *object* | * | Show what would be changed without making actual modifications. |
| -Force | *object* | * | Skip confirmation dialog and apply changes immediately. |
| -EnableException | *object* | * | Switch to allow exceptions to pass through (default: errors logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Preview what would be restored
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -WhatIf
\\\`n
**Example 2:**
\\\powershell
# Apply rollback (with confirmation)
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json"
\\\`n
**Example 3:**
\\\powershell
# Force rollback without confirmation
Invoke-sqmConfigRollback -SqlInstance "SQL01" `
  -SnapshotPath "C:\Snapshots\SQL01_MSSQLSERVER_20260602_143022.json" `
  -Force
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Set-sqmConfig

**Sets one or more configuration values for the MSSQLTools module.**

### Description

Allows setting of LogPath, OutputPath, CentralPath, Ola job names,
    TSM management classes, the HPU domain group mapping, and the
    SSRS installer path (SsrsInstallerPath).
    Each path is validated for existence or creatability.
    The configuration is permanently saved in a JSON file in the user profile.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -LogPath | *object* | * | Directory for log files (Invoke-sqmLogging). |
| -OutputPath | *object* | * | Default output directory for reports. |
| -CentralPath | *object* | * | Optional central storage directory (additional copy). |
| -OlaJobNameFull | *object* | * | Name of the full backup job for user databases. |
| -OlaJobNameDiff | *object* | * | Name of the diff backup job for user databases. |
| -OlaJobNameLog | *object* | * | Name of the log backup job for user databases. |
| -OlaJobNameIndexOpt | *object* | * | Name of the IndexOptimize job. |
| -OlaJobNameIntUserDb | *object* | * | Name of the IntegrityCheck job for user databases. |
| -OlaJobNameIntSysDb | *object* | * | Name of the IntegrityCheck job for system databases. |
| -OlaJobNameSysDbBackup | *object* | * | Name of the full backup job for system databases. |
| -TsmManagementClasses | *object* | * | Array of valid TSM management classes (e.g. 'MC_B_NL.NL_42.42.NA'). |
| -HpuDomainGroupMap | *object* | * | Array of PSCustomObject with fields DomainPattern (wildcard) and GroupNamePattern     (sAMAccountNa |
| -SsrsInstallerPath | *object* | * | Full UNC or local path to the SSRS installer file     (SQLServerReportingServices.exe or .msi).    |
| -CheckProfile | *object* | * | Check-Profil fuer Invoke-sqmSetupReport und verwandte Checks.     Auto  = FI-TS-Checks nur wenn sqm |
| -CheckCostThresholdMin | *object* | * | Mindestwert fuer Cost Threshold for Parallelism im Setup-Check.     Standard: 50 |
| -CheckTempDbMaxFiles | *object* | * | Maximale TempDB-Dateianzahl im Setup-Check.     Standard: 8 |
| -CheckDiskBlockSize | *object* | * | Empfohlene NTFS-Blockgroesse in Bytes fuer Get-sqmDiskBlockSize.     Standard: 65536 (64 KB) |
| -Language | *object* | * | Output language of the module. Allowed values: de-DE, en-US.     Default: de-DE.     Example: Set- |
| -PassThru | *object* | * | Returns the updated configuration as an object. |

### Examples

**Example 1:**
\\\powershell
Set-sqmConfig -LogPath "D:\Logs" -OlaJobNameFull "Prod-FULL"
\\\`n
**Example 2:**
\\\powershell
Set-sqmConfig -TsmManagementClasses @('MC_10','MC_30','MC_100')
\\\`n
**Example 3:**
\\\powershell
Set-sqmConfig -HpuDomainGroupMap @(
        [PSCustomObject]@{ DomainPattern = '*.sfinance.net'; GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
        [PSCustomObject]@{ DomainPattern = '*';              GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }
    )
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmConfig

**Returns the current module configuration.**

### Description

Without parameters, the entire configuration is returned as a hashtable.
    With -Key, the value of the requested key is returned.
    If the key does not exist, a warning is shown and $null is returned.

    NOTE: Initialization of $script:sqmModuleConfig is performed exclusively
    in sqmSQLTool.psm1. This file contains only the Get-sqmConfig function.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Key | *object* | * | Name of the configuration key (e.g. 'LogPath', 'OutputPath', 'CentralPath'). |

### Examples

**Example 1:**
\\\powershell
Get-sqmConfig
\\\`n
**Example 2:**
\\\powershell
Get-sqmConfig -Key 'OutputPath'
#>
function Get-sqmConfig
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$Key
	)
	if ($Key)
	{
		if ($script:sqmModuleConfig.ContainsKey($Key))
		{
			return $script:sqmModuleConfig[$Key]
		}
		else
		{
			Write-Warning "Konfigurationsschluessel '$Key' existiert nicht. Verfuegbare Schluessel: $($script:sqmModuleConfig.Keys -join ', ')"
			return $null
		}
	}
	return $script:sqmModuleConfig
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Set-sqmTcpPort

**Konfiguriert den TCP-Port einer SQL Server-Instanz ueber die Registry.**

### Description

Setzt den statischen TCP-Port fuer eine SQL Server-Instanz.
    Der Port wird aus BasePort und PortIncrement berechnet:
        - Default-Instanz (MSSQLSERVER): Port = BasePort
        - Named Instance:                Port = BasePort + (InstanzNummer * PortIncrement)

    Die Instanznummer wird aus dem Instanznamen extrahiert wenn moeglich
    (z.B. INST01 -> 1, INST02 -> 2). Ist keine Zahl im Namen enthalten,
    wird eine fortlaufende Nummer anhand der Registry-Reihenfolge vergeben.

    Aenderungen werden erst nach Neustart des SQL Server-Dienstes aktiv.
    Die Funktion startet den Dienst NICHT automatisch neu.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Name der SQL-Instanz (z.B. "MSSQLSERVER" fuer Default, "INST01" fuer Named Instance).     Darf auch  |
| -BasePort | *object* | * | Basisport. Standard: 1433. |
| -PortIncrement | *object* | * | Schrittweite pro Instanz. Standard: 10. |
| -InstanceNumber | *object* | * | Optionale explizite Instanznummer (ueberschreibt Auto-Erkennung aus Instanzname). |

### Examples

**Example 1:**
\\\powershell
Set-sqmTcpPort -SqlInstance 'MSSQLSERVER' -BasePort 1433
\\\`n
**Example 2:**
\\\powershell
Set-sqmTcpPort -SqlInstance 'INST01' -BasePort 1433 -PortIncrement 10
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmCollationChange

**Automatically changes the server collation of a SQL Server instance.**

### Description

Changes the SQL Server instance collation using the undocumented method
    "sqlservr.exe -m -T4022 -T3659 -q '<Collation>'". This function is only
    suitable for local standalone instances (no AGs, no failover cluster).

    The function performs the following steps:
    1. Pre-flight check (connection, current collation, target collation, locality, service, admin rights)
    2. Create rollback documentation
    3. Optional backup of all user databases (-BackupBeforeChange)
    4. Stop SQL Server service
    5. Start sqlservr.exe with new collation (waits for readiness)
    6. Terminate process (sqlservr.exe stops itself)
    7. Start SQL Server service normally
    8. Verify the new collation
    9. Optional: ALTER DATABASE ... COLLATE for user databases (-IncludeUserDatabases)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (must be local). Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the SQL connection. |
| -NewCollation | *object* | * | Target collation (e.g. 'Latin1_General_CI_AS'). |
| -IncludeUserDatabases | *object* | * | When set, the default collation of all user databases is also changed. |
| -BackupBeforeChange | *object* | * | Creates a full backup of all user databases before the change. |
| -ExcludeDatabase | *object* | * | Databases to exclude from -IncludeUserDatabases (wildcards allowed). |
| -ServiceName | *object* | * | Windows service name (automatically determined from SqlInstance if not specified). |
| -StartupTimeoutSeconds | *object* | * | Maximum wait time for sqlservr.exe in minimal mode (default: 120). |
| -OutputPath | *object* | * | Output directory for rollback documentation and column script.     Default: Get-sqmDefaultOutputPat |
| -ContinueOnError | *object* | * | Continue with the next step on error (rarely used). |
| -EnableException | *object* | * | Throw exceptions immediately. |
| -Confirm | *object* | * | Request confirmation before stopping the service and making the change. |
| -WhatIf | *object* | * | Shows all planned steps without execution. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmCollationChange -NewCollation "Latin1_General_CI_AS"
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmCollationChange -SqlInstance "SQL01\INST2" -NewCollation "German_CI_AS" -IncludeUserDatabases -BackupBeforeChange
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 17. SSRS Configuration

This section covers **3 functions** related to SSRS Configuration.


## Install-sqmSsrsReportServer

****

### Description

Executes the following steps in sequence:

    [1] Check prerequisites
        - Administrator rights on the target computer
        - Installer (.exe or .msi) found in the configured share (SsrsInstallerPath)
        - SSRS not yet installed (skippable with -Force)

    [2] Installation
        - Copies the installer to a local temp directory (UNC paths are not
          directly supported as process start)
        - Runs the installer silently:
            SQLServerReportingServices.exe
                /quiet /IAcceptLicenseTerms /Edition=<Edition> /IAcceptLicenseTerms
        - Evaluates the exit code (0 = OK, 3010 = restart recommended)
        - Waits up to 60 seconds for the SSRS WMI namespace (service startup)

    [3] Configuration
        - Calls Set-sqmSsrsConfiguration with all passed configuration parameters
          (splatting). Parameters not passed use the defaults of Set-sqmSsrsConfiguration.

    The installer path is read preferably from the -InstallerPath parameter.
    If missing, Get-sqmConfig -Key 'SsrsInstallerPath' is used.
    If that is also not set, an error is thrown.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer. Default: $env:COMPUTERNAME (local).     Remote installation via WinRM / PsRemoting  |
| -InstallerPath | *object* | * | Full UNC or local path to the installation file     (SQLServerReportingServices.exe or .msi).     Ov |
| -Edition | *object* | * | License edition for the silent parameter /Edition.     Valid values: Eval, Developer, Expr, Web, Sta |
| -ProductKey | *object* | * | Product key (25 characters). If specified, instead of -Edition the     parameter /IAcceptLicenseTerm |
| -Force | *object* | * | Perform installation even if SSRS is already installed. |
| -SkipConfiguration | *object* | * | Install only; do not call Set-sqmSsrsConfiguration. |
| -InstanceName | *object* | * | SSRS instance name. Passed to Set-sqmSsrsConfiguration.     Default: 'MSSQLSERVER'. |
| -DatabaseServer | *object* | * | SQL Server for the ReportServer database.     Passed to Set-sqmSsrsConfiguration. |
| -DatabaseName | *object* | * | Name of the ReportServer database. Default: 'ReportServer'. |
| -ReportServerUrl | *object* | * | URL for the ReportServer web service.     Default: 'http://+:80/ReportServer'. |
| -ReportsUrl | *object* | * | URL for the reports portal. Default: 'http://+:80/Reports'. |
| -ServiceAccount | *object* | * | Windows service account for SSRS. |
| -ServiceAccountPassword | *object* | * | Password for -ServiceAccount (SecureString). |
| -DatabaseAuthType | *object* | * | Authentication for the DB connection: 'Windows' or 'SQL'. |
| -DatabaseCredential | *object* | * | PSCredential for SQL authentication (only with -DatabaseAuthType SQL). |
| -EncryptionKeyFile | *object* | * | Path for the encryption key backup (.snk). |
| -EncryptionKeyPassword | *object* | * | Password for the key backup (SecureString). |
| -SkipDatabase | *object* | * | Skip database configuration in Set-sqmSsrsConfiguration. |
| -SkipUrls | *object* | * | Skip URL configuration in Set-sqmSsrsConfiguration. |
| -SkipServiceAccount | *object* | * | Skip service account configuration in Set-sqmSsrsConfiguration. |
| -SkipEncryptionKeyBackup | *object* | * | Skip the key backup in Set-sqmSsrsConfiguration. |
| -Credential | *object* | * | PSCredential for the WinRM connection to the target computer (remote operation). |
| -OutputPath | *object* | * | Output directory for the configuration report. |
| -WmiWaitSeconds | *object* | * | Maximum wait time in seconds for the SSRS WMI namespace after installation.     Default: 60. |
| -ContinueOnError | *object* | * | Do not treat configuration errors as terminating. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Install-sqmSsrsReportServer

    Installs SSRS using the installer path stored in sqmConfig,
    Edition Developer, followed by full configuration with default values.
\\\`n
**Example 2:**
\\\powershell
Install-sqmSsrsReportServer `
        -InstallerPath '\\srv-share\Software\SSRS2022\SQLServerReportingServices.exe' `
        -Edition Standard `
        -DatabaseServer 'SQL-AG-Listener' `
        -ServiceAccount 'DOMAIN\svc_ssrs' `
        -EncryptionKeyPassword (Read-Host -AsSecureString 'Key-Passwort')
\\\`n
**Example 3:**
\\\powershell
Install-sqmSsrsReportServer -SkipConfiguration -WhatIf

    Shows what would be installed without making any changes.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Set-sqmSsrsConfiguration

****

### Description

Performs a complete initial or re-configuration of SSRS.
        Supports Native Mode and SharePoint Integrated Mode (automatic detection).

        Configurable areas (individually disableable):
        - Service account (SetWindowsServiceIdentity)
        - Database (create, grant permissions, set connection)
        - URLs (ReportServer Web Service + Portal, Native Mode only)
        - Encryption key (BackupEncryptionKey)

        For AlwaysOn Availability Groups (AG), the database server is automatically
        detected as a listener; the DB is created on the primary replica and the
        connection is configured to point to the listener.

        Optionally, a Policy-Based Management (PBM) policy (e.g. 'Password Policy')
        can be disabled before database creation and re-enabled after successful configuration.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | SSRS server (local or remote). Default: $env:COMPUTERNAME. |
| -InstanceName | *object* | * | SSRS instance name. Default: 'MSSQLSERVER'. |
| -DatabaseServer | *object* | * | SQL Server instance or AG listener for the ReportServer database.         Default: $ComputerName. |
| -DatabaseName | *object* | * | Name of the ReportServer main database. Default: 'ReportServer'. |
| -ReportServerUrl | *object* | * | URL for the ReportServer Web Service. Default: 'http://+:80/ReportServer' |
| -ReportsUrl | *object* | * | URL for the Reports Manager / Web Portal. Default: 'http://+:80/Reports' |
| -ServiceAccount | *object* | * | Windows service account for SSRS (e.g. 'DOMAIN\user' or 'NT SERVICE\...'). |
| -ServiceAccountPassword | *object* | * | Password for -ServiceAccount (SecureString). Not needed for managed service accounts. |
| -DatabaseAuthType | *object* | * | Authentication for the DB connection: 'Windows' (default) or 'SQL'. |
| -DatabaseCredential | *object* | * | PSCredential for SQL authentication (only with -DatabaseAuthType SQL). |
| -EncryptionKeyFile | *object* | * | Path for the encryption key backup (.snk). If not specified, the file is stored         in OutputPa |
| -EncryptionKeyPassword | *object* | * | Password to protect the key file (SecureString). Required when a backup is to be created. |
| -PbmPolicyName | *object* | * | Name of a Policy-Based Management policy (e.g. 'Password Policy') that is         disabled before d |
| -SkipDatabase | *object* | * | Skip database configuration. |
| -SkipUrls | *object* | * | Skip URL configuration (Native Mode only). |
| -SkipServiceAccount | *object* | * | Skip service account configuration. |
| -SkipEncryptionKeyBackup | *object* | * | Skip encryption key backup. |
| -Credential | *object* | * | PSCredential for the WinRM connection (remote operation only). |
| -OutputPath | *object* | * | Output directory for the configuration report and optionally the key file.         Default: Get-sqm |
| -ContinueOnError | *object* | * | Continue with the next step on error (rarely used). |
| -EnableException | *object* | * | Throw exceptions immediately. |
| -Confirm | *object* | * | Request confirmation before execution. |
| -WhatIf | *object* | * | Shows what would happen without making any changes. |

### Examples

**Example 1:**
\\\powershell
Set-sqmSsrsConfiguration
\\\`n
**Example 2:**
\\\powershell
Set-sqmSsrsConfiguration -ComputerName "SSRS01" -DatabaseServer "AG_Listener" -PbmPolicyName "Password Policy"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Set-sqmSsrsHttpsCertificate

**Binds a Windows certificate to SSRS or Power BI Report Server for HTTPS access.**

### Description

Eliminates browser security warnings by binding a valid certificate to the SSRS
		or Power BI Report Server (PBIRS) HTTPS endpoint via the WMI configuration interface.

		The function performs the following steps:
		1. Discovers the SSRS/PBIRS WMI namespace dynamically under
		   root\Microsoft\SqlServer\ReportServer\{Instance}\v{Version}\Admin
		2. Validates the certificate in Cert:\LocalMachine\My by thumbprint
		3. Lists and removes existing HTTPS URL reservations for all web applications
		4. Removes existing SSL certificate bindings
		5. Reserves HTTPS URLs for all applicable web applications
		6. Creates the SSL certificate binding
		7. Optionally sets SecureConnectionLevel to require HTTPS
		8. Calls ApplyChanges() to finalize

		Supported application names (auto-detected by version):
		- ReportServerWebService  (always present)
		- ReportManager           (SSRS 2016 and earlier, v13-)
		- ReportServerWebApp      (SSRS 2017+ / PBIRS, v14+)

		Prerequisites: Local administrator rights on the target computer.
		For remote execution, WinRM must be available.
		The certificate must already be present in the LocalMachine\My store on the target.
		The SSRS service may need to be restarted after binding.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer name or IP address. Default: localhost ($env:COMPUTERNAME). |
| -Thumbprint | *object* | * | Mandatory. Certificate thumbprint (40 hex characters) from the LocalMachine\My store. 		Spaces are a |
| -Port | *object* | * | HTTPS port to bind. Default: 443. |
| -InstanceName | *object* | * | SSRS WMI instance name (e.g. "RS_SSRS", "RS_PBIRS"). 		Auto-detected when only one instance is found |
| -IPAddress | *object* | * | IP address for the SSL binding. Default: "0.0.0.0" (all interfaces). |
| -RequireSSL | *object* | * | When specified, sets SecureConnectionLevel = 1 (HTTPS required). 		Default: SecureConnectionLevel =  |
| -Credential | *object* | * | PSCredential for the WinRM session (remote operation only). |
| -WhatIf | *object* | * | Shows what would happen without making any changes. |
| -Confirm | *object* | * | Prompts for confirmation before applying changes. |

### Examples

**Example 1:**
\\\powershell
Set-sqmSsrsHttpsCertificate -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"

		Binds the specified certificate to SSRS on the local machine on port 443.
		The SSRS instance is auto-detected.
\\\`n
**Example 2:**
\\\powershell
Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER01" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Port 8443 -InstanceName "RS_PBIRS" -RequireSSL

		Binds the certificate to Power BI Report Server on REPSERVER01, port 8443,
		and requires HTTPS (SecureConnectionLevel = 1).
\\\`n
**Example 3:**
\\\powershell
$cred = Get-Credential
		Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER02" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Credential $cred -WhatIf

		Shows what changes would be made on REPSERVER02 without applying them.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 5. Login & User Security

This section covers **8 functions** related to Login & User Security.


## Copy-sqmLogins

**Copies logins from a source SQL Server instance to a target instance.**

### Description

Transfers SQL and Windows logins from a source instance to a target instance.

    Process:
        1. Disable policy  (Set-sqmSqlPolicyState -State Disable, if -DisablePolicy $true)
        2. Connect + authentication mode check / alignment
        3. Load and filter logins
        4. Check Windows logins against Active Directory (AD module required)
           - Unresolvable logins are skipped and reported as 'AdOrphan'.
        5. Copy logins (Copy-DbaLogin, password hash + SID mapping)
        6. Repair orphaned users on all user databases on the target
           (Repair-DbaDbOrphanUser - always runs, no optional switch)
        7. Re-enable policy - guaranteed via finally block, even on error.

    Authentication mode alignment:
        If the source uses Mixed Mode (SQL + Windows) and the target is set to
        Windows Authentication only, the target is automatically switched to Mixed Mode
        - provided -AdjustAuthMode is specified. Without this switch, the function
        aborts with an error and reports the discrepancy.
        The SQL Server service must be restarted after an authentication mode change.
        With -RestartServiceIfRequired this is done automatically.

    AD check:
        All Windows logins (type WindowsUser / WindowsGroup) from the source are
        validated against Active Directory via Get-ADObject before copying.
        Unresolvable logins are removed from the copy batch and reported as
        'AdOrphan' in the result.

        If the ActiveDirectory module is not present, -AdModuleAction controls behavior:
            'Install' (default) - Install-sqmAdModule is called.
                                  If installation fails, the AD check is
                                  skipped with a warning.
            'Skip'              - Warning, AD check is skipped.
            'Abort'             - Error, function aborts.

    Login filter:
        System logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*, BUILTIN\*)
        are excluded by default. With -IncludeSystemLogins they are included.
        Individual logins can be filtered via -ExcludeLogin.

    Passwords for SQL logins:
        Copy-DbaLogin transfers the password hash (HASHED) directly.
        SIDs are preserved (SID mapping).

    Orphaned users:
        After copying, Repair-DbaDbOrphanUser is automatically run on all user
        databases on the target (no optional switch).

    Policy:
        Before copying, Set-sqmSqlPolicyState disables the configured default policy
        on the target instance. After completion (even on error) it is guaranteed to
        be re-enabled via a finally block.
        Controlled by -DisablePolicy (default: $true).
        The finally block re-enables the policy only if it was previously successfully
        disabled ($policyWasDisabled flag).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Source | *object* | * | Source SQL Server instance. Mandatory. |
| -Destination | *object* | * | Target SQL Server instance. Mandatory. |
| -SqlCredential | *object* | * | Optional PSCredential for both instances (source and target).     For different credentials use -So |
| -SourceCredential | *object* | * | PSCredential specifically for the source instance. |
| -DestinationCredential | *object* | * | PSCredential specifically for the target instance. |
| -Login | *object* | * | Filters the copy operation to these login names (wildcards allowed).     Without specification, all |
| -ExcludeLogin | *object* | * | Logins that should not be copied (wildcards allowed).     Example: 'AppLogin_*', 'OldUser'. |
| -IncludeSystemLogins | *object* | * | When set, system logins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*) are also copied.     Default: $f |
| -DisablePolicy | *object* | * | Controls whether the default policy on the target is disabled before copying     and re-enabled aft |
| -AdjustAuthMode | *object* | * | When set and the target is Windows-only auth but the source uses Mixed Mode,     the target is auto |
| -RestartServiceIfRequired | *object* | * | When set, the SQL Server service on the target server is automatically restarted     after an authe |
| -Force | *object* | * | Existing logins on the target server are overwritten. |
| -AdModuleAction | *object* | * | Controls behavior when the ActiveDirectory module is not present.         'Install' (default) - Ins |
| -ContinueOnError | *object* | * | Continue with the next login on error. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before critical actions. |
| -WhatIf | *object* | * | Shows all planned actions without executing them. |

### Examples

**Example 1:**
\\\powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02'

    Copies all non-system logins. Policy is disabled/re-enabled,
    AD check and orphan repair run automatically.
\\\`n
**Example 2:**
\\\powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -AdjustAuthMode -RestartServiceIfRequired

    Copies all logins and switches the target server to Mixed Mode if needed.
    Automatically restarts the SQL service if required.
\\\`n
**Example 3:**
\\\powershell
Copy-sqmLogins -Source 'SQL01' -Destination 'SQL02' -Login 'App_*' -Force

    Copies only logins starting with 'App_' and overwrites existing ones.
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Review audit logs after bulk changes
- Test permissions in non-prod first
- Maintain password policies compliance

---

## Get-sqmADAccountStatus

**Checks the status of an Active Directory user account.**

### Description

Determines the account status using the ActiveDirectory module (RSAT) with
        automatic fallback to ADSI if RSAT is not available.
        Returns a detailed PSObject with Enabled, LockedOut, PasswordExpired
        and AccountExpired.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SamAccountName | *object* | * | The SamAccountName of the AD account to check. |
| -DomainController | *object* | * | Optional target DC. Only used via the RSAT path. |

### Examples

**Example 1:**
\\\powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe'
\\\`n
**Example 2:**
\\\powershell
'jdoe','jsmith' | Get-sqmADAccountStatus
\\\`n
**Example 3:**
\\\powershell
Get-sqmADAccountStatus -SamAccountName 'jdoe' -DomainController 'DC01'
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $SamAccountName,

        [Parameter()]
        [string] $DomainController
    )

    begin {
        #region --- Modul-Verfuegbarkeit einmalig pruefen ---
        $useRSAT = $false
        if (Get-Module -Name ActiveDirectory -ListAvailable) {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $useRSAT = $true
                Write-Verbose 'ActiveDirectory-Modul geladen (RSAT-Pfad aktiv).'
            }
            catch {
                Write-Verbose "ActiveDirectory-Modul nicht ladbar: $_  - Fallback auf ADSI."
            }
        }
        else {
            Write-Verbose 'ActiveDirectory-Modul nicht installiert - Fallback auf ADSI.'
        }

        # Hilfsfunktion: Ergebnis-Objekt erzeugen
        function New-ResultObject {
            param (
                [string]   $Sam,
                [bool]     $Enabled        = $false,
                [bool]     $LockedOut      = $false,
                [bool]     $PwdExpired     = $false,
                [bool]     $AcctExpired    = $false,
                [string]   $Source         = '',
                [string]   $ErrorMessage   = ''
            )
            [PSCustomObject]@{
                SamAccountName  = $Sam
                Enabled         = $Enabled
                LockedOut       = $LockedOut
                PasswordExpired = $PwdExpired
                AccountExpired  = $AcctExpired
                Source          = $Source
                QueryTime       = (Get-Date)
                ErrorMessage    = $ErrorMessage
            }
        }

        #region --- ADSI-Hilfsfunktion ---
        function Get-ADAccountStatusViaADSI {
            param ([string] $Sam)

            # Searcher aufbauen
            $searcher = [adsisearcher]"(sAMAccountName=$Sam)"
            $searcher.PropertiesToLoad.AddRange(@(
                'sAMAccountName',
                'userAccountControl',
                'lockoutTime',
                'pwdLastSet',
                'accountExpires',
                'msDS-UserPasswordExpiryTimeComputed'
            )) | Out-Null
            $searcher.SizeLimit = 1

            $entry = $searcher.FindOne()
            if (-not $entry) {
                throw "Konto '$Sam' wurde im Verzeichnis nicht gefunden."
            }

            $uac = [int]$entry.Properties['useraccountcontrol'][0]

            # Enabled: Bit 2 (0x0002) = disabled
            $enabled   = -not [bool]($uac -band 0x0002)

            # LockedOut: Bit 16 (0x0010) oder lockoutTime > 0
            $lockedBit = [bool]($uac -band 0x0010)
            $lockoutTimeRaw = $entry.Properties['lockouttime']
            $lockedTime = $false
            if ($lockoutTimeRaw.Count -gt 0) {
                $lt = [long]$lockoutTimeRaw[0]
                $lockedTime = ($lt -gt 0)
            }
            $lockedOut = $lockedBit -or $lockedTime

            # PasswordExpired: Bit 8388608 (0x800000) oder msDS-Attribut
            $pwdExpiredBit = [bool]($uac -band 0x800000)
            $pwdExpired = $pwdExpiredBit

            if (-not $pwdExpired) {
                $expiryRaw = $entry.Properties['msds-userpasswordexpirytimecomputed']
                if ($expiryRaw.Count -gt 0) {
                    $expiryFt = [long]$expiryRaw[0]
                    # 0 = laeuft nie ab, 9223372036854775807 = nie
                    if ($expiryFt -gt 0 -and $expiryFt -ne [long]::MaxValue) {
                        $expiryDate = [datetime]::FromFileTime($expiryFt)
                        $pwdExpired = ($expiryDate -lt (Get-Date))
                    }
                }
            }

            # AccountExpired
            $acctExpired = $false
            $acctExpiresRaw = $entry.Properties['accountexpires']
            if ($acctExpiresRaw.Count -gt 0) {
                $ae = [long]$acctExpiresRaw[0]
                # 0 und Int64.MaxValue bedeuten "laeuft nie ab"
                if ($ae -gt 0 -and $ae -ne [long]::MaxValue) {
                    $expDate = [datetime]::FromFileTime($ae)
                    $acctExpired = ($expDate -lt (Get-Date))
                }
            }

            return [PSCustomObject]@{
                Enabled         = $enabled
                LockedOut       = $lockedOut
                PasswordExpired = $pwdExpired
                AccountExpired  = $acctExpired
            }
        }
        #endregion
    }

    process {
        foreach ($sam in $SamAccountName) {
            Write-Verbose "Verarbeite Konto: $sam"

            #region --- RSAT-Pfad ---
            if ($useRSAT) {
                try {
                    $params = @{
                        Identity    = $sam
                        Properties  = @(
                            'Enabled',
                            'LockedOut',
                            'PasswordExpired',
                            'AccountExpirationDate'   # 'AccountExpired' ist keine abrufbare Property
                        )
                        ErrorAction = 'Stop'
                    }
                    if ($DomainController) { $params['Server'] = $DomainController }

                    $adUser = Get-ADUser @params

                    # AccountExpired: ExpirationDate vorhanden und in der Vergangenheit?
                    $acctExpired = ($null -ne $adUser.AccountExpirationDate) -and
                                   ($adUser.AccountExpirationDate -lt (Get-Date))

                    New-ResultObject `
                        -Sam         $sam `
                        -Enabled     ([bool]$adUser.Enabled) `
                        -LockedOut   ([bool]$adUser.LockedOut) `
                        -PwdExpired  ([bool]$adUser.PasswordExpired) `
                        -AcctExpired $acctExpired `
                        -Source      'RSAT'
                    continue
                }
                catch {
                    # Konto nicht gefunden ? direkt Fehlerobjekt, kein ADSI-Fallback
                    if ($_.Exception.GetType().Name -eq 'ADIdentityNotFoundException') {
                        New-ResultObject -Sam $sam -ErrorMessage "Konto nicht gefunden: $_" -Source 'RSAT'
                        continue
                    }
                    Write-Verbose "RSAT-Fehler fuer '$sam': $_ - Fallback auf ADSI."
                }
            }
            #endregion

            #region --- ADSI-Fallback ---
            try {
                $adsi = Get-ADAccountStatusViaADSI -Sam $sam

                New-ResultObject `
                    -Sam        $sam `
                    -Enabled    $adsi.Enabled `
                    -LockedOut  $adsi.LockedOut `
                    -PwdExpired $adsi.PasswordExpired `
                    -AcctExpired $adsi.AccountExpired `
                    -Source     'ADSI'
            }
            catch {
                New-ResultObject -Sam $sam -ErrorMessage $_.ToString() -Source 'ADSI'
            }
            #endregion
        }
    }
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmADGroupMembers

**Lists all members of an Active Directory group.**

### Description

Simple, reliable function to list members of an AD group (including nested groups).
    Useful when SQL Server access fails and you need to check group permissions.

    Supports NESTED GROUPS: Recursively resolves all members, including members of nested groups.
    Example: If GroupA contains GroupB (which contains User2), both GroupB and User2 are returned.

    Methods:
    1. Get-ADGroupMember -Recursive (if ActiveDirectory module available) — Resolves nested groups
    2. LDAP direct query (fallback, no module required) — Direct members only

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -GroupName | *object* | * | Name of the AD group. Pipeline-capable.     Format: "GroupName" or "DOMAIN\GroupName" |
| -Domain | *object* | * | Optional: AD domain (e.g., "FITS.LOCAL", "corp.de")     If not specified, auto-detects current domai |

### Returns

**Type:** PSCustomObject with GroupName, MemberCount, Members[], TxtFile, CsvFile, Status

### Examples

**Example 1:**
\\\powershell
Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"
\\\`n
**Example 2:**
\\\powershell
Get-sqmADGroupMembers -GroupName "Administrators" -Domain "FITS"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmLoginSettings

**Zeigt alle Logins mit Default-Datenbank und Spracheinstellung.**

### Description

Liest sys.server_principals und gibt pro Login aus:
    - Name, Typ (SQL / Windows-User / Windows-Gruppe)
    - Default-Datenbank
    - Default-Sprache
    - Aktiviert / deaktiviert
    - Erstellungs- und Aenderungsdatum

    Ausgabe direkt als Objekte. Optional als CSV nach OutputPath.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername. |
| -SqlCredential | *object* | * | Optionales PSCredential. |
| -LoginType | *object* | * | Filter: 'All' (Standard), 'SQL', 'Windows' |
| -ExcludeSystemLogins | *object* | * | NT SERVICE\*, NT AUTHORITY\*, ##MS_*## automatisch ausblenden. |
| -DefaultDatabase | *object* | * | Filter: nur Logins mit dieser Default-Datenbank anzeigen. |
| -DefaultLanguage | *object* | * | Filter: nur Logins mit dieser Sprache anzeigen. |
| -OutputPath | *object* | * | Wenn angegeben, wird eine CSV-Datei geschrieben.     Standard: kein Export. |
| -ContinueOnError | *object* | * | Bei Fehler auf einer Instanz fortfahren. |
| -EnableException | *object* | * | Fehler sofort als Ausnahme ausloesen. |

### Examples

**Example 1:**
\\\powershell
Get-sqmLoginSettings
\\\`n
**Example 2:**
\\\powershell
Get-sqmLoginSettings -SqlInstance "SQL01" -ExcludeSystemLogins
\\\`n
**Example 3:**
\\\powershell
Get-sqmLoginSettings -SqlInstance "SQL01" -DefaultDatabase "master" -DefaultLanguage "us_english"
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Review audit logs after bulk changes
- Test permissions in non-prod first
- Maintain password policies compliance

---

## Get-sqmSysadminAccounts

**Retrieves all logins with sysadmin rights on a SQL Server instance.**

### Description

Queries sys.server_principals and sys.server_role_members and returns
    all direct members of the sysadmin server role.

    Per login the following information is determined:
    - Login name and login type (SQL, Windows user, Windows group, etc.)
    - Enabled / disabled
    - Is SA (SID 0x01) or not
    - Creation date
    - Whether the login was explicitly excluded (-ExcludeLogin)

    With -ExcludeLogin, known/expected accounts can be filtered from the report
    (they are marked as 'Excluded').

    With -ExcludeSysAccounts, known SQL Server system and service accounts are
    automatically marked as 'Excluded'.

    BUILTIN\Administrators receives its own status 'BuiltinAdmins'
    and is NOT automatically excluded - security review required.

    Output:
        SysadminAccounts_<instance>_<date>.txt   - Readable report
        SysadminAccounts_<instance>_<date>.csv   - Machine-readable

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -ExcludeLogin | *object* | * | Logins to be marked as 'Excluded' (wildcards allowed). |
| -ExcludeSysAccounts | *object* | * | When set, known system accounts are automatically excluded. |
| -IncludeDisabled | *object* | * | If $true (default), disabled sysadmin logins are also included. |
| -OutputPath | *object* | * | Output directory for report files. Default: C:\System\WinSrvLog\MSSQL |
| -ContinueOnError | *object* | * | Continue on error for an instance. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before writing files. |
| -WhatIf | *object* | * | Shows which files would be created without writing them. |

### Examples

**Example 1:**
\\\powershell
Get-sqmSysadminAccounts
\\\`n
**Example 2:**
\\\powershell
Get-sqmSysadminAccounts -SqlInstance "SQL01" -ExcludeSysAccounts
#>
function Get-sqmSysadminAccounts
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin = @(),
		[Parameter(Mandatory = $false)]
		[switch]$ExcludeSysAccounts,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeDisabled = $true,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
		
		# Systemkonten-Muster fuer -ExcludeSysAccounts
		$sysAccountPatterns = @(
			'NT SERVICE\*',
			'NT AUTHORITY\SYSTEM',
			'NT AUTHORITY\NETWORK SERVICE',
			'NT AUTHORITY\LOCAL SERVICE',
			'NT AUTHORITY\*',
			'##MS_*##'
		)
		
		if ($ExcludeSysAccounts)
		{
			$ExcludeLogin = @($ExcludeLogin) + $sysAccountPatterns | Sort-Object -Unique
			Invoke-sqmLogging -Message "ExcludeSysAccounts: $($sysAccountPatterns.Count) Systemmuster hinzugefuegt." -FunctionName $functionName -Level "DEBUG"
		}
		
		# Hilfsfunktion fuer Ausschlusspruefung
		function _IsExcluded
		{
			param ([string]$Name,
				[string[]]$Patterns)
			if (-not $Patterns) { return $false }
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Starte Sysadmin-Audit ..." -FunctionName $functionName -Level "INFO"
				
				$disabledFilter = if ($IncludeDisabled) { '' }
				else { 'AND sp.is_disabled = 0' }
				
				# Achtung: password_last_set_time und last_login_date wurden entfernt,
				# da sie in aelteren SQL Server-Versionen nicht existieren.
				$query = @"
SELECT
    sp.name                                          AS LoginName,
    sp.type_desc                                     AS LoginType,
    sp.is_disabled                                   AS IsDisabled,
    CASE WHEN sp.sid = 0x01 THEN 1 ELSE 0 END        AS IsSa,
    sp.create_date                                   AS CreateDate,
    sp.modify_date                                   AS ModifyDate,
    NULL                                             AS LastPasswordChange,
    NULL                                             AS LastLogin,
    sp.default_database_name                         AS DefaultDatabase
FROM sys.server_principals       sp
JOIN sys.server_role_members     rm ON rm.member_principal_id = sp.principal_id
JOIN sys.server_principals       sr ON sr.principal_id        = rm.role_principal_id
WHERE sr.name        = 'sysadmin'
  AND sp.type        IN ('S','U','G','R')
  AND sp.principal_id > 1
  $disabledFilter
ORDER BY sp.type_desc, sp.name;
"@
				$rows = Invoke-DbaQuery @connParams -Query $query -EnableException:$EnableException
				
				if (-not $rows)
				{
					$msg = "Keine sysadmin-Logins auf '$instance' gefunden (unerwartet)."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$detailRows.Add([PSCustomObject]@{
							SqlInstance	       = $instance
							LoginName		   = '(keine)'
							LoginType		   = 'n/a'
							IsEnabled		   = $null
							IsSa			   = $false
							LastPasswordChange = $null
							LastLogin		   = $null
							CreateDate		   = $null
							Status			   = 'Error'
							Message		       = $msg
						})
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] $($rows.Count) sysadmin-Login(s) gefunden." -FunctionName $functionName -Level "INFO"
					
					foreach ($row in $rows)
					{
						$loginName = $row.LoginName
						$isSa = [bool]$row.IsSa
						$isEnabled = -not [bool]$row.IsDisabled
						$excluded = _IsExcluded $loginName $ExcludeLogin
						$isBuiltinAdmins = ($loginName -eq 'BUILTIN\Administrators')
						
						$status = if ($isSa) { 'SA' }
						elseif ($isBuiltinAdmins) { 'BuiltinAdmins' }
						elseif ($excluded) { 'Excluded' }
						elseif (-not $isEnabled) { 'Disabled' }
						else { 'Unexpected' }
						
						$msg = switch ($status)
						{
							'SA'            { 'SA-Konto (SID 0x01).' }
							'BuiltinAdmins' { 'BUILTIN\Administrators hat Sysadmin-Rechte - SICHERHEITSPRueFUNG ERFORDERLICH.' }
							'Excluded'      { 'Ausgeschlossen via -ExcludeLogin.' }
							'Disabled'      { 'Login hat sysadmin-Rechte, ist aber deaktiviert.' }
							'Unexpected'    { 'Sysadmin-Login - kein Ausschluss definiert.' }
						}
						
						$createDate = if ($row.CreateDate) { $row.CreateDate.ToString('yyyy-MM-dd') }
						else { $null }
						
						$detailRows.Add([PSCustomObject]@{
								SqlInstance = $instance
								LoginName   = $loginName
								LoginType   = $row.LoginType
								IsEnabled   = $isEnabled
								IsSa	    = $isSa
								LastPasswordChange = $null # Nicht verfuegbar in aelteren Versionen
								LastLogin   = $null # Nicht verfuegbar in aelteren Versionen
								CreateDate  = $createDate
								Status	    = $status
								Message	    = $msg
							})
					}
				}
				
				# Statistik
				$cntSa = ($detailRows | Where-Object Status -eq 'SA').Count
				$cntExcluded = ($detailRows | Where-Object Status -eq 'Excluded').Count
				$cntDisabled = ($detailRows | Where-Object Status -eq 'Disabled').Count
				$cntUnexpected = ($detailRows | Where-Object Status -eq 'Unexpected').Count
				$cntBuiltinAdmins = ($detailRows | Where-Object Status -eq 'BuiltinAdmins').Count
				
				Invoke-sqmLogging -Message ("[$instance] Gesamt: $($detailRows.Count) | SA: $cntSa | Ausgeschlossen: $cntExcluded | " +
					"Deaktiviert: $cntDisabled | Unerwartet: $cntUnexpected | BUILTIN\\Admins: $cntBuiltinAdmins") -FunctionName $functionName -Level "INFO"
				
				# Dateien schreiben
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeInst = $instance -replace '[\\/:*?"<>|]', '_'
				$txtFile = Join-Path $OutputPath "SysadminAccounts_${safeInst}_${datestamp}.txt"
				$csvFile = Join-Path $OutputPath "SysadminAccounts_${safeInst}_${datestamp}.csv"
				
				if ($PSCmdlet.ShouldProcess($instance, "Erstelle Sysadmin-Bericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
					}
					
					# TXT-Bericht (identisch zum vorherigen, daher hier ausgelassen - bitte aus Original uebernehmen)
					# ... (der Code fuer die TXT-Erstellung bleibt unveraendert)
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - Sysadmin-Konten Bericht")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz   : $instance")
					$lines.Add("# Erstellt  : $timestamp")
					$lines.Add("# Gesamt    : $($detailRows.Count) Logins")
					$lines.Add("# SA        : $cntSa")
					$lines.Add("# Ausgesch. : $cntExcluded")
					$lines.Add("# Deaktiv.  : $cntDisabled")
					$lines.Add("# Unerwartet: $cntUnexpected  ? PRueFEN")
					$lines.Add("# BUILTIN\\Adm: $cntBuiltinAdmins  ? SICHERHEITSPRueFUNG")
					$lines.Add("# SysExclude: $(if ($ExcludeSysAccounts) { 'Ja (NT SERVICE\*, NT AUTHORITY\*, ##MS_*##)' }
							else { 'Nein (manuell via -ExcludeLogin)' })")
					$lines.Add("# ================================================================")
					
					# BUILTIN\Administrators
					$builtinEntries = $detailRows | Where-Object { $_.Status -eq 'BuiltinAdmins' }
					$lines.Add(""); $lines.Add("# ================================================================")
					$lines.Add("# BUILTIN\Administrators - SICHERHEITSPRueFUNG ERFORDERLICH ($cntBuiltinAdmins)")
					$lines.Add("# ================================================================")
					if ($builtinEntries)
					{
						foreach ($e in $builtinEntries)
						{
							$lines.Add(("  Name   : {0}" -f $e.LoginName))
							$lines.Add(("  Typ    : {0}  |  Aktiv: {1}  |  Erstellt: {2}" -f $e.LoginType, $e.IsEnabled, $e.CreateDate))
							$lines.Add("  ? Empfehlung: Pruefen ob BUILTIN\Administrators Sysadmin-Rechte")
							$lines.Add("    gemaess Sicherheitsrichtlinie zulaessig sind. Ggf. entfernen:")
							$lines.Add("    EXEC sp_dropsrvrolemember 'BUILTIN\Administrators','sysadmin';")
						}
					}
					else { $lines.Add("  (nicht vorhanden - kein Befund)") }
					
					# Unerwartete Konten
					$unexpected = $detailRows | Where-Object { $_.Status -eq 'Unexpected' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# UNERWARTETE SYSADMIN-KONTEN ($cntUnexpected)  ? PRueFEN")
					$lines.Add("# ----------------------------------------------------------------")
					if ($unexpected)
					{
						foreach ($e in ($unexpected | Sort-Object LoginType, LoginName))
						{
							$lines.Add(("  {0,-40} {1,-20} Enabled:{2,-5} Erstellt:{3}" -f $e.LoginName, $e.LoginType, $e.IsEnabled, $e.CreateDate))
						}
					}
					else { $lines.Add("  (keine)") }
					
					# Deaktivierte Konten
					$disabledEntries = $detailRows | Where-Object { $_.Status -eq 'Disabled' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# DEAKTIVIERTE SYSADMIN-KONTEN ($cntDisabled)")
					$lines.Add("# ----------------------------------------------------------------")
					if ($disabledEntries)
					{
						foreach ($e in ($disabledEntries | Sort-Object LoginName))
						{
							$lines.Add("  $($e.LoginName)  [$($e.LoginType)]  Erstellt: $($e.CreateDate)")
						}
					}
					else { $lines.Add("  (keine)") }
					
					# SA-Konto
					$saEntry = $detailRows | Where-Object { $_.Status -eq 'SA' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# SA-KONTO (SID 0x01)")
					$lines.Add("# ----------------------------------------------------------------")
					if ($saEntry)
					{
						foreach ($e in $saEntry)
						{
							$lines.Add(("  Name: {0,-40} Enabled: {1}" -f $e.LoginName, $e.IsEnabled))
						}
					}
					else { $lines.Add("  (nicht gefunden)") }
					
					# Ausgeschlossene Konten
					$excludedEntries = $detailRows | Where-Object { $_.Status -eq 'Excluded' }
					$lines.Add(""); $lines.Add("# ----------------------------------------------------------------")
					$lines.Add("# AUSGESCHLOSSENE KONTEN ($cntExcluded)")
					$lines.Add("# ----------------------------------------------------------------")
					if ($excludedEntries)
					{
						foreach ($e in ($excludedEntries | Sort-Object LoginType, LoginName))
						{
							$lines.Add(("  {0,-40} {1,-20} Enabled:{2}" -f $e.LoginName, $e.LoginType, $e.IsEnabled))
						}
					}
					else { $lines.Add("  (keine)") }
					
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					Invoke-sqmOpenReport -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$instance] Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$txtFile = $null
					$csvFile = $null
				}
				
				if ($cntBuiltinAdmins -gt 0)
				{
					Invoke-sqmLogging -Message ("[$instance] BUILTIN\Administrators hat Sysadmin-Rechte - Sicherheitspruefung erforderlich!") -FunctionName $functionName -Level "WARNING"
				}
				if ($cntUnexpected -gt 0)
				{
					Invoke-sqmLogging -Message ("[$instance] $cntUnexpected unerwartete(s) sysadmin-Konto(en) gefunden.") -FunctionName $functionName -Level "WARNING"
				}
				
				$instanceResult = [PSCustomObject]@{
					SqlInstance							     = $instance
					Timestamp							     = $timestamp
					DetailRows							     = $detailRows
					TxtFile								     = $txtFile
					CsvFile								     = $csvFile
					Status								     = if ($cntUnexpected -gt 0 -or $cntBuiltinAdmins -gt 0) { 'Warning' } else { 'OK' }
				}
				$allInstanceResults.Add($instanceResult)
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allInstanceResults.Add([PSCustomObject]@{
						SqlInstance = $instance
						Status	    = 'Error'
						Message	    = $errMsg
						DetailRows  = $null
						TxtFile	    = $null
						CsvFile	    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanzen verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmSaObfuscation

**Obfuscates the SA account on a SQL Server instance by renaming it, disabling it, and setting a random password.**

### Description

Performs the following steps:
    1. Checks that at least one other active login with sysadmin rights exists (aborts otherwise).
    2. Identifies the SA account via its fixed SID 0x01 (rename-safe).
    3. Generates a secure random password (configurable length).
    4. Sets the new password.
    5. Renames the account (default: 'sqmsa').
    6. Disables the account.

    The generated password is returned in the output object — the caller is responsible for storing it securely.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the SQL connection. |
| -NewName | *object* | * | New name for the SA account. Default: 'sqmsa'. |
| -PasswordLength | *object* | * | Length of the random password (12-128). Default: 18. |
| -ContinueOnError | *object* | * | Continue with the next instance on error (otherwise aborts). |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Prompts for confirmation before critical changes (default: off). |
| -WhatIf | *object* | * | Shows what would happen without making any changes. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmSaObfuscation -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmSaObfuscation -SqlInstance "SQL01" -NewName "hidden_sa" -PasswordLength 24
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Remove-sqmAdOrphanLogin

**Removes Windows logins whose Active Directory account no longer exists (AD orphans).**

### Description

Safe, deliberate cleanup of "dead" AD logins on a SQL Server instance. This is the manual
    counterpart to the detection-only -AuditAdOrphans option of New-sqmAutoLoginSyncJob and is
    intentionally NOT meant for unattended or scheduled use: a missing AD account can be a
    transient domain controller or trust problem, and dropping a valid login would cause an outage.

    Safety model:
    1. The ActiveDirectory module is REQUIRED. If it is missing, -AdModuleAction controls behavior
       (default 'Abort'). Without AD lookups orphans cannot be verified, so nothing is deleted.
    2. Only Windows logins (WINDOWS_LOGIN / WINDOWS_GROUP) are considered.
    3. System logins and ALL sysadmin logins are excluded from removal, always.
    4. A login is treated as an orphan ONLY when Active Directory positively reports the account as
       missing. If the AD query fails, the login is skipped (never deleted).
    5. Logins that own a database are skipped (dropping them would fail or orphan the ownership).
    6. Before removal a rollback script (CREATE LOGIN FROM WINDOWS + server role memberships) is
       written per run, unless -SkipBackup is set.
    7. Every removal honors -WhatIf / -Confirm (ConfirmImpact = High), so nothing is dropped silently.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the instance. |
| -ExcludeLogin | *object* | * | Additional logins to exclude from removal (wildcards allowed). Combined with the always-on     safet |
| -AdModuleAction | *object* | * | Behavior when the ActiveDirectory module is not present:         'Abort'   (default) - stop with an  |
| -BackupPath | *object* | * | Directory for the rollback script. Default: C:\System\WinSrvLog\MSSQL (created if missing). |
| -SkipBackup | *object* | * | Skip writing the rollback script. Not recommended. |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error status. |

### Examples

**Example 1:**
\\\powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -WhatIf
    Lists exactly which AD-orphaned logins would be removed, without changing anything.
\\\`n
**Example 2:**
\\\powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01"
    Removes confirmed AD-orphaned logins after a rollback backup, asking for confirmation per login.
\\\`n
**Example 3:**
\\\powershell
Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -ExcludeLogin 'DOMAIN\KeepThis*' -Confirm:$false
    Removes confirmed orphans (except the excluded pattern) without interactive confirmation.
\\\`n
### Best Practices

- Review audit logs after bulk changes
- Test permissions in non-prod first
- Maintain password policies compliance

---

## Set-sqmDatabaseOwner

**Sets the owner of one or more databases to a uniform login.**

### Description

Checks and corrects the database owner on one or more SQL Server instances.
    Typical use case: after restores or migrations the owner is often a login that no
    longer exists or is incorrect. The function uniformly sets it to the sa account
    (regardless of the actual sa name, which may have been renamed via obfuscation) or
    any other login.

    Process per database:
      1. Read current owner
      2. Check whether a change is necessary (already correct -> skip)
      3. Check whether the target login exists on the instance
      4. Execute ALTER AUTHORIZATION ON DATABASE::<Name> TO <Login>
      5. Log result

    Returns a status object for each database:
      Status = OK / Skipped / Failed / NotFound

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Database | *object* | * | Database name(s). Wildcards allowed (e.g. 'Prod*'). Default: all user databases. |
| -ExcludeDatabase | *object* | * | Databases to exclude. Wildcards allowed. |
| -OwnerLogin | *object* | * | Login to set as the new owner.     Default: sa account (automatically determined via SID 0x01,     |
| -IncludeSystemDatabases | *object* | * | Also include system databases (master, model, msdb). Default: $false.     tempdb is always excluded |
| -Force | *object* | * | Also process databases that already have the correct owner (forces re-assignment). |
| -OutputPath | *object* | * | Directory for the change log. Default: from module configuration. |
| -ContinueOnError | *object* | * | Continue on error for one instance. Default: $false. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Set sa account on all user databases
    Set-sqmDatabaseOwner -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
# Specific databases with a custom login
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -Database "Prod*" -OwnerLogin "svc_sqlowner"
\\\`n
**Example 3:**
\\\powershell
# Pipeline across multiple instances
    'SQL01','SQL02' | Set-sqmDatabaseOwner
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 12. Server Configuration Testing

This section covers **5 functions** related to Server Configuration Testing.


## Get-sqmClusterInfo

**Retrieves information about a Windows Failover Cluster: cluster name, nodes and roles including IP addresses.**

### Description

This function queries a Windows Failover Cluster and returns an object containing the cluster name,
    a list of nodes, and a list of roles (cluster groups).
    For each role, the associated IP address resources are also provided.
    By default, the core cluster group ("Cluster Group") and all storage groups ("Available Storage")
    are excluded from the role list.

    If the required PowerShell module 'FailoverClusters' is not available, an attempt is made to
    install the RSAT clustering tools automatically (Windows Server only, administrator rights required).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ClusterName | *object* | * | The name of the cluster to query. If not specified, the function attempts to determine     the loca |
| -IncludeCoreGroup | *object* | * | Switch to include the core cluster group ("Cluster Group") in the roles list.     Storage groups ar |
| -NoAutoInstall | *object* | * | Suppresses the automatic installation of RSAT clustering tools if the module is missing. |
| -EnableException | *object* | * | When set, errors are thrown as exceptions (by default an error object is returned). |

### Examples

**Example 1:**
\\\powershell
$info = Get-sqmClusterInfo -ClusterName "MYCLUSTER"
    if (-not $info.Success) { Write-Error $info.ErrorMessage; return }
    $info.ClusterName
    $info.Nodes | Format-Table
    $info.Roles | Where-Object OwnerNode -eq "Node1" | Select Name, IPAddresses
\\\`n
**Example 2:**
\\\powershell
Get-sqmClusterInfo -IncludeCoreGroup

    Queries the local cluster and returns all roles including the core group.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmPerfCounters

**Reads SQL Server performance counters from sys.dm_os_performance_counters.**

### Description

Returns the most important SQL Server performance counters:
    Buffer Cache Hit Ratio, Page Life Expectancy, Batch Requests/sec,
    compilations, lock waits, memory, connections, scans and more.
    Automatically interprets values and flags notable ones.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: local computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Category | *object* | * | Filter on category fragments, e.g. @('Buffer','Memory','Locks').     Default: all key counters. |
| -TopN | *object* | * | Maximum number of results. Default: 50. |
| -OutputPath | *object* | * | If specified, a CSV report is saved. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmPerfCounters -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Get-sqmPerfCounters -SqlInstance "SQL01" -Category "Buffer","Memory"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmSpnReport

**Checks the registered SPNs for SQL Server instances (default and named instances).**

### Description

Automatically determines all SQL Server services on the specified computer,
    identifies the service account per instance and derives the AD account for
    the SPN check.

    Supported service account types:
    - Domain account (DOMAIN\svc_sql)        -> used directly as SPN account
    - Computer-account-based accounts (SYSTEM,
      NETWORK SERVICE, NT SERVICE\*)         -> computer account (DOMAIN\HOSTNAME$)
      The computer account is determined cleanly via
      [System.DirectoryServices.ActiveDirectory.Domain].
    - LOCAL SERVICE                          -> no network identity, SPNs
      not possible -> finding with status 'NoNetwork'

    Per instance, the four expected MSSQLSvc SPNs are checked:
        MSSQLSvc/<Hostname>:<Port>
        MSSQLSvc/<FQDN>:<Port>
        MSSQLSvc/<Hostname>        (default instance only, port 1433)
        MSSQLSvc/<FQDN>            (default instance only, port 1433)

    For named instances (dynamic port via SQL Browser), additional instance-name SPNs are checked:
        MSSQLSvc/<Hostname>:<InstanceName>
        MSSQLSvc/<FQDN>:<InstanceName>

    For AlwaysOn Availability Groups, listener SPNs are also checked:
        MSSQLSvc/<ListenerName>:<Port>
        MSSQLSvc/<ListenerFQDN>:<Port>

    Missing SPNs are prepared as ready-to-use setspn.exe commands
    that can be handed to the AD team.

    Output per instance:
        SpnReport_<Computer>_<Instance>_<Date>.txt   - Readable report including setspn commands
        SpnReport_<Computer>_<Instance>_<Date>.csv   - Machine-readable (one row per SPN)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer. Default: local computer. Pipeline-capable. |
| -InstanceFilter | *object* | * | Optional filter on instance names (wildcards allowed).     Example: 'MSSQLSERVER' for default instan |
| -OutputPath | *object* | * | Output directory for report and CSV.     Default: module configuration (Get-sqmConfig -Key 'OutputPa |
| -ContinueOnError | *object* | * | Continue with the next instance on error. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before creating files. |
| -WhatIf | *object* | * | Shows which files would be created without writing them. |

### Examples

**Example 1:**
\\\powershell
Get-sqmSpnReport

    Checks all SQL Server instances on the local computer.
\\\`n
**Example 2:**
\\\powershell
Get-sqmSpnReport -ComputerName 'SQL01' -InstanceFilter 'MSSQLSERVER'

    Checks only the default instance on SQL01.
\\\`n
**Example 3:**
\\\powershell
'SQL01','SQL02' | Get-sqmSpnReport -ContinueOnError

    Checks all instances on two servers; errors are skipped.
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmSQLFirewall

**Tests whether the firewall and network allow a TCP connection to SQL Server.**

### Description

Attempts to establish a TCP connection to the specified SQL Server and port.
    By default, port 1433 (default instance) is used.

    For named instances, the SQL Browser service (UDP 1434) can additionally be
    queried to determine the dynamic TCP port of the instance.

    Returns one [PSCustomObject] per server/port combination with:
        Server, Port, Instance, TcpReachable, DynamicPort, Status, Message

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Server | *object* | * | Hostname or IP address of the SQL Server. Pipeline-capable. |
| -Port | *object* | * | TCP port to test. Default: 1433.     Ignored when -Instance is specified and the SQL Browser provide |
| -Instance | *object* | * | Name of the named instance (without server prefix). When specified, the SQL Browser     (UDP 1434) i |
| -TimeoutSeconds | *object* | * | Timeout for the TCP connection test in seconds. Default: 5. |
| -ContinueOnError | *object* | * | Continue with the next server on error instead of aborting. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |

### Examples

**Example 1:**
\\\powershell
Test-sqmSQLFirewall -Server "SQL01"

    Tests the default instance on TCP port 1433.
\\\`n
**Example 2:**
\\\powershell
Test-sqmSQLFirewall -Server "SQL01" -Port 54321

    Tests a custom port.
\\\`n
**Example 3:**
\\\powershell
Test-sqmSQLFirewall -Server "SQL01" -Instance "SAGE"

    Determines the dynamic port of the "SAGE" instance via SQL Browser (UDP 1434)
    and then tests the TCP connection.
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmSqlInstanceInstalled

**Prueft ob eine SQL Server-Instanz auf dem lokalen System installiert ist.**

### Description

Kombiniert zwei Pruefmethoden:
        1. Registry: HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL
        2. Windows-Dienst: MSSQLSERVER (Default) oder MSSQL$<InstanceName> (Named)

    Gibt ein Objekt mit Installationsstatus, Version, Edition und Dienststatus zurueck.
    Rein lesender Zugriff - keine Aenderungen am System.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -InstanceName | *object* | * | Name der zu pruefenden SQL-Instanz.     Default: "MSSQLSERVER" (Default-Instanz). |

### Examples

**Example 1:**
\\\powershell
Test-sqmSqlInstanceInstalled
    # Prueft Default-Instanz MSSQLSERVER
\\\`n
**Example 2:**
\\\powershell
Test-sqmSqlInstanceInstalled -InstanceName 'INST01'
\\\`n
**Example 3:**
\\\powershell
if ((Test-sqmSqlInstanceInstalled).IsInstalled) { Write-Host "SQL installiert" }
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 4. Monitoring & Health Checks

This section covers **8 functions** related to Monitoring & Health Checks.


## Get-sqmBlockingReport

**Retrieves current blocking chains on a SQL Server instance.**

### Description

Reads sys.dm_exec_requests, sys.dm_exec_sessions and sys.dm_exec_sql_text
    and builds complete blocking chains. For each blocked session the following is returned:
      - Blocking SPID and its SQL text
      - Blocked SPID(s) with wait time, wait type and lock resource
      - Database, login, hostname, program
      - Complete chain (head blocker to all blocked sessions)

    An optional snapshot mode can be enabled: the function then periodically writes
    snapshots as CSV files - useful for Agent jobs for historical analysis.

    Returns an object that can be used directly for further processing:
      .BlockingChains  - List of all chains with head blocker and blocked sessions
      .HeadBlockers    - Only the blocking sessions
      .BlockedSessions - Only the blocked sessions
      .HasBlocking     - $true if blocking was found

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -MinWaitSeconds | *object* | * | Only report blocking that has been waiting longer than this value (in seconds). Default: 0. |
| -OutputPath | *object* | * | If specified, a CSV snapshot is written to this directory. |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning as errors. |

### Examples

**Example 1:**
\\\powershell
Get-sqmBlockingReport
\\\`n
**Example 2:**
\\\powershell
Get-sqmBlockingReport -SqlInstance "SQL01" -MinWaitSeconds 30
\\\`n
**Example 3:**
\\\powershell
# Check whether blocking is currently occurring
    if ((Get-sqmBlockingReport -SqlInstance "SQL01").HasBlocking) { Write-Warning "Blocking detected!" }
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmConnectionStats

**Analyzes active SQL Server connections and connection statistics.**

### Description

Reads sys.dm_exec_sessions and sys.dm_exec_connections and groups
    by application, login, host or database. Shows connection load,
    active requests, CPU usage and oldest connections.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: local computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -GroupBy | *object* | * | Grouping criterion: Application / Login / Host / Database.     Default: Application. |
| -TopN | *object* | * | Number of top groups. Default: 25. |
| -IncludeSystemConnections | *object* | * | Include system connections (is_user_process = 0). |
| -OutputPath | *object* | * | If specified, a CSV report is saved. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmConnectionStats -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Get-sqmConnectionStats -SqlInstance "SQL01" -GroupBy Login -TopN 10
\\\`n
**Example 3:**
\\\powershell
Get-sqmConnectionStats -SqlInstance "SQL01" -GroupBy Database -IncludeSystemConnections
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmDatabaseHealth

**Aggregated health report for all databases on an instance.**

### Description

Checks per database:
    - Recovery model
    - Last DBCC CHECKDB execution and whether it was error-free
    - Last backup times (Full / Diff / Log)
    - AutoGrowth events in the last -HistoryDays days (via default trace)
    - VLF count (excessively fragmented transaction log files)
    - Database size (data + log)
    - Database status (Online, Suspect, Restoring, ...)

    Results are saved as TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -MaxCheckDbAgeDays | *object* | * | Maximum age in days of the last error-free DBCC CHECKDB. Default: 14. |
| -MaxVlfCount | *object* | * | Warning threshold for VLF count per database. Default: 200. |
| -HistoryDays | *object* | * | Time range for AutoGrowth evaluation in days. Default: 30. |
| -ExcludeDatabase | *object* | * | Databases to exclude. Wildcards allowed. |
| -IncludeSystemDatabases | *object* | * | Include system databases (except tempdb). Default: $false. |
| -OutputPath | *object* | * | Output directory for report files. Default: C:\System\WinSrvLog\MSSQL |
| -ContinueOnError | *object* | * | Continue on error for an instance (otherwise the error is thrown). |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before writing files. |
| -WhatIf | *object* | * | Shows which files would be created without actually writing them. |

### Examples

**Example 1:**
\\\powershell
Get-sqmDatabaseHealth
\\\`n
**Example 2:**
\\\powershell
Get-sqmDatabaseHealth -SqlInstance "SQL01" -IncludeSystemDatabases -OutputPath "D:\Reports"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmDeadlockReport

**Reads and analyzes deadlock events from the System Health Extended Event session.**

### Description

The System Health session (always active since SQL Server 2008) logs all
    deadlocks as XML in the ring buffer. This function reads that buffer,
    parses the deadlock graphs and returns for each deadlock:

      - Timestamp of the deadlock
      - Victim session with login, host, program, statement
      - All involved processes with their statements and held/requested locks
      - Involved resources (tables, indexes, objects)
      - Deadlock graph as XML (for SSMS import or storage as .xdl)

    Optionally, deadlock graphs can be saved as .xdl files
    (openable directly in SSMS by double-click).

    Additionally, the System Health .xel ring buffer is read when available
    (SQL Server 2012+, provides more history than the ring buffer).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -StartTime | *object* | * | Return only deadlocks from this point in time. Default: last 24 hours. |
| -EndTime | *object* | * | Return only deadlocks up to this point in time. Default: now. |
| -MaxDeadlocks | *object* | * | Maximum number of deadlocks returned (newest first). Default: 100. |
| -OutputPath | *object* | * | If specified, deadlock graphs are saved as .xdl files in this directory     (format: Deadlock_<Inst |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning as errors. |

### Examples

**Example 1:**
\\\powershell
Get-sqmDeadlockReport
\\\`n
**Example 2:**
\\\powershell
Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-7)
\\\`n
**Example 3:**
\\\powershell
# Save deadlocks as XDL files for SSMS
    Get-sqmDeadlockReport -SqlInstance "SQL01" -OutputPath "$env:ProgramData\sqmSQLTool\Logs\Deadlocks"
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmLongRunningQueries

**Identifies long-running queries on a SQL Server instance.**

### Description

Reads sys.dm_exec_requests, sys.dm_exec_sessions, sys.dm_exec_sql_text and
    sys.dm_exec_query_plan and returns all active requests that exceed the
    configured thresholds.

    Per query the following is returned:
      - Session ID, database, login, host, program
      - Duration in seconds, CPU time, logical/physical reads, writes
      - Current wait type and wait resource
      - Current statement (not just the batch) with start/end offset resolution
      - Query plan hash and query hash (for plan cache comparison)
      - Estimated completion (if percent_complete > 0)
      - Transaction isolation level

    System sessions (session_id <= 50) and the own request are automatically excluded.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -MinDurationSeconds | *object* | * | Return only queries running longer than this value (seconds). Default: 30. |
| -MinCpuMs | *object* | * | Return only queries whose CPU time exceeds this value (milliseconds). Default: 0. |
| -ExcludeWaitType | *object* | * | Wait types to exclude (e.g. 'SLEEP_TASK','WAITFOR'). Default: common idle waits. |
| -IncludeSystemSessions | *object* | * | Include system sessions (SPID <= 50) as well. Default: $false. |
| -IncludeQueryPlan | *object* | * | Retrieve the XML execution plan as well (expensive - only on demand). Default: $false. |
| -OutputPath | *object* | * | If specified, a CSV snapshot is written to this directory. |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning as errors. |

### Examples

**Example 1:**
\\\powershell
Get-sqmLongRunningQueries
\\\`n
**Example 2:**
\\\powershell
Get-sqmLongRunningQueries -SqlInstance "SQL01" -MinDurationSeconds 60
\\\`n
**Example 3:**
\\\powershell
# Top 10 by duration
    Get-sqmLongRunningQueries -MinDurationSeconds 10 | Sort-Object DurationSeconds -Descending | Select-Object -First 10
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmServerSetting

**Reads one or all server properties from a SQL Server instance.**

### Description

The function queries either a named property value (e.g. "BackupDirectory") from the
object returned by Connect-DbaInstance, or lists all properties with -All.

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME)
is used by default.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). If not specified, the current  |
| -SqlCredential | *object* | * | Alternative credentials (PSCredential). If not specified, Windows Authentication is used. |
| -Name | *object* | * | The name of the server property to retrieve. Only the following values are allowed: BackupDirectory |
| -All | *object* | * | When set, all properties of the server object are returned as a list. |
| -DefaultValue | *object* | * | Optional default value if the property does not exist or cannot be read. Ignored when -All is used. |
| -EnableException | *object* | * | Switch to allow exceptions to pass through (by default errors are logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Read BackupDirectory from the local server
$backupPath = Get-sqmServerSetting -Name "BackupDirectory"
\\\`n
**Example 2:**
\\\powershell
# Show all properties
Get-sqmServerSetting -All
\\\`n
**Example 3:**
\\\powershell
# All properties from a remote instance with credentials
$cred = Get-Credential
Get-sqmServerSetting -SqlInstance "SQL01" -SqlCredential $cred -All
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmSQLInstanceCheck

**Checks a SQL Server instance against best practices.**

### Description

The function performs a series of best practice checks:
- Max Degree of Parallelism (MAXDOP) - recommendation based on number of cores
- Max Server Memory - should not be too high (reserve for OS)
- Cost Threshold for Parallelism - recommendation >= 50
- Backup Directory - existence and write permissions (optional)
- SA account - renaming and disabling
- xp_cmdshell - should be disabled (unless required)
- Database autogrow settings - percent vs. MB, appropriate values
- TempDB - number of files (should match number of cores, max 8), equal size, path
- Isolated volumes - check whether database files are on separate drives (optional)
- SQL Server version / service pack - checks for outdated versions (optional)

If no SqlInstance parameter is specified, the current computer name ($env:COMPUTERNAME)
is used by default.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | Alternative credentials. |
| -Detailed | *object* | * | Detailed output (e.g. path checks, analyze all databases). Default: $false. |
| -EnableException | *object* | * | Allow exceptions to pass through. |

### Examples

**Example 1:**
\\\powershell
Get-sqmSQLInstanceCheck
\\\`n
**Example 2:**
\\\powershell
Get-sqmSQLInstanceCheck -SqlInstance "SQL01\INSTANCE" -Detailed
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmLoginAudit

**Comprehensive audit of all SQL Server logins on one or more instances.**

### Description

Checks per login:
    - POLICY VIOLATIONS (CHECK_POLICY/EXPIRATION/MUST_CHANGE)
    - Password age and whether it was never changed
    - Inactive / never-used logins
    - Duplicate SIDs (failed migration)
    - AD-orphaned Windows logins (optional)

    Output as TXT report and CSV (findings only) in the configured OutputPath.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential. |
| -InactivityThresholdDays | *object* | * | Logins without login since this value are considered inactive. Default: 90. |
| -MaxPasswordAgeDays | *object* | * | SQL logins with password older than this value are reported (non-sysadmins). Default: 180. 0 = disab |
| -MaxPasswordAgeDaysSysadmin | *object* | * | SQL logins with password older than this value are reported (sysadmins). Default: 365. 0 = disabled. |
| -ExcludeLogin | *object* | * | Logins to exclude (wildcards). E.g. 'NT SERVICE\*', 'sqmsa'. |
| -IncludeSystemLogins | *object* | * | When set, NT SERVICE\*, NT AUTHORITY\* are also included. |
| -CheckPolicyNonSysadmin | *object* | * | Check password policy violations for non-sysadmin logins. Default: $true. |
| -CheckPolicySysadmin | *object* | * | Check password policy violations for sysadmin logins. Default: $true. |
| -ReportBuiltInAdmins | *object* | * | When BUILTIN\Administrators is found in logins, report as warning. Default: $true. |
| -CheckAdOrphans | *object* | * | When set, AD orphan check is performed for Windows logins (requires AD module). |
| -GenerateHtmlReport | *object* | * | Generate HTML report in addition to TXT/CSV. Default: $true. |
| -HtmlReportTemplate | *object* | * | HTML template style: 'Standard', 'Compact', 'Detailed'. Default: 'Standard'. |
| -OutputPath | *object* | * | Output directory. Default: from module configuration (Get-sqmDefaultOutputPath). |
| -ContinueOnError | *object* | * | Continue on error for an instance. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before file creation. |
| -WhatIf | *object* | * | Shows what would happen. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmLoginAudit
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmLoginAudit -SqlInstance "SQL01" -CheckAdOrphans -IncludeSystemLogins
\\\`n
### Best Practices

- Review audit logs after bulk changes
- Test permissions in non-prod first
- Maintain password policies compliance

---

# 8. Storage & Disk Management

This section covers **6 functions** related to Storage & Disk Management.


## Copy-sqmNTFSPermissions

**Copies NTFS permissions (ACLs) from a source path to a destination path.**

### Description

Reads the explicit NTFS permissions for each file system object (folder/file) below
    the source path and applies them to the corresponding object below the destination path.
    The target structure must already exist (exception: with -CreateMissingFolders, missing
    target folders are created automatically).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SourcePath | *object* | * | Source path (e.g. "D:\" or "D:\Data"). |
| -DestinationPath | *object* | * | Destination path (e.g. "E:\" or "E:\Data"). |
| -Recurse | *object* | * | Recursive traversal of all subfolders and files. |
| -CreateMissingFolders | *object* | * | Automatically creates missing target folders (directories only, not files).     Files missing at the |
| -IncludeSystemAndHidden | *object* | * | Includes hidden and system objects in the processing. |

### Examples

**Example 1:**
\\\powershell
Copy-sqmNTFSPermissions -SourcePath "D:\" -DestinationPath "E:\" -Recurse
    Copies all permissions from D: to E: (recursively).
\\\`n
**Example 2:**
\\\powershell
Copy-sqmNTFSPermissions -SourcePath "D:\Daten" -DestinationPath "E:\Daten" -Recurse -CreateMissingFolders
    Copies permissions and creates missing target folders.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmDiskBlockSize

**Prueft die NTFS-Blockgroesse (Cluster-Groesse) von Laufwerken auf 64KB.**

### Description

Liest die NTFS-Allokationseinheit (Blockgroesse) der angegebenen Laufwerke
    per WMI (Win32_Volume) und prueft ob die fuer SQL Server empfohlenen
    64 KB (65536 Bytes) konfiguriert sind.

    Kann entweder gezielt einzelne Laufwerkbuchstaben pruefen oder automatisch
    alle Laufwerke ermitteln die von einer SQL Server-Instanz genutzt werden
    (Data, Log, Backup, TempDB).

    Rein lesender Zugriff - keine Aenderungen am System.
    Zum Formatieren: Invoke-sqmFormatDrive64k

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Drive | *object* | * | Laufwerkbuchstabe(n) ohne Doppelpunkt, z.B. 'F', 'G', 'H'.     Pipeline-faehig. Wenn nicht angegeben |
| -SqlInstance | *object* | * | SQL Server-Instanz. Wenn angegeben werden automatisch alle von SQL Server     genutzten Laufwerke (D |
| -ComputerName | *object* | * | Zielcomputer fuer die WMI-Abfrage. Standard: lokaler Computer. |
| -RecommendedBlockSize | *object* | * | Empfohlene Blockgroesse in Bytes. Standard: 65536 (64 KB). |
| -EnableException | *object* | * | Ausnahmen sofort ausloesen statt Write-Error. |

### Examples

**Example 1:**
\\\powershell
# Einzelne Laufwerke pruefen
    Get-sqmDiskBlockSize -Drive 'F', 'G', 'H'
\\\`n
**Example 2:**
\\\powershell
# Automatisch alle SQL-Laufwerke der Instanz ermitteln und pruefen
    Get-sqmDiskBlockSize -SqlInstance "SQL01"
\\\`n
**Example 3:**
\\\powershell
# Pipeline
    'F','G' | Get-sqmDiskBlockSize
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmDiskInfoByDriveLetter

**Returns disk information for a given drive letter.**

### Description

Accepts a drive letter, determines the associated disk number (disk number)
    and returns the total size, free space, percentage free and the serial number
    (LUN serial number) of the physical disk.

    The result is returned as a PSCustomObject and also copied to the clipboard
    as a formatted text table.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -DriveLetter | *object* | * | Drive letter of the volume (e.g. "C", "C:" or "D:"). |
| -NoClipboard | *object* | * | Suppresses copying the result to the clipboard. |

### Examples

**Example 1:**
\\\powershell
Get-sqmDiskInfoByDriveLetter -DriveLetter "C"

    Returns disk information for drive C: and copies it to the clipboard.
\\\`n
**Example 2:**
\\\powershell
Get-sqmDiskInfoByDriveLetter "D:" -NoClipboard

    Returns disk information for drive D: without clipboard output.
\\\`n
**Example 3:**
\\\powershell
"C","D","E" | ForEach-Object { Get-sqmDiskInfoByDriveLetter $_ }

    Returns disk information for multiple drives.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmDiskSpaceReport

****

### Description

Queries sys.dm_os_volume_stats for all database files and determines:
    - Free disk space per volume
    - Total size of database files on the volume
    - AutoGrowth volume over the last -HistoryDays days (from default trace)
    - Estimated days until exhaustion based on growth rate
    - Warning when free space falls below -WarnThresholdPct

    Results are saved as TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -WarnThresholdPct | *object* | * | Warning when free space falls below this percentage. Default: 20. |
| -CriticalThresholdPct | *object* | * | Critical when free space falls below this percentage. Default: 10. |
| -HistoryDays | *object* | * | Time range for growth calculation in days. Default: 30. |
| -OutputPath | *object* | * | Output directory for report files. Default: C:\System\WinSrvLog\MSSQL |
| -ContinueOnError | *object* | * | Continue on error for an instance (otherwise the error is thrown). |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before writing files. |
| -WhatIf | *object* | * | Shows which files would be created without actually writing them. |

### Examples

**Example 1:**
\\\powershell
Get-sqmDiskSpaceReport
\\\`n
**Example 2:**
\\\powershell
Get-sqmDiskSpaceReport -SqlInstance "SQL01" -WarnThresholdPct 15 -OutputPath "D:\Reports"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmOrphanedFiles

**Finds MDF/LDF/NDF database files that are not assigned to any database.**

### Description

Reads all registered database files from sys.master_files and compares them
    with the files actually present in the directories.
    Files that exist on the file system but are not registered in sys.master_files
    are reported as orphaned.

    Note: Directories are searched from the PowerShell session.
    For remote instances, paths must be accessible as UNC paths or
    SearchPath must be specified explicitly as a UNC path.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: local computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -SearchPath | *object* | * | Directories to search.     Default: all unique directories from sys.master_files + SQL Server defaul |
| -FileExtension | *object* | * | File extensions to search for.     Default: .mdf, .ldf, .ndf |
| -Recurse | *object* | * | Recursively search subdirectories. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmOrphanedFiles -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Get-sqmOrphanedFiles -SqlInstance "SQL01" -SearchPath "D:\SQLData","E:\SQLLog" -Recurse
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmFormatDrive64k

****

### Description

Process:
        1. Safety checks (not C:, NTFS, one primary partition).
        2. Save drive metadata (letter, label, partition size).
        3. Check allocation unit via Get-Volume / fsutil.
        4. If cluster size is already 65536 bytes -> abort with status 'AlreadyOK'.
        5. Check whether the drive is in use by a process.
           If so: warning and abort (status 'InUse').
        6. If drive contains data: back up with robocopy to
           $BackupPath\<Letter>_<Timestamp>\.
        7. Format-Volume with -AllocationUnitSize 65536 -FileSystem NTFS.
        8. Restore drive letter and label.
        9. If data was backed up: restore with robocopy.
           Restore error -> warning, backup remains on C:.
       10. Delete backup on C: only if robocopy restored without errors.

    Safety rules:
        - Drive C: is never formatted (hard-coded guard).
        - Only NTFS volumes are accepted.
        - Only drives with exactly one primary partition.
        - Drives opened by a process -> abort.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -DriveLetter | *object* | * | Target drive letter (single letter, e.g. 'D'). Mandatory.     C is explicitly prohibited. |
| -BackupPath | *object* | * | Temporary backup path on C: for data backup before formatting.     Default: C:\System\DriveBackup.   |
| -Force | *object* | * | Skips the interactive confirmation prompt before formatting. |
| -WhatIf | *object* | * | Simulates all steps without making changes. |
| -Confirm | *object* | * | Requests explicit confirmation before formatting. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmFormatDrive64k -DriveLetter D

    Checks drive D: and formats it with 64 KB clusters if needed.
    Data is backed up to C:\System\DriveBackup first.
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmFormatDrive64k -DriveLetter E -BackupPath "C:\Backup\DriveTemp" -Force

    Same as above, without confirmation prompt, using a different backup path.
\\\`n
**Example 3:**
\\\powershell
Invoke-sqmFormatDrive64k -DriveLetter D -WhatIf

    Simulates the entire process without making any changes.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 11. Module & Update Management

This section covers **6 functions** related to Module & Update Management.


## Install-sqmAdModule

**Ensures that the ActiveDirectory PowerShell module (RSAT) is installed.**

### Description

First checks whether the ActiveDirectory module is already available.
    If not, the function attempts installation using four methods in the following
    order (fallback chain):

        1. Windows Capability  (Add-WindowsCapability)
           Target: Windows 10/11 clients and Windows Server 2019+
           Package: Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

        2. Windows Feature  (Install-WindowsFeature)
           Target: Windows Server (all versions with ServerManager)
           Feature: RSAT-AD-PowerShell

        3. DISM  (dism.exe /Online /Add-Capability)
           Target: older systems or environments without ServerManager/PS cmdlets
           Capability: Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

        4. PSGallery  (Install-Module ActiveDirectory)
           Target: systems with internet access and PSGallery access, when all
                   other methods are unavailable or failed.
           Scope: first CurrentUser, then AllUsers.
           Prerequisite: NuGet provider >= 2.8.5.201 (installed automatically if missing).

    Each method is only attempted if the responsible cmdlets or tool are present
    on the system. If a method fails, the next one is tried.

    After successful installation, Import-Module ActiveDirectory is run
    to load the module into the current session.

    Permission note:
        All installation methods require local administrator rights.
        The function checks this beforehand and returns an informative error.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SkipIfPresent | *object* | * | If $true (default) and the module is already present, $true is returned     immediately without att |
| -ContinueOnError | *object* | * | When set, the function returns $false on failed installation instead of throwing an error. |
| -EnableException | *object* | * | When set, the function throws an exception on failed installation     (overrides ContinueOnError). |
| -WhatIf | *object* | * | Shows which installation method would be attempted, without executing it. |
| -Confirm | *object* | * | Request confirmation before installation. |

### Examples

**Example 1:**
\\\powershell
Install-sqmAdModule

    Checks whether the AD module is present and installs it if necessary.
\\\`n
**Example 2:**
\\\powershell
Install-sqmAdModule -ContinueOnError

    Returns $false if installation fails instead of throwing an exception.
\\\`n
**Example 3:**
\\\powershell
if (-not (Install-sqmAdModule -ContinueOnError))
    {
        Write-Warning "AD module not available - AD check will be skipped."
    }
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmModuleUpdate

**Checks all configured update sources for a newer sqmSQLTool version.**

### Description

Checks GitHub, PSGallery and/or a UNC share for newer versions of sqmSQLTool.
    Returns combined results from all reachable sources.
    Use -Source to limit the check to specific sources.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Source | *object* | * | Which sources to check. Valid values: GitHub, PSGallery, UNC, All.     Default: All |
| -RepositoryPath | *object* | * | UNC path for the UNC source check.     Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error object. |

### Examples

**Example 1:**
\\\powershell
Test-sqmModuleUpdate
\\\`n
**Example 2:**
\\\powershell
Test-sqmModuleUpdate -Source GitHub
\\\`n
**Example 3:**
\\\powershell
Test-sqmModuleUpdate -Source UNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmUpdateViaGitHub

**Checks if a newer version of sqmSQLTool is available on GitHub.**

### Description

Queries the GitHub Releases API for the latest release tag of sqmSQLTool
    and compares it with the locally installed version.
    Returns a PSCustomObject with UpdateAvailable, LocalVersion, RemoteVersion and DownloadUrl.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Owner | *object* | * | GitHub repository owner. Default: JankeUwe |
| -Repository | *object* | * | GitHub repository name. Default: sqmSQLTool |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error object. |

### Examples

**Example 1:**
\\\powershell
Test-sqmUpdateViaGitHub
\\\`n
**Example 2:**
\\\powershell
$result = Test-sqmUpdateViaGitHub
    if ($result.UpdateAvailable) { Write-Host "Update available: $($result.RemoteVersion)" }
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Test-sqmUpdateViaPSGallery

**Checks if a newer version of sqmSQLTool is available on PowerShell Gallery.**

### Description

Queries PowerShell Gallery for the latest published version of sqmSQLTool
    and compares it with the locally installed version.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ModuleName | *object* | * | Module name to check. Default: sqmSQLTool |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error object. |

### Examples

**Example 1:**
\\\powershell
Test-sqmUpdateViaPSGallery
\\\`n
**Example 2:**
\\\powershell
$result = Test-sqmUpdateViaPSGallery
    if ($result.UpdateAvailable) { Update-sqmModule -Source PSGallery }
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmUpdateViaUNC

**Checks if a newer version of sqmSQLTool is available on a UNC share.**

### Description

Compares the locally installed sqmSQLTool version with the version in the
    specified UNC share. Reads ModuleVersion.txt or sqmSQLTool.psd1 from the share.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -RepositoryPath | *object* | * | UNC path to the sqmSQLTool repository share.     Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error object. |

### Examples

**Example 1:**
\\\powershell
Test-sqmUpdateViaUNC
\\\`n
**Example 2:**
\\\powershell
Test-sqmUpdateViaUNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Update-sqmModule

**Updates the sqmSQLTool module from GitHub, PSGallery or a UNC share.**

### Description

Downloads and installs the latest version of sqmSQLTool from the specified source.

    Process:
    1. Check if update is available (via Test-sqmModuleUpdate)
    2. Create backup of current installation
    3. Download/copy new version
    4. Unblock all files (remove Zone.Identifier ADS)
    5. Verify import succeeds
    6. Report installed version

    Sources:
    - GitHub  : Downloads latest release ZIP from GitHub Releases
    - PSGallery: Installs via Install-Module / Update-Module
    - UNC     : Copies from share using robocopy (same as Update.ps1)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Source | *object* | * | Update source. Valid values: GitHub, PSGallery, UNC.     Default: GitHub |
| -RepositoryPath | *object* | * | UNC path for UNC source.     Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool |
| -Destination | *object* | * | Installation path for the module.     Default: C:\Windows\System32\WindowsPowerShell\v1.0\Modules\sq |
| -Force | *object* | * | Install even if no newer version is available. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Update-sqmModule
\\\`n
**Example 2:**
\\\powershell
Update-sqmModule -Source GitHub -Force
\\\`n
**Example 3:**
\\\powershell
Update-sqmModule -Source UNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 16. SQL Drivers & Tools Installation

This section covers **6 functions** related to SQL Drivers & Tools Installation.


## Install-sqmDb2Driver

**Installiert den IBM DB2 ODBC/CLI-Treiber.**

### Description

Prueft ob ein DB2-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled -DriverType DB2).
    Bei Bedarf: Fuehrt den IBM-Installer still aus.

    Unterstuetzte Installer-Formate:
        - db2_odbc_cli.exe / db2_odbc_cli_64.exe : IBM CLI-Treiber
        - setup.exe (DB2 Client)                  : Vollstaendiger IBM-Installer
        - .msi                                    : MSI-basierter Installer

    Falls der Treiber nach der Installation nicht automatisch als ODBC-Treiber
    registriert ist, wird db2cli.exe -setup -registerall ausgefuehrt.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SourcePath | *object* | * | Pfad zum DB2-Installer oder Verzeichnis mit dem Installer.     Z.B.: \\srv\Treiber\DB2 oder C:\Downl |

### Examples

**Example 1:**
\\\powershell
Install-sqmDb2Driver -SourcePath '\\srv\Treiber\DB2'
\\\`n
**Example 2:**
\\\powershell
Install-sqmDb2Driver -SourcePath 'C:\Downloads\db2_odbc_cli_64.exe'
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Install-sqmJdbcDriver

**Installiert den Microsoft JDBC Driver for SQL Server.**

### Description

Prueft ob der JDBC-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled).
    Bei Bedarf: Kopiert die .jar-Datei aus dem SourcePath in den Zielpfad
    und setzt optional die CLASSPATH-Umgebungsvariable.

    Unterstuetzte Installer-Formate:
        - .jar  : Direkte Kopie
        - .exe  : Microsoft-Installer, wird still ausgefuehrt (/quiet /passive)
        - .zip  : Extraktion, dann .jar kopieren

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SourcePath | *object* | * | Quellpfad wo der JDBC-Installer oder die .jar liegt.     Z.B.: \\srv\Treiber\JDBC oder C:\Downloads\ |
| -DestinationPath | *object* | * | Zielpfad fuer die .jar-Datei.     Standard: C:\Program Files\Microsoft JDBC Driver for SQL Server\ |
| -UpdateClassPath | *object* | * | Wenn $true: CLASSPATH-Systemumgebungsvariable wird um den Zielpfad erweitert.     Standard: $false |

### Examples

**Example 1:**
\\\powershell
Install-sqmJdbcDriver -SourcePath '\\srv\Treiber\JDBC'
\\\`n
**Example 2:**
\\\powershell
Install-sqmJdbcDriver -SourcePath 'C:\Downloads\jdbc' -UpdateClassPath $true
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Install-sqmOdbcDriver

**Installiert den Microsoft ODBC Driver for SQL Server.**

### Description

Prueft ob der ODBC-Treiber bereits vorhanden ist (via Test-sqmDriverInstalled).
    Bei Bedarf: Fuehrt den Installer still aus.

    Unterstuetzte Installer-Formate:
        - .msi : msiexec /i /quiet /norestart
        - .exe : Direktausfuehrung mit /quiet /norestart

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SourcePath | *object* | * | Pfad zum ODBC-Installer oder Verzeichnis mit dem Installer.     Z.B.: \\srv\Treiber\ODBC oder C:\Dow |
| -DriverName | *object* | * | Optionaler Treibername fuer die Vorab-Pruefung via Test-sqmDriverInstalled.     Standard: automatisc |

### Examples

**Example 1:**
\\\powershell
Install-sqmOdbcDriver -SourcePath '\\srv\Treiber\ODBC'
\\\`n
**Example 2:**
\\\powershell
Install-sqmOdbcDriver -SourcePath 'C:\Setup\msodbcsql18.msi'
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Uninstall-sqmDb2Driver

**Deinstalliert den IBM DB2 ODBC/CLI-Treiber.**

### Examples

**Example 1:**
\\\powershell
Uninstall-sqmDb2Driver
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Uninstall-sqmJdbcDriver

**Deinstalliert den Microsoft JDBC Driver for SQL Server.**

### Description

Entfernt vorhandene mssql-jdbc*.jar Dateien aus dem Standard-Installationsverzeichnis
        des Microsoft JDBC Driver for SQL Server. Da JDBC als JAR-Datei deployed wird
        (kein MSI), genuegt das Loeschen der JAR-Dateien als Deinstallation.
        Optionale Bereinigung des CLASSPATH-Eintrags.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -RemoveClassPath | *object* | * | Entfernt den CLASSPATH-Systemeintrag wenn vorhanden. Standard: $false. |

### Examples

**Example 1:**
\\\powershell
Uninstall-sqmJdbcDriver
\\\`n
**Example 2:**
\\\powershell
Uninstall-sqmJdbcDriver -RemoveClassPath
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Uninstall-sqmOdbcDriver

**Deinstalliert den Microsoft ODBC Driver for SQL Server.**

### Description

Sucht den installierten Microsoft ODBC Driver for SQL Server in der
        Windows-Uninstall-Registry und fuehrt eine stille Deinstallation via
        msiexec /x durch. Wird typischerweise vor einer Neuinstallation einer
        neueren Version aufgerufen.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -DriverName | *object* | * | Optionaler Treibername fuer gezieltes Matching.         Standard: Wildcard 'Microsoft ODBC Driver *  |

### Examples

**Example 1:**
\\\powershell
Uninstall-sqmOdbcDriver
\\\`n
**Example 2:**
\\\powershell
Uninstall-sqmOdbcDriver -DriverName 'Microsoft ODBC Driver 17 for SQL Server'
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 19. External Systems Integration

This section covers **3 functions** related to External Systems Integration.


## Invoke-sqmSplunkConfiguration

**Configures the Splunk Universal Forwarder on SQL Server hosts.**

### Description

Detects all SQL Server instances, sets machine-wide environment variables
        for the ErrorLog path (MSSQL1_Log, MSSQL2_Log, ...) and manages the
        SplunkForwarder service — locally or remotely on any number of servers.
        Existing environment variables are not overwritten.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -Mode | *object* | * | Set  - Set environment variables and start/restart SplunkForwarder (default).         Test - Check o |
| -Remote | *object* | * | Remote execution via AD OU search. Combine with -SearchOU. |
| -SearchOU | *object* | * | Distinguished Name or simple OU name. Default: OUServDatabase. |
| -ComputerList | *object* | * | Explicit server list: string array or path to a text file (# = comment). |
| -Credential | *object* | * | Credentials for AD and remoting. |
| -LogPath | *object* | * | Directory for log files. Default: sqmSQLTool LogPath configuration. |
| -LogCallback | *object* | * | Optional ScriptBlock for GUI logging. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmSplunkConfiguration
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmSplunkConfiguration -Mode Test
\\\`n
**Example 3:**
\\\powershell
Invoke-sqmSplunkConfiguration -Remote -SearchOU "OU=DB-Server,DC=contoso,DC=com"
\\\`n
*Note: 2 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmTsmConfiguration

****

### Description

Reads the existing dsm.opt, adds or replaces the relevant entries,
    and writes the file back. Before each change a backup copy (dsm.opt.bak)
    is automatically created.

    Configured sections:
    - EXCLUDE for SQL Server database files (*.mdf, *.ndf, *.ldf)
    - INCLUDE for backup directories (User-db, Sys-db, additional paths)
    - MANAGEMENTCLASS for backup files (retention period)

    When -UseDiff is set, the management class is forced to
    MC_B_NL.NL_42.42.NA (42-day retention).

    The managed block in dsm.opt is delimited by the markers
    '* --- dtcSqlTools BEGIN ---' and '* --- dtcSqlTools END ---'.
    Manual entries outside this block are preserved.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer (TSM client). Default: current computer name. |
| -SqlInstance | *object* | * | SQL Server instance used to determine the backup directory.     Default: $ComputerName. |
| -DsmOptPath | *object* | * | Full path to the dsm.opt on the target computer.     Determined automatically when not specified. |
| -BackupDirectory | *object* | * | Base backup directory. The subdirectories \User-db and \Sys-db     are added as INCLUDE entries.   |
| -AdditionalIncludePaths | *object* | * | Additional directories to be added as INCLUDE entries. |
| -ManagementClass | *object* | * | TSM management class for the backup files.     Allowed values: MC_B_NL.NL_10.10.NA, MC_B_NL.NL_35.3 |
| -UseDiff | *object* | * | When set, forces the management class to MC_B_NL.NL_42.42.NA     (required for diff backup strategy |
| -SqlCredential | *object* | * | PSCredential for the SQL connection (to read the backup directory). |
| -Credential | *object* | * | PSCredential for remote file access (Copy-Item, Test-Path) on the target computer. |
| -OutputPath | *object* | * | Output directory for the configuration report.     Default: Get-sqmDefaultOutputPath. |
| -ContinueOnError | *object* | * | Continue on error (not applicable here as there is no loop). |
| -EnableException | *object* | * | Throw exceptions immediately (instead of silent error objects). |
| -Confirm | *object* | * | Request confirmation before writing the dsm.opt. |
| -WhatIf | *object* | * | Shows what would happen without making any changes. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmTsmConfiguration -ManagementClass MC_B_NL.NL_42.42.NA
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmTsmConfiguration -ComputerName "SQL01" -UseDiff
\\\`n
**Example 3:**
\\\powershell
Invoke-sqmTsmConfiguration -ComputerName "SQL01" -AdditionalIncludePaths "E:\Archive"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmTsmConnection

**Tests the connection to an IBM Spectrum Protect (TSM) server using dsmadmc.**

### Description

Locates dsmadmc.exe on the local or remote computer, reads the TSM configuration
    from dsm.opt (server name, user name, password) if not provided explicitly,
    and executes a 'show version' command to verify that the TSM server is reachable.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer on which the connection test is performed. Default: current computer name. |
| -DsmadmcPath | *object* | * | Full path to dsmadmc.exe. Determined automatically from the registry if not specified. |
| -UserName | *object* | * | TSM user name (USERID from dsm.opt if not specified). |
| -Password | *object* | * | TSM password as SecureString (PASSWORD from dsm.opt if not specified). |
| -ServerName | *object* | * | TSM server address (TCPServeraddress from dsm.opt if not specified). |
| -DsmOptPath | *object* | * | Full path to dsm.opt. Determined automatically if not specified. |
| -Credential | *object* | * | PSCredential for remote access (WinRM). |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Test-sqmTsmConnection
\\\`n
**Example 2:**
\\\powershell
Test-sqmTsmConnection -ComputerName "SQL01" -UserName "tsm_admin" -Password (Read-Host -AsSecureString)
#>
function Test-sqmTsmConnection
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$DsmadmcPath,
		[Parameter(Mandatory = $false)]
		[string]$UserName,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$Password,
		[Parameter(Mandatory = $false)]
		[string]$ServerName,
		[Parameter(Mandatory = $false)]
		[string]$DsmOptPath,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName auf $ComputerName" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		$result = [PSCustomObject]@{
			Success	    = $false
			Message	    = $null
			DsmadmcPath = $null
			ServerName  = $null
			UserName    = $null
			Output	    = $null
			ErrorOutput = $null
		}
		
		try
		{
			# ---- 1. dsmadmc.exe Pfad ermitteln ----
			$dsmadmc = if ($DsmadmcPath) { $DsmadmcPath }
			else { _FindDsmadmcPath -ComputerName $ComputerName -Credential $Credential }
			if (-not $dsmadmc)
			{
				$msg = "dsmadmc nicht gefunden. Bitte TSM-Client installieren oder -DsmadmcPath angeben."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			$result.DsmadmcPath = $dsmadmc
			Invoke-sqmLogging -Message "Verwende dsmadmc: $dsmadmc" -FunctionName $functionName -Level "VERBOSE"
			
			# ---- 2. TSM-Konfiguration aus dsm.opt lesen (falls nicht alle Parameter angegeben) ----
			$effUserName = $UserName
			$effPassword = $Password
			$effServerName = $ServerName
			
			if (-not $effUserName -or -not $effPassword -or -not $effServerName)
			{
				$cfg = Get-sqmTsmConfiguration -ComputerName $ComputerName -DsmOptPath $DsmOptPath -Credential $Credential -IncludePasswordPlain -ErrorAction Stop
				if (-not $cfg.Success)
				{
					throw "TSM-Konfiguration konnte nicht gelesen werden: $($cfg.ErrorMessage)"
				}
				if (-not $effServerName) { $effServerName = $cfg.ServerName }
				if (-not $effUserName) { $effUserName = $cfg.UserName }
				if (-not $effPassword -and $cfg.Password) { $effPassword = $cfg.Password }
			}
			
			if (-not $effUserName)
			{
				$msg = "Kein TSM-Benutzername angegeben und kein USERID in dsm.opt gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			if (-not $effPassword)
			{
				$msg = "Kein TSM-Kennwort angegeben und kein PASSWORD in dsm.opt gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			if (-not $effServerName)
			{
				$msg = "Kein TSM-Server angegeben und kein TCPServeraddress in dsm.opt gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			$result.UserName = $effUserName
			$result.ServerName = $effServerName
			Invoke-sqmLogging -Message "TSM-Server: $effServerName, Benutzer: $effUserName" -FunctionName $functionName -Level "INFO"
			
			# ---- 3. Kennwort aus SecureString extrahieren ----
			$plainPwd = _SecureToPlain $effPassword
			
			# ---- 4. dsmadmc-Befehl aufbauen ----
			$cmdArgs = "-id=$effUserName -password=$plainPwd -se=$effServerName -dataonly=yes show version"
			Invoke-sqmLogging -Message "Fuehre dsmadmc aus: $dsmadmc $cmdArgs" -FunctionName $functionName -Level "VERBOSE"
			
			# ---- 5. Befehl ausfuehren ----
			$output = $null
			$errorOut = $null
			$exitCode = 0
			$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
			
			if ($PSCmdlet.ShouldProcess("TSM-Verbindung zu $effServerName mit Benutzer $effUserName", "Pruefen"))
			{
				if ($isLocal)
				{
					$psi = New-Object System.Diagnostics.ProcessStartInfo
					$psi.FileName = $dsmadmc
					$psi.Arguments = $cmdArgs
					$psi.UseShellExecute = $false
					$psi.RedirectStandardOutput = $true
					$psi.RedirectStandardError = $true
					$psi.CreateNoWindow = $true
					$p = [System.Diagnostics.Process]::Start($psi)
					$output = $p.StandardOutput.ReadToEnd()
					$errorOut = $p.StandardError.ReadToEnd()
					$p.WaitForExit()
					$exitCode = $p.ExitCode
				}
				else
				{
					$scriptBlock = {
						param ($exe,
							$args)
						$psi = New-Object System.Diagnostics.ProcessStartInfo
						$psi.FileName = $exe
						$psi.Arguments = $args
						$psi.UseShellExecute = $false
						$psi.RedirectStandardOutput = $true
						$psi.RedirectStandardError = $true
						$psi.CreateNoWindow = $true
						$p = [System.Diagnostics.Process]::Start($psi)
						$out = $p.StandardOutput.ReadToEnd()
						$err = $p.StandardError.ReadToEnd()
						$p.WaitForExit()
						return @{ ExitCode = $p.ExitCode; Output = $out; Error = $err }
					}
					$session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
					$remoteResult = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $dsmadmc, $cmdArgs -ErrorAction Stop
					$exitCode = $remoteResult.ExitCode
					$output = $remoteResult.Output
					$errorOut = $remoteResult.Error
					Remove-PSSession $session
				}
				
				$result.Output = $output
				$result.ErrorOutput = $errorOut
				
				if ($exitCode -eq 0 -and $output -match 'IBM Spectrum Protect')
				{
					$result.Success = $true
					$result.Message = "Verbindung zu TSM-Server '$effServerName' mit Benutzer '$effUserName' erfolgreich."
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
				}
				else
				{
					$result.Success = $false
					$result.Message = "Fehler bei TSM-Verbindung (Exitcode $exitCode). Ausgabe: $output $errorOut".Trim()
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				}
			}
			else
			{
				$result.Success = $false
				$result.Message = "WhatIf: Verbindungstest wuerde ausgefuehrt."
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "VERBOSE"
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$result.Message = $errMsg
		}
		return $result
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}

# ---- Hilfsfunktionen (lokal) ----
function _FindDsmadmcPath
{
	param ([string]$ComputerName,
		[System.Management.Automation.PSCredential]$Credential)
	
	$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
	$candidates = [System.Collections.Generic.List[string]]::new()
	
	if ($isLocal)
	{
		try
		{
			$regPath = 'HKLM:\SOFTWARE\IBM\ADSM\CurrentVersion'
			$installPath = (Get-ItemProperty $regPath -Name 'InstallPath' -ErrorAction SilentlyContinue).InstallPath
			# KORREKTUR: Doppelte Klammern fuer den Methodenaufruf
			if ($installPath) { $candidates.Add((Join-Path $installPath 'dsmadmc.exe')) }
		}
		catch { }
		
		if ($env:DSM_DIR) { $candidates.Add((Join-Path $env:DSM_DIR 'dsmadmc.exe')) }
		
		$candidates.Add('C:\Program Files\Tivoli\TSM\baclient\dsmadmc.exe')
		$candidates.Add('C:\Program Files\IBM\TSM\baclient\dsmadmc.exe')
		$candidates.Add('C:\Program Files\IBM\SpectrumProtect\baclient\dsmadmc.exe')
	}
	else
	{
		# Remote-Logik... (hier ebenfalls Klammern pruefen falls Join-Path genutzt wird)
	}
	
	foreach ($c in $candidates)
	{
		if (Test-Path $c) { return $c }
	}
	return $null
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 13. SQL Agent & Proxy Jobs

This section covers **4 functions** related to SQL Agent & Proxy Jobs.


## Get-sqmAgentJobHistory

**Displays the execution history of SQL Agent jobs.**

### Description

Returns the last execution(s) of all or selected SQL Agent jobs.
    Can filter by job name, status (success/failure) and time range.
    By default, the last 7 days are shown.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -JobName | *object* | * | Name or wildcard pattern (e.g. '*Backup*') to filter jobs. |
| -Status | *object* | * | 'Success', 'Failure', 'Retry' or 'Cancelled'. Default: all. |
| -Since | *object* | * | Show history from this date onwards. Default: today minus 7 days. |
| -LastX | *object* | * | Instead of a time range: number of last executions per job (e.g. -LastX 5). |
| -OutputPath | *object* | * | Export as CSV (optional). If specified, a CSV file is created. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmAgentJobHistory
\\\`n
**Example 2:**
\\\powershell
Get-sqmAgentJobHistory -JobName '*Backup*' -Status Failure -Since (Get-Date).AddDays(-1)
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## New-sqmAgentProxy

**Erstellt einen SQL Server Credential und einen SQL Agent Proxy und verbindet beide.**

### Description

Legt in einem Schritt einen neuen SQL Server Credential an und erstellt darauf
    basierend einen SQL Server Agent Proxy. Die Windows-Credentials werden interaktiv
    per Get-Credential abgefragt. Der Account wird vor der Erstellung auf Existenz
    und Eignung geprueft (Enabled, nicht gesperrt, Passwort nicht abgelaufen,
    Konto nicht abgelaufen). Ueber -Subsystem wird gesteuert welche Subsysteme
    dem Proxy zugewiesen werden.

    Ablauf:
      1. Get-Credential Dialog - Windows-Account eingeben
      2. AD-Pruefung: Existenz, Enabled, LockedOut, PasswordExpired, AccountExpired
      3. Pruefen ob Credential bereits existiert (Fehler oder -Force)
      4. Credential anlegen (CREATE CREDENTIAL) via SMO
      5. Pruefen ob Proxy bereits existiert (Fehler oder -Force)
      6. Agent Proxy anlegen und mit dem Credential verbinden via SMO
      7. Subsysteme gemaess -Subsystem zuweisen (CmdExec, SSIS, PowerShell oder All)
      8. Protokoll-Objekt zurueckgeben

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server-Instanz. Standard: lokaler Computername. |
| -SqlCredential | *object* | * | PSCredential fuer die SQL-Verbindung (Windows-Auth wenn nicht angegeben). |
| -CredentialName | *object* | * | Name des neuen SQL Server Credentials (z.B. "DOMAIN\ServiceAccount"). |
| -ProxyName | *object* | * | Name des neuen SQL Agent Proxys. |
| -ProxyDescription | *object* | * | Optionale Beschreibung fuer den Proxy. |
| -WindowsCredential | *object* | * | Windows-Credential direkt als PSCredential uebergeben (kein Dialog).     Wenn nicht angegeben ersche |
| -WindowsUserName | *object* | * | Optionaler Windows-Benutzername (DOMAIN\User) zur Vorbestueckung des     Get-Credential Dialogs. Wir |
| -Subsystem | *object* | * | Subsysteme die dem Proxy zugewiesen werden. Mehrfachauswahl moeglich.     Gueltiger Werte: CmdExec,  |
| -Force | *object* | * | Ueberschreibt bestehenden Credential und/oder Proxy wenn vorhanden. |
| -EnableException | *object* | * | Ausnahmen sofort ausloesen statt Write-Error. |

### Examples

**Example 1:**
\\\powershell
# Einzeiler - Credential-Dialog erscheint automatisch
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SqlServiceAccount" `
        -ProxyName "SSIS Proxy"

    # Credential direkt uebergeben - kein Dialog
    $cred = Get-Credential "DOMAIN\SvcSSIS"
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Proxy" -WindowsCredential $cred
\\\`n
**Example 2:**
\\\powershell
# Nur SSIS - Benutzername vorausgewaehlt im Dialog
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Only Proxy" -Subsystem SSIS
\\\`n
**Example 3:**
\\\powershell
# CmdExec und PowerShell
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcPS" `
        -ProxyName "Script Proxy" -Subsystem CmdExec, PowerShell
\\\`n
*Note: 2 more examples available in function help*

### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## New-sqmAlwaysOnRepairJob

**Creates a SQL Server Agent job that runs Repair-Job.ps1 (AutoRepair).**

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL instance (default: computer name). |
| -JobName | *object* | * | Name of the Agent job. Default: 'sqmAlwaysOnRepair'. |
| -Force | *object* | * | Overwrites an existing job. |

### Examples

**Example 1:**
\\\powershell
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
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## New-sqmAutoLoginSyncJob

**Creates a SQL Agent job that runs Sync-Job.ps1 (AutoSync).**

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Target SQL instance (default: computer name). |
| -JobName | *object* | * | Name of the Agent job. Default: 'sqmAutoLoginSync'. |
| -Force | *object* | * | Overwrites an existing job. |

### Examples

**Example 1:**
\\\powershell
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
\\\`n
### Best Practices

- Review audit logs after bulk changes
- Test permissions in non-prod first
- Maintain password policies compliance

---

# 1. Always On & Availability Groups

This section covers **18 functions** related to Always On & Availability Groups.


## Add-sqmDatabaseToAG

**Adds one or more databases to an Always On availability group (AutoSeed).**

### Description

- Checks whether the database is already in an AG.
- Sets recovery mode to Full (if necessary).
- Drops existing databases on all secondary replicas.
- Adds the database to the AG using Automatic Seeding.
- With -All, databases are added sequentially to avoid load spikes.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Primary SQL instance (default: computer name). |
| -SqlCredential | *object* | * | Credentials. |
| -AvailabilityGroup | *object* | * | Name of the target availability group (mandatory). |
| -Database | *object* | * | Name or array of databases. Ignored when -All is set. |
| -All | *object* | * | Add all user databases that are not yet in an AG. |
| -EnableException | *object* | * | Allow exceptions to pass through. |
| -Confirm | *object* | * | Request confirmation. |
| -WhatIf | *object* | * | Test only (no changes). |

### Examples

**Example 1:**
\\\powershell
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -Database "SalesDB"
\\\`n
**Example 2:**
\\\powershell
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -All
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Add-sqmDatabaseToDistributedAg

**Adds a database to a Distributed AlwaysOn Availability Group.**

### Description

Performs the following steps:
    1. Creates full backup of source database
    2. Backs up transaction log
    3. Restores database to secondary cluster
    4. Joins database to secondary AG
    5. Adds database to Distributed AG
    6. Monitors synchronization

    Requires:
    - Source database on primary AG
    - Secondary AG already configured
    - Distributed AG relationship established

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Primary SQL Server instance. Default: current computer name. |
| -AvailabilityGroupName | *object* | * | Name of the Distributed AG. |
| -DatabaseName | *object* | * | Name of the database to add. |
| -SecondaryInstance | *object* | * | Secondary SQL Server instance where database will be restored. |
| -BackupPath | *object* | * | Path for full and log backups. Default: C:\Backups |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Add-sqmDatabaseToDistributedAg -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -DatabaseName "MyDb" -SecondaryInstance "DR-SQL01"
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Compare-sqmAlwaysOnLogins

**Vergleicht die Logins aller Replicas einer AlwaysOn Availability Group.**

### Description

Ermittelt alle Replicas einer Availability Group und vergleicht pro Login:
    - Vorhanden        : existiert der Login auf jeder Replica?
    - Standard-DB      : default_database_name auf allen gleich?
    - Sprache          : default_language_name (Text) auf allen gleich?
    - Passwort-Hash    : password_hash gleich (nur SQL-Logins; Windows = N/A)
    - SID              : sid gleich? (Mismatch = verwaiste User nach Failover)

    Statusbewertung pro Login:
    - Critical : fehlt auf mindestens einer Replica, ODER SID-Mismatch,
                 ODER Passwort-Hash-Mismatch (Authentifizierung bricht nach Failover)
    - Warning  : Standard-DB oder Sprache weicht ab
    - OK       : alles konsistent

    Ausgabe als Tabelle (Rueckgabeobjekt) sowie TXT- und HTML-Report. Der HTML-Report
    wird nach dem Erstellen automatisch geoeffnet (ausser -NoOpen).

    Voraussetzung fuer den Passwort-Hash-Vergleich: Leserecht auf sys.sql_logins
    (sysadmin oder CONTROL SERVER). Fehlt das Recht, wird der Hash als N/A behandelt.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Einstiegs-Instanz der AG (Primary oder eine Secondary). Standard: aktueller Computer. |
| -AvailabilityGroupName | *object* | * | Name der Availability Group. Ohne Angabe wird die erste gefundene AG verwendet     (bei mehreren: Wa |
| -SqlCredential | *object* | * | Optionales PSCredential fuer alle Replicas. |
| -IncludeSystemLogins | *object* | * | Wenn gesetzt, werden auch Systemlogins (sa, ##MS_*, NT SERVICE\*, NT AUTHORITY\*,     BUILTIN\*) ver |
| -Login | *object* | * | Nur diese Logins vergleichen (Wildcards erlaubt). |
| -ExcludeLogin | *object* | * | Diese Logins ausschliessen (Wildcards erlaubt). |
| -OnlyDifferences | *object* | * | Nur Logins mit Abweichung (Status Warning/Critical) ausgeben. |
| -OutputPath | *object* | * | Ausgabeverzeichnis fuer TXT/HTML. Standard: aus Modulkonfiguration. |
| -NoOpen | *object* | * | Unterdrueckt das automatische Oeffnen des Reports. |
| -FailOnDrift | *object* | * | Wenn gesetzt: bei Login-Drift (Status Warning oder Critical) wird ein Windows Event     (Source 'sqm |
| -ContinueOnError | *object* | * | Bei Fehler fortfahren. |
| -EnableException | *object* | * | Fehler sofort als Ausnahme ausloesen. |

### Examples

**Example 1:**
\\\powershell
Compare-sqmAlwaysOnLogins -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Compare-sqmAlwaysOnLogins -SqlInstance "SQL01" -AvailabilityGroupName "AG_Prod" -OnlyDifferences
\\\`n
**Example 3:**
\\\powershell
Compare-sqmAlwaysOnLogins -SqlInstance "SQL01" | Format-Table
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Complete-sqmListenerMigration

**Completes listener migration after cluster team recreates the listener resource.**

### Description

Re-registers the listener with SQL Server AG after cluster team has:
    1. Deleted old listener cluster resource
    2. Created new listener cluster resource (with same DNS name)

    This function:
    1. Discovers the new listener cluster resource
    2. Registers it with the SQL Server AG
    3. Verifies all databases return to ONLINE state
    4. Validates listener connectivity

    CRITICAL: Only run AFTER AD team has:
    - Deleted old listener role
    - Created new listener role (with same DNS name)
    - Configured new cluster IP address
    - Verified cluster resource is ONLINE

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance hosting the AG. Default: current computer name. |
| -AvailabilityGroupName | *object* | * | Name of the Availability Group. |
| -ListenerName | *object* | * | DNS name of the listener to be added (must match new cluster resource). |
| -OutputPath | *object* | * | Output directory for completion report. Default: C:\System\WinSrvLog\MSSQL |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# STEP 1: DBA runs Invoke-sqmListenerMigrationPrep
    # STEP 2: AD team deletes/recreates listener role (15-30 min wait)
    # STEP 3: DBA runs this function

    Complete-sqmListenerMigration -SqlInstance "SQL02" -AvailabilityGroupName "ProdAG" -ListenerName "PROD-SQL-Listener"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Export-sqmAlwaysOnConfiguration

**Exports the complete AlwaysOn AG configuration for one or more SQL Server instances.**

### Description

Reads all static AG configuration settings (not runtime status) and exports them as TXT, CSV, and optional JSON.
	For each AG on the specified instance:
	- AG name, backup preference, failover condition, health check timeout
	- All replicas with ReadableSecondary setting (with FI-TS standard warning)
	- Listener configuration (name, port, IPs)
	- Member databases

	CRITICAL FI-TS CHECK: ReadableSecondary must be NO (not NONE, READ_ONLY, or ALL).
	Any other value triggers a warning unless -NoWarning is specified.

	Results are saved as TXT report and CSV file in the specified directory.
	The function also returns an object with the detail data and file paths.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -OutputPath | *object* | * | Output directory for report files. Default: $env:ProgramData\sqmSQLTool\Logs |
| -NoWarning | *object* | * | Suppress FI-TS ReadableSecondary warnings (Write-Warning is skipped). 	Note: Status will still be Wa |
| -NoOpen | *object* | * | Do not automatically open the TXT report after creation. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before writing files. |
| -WhatIf | *object* | * | Shows which files would be created without actually writing them. |

### Examples

**Example 1:**
\\\powershell
Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01"
	# Exports all AGs from SQL01, warns if ReadableSecondary != NO
\\\`n
**Example 2:**
\\\powershell
Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01" -NoWarning
	# Exports all AGs, suppresses Write-Warning but Status still shows if issues
\\\`n
**Example 3:**
\\\powershell
Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01" -OutputPath "D:\Reports" -NoOpen
	# Exports to D:\Reports, does not auto-open TXT file
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Get-sqmAlwaysOnFailoverHistory

**Ermittelt AlwaysOn-Failover-Ereignisse aus dem Windows Event Log.**

### Description

Wertet den Windows Application Event Log auf dem Zielcomputer aus und
    liefert alle AlwaysOn-Failover-Ereignisse im angegebenen Zeitraum.

    Primaerquelle: Application Log, EventID 1480
    "The %ls role of availability group '%s' has been successfully changed to '%ls'."
    Diese EventID wird von SQL Server bei jedem AG-Rollenuebergang geschrieben.
    Sie ist strukturiert, sprachunabhaengig und in allen SQL Server-Versionen
    verfuegbar (SQL 2012+).

    Optional: Windows Failover Clustering Operational Log (EventID 1641)
    Liefert die Cluster-Perspektive des Failovers. Nur verfuegbar wenn WSFC
    installiert und der Log aktiv ist (-IncludeClusterLog).

    Ergaenzung: sys.dm_hadr_availability_replica_states.role_start_time
    Zeigt den Zeitpunkt des letzten Rollenwechsels der lokalen Replica.
    Wird als zusaetzliche Zeile mit Source 'RoleStartTime' ausgegeben wenn
    -SqlInstance angegeben ist.

    FailoverType-Erkennung:
    - 'Planned'   : EventID 1480, Message enthaelt "user" oder "manual"
    - 'Automatic' : EventID 1480, Message enthaelt "automatic" oder "WSFC"
    - 'Forced'    : EventID 19407 (Lease-Ablauf) im gleichen Zeitfenster vorhanden
    - 'Unknown'   : Kein eindeutiges Merkmal erkennbar

    Ausgabe:
        AlwaysOnFailoverHistory_<computer>_<datum>.txt  - Lesbarer Bericht
        AlwaysOnFailoverHistory_<computer>_<datum>.csv  - Maschinenlesbar

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Zielcomputer. Standard: aktueller Computer.     Mehrere Computer moeglich (Pipeline). Event Log wird |
| -SqlInstance | *object* | * | SQL Server-Instanz fuer role_start_time-Ergaenzung. Optional.     Wird nicht benoetigt wenn nur Even |
| -SqlCredential | *object* | * | Optionales PSCredential fuer die SQL-Verbindung. |
| -AvailabilityGroup | *object* | * | Filter auf eine bestimmte AG. Leer = alle AGs. |
| -Since | *object* | * | Wie weit zurueck suchen. Standard: 30 Tage. |
| -IncludeClusterLog | *object* | * | WSFC Operational Log (Microsoft-Windows-FailoverClustering/Operational)     zusaetzlich auswerten. N |
| -OutputPath | *object* | * | Ausgabeverzeichnis. Standard: C:\System\WinSrvLog\MSSQL |
| -ContinueOnError | *object* | * | Bei Fehler auf einem Computer fortfahren. |
| -EnableException | *object* | * | Fehler als terminierende Ausnahmen ausloesen. |

### Examples

**Example 1:**
\\\powershell
Get-sqmAlwaysOnFailoverHistory
\\\`n
**Example 2:**
\\\powershell
Get-sqmAlwaysOnFailoverHistory -ComputerName "SQL01" -Since (Get-Date).AddDays(-90)
\\\`n
**Example 3:**
\\\powershell
Get-sqmAlwaysOnFailoverHistory -ComputerName "SQL01" `
        -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -IncludeClusterLog
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Get-sqmAlwaysOnHealthReport

**Creates a detailed health report for all Always On availability groups on an instance.**

### Description

Retrieves for each AG on the specified instance:
    - Synchronization status of all replicas
    - LSN lag between primary and secondaries (redo queue, send queue)
    - Database status per replica (Synchronized, Synchronizing, NotSynchronizing, ...)
    - Connection status of replicas
    - Listener configuration
    - Running AutoSeed operations

    Results are saved as a TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -MaxRedoQueueMB | *object* | * | Warning threshold for the redo queue in MB. Default: 100. |
| -MaxSendQueueMB | *object* | * | Warning threshold for the send queue in MB. Default: 50. |
| -OutputPath | *object* | * | Output directory for report files. Default: C:\System\WinSrvLog\MSSQL |
| -ContinueOnError | *object* | * | Continue on error for an instance (otherwise the error is thrown). |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before writing files. |
| -WhatIf | *object* | * | Shows which files would be created without actually writing them. |

### Examples

**Example 1:**
\\\powershell
Get-sqmAgHealthReport
\\\`n
**Example 2:**
\\\powershell
Get-sqmAgHealthReport -SqlInstance "SQL01" -MaxRedoQueueMB 200 -OutputPath "D:\Reports"
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Get-sqmDistributedAgHealth

**Creates a detailed health report for Distributed AlwaysOn Availability Groups.**

### Description

Retrieves for each Distributed AG on the specified instance:
    - Synchronization status between primary and secondary AGs
    - Replica status within each AG
    - Database synchronization state
    - LSN lag information (redo/send queues)
    - Listener configuration
    - Failover readiness status

    Results are saved as TXT and CSV reports. Requires SQL Server 2016 SP1 or later.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -OutputPath | *object* | * | Output directory for report files. Default: C:\System\WinSrvLog\MSSQL |
| -ContinueOnError | *object* | * | Continue on error for an instance (otherwise the error is thrown). |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |

### Examples

**Example 1:**
\\\powershell
Get-sqmDistributedAgHealth -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Get-sqmDistributedAgHealth -SqlInstance "SQL01", "SQL02" -OutputPath "D:\Reports"
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Invoke-sqmDistributedFailover

**Initiates failover of a Distributed AlwaysOn AG.**

### Description

Performs a controlled failover from the primary Distributed AG to the secondary AG.

    Process:
    1. Validates failover readiness (all replicas SYNCHRONIZED)
    2. Initiates failover on the secondary AG (makes it primary)
    3. Previous primary becomes secondary
    4. Logs all changes
    5. Exports detailed report

    Requires explicit confirmation unless -Force is used.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Primary SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -AvailabilityGroupName | *object* | * | Name of the Distributed AG to failover. Required. |
| -Force | *object* | * | Skip confirmation dialog. |
| -Rollback | *object* | * | Rollback zum urspruenglichen Primary. Ueberspringt den Readiness-Check.     Verwenden wenn nach eine |
| -WhatIf | *object* | * | Shows what would be done without actually performing the failover. |
| -OutputPath | *object* | * | Output directory for report files. Default: C:\System\WinSrvLog\MSSQL |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -Force
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -WhatIf
\\\`n
**Example 3:**
\\\powershell
# Rollback zum alten System nach fehlgeschlagenem Failover:
    Invoke-sqmDistributedFailover -SqlInstance "SQL01" -AvailabilityGroupName "MyDAG" -Rollback -Force
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmFailover

**Performs a controlled AlwaysOn AG failover with pre- and post-checks.**

### Description

Checks before failover: synchronization status, redo queue size.
    Performs the failover: ALTER AVAILABILITY GROUP ... FAILOVER on the target secondary.
    Checks after failover: new primary reachable, all DBs SYNCHRONIZED.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Current PRIMARY instance. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -AvailabilityGroup | *object* | * | Name of the availability group. |
| -TargetReplica | *object* | * | Instance name of the target replica. If not specified, the first     SYNCHRONIZED secondary replica  |
| -MaxRedoQueueMB | *object* | * | Maximum redo queue size in MB. Failover is aborted if exceeded.     Default: 50 MB. |
| -WaitAfterFailoverSeconds | *object* | * | Wait time in seconds after the failover command before post-checks run.     Default: 30 seconds. |
| -ContinueOnError | *object* | * | Do not throw errors; return them in the result object instead. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmFailover -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" -WhatIf
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmFailover -SqlInstance "SQL01" -AvailabilityGroup "AG_Prod" `
        -TargetReplica "SQL02" -MaxRedoQueueMB 10
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmSqlAlwaysOnAutoseeding

**Enables Automatic Seeding on all replicas of an Always On Availability Group.**

### Description

Configures the seeding mode of all replicas of one or more Availability Groups to
"Automatic". Using the -All switch forces processing of all Availability Groups on
the instance.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). If not specified, the current  |
| -SqlCredential | *object* | * | Alternative credentials (PSCredential). If not specified, Windows authentication is used. |
| -AvailabilityGroup | *object* | * | Name of the Availability Group(s). Ignored when -All is set. |
| -All | *object* | * | When set, all Availability Groups on the instance are processed. |
| -EnableException | *object* | * | Switch to propagate exceptions immediately (by default errors are logged as warnings). |

### Examples

**Example 1:**
\\\powershell
# Uses the current computer name as default
Invoke-sqmSqlAlwaysOnAutoseeding
\\\`n
**Example 2:**
\\\powershell
# Explicit instance specification
Invoke-sqmSqlAlwaysOnAutoseeding -SqlInstance "SQL01\INSTANCE"
\\\`n
**Example 3:**
\\\powershell
# All groups on the current computer
Invoke-sqmSqlAlwaysOnAutoseeding -All
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Move-sqmAlwaysOnListener

**Migrates an AG Listener from one Availability Group to another.**

### Description

Used for Distributed AG failover scenarios where the listener must "follow" the
    primary role to a new AG.

    Process:
    1. Validate listener exists on source AG
    2. Extract listener configuration (IP, port, network mask)
    3. Remove listener from source AG
    4. Create new listener on target AG with same configuration
    5. Update DNS records (manual step documented)
    6. Verify connectivity

    IMPORTANT: This is typically done BEFORE failover to ensure zero-downtime transition.

    For Distributed AG Customer Scenario:
    - Before failover: Move listener from C1 AG to C2 AG
    - Update DNS to point to C2 listener IP
    - Trigger failover (C2 becomes primary)
    - Applications connect to listener (already pointing to C2)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance hosting the SOURCE AG. Default: current computer name. |
| -SourceAgName | *object* | * | Name of the source AG (currently has the listener). |
| -TargetAgName | *object* | * | Name of the target AG (will receive the listener). |
| -TargetInstance | *object* | * | SQL Server instance hosting the target AG. Default: same as SourceInstance. |
| -ListenerName | *object* | * | Specific listener name to move (if multiple listeners exist). Optional. |
| -SqlCredential | *object* | * | Optional PSCredential for both instances. |
| -WhatIf | *object* | * | Shows what would be done without actually moving the listener. |
| -OutputPath | *object* | * | Output directory for detailed logs. Default: C:\System\WinSrvLog\MSSQL |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Move listener from Primary AG to Secondary AG (before failover)
    Move-sqmAgListener -SqlInstance "SQL01" -SourceAgName "ProductionAG" `
        -TargetAgName "DrAG" -TargetInstance "DR-SQL01"
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## New-sqmDistributedAvailabilityGroup

**Creates a new Distributed AlwaysOn Availability Group.**

### Description

Establishes a Distributed AG relationship between two SQL Server clusters:

    1. Validates primary and secondary AG exist and are synchronized
    2. Configures AutoSeed on both sides (if requested)
    3. Creates Distributed AG on primary cluster
    4. Registers secondary AG as part of distributed relationship
    5. Verifies initial synchronization

    Prerequisites:
    - Primary AG must exist on PrimaryInstance and be HEALTHY
    - Secondary AG must exist on SecondaryInstance
    - Both clusters must be WSFC clusters
    - Network connectivity between clusters

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -PrimaryInstance | *object* | * | SQL Server instance hosting the PRIMARY Availability Group. |
| -PrimaryAgName | *object* | * | Name of the primary AG (the one that will remain primary). |
| -SecondaryInstance | *object* | * | SQL Server instance hosting the SECONDARY Availability Group. |
| -SecondaryAgName | *object* | * | Name of the secondary AG (the one that will be secondary in Distributed AG). |
| -SqlCredential | *object* | * | Optional PSCredential for both instances (same account required). |
| -EnableAutoSeed | *object* | * | Configure AutoSeed for the distributed relationship (recommended). |
| -SeedingMode | *object* | * | 'Automatic' (default) = AutoSeed enabled     'Manual' = Manual backup/restore required for new datab |
| -OutputPath | *object* | * | Output directory for detailed logs. Default: C:\System\WinSrvLog\MSSQL |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
New-sqmDistributedAvailabilityGroup `
        -PrimaryInstance   "SQL01" `
        -PrimaryAgName     "ProductionAG" `
        -PrimaryFqdn       "SQL01.domain.local" `
        -SecondaryInstance "DR-SQL01" `
        -SecondaryAgName   "DrAG" `
        -SecondaryFqdn     "DR-SQL01.domain.local" `
        -ServiceAccount    "DOMAIN\SqlServiceAccount" `
        -SeedingMode       Automatic
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Prepare-sqmListenerForMigration

**Prepares an AG listener for cluster-level migration without downtime.**

### Description

Removes the listener from the SQL Server AG while keeping databases ONLINE.

    This is CRITICAL preparation before AD/Cluster team deletes/recreates the
    listener cluster resource. Skipping this step causes all databases to enter
    RECOVERY MODE when the cluster resource is deleted.

    Process:
    1. Validates listener exists and is configured correctly
    2. Removes listener from AG (via ALTER AVAILABILITY GROUP ... REMOVE LISTENER)
    3. Verifies all databases remain ONLINE (still in AG, just no listener)
    4. Documents listener configuration for re-creation
    5. Waits for DNS/application timeout
    6. Gives AD team "safe to delete" confirmation

    CRITICAL: Run this BEFORE AD team deletes the listener cluster resource!

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance hosting the AG. Default: current computer name. |
| -AvailabilityGroupName | *object* | * | Name of the Availability Group. |
| -ListenerName | *object* | * | DNS name of the listener to be removed (must exist). Optional if only one listener. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -OutputPath | *object* | * | Output directory for listener documentation. Default: C:\System\WinSrvLog\MSSQL |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# STEP 1: Prepare listener before AD team deletes it
    Invoke-sqmListenerMigrationPrep -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"

    # STEP 2: Wait 15 minutes for DNS/application timeout

    # STEP 3: AD team deletes old listener role and creates new one

    # STEP 4: You run Complete-sqmListenerMigration
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Remove-sqmDatabaseFromAG

**Removes one or more databases from their Always On Availability Group.**

### Description

The function automatically detects which Availability Group the specified database
belongs to, removes it from the group, and then deletes it from all secondary replicas.
System databases are ignored.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The primary SQL Server instance (the primary replica of the AG). Default: current computer name. |
| -SqlCredential | *object* | * | Alternative credentials. |
| -Database | *object* | * | Name or array of user databases to remove from their AG. Ignored when -All is set. |
| -All | *object* | * | When set, all user databases that are members of an AG are removed. |
| -EnableException | *object* | * | Switch to propagate exceptions immediately. |
| -Confirm | *object* | * | Prompts for confirmation before critical actions (remove from AG, delete on secondaries). |
| -WhatIf | *object* | * | Shows what would happen without making any changes. |

### Examples

**Example 1:**
\\\powershell
# Remove a single database from its AG
Remove-sqmDatabaseFromAG -Database "SalesDB"
\\\`n
**Example 2:**
\\\powershell
# Remove all AG databases
Remove-sqmDatabaseFromAG -All
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Repair-sqmAlwaysOnDatabases

**Checks all AlwaysOn databases for problems and repairs them (Remove -> Cleanup -> Add).**

### Description

- Determines all databases in all Availability Groups.
- Checks whether a database is problematic (synchronization status not 'HEALTHY' or 'SYNCHRONIZED').
- Ensures that Automatic Seeding is enabled on all replicas (calls Invoke-sqmSqlAlwaysOnAutoseeding).
- On problems: removes database from AG, deletes it from all secondaries, re-adds it with AutoSeed.
- Each repair is recorded in the event log (via Invoke-sqmLogging and Windows Event Log).
- Automatically creates the event log source "sqmAlwaysOn" if it does not exist.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Primary SQL instance (default: computer name). |
| -SqlCredential | *object* | * | Credentials. |
| -Force | *object* | * | Also repair databases that are considered healthy (e.g. to force a refresh). |
| -EnableException | *object* | * | Propagate exceptions immediately. |
| -WhatIf | *object* | * | Test only. |

### Examples

**Example 1:**
\\\powershell
Automatically repairs all problematic AG databases.
Repair-sqmAlwaysOnDatabases
\\\`n
**Example 2:**
\\\powershell
Forces repair of all AG databases (including healthy ones).
Repair-sqmAlwaysOnDatabases -Force
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Sync-sqmLoginsToAlwaysOn

**Synchronizes logins from the primary replica to all secondary replicas in an AlwaysOn Availability Group.**

### Description

Automatically detects the primary and all secondary replicas in an AlwaysOn Availability Group,
    then copies logins from the primary to each secondary.

    Process:
    1. Detect primary replica in the AG (role_desc = 'PRIMARY')
    2. Enumerate all secondary replicas
    3. For each secondary:
       - Connect and validate
       - Copy logins from primary via Copy-sqmLogins
       - Repair orphaned users (automatic)
       - Log result (Success/Failed/Skipped)
    4. Return summary with per-replica status

    Authentication:
    - All replicas use the same credentials (SqlCredential or SourceCredential/DestinationCredential)
    - If replicas are on different domains: use -SqlCredential with cross-domain account

    Error handling:
    - Replica connection failure: Logged as 'Failed', process continues to next replica
    - Login copy failure: Logged with error details, does not block other replicas
    - Orphan repair failure: Logged, does not block result return

    Logins excluded by default:
    - System logins (sa, ##MS_*, NT SERVICE\*, BUILTIN\*) - use -IncludeSystemLogins to include

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The SQL Server instance hosting the primary replica. Default: $env:COMPUTERNAME |
| -AvailabilityGroupName | *object* | * | Name of the Availability Group. If not specified, the first AG found on the instance is used.     If |
| -SqlCredential | *object* | * | PSCredential for all replicas (source and destination). |
| -SourceCredential | *object* | * | PSCredential specifically for the primary replica (overrides -SqlCredential for source). |
| -DestinationCredential | *object* | * | PSCredential for the secondary replicas (overrides -SqlCredential for destinations). |
| -Login | *object* | * | Filters the copy operation to these login names (wildcards allowed).     Without specification, all  |
| -ExcludeLogin | *object* | * | Logins that should not be copied (wildcards allowed).     Example: 'AppLogin_*', 'OldUser'. |
| -IncludeSystemLogins | *object* | * | When set, system logins are also copied. Default: $false. |
| -AdjustAuthMode | *object* | * | When set, automatically adjust target replica authentication mode to match primary if needed. |
| -RestartServiceIfRequired | *object* | * | When set, restart the SQL Server service on secondary replicas if auth mode was changed. |
| -DisablePolicy | *object* | * | Disable SQL Server policies on secondaries during the copy (default: $true). |
| -SkipSecondaryServers | *object* | * | Comma-separated list of secondary instance names to skip (for maintenance).     Example: 'SQL02', 'S |
| -Force | *object* | * | Existing logins on secondaries are overwritten (password / language / default-db drift),     not onl |
| -ForceIncludeOnly | *object* | * | When Force is set with this parameter, only these logins are updated (whitelist).     Overrides othe |
| -ForceExclude | *object* | * | Additional logins to exclude from Force operation (blacklist).     Combined with SafeForceMode exclu |
| -SafeForceMode | *object* | * | When Force is set and SafeForceMode is true (default), automatically excludes dangerous logins:      |
| -BackupLogins | *object* | * | Creates a backup of existing logins on each secondary BEFORE applying -Force (rollback safety).      |
| -BackupPath | *object* | * | Path where login backups are stored. Default: configured output path (Get-sqmDefaultOutputPath),     |
| -BackupRetentionDays | *object* | * | When greater than 0, login backups (LoginBackup_*.sql) in BackupPath older than this many     days a |
| -AuditAdOrphans | *object* | * | When set, runs an AD-orphan check (Invoke-sqmLoginAudit -CheckAdOrphans) on the primary AFTER     th |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning error status. |

### Examples

**Example 1:**
\\\powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"
    Syncs all logins from primary to all secondaries in ProdAG.
\\\`n
**Example 2:**
\\\powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -IncludeSystemLogins
    Includes system logins in the sync.
\\\`n
**Example 3:**
\\\powershell
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" -ExcludeLogin "TempUser_*"
    Skips logins matching the pattern.
\\\`n
*Note: 2 more examples available in function help*

### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Test-sqmDistributedAgReadiness

**Tests Distributed AlwaysOn AG readiness for failover.**

### Description

Validates:
    - Synchronization status between primary and secondary AGs
    - All replicas are SYNCHRONIZED
    - Listener is online
    - Network connectivity between clusters
    - Database consistency
    - No pending transactions

    Returns a readiness score (0-100) and detailed report.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | Primary SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -TargetInstance | *object* | * | Secondary SQL Server instance for network testing. Optional. |
| -OutputPath | *object* | * | Output directory for report files. Default: C:\System\WinSrvLog\MSSQL |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Test-sqmDistributedAgReadiness -SqlInstance "SQL01" -TargetInstance "DR-SQL01"
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

# 18. SSIS Configuration

This section covers **2 functions** related to SSIS Configuration.


## Invoke-sqmSsisConfiguration

****

### Description

Performs a complete initial or re-configuration of SSIS:
    1. SSIS service (service account + startup type)
    2. SSISDB catalog (incl. CLR activation, properties)
    3. AlwaysOn AG integration (SSISDB into AG, DMK restore, disable cleanup job, sp_ssis_startup)
    4. Create catalog folders and environments

    Connection modes: Local (direct) / Remote (dbatools + WinRM for service).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the SQL connection. |
| -AgName | *object* | * | Name of the AlwaysOn Availability Group (optional). |
| -AgListener | *object* | * | AG listener name (automatically determined if not specified). |
| -AgNodes | *object* | * | Explicit list of all AG nodes (optional). |
| -CatalogPassword | *object* | * | Password for the SSISDB catalog (SecureString, required). |
| -CatalogFolder | *object* | * | Array of catalog folder names (e.g. @('ETL','Staging')). |
| -CatalogFolderDescription | *object* | * | Description for the folders (default: 'Created by MSSQLTools'). |
| -Environments | *object* | * | Array of environment names (created in each CatalogFolder). |
| -SsisServiceAccount | *object* | * | Service account for the SSIS service (e.g. 'DOMAIN\svc_ssis'). |
| -SsisServiceAccountPassword | *object* | * | Password for the service account (SecureString). |
| -SsisServiceStartupType | *object* | * | Startup type of the SSIS service (Automatic, Manual, Disabled; default: Automatic). |
| -RetentionPeriod | *object* | * | Retention period for SSISDB logs in days (default: 365). |
| -LoggingLevel | *object* | * | Logging level (0=None, 1=Basic, 2=Performance, 3=Verbose; default: 1). |
| -MaxConcurrentExecutables | *object* | * | Maximum concurrent executions (default: -1 = unlimited). |
| -SkipService | *object* | * | Skip service configuration. |
| -SkipCatalog | *object* | * | Skip catalog creation/configuration. |
| -SkipAg | *object* | * | Skip AG integration (even if -AgName is specified). |
| -SkipFolders | *object* | * | Skip folder/environment creation. |
| -WinRmCredential | *object* | * | Credentials for WinRM (remote service configuration, optional). |
| -OutputPath | *object* | * | Output directory for the configuration report.     Default: Get-sqmDefaultOutputPath. |
| -ContinueOnError | *object* | * | Continue with the next step on error (rarely used). |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before critical changes. |
| -WhatIf | *object* | * | Shows what would happen without making changes. |

### Examples

**Example 1:**
\\\powershell
$pwd = Read-Host "SSISDB-Kennwort" -AsSecureString
    Invoke-sqmSsisConfiguration -SqlInstance "SQL01" -CatalogPassword $pwd
\\\`n
**Example 2:**
\\\powershell
$pwd = Read-Host "SSISDB-Kennwort" -AsSecureString
    Invoke-sqmSsisConfiguration -SqlInstance "SQL01" -AgName "AG_SSIS" -CatalogPassword $pwd
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmSSISPackageCompatibility

**Validates SSIS package compatibility for SQL Server upgrades (2016 - 2025).**

### Description

Tests whether SSIS packages will run in a target SQL Server version.
    Checks deprecated features, encoding issues, and connection types.

    Supports two package sources:
    1. SSISDB Catalog (deployed packages on target SQL Server)
    2. Filesystem .dtsx files (backup/undeployed packages)

    Output: HTML report + TXT + CSV (dark theme, with summary cards and filter)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance to connect to (for SSISDB source).     Omit to check only filesystem packages. |
| -SqlCredential | *object* | * | Optional PSCredential for SQL authentication. |
| -FolderName | *object* | * | Filter SSISDB packages to specific catalog folder(s).     Example: 'MyFolder', 'Integration', etc. |
| -PackagePath | *object* | * | Path to .dtsx files (filesystem source).     Omit to check only SSISDB packages. |
| -Recurse | *object* | * | Recurse into subfolders when reading .dtsx files. |
| -TargetVersion | *object* | * | Target SQL Server version for compatibility check.     Supported: 2016, 2017, 2019, 2022, 2025     D |
| -OutputPath | *object* | * | Directory for HTML/TXT/CSV reports.     Default: $env:ProgramData\sqmSQLTool\SSISReports |
| -EnableException | *object* | * | Throw exceptions instead of returning error status. |

### Examples

**Example 1:**
\\\powershell
# Check deployed packages on target server
    Test-sqmSSISPackageCompatibility -SqlInstance "NewServer2025" -TargetVersion 2025
\\\`n
**Example 2:**
\\\powershell
# Check old package files before deployment
    Test-sqmSSISPackageCompatibility -PackagePath "C:\OldPackages" -TargetVersion 2025 -Recurse
\\\`n
**Example 3:**
\\\powershell
# Compare deployed vs. backup packages
    Test-sqmSSISPackageCompatibility -SqlInstance "NewServer2025" `
      -PackagePath "C:\OldPackages" -TargetVersion 2025
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

# 21. Analysis Services (SSAS)

This section covers **1 functions** related to Analysis Services (SSAS).


## Test-sqmSsasDirectoryPermissions

**Checks and corrects NTFS permissions for SSAS directories (Data, Log, Temp, Backup).**

### Description

Determines the directory paths for an SSAS instance from the registry,
    checks whether the SSAS service account has FullControl access to these directories,
    and sets any missing permissions as needed.

    The function is idempotent — on repeated calls only missing permissions are added.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -InstanceName | *object* | * | Name of the SSAS instance. Default: 'MSSQLSERVER' (default instance).     For named instances e.g.  |
| -ServiceAccount | *object* | * | Optional: Name of the service account (e.g. 'NT SERVICE\MSSQLServerOLAPService').     If not specif |
| -WhatIf | *object* | * | Shows which changes would be made without executing them. |
| -Confirm | *object* | * | Prompts for confirmation before each change. |
| -EnableException | *object* | * | Throws an exception immediately on errors (otherwise the error is logged). |
| -ContinueOnError | *object* | * | Continues checking the next directories even on errors. |

### Examples

**Example 1:**
\\\powershell
Test-sqmSsasDirectoryPermissions

    Checks the directories of the default SSAS instance and corrects missing permissions.
\\\`n
**Example 2:**
\\\powershell
Test-sqmSsasDirectoryPermissions -InstanceName "SSAS2019" -WhatIf

    Shows which permissions would be set for the named instance.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 2. Performance Analysis & Optimization

This section covers **10 functions** related to Performance Analysis & Optimization.


## Get-sqmIndexFragmentation

**Analyzes index fragmentation in one or more databases.**

### Description

Returns the fragmentation level (%) for all indexes and recommends an action:
        - 5-30%  -> REORGANIZE
        - >30%   -> REBUILD
    Output can be restricted to specific databases, tables or a minimum fragmentation level.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Database | *object* | * | Database name or wildcard pattern (e.g. 'Sales*'). Default: all user databases. |
| -TableName | *object* | * | Table name or wildcard pattern (e.g. 'Order*'). Default: all tables. |
| -MinFragmentationPercent | *object* | * | Show only indexes with fragmentation >= this value. Default: 5. |
| -PageCountMin | *object* | * | Show only indexes with at least this page count. Default: 0 (all indexes). |
| -OutputPath | *object* | * | Optional CSV export path. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmIndexFragmentation -Database 'AdventureWorks' -MinFragmentationPercent 10
\\\`n
**Example 2:**
\\\powershell
Get-sqmIndexFragmentation -SqlInstance 'SQL01' -MinFragmentationPercent 30
\\\`n
### Best Practices

- Always verify AG health before making changes
- Test in non-production first for listener migrations
- Ensure all databases are SYNCHRONIZED before failovers

---

## Get-sqmMissingIndexes

**Retrieves missing index recommendations from the SQL Server DMV cache.**

### Description

Reads sys.dm_db_missing_index_details, sys.dm_db_missing_index_groups and
    sys.dm_db_missing_index_group_stats and calculates an impact score
    (using the Microsoft formula) and a ready-to-use CREATE INDEX statement per missing index.

    Per recommendation the following is returned:
      - Database, schema, table
      - Equality and inequality columns, include columns
      - Impact score (0-100, calculated from seeks/scans/lookups * avg_user_cost * avg_user_impact)
      - Number of seeks, scans, lookups since last SQL Server restart
      - Last seek timestamp
      - Ready-to-use CREATE INDEX statement with suggested index name

    IMPORTANT: DMV data is volatile (reset on SQL Server restart, failover,
    and certain plan cache events). Always review recommendations with the DBA
    before creating indexes - especially on heavily loaded systems.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Database | *object* | * | Filter by database name(s). Wildcards allowed. Default: all user databases. |
| -MinImpactScore | *object* | * | Return only recommendations with impact score >= this value. Default: 10. |
| -MinSeeks | *object* | * | Return only recommendations with at least this number of seeks/scans. Default: 50. |
| -Top | *object* | * | Return at most this number of recommendations (sorted by impact score). Default: 50. |
| -OutputPath | *object* | * | If specified, a CSV file with the recommendations and CREATE statements     is written to this dire |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmMissingIndexes -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
# Only high-impact recommendations
    Get-sqmMissingIndexes -SqlInstance "SQL01" -MinImpactScore 50 -MinSeeks 500
\\\`n
**Example 3:**
\\\powershell
# Show top 10 and save as CSV
    Get-sqmMissingIndexes -SqlInstance "SQL01" -Top 10 -OutputPath "D:\Reports"
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmWaitStatistics

**Reads and analyzes SQL Server wait statistics from sys.dm_os_wait_stats.**

### Description

Reads the cumulative wait statistics of the instance, filters out known idle waits
    and returns the top-N waits with category and recommended action.
    Optional: snapshot comparison (before/after) via -SnapshotBefore/-SaveSnapshot.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: local computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -TopN | *object* | * | Number of top wait types to return. Default: 25. |
| -IncludeIdle | *object* | * | Include idle waits (SLEEP_*, WAITFOR, etc.). Default: off. |
| -SnapshotBefore | *object* | * | PSCustomObject array of an earlier snapshot (output of -SaveSnapshot).     If specified, only the de |
| -SaveSnapshot | *object* | * | Returns a snapshot array that can later be used as SnapshotBefore. |
| -OutputPath | *object* | * | If specified, a CSV report is saved. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmWaitStatistics -SqlInstance "SQL01" -TopN 20
\\\`n
**Example 2:**
\\\powershell
$before = Get-sqmWaitStatistics -SqlInstance "SQL01" -SaveSnapshot
    Get-sqmWaitStatistics -SqlInstance "SQL01" -SnapshotBefore $before
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmPerfBaseline

**Creates, compares or lists performance baselines (wait stats + perf counters).**

### Description

Capture: Saves the current snapshot of sys.dm_os_wait_stats and
    sys.dm_os_performance_counters as a JSON file.
    Compare: Calculates the delta between two baselines.
    List:    Lists all saved baseline files.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: local computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Action | *object* | * | Capture / Compare / List. Default: Capture. |
| -BaselineName | *object* | * | Label for the snapshot (used in the file name).     Default: timestamp. |
| -BaselineA | *object* | * | Path or file name (without path) of the first baseline for comparison.     Default: the second-to-la |
| -BaselineB | *object* | * | Path or file name of the second (newer) baseline.     Default: the most recent file in OutputPath. |
| -OutputPath | *object* | * | Directory for baseline JSON files.     Default: from module configuration + \PerfBaseline. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Capture baseline
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -BaselineName "before_patch"
\\\`n
**Example 2:**
\\\powershell
# Capture baseline after change and compare
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -BaselineName "after_patch"
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -Action Compare
\\\`n
**Example 3:**
\\\powershell
# List all baselines
    Invoke-sqmPerfBaseline -SqlInstance "SQL01" -Action List
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmQueryStore

**Configures the Query Store, reads from it, detects issues and saves reports.**

### Description

Comprehensive Query Store management for one, multiple or all user databases.

    Operating modes (switches, combinable):
      -Configure  Enables and configures the Query Store (ALTER DATABASE SET QUERY_STORE).
      -Query      Reads the top-N queries from the Query Store (by duration, CPU, reads, etc.).
      -Diagnose   Detects issues: READ_ONLY status, memory pressure, plan regression,
                  forced plan failures, unstable execution plans.

    If none of the three switches are specified, -Query and -Diagnose are executed
    (report mode).

    Results are returned as PSCustomObject and optionally saved as CSV/TXT.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Database | *object* | * | One or more databases. Ignored when -All is set. |
| -All | *object* | * | Process all accessible user databases. |
| -Configure | *object* | * | Configure Query Store (enable/set parameters). |
| -Query | *object* | * | Read top-N queries from the Query Store. |
| -Diagnose | *object* | * | Detect issues in the Query Store and return them as issues. |
| -OperationMode | *object* | * | Query Store operation mode. Values: READ_WRITE, READ_ONLY, OFF. Default: READ_WRITE. |
| -FlushIntervalSeconds | *object* | * | Frequency of writing to the Query Store (seconds). Default: 900. |
| -IntervalLengthMinutes | *object* | * | Length of a statistics interval (minutes). Default: 60. |
| -MaxStorageSizeMB | *object* | * | Maximum size of the Query Store (MB). Default: 1000. |
| -QueryCaptureMode | *object* | * | Capture mode. Values: ALL, AUTO, NONE. Default: AUTO. |
| -SizeBasedCleanupMode | *object* | * | Automatic cleanup under memory pressure. Values: OFF, AUTO. Default: AUTO. |
| -MaxPlansPerQuery | *object* | * | Maximum number of execution plans per query. Default: 200. |
| -TopN | *object* | * | Number of top queries to return. Default: 25. |
| -OrderBy | *object* | * | Sort column for top queries. Values: Duration, CPU, LogicalReads, ExecutionCount, Memory.     Defaul |
| -LookbackHours | *object* | * | Lookback period in hours (from now backwards). Default: 24. |
| -MinExecutionCount | *object* | * | Minimum number of executions required to be included in top queries. Default: 5. |
| -StorageWarningPct | *object* | * | Fill level (%) at which a storage warning is issued. Default: 80. |
| -MaxPlansWarning | *object* | * | Number of plans per query at which a plan instability warning is issued. Default: 5. |
| -OutputPath | *object* | * | Directory for reports (CSV + TXT). Default: from module configuration + \QueryStore. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Report for all databases (Query + Diagnose)
    Invoke-sqmQueryStore -All
\\\`n
**Example 2:**
\\\powershell
# Configure Query Store and query immediately
    Invoke-sqmQueryStore -Database "SalesDB","CRM" -Configure -Query -Diagnose
\\\`n
**Example 3:**
\\\powershell
# Top 50 queries by CPU consumption, last 48 hours
    Invoke-sqmQueryStore -Database "SalesDB" -Query -TopN 50 -OrderBy CPU -LookbackHours 48
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmCostThreshold

**Prueft ob CostThresholdForParallelism auf dem empfohlenen Wert liegt.**

### Description

Liest den aktuellen Wert von CostThresholdForParallelism per SMO und
    vergleicht ihn mit dem konfigurierbaren Mindestwert (Standard: 50).
    Der SQL Server Default von 5 ist fuer moderne Systeme in der Regel
    zu niedrig und fuehrt zu unnoetigem parallelen Ausfuehrungsaufwand
    bei kurzen Abfragen.

    Gibt ein PSCustomObject mit Status, aktuellem Wert und Empfehlung zurueck.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server-Instanz. Standard: lokaler Computername. |
| -SqlCredential | *object* | * | PSCredential fuer die SQL-Verbindung. |
| -MinRecommendedValue | *object* | * | Mindestwert fuer CostThresholdForParallelism. Standard: 50. |
| -EnableException | *object* | * | Ausnahmen sofort ausloesen statt Write-Error. |

### Examples

**Example 1:**
\\\powershell
Test-sqmCostThreshold -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Test-sqmCostThreshold -SqlInstance "SQL01" -MinRecommendedValue 25
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmMaxDop

**Prueft ob MAXDOP (Max Degree of Parallelism) korrekt konfiguriert ist.**

### Description

Liest den aktuellen MAXDOP-Wert aus sys.configurations und vergleicht
    ihn mit der Microsoft-Empfehlung:
        Empfehlung: min(8, Anzahl logischer CPUs)

    Sonderwert 0 bedeutet "kein Limit" = unkonfiguriert (SQL-Default, nicht empfohlen).

    Status-Auswertung:
        OK          : MAXDOP entspricht der Empfehlung
        Suboptimal  : MAXDOP weicht von der Empfehlung ab (zu hoch oder zu niedrig, aber > 0)
        Unconfigured: MAXDOP = 0 (unbegrenzt, Standard-Default)

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server-Instanzname. Z.B. "MSSQLSERVER" oder "SERVER\INST01". |

### Examples

**Example 1:**
\\\powershell
Test-sqmMaxDop -SqlInstance 'MSSQLSERVER'
\\\`n
**Example 2:**
\\\powershell
Test-sqmMaxDop -SqlInstance 'SQL01\INST01'
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmMaxMemory

**Prueft ob SQL Server Max Server Memory korrekt konfiguriert ist.**

### Description

Liest den aktuellen "max server memory (MB)"-Wert und vergleicht ihn
    mit der Empfehlung (90% des physischen RAM).

    Sonderwert 2147483647 (= 2^31 - 1) bedeutet "nicht konfiguriert" (SQL-Standard-Default).

    Status-Auswertung:
        OK          : Konfigurierter Wert liegt im Toleranzbereich (>=85% und <=95% RAM)
        TooHigh     : Konfiguriert aber oberhalb 95% RAM (Risiko fuer OS)
        TooLow      : Konfiguriert aber unterhalb 85% RAM (SQL Server unterversorgt)
        Unconfigured: Wert ist 2147483647 - Standard-Default, kein expliziter Wert gesetzt

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server-Instanzname. Z.B. "MSSQLSERVER" oder "SERVER\INST01". |
| -RecommendedPct | *object* | * | Empfohlener Prozentsatz des RAM fuer SQL Server. Standard: 90. |

### Examples

**Example 1:**
\\\powershell
Test-sqmMaxMemory -SqlInstance 'MSSQLSERVER'
\\\`n
**Example 2:**
\\\powershell
Test-sqmMaxMemory -SqlInstance 'SQL01\INST01' | Where-Object { $_.Status -ne 'OK' }
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmTempDbRecommendation

**Analyzes the TempDB configuration and provides optimization recommendations.**

### Description

Checks the number and size of TempDB files, autogrow settings and the path.
    Recommends file count (matching CPU core count, max 8), equal sizes, MB-based autogrow,
    and separate drives where possible.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -OutputPath | *object* | * | Optional CSV export path. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
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
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Test-sqmTempDbFileCount

**Prueft ob die Anzahl der TempDB-Datendateien der empfohlenen CPU-Anzahl entspricht.**

### Description

Liest die Anzahl der TempDB-Datendateien (Typ = Rows, ohne Log) per SMO und
    vergleicht sie mit der Anzahl der CPU-Kerne des Servers (max 8 gemaess
    Microsoft-Empfehlung).

    Hintergrund: Zu wenige TempDB-Dateien koennen zu PAGELATCH-Konflikten auf
    der Allocation-Seite fuehren. Microsoft empfiehlt eine Datei pro
    logischem Kern, maximal 8.

    Gibt ein PSCustomObject mit aktuellem Wert, empfohlenem Wert und Status zurueck.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server-Instanz. Standard: lokaler Computername. |
| -SqlCredential | *object* | * | PSCredential fuer die SQL-Verbindung. |
| -MaxFiles | *object* | * | Maximale empfohlene Dateianzahl. Standard: 8 (Microsoft-Empfehlung). |
| -EnableException | *object* | * | Ausnahmen sofort ausloesen statt Write-Error. |

### Examples

**Example 1:**
\\\powershell
Test-sqmTempDbFileCount -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
Test-sqmTempDbFileCount -SqlInstance "SQL01\INST1" -MaxFiles 4
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 6. Certificates & TLS Security

This section covers **8 functions** related to Certificates & TLS Security.


## Get-sqmCertificateReport

**Creates a comprehensive report on SQL Server certificates and their expiration dates.**

### Description

Checks all security-relevant certificates on one or more instances:

    MASTER KEY
      - Checks whether a Database Master Key exists in master (required for certificates)
      - Checks whether the DMK is encrypted by the Service Master Key (important for automatic startup)

    INSTANCE CERTIFICATES (sys.certificates in master)
      - AlwaysOn endpoint certificates (Hadr_endpoint)
      - Service Broker certificates
      - Backup encryption certificates
      - All other certificates in master

    TDE CERTIFICATES (Transparent Data Encryption)
      - Per encrypted database: which certificate, expiration date, encryption state

    DATABASE CERTIFICATES
      - Certificates in user databases (e.g. for column encryption, signing)

    PER CERTIFICATE:
      - Name, type, issuer, subject
      - Expiration date with traffic-light status (OK / Warning / Critical / Expired)
      - Remaining days until expiration
      - Purpose (AlwaysOn / TDE / ServiceBroker / Backup / UserDefined)
      - Whether the private key is present and encrypted
      - Thumbprint

    Results are saved as TXT report and CSV in the configured OutputPath.
    An additional filtered CSV is generated containing only expiring/expired certificates.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -WarningThresholdDays | *object* | * | Certificates expiring in less than this number of days receive status 'Warning'. Default: 90. |
| -CriticalThresholdDays | *object* | * | Certificates expiring in less than this number of days receive status 'Critical'. Default: 30. |
| -IncludeUserDatabases | *object* | * | Also include certificates in user databases. Default: $false. |
| -OutputPath | *object* | * | Output directory for report files. Default: from module configuration. |
| -ContinueOnError | *object* | * | Continue on error for an instance instead of aborting. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Get-sqmCertificateReport
\\\`n
**Example 2:**
\\\powershell
Get-sqmCertificateReport -SqlInstance "SQL01","SQL02" -WarningThresholdDays 180
\\\`n
**Example 3:**
\\\powershell
# Show only expiring certificates
    Get-sqmCertificateReport -SqlInstance "SQL01" |
        Select-Object -ExpandProperty Certificates |
        Where-Object { $_.ExpiryStatus -ne 'OK' } |
        Select-Object SqlInstance, DatabaseName, CertificateName, ExpiryDate, DaysRemaining, ExpiryStatus, Purpose
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Install-sqmCertificate

****

### Description

Supports three input formats:
      PFX   (.pfx)  - Certificate + private key in one file (CA-signed or exported)
      CER+PVK       - Certificate (.cer) + encrypted private key (.pvk) separately
      CER only      - Certificate without private key (e.g. public key for AlwaysOn replicas)

    Process:
      1. Read certificate file and validate content (expiry date, subject, format)
      2. Check whether a certificate with the same thumbprint already exists in SQL Server
      3. Import certificate via CREATE CERTIFICATE in SQL Server
      4. Automatically bind based on -Purpose:
           AlwaysOn      -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
                            Output guidance for replica distribution
           TDE           -> ALTER DATABASE ... SET ENCRYPTION KEY ... CERTIFICATE <new>
           SSL           -> Import certificate into Windows machine store +
                            set SQL Server network protocol certificate (Registry)
           ServiceBroker -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
      5. Write installation log as TXT

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the SQL Server connection. |
| -CertFile | *object* | * | Path to the certificate file (.pfx, .cer, .crt, .p12).     For PFX the private key is automatically |
| -PrivateKeyFile | *object* | * | Path to the separate private key file (.pvk). Only required for CER+PVK format. |
| -CertPassword | *object* | * | Password for the PFX file or .pvk file (as SecureString). |
| -CertificateName | *object* | * | Name under which the certificate is created in SQL Server.     Default: file name without extension |
| -Database | *object* | * | Target database in SQL Server. Default: master. |
| -Purpose | *object* | * | Purpose determines the automatic binding after import.     Valid values: AlwaysOn, TDE, SSL, Servic |
| -EndpointName | *object* | * | Name of the endpoint for AlwaysOn/ServiceBroker binding.     If not specified, the first matching e |
| -TdeDatabaseName | *object* | * | Name of the database for TDE binding. If not specified, the current     TDE-encrypted database on t |
| -ReplaceCertificateName | *object* | * | Name of an existing certificate that is replaced (endpoint/TDE switched)     after successful insta |
| -ImportToWindowsStore | *object* | * | Additionally import the certificate into the Windows machine certificate store.     Required for SS |
| -SetSqlServerSslCert | *object* | * | Set the SQL Server network configuration to use this certificate (thumbprint).     Requires a resta |
| -OutputPath | *object* | * | Output directory for the installation log. Default: from module configuration. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Import PFX from CA and bind to AlwaysOn endpoint
    Install-sqmCertificate -SqlInstance "SQL01" -CertFile "C:\Certs\sql01.pfx" `
        -CertPassword (Read-Host -AsSecureString) -Purpose AlwaysOn
\\\`n
**Example 2:**
\\\powershell
# Install public-key certificate on AlwaysOn replica (no private key)
    Install-sqmCertificate -SqlInstance "SQL02" -CertFile "C:\Certs\SQL01_AG_CERT.cer" `
        -CertificateName "SQL01_AG_CERT" -Purpose AlwaysOn
\\\`n
**Example 3:**
\\\powershell
# Install CER + PVK and bind TDE
    Install-sqmCertificate -SqlInstance "SQL01" `
        -CertFile "C:\Certs\tde_new.cer" `
        -PrivateKeyFile "C:\Certs\tde_new.pvk" `
        -CertPassword (Read-Host -AsSecureString "PVK password") `
        -Purpose TDE -TdeDatabaseName "ProdDB"
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Install-sqmCertificateToStore

****

### Description

Reads a certificate file (.cer, .crt, or .pfx) and installs it into the
    specified Windows certificate store (LocalMachine) on one or more computers.

    Use cases:
      - Distribute a CA root certificate to the Trusted Root store on all nodes
      - Distribute a SQL Server self-signed certificate to admin workstations
      - Distribute AlwaysOn partner certificates (CER without private key) to replica machines

    Process:
      1. Read the certificate file and determine format (PFX vs CER/CRT) by extension
         and by attempting to parse the file
      2. For PFX files: load with X509KeyStorageFlags MachineKeySet + PersistKeySet
         and an optional password
      3. For CER/CRT files: load without password
      4. Open the target store (LocalMachine\<StoreName>) with ReadWrite access
      5. Check whether a certificate with the same thumbprint is already present -
         skip and log WARNING if so
      6. Add the certificate and close the store
      7. For remote computers: serialize the certificate as a byte array and pass it
         via Invoke-Command so the import runs on the target without needing file share access

    Returns one PSCustomObject per target computer with:
      ComputerName, StoreName, Thumbprint, Subject, Expiry, Action
    Action values: Installed / AlreadyPresent / Failed

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -CertFile | *object* | * | Full path to the certificate file (.cer, .crt, or .pfx).     The file must exist and be readable. |
| -StoreName | *object* | * | Target Windows certificate store under LocalMachine.     Valid values: Root, My, TrustedPeople, CA   |
| -ComputerName | *object* | * | One or more target computer names. Default: localhost only (the local machine).     For remote targe |
| -CertPassword | *object* | * | Password for PFX files as SecureString. Ignored for CER/CRT files. |

### Examples

**Example 1:**
\\\powershell
# Install a CA root certificate to the Trusted Root store on all AlwaysOn replica nodes
    $nodes = 'SQL-AG-01', 'SQL-AG-02', 'SQL-AG-03'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\CompanyRootCA.cer' `
        -StoreName Root -ComputerName $nodes
\\\`n
**Example 2:**
\\\powershell
# Distribute a SQL Server self-signed certificate to an admin workstation
    Install-sqmCertificateToStore -CertFile 'C:\Certs\SQL-PROD-01.cer' `
        -StoreName TrustedPeople -ComputerName 'ADMINWS-01'
\\\`n
**Example 3:**
\\\powershell
# Distribute an AlwaysOn partner certificate (CER without private key) to replica machines
    $replicas = 'SQL-AG-02', 'SQL-AG-03'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\SQL-AG-01_AG_CERT.cer' `
        -StoreName My -ComputerName $replicas
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## New-sqmCertificateRequest

****

### Description

Reads all relevant properties of the existing certificate from SQL Server
    (Subject, SANs, purpose, endpoint binding) and creates:

    1. INF file (certreq configuration) with all fields from the existing certificate
    2. CSR file (.csr / PKCS#10) via Windows certreq.exe or New-SelfSignedCertificate
    3. Order data sheet (.txt) with:
         - All information for the CA order (Subject, SANs, Key Usage, EKU)
         - Suggested certificate type based on purpose
         - Checklist for the ordering process
         - T-SQL commands for later installation
    4. Optional: Generate private key locally and store securely

    PURPOSE-SPECIFIC HANDLING:
      AlwaysOn / Mirroring  -> Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication (1.3.6.1.5.5.7.3.1)
      TDE                   -> Note: TDE typically uses self-signed certificates;
                               CA-signed certificates are possible but uncommon
      SSL/TLS connections   -> Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication + Client Authentication
      Service Broker        -> Key Usage: Digital Signature, Key Encipherment

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). Used for SAN and order sheet. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -CertificateName | *object* | * | Name of the existing certificate to use as a template. If not specified, a new     certificate is c |
| -Database | *object* | * | Database where the certificate resides. Default: master. |
| -Subject | *object* | * | Subject (CN) of the new certificate. Overrides the value from the existing certificate.     Format: |
| -SubjectAlternativeNames | *object* | * | Additional SANs (DNS names or IP addresses).     Automatically extended with: FQDN, NetBIOS name, A |
| -KeyLength | *object* | * | Key length in bits. Default: 4096. |
| -ValidityYears | *object* | * | Desired validity period in years (information for the CA, not guaranteed). Default: 3. |
| -Purpose | *object* | * | Purpose when no existing certificate is used as a template.     Valid values: AlwaysOn, TDE, SSL, S |
| -OutputPath | *object* | * | Output directory for CSR, INF, and order data sheet. Default: $env:ProgramData\sqmSQLTool\Logs\Cert |
| -Organization | *object* | * | Organization name for the certificate (O=). Default: from existing certificate or computer name. |
| -OrganizationalUnit | *object* | * | Organizational unit (OU=). Optional. |
| -Locality | *object* | * | City/locality (L=). Optional. |
| -State | *object* | * | State/province (S=). Optional. |
| -Country | *object* | * | Two-letter country code (C=). Default: DE. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# CSR based on an existing certificate
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "AG_CERT"
\\\`n
**Example 2:**
\\\powershell
# New CSR without template, all fields specified manually
    New-sqmCertificateRequest -SqlInstance "SQL01" -Purpose "SSL" `
        -Subject "CN=SQL01.firma.de,O=Firma GmbH,L=Muenchen,C=DE" `
        -SubjectAlternativeNames @("sql01.firma.de","sql01","192.168.1.10") `
        -KeyLength 4096 -ValidityYears 2
\\\`n
**Example 3:**
\\\powershell
# CSR with output to a specific directory
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "TLS_CERT" `
        -OutputPath "D:\CertRequests"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## New-sqmSqlCertificate

**Creates a new self-signed SQL Server certificate as a renewal of an existing one.**

### Description

Reads all relevant properties of the existing certificate (Subject, purpose,
    endpoint binding, TDE binding) and creates a new self-signed certificate directly
    in SQL Server using CREATE CERTIFICATE.

    Process:
      1. Read existing certificate and determine its purpose
      2. Back up old certificate as .cer + private key as .pvk (BackupPath)
      3. Create new certificate with same properties and new expiry date
      4. Automatically bind based on purpose:
           AlwaysOn  -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
           TDE       -> ALTER DATABASE ... SET ENCRYPTION KEY ... CERTIFICATE <new>
           Broker    -> ALTER ENDPOINT ... AUTHENTICATION = CERTIFICATE <new>
      5. Rename old certificate (suffix _OLD_<date>) — do not delete
      6. Output order data sheet as TXT (Subject, thumbprint old/new, bindings)

    NOTE: For AlwaysOn, the new certificate must subsequently be distributed to all
    replica instances. The function outputs the necessary steps as instructions.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -CertificateName | *object* | * | Name of the certificate to renew (exact name from sys.certificates). |
| -Database | *object* | * | Database where the certificate resides. Default: master. |
| -NewCertificateName | *object* | * | Name of the new certificate. Default: <OldName>_<Year> (e.g. AG_CERT_2027). |
| -ValidityYears | *object* | * | Validity period of the new certificate in years. Default: 5. |
| -BackupPath | *object* | * | Path for backing up the old certificate (.cer and .pvk).     Default: from module configuration (Ou |
| -BackupEncryptionPassword | *object* | * | Password for encrypting the exported private key (.pvk).     Required when the old certificate has  |
| -RenameOldCertificate | *object* | * | Rename the old certificate after renewal (suffix _OLD_<date>). Default: $true. |
| -BindEndpoint | *object* | * | Automatically bind the new certificate to the existing endpoint (AlwaysOn/Broker).     Default: $fa |
| -BindTde | *object* | * | Automatically activate the new certificate for TDE-encrypted databases.     Default: $false — must  |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Simple renewal without automatic binding
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "AG_CERT" -BackupEncryptionPassword (Read-Host -AsSecureString)
\\\`n
**Example 2:**
\\\powershell
# With automatic endpoint binding and 10-year validity
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "AG_CERT" `
        -ValidityYears 10 -BindEndpoint `
        -BackupEncryptionPassword (Read-Host -AsSecureString "Backup-Passwort")
\\\`n
**Example 3:**
\\\powershell
# Renew TDE certificate
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "TDE_PROD" `
        -BindTde -BackupEncryptionPassword (Read-Host -AsSecureString "Backup-Passwort")
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Set-sqmSqlTlsCertificate

**Binds a Windows certificate from the Machine store to SQL Server as the TLS certificate.**

### Description

Replaces the default self-signed auto-generated SQL Server TLS certificate with a
    proper certificate from the LocalMachine\My store. This eliminates SSL/TLS connection
    warnings in client applications and satisfies security/compliance requirements.

    Process:
      1. Resolve the SQL Server instance registry key name from the Instance Names registry
      2. Validate the certificate: find by thumbprint, check expiry, verify private key
      3. Determine SQL Server service name (MSSQLSERVER or MSSQL$INSTANCENAME)
      4. Get SQL Server service account from WMI
      5. Grant READ permission on the certificate private key to the service account
         (supports both CSP keys in MachineKeys and CNG keys in Crypto\Keys)
      6. Write the thumbprint to the SuperSocketNetLib registry key
      7. Optionally enable Force Encryption in the same registry key
      8. Optionally restart the SQL Server service to apply the change

    Returns a PSCustomObject summarising the result. A service restart is always required
    for the new certificate to take effect - either via -Restart or manually.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance name. For a default instance use the computer name or leave     at default ($env |
| -Thumbprint | *object* | * | Certificate thumbprint (hex string). Spaces are stripped automatically.     Must match a certificate |
| -ForceEncryption | *object* | * | If specified, sets ForceEncryption = 1 in the SuperSocketNetLib registry key,     requiring all conn |
| -Restart | *object* | * | If specified, restarts the SQL Server service automatically after the registry     change. Without t |
| -WhatIf | *object* | * | Shows what would be changed without making any modifications. |
| -Confirm | *object* | * | Prompts for confirmation before making changes. |

### Examples

**Example 1:**
\\\powershell
Set-sqmSqlTlsCertificate -SqlInstance "SQL01" -Thumbprint "A1B2C3D4E5F6..."

    Binds the specified certificate to the default instance on SQL01.
    Service restart must be performed manually.
\\\`n
**Example 2:**
\\\powershell
Set-sqmSqlTlsCertificate -SqlInstance "SQL01\INST1" -Thumbprint "A1B2C3D4E5F6..." -ForceEncryption -Restart

    Binds the certificate to the named instance INST1, enables Force Encryption,
    and restarts the SQL Server service automatically.
\\\`n
**Example 3:**
\\\powershell
Set-sqmSqlTlsCertificate -Thumbprint "A1 B2 C3 D4 E5 F6" -WhatIf

    Shows what would be done for the local default instance without making changes.
    Thumbprint spaces are stripped automatically.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Set-sqmSsrsHttpsCertificate

**Binds a Windows certificate to SSRS or Power BI Report Server for HTTPS access.**

### Description

Eliminates browser security warnings by binding a valid certificate to the SSRS
		or Power BI Report Server (PBIRS) HTTPS endpoint via the WMI configuration interface.

		The function performs the following steps:
		1. Discovers the SSRS/PBIRS WMI namespace dynamically under
		   root\Microsoft\SqlServer\ReportServer\{Instance}\v{Version}\Admin
		2. Validates the certificate in Cert:\LocalMachine\My by thumbprint
		3. Lists and removes existing HTTPS URL reservations for all web applications
		4. Removes existing SSL certificate bindings
		5. Reserves HTTPS URLs for all applicable web applications
		6. Creates the SSL certificate binding
		7. Optionally sets SecureConnectionLevel to require HTTPS
		8. Calls ApplyChanges() to finalize

		Supported application names (auto-detected by version):
		- ReportServerWebService  (always present)
		- ReportManager           (SSRS 2016 and earlier, v13-)
		- ReportServerWebApp      (SSRS 2017+ / PBIRS, v14+)

		Prerequisites: Local administrator rights on the target computer.
		For remote execution, WinRM must be available.
		The certificate must already be present in the LocalMachine\My store on the target.
		The SSRS service may need to be restarted after binding.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer name or IP address. Default: localhost ($env:COMPUTERNAME). |
| -Thumbprint | *object* | * | Mandatory. Certificate thumbprint (40 hex characters) from the LocalMachine\My store. 		Spaces are a |
| -Port | *object* | * | HTTPS port to bind. Default: 443. |
| -InstanceName | *object* | * | SSRS WMI instance name (e.g. "RS_SSRS", "RS_PBIRS"). 		Auto-detected when only one instance is found |
| -IPAddress | *object* | * | IP address for the SSL binding. Default: "0.0.0.0" (all interfaces). |
| -RequireSSL | *object* | * | When specified, sets SecureConnectionLevel = 1 (HTTPS required). 		Default: SecureConnectionLevel =  |
| -Credential | *object* | * | PSCredential for the WinRM session (remote operation only). |
| -WhatIf | *object* | * | Shows what would happen without making any changes. |
| -Confirm | *object* | * | Prompts for confirmation before applying changes. |

### Examples

**Example 1:**
\\\powershell
Set-sqmSsrsHttpsCertificate -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"

		Binds the specified certificate to SSRS on the local machine on port 443.
		The SSRS instance is auto-detected.
\\\`n
**Example 2:**
\\\powershell
Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER01" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Port 8443 -InstanceName "RS_PBIRS" -RequireSSL

		Binds the certificate to Power BI Report Server on REPSERVER01, port 8443,
		and requires HTTPS (SecureConnectionLevel = 1).
\\\`n
**Example 3:**
\\\powershell
$cred = Get-Credential
		Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER02" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Credential $cred -WhatIf

		Shows what changes would be made on REPSERVER02 without applying them.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Get-sqmTlsStatus

**Audits TLS/SSL configuration and certificate status for all SQL Server instances on one or more computers.**

### Description

Get-sqmTlsStatus connects to each target computer (locally or via Invoke-Command for remotes),
    reads the SQL Server instance list from the registry, and for each instance checks:

    - The TLS certificate thumbprint bound in SuperSocketNetLib (empty = auto-generated self-signed)
    - Whether ForceEncryption is enabled (0 = Warning, 1 = required)
    - Certificate details from the local machine certificate store (Cert:\LocalMachine\My):
        Expiry date, days remaining, Subject/CN, SAN entries, chain trust validation, private key presence
    - TLS protocol version state at the OS/SCHANNEL level:
        TLS 1.0, TLS 1.1, TLS 1.2, TLS 1.3 -- each reported as Enabled, Disabled, or NotConfigured

    Status is calculated per instance:
    - Critical : cert expired, cert not found in store, or cert chain not trusted
    - Warning  : cert expires within 60 days, ForceEncryption = 0, or TLS 1.0 / TLS 1.1 enabled
    - OK       : cert trusted, not expiring soon, ForceEncryption = 1, TLS 1.0 and TLS 1.1 disabled

    Results are written to a CSV and a TXT summary report in OutputPath, and returned as PSCustomObjects.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | One or more computer names to audit. Default: current computer ($env:COMPUTERNAME). |
| -Credential | *object* | * | Optional PSCredential used for Invoke-Command when auditing remote computers. |
| -OutputPath | *object* | * | Directory where the CSV and TXT report files are saved.     Default: C:\System\WinSrvLog\MSSQL |
| -WarnDaysBeforeExpiry | *object* | * | Number of days before certificate expiry that triggers a Warning status.     Default: 60 |

### Examples

**Example 1:**
\\\powershell
Get-sqmTlsStatus

    Audits all SQL Server instances on the local computer and saves results to the default log folder.
\\\`n
**Example 2:**
\\\powershell
Get-sqmTlsStatus -ComputerName "SQL01", "SQL02" -OutputPath "D:\Reports"

    Audits SQL01 and SQL02, saves reports to D:\Reports.
\\\`n
**Example 3:**
\\\powershell
$cred = Get-Credential
    Get-sqmTlsStatus -ComputerName "SQL01" -Credential $cred | Where-Object Status -ne "OK"

    Audits SQL01 with explicit credentials and filters for non-OK results.
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 15. Extended Events & Diagnostics

This section covers **3 functions** related to Extended Events & Diagnostics.


## Get-sqmDeadlockReport

**Reads and analyzes deadlock events from the System Health Extended Event session.**

### Description

The System Health session (always active since SQL Server 2008) logs all
    deadlocks as XML in the ring buffer. This function reads that buffer,
    parses the deadlock graphs and returns for each deadlock:

      - Timestamp of the deadlock
      - Victim session with login, host, program, statement
      - All involved processes with their statements and held/requested locks
      - Involved resources (tables, indexes, objects)
      - Deadlock graph as XML (for SSMS import or storage as .xdl)

    Optionally, deadlock graphs can be saved as .xdl files
    (openable directly in SSMS by double-click).

    Additionally, the System Health .xel ring buffer is read when available
    (SQL Server 2012+, provides more history than the ring buffer).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -StartTime | *object* | * | Return only deadlocks from this point in time. Default: last 24 hours. |
| -EndTime | *object* | * | Return only deadlocks up to this point in time. Default: now. |
| -MaxDeadlocks | *object* | * | Maximum number of deadlocks returned (newest first). Default: 100. |
| -OutputPath | *object* | * | If specified, deadlock graphs are saved as .xdl files in this directory     (format: Deadlock_<Inst |
| -EnableException | *object* | * | Throw exceptions immediately instead of returning as errors. |

### Examples

**Example 1:**
\\\powershell
Get-sqmDeadlockReport
\\\`n
**Example 2:**
\\\powershell
Get-sqmDeadlockReport -SqlInstance "SQL01" -StartTime (Get-Date).AddDays(-7)
\\\`n
**Example 3:**
\\\powershell
# Save deadlocks as XDL files for SSMS
    Get-sqmDeadlockReport -SqlInstance "SQL01" -OutputPath "$env:ProgramData\sqmSQLTool\Logs\Deadlocks"
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmExtendedEvents

**Manages Extended Events sessions for performance analysis on SQL Server.**

### Description

Creates, starts, stops, reads and evaluates Extended Events sessions.

    Operating modes (switches, combinable):
      -Create    Creates a new XEvent session based on a template.
      -Start     Starts an existing (or newly created) session.
      -Stop      Stops a running session.
      -Read      Reads events from the XEL ring buffer or a file.
      -Diagnose  Aggregates events and detects patterns (top waits, blocking chains,
                 slow queries, deadlocks).
      -Drop      Removes a session completely (including XEL files).

    If no switch is specified, -Read and -Diagnose are executed.

    Available session templates:
      SlowQueries   sql_statement_completed > threshold (default: 1000 ms)
      Blocking      blocked_process_report
      Waits         wait_info with configurable wait list
      Deadlocks     xml_deadlock_report
      AllInOne      Combines all four templates in one session

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -SessionName | *object* | * | Name of the XEvent session. Default: 'sqmPerformance'. |
| -Template | *object* | * | Session template when creating. Values: SlowQueries, Blocking, Waits, Deadlocks, AllInOne.     Defau |
| -SlowQueryThresholdMs | *object* | * | Minimum execution duration in milliseconds for SlowQueries capture. Default: 1000. |
| -WaitTypes | *object* | * | Comma-separated list of wait types for the Waits template.     Default: LCK_M_X,LCK_M_S,LCK_M_U,PAGE |
| -TargetType | *object* | * | Target type for event storage: RingBuffer or File. Default: RingBuffer. |
| -TargetFilePath | *object* | * | Directory for XEL files (only for TargetType = File).     Default: from module configuration OutputP |
| -MaxFileSizeMB | *object* | * | Maximum size of an XEL file (MB). Default: 100. |
| -MaxRolloverFiles | *object* | * | Number of XEL rollover files. Default: 5. |
| -RingBufferMaxMB | *object* | * | Maximum size of the ring buffer (MB). Default: 50. |
| -MaxEventsRead | *object* | * | Maximum number of events when reading. Default: 10000. |
| -LookbackMinutes | *object* | * | Time window for diagnostic aggregation in minutes. Default: 60. |
| -TopN | *object* | * | Number of top entries in diagnostic tables. Default: 25. |
| -OutputPath | *object* | * | Directory for saved reports. Default: from module configuration + \XEvents. |
| -Create | *object* | * | Create session. |
| -Start | *object* | * | Start session. |
| -Stop | *object* | * | Stop session. |
| -Read | *object* | * | Read events. |
| -Diagnose | *object* | * | Aggregate events and detect issues. |
| -Drop | *object* | * | Remove session. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Create AllInOne session and start immediately
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Create -Start
\\\`n
**Example 2:**
\\\powershell
# Record Slow Queries > 2 seconds, save to file
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Template SlowQueries -SlowQueryThresholdMs 2000 -TargetType File -Create -Start
\\\`n
**Example 3:**
\\\powershell
# Read running session and create report
    Invoke-sqmExtendedEvents -SqlInstance SQL01 -Read -Diagnose
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmMonitoringKey

**Gets or sets monitoring registry values for the sqmSQLTool on one or more computers.**

### Description

Reads or writes the registry key HKLM:\<RegistryBase>\dtcSoftware\sqmSQLTool on
    the specified computers. The key controls which monitoring components are active:
    SQL monitoring level (None/Standard/Full), SQLFreeSpaceVersion (Standard/Cluster),
    and TSM backup monitoring (0/1).

    When -Operation is 'Set', the specified values are written to the registry.
    The key is created automatically if it does not exist.
    The current values are always read and returned after a write operation.

    Remote access uses Invoke-Command (WinRM). Provide -Credential for remote computers
    if required.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer(s). Pipeline-capable. Default: current computer name. |
| -Operation | *object* | * | 'Get' (default) reads the current values; 'Set' writes the specified values. |
| -SQL | *object* | * | SQL monitoring level: 'None', 'Standard', or 'Full'.     Stored as DWORD (0/1/2) in the registry. |
| -SQLFreeSpaceVersion | *object* | * | Free-space monitoring variant: 'Standard' (standalone) or 'Cluster' (AlwaysOn AG). |
| -TSM | *object* | * | TSM backup monitoring: 0 = inactive, 1 = active. |
| -RegistryBase | *object* | * | Registry hive path base under HKLM. Default: 'System'. |
| -AutoDetectSQLFreeSpaceVersion | *object* | * | When set (and -Operation Set), automatically detects whether the instance belongs to     an AlwaysO |
| -Credential | *object* | * | PSCredential for remote computer access. |
| -ContinueOnError | *object* | * | Continue with the next computer on error. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmMonitoringKey
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmMonitoringKey -Operation Set -SQL Standard -TSM 1 -AutoDetectSQLFreeSpaceVersion
\\\`n
**Example 3:**
\\\powershell
"SQL01","SQL02" | Invoke-sqmMonitoringKey -Operation Set -SQL Full -TSM 1
#>
function Invoke-sqmMonitoringKey
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[Alias('Computer', 'Server')]
		[string[]]$ComputerName = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[ValidateSet('Get', 'Set')]
		[string]$Operation = 'Get',
		[Parameter(Mandatory = $false)]
		[ValidateSet('None', 'Standard', 'Full')]
		[string]$SQL,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Standard', 'Cluster')]
		[string]$SQLFreeSpaceVersion,
		[Parameter(Mandatory = $false)]
		[ValidateSet(0, 1)]
		[Nullable[int]]$TSM,
		[Parameter(Mandatory = $false)]
		[string]$RegistryBase = 'System',
		[Parameter(Mandatory = $false)]
		[switch]$AutoDetectSQLFreeSpaceVersion,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$regSubKey = "$RegistryBase\dtcSoftware\sqmSQLTool"
		$regPath = "HKLM:\$regSubKey"
		
		$sqlToDword = @{ 'None' = 0; 'Standard' = 1; 'Full' = 2 }
		$sqlDesc = @{ 0 = 'NoMonitoring'; 1 = 'ServiceMonitoring'; 2 = 'FullMonitoring' }
		$tsmDesc = @{ 0 = 'Inactive'; 1 = 'Active' }
		
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	}
	
	process
	{
		foreach ($computer in $ComputerName)
		{
			try
			{
				Invoke-sqmLogging -Message "[$computer] Operation: $Operation" -FunctionName $functionName -Level "INFO"
				
				$effectiveFreeSpaceVersion = $SQLFreeSpaceVersion
				
				# AutoDetect (nur bei Set)
				if ($Operation -eq 'Set' -and $AutoDetectSQLFreeSpaceVersion -and [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion))
				{
					Invoke-sqmLogging -Message "[$computer] AutoDetect SQLFreeSpaceVersion ..." -FunctionName $functionName -Level "INFO"
					try
					{
						if (-not (Get-Module -ListAvailable -Name dbatools))
						{
							Invoke-sqmLogging -Message "dbatools nicht gefunden - AutoDetect uebersprungen, verwende 'Standard'." -FunctionName $functionName -Level "WARNING"
							$effectiveFreeSpaceVersion = 'Standard'
						}
						else
						{
							$agCheck = Get-DbaAvailabilityGroup -SqlInstance $computer -ErrorAction SilentlyContinue
							$effectiveFreeSpaceVersion = if ($agCheck) { 'Cluster' }
							else { 'Standard' }
							Invoke-sqmLogging -Message "[$computer] AutoDetect Ergebnis: $effectiveFreeSpaceVersion" -FunctionName $functionName -Level "INFO"
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$computer] AutoDetect fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						$effectiveFreeSpaceVersion = 'Standard'
					}
				}
				
				# Schreibvorgang
				if ($Operation -eq 'Set')
				{
					if ([string]::IsNullOrWhiteSpace($SQL) -and [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion) -and $null -eq $TSM)
					{
						Invoke-sqmLogging -Message "[$computer] Keine Werte zum Setzen angegeben." -FunctionName $functionName -Level "WARNING"
						continue
					}
					
					if ($PSCmdlet.ShouldProcess($computer, "Setze Monitoring-Registry-Werte in '$regPath'"))
					{
						# Stelle sicher, dass der Schluessel existiert (lokal/remote)
						$keyExists = $false
						try
						{
							if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
							{
								$fullPath = "HKLM:\$regSubKey"
								if (-not (Test-Path $fullPath))
								{
									New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
									Invoke-sqmLogging -Message "[$computer] Registry-Schluessel erstellt: $fullPath" -FunctionName $functionName -Level "INFO"
								}
								$keyExists = $true
							}
							else
							{
								# Remote: Pruefe/Erstelle ueber Invoke-Command
								$sb = {
									param ($sk)
									$fullPath = "HKLM:\$sk"
									if (-not (Test-Path $fullPath))
									{
										New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
										Write-Output "CREATED"
									}
									else
									{
										Write-Output "EXISTS"
									}
								}
								$invokeParams = @{
									ComputerName = $computer
									ScriptBlock  = $sb
									ArgumentList = $regSubKey
									ErrorAction  = 'Stop'
								}
								if ($Credential) { $invokeParams['Credential'] = $Credential }
								$result = Invoke-Command @invokeParams
								if ($result -eq 'CREATED')
								{
									Invoke-sqmLogging -Message "[$computer] Registry-Schluessel remote erstellt: HKLM:\$regSubKey" -FunctionName $functionName -Level "INFO"
								}
								$keyExists = $true
							}
						}
						catch
						{
							Invoke-sqmLogging -Message "[$computer] Fehler bei Schluesselerstellung: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
							throw
						}
						
						# Nun Werte setzen
						$values = @{ }
						if (-not [string]::IsNullOrWhiteSpace($SQL)) { $values['SQL'] = $sqlToDword[$SQL] }
						if (-not [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion)) { $values['SQLFreeSpaceVersion'] = $effectiveFreeSpaceVersion }
						if ($null -ne $TSM) { $values['TSM'] = [int]$TSM }
						
						if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
						{
							$fullPath = "HKLM:\$regSubKey"
							foreach ($entry in $values.GetEnumerator())
							{
								$type = if ($entry.Value -is [int]) { 'DWord' }
								else { 'String' }
								Set-ItemProperty -Path $fullPath -Name $entry.Key -Value $entry.Value -Type $type -ErrorAction Stop
							}
						}
						else
						{
							$sb2 = {
								param ($sk,
									$vals)
								$fullPath = "HKLM:\$sk"
								foreach ($entry in $vals.GetEnumerator())
								{
									$type = if ($entry.Value -is [int]) { 'DWord' }
									else { 'String' }
									Set-ItemProperty -Path $fullPath -Name $entry.Key -Value $entry.Value -Type $type -ErrorAction Stop
								}
								return $true
							}
							$invokeParams2 = @{
								ComputerName = $computer
								ScriptBlock  = $sb2
								ArgumentList = $regSubKey, $values
								ErrorAction  = 'Stop'
							}
							if ($Credential) { $invokeParams2['Credential'] = $Credential }
							Invoke-Command @invokeParams2 | Out-Null
						}
						Invoke-sqmLogging -Message "[$computer] Werte erfolgreich gesetzt." -FunctionName $functionName -Level "INFO"
					}
					else
					{
						Invoke-sqmLogging -Message "[$computer] WhatIf: Schreibvorgang uebersprungen." -FunctionName $functionName -Level "VERBOSE"
					}
				}
				
				# Lesen (immer, auch nach Set)
				# Hier wird der Schluessel NICHT erstellt - nur lesen
				$current = $null
				try
				{
					if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
					{
						$fullPath = "HKLM:\$regSubKey"
						if (Test-Path $fullPath)
						{
							$key = Get-ItemProperty -Path $fullPath -ErrorAction Stop
							$current = @{
								SQL = $key.SQL
								SQLFreeSpaceVersion = $key.SQLFreeSpaceVersion
								TSM = $key.TSM
								_KeyExists = $true
							}
						}
						else
						{
							$current = @{ _KeyExists = $false }
						}
					}
					else
					{
						$sbRead = {
							param ($sk)
							$fullPath = "HKLM:\$sk"
							if (Test-Path $fullPath)
							{
								$key = Get-ItemProperty -Path $fullPath -ErrorAction Stop
								return @{
									SQL = $key.SQL
									SQLFreeSpaceVersion = $key.SQLFreeSpaceVersion
									TSM = $key.TSM
									_KeyExists = $true
								}
							}
							else
							{
								return @{ _KeyExists = $false }
							}
						}
						$invokeRead = @{
							ComputerName = $computer
							ScriptBlock  = $sbRead
							ArgumentList = $regSubKey
							ErrorAction  = 'Stop'
						}
						if ($Credential) { $invokeRead['Credential'] = $Credential }
						$current = Invoke-Command @invokeRead
					}
				}
				catch
				{
					throw "Registry-Lesen fehlgeschlagen: $($_.Exception.Message)"
				}
				
				$status = if ($Operation -eq 'Set') { if ($current._KeyExists) { 'Updated' }
					else { 'Created' } }
				elseif ($current._KeyExists) { 'OK' }
				else { 'KeyNotFound' }
				
				$sqlVal = $current.SQL
				$tsmVal = $current.TSM
				$fsvVal = $current.SQLFreeSpaceVersion
				$sqlText = if ($null -ne $sqlVal -and $sqlDesc.ContainsKey([int]$sqlVal)) { $sqlDesc[[int]$sqlVal] }
				else { '(nicht gesetzt)' }
				$tsmText = if ($null -ne $tsmVal -and $tsmDesc.ContainsKey([int]$tsmVal)) { $tsmDesc[[int]$tsmVal] }
				else { '(nicht gesetzt)' }
				
				$msg = switch ($status)
				{
					'KeyNotFound' { "Registry-Schluessel '$regPath' nicht vorhanden." }
					'Created'     { "Schluessel neu erstellt und Werte gesetzt." }
					'Updated'     { "Werte aktualisiert." }
					default       { "Werte erfolgreich ausgelesen." }
				}
				
				$allResults.Add([PSCustomObject]@{
						ComputerName = $computer
						RegistryPath = "HKLM:\$regSubKey"
						SQL		     = $sqlVal
						SQL_Description = $sqlText
						SQLFreeSpaceVersion = $fsvVal
						TSM		     = $tsmVal
						TSM_Description = $tsmText
						Status	     = $status
						Message	     = $msg
					})
			}
			catch
			{
				$errMsg = $_.Exception.Message
				Invoke-sqmLogging -Message "[$computer] Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						ComputerName = $computer
						RegistryPath = "HKLM:\$regSubKey"
						SQL		     = $null
						SQL_Description = '(Fehler)'
						SQLFreeSpaceVersion = $null
						TSM		     = $null
						TSM_Description = '(Fehler)'
						Status	     = 'Failed'
						Message	     = $errMsg
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 9. Database Maintenance

This section covers **5 functions** related to Database Maintenance.


## Find-sqmDatabaseObject

**Searches all (or selected) databases on an instance for an object name.**

### Description

Searches user databases for tables, views, procedures, functions, triggers, synonyms.
    Returns the location (database, schema, object type, name). Can filter by SQL text (full definition).

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -ObjectName | *object* | * | Name of the object to search for, or wildcard (e.g. '*customer*'). |
| -ObjectType | *object* | * | Restrict to type: 'TABLE', 'VIEW', 'PROCEDURE', 'FUNCTION', 'TRIGGER', 'SYNONYM'.     Multiple valu |
| -Database | *object* | * | Databases to search (wildcard, default: all user databases). |
| -IncludeSystem | *object* | * | Include system databases. Default: $false. |
| -SearchDefinition | *object* | * | If $true, the object text (definition) is also searched for <ObjectName> (slower). |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "sp_GetOrders"
\\\`n
**Example 2:**
\\\powershell
Find-sqmDatabaseObject -SqlInstance "SQL01" -ObjectName "*log*" -ObjectType "TABLE","VIEW" -Database "Sales*"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmLogShrink

**Shrinks the transaction log file (LDF) of one or more databases.**

### Description

Executes DBCC SHRINKFILE on the log file(s). Calculates the target size
    as a percentage of the current size (ShrinkTargetPercent) with a
    lower threshold (MinTargetMB). Handles Always On AGs (automatically
    redirects to the primary). System databases and offline databases are skipped.

    Important notes:
    - Shrink can only reduce to the oldest active VLF.
    - In FULL recovery model, a log backup beforehand is advisable.
    - Frequent shrinking fragments VLFs.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). For AG members,     automatically redirected  |
| -SqlCredential | *object* | * | Optional PSCredential for the connection. |
| -Database | *object* | * | Target database name(s) (wildcards allowed). Without specification, all     user databases are proc |
| -All | *object* | * | Processes all user databases (excl. system databases, online only).     Also used implicitly when n |
| -ShrinkTargetPercent | *object* | * | Target size as a percentage of the current log size (1-99). Default: 10. |
| -MinTargetMB | *object* | * | Minimum target size in MB (default: 64 MB). |
| -ContinueOnError | *object* | * | Continue with the next database on error. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |
| -Confirm | *object* | * | Request confirmation before shrinking. Disabled by default. |
| -WhatIf | *object* | * | Shows what would happen without executing the shrink. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmLogShrink -Database "MyDB" -ShrinkTargetPercent 20
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmLogShrink -SqlInstance "SQL01" -All -WhatIf
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmSetDatabaseRecoveryMode

**Changes the recovery mode of one or more user databases.**

### Description

Sets the recovery mode (Simple, Full, BulkLogged) for all or selected user databases
on a SQL Server instance. System databases are automatically excluded.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). If not specified, the current  |
| -SqlCredential | *object* | * | Alternative credentials (PSCredential). If not specified, Windows authentication is used. |
| -Database | *object* | * | Name or array of user databases whose recovery mode should be changed. Ignored when -All is set. |
| -All | *object* | * | When set, changes the recovery mode for all user databases. |
| -RecoveryMode | *object* | * | The desired recovery mode. Allowed values: Simple, Full, BulkLogged. |
| -EnableException | *object* | * | Switch to propagate exceptions immediately (by default errors are logged as warnings). |
| -Confirm | *object* | * | Prompts for confirmation before execution. Disabled by default. Passed through to Set-DbaDbRecovery |
| -WhatIf | *object* | * | Shows what would happen without actually making the change. Passed through to Set-DbaDbRecoveryMode |

### Examples

**Example 1:**
\\\powershell
# Set all user databases to Full (without prompting)
Invoke-sqmSetDatabaseRecoveryMode -All -RecoveryMode Full
\\\`n
**Example 2:**
\\\powershell
# With confirmation prompt (passed to Set-DbaDbRecoveryModel)
Invoke-sqmSetDatabaseRecoveryMode -Database "SalesDB" -RecoveryMode Simple -Confirm
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmUpdateStatistics

**Updates statistics in one or more databases.**

### Description

Executes UPDATE STATISTICS with configurable options (scan percentage, only modified statistics, etc.).
    Can be restricted to specific databases, tables, or statistics.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance (default: current computer name). |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Database | *object* | * | Database name or wildcard pattern. |
| -Table | *object* | * | Table name or wildcard pattern. |
| -Statistics | *object* | * | Statistic name or wildcard pattern. |
| -SamplePercent | *object* | * | Percentage of rows used for the update (0 = full scan). Default: 0. |
| -OnlyModified | *object* | * | Only update statistics that have changed since the last update. Default: $true. |
| -Index | *object* | * | Also update statistics associated with an index. Default: $true. |
| -WhatIf | *object* | * | Shows which statistics would be affected. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 10
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Set-sqmDatabaseOwner

**Sets the owner of one or more databases to a uniform login.**

### Description

Checks and corrects the database owner on one or more SQL Server instances.
    Typical use case: after restores or migrations the owner is often a login that no
    longer exists or is incorrect. The function uniformly sets it to the sa account
    (regardless of the actual sa name, which may have been renamed via obfuscation) or
    any other login.

    Process per database:
      1. Read current owner
      2. Check whether a change is necessary (already correct -> skip)
      3. Check whether the target login exists on the instance
      4. Execute ALTER AUTHORIZATION ON DATABASE::<Name> TO <Login>
      5. Log result

    Returns a status object for each database:
      Status = OK / Skipped / Failed / NotFound

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance(s). Pipeline-capable. Default: current computer name. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -Database | *object* | * | Database name(s). Wildcards allowed (e.g. 'Prod*'). Default: all user databases. |
| -ExcludeDatabase | *object* | * | Databases to exclude. Wildcards allowed. |
| -OwnerLogin | *object* | * | Login to set as the new owner.     Default: sa account (automatically determined via SID 0x01,     |
| -IncludeSystemDatabases | *object* | * | Also include system databases (master, model, msdb). Default: $false.     tempdb is always excluded |
| -Force | *object* | * | Also process databases that already have the correct owner (forces re-assignment). |
| -OutputPath | *object* | * | Directory for the change log. Default: from module configuration. |
| -ContinueOnError | *object* | * | Continue on error for one instance. Default: $false. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
# Set sa account on all user databases
    Set-sqmDatabaseOwner -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
# Specific databases with a custom login
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -Database "Prod*" -OwnerLogin "svc_sqlowner"
\\\`n
**Example 3:**
\\\powershell
# Pipeline across multiple instances
    'SQL01','SQL02' | Set-sqmDatabaseOwner
\\\`n
*Note: 1 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 22. Monitoring & Registry

This section covers **3 functions** related to Monitoring & Registry.


## Enable-sqmMonitoringAccess

**Richtet einen Monitoring-Account auf allen SQL Server-Instanzen eines Computers ein.**

### Description

Findet alle SQL Server-Instanzen auf dem Zielcomputer per Registry-Abfrage,
    verbindet sich mit jeder Instanz und richtet folgende Objekte ein:

    - Server-Rolle ($ServerRoleName) mit den notwendigen Server-Berechtigungen
    - Login ($MonitoringUser) als Windows-Login
    - Datenbank-Rolle ($DatabaseRoleName) in master und msdb
    - Datenbankbenutzer und Rollenzuordnung in master und msdb
    - Granulare GRANT-Berechtigungen auf System-Views und Stored Procedures

    Optional: Eine SQL Server Policy kann vor dem Setup deaktiviert und
    danach wieder aktiviert werden (-PolicyName).

    Ausgabe:
        MonitoringAccess_<computer>_<datum>.log  - Protokoll der ausgefuehrten Schritte

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Zielcomputer. Standard: aktueller Computer. |
| -MonitoringUser | *object* | * | Windows-Login des Monitoring-Accounts (z.B. "DOMAIN\MonUser"). |
| -ServerRoleName | *object* | * | Name der SQL Server-Rolle die angelegt wird. Standard: "MonitoringRole". |
| -DatabaseRoleName | *object* | * | Name der Datenbank-Rolle die in master und msdb angelegt wird.     Standard: "MonitoringDbRole". |
| -PolicyName | *object* | * | Name einer SQL Server Policy die vor dem Setup deaktiviert und danach     wieder aktiviert wird. Wir |
| -OutputPath | *object* | * | Ausgabeverzeichnis fuer das Log. Standard: C:\System\WinSrvLog\MSSQL |
| -SqlCredential | *object* | * | Optionales PSCredential fuer die SQL Server-Verbindung. |
| -ContinueOnError | *object* | * | Bei Fehler auf einer Instanz fortfahren statt abbrechen. |
| -EnableException | *object* | * | Fehler als terminierende Ausnahmen ausloesen. |

### Examples

**Example 1:**
\\\powershell
Enable-sqmMonitoringAccess -MonitoringUser "CORP\SvcMonitoring"
\\\`n
**Example 2:**
\\\powershell
Enable-sqmMonitoringAccess -ComputerName "SQL01" -MonitoringUser "CORP\SvcMonitoring" `
        -ServerRoleName "MonRole" -DatabaseRoleName "MonDbRole" `
        -PolicyName "Enforce Password Policy" -ContinueOnError
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmMonitoringKey

**Gets or sets monitoring registry values for the sqmSQLTool on one or more computers.**

### Description

Reads or writes the registry key HKLM:\<RegistryBase>\dtcSoftware\sqmSQLTool on
    the specified computers. The key controls which monitoring components are active:
    SQL monitoring level (None/Standard/Full), SQLFreeSpaceVersion (Standard/Cluster),
    and TSM backup monitoring (0/1).

    When -Operation is 'Set', the specified values are written to the registry.
    The key is created automatically if it does not exist.
    The current values are always read and returned after a write operation.

    Remote access uses Invoke-Command (WinRM). Provide -Credential for remote computers
    if required.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ComputerName | *object* | * | Target computer(s). Pipeline-capable. Default: current computer name. |
| -Operation | *object* | * | 'Get' (default) reads the current values; 'Set' writes the specified values. |
| -SQL | *object* | * | SQL monitoring level: 'None', 'Standard', or 'Full'.     Stored as DWORD (0/1/2) in the registry. |
| -SQLFreeSpaceVersion | *object* | * | Free-space monitoring variant: 'Standard' (standalone) or 'Cluster' (AlwaysOn AG). |
| -TSM | *object* | * | TSM backup monitoring: 0 = inactive, 1 = active. |
| -RegistryBase | *object* | * | Registry hive path base under HKLM. Default: 'System'. |
| -AutoDetectSQLFreeSpaceVersion | *object* | * | When set (and -Operation Set), automatically detects whether the instance belongs to     an AlwaysO |
| -Credential | *object* | * | PSCredential for remote computer access. |
| -ContinueOnError | *object* | * | Continue with the next computer on error. |
| -EnableException | *object* | * | Throw exceptions immediately (overrides ContinueOnError). |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmMonitoringKey
\\\`n
**Example 2:**
\\\powershell
Invoke-sqmMonitoringKey -Operation Set -SQL Standard -TSM 1 -AutoDetectSQLFreeSpaceVersion
\\\`n
**Example 3:**
\\\powershell
"SQL01","SQL02" | Invoke-sqmMonitoringKey -Operation Set -SQL Full -TSM 1
#>
function Invoke-sqmMonitoringKey
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[Alias('Computer', 'Server')]
		[string[]]$ComputerName = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[ValidateSet('Get', 'Set')]
		[string]$Operation = 'Get',
		[Parameter(Mandatory = $false)]
		[ValidateSet('None', 'Standard', 'Full')]
		[string]$SQL,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Standard', 'Cluster')]
		[string]$SQLFreeSpaceVersion,
		[Parameter(Mandatory = $false)]
		[ValidateSet(0, 1)]
		[Nullable[int]]$TSM,
		[Parameter(Mandatory = $false)]
		[string]$RegistryBase = 'System',
		[Parameter(Mandatory = $false)]
		[switch]$AutoDetectSQLFreeSpaceVersion,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$regSubKey = "$RegistryBase\dtcSoftware\sqmSQLTool"
		$regPath = "HKLM:\$regSubKey"
		
		$sqlToDword = @{ 'None' = 0; 'Standard' = 1; 'Full' = 2 }
		$sqlDesc = @{ 0 = 'NoMonitoring'; 1 = 'ServiceMonitoring'; 2 = 'FullMonitoring' }
		$tsmDesc = @{ 0 = 'Inactive'; 1 = 'Active' }
		
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	}
	
	process
	{
		foreach ($computer in $ComputerName)
		{
			try
			{
				Invoke-sqmLogging -Message "[$computer] Operation: $Operation" -FunctionName $functionName -Level "INFO"
				
				$effectiveFreeSpaceVersion = $SQLFreeSpaceVersion
				
				# AutoDetect (nur bei Set)
				if ($Operation -eq 'Set' -and $AutoDetectSQLFreeSpaceVersion -and [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion))
				{
					Invoke-sqmLogging -Message "[$computer] AutoDetect SQLFreeSpaceVersion ..." -FunctionName $functionName -Level "INFO"
					try
					{
						if (-not (Get-Module -ListAvailable -Name dbatools))
						{
							Invoke-sqmLogging -Message "dbatools nicht gefunden - AutoDetect uebersprungen, verwende 'Standard'." -FunctionName $functionName -Level "WARNING"
							$effectiveFreeSpaceVersion = 'Standard'
						}
						else
						{
							$agCheck = Get-DbaAvailabilityGroup -SqlInstance $computer -ErrorAction SilentlyContinue
							$effectiveFreeSpaceVersion = if ($agCheck) { 'Cluster' }
							else { 'Standard' }
							Invoke-sqmLogging -Message "[$computer] AutoDetect Ergebnis: $effectiveFreeSpaceVersion" -FunctionName $functionName -Level "INFO"
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$computer] AutoDetect fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						$effectiveFreeSpaceVersion = 'Standard'
					}
				}
				
				# Schreibvorgang
				if ($Operation -eq 'Set')
				{
					if ([string]::IsNullOrWhiteSpace($SQL) -and [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion) -and $null -eq $TSM)
					{
						Invoke-sqmLogging -Message "[$computer] Keine Werte zum Setzen angegeben." -FunctionName $functionName -Level "WARNING"
						continue
					}
					
					if ($PSCmdlet.ShouldProcess($computer, "Setze Monitoring-Registry-Werte in '$regPath'"))
					{
						# Stelle sicher, dass der Schluessel existiert (lokal/remote)
						$keyExists = $false
						try
						{
							if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
							{
								$fullPath = "HKLM:\$regSubKey"
								if (-not (Test-Path $fullPath))
								{
									New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
									Invoke-sqmLogging -Message "[$computer] Registry-Schluessel erstellt: $fullPath" -FunctionName $functionName -Level "INFO"
								}
								$keyExists = $true
							}
							else
							{
								# Remote: Pruefe/Erstelle ueber Invoke-Command
								$sb = {
									param ($sk)
									$fullPath = "HKLM:\$sk"
									if (-not (Test-Path $fullPath))
									{
										New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
										Write-Output "CREATED"
									}
									else
									{
										Write-Output "EXISTS"
									}
								}
								$invokeParams = @{
									ComputerName = $computer
									ScriptBlock  = $sb
									ArgumentList = $regSubKey
									ErrorAction  = 'Stop'
								}
								if ($Credential) { $invokeParams['Credential'] = $Credential }
								$result = Invoke-Command @invokeParams
								if ($result -eq 'CREATED')
								{
									Invoke-sqmLogging -Message "[$computer] Registry-Schluessel remote erstellt: HKLM:\$regSubKey" -FunctionName $functionName -Level "INFO"
								}
								$keyExists = $true
							}
						}
						catch
						{
							Invoke-sqmLogging -Message "[$computer] Fehler bei Schluesselerstellung: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
							throw
						}
						
						# Nun Werte setzen
						$values = @{ }
						if (-not [string]::IsNullOrWhiteSpace($SQL)) { $values['SQL'] = $sqlToDword[$SQL] }
						if (-not [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion)) { $values['SQLFreeSpaceVersion'] = $effectiveFreeSpaceVersion }
						if ($null -ne $TSM) { $values['TSM'] = [int]$TSM }
						
						if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
						{
							$fullPath = "HKLM:\$regSubKey"
							foreach ($entry in $values.GetEnumerator())
							{
								$type = if ($entry.Value -is [int]) { 'DWord' }
								else { 'String' }
								Set-ItemProperty -Path $fullPath -Name $entry.Key -Value $entry.Value -Type $type -ErrorAction Stop
							}
						}
						else
						{
							$sb2 = {
								param ($sk,
									$vals)
								$fullPath = "HKLM:\$sk"
								foreach ($entry in $vals.GetEnumerator())
								{
									$type = if ($entry.Value -is [int]) { 'DWord' }
									else { 'String' }
									Set-ItemProperty -Path $fullPath -Name $entry.Key -Value $entry.Value -Type $type -ErrorAction Stop
								}
								return $true
							}
							$invokeParams2 = @{
								ComputerName = $computer
								ScriptBlock  = $sb2
								ArgumentList = $regSubKey, $values
								ErrorAction  = 'Stop'
							}
							if ($Credential) { $invokeParams2['Credential'] = $Credential }
							Invoke-Command @invokeParams2 | Out-Null
						}
						Invoke-sqmLogging -Message "[$computer] Werte erfolgreich gesetzt." -FunctionName $functionName -Level "INFO"
					}
					else
					{
						Invoke-sqmLogging -Message "[$computer] WhatIf: Schreibvorgang uebersprungen." -FunctionName $functionName -Level "VERBOSE"
					}
				}
				
				# Lesen (immer, auch nach Set)
				# Hier wird der Schluessel NICHT erstellt - nur lesen
				$current = $null
				try
				{
					if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
					{
						$fullPath = "HKLM:\$regSubKey"
						if (Test-Path $fullPath)
						{
							$key = Get-ItemProperty -Path $fullPath -ErrorAction Stop
							$current = @{
								SQL = $key.SQL
								SQLFreeSpaceVersion = $key.SQLFreeSpaceVersion
								TSM = $key.TSM
								_KeyExists = $true
							}
						}
						else
						{
							$current = @{ _KeyExists = $false }
						}
					}
					else
					{
						$sbRead = {
							param ($sk)
							$fullPath = "HKLM:\$sk"
							if (Test-Path $fullPath)
							{
								$key = Get-ItemProperty -Path $fullPath -ErrorAction Stop
								return @{
									SQL = $key.SQL
									SQLFreeSpaceVersion = $key.SQLFreeSpaceVersion
									TSM = $key.TSM
									_KeyExists = $true
								}
							}
							else
							{
								return @{ _KeyExists = $false }
							}
						}
						$invokeRead = @{
							ComputerName = $computer
							ScriptBlock  = $sbRead
							ArgumentList = $regSubKey
							ErrorAction  = 'Stop'
						}
						if ($Credential) { $invokeRead['Credential'] = $Credential }
						$current = Invoke-Command @invokeRead
					}
				}
				catch
				{
					throw "Registry-Lesen fehlgeschlagen: $($_.Exception.Message)"
				}
				
				$status = if ($Operation -eq 'Set') { if ($current._KeyExists) { 'Updated' }
					else { 'Created' } }
				elseif ($current._KeyExists) { 'OK' }
				else { 'KeyNotFound' }
				
				$sqlVal = $current.SQL
				$tsmVal = $current.TSM
				$fsvVal = $current.SQLFreeSpaceVersion
				$sqlText = if ($null -ne $sqlVal -and $sqlDesc.ContainsKey([int]$sqlVal)) { $sqlDesc[[int]$sqlVal] }
				else { '(nicht gesetzt)' }
				$tsmText = if ($null -ne $tsmVal -and $tsmDesc.ContainsKey([int]$tsmVal)) { $tsmDesc[[int]$tsmVal] }
				else { '(nicht gesetzt)' }
				
				$msg = switch ($status)
				{
					'KeyNotFound' { "Registry-Schluessel '$regPath' nicht vorhanden." }
					'Created'     { "Schluessel neu erstellt und Werte gesetzt." }
					'Updated'     { "Werte aktualisiert." }
					default       { "Werte erfolgreich ausgelesen." }
				}
				
				$allResults.Add([PSCustomObject]@{
						ComputerName = $computer
						RegistryPath = "HKLM:\$regSubKey"
						SQL		     = $sqlVal
						SQL_Description = $sqlText
						SQLFreeSpaceVersion = $fsvVal
						TSM		     = $tsmVal
						TSM_Description = $tsmText
						Status	     = $status
						Message	     = $msg
					})
			}
			catch
			{
				$errMsg = $_.Exception.Message
				Invoke-sqmLogging -Message "[$computer] Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						ComputerName = $computer
						RegistryPath = "HKLM:\$regSubKey"
						SQL		     = $null
						SQL_Description = '(Fehler)'
						SQLFreeSpaceVersion = $null
						TSM		     = $null
						TSM_Description = '(Fehler)'
						Status	     = 'Failed'
						Message	     = $errMsg
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmPatchAnalysis

**Compares the installed SQL Server version with known CU/SP builds.**

### Description

Reads the installed SQL Server version (ProductVersion) and compares it
    against an embedded reference table of known builds. Indicates whether the
    instance is current, how many builds it lags behind the latest, and provides
    a patch recommendation.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | One or more SQL Server instances. Default: local computer name.     Pipeline-capable. |
| -SqlCredential | *object* | * | PSCredential for the connection. |
| -OutputPath | *object* | * | If specified, a CSV report is saved. |
| -EnableException | *object* | * | Throw exceptions immediately. |

### Examples

**Example 1:**
\\\powershell
Invoke-sqmPatchAnalysis -SqlInstance "SQL01"
\\\`n
**Example 2:**
\\\powershell
"SQL01","SQL02","SQL03" | Invoke-sqmPatchAnalysis
\\\`n
**Example 3:**
\\\powershell
Invoke-sqmPatchAnalysis -SqlInstance "SQL01","SQL02" -OutputPath "D:\Reports"
\\\`n
### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

# 20. Script Execution & Deployment

This section covers **3 functions** related to Script Execution & Deployment.


## Invoke-sqmDeployScripts

**Executes numbered SQL scripts from a directory sequentially against a SQL Server database.**

### Description

Runs all SQL script files whose filename starts with a numeric prefix (e.g. 001_CreateTable.sql)
    in ascending numeric order against the specified database. Before execution the function:

    - Validates that ScriptPath and LogPath exist (LogPath is created if missing)
    - Optionally creates a full database backup in a Sonderbackup subdirectory
    - Scans every script for USE DATABASE mismatches and nested BEGIN TRANSACTION statements
    - Wraps all scripts in one outer transaction by default (COMMIT on full success, ROLLBACK on any error)
    - Writes a detailed .log and .csv file to LogPath
    - Returns a result object per script plus an overall summary object

    When -WhatIf is specified the function performs all pre-checks and prints a summary table
    but does not execute any SQL or create any files.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -SqlInstance | *object* | * | SQL Server instance name (e.g. "SQLSERVER01" or "SQLSERVER01\INST1"). |
| -Database | *object* | * | Target database name. |
| -ScriptPath | *object* | * | Directory that contains the numbered SQL script files. |
| -LogPath | *object* | * | Directory where the .log and .csv output files are written. Created if it does not exist. |
| -JobNumber | *object* | * | Optional job or order number. When provided it is embedded in the log filename:     yyyyMMdd_HHmmss_ |
| -QueryTimeout | *object* | * | Timeout in seconds per script execution. Default: 30. |
| -SkipBackup | *object* | * | Skip the pre-deployment backup. Requires ShouldProcess confirmation (ConfirmImpact=High).     If the |
| -NoWrapTransaction | *object* | * | Do not wrap all scripts in one outer transaction. Each script is responsible for its own     transac |
| -SqlCredential | *object* | * | PSCredential for SQL Server authentication. When omitted Windows Authentication is used. |

### Examples

**Example 1:**
\\\powershell
# Basic deploy with automatic backup
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy"
\\\`n
**Example 2:**
\\\powershell
# Deploy with job number embedded in log filename
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -JobNumber "AU-2026-042"
\\\`n
**Example 3:**
\\\powershell
# Skip backup - requires interactive confirmation
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -SkipBackup
\\\`n
*Note: 3 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Invoke-sqmSignModule

**Signs all PowerShell script files in a module directory using Set-AuthenticodeSignature.**

### Description

Signs .ps1, .psm1, and .psd1 files (configurable) under a module root directory recursively.
    Works with any code signing certificate: commercial OV cert, self-signed cert, or a
    SignPath-exported PFX file. Designed to be run before each GitHub release.

    Certificate resolution order:
      1. PFX file path  (-CertificatePath)
      2. Thumbprint      (-CertificateThumbprint) - searched in LocalMachine\My, then CurrentUser\My
      3. Auto-detect     - first valid, non-expired code signing cert in both stores

    Each file is checked for an existing signature before signing. Files with a valid
    signature are skipped unless -Force is specified. Files with an invalid or expired
    signature are always re-signed.

    On timestamp server failure the function automatically retries with a fallback TSA.

    Results are returned as a list of PSCustomObjects and copied to the clipboard.

### Parameters

| Name | Type | Required | Description |
|------|------|----------|-------------|
| -ModulePath | *object* | * | Path to the module root directory. All matching files are signed recursively.     If omitted, the pa |
| -CertificateThumbprint | *object* | * | Thumbprint of a certificate in Cert:\LocalMachine\My or Cert:\CurrentUser\My.     If omitted and -Ce |
| -CertificatePath | *object* | * | Path to a .pfx file. Takes precedence over -CertificateThumbprint. |
| -CertificatePassword | *object* | * | SecureString password for the PFX file specified in -CertificatePath. |
| -TimestampServer | *object* | * | URL of the timestamp authority (TSA). Default: http://timestamp.digicert.com.     On failure the fun |
| -IncludeExtensions | *object* | * | File extensions to sign. Default: @('.ps1', '.psm1', '.psd1'). |
| -Force | *object* | * | Re-signs files that already carry a valid signature. Without -Force those files     are skipped. |

### Examples

**Example 1:**
\\\powershell
# 1. Sign with a specific certificate from the store
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" `
        -CertificateThumbprint "AB12CD34EF56..."
\\\`n
**Example 2:**
\\\powershell
# 2. Sign with a PFX file
    $pwd = ConvertTo-SecureString "secret" -AsPlainText -Force
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" `
        -CertificatePath "C:\Certs\CodeSign.pfx" -CertificatePassword $pwd
\\\`n
**Example 3:**
\\\powershell
# 3. Auto-detect certificate (no parameters needed if cert is in store)
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule"
\\\`n
*Note: 2 more examples available in function help*

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

## Copy-sqmToCentralPath

**Copies one or more files to the configured CentralPath.**

### Description

If no CentralPath is configured, the function exits without error.
    Source files that do not exist are skipped.

### Best Practices

- Consult SQL Server documentation for related DMVs and configuration options
- Test in development environment first
- Review results carefully before applying to production

---

---

# Appendix

## A. Configuration Reference

Use \Get-sqmConfig\ to review and \Set-sqmConfig\ to modify:

\\\powershell
Get-sqmConfig
Get-sqmConfig -Property "LogPath"
Set-sqmConfig -LogPath "C:\Logs\sqmSQLTool"
\\\

## B. Common Patterns

### Working with Multiple Instances

\\\powershell
# Check multiple instances
"SQL01", "SQL02", "SQL03" | ForEach-Object {
    Get-sqmAlwaysOnHealthReport -SqlInstance \
}
\\\

### Exporting Reports

\\\powershell
Get-sqmDiskSpaceReport -SqlInstance "SQL01" | Export-Csv "C:\reports\disk_space.csv"
Get-sqmSysadminAccounts -SqlInstance "SQL01" | ConvertTo-Html | Out-File "C:\reports\admins.html"
\\\

### Error Handling

\\\powershell
try {
    Get-sqmAlwaysOnHealthReport -SqlInstance "SQL01" -ErrorAction Stop
} catch {
    Write-Error "Failed to get AG health: \"
}
\\\

## C. Integration with Other Tools

- **dbatools** - sqmSQLTool uses dbatools for core SQL Server connectivity
- **Active Directory** - Use Get-sqmADGroupMembers for AD integration
- **Splunk** - Use Invoke-sqmSplunkConfiguration for monitoring integration
- **SQL Agent** - Use New-sqmAgentProxy and job creation functions

## D. Support & Updates

- **Check for updates:** Test-sqmModuleUpdate, Update-sqmModule
- **Module location:** C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool
- **GitHub:** https://github.com/JankeUwe/sqmSQLTool
- **Documentation:** See \Get-Help FunctionName -Full\

---

**End of Manual**

