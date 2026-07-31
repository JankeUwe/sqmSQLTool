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
# Uebersetzt einen Kompatibilitaetsgrad (sys.databases.compatibility_level) in die SQL Server-
# Version, fuer die er steht. Die nackte Zahl steht zwar in jedem Bericht, sagt aber nur denen
# etwas, die die Tabelle auswendig koennen - und genau dieser Wert entscheidet, welches Verhalten
# und welcher Abfrageoptimierer fuer die Datenbank tatsaechlich gelten.
function _ConvertTo-SqlVersionName
{
    param([int]$CompatibilityLevel)

    $map = @{
        170 = '2025'; 160 = '2022'; 150 = '2019'; 140 = '2017'; 130 = '2016'
        120 = '2014'; 110 = '2012'; 100 = '2008'; 90 = '2005'; 80 = '2000'
    }
    if ($CompatibilityLevel -le 0) { return 'unbekannt' }
    if ($map.ContainsKey($CompatibilityLevel)) { return "$($map[$CompatibilityLevel]) ($CompatibilityLevel)" }
    return "unbekannt ($CompatibilityLevel)"
}

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

            # Backup-Status aus der TATSAECHLICHEN Sicherungshistorie, nicht aus Jobnamen.
            #
            # Vorher wurden ausschliesslich SQL Agent-Jobs gezaehlt, deren Name 'backup' oder 'bkp'
            # enthaelt. Wird ueber ein externes Werkzeug gesichert (TDP/TSM, Netzwerk-Backupserver,
            # zentraler Scheduler), gibt es solche Jobs nicht - der Bericht meldete dann
            # "NO BACKUP JOBS", obwohl jede Nacht sauber gesichert wurde. msdb.dbo.backupset
            # enthaelt dagegen JEDE Sicherung, unabhaengig davon, wer sie ausgeloest hat, auch die
            # ueber Virtual Device Interface laufenden Sicherungen von TDP/TSM.
            $backupJobStatus = 'Nicht ermittelbar'
            $backupStatusColor = 'orange'
            $backupDetails = @()
            try
            {
                $backupRows = @(Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT d.name                                                            AS DatabaseName,
       d.recovery_model_desc                                             AS RecoveryModel,
       MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END)         AS LastFull,
       MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END)         AS LastLog
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b
       ON b.database_name = d.name
      AND b.is_copy_only = 0
WHERE d.database_id <> 2          -- tempdb wird nie gesichert
  AND d.state = 0                 -- nur ONLINE
  AND d.is_read_only = 0
