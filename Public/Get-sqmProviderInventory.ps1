<#
.SYNOPSIS
    Collects an inventory of the local server (OS, hardware, disks, SQL Server, databases, backups,
    security) and writes ONE self-contained HTML file with a built-in viewer.

.DESCRIPTION
    Runs LOCALLY on the server to be inventoried (host data comes from the local CIM/WMI classes).
    Everything is collected in a single scan, including the security part (logins, database users,
    roles, permissions). The result is one HTML file per server. It contains the data and a viewer
    that needs no PowerShell, no Excel and no internet connection: open it in any browser.

    In the viewer you can load the HTML files of other servers (drag and drop), assign application
    and parent group per server, switch the security data on or off, anonymize server names, and
    export the provider view as CSV, Excel (.xlsx) or as a reduced HTML file WITHOUT security data.
    A second scan for the security part is never needed.

    Read-only: nothing is changed on the server. Only metadata views and DMVs are read, no user
    tables are scanned. Job step commands are NOT stored (they may contain secrets); only detected
    external references (UNC paths, linked servers, OPENQUERY) are stored.

    Sections that cannot be read (missing permission, old SQL version) do not abort the scan. They
    are listed in the viewer on the 'Pruefbericht' tab.

    IMPORTANT: the HTML file written by this function contains the security data (login names,
    permissions). Do not hand it to third parties. Use the viewer's provider export instead.

.PARAMETER SqlInstance
    Instance(s) to scan, e.g. "SQL01", "SQL01\INST1", "AGLISTENER". Default: all running SQL Server
    instances found as services on this computer. For clustered instances (FCI) pass the virtual
    network name explicitly.

.PARAMETER SqlCredential
    SQL login if Windows authentication is not possible. Default: Windows authentication.

.PARAMETER OutputPath
    Directory for the HTML file. Default: <module output path>\ProviderInventory.

.PARAMETER Application
    Optional: application(s) of this server, separated by "|". Can also be edited later in the
    viewer (the viewer value wins).

.PARAMETER ParentGroup
    Optional: parent group (Obergruppe) of this server. Same rule as -Application.

.PARAMETER IncludeAgentJobs
    Also collect SQL Agent job details (name, owner, schedule, last run, external references).
    Without this switch only the job count is collected.

.PARAMETER SkipSecurity
    Do not collect logins, database users, roles and permissions.

.PARAMETER SkipPerDatabase
    Do not switch into each database (no used-space, no database users, no cross-database
    references). Use only if a very large number of databases makes the scan too slow.

.PARAMETER SampleSeconds
    Length of the short load sample (batch requests/sec, transactions/sec). 0 = no sample. Default 10.

.PARAMETER BackupHistoryDays
    Window for backup duration and size statistics. Default 30.

.PARAMETER QueryTimeoutSeconds
    Timeout per SQL query in seconds. Default 120.

.PARAMETER SaveJson
    Additionally write the raw scan as a .json file (same name as the HTML file).

.PARAMETER NoOpen
    Do not open the HTML file after the scan.

.EXAMPLE
    Get-sqmProviderInventory -OutputPath D:\Inventory

.EXAMPLE
    Get-sqmProviderInventory -SqlInstance SQLCL01 -Application "SAP|DWH" -ParentGroup "Finance" -IncludeAgentJobs -NoOpen

.NOTES
    Run as local administrator for complete OS data (volumes, services, power plan).
    Load values are a snapshot; the file contains sqlserver_start_time so that the age of the DMV
    statistics can be judged.
#>
function Get-sqmProviderInventory
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string[]]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'ProviderInventory'),
		[Parameter(Mandatory = $false)]
		[string]$Application,
		[Parameter(Mandatory = $false)]
		[string]$ParentGroup,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeAgentJobs,
		[Parameter(Mandatory = $false)]
		[switch]$SkipSecurity,
		[Parameter(Mandatory = $false)]
		[switch]$SkipPerDatabase,
		[Parameter(Mandatory = $false)]
		[int]$SampleSeconds = 10,
		[Parameter(Mandatory = $false)]
		[int]$BackupHistoryDays = 30,
		[Parameter(Mandatory = $false)]
		[int]$QueryTimeoutSeconds = 120,
		[Parameter(Mandatory = $false)]
		[switch]$SaveJson,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	$ToolVersion = '0.2.0'
	$SchemaVersion = '1.0'
	$ErrorActionPreference = 'Stop'
	$queryTimeout = $QueryTimeoutSeconds
	$credential = $SqlCredential
	$script:Errs = New-Object System.Collections.ArrayList

	#region helpers
	function Add-ScanError
	{
		param ([string]$Section, [string]$Message)
		[void]$script:Errs.Add([pscustomobject]@{ section = $Section; message = $Message })
	}

	# Runs a block, records an error instead of throwing. Emits nothing on failure.
	function Invoke-Section
	{
		param ([string]$Name, [scriptblock]$Block)
		try { & $Block }
		catch { Add-ScanError -Section $Name -Message $_.Exception.Message }
	}

	function Get-Prop
	{
		param ($Object, [string]$Name)
		if ($null -eq $Object) { return $null }
		$p = $Object.PSObject.Properties[$Name]
		if ($p) { return $p.Value }
		return $null
	}

	function Invoke-Q
	{
		param ($Conn, [string]$Sql)
		$cmd = $Conn.CreateCommand()
		$cmd.CommandText = $Sql
		$cmd.CommandTimeout = $queryTimeout
		$rdr = $cmd.ExecuteReader()
		$list = New-Object System.Collections.Generic.List[object]
		try
		{
			$names = @()
			for ($i = 0; $i -lt $rdr.FieldCount; $i++) { $names += $rdr.GetName($i) }
			while ($rdr.Read())
			{
				$o = [ordered]@{ }
				for ($i = 0; $i -lt $rdr.FieldCount; $i++)
				{
					$v = $rdr.GetValue($i)
					if ($v -is [DBNull]) { $v = $null }
					elseif ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-ddTHH:mm:ss') }
					elseif ($v -is [datetimeoffset]) { $v = $v.ToString('yyyy-MM-ddTHH:mm:sszzz') }
					elseif ($v -is [timespan]) { $v = $v.ToString() }
					elseif ($v -is [byte[]]) { $v = [BitConverter]::ToString($v).Replace('-', '') }
					elseif ($v -is [guid]) { $v = $v.ToString() }
					$o[$names[$i]] = $v
				}
				$list.Add([pscustomobject]$o)
			}
		}
		finally { $rdr.Dispose() }
		return $list.ToArray()
	}

	function Get-Percentile
	{
		param ([double[]]$Values, [double]$P)
		if (-not $Values -or $Values.Count -eq 0) { return $null }
		$s = $Values | Sort-Object
		$idx = [math]::Ceiling($P / 100.0 * $s.Count) - 1
		if ($idx -lt 0) { $idx = 0 }
		return [double]$s[$idx]
	}

	function Get-ScheduleText
	{
		param ($S)
		$t = switch ([int]$S.freq_type)
		{
			1 { 'once' } 4 { 'daily' } 8 { 'weekly' } 16 { 'monthly' } 32 { 'monthly relative' } 64 { 'on agent start' } 128 { 'when idle' } default { 'unknown' }
		}
		$sub = ''
		$n = [int]$S.freq_subday_interval
		switch ([int]$S.freq_subday_type)
		{
			2 { $sub = " every $n sec" }
			4 { $sub = " every $n min" }
			8 { $sub = " every $n h" }
		}
		return ($t + $sub)
	}

	function Get-ExternalRef
	{
		param ([string]$Cmd, [string[]]$LinkedNames)
		$refs = @()
		if (-not $Cmd) { return @() }
		foreach ($m in [regex]::Matches($Cmd, '\\\\[A-Za-z0-9_.\-$]+\\[^\s"'']*')) { $refs += $m.Value }
		foreach ($ln in $LinkedNames)
		{
			if ($ln -and $Cmd.IndexOf($ln, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $refs += ('linkedserver:' + $ln) }
		}
		if ($Cmd -match '(?i)\bOPENQUERY\b|\bOPENROWSET\b|\bOPENDATASOURCE\b') { $refs += 'openquery/openrowset' }
		return @($refs | Select-Object -Unique)
	}

	function Get-VolumeForPath
	{
		param ([string]$Path, $Volumes)
		$best = $null
		$bestLen = -1
		foreach ($v in $Volumes)
		{
			$n = [string]$v.name
			if ($n -and $Path.StartsWith($n, [StringComparison]::OrdinalIgnoreCase) -and $n.Length -gt $bestLen)
			{
				$best = $v
				$bestLen = $n.Length
			}
		}
		return $best
	}
	#endregion

	#region host data
	function Get-HostData
	{
		$h = [ordered]@{ }
		$cs = Invoke-Section 'host.computersystem' { Get-CimInstance -ClassName Win32_ComputerSystem }
		$os = Invoke-Section 'host.operatingsystem' { Get-CimInstance -ClassName Win32_OperatingSystem }
		$cpu = @(Invoke-Section 'host.processor' { Get-CimInstance -ClassName Win32_Processor })
		$reg = Invoke-Section 'host.registry' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }

		$h.computer_name = $env:COMPUTERNAME
		$h.fqdn = Invoke-Section 'host.fqdn' { [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName }
		if ($cs)
		{
			$h.domain = $cs.Domain
			$h.part_of_domain = [bool]$cs.PartOfDomain
			$h.manufacturer = $cs.Manufacturer
			$h.model = $cs.Model
			$h.memory_mb = [math]::Round($cs.TotalPhysicalMemory / 1MB, 0)
			$h.is_virtual = [bool]("$($cs.Manufacturer) $($cs.Model)" -match '(?i)virtual|vmware|kvm|xen|hvm|qemu|google|amazon|nutanix|red hat')
		}
		$h.cpu = [ordered]@{
			sockets = @($cpu | ForEach-Object { $_.SocketDesignation } | Select-Object -Unique).Count
			cores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
			logical_processors = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
			model = ($cpu | Select-Object -First 1).Name
			max_clock_mhz = ($cpu | Select-Object -First 1).MaxClockSpeed
		}
		$osInfo = [ordered]@{ }
		if ($os)
		{
			$osInfo.caption = $os.Caption
			$osInfo.version = $os.Version
			$osInfo.build = $os.BuildNumber
			$osInfo.architecture = $os.OSArchitecture
			$osInfo.service_pack = $os.CSDVersion
			$osInfo.install_date = if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { $null }
			$h.last_boot = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
			$h.pagefile_configured_mb = Invoke-Section 'host.pagefile' { ((Get-CimInstance -ClassName Win32_PageFileUsage) | Measure-Object -Property AllocatedBaseSize -Sum).Sum }
		}
		if ($reg)
		{
			$osInfo.edition_id = Get-Prop $reg 'EditionID'
			$osInfo.installation_type = Get-Prop $reg 'InstallationType'
			$osInfo.display_version = Get-Prop $reg 'DisplayVersion'
			$osInfo.ubr = Get-Prop $reg 'UBR'
			$osInfo.product_name = Get-Prop $reg 'ProductName'
		}
		$h.os = $osInfo
		$h.time_zone = Invoke-Section 'host.timezone' { (Get-CimInstance -ClassName Win32_TimeZone).Caption }
		$h.power_plan = Invoke-Section 'host.powerplan' { (Get-CimInstance -Namespace 'root\cimv2\power' -ClassName Win32_PowerPlan -Filter 'IsActive=True').ElementName }
		$h.last_hotfix = Invoke-Section 'host.hotfix' {
			$hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
			if ($hf) { [ordered]@{ id = $hf.HotFixID; installed_on = $hf.InstalledOn.ToString('yyyy-MM-dd') } }
		}
		$h.ip_addresses = @(Invoke-Section 'host.network' {
				Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object {
					[ordered]@{ description = $_.Description; ip = @($_.IPAddress); dns_domain = $_.DNSDomain; dns_servers = @($_.DNSServerSearchOrder) }
				}
			})

		$h.volumes = @(Invoke-Section 'host.volumes' {
				Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType=3' | Where-Object { $_.Name -match '^[A-Za-z]:\\' } | ForEach-Object {
					[ordered]@{
						name = $_.Name
						label = $_.Label
						file_system = $_.FileSystem
						block_size = $_.BlockSize
						size_gb = if ($_.Capacity) { [math]::Round($_.Capacity / 1GB, 2) } else { $null }
						free_gb = if ($null -ne $_.FreeSpace) { [math]::Round($_.FreeSpace / 1GB, 2) } else { $null }
						used_gb = if ($_.Capacity) { [math]::Round(($_.Capacity - $_.FreeSpace) / 1GB, 2) } else { $null }
					}
				}
			})
		$h.disk_drives = @(Invoke-Section 'host.diskdrives' {
				Get-CimInstance -ClassName Win32_DiskDrive | ForEach-Object {
					[ordered]@{ model = $_.Model; size_gb = [math]::Round($_.Size / 1GB, 1); interface = $_.InterfaceType; media_type = $_.MediaType }
				}
			})
		$h.physical_disks = @(Invoke-Section 'host.physicaldisks' {
				Get-PhysicalDisk | ForEach-Object {
					[ordered]@{ friendly_name = $_.FriendlyName; media_type = [string]$_.MediaType; bus_type = [string]$_.BusType; size_gb = [math]::Round($_.Size / 1GB, 1) }
				}
			})

		$svcs = @(Invoke-Section 'host.services' { Get-CimInstance -ClassName Win32_Service })
		$sqlRegex = '^(MSSQL|SQLAgent|SQLBrowser|ReportServer|MsDtsServer|MSOLAP|SQLTELEMETRY|SSASTELEMETRY|SSISTELEMETRY|SQLWriter|SQLSERVERAGENT|PowerBIReportServer|MSSQLFDLauncher|MSSQLLaunchpad)'
		$h.sql_services = @($svcs | Where-Object { $_.Name -match $sqlRegex } | ForEach-Object {
				[ordered]@{ name = $_.Name; display_name = $_.DisplayName; state = $_.State; start_mode = $_.StartMode; account = $_.StartName }
			})
		# heuristic: automatic non-Microsoft services (monitoring, backup, security agents)
		$h.third_party_services = @($svcs | Where-Object {
				$_.StartMode -eq 'Auto' -and $_.PathName -and $_.PathName -notmatch '(?i)system32|syswow64|\\windows\\|microsoft|sql server'
			} | ForEach-Object {
				[ordered]@{ name = $_.Name; display_name = $_.DisplayName; state = $_.State; account = $_.StartName; path = $_.PathName }
			})
		$h.errors = @($script:Errs)
		return $h
	}
	#endregion

	#region instance data
	function Get-InstanceData
	{
		param ([string]$Target, [string]$InstanceName, $HostVolumes)

		$script:Errs = New-Object System.Collections.ArrayList
		$inst = [ordered]@{ instance_name = $InstanceName; connect_target = $Target; connected = $false; connect_error = $null }

		$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
		$csb['Data Source'] = $Target
		$csb['Initial Catalog'] = 'master'
		$csb['Application Name'] = 'sqmProviderInventory'
		$csb['Connect Timeout'] = 15
		$csb['TrustServerCertificate'] = $true
		if ($credential)
		{
			$csb['User ID'] = $credential.UserName
			$csb['Password'] = $credential.GetNetworkCredential().Password
		}
		else { $csb['Integrated Security'] = $true }

		$conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString)
		try { $conn.Open() }
		catch
		{
			$inst.connect_error = $_.Exception.Message
			return [pscustomobject]$inst
		}
		$inst.connected = $true

		try
		{
			#--- server properties
			$srv = Invoke-Section 'server.properties' {
				Invoke-Q $conn @'
	SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(256)) AS machine_name,
	 CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)) AS server_name,
	 CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) AS product_version,
	 CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64)) AS product_level,
	 CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)) AS product_update_level,
	 CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(64)) AS product_update_reference,
	 CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
	 CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
	 CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS collation,
	 CAST(SERVERPROPERTY('IsClustered') AS int) AS is_clustered,
	 CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS is_hadr_enabled,
	 CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS windows_auth_only,
	 CAST(SERVERPROPERTY('IsFullTextInstalled') AS int) AS fulltext_installed,
	 CAST(SERVERPROPERTY('IsPolyBaseInstalled') AS int) AS polybase_installed,
	 CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)) AS default_data_path,
	 CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(512)) AS default_log_path,
	 @@VERSION AS version_string