GROUP BY d.name, d.recovery_model_desc
"@)

                $totalDbs = $backupRows.Count
                $neverBackedUp = @($backupRows | Where-Object { -not $_.LastFull -or $_.LastFull -is [System.DBNull] })
                $staleBackups = @($backupRows | Where-Object {
                        $_.LastFull -and $_.LastFull -isnot [System.DBNull] -and
                        (New-TimeSpan -Start $_.LastFull -End (Get-Date)).TotalDays -gt 7
                    })

                if ($totalDbs -eq 0)
                {
                    $backupJobStatus = 'Keine zu sichernden Datenbanken'
                    $backupStatusColor = 'green'
                }
                elseif ($neverBackedUp.Count -gt 0)
                {
                    $backupJobStatus = "CRITICAL ($($neverBackedUp.Count) von $totalDbs ohne Vollsicherung)"
                    $backupStatusColor = 'red'
                    $backupDetails += "Ohne Vollsicherung: $(($neverBackedUp | Select-Object -ExpandProperty DatabaseName) -join ', ')"
                }
                elseif ($staleBackups.Count -gt 0)
                {
                    $backupJobStatus = "WARNING ($($staleBackups.Count) von $totalDbs aelter als 7 Tage)"
                    $backupStatusColor = 'orange'
                    $backupDetails += "Aelter als 7 Tage: $(($staleBackups | Select-Object -ExpandProperty DatabaseName) -join ', ')"
                }
                else
                {
                    $oldest = ($backupRows | Measure-Object -Property LastFull -Minimum).Minimum
                    $oldestDays = if ($oldest) { [math]::Floor((New-TimeSpan -Start $oldest -End (Get-Date)).TotalDays) } else { 0 }
                    $backupJobStatus = "OK ($totalDbs von $totalDbs gesichert, aelteste $oldestDays Tag(e))"
                    $backupStatusColor = 'green'
                }
            }
            catch
            {
                # Nicht als "keine Backups" durchgehen lassen - unbekannt ist unbekannt.
                $backupJobStatus = 'Nicht ermittelbar'
                $backupStatusColor = 'orange'
                $backupDetails += "Sicherungshistorie nicht lesbar: $($_.Exception.Message)"
            }

            # Agent-Jobs nur noch als Zusatzinformation, nicht mehr als Bewertungsgrundlage.
            try
            {
                $backupJobs = @(Get-DbaAgentJob -SqlInstance $server -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*backup*' -or $_.Name -like '*bkp*' -or $_.Name -like '*sicherung*' })
                if ($backupJobs.Count -gt 0)
                {
                    $enabledJobs = @($backupJobs | Where-Object { $_.IsEnabled }).Count
                    $backupDetails += "Agent-Jobs mit Backup-Bezug: $($backupJobs.Count) ($enabledJobs aktiv)"
                }
                else
                {
                    $backupDetails += 'Keine Agent-Jobs mit Backup-Bezug (bei externer Sicherung normal)'
                }
            }
            catch { }

            # Max Memory (synchronized with Test-sqmMaxMemory logic)
            # WICHTIG: sowohl max server memory (ConfigValue) als auch SMO Server.PhysicalMemory
            # sind in MB. Frueher wurde PhysicalMemory faelschlich durch 1024 geteilt (= GB),
            # wodurch jeder konfigurierte Wert als "TOO HIGH" erschien.
            $maxMem = $server.Configuration.MaxServerMemory.ConfigValue
            $totalMem = [int]$server.PhysicalMemory
            if (-not $totalMem -or $totalMem -le 0)
            {
                try { $totalMem = [math]::Round((Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB) } catch { }
            }
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
            # Robuste Ermittlung ueber die Rollenmitgliedschaft (Get-DbaLogin hat keine
            # zuverlaessige IsSysAdmin-Eigenschaft -> Liste blieb sonst leer).
            # sys.server_principals.sid liefert zugleich die SID fuer die BUILTIN-Erkennung.
            $sysadminLogins = @()
            try
            {
                $sysadminQuery = @"
SELECT sp.name AS Name, sp.sid AS Sid
FROM sys.server_role_members rm
JOIN sys.server_principals r  ON rm.role_principal_id   = r.principal_id
JOIN sys.server_principals sp ON rm.member_principal_id = sp.principal_id
WHERE r.type = 'R' AND r.name = N'sysadmin'
ORDER BY sp.name
"@
                $sysadminLogins = @(Invoke-DbaQuery -SqlInstance $server -Query $sysadminQuery -ErrorAction Stop)
            }
            catch
            {
                # Fallback: dbatools-Rollenmitglieder (ohne SID -> nur Namensabgleich)
                try
                {
                    $sysadminLogins = @(Get-DbaServerRoleMember -SqlInstance $server -ServerRole 'sysadmin' -ErrorAction Stop |
                        ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Sid = $null } })
                }
                catch { }
            }
            $sysadmins = @($sysadminLogins | Select-Object -ExpandProperty Name | Where-Object { $_ })

            # Warnung: BUILTIN\Administrators (lokalisiert z.B. VORDEFINIERT\Administratoren) als sysadmin
            # ist ein Least-Privilege-Verstoss (jeder lokale Admin wird damit zum SQL-sysadmin).
            # Erkennung primaer ueber die Well-Known-SID S-1-5-32-544 (sprachunabhaengig),
            # Fallback ueber den Namen.
            $builtinAdmins = @()
            foreach ($sa in $sysadminLogins)
            {
                $isBuiltin = $false
                try
                {
                    if ($sa.Sid)
                    {
                        $sidStr = (New-Object System.Security.Principal.SecurityIdentifier(([byte[]]$sa.Sid), 0)).Value
                        if ($sidStr -eq 'S-1-5-32-544') { $isBuiltin = $true }
                    }
                }
                catch { }
                if (-not $isBuiltin -and $sa.Name -match '^(BUILTIN|VORDEFINIERT|INTEGR)\\.*Admin') { $isBuiltin = $true }
                if ($isBuiltin) { $builtinAdmins += $sa.Name }
            }
            $builtinAdmins   = @($builtinAdmins | Select-Object -Unique)
            $hasBuiltinAdmins = $builtinAdmins.Count -gt 0
            $sysadminColor   = if ($hasBuiltinAdmins) { 'red' } else { '' }
            $sysadminWarning = if ($hasBuiltinAdmins) { "WARNUNG: $($builtinAdmins -join ', ') hat sysadmin-Rechte - fuer Least Privilege entfernen" } else { '' }

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
            if ($advancedLogins.Count -eq 0) { $advancedLogins = @('None with server roles') }

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

            # Dienstkonten aus sys.dm_server_services, also von der TATSAECHLICH berichteten Instanz.
            #
            # Vorher lief das ueber Get-Service/Win32_Service OHNE -ComputerName. Beides fragt damit
            # den Rechner ab, auf dem das Skript laeuft - bei einem Bericht ueber eine entfernte
            # Instanz wurde also das Dienstkonto des LOKALEN Rechners ausgewiesen. Auf einem Host mit
            # mehreren Instanzen kam durch "Select-Object -First 1" zusaetzlich eine beliebige davon
            # heraus. Die DMV liefert genau die Dienste der verbundenen Instanz, ohne WinRM.
            $serviceAccounts = @()
            try
            {
                $svcRows = @(Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT servicename, service_account, status_desc, startup_type_desc
FROM sys.dm_server_services
"@)
                foreach ($svc in $svcRows)
                {
                    $serviceAccounts += "$($svc.servicename): $($svc.service_account) [$($svc.status_desc), Start: $($svc.startup_type_desc)]"
                }
            }
            catch
            {
                $serviceAccounts += "Dienstkonten nicht ermittelbar (sys.dm_server_services): $($_.Exception.Message)"
            }
            if ($serviceAccounts.Count -eq 0) { $serviceAccounts = @('Unable to determine') }

            # ==========================================
            # SERVERFAKTEN UND INSTALLIERTE KOMPONENTEN
            # ==========================================
            # Alles, was ueber die SQL-Verbindung geht, wird auch darueber geholt: das funktioniert
            # unabhaengig von WinRM und trifft garantiert die berichtete Instanz. Nur was es
            # SQL-seitig nicht gibt (SSAS/SSRS/SSIS als Hostdienste, Registry), braucht WinRM - und
            # schlaegt das fehl, steht dort "nicht ermittelbar" statt "nicht installiert".
            $hostName = if ($server.ComputerNamePhysicalNetBIOS) { $server.ComputerNamePhysicalNetBIOS } else { ($SqlInstance -split '[\\,]')[0] }

            $serverFacts = @()
            $instanceCompat = 0
            try
            {
                $facts = Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT CONVERT(nvarchar(128), SERVERPROPERTY('Collation'))       AS Collation,
       CONVERT(int, SERVERPROPERTY('IsFullTextInstalled'))       AS IsFullTextInstalled,
       CONVERT(nvarchar(128), SERVERPROPERTY('Edition'))         AS Edition,
       CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'))  AS ProductVersion,
       si.cpu_count                                              AS CpuCount,
       si.hyperthread_ratio                                      AS HyperthreadRatio,
       si.scheduler_count                                        AS SchedulerCount,
       CONVERT(bigint, si.physical_memory_kb)                    AS PhysicalMemoryKb,
       (SELECT compatibility_level FROM sys.databases WHERE name = 'model') AS InstanceCompat
FROM sys.dm_os_sys_info si
"@
                $instanceCompat = [int]$facts.InstanceCompat
                $ramGb = [math]::Round([int64]$facts.PhysicalMemoryKb / 1024 / 1024, 1)
                # hyperthread_ratio ist die Zahl der logischen Prozessoren JE physischem Paket,
                # nicht das Hyperthreading-Verhaeltnis im umgangssprachlichen Sinn. cpu_count
                # geteilt durch diesen Wert ergibt daher die Zahl der SOCKEL, nicht die der Kerne.
                $sockets = if ([int]$facts.HyperthreadRatio -gt 0) { [int]$facts.CpuCount / [int]$facts.HyperthreadRatio } else { $null }

                $serverFacts += "Collation: $($facts.Collation)"
                $serverFacts += "Edition: $($facts.Edition) ($($facts.ProductVersion))"
                $serverFacts += "Datenbank-Modus der Instanz: $(_ConvertTo-SqlVersionName $instanceCompat) - Standard fuer neu angelegte Datenbanken"
                $serverFacts += "CPU: $($facts.CpuCount) logische Prozessoren$(if ($sockets) { " auf $sockets Sockel" }), $($facts.SchedulerCount) Scheduler"
                $serverFacts += "OS-RAM: $ramGb GB"
            }
            catch
            {
                $serverFacts += "Serverfakten nicht ermittelbar: $($_.Exception.Message)"
            }

            # ---- Installierte Komponenten ----
            $featureList = @()

            # Volltextsuche: rein SQL-seitig feststellbar, daher immer belastbar.
            try
            {
                $ftInstalled = [int](Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException `
                        -Query "SELECT CONVERT(int, SERVERPROPERTY('IsFullTextInstalled')) AS FT").FT
                $featureList += "Volltextsuche: $(if ($ftInstalled -eq 1) { 'installiert' } else { 'nicht installiert' })"
            }
            catch { $featureList += 'Volltextsuche: nicht ermittelbar' }

            # SSIS/SSAS/SSRS sind Hostdienste, nicht Teil der Instanz - primaer ueber die Dienste
            # des Zielrechners, das braucht WinRM.
            $hostServices = $null
            try { $hostServices = @(Get-DbaService -ComputerName $hostName -ErrorAction Stop) } catch { $hostServices = $null }

            if ($hostServices)
            {
                foreach ($feature in @(
                        @{ Label = 'Integration Services (SSIS)'; Type = 'SSIS' },
                        @{ Label = 'Analysis Services (SSAS)'; Type = 'SSAS' },
                        @{ Label = 'Reporting Services (SSRS)'; Type = 'SSRS' }))
                {
                    $match = @($hostServices | Where-Object { $_.ServiceType -eq $feature.Type })
                    if ($match.Count -gt 0)
                    {
                        $featureList += "$($feature.Label): installiert ($(($match | ForEach-Object { $_.State }) -join ', '))"
                    }
                    else
                    {
                        $featureList += "$($feature.Label): nicht installiert"
                    }
                }
            }
            else
            {
                # Kein WinRM: nur SQL-seitige Indizien, und die werden auch als solche benannt.
                try
                {
                    $catalogs = @(Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT name FROM sys.databases WHERE name IN ('SSISDB', 'ReportServer', 'ReportServerTempDB')
"@ | Select-Object -ExpandProperty name)

                    $featureList += "Integration Services (SSIS): $(if ($catalogs -contains 'SSISDB') { 'SSISDB-Katalog auf dieser Instanz vorhanden' } else { 'nicht ermittelbar (kein WinRM, kein SSISDB-Katalog)' })"
                    $featureList += "Reporting Services (SSRS): $(if ($catalogs -contains 'ReportServer') { 'ReportServer-Datenbank auf dieser Instanz vorhanden' } else { 'nicht ermittelbar (kein WinRM, keine ReportServer-Datenbank)' })"
                }
                catch
                {
                    $featureList += 'Integration Services (SSIS): nicht ermittelbar'
                    $featureList += 'Reporting Services (SSRS): nicht ermittelbar'
                }
                $featureList += 'Analysis Services (SSAS): nicht ermittelbar (nur ueber die Dienste des Rechners feststellbar, WinRM zu ' + $hostName + ' nicht moeglich)'
            }

            # ==========================================
            # CLUSTER UND HOCHVERFUEGBARKEIT
            # ==========================================
            # Vollstaendig ueber die SQL-Verbindung: Failover-Cluster-Knoten, WSFC-Mitglieder,
            # Availability Groups mit allen Replikaten und Listenern. Kein WinRM noetig, und die
            # Angaben stammen garantiert von der berichteten Instanz.
            $clusterList = @()
            try
            {
                $ha = Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT CONVERT(int, SERVERPROPERTY('IsClustered'))                          AS IsClustered,
       CONVERT(int, ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0))             AS IsHadrEnabled,
       CONVERT(nvarchar(128), SERVERPROPERTY('MachineName'))                AS MachineName,
       CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS')) AS PhysicalNode
"@
                $isClustered = [int]$ha.IsClustered -eq 1
                $isHadr = [int]$ha.IsHadrEnabled -eq 1

                $clusterList += "Failover Cluster (FCI): $(if ($isClustered) { "ja - virtueller Name '$($ha.MachineName)', aktiver Knoten '$($ha.PhysicalNode)'" } else { 'nein (Einzelinstanz)' })"

                if ($isClustered)
                {
                    try
                    {
                        $nodes = @(Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException `
                                -Query "SELECT NodeName, status_description FROM sys.dm_os_cluster_nodes ORDER BY NodeName")
                        $clusterList += "FCI-Knoten ($($nodes.Count)): $(($nodes | ForEach-Object { "$($_.NodeName) [$($_.status_description)]" }) -join ', ')"
                    }
                    catch { $clusterList += 'FCI-Knoten: nicht lesbar' }
                }

                $clusterList += "AlwaysOn Availability Groups: $(if ($isHadr) { 'aktiviert' } else { 'nicht aktiviert' })"

                if ($isHadr)
                {
                    # WSFC-Ebene: Clustername, Quorum und ALLE Mitglieder - auch die Knoten, auf
                    # denen diese Instanz gar nicht laeuft.
                    try
                    {
                        $wsfc = Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException `
                            -Query "SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_hadr_cluster"
                        if ($wsfc) { $clusterList += "WSFC: '$($wsfc.cluster_name)', Quorum $($wsfc.quorum_type_desc) ($($wsfc.quorum_state_desc))" }

                        $members = @(Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT member_name, member_type_desc, member_state_desc, number_of_quorum_votes
FROM sys.dm_hadr_cluster_members ORDER BY member_name
"@)
                        if ($members.Count -gt 0)
                        {
                            $clusterList += "WSFC-Mitglieder ($($members.Count)): $(($members | ForEach-Object { "$($_.member_name) [$($_.member_type_desc), $($_.member_state_desc), $($_.number_of_quorum_votes) Stimme(n)]" }) -join ', ')"
                        }
                    }
                    catch { $clusterList += "WSFC-Informationen nicht lesbar: $($_.Exception.Message)" }

                    # Availability Groups samt Replikaten - das sind die 'weiteren Nodes' aus Sicht
                    # der Hochverfuegbarkeit.
                    try
                    {
                        $agRows = @(Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT ag.name                          AS AGName,
       ar.replica_server_name           AS ReplicaServer,
       ISNULL(ars.role_desc, 'UNKNOWN') AS RoleDesc,
       ar.availability_mode_desc        AS AvailabilityMode,
       ar.failover_mode_desc            AS FailoverMode,
       ISNULL(ars.synchronization_health_desc, 'UNKNOWN') AS SyncHealth
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
ORDER BY ag.name, ar.replica_server_name
"@)
                        if ($agRows.Count -eq 0)
                        {
                            $clusterList += 'Availability Groups: AlwaysOn ist aktiviert, es ist aber keine AG eingerichtet.'
                        }
                        else
                        {
                            foreach ($grp in ($agRows | Group-Object AGName))
                            {
                                $clusterList += "AG '$($grp.Name)' - $($grp.Count) Replikat(e):"
                                foreach ($rep in $grp.Group)
                                {
                                    $clusterList += "    $($rep.ReplicaServer): $($rep.RoleDesc), $($rep.AvailabilityMode), Failover $($rep.FailoverMode), Zustand $($rep.SyncHealth)"
                                }
                            }
                        }

                        $listeners = @(Invoke-DbaQuery -SqlInstance $server -Database master -As PSObject -EnableException -Query @"
SELECT ag.name AS AGName, l.dns_name, l.port
FROM sys.availability_group_listeners l
JOIN sys.availability_groups ag ON ag.group_id = l.group_id
"@)
                        foreach ($lsn in $listeners)
                        {
                            $clusterList += "Listener AG '$($lsn.AGName)': $($lsn.dns_name):$($lsn.port)"
                        }
                    }
                    catch { $clusterList += "Availability Groups nicht lesbar: $($_.Exception.Message)" }
                }
            }
            catch
            {
                $clusterList += "Cluster-/AlwaysOn-Status nicht ermittelbar: $($_.Exception.Message)"
            }

            # ---- Monitoring-Registry-Schluessel (Invoke-sqmMonitoringKey) ----
            try
            {
                $mk = Invoke-sqmMonitoringKey -ComputerName $hostName -Operation Get -ErrorAction Stop | Select-Object -First 1
                if ($mk -and ($mk.SQL -or $mk.TSM))
                {
                    $featureList += "Monitoring-Schluessel: gesetzt (SQL=$($mk.SQL)$(if ($mk.SQL_Description) { " / $($mk.SQL_Description)" }), TSM=$($mk.TSM), SQLFreeSpaceVersion=$($mk.SQLFreeSpaceVersion)) unter $($mk.RegistryPath)"
                }
                elseif ($mk)
                {
                    $featureList += "Monitoring-Schluessel: vorhanden, aber ohne Werte ($($mk.RegistryPath))"
                }
                else
                {
                    $featureList += 'Monitoring-Schluessel: NICHT gesetzt'
                }
            }
            catch
            {
                # Nur die erste Zeile der Ausnahme: der WinRM-Fehlertext ist mehrere Absaetze lang
                # und wuerde den Bericht sonst zumuellen.
                $kurz = (($_.Exception.Message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                if ($kurz.Length -gt 160) { $kurz = $kurz.Substring(0, 160) + '...' }
                $featureList += "Monitoring-Schluessel: nicht ermittelbar (kein WinRM-Zugriff auf $hostName): $kurz"
            }

            # SPN Status (List all SPNs + overall OK/Warning summary)
            $spnLines  = @('Not checked')
            $spnStatus = 'Not checked'
            $spnColor  = 'orange'
            try
            {
                $spnReport = Get-sqmSpnReport -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue
                if ($spnReport)
                {
                    if ($spnReport.DetailRows)
                    {
                        $spnDetails = @()
                        foreach ($row in $spnReport.DetailRows)
                        {
                            $spnDetails += "$($row.SPN) [$($row.Status)]"
                        }
                        $spnLines = if ($spnDetails.Count -gt 0) { $spnDetails } else { @('No SPNs found') }

                        $cntOk      = @($spnReport.DetailRows | Where-Object { $_.Status -eq 'OK' }).Count
                        $cntMissing = @($spnReport.DetailRows | Where-Object { $_.Status -eq 'Missing' }).Count
                        $cntUnexp   = @($spnReport.DetailRows | Where-Object { $_.Status -eq 'Unexpected' }).Count
                        $cntTotal   = @($spnReport.DetailRows).Count
                    }
                    else { $cntOk = 0; $cntMissing = 0; $cntUnexp = 0; $cntTotal = 0 }

                    # Gesamtstatus: bevorzugt das Status-Feld des Reports, sonst aus den Zaehlern ableiten
                    switch ("$($spnReport.Status)")
                    {
                        'OK'        { $spnStatus = "OK ($cntOk/$cntTotal SPNs registriert)"; $spnColor = 'green' }
                        'Warning'   { $spnStatus = "WARNUNG ($cntMissing fehlend, $cntUnexp unerwartet)"; $spnColor = 'orange' }
                        'NoNetwork' { $spnStatus = 'Nicht pruefbar (kein AD/Netzwerk)'; $spnColor = 'orange' }
                        'Error'     { $spnStatus = 'Fehler bei SPN-Pruefung'; $spnColor = 'red' }
                        default
                        {
                            if ($cntMissing -gt 0 -or $cntUnexp -gt 0) { $spnStatus = "WARNUNG ($cntMissing fehlend, $cntUnexp unerwartet)"; $spnColor = 'orange' }
                            elseif ($cntOk -gt 0) { $spnStatus = "OK ($cntOk/$cntTotal SPNs registriert)"; $spnColor = 'green' }
                            else { $spnStatus = 'Keine SPNs gefunden'; $spnColor = 'orange' }
                        }
                    }
                }
            }
            catch
            {
                $spnLines  = @('Error retrieving SPNs')
                $spnStatus = 'Fehler bei SPN-Pruefung'
                $spnColor  = 'red'
            }

            # Splunk Status (via Invoke-sqmSplunkConfiguration -Test)
            #
            # Der Aufruf lief frueher IMMER ohne Zielangabe und hat damit den Rechner geprueft, auf
            # dem der Bericht erzeugt wird - bei einem Bericht ueber eine entfernte Instanz stand im
            # Ergebnis also der Zustand des falschen Servers, ohne dass das erkennbar war. Jetzt wird
            # der lokale Weg nur noch benutzt, wenn die Zielinstanz auch wirklich hier laeuft;
            # andernfalls wird der Zielrechner adressiert, und ist der nicht erreichbar, steht das
            # ausdruecklich da statt eines fremden Messwerts.
            $splunkStatus = 'Nicht ermittelbar'
            $isLocalHost = $hostName -and (@($env:COMPUTERNAME, 'localhost', '.', '127.0.0.1') -contains $hostName -or
                $hostName -ieq $env:COMPUTERNAME)
            try
            {
                $splunkResult = if ($isLocalHost)
                {
                    Invoke-sqmSplunkConfiguration -Mode Test -ErrorAction SilentlyContinue
                }
                else
                {
                    Invoke-sqmSplunkConfiguration -Mode Test -ComputerList @($hostName) -ErrorAction Stop |
                        Select-Object -First 1
                }

                $geprueftAuf = if ($isLocalHost) { $env:COMPUTERNAME } else { $hostName }

                # Status statt nur IsConfigured auswerten: schlaegt die Remoteverbindung fehl,
                # liefert die Funktion trotzdem ein Objekt mit IsConfigured = $false zurueck. Das
                # allein auszuwerten hiesse, "nicht erreichbar" als "nicht konfiguriert" zu melden -
                # also wieder eine Aussage ueber einen Server, den wir nie gesehen haben.
                $antwortVonZiel = -not $splunkResult.ComputerName -or
                    ($splunkResult.ComputerName -split '\.')[0] -ieq ($geprueftAuf -split '\.')[0]

                if (-not $splunkResult)
                {
                    $splunkStatus = "Nicht ermittelbar (keine Antwort von $geprueftAuf)"
                }
                elseif (-not $antwortVonZiel)
                {
                    $splunkStatus = "Nicht ermittelbar (Antwort kam von '$($splunkResult.ComputerName)', gefragt war '$geprueftAuf')"
                }
                elseif ($splunkResult.Status -eq 'Success' -or $splunkResult.IsConfigured)
                {
                    $splunkStatus = "Konfiguriert auf $geprueftAuf (Dienst: $($splunkResult.ServiceStatus))"
                }
                elseif ($splunkResult.Status -eq 'NotConfigured')
                {
                    $splunkStatus = "Nicht konfiguriert auf $geprueftAuf"
                }
                else
                {
                    $grund = if ([string]::IsNullOrWhiteSpace($splunkResult.Status)) { 'keine auswertbare Rueckmeldung' } else { "Status: $($splunkResult.Status)" }
                    $splunkStatus = "Nicht ermittelbar auf $geprueftAuf ($grund)"
                }
            }
            catch
            {
                $splunkStatus = "Nicht ermittelbar (kein Zugriff auf $hostName)"
            }

            # ==========================================
            # CONFIGURATION
            # ==========================================

            # MAXDOP
            $maxdop = $server.Configuration.MaxDegreeOfParallelism.ConfigValue
            $cpuCount = $server.Processors
            $recommendedMaxdop = [math]::Min(8, $cpuCount)
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

                    # Kompatibilitaetsgrad als Jahreszahl - die reine Zahl (150, 160, ...) sagt im
                    # Bericht niemandem etwas, und genau dieser Wert entscheidet darueber, welches
                    # Verhalten und welcher Optimierer tatsaechlich gelten. Liegt er unter dem
                    # Stand der Instanz, laeuft die Datenbank bewusst oder unbewusst im Modus einer
                    # aelteren Version - das wird deshalb ausdruecklich vermerkt.
                    $compatValue = [int]($db.CompatibilityLevel -replace '\D', '')
                    $compatText = _ConvertTo-SqlVersionName $compatValue
                    if ($instanceCompat -gt 0 -and $compatValue -gt 0 -and $compatValue -lt $instanceCompat)
                    {
                        $compatText += ", niedriger als die Instanz: $(_ConvertTo-SqlVersionName $instanceCompat)"
                    }

                    $databases += [PSCustomObject]@{
                        Name           = $db.Name
                        Recovery       = $db.RecoveryModel
                        Compatibility  = $compatText
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
                -BackupDetails $backupDetails `
                -ServerFacts $serverFacts `
                -FeatureList $featureList `
                -ClusterList $clusterList `
                -MaxMemStatus $maxMemStatus `
                -MaxMemColor $maxMemColor `
                -Sysadmins $sysadmins `
                -SysadminColor $sysadminColor `
                -SysadminWarning $sysadminWarning `
                -AdvancedLogins $advancedLogins `
                -CLRStatus $clrStatus `
                -CLRColor $clrColor `
                -XPStatus $xpStatus `
                -XPColor $xpColor `
                -ServiceAccounts $serviceAccounts `
                -SPNList $spnLines `
                -SPNStatus $spnStatus `
                -SPNColor $spnColor `
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
        [string[]]$BackupDetails,
        [string[]]$ServerFacts,
        [string[]]$FeatureList,
        [string[]]$ClusterList,
        [string]$MaxMemStatus,
        [string]$MaxMemColor,
        [string[]]$Sysadmins,
        [string]$SysadminColor,
        [string]$SysadminWarning,
        [string[]]$AdvancedLogins,
        [string]$CLRStatus,
        [string]$CLRColor,
        [string]$XPStatus,
        [string]$XPColor,
        [string[]]$ServiceAccounts,
        [string[]]$SPNList,
        [string]$SPNStatus,
        [string]$SPNColor,
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

    # Rendert eine Werteliste untereinander (eine Zeile pro Eintrag), HTML-kodiert.
    function _HtmlList
    {
        param([string[]]$Items, [string]$EmptyText = 'None')
        $vals = @($Items | Where-Object { $_ -ne $null -and "$_".Trim() -ne '' })
        if ($vals.Count -eq 0) { return (_HtmlEncode $EmptyText) }
        return (($vals | ForEach-Object { _HtmlEncode $_ }) -join '<br>')
    }

    # Mappt die Status-Farbnamen (green/orange/red) auf Hex fuer Inline-Text.
    function _SpnColorHex
    {
        param([string]$Color)
        switch ($Color) { 'green' { '#27ae60' } 'red' { '#e74c3c' } 'orange' { '#f39c12' } default { '#e2e8f0' } }
    }

    $sysadminWarningHtml = if ($SysadminWarning) { "<div class=`"card-detail`" style=`"color:#e74c3c;font-weight:600;`">$(_HtmlEncode $SysadminWarning)</div>" } else { '' }

    $dbRows = if ($Databases) {
        $Databases | ForEach-Object {
            "<tr><td>$(_HtmlEncode $_.Name)</td><td>$($_.Recovery)</td><td>$(_HtmlEncode $_.Compatibility)</td><td>$(_HtmlEncode $_.DBO)</td><td>$($_.LastFullBackup)</td></tr>"
        } | Out-String
    } else {
        '<tr><td colspan="5">No databases</td></tr>'
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
      <div class="card-label">Sicherungen</div>
      <div class="card-value">$BackupStatus</div>
      <div class="card-detail">$(_HtmlList $BackupDetails 'Aus msdb.dbo.backupset, unabhaengig vom sichernden Werkzeug')</div>
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
    <div class="card $SysadminColor">
      <div class="card-label">Sysadmin Accounts</div>
      <div class="card-value" style="font-size: 13px; line-height: 1.8;">$(_HtmlList $Sysadmins 'None')</div>
      $sysadminWarningHtml
    </div>
    <div class="card">
      <div class="card-label">Logins with Extended Roles</div>
      <div class="card-value" style="font-size: 13px; line-height: 1.8;">$(_HtmlList $AdvancedLogins 'None with server roles')</div>
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
      <p><span class="info-label">SPN Status:</span> <strong style="color: $(_SpnColorHex $SPNColor);">$(_HtmlEncode $SPNStatus)</strong></p>
      <p style="margin-left: 12px;">$(_HtmlList $SPNList 'Not checked')</p>
      <p><span class="info-label">Splunk:</span> $SplunkStatus</p>
    </div>
  </div>

  <!-- SERVICE ACCOUNTS -->
  <div class="section-title">SERVER</div>
  <div class="info-block">
    <p>$(_HtmlList $ServerFacts 'Nicht ermittelbar')</p>
  </div>

  <div class="section-title">CLUSTER &amp; HOCHVERFUEGBARKEIT</div>
  <div class="info-block">
    <p>$(_HtmlList $ClusterList 'Nicht ermittelbar')</p>
  </div>

  <div class="section-title">INSTALLIERTE KOMPONENTEN</div>
  <div class="info-block">
    <p>$(_HtmlList $FeatureList 'Nicht ermittelbar')</p>
  </div>

  <div class="section-title">SERVICE ACCOUNTS</div>
  <div class="info-block">
    <p>$(_HtmlList $ServiceAccounts 'Unable to determine')</p>
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
        <th>Datenbank-Modus</th>
        <th>DBO Owner</th>
        <th>Last Full Backup</th>
      </tr>
    </thead>
    <tbody>
      $dbRows
    </tbody>
  </table>

  <div class="footer">
    Report generated by sqmSQLTool - Setup Report v2.0 | All times UTC<br>
    Quelle: <a href="https://www.powershelldba.de">www.powershelldba.de</a>
  </div>

</div>

</body>
</html>
"@
}