'@
			}
			$srvRow = $srv | Select-Object -First 1
			$major = 0
			if ($srvRow -and $srvRow.product_version) { $major = [int]($srvRow.product_version.Split('.')[0]) }
			$sysinfo = Invoke-Section 'server.sysinfo' { Invoke-Q $conn 'SELECT * FROM sys.dm_os_sys_info' } | Select-Object -First 1
			$sched = Invoke-Section 'server.schedulers' { Invoke-Q $conn "SELECT COUNT(*) AS n FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE'" } | Select-Object -First 1
			$sysmem = Invoke-Section 'server.sysmemory' { Invoke-Q $conn 'SELECT * FROM sys.dm_os_sys_memory' } | Select-Object -First 1
			$uptime = Invoke-Section 'server.uptime' { Invoke-Q $conn 'SELECT DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS uptime_sec FROM sys.dm_os_sys_info' } | Select-Object -First 1
			$uptimeSec = if ($uptime) { [double]$uptime.uptime_sec } else { 0 }

			$server = [ordered]@{ }
			if ($srvRow) { foreach ($p in $srvRow.PSObject.Properties) { $server[$p.Name] = $p.Value } }
			$server.major_version = $major
			$server.sqlserver_start_time = Get-Prop $sysinfo 'sqlserver_start_time'
			$server.uptime_hours = [math]::Round($uptimeSec / 3600, 1)
			$server.cpu_count = Get-Prop $sysinfo 'cpu_count'
			$server.hyperthread_ratio = Get-Prop $sysinfo 'hyperthread_ratio'
			$server.socket_count = Get-Prop $sysinfo 'socket_count'
			$server.cores_per_socket = Get-Prop $sysinfo 'cores_per_socket'
			$server.licensed_cores_visible_online = Get-Prop $sched 'n'
			$server.virtual_machine_type = Get-Prop $sysinfo 'virtual_machine_type_desc'
			$pmkb = Get-Prop $sysinfo 'physical_memory_kb'
			$server.physical_memory_mb = if ($pmkb) { [math]::Round($pmkb / 1024, 0) } else { $null }
			$server.os_available_memory_mb = if (Get-Prop $sysmem 'available_physical_memory_kb') { [math]::Round($sysmem.available_physical_memory_kb / 1024, 0) } else { $null }
			$server.os_memory_state = Get-Prop $sysmem 'system_memory_state_desc'
			$inst.server = $server

			#--- configuration
			$cfg = [ordered]@{ }
			$cfgRows = @(Invoke-Section 'server.config' {
					Invoke-Q $conn @'
	SELECT name, CAST(value_in_use AS bigint) AS v FROM sys.configurations
	WHERE name IN (N'max server memory (MB)', N'min server memory (MB)', N'max degree of parallelism', N'cost threshold for parallelism',
	 N'optimize for ad hoc workloads', N'backup compression default', N'clr enabled', N'xp_cmdshell', N'remote admin connections',
	 N'Database Mail XPs', N'Agent XPs', N'Ole Automation Procedures', N'Ad Hoc Distributed Queries', N'filestream access level',
	 N'contained database authentication', N'backup checksum default')
'@
				})
			foreach ($r in $cfgRows) { $cfg[$r.name] = $r.v }
			$inst.config = $cfg

			#--- network (listening ports)
			$inst.tcp_settings = @(Invoke-Section 'server.network' {
					Invoke-Q $conn @'
	SELECT registry_key, value_name, CAST(value_data AS nvarchar(256)) AS value_data FROM sys.dm_server_registry
	WHERE (registry_key LIKE N'%SuperSocketNetLib\Tcp' OR registry_key LIKE N'%SuperSocketNetLib\Tcp\IPAll') AND value_name IN (N'Enabled', N'TcpPort', N'TcpDynamicPorts')
'@
				} | ForEach-Object {
					# registry values arrive with a trailing NUL character
					[pscustomobject][ordered]@{ registry_key = $_.registry_key; value_name = $_.value_name; value_data = ([string]$_.value_data).TrimEnd([char]0) }
				})
			$inst.endpoints = @(Invoke-Section 'server.endpoints' {
					Invoke-Q $conn @'
	SELECT e.name, e.type_desc, e.state_desc, t.port FROM sys.endpoints e LEFT JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id WHERE e.endpoint_id > 4
'@
				})

			#--- load (CPU history from ring buffer, memory counters, short sample)
			$load = [ordered]@{ }
			$cpuRows = @(Invoke-Section 'load.cpu' {
					Invoke-Q $conn @'
	SELECT record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu,
	 100 - record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS total_cpu
	FROM (SELECT CONVERT(xml, record) AS record FROM sys.dm_os_ring_buffers
	 WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%') x
'@
				})
			if ($cpuRows.Count -gt 0)
			{
				$sq = [double[]]@($cpuRows | ForEach-Object { [double]$_.sql_cpu })
				$tt = [double[]]@($cpuRows | ForEach-Object { [double]$_.total_cpu })
				$load.cpu_samples_minutes = $cpuRows.Count
				$load.sql_cpu_avg_pct = [math]::Round(($sq | Measure-Object -Average).Average, 1)
				$load.sql_cpu_p95_pct = Get-Percentile $sq 95
				$load.sql_cpu_max_pct = ($sq | Measure-Object -Maximum).Maximum
				$load.total_cpu_avg_pct = [math]::Round(($tt | Measure-Object -Average).Average, 1)
				$load.total_cpu_p95_pct = Get-Percentile $tt 95
				$load.total_cpu_max_pct = ($tt | Measure-Object -Maximum).Maximum
			}
			$ctrSql = @'
	SELECT RTRIM(object_name) AS obj, RTRIM(counter_name) AS ctr, RTRIM(instance_name) AS inst, cntr_value AS v
	FROM sys.dm_os_performance_counters
	WHERE counter_name IN (N'Page life expectancy', N'Total Server Memory (KB)', N'Target Server Memory (KB)', N'Batch Requests/sec', N'Transactions/sec', N'User Connections', N'SQL Compilations/sec')
'@
			$c0 = @(Invoke-Section 'load.counters' { Invoke-Q $conn $ctrSql })
			$t0 = Get-Date
			if ($SampleSeconds -gt 0) { Start-Sleep -Seconds $SampleSeconds }
			$c1 = if ($SampleSeconds -gt 0) { @(Invoke-Section 'load.counters2' { Invoke-Q $conn $ctrSql }) } else { @() }
			$t1 = Get-Date
			$span = ($t1 - $t0).TotalSeconds
			function Get-Ctr { param ($Rows, [string]$Name, [string]$ObjLike, [string]$Inst) $Rows | Where-Object { $_.ctr -eq $Name -and $_.obj -like $ObjLike -and ($Inst -eq '' -or $_.inst -eq $Inst) } | Select-Object -First 1 }
			$ple = Get-Ctr $c0 'Page life expectancy' '*Buffer Manager*' ''
			$tsm = Get-Ctr $c0 'Total Server Memory (KB)' '*Memory Manager*' ''
			$tgt = Get-Ctr $c0 'Target Server Memory (KB)' '*Memory Manager*' ''
			$uc = Get-Ctr $c0 'User Connections' '*General Statistics*' ''
			$load.page_life_expectancy_sec = Get-Prop $ple 'v'
			$load.total_server_memory_mb = if ($tsm) { [math]::Round($tsm.v / 1024, 0) } else { $null }
			$load.target_server_memory_mb = if ($tgt) { [math]::Round($tgt.v / 1024, 0) } else { $null }
			$load.user_connections = Get-Prop $uc 'v'
			foreach ($def in @(
					@{ key = 'batch_requests_per_sec'; name = 'Batch Requests/sec'; obj = '*SQL Statistics*'; inst = '' },
					@{ key = 'transactions_per_sec'; name = 'Transactions/sec'; obj = '*:Databases*'; inst = '_Total' },
					@{ key = 'compilations_per_sec'; name = 'SQL Compilations/sec'; obj = '*SQL Statistics*'; inst = '' }))
			{
				$a = Get-Ctr $c0 $def.name $def.obj $def.inst
				$b = Get-Ctr $c1 $def.name $def.obj $def.inst
				if ($a -and $uptimeSec -gt 0) { $load["$($def.key)_avg_since_start"] = [math]::Round($a.v / $uptimeSec, 1) }
				if ($a -and $b -and $span -gt 0) { $load["$($def.key)_sampled"] = [math]::Round(($b.v - $a.v) / $span, 1) }
			}
			$load.sample_seconds = $SampleSeconds
			$inst.load = $load

			#--- databases (user databases + tempdb only)
			$dbRows = @(Invoke-Section 'databases' {
					Invoke-Q $conn 'SELECT d.*, SUSER_SNAME(d.owner_sid) AS owner_name FROM sys.databases d WHERE d.database_id > 4 OR d.database_id = 2 ORDER BY d.name'
				})
			$fileRows = @(Invoke-Section 'database.files' {
					Invoke-Q $conn @'
	SELECT mf.database_id, DB_NAME(mf.database_id) AS database_name, mf.name AS logical_name, mf.type_desc, mf.physical_name,
	 CAST(mf.size AS bigint) * 8 / 1024.0 AS size_mb, mf.max_size, mf.growth, mf.is_percent_growth, mf.state_desc
	FROM sys.master_files mf WHERE mf.database_id > 4 OR mf.database_id = 2
'@
				})
			$logSpace = @(Invoke-Section 'database.logspace' { Invoke-Q $conn 'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS' })
			$tde = @(Invoke-Section 'database.tde' {
					Invoke-Q $conn 'SELECT DB_NAME(database_id) AS database_name, encryption_state, encryptor_type, key_algorithm, key_length FROM sys.dm_database_encryption_keys'
				})

			#--- backups
			$bkpStats = @(Invoke-Section 'backup.stats' {
					$sql = @'
	SELECT bs.database_name, bs.type, COUNT(*) AS cnt,
	 AVG(CAST(DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) AS float)) AS avg_sec,
	 MAX(DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date)) AS max_sec,
	 AVG(CAST(bs.backup_size AS float)) / 1048576.0 AS avg_size_mb,
	 MAX(CAST(bs.backup_size AS float)) / 1048576.0 AS max_size_mb,
	 AVG(CAST(bs.compressed_backup_size AS float)) / 1048576.0 AS avg_compressed_mb
	FROM msdb.dbo.backupset bs
	WHERE bs.backup_finish_date >= DATEADD(DAY, -{DAYS}, GETDATE())
	GROUP BY bs.database_name, bs.type
'@
					Invoke-Q $conn $sql.Replace('{DAYS}', [string]$BackupHistoryDays)
				})
			$bkpLast = @(Invoke-Section 'backup.last' {
					Invoke-Q $conn 'SELECT database_name, type, MAX(backup_finish_date) AS last_finish FROM msdb.dbo.backupset GROUP BY database_name, type'
				})
			$bkpDev = @(Invoke-Section 'backup.devices' {
					Invoke-Q $conn @'
	;WITH x AS (SELECT bs.database_name, bs.type, mf.physical_device_name, mf.device_type,
	 ROW_NUMBER() OVER (PARTITION BY bs.database_name, bs.type ORDER BY bs.backup_finish_date DESC) AS rn
	 FROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id)
	SELECT database_name, type, physical_device_name, device_type FROM x WHERE rn = 1
'@
				})
			$bkpGrowth = @(Invoke-Section 'backup.growth' {
					Invoke-Q $conn @'
	SELECT database_name, CONVERT(char(7), backup_finish_date, 120) AS ym, MAX(CAST(backup_size AS float)) / 1048576.0 AS size_mb
	FROM msdb.dbo.backupset WHERE type = 'D' AND backup_finish_date >= DATEADD(MONTH, -12, GETDATE())
	GROUP BY database_name, CONVERT(char(7), backup_finish_date, 120)
'@
				})

			#--- per database loop
			$spaceByDb = @{ }
			$xdb = New-Object System.Collections.ArrayList
			$dbUsers = New-Object System.Collections.ArrayList
			$dbRoles = New-Object System.Collections.ArrayList
			$dbRoleMembers = New-Object System.Collections.ArrayList
			$dbPerms = New-Object System.Collections.ArrayList
			$fixedRoles = @('db_owner', 'db_accessadmin', 'db_securityadmin', 'db_ddladmin', 'db_backupoperator', 'db_datareader', 'db_datawriter', 'db_denydatareader', 'db_denydatawriter', 'public')
			if (-not $SkipPerDatabase)
			{
				foreach ($d in $dbRows)
				{
					if ($d.database_id -le 4 -or $d.state_desc -ne 'ONLINE') { continue }
					$dn = [string]$d.name
					try
					{
						$conn.ChangeDatabase($dn)
						$sp = Invoke-Q $conn @'
	SELECT SUM(CASE WHEN type = 0 THEN CAST(FILEPROPERTY(name, 'SpaceUsed') AS bigint) END) * 8 / 1024.0 AS data_used_mb,
	 (SELECT COUNT(*) FROM sys.tables) AS table_count,
	 (SELECT COUNT(*) FROM sys.assemblies WHERE is_user_defined = 1) AS clr_assemblies
	FROM sys.database_files
'@ | Select-Object -First 1
						$spaceByDb[$dn] = $sp
						$ae = $null
						if ($major -ge 13)
						{
							try { $ae = (Invoke-Q $conn 'SELECT COUNT(*) AS n FROM sys.column_master_keys' | Select-Object -First 1).n } catch { Write-Verbose "Ignoriert: $($_.Exception.Message)" }
						}
						if ($ae) { $spaceByDb[$dn] | Add-Member -NotePropertyName always_encrypted_keys -NotePropertyValue $ae -Force }

						Invoke-Q $conn @'
	SELECT ISNULL(referenced_server_name, '') AS ref_server, ISNULL(referenced_database_name, '') AS ref_database, COUNT(*) AS ref_count
	FROM sys.sql_expression_dependencies
	WHERE referenced_server_name IS NOT NULL OR (referenced_database_name IS NOT NULL AND referenced_database_name <> DB_NAME())
	GROUP BY referenced_server_name, referenced_database_name
'@ | ForEach-Object { [void]$xdb.Add([pscustomobject][ordered]@{ database = $dn; ref_server = $_.ref_server; ref_database = $_.ref_database; ref_count = $_.ref_count }) }

						if (-not $SkipSecurity)
						{
							Invoke-Q $conn @'
	SELECT dp.*, sp.name AS login_name FROM sys.database_principals dp LEFT JOIN sys.server_principals sp ON sp.sid = dp.sid
	WHERE dp.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K') AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys') AND dp.name NOT LIKE '##%'
'@ | ForEach-Object {
								$auth = Get-Prop $_ 'authentication_type_desc'
								$orphan = ($_.type -in @('S', 'U', 'G')) -and (-not $_.login_name) -and ($auth -notin @('NONE', 'DATABASE'))
								[void]$dbUsers.Add([pscustomobject][ordered]@{
										database = $dn; name = $_.name; type = $_.type_desc; authentication = $auth; login_name = $_.login_name
										default_schema = $_.default_schema_name; create_date = $_.create_date; orphaned = [bool]$orphan
									})
							}
							Invoke-Q $conn @'
	SELECT name, type_desc, USER_NAME(owning_principal_id) AS owner_name FROM sys.database_principals WHERE type IN ('R', 'A') AND principal_id > 0
'@ | Where-Object { $_.name -notin $fixedRoles } | ForEach-Object {
								[void]$dbRoles.Add([pscustomobject][ordered]@{ database = $dn; name = $_.name; type = $_.type_desc; owner = $_.owner_name })
							}
							Invoke-Q $conn @'
	SELECT r.name AS role_name, m.name AS member_name, m.type_desc AS member_type
	FROM sys.database_role_members rm JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
	JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
	WHERE m.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys') AND m.name NOT LIKE '##%'
'@ | ForEach-Object {
								[void]$dbRoleMembers.Add([pscustomobject][ordered]@{ database = $dn; role = $_.role_name; member = $_.member_name; member_type = $_.member_type; role_is_fixed = ($_.role_name -in $fixedRoles) })
							}
							Invoke-Q $conn @'
	SELECT TOP 5000 pr.name AS grantee, pr.type_desc AS grantee_type, pe.class_desc, pe.permission_name, pe.state_desc,
	 CASE pe.class WHEN 0 THEN DB_NAME() WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + '.' + OBJECT_NAME(pe.major_id) WHEN 3 THEN SCHEMA_NAME(pe.major_id) ELSE CAST(pe.major_id AS varchar(20)) END AS target
	FROM sys.database_permissions pe JOIN sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
	WHERE pr.name NOT IN ('public', 'dbo', 'guest') AND pr.name NOT LIKE '##%' AND pe.permission_name <> 'CONNECT'
'@ | ForEach-Object {
								[void]$dbPerms.Add([pscustomobject][ordered]@{ database = $dn; grantee = $_.grantee; grantee_type = $_.grantee_type; class = $_.class_desc; permission = $_.permission_name; state = $_.state_desc; target = $_.target })
							}
						}
					}
					catch { Add-ScanError -Section "database:$dn" -Message $_.Exception.Message }
				}
				try { $conn.ChangeDatabase('master') } catch { Write-Verbose "Ignoriert: $($_.Exception.Message)" }
			}

			# assemble database list
			$databases = New-Object System.Collections.ArrayList
			foreach ($d in $dbRows)
			{
				$dn = [string]$d.name
				$myFiles = @($fileRows | Where-Object { $_.database_id -eq $d.database_id })
				$dataMb = ($myFiles | Where-Object { $_.type_desc -eq 'ROWS' } | Measure-Object -Property size_mb -Sum).Sum
				$logMb = ($myFiles | Where-Object { $_.type_desc -eq 'LOG' } | Measure-Object -Property size_mb -Sum).Sum
				$sp = $spaceByDb[$dn]
				$ls = $logSpace | Where-Object { $_.'Database Name' -eq $dn } | Select-Object -First 1
				$tdeRow = $tde | Where-Object { $_.database_name -eq $dn } | Select-Object -First 1
				# backups
				$bk = [ordered]@{ }
				foreach ($t in @('D', 'I', 'L'))
				{
					$st = $bkpStats | Where-Object { $_.database_name -eq $dn -and $_.type -eq $t } | Select-Object -First 1
					$lt = $bkpLast | Where-Object { $_.database_name -eq $dn -and $_.type -eq $t } | Select-Object -First 1
					$dv = $bkpDev | Where-Object { $_.database_name -eq $dn -and $_.type -eq $t } | Select-Object -First 1
					$key = switch ($t) { 'D' { 'full' } 'I' { 'diff' } 'L' { 'log' } }
					$bk[$key] = [ordered]@{
						last_finish = Get-Prop $lt 'last_finish'
						count_in_window = Get-Prop $st 'cnt'
						avg_duration_sec = if ($st) { [math]::Round($st.avg_sec, 1) } else { $null }
						max_duration_sec = Get-Prop $st 'max_sec'
						avg_size_mb = if ($st) { [math]::Round($st.avg_size_mb, 1) } else { $null }
						max_size_mb = if ($st) { [math]::Round($st.max_size_mb, 1) } else { $null }
						avg_compressed_mb = if ($st -and $null -ne $st.avg_compressed_mb) { [math]::Round($st.avg_compressed_mb, 1) } else { $null }
						last_target = Get-Prop $dv 'physical_device_name'
					}
				}
				# growth from monthly full backup size
				$gr = @($bkpGrowth | Where-Object { $_.database_name -eq $dn } | Sort-Object ym)
				$growthMonth = $null
				$growthHist = $null
				if ($gr.Count -ge 2)
				{
					$first = $gr[0]; $last = $gr[$gr.Count - 1]
					$months = ([int]$last.ym.Substring(0, 4) * 12 + [int]$last.ym.Substring(5, 2)) - ([int]$first.ym.Substring(0, 4) * 12 + [int]$first.ym.Substring(5, 2))
					if ($months -gt 0) { $growthMonth = [math]::Round(($last.size_mb - $first.size_mb) / $months, 1) }
				}
				if ($gr.Count -ge 1) { $growthHist = ($gr | ForEach-Object { "$($_.ym)=$([math]::Round($_.size_mb,0))" }) -join ';' }

				[void]$databases.Add([pscustomobject][ordered]@{
						name = $dn
						database_id = $d.database_id
						state = $d.state_desc
						compatibility_level = Get-Prop $d 'compatibility_level'
						recovery_model = Get-Prop $d 'recovery_model_desc'
						collation = Get-Prop $d 'collation_name'
						owner = Get-Prop $d 'owner_name'
						create_date = Get-Prop $d 'create_date'
						is_read_only = Get-Prop $d 'is_read_only'
						is_snapshot = [bool](Get-Prop $d 'source_database_id')
						page_verify = Get-Prop $d 'page_verify_option_desc'
						containment = Get-Prop $d 'containment_desc'
						is_encrypted_tde = Get-Prop $d 'is_encrypted'
						tde_algorithm = Get-Prop $tdeRow 'key_algorithm'
						service_broker = Get-Prop $d 'is_broker_enabled'
						is_published = Get-Prop $d 'is_published'
						is_subscribed = Get-Prop $d 'is_subscribed'
						is_merge_published = Get-Prop $d 'is_merge_published'
						is_distributor = Get-Prop $d 'is_distributor'
						cdc_enabled = Get-Prop $d 'is_cdc_enabled'
						data_size_mb = if ($null -ne $dataMb) { [math]::Round($dataMb, 1) } else { $null }
						data_used_mb = if ($sp -and $null -ne $sp.data_used_mb) { [math]::Round($sp.data_used_mb, 1) } else { $null }
						log_size_mb = if ($null -ne $logMb) { [math]::Round($logMb, 1) } else { $null }
						log_used_pct = if ($ls) { $ls.'Log Space Used (%)' } else { $null }
						file_count = $myFiles.Count
						table_count = Get-Prop $sp 'table_count'
						clr_assemblies = Get-Prop $sp 'clr_assemblies'
						always_encrypted_keys = Get-Prop $sp 'always_encrypted_keys'
						growth_mb_per_month = $growthMonth
						full_backup_size_history_mb = $growthHist
						backup = $bk
					})
			}
			$inst.databases = @($databases)
			$inst.files = @($fileRows | ForEach-Object {
					[pscustomobject][ordered]@{
						database = $_.database_name; logical_name = $_.logical_name; type = $_.type_desc; path = $_.physical_name
						size_mb = [math]::Round($_.size_mb, 1); max_size = $_.max_size; growth = $_.growth; percent_growth = $_.is_percent_growth
						volume = $(
							$fv = Get-VolumeForPath -Path $_.physical_name -Volumes $HostVolumes
							if ($fv) { $fv.name } else { $null }
						)
					}
				})
			$inst.cross_database_refs = @($xdb)

			#--- storage IO per volume (since SQL start)
			$ioRows = @(Invoke-Section 'storage.io' {
					Invoke-Q $conn @'
	SELECT mf.physical_name, CAST(mf.size AS bigint) * 8 / 1024.0 AS size_mb, vfs.num_of_reads, vfs.num_of_writes,
	 vfs.num_of_bytes_read, vfs.num_of_bytes_written, vfs.io_stall_read_ms, vfs.io_stall_write_ms
	FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
'@
				})
			$agg = @{ }
			foreach ($r in $ioRows)
			{
				$vol = Get-VolumeForPath -Path $r.physical_name -Volumes $HostVolumes
				$vn = if ($vol) { $vol.name } else { '(other/UNC)' }
				if (-not $agg.ContainsKey($vn)) { $agg[$vn] = [pscustomobject]@{ volume = $vn; files = 0; sql_files_mb = 0.0; reads = 0.0; writes = 0.0; read_mb = 0.0; write_mb = 0.0; stall_read = 0.0; stall_write = 0.0 } }
				$a = $agg[$vn]
				$a.files++
				$a.sql_files_mb += [double]$r.size_mb
				$a.reads += [double]$r.num_of_reads
				$a.writes += [double]$r.num_of_writes
				$a.read_mb += [double]$r.num_of_bytes_read / 1MB
				$a.write_mb += [double]$r.num_of_bytes_written / 1MB
				$a.stall_read += [double]$r.io_stall_read_ms
				$a.stall_write += [double]$r.io_stall_write_ms
			}
			$inst.volume_io = @($agg.Values | Sort-Object volume | ForEach-Object {
					[pscustomobject][ordered]@{
						volume = $_.volume; sql_file_count = $_.files; sql_files_mb = [math]::Round($_.sql_files_mb, 0)
						avg_read_latency_ms = if ($_.reads -gt 0) { [math]::Round($_.stall_read / $_.reads, 1) } else { $null }
						avg_write_latency_ms = if ($_.writes -gt 0) { [math]::Round($_.stall_write / $_.writes, 1) } else { $null }
						avg_iops_since_start = if ($uptimeSec -gt 0) { [math]::Round(($_.reads + $_.writes) / $uptimeSec, 1) } else { $null }
						avg_mb_per_sec_since_start = if ($uptimeSec -gt 0) { [math]::Round(($_.read_mb + $_.write_mb) / $uptimeSec, 2) } else { $null }
						total_read_gb = [math]::Round($_.read_mb / 1024, 1); total_write_gb = [math]::Round($_.write_mb / 1024, 1)
					}
				})

			#--- linked servers
			$inst.linked_servers = @(Invoke-Section 'linked.servers' {
					Invoke-Q $conn @'
	SELECT s.name, s.product, s.provider, s.data_source, s.catalog, s.is_data_access_enabled, s.is_rpc_out_enabled,
	 (SELECT COUNT(*) FROM sys.linked_logins ll WHERE ll.server_id = s.server_id) AS login_mappings,
	 (SELECT COUNT(*) FROM sys.linked_logins ll WHERE ll.server_id = s.server_id AND ll.uses_self_credential = 0 AND ll.remote_name IS NOT NULL) AS fixed_remote_logins
	FROM sys.servers s WHERE s.is_linked = 1
'@
				})
			$linkedNames = @($inst.linked_servers | ForEach-Object { $_.name })

			#--- agent jobs
			$js = Invoke-Section 'agent.summary' { Invoke-Q $conn 'SELECT COUNT(*) AS total, SUM(CAST(enabled AS int)) AS enabled FROM msdb.dbo.sysjobs' } | Select-Object -First 1
			$inst.agent_jobs_summary = [ordered]@{ total = Get-Prop $js 'total'; enabled = Get-Prop $js 'enabled'; details_collected = [bool]$IncludeAgentJobs }
			if ($IncludeAgentJobs)
			{
				$jobs = @(Invoke-Section 'agent.jobs' {
						Invoke-Q $conn @'
	SELECT j.job_id, j.name, j.enabled, SUSER_SNAME(j.owner_sid) AS owner_name, c.name AS category, j.date_created, j.date_modified,
	 (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps s WHERE s.job_id = j.job_id) AS step_count
	FROM msdb.dbo.sysjobs j LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
'@
					})
				$hist = @(Invoke-Section 'agent.history' {
						Invoke-Q $conn @'
	SELECT job_id, MAX(msdb.dbo.agent_datetime(run_date, run_time)) AS last_run, COUNT(*) AS runs,
	 AVG(CAST((run_duration / 10000) * 3600 + ((run_duration / 100) % 100) * 60 + (run_duration % 100) AS float)) AS avg_sec,
	 SUM(CASE WHEN run_status = 0 THEN 1 ELSE 0 END) AS failures
	FROM msdb.dbo.sysjobhistory WHERE step_id = 0 GROUP BY job_id
'@
					})
				$sched = @(Invoke-Section 'agent.schedules' {
						Invoke-Q $conn @'
	SELECT js.job_id, sc.name, sc.freq_type, sc.freq_interval, sc.freq_subday_type, sc.freq_subday_interval
	FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id WHERE sc.enabled = 1
'@
					})
				$steps = @(Invoke-Section 'agent.steps' {
						Invoke-Q $conn 'SELECT job_id, step_id, step_name, subsystem, database_name, proxy_id, command FROM msdb.dbo.sysjobsteps'
					})
				$jobList = New-Object System.Collections.ArrayList
				foreach ($j in $jobs)
				{
					$myS = @($steps | Where-Object { $_.job_id -eq $j.job_id })
					$refs = @()
					foreach ($s in $myS) { $refs += @(Get-ExternalRef -Cmd ([string]$s.command) -LinkedNames $linkedNames) }
					$h1 = $hist | Where-Object { $_.job_id -eq $j.job_id } | Select-Object -First 1
					$sc = @($sched | Where-Object { $_.job_id -eq $j.job_id } | ForEach-Object { Get-ScheduleText $_ })
					[void]$jobList.Add([pscustomobject][ordered]@{
							name = $j.name; enabled = [bool]$j.enabled; owner = $j.owner_name; category = $j.category
							created = $j.date_created; modified = $j.date_modified; step_count = $j.step_count
							subsystems = (($myS | ForEach-Object { $_.subsystem } | Select-Object -Unique) -join ',')
							uses_proxy = [bool]($myS | Where-Object { $_.proxy_id })
							schedules = ($sc -join '; ')
							last_run = Get-Prop $h1 'last_run'
							avg_duration_sec = if ($h1) { [math]::Round($h1.avg_sec, 1) } else { $null }
							failures_in_history = Get-Prop $h1 'failures'
							external_refs = (@($refs | Select-Object -Unique) -join '; ')
						})
				}
				$inst.agent_jobs = @($jobList)
			}

			#--- high availability / DR
			$ha = [ordered]@{ is_hadr_enabled = [bool]$server.is_hadr_enabled; is_clustered = [bool]$server.is_clustered }
			if ($server.is_hadr_enabled)
			{
				$ha.availability_replicas = @(Invoke-Section 'ha.replicas' {
						Invoke-Q $conn @'
	SELECT ag.name AS ag_name, ar.replica_server_name, ar.availability_mode_desc, ar.failover_mode_desc, ar.secondary_role_allow_connections_desc,
	 rs.role_desc, rs.synchronization_health_desc, rs.is_local
	FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
	LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
'@
					})
				$ha.listeners = @(Invoke-Section 'ha.listeners' {
						Invoke-Q $conn 'SELECT ag.name AS ag_name, l.dns_name, l.port FROM sys.availability_group_listeners l JOIN sys.availability_groups ag ON ag.group_id = l.group_id'
					})
				$ha.availability_databases = @(Invoke-Section 'ha.databases' {
						Invoke-Q $conn 'SELECT ag.name AS ag_name, adc.database_name FROM sys.availability_databases_cluster adc JOIN sys.availability_groups ag ON ag.group_id = adc.group_id'
					})
			}
			if ($server.is_clustered)
			{
				$ha.cluster_nodes = @(Invoke-Section 'ha.clusternodes' { Invoke-Q $conn 'SELECT NodeName AS node_name, status_description, is_current_owner FROM sys.dm_os_cluster_nodes' })
			}
			$ha.log_shipping_primary = @(Invoke-Section 'ha.logshipping_primary' { Invoke-Q $conn 'SELECT primary_database FROM msdb.dbo.log_shipping_primary_databases' })
			$ha.log_shipping_secondary = @(Invoke-Section 'ha.logshipping_secondary' { Invoke-Q $conn 'SELECT secondary_database FROM msdb.dbo.log_shipping_secondary_databases' })
			$ha.mirroring = @(Invoke-Section 'ha.mirroring' {
					Invoke-Q $conn 'SELECT DB_NAME(database_id) AS database_name, mirroring_role_desc, mirroring_state_desc, mirroring_partner_name FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL'
				})
			$inst.high_availability = $ha

			#--- components, encryption, credentials
			$comp = [ordered]@{ }
			$mp = Invoke-Section 'components.dbmail' { Invoke-Q $conn 'SELECT COUNT(*) AS n FROM msdb.dbo.sysmail_profile' } | Select-Object -First 1
			$comp.database_mail_profiles = Get-Prop $mp 'n'
			$comp.credentials = @(Invoke-Section 'components.credentials' { Invoke-Q $conn 'SELECT name, credential_identity FROM sys.credentials' })
			$comp.proxies = @(Invoke-Section 'components.proxies' {
					Invoke-Q $conn 'SELECT p.name, c.credential_identity FROM msdb.dbo.sysproxies p LEFT JOIN sys.credentials c ON c.credential_id = p.credential_id'
				})
			$comp.certificates = @(Invoke-Section 'components.certificates' {
					Invoke-Q $conn "SELECT name, subject, expiry_date, pvt_key_encryption_type_desc, thumbprint FROM master.sys.certificates WHERE name NOT LIKE '##%'"
				})
			$comp.tde_databases = @($tde | ForEach-Object { [pscustomobject][ordered]@{ database = $_.database_name; encryption_state = $_.encryption_state; algorithm = $_.key_algorithm; key_length = $_.key_length } })
			$inst.components = $comp

			#--- server level security
			if (-not $SkipSecurity)
			{
				$logins = @(Invoke-Section 'security.logins' {
						Invoke-Q $conn @'
	SELECT p.name, p.type_desc, p.is_disabled, p.default_database_name, p.create_date, p.modify_date,
	 CAST(ISNULL(IS_SRVROLEMEMBER('sysadmin', p.name), 0) AS int) AS is_sysadmin,
	 STUFF((SELECT ',' + r.name FROM sys.server_role_members rm JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id WHERE rm.member_principal_id = p.principal_id FOR XML PATH('')), 1, 1, '') AS server_roles,
	 l.is_policy_checked, l.is_expiration_checked
	FROM sys.server_principals p LEFT JOIN sys.sql_logins l ON l.principal_id = p.principal_id
	WHERE p.type IN ('S', 'U', 'G', 'C', 'K', 'E', 'X') AND p.name NOT LIKE '##%##'
'@
					})
				$inst.logins = @($logins | ForEach-Object {
						[pscustomobject][ordered]@{
							name = $_.name; type = $_.type_desc; disabled = [bool]$_.is_disabled; default_database = $_.default_database_name
							created = $_.create_date; modified = $_.modify_date; is_sysadmin = ($_.is_sysadmin -eq 1); server_roles = $_.server_roles
							is_system = [bool]($_.name -match '^(sa|NT SERVICE\\.*|NT AUTHORITY\\.*)$')
							policy_checked = $_.is_policy_checked; expiration_checked = $_.is_expiration_checked
						}
					})
				$inst.server_permissions = @(Invoke-Section 'security.serverpermissions' {
						Invoke-Q $conn @'
	SELECT pr.name AS grantee, pe.permission_name, pe.state_desc FROM sys.server_permissions pe
	JOIN sys.server_principals pr ON pr.principal_id = pe.grantee_principal_id
	WHERE pe.class = 100 AND pr.type <> 'R' AND pr.name NOT LIKE '##%' AND pe.permission_name <> 'CONNECT SQL'
'@
					})
				$inst.db_users = @($dbUsers)
				$inst.db_roles = @($dbRoles)
				$inst.db_role_members = @($dbRoleMembers)
				$inst.db_permissions = @($dbPerms)
			}
		}
		finally { $conn.Dispose() }

		$inst.errors = @($script:Errs)
		return [pscustomobject]$inst
	}
	#endregion

	#region main
	$started = Get-Date
	$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
	$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
	if (-not $isAdmin) { Write-Warning 'Not running as administrator: volume, service and power plan data may be incomplete.' }

	Write-Information "sqmProviderInventory $ToolVersion on $env:COMPUTERNAME" -InformationAction Continue
	$script:Errs = New-Object System.Collections.ArrayList
	$hostData = Get-HostData

	# determine instances
	$targets = @()
	if ($SqlInstance)
	{
		foreach ($si in $SqlInstance) { $targets += [pscustomobject]@{ target = $si; name = $si } }
	}
	else
	{
		$svcRows = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' })
		foreach ($s in $svcRows)
		{
			if ($s.State -ne 'Running') { Write-Warning "Service $($s.Name) is $($s.State), skipped."; continue }
			if ($s.Name -eq 'MSSQLSERVER') { $targets += [pscustomobject]@{ target = $env:COMPUTERNAME; name = 'MSSQLSERVER' } }
			else { $targets += [pscustomobject]@{ target = ($env:COMPUTERNAME + '\' + $s.Name.Substring(6)); name = $s.Name.Substring(6) } }
		}
	}
	if ($targets.Count -eq 0) { Write-Warning 'No SQL Server instance found. Use -SqlInstance for clustered instances.' }

	$instances = @()
	foreach ($t in $targets)
	{
		Write-Information "  scanning instance $($t.target) ..." -InformationAction Continue
		$instances += Get-InstanceData -Target $t.target -InstanceName $t.name -HostVolumes $hostData.volumes
	}

	$finished = Get-Date
	$result = [ordered]@{
		schema_version = $SchemaVersion
		tool_version = $ToolVersion
		scan_started = $started.ToString('yyyy-MM-ddTHH:mm:ss')
		scan_finished = $finished.ToString('yyyy-MM-ddTHH:mm:ss')
		scan_duration_sec = [math]::Round(($finished - $started).TotalSeconds, 0)
		scanned_by = $identity.Name
		powershell_version = $PSVersionTable.PSVersion.ToString()
		options = [ordered]@{ include_agent_jobs = [bool]$IncludeAgentJobs; skip_security = [bool]$SkipSecurity; skip_per_database = [bool]$SkipPerDatabase; sample_seconds = $SampleSeconds; backup_history_days = $BackupHistoryDays }
		mapping = [ordered]@{ application = $Application; parent_group = $ParentGroup }
		host = $hostData
		instances = @($instances)
	}

	if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
	$baseName = '{0}_{1}' -f $env:COMPUTERNAME, $started.ToString('yyyyMMdd-HHmmss')
	$json = $result | ConvertTo-Json -Depth 10
	$utf8 = New-Object System.Text.UTF8Encoding($false)
	$htmlFile = Join-Path $OutputPath "ProviderInventory_$baseName.html"
	[System.IO.File]::WriteAllText($htmlFile, (ConvertTo-sqmProviderInventoryHtml -ScanJson @($json)), $utf8)
	$jsonFile = $null
	if ($SaveJson)
	{
		$jsonFile = Join-Path $OutputPath "$baseName.json"
		[System.IO.File]::WriteAllText($jsonFile, $json, $utf8)
	}

	$errCount = @($hostData.errors).Count
	foreach ($i in $instances) { $errCount += @($i.errors).Count; if (-not $i.connected) { $errCount++ } }
	if ($errCount -gt 0) { Write-Warning "$errCount section(s) could not be read. See the 'Pruefbericht' tab in the HTML file." }
	foreach ($i in $instances) { if (-not $i.connected) { Write-Warning "Instance $($i.connect_target) not reachable: $($i.connect_error)" } }
	Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

	return [pscustomobject][ordered]@{
		ComputerName  = $env:COMPUTERNAME
		Instances     = @($instances).Count
		DatabaseCount = @($instances | ForEach-Object { @($_.databases).Count } | Measure-Object -Sum).Sum
		ErrorCount    = $errCount
		DurationSec   = $result.scan_duration_sec
		HtmlFile      = $htmlFile
		JsonFile      = $jsonFile
	}
	#endregion
}
