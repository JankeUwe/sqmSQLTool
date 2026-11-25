# =============================================================================
# Invoke-sqmDiscoveryHelpers.ps1
# Gemeinsame Bausteine fuer Install-sqmDiscoveryRole, Set-sqmDiscoveryWmiAccess und
# Test-sqmDiscoveryAccess. Die Definition, was ein Discovery-Konto braucht, steht NUR hier,
# damit Einrichten und Pruefen nicht auseinanderlaufen koennen.
# =============================================================================

function Get-sqmDiscoveryProductList
{
	<# Die angebotenen Produkte mit ihrem Standard-Rollennamen. Eine freie Eingabe von -RoleName
	   bleibt moeglich, die Namen hier sind nur das Angebot. Die Namen sind konfigurierbar
	   (Set-sqmConfig -DiscoveryRoleNameServiceNow / -Qualys / -SCOM, config.json), Standard:
	   SNOWDISCO, Qualis_Scan, SCOM_HealthService. #>
	[CmdletBinding()]
	param ()

	$defaults = [ordered]@{ ServiceNow = 'SNOWDISCO'; Qualys = 'Qualis_Scan'; SCOM = 'SCOM_HealthService' }
	foreach ($product in $defaults.Keys)
	{
		$name = $null
		if ($script:sqmModuleConfig) { $name = [string]$script:sqmModuleConfig["DiscoveryRoleName$product"] }
		if ([string]::IsNullOrWhiteSpace($name)) { $name = $defaults[$product] }
		[PSCustomObject]@{ Product = $product; RoleName = $name.Trim() }
	}
}

function Get-sqmDiscoveryDefinition
{
	<#
	.SYNOPSIS
	    Liefert die Rechte, die ein read-only Scan-Konto eines Produkts (ServiceNow, Qualys, SCOM) braucht.
	.DESCRIPTION
	    Einzige Quelle der Wahrheit fuer Install-sqmDiscoveryRole (setzt sie),
	    Set-sqmDiscoveryWmiAccess (setzt die WMI-Seite) und Test-sqmDiscoveryAccess (prueft sie).

	    Quellen: ServiceNow = gemessene Abfragen des Patterns "MSSql DB On Windows"; Qualys = "MS SQL Server
	    2005-2019" Authenticated Scanning (Restricted/Read-only, Schritt 3b mit den optionalen Rechten und
	    dem msdb-Teil); SCOM = Microsoft Learn "SQL Server Management Pack: Low-Privilege Monitoring"
	    (Agent-Skript).

	    DatabaseGrants: je Datenbank die GRANTs an die gleichnamige Datenbankrolle. DatabaseScope 'Eligible'
	    (SCOM) heisst: Benutzer und Rolle in jeder online, schreibbaren Datenbank ausser tempdb, bei einer
	    AG nur auf dem Primary.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[int]$MajorVersion = 0,
		[Parameter(Mandatory = $false)]
		[ValidateSet('ServiceNow', 'Qualys', 'SCOM')]
		[string]$Product = 'ServiceNow'
	)

	$roleName = (Get-sqmDiscoveryProductList | Where-Object { $_.Product -eq $Product }).RoleName
	$databaseGrants = @()
	$databaseScope = 'None'
	$msdbRoleMembership = @()

	switch ($Product)
	{
		'ServiceNow'
		{
			# Ab SQL Server 2022 gibt es VIEW SERVER PERFORMANCE STATE als feineres Recht fuer die DMVs.
			$statePermission = if ($MajorVersion -ge 16) { 'VIEW SERVER PERFORMANCE STATE' } else { 'VIEW SERVER STATE' }
			# ViewAnyDefinition: Katalogsichten (sys.master_files, sys.availability_groups, Listener).
			#                    Ohne das kommen 0 Zeilen zurueck, kein Fehler.
			# ViewAnyDatabase:   Standardmaessig ueber public; explizit, damit eine Haertung nicht greift.
			# State:             sys.dm_exec_sessions, sys.dm_os_schedulers, sys.dm_hadr_availability_group_states
			$serverPermissions = @('VIEW ANY DEFINITION', 'VIEW ANY DATABASE', $statePermission)
		}
		'Qualys'
		{
			# Qualys nennt VIEW SERVER STATE ausdruecklich (Control 10615); es schliesst die feinere
			# Berechtigung ein, daher gilt es auch ab SQL Server 2022.
			$serverPermissions = @('ALTER TRACE', 'VIEW SERVER STATE', 'VIEW ANY DEFINITION')
			$databaseScope = 'Fixed'
			$databaseGrants = @(
				[PSCustomObject]@{
					Database = 'master'
					Grants   = @(
						'SELECT ON sys.all_objects', 'SELECT ON sys.configurations', 'SELECT ON sys.databases',
						'SELECT ON sys.database_permissions', 'SELECT ON sys.syslogins', 'SELECT ON sys.trace_events',
						'SELECT ON sys.traces', 'SELECT ON sys.sysaltfiles', 'SELECT ON sys.server_principals',
						'EXECUTE ON sys.xp_loginconfig'
					)
				}
				[PSCustomObject]@{
					Database = 'msdb'
					Grants   = @(
						'EXECUTE ON dbo.sp_enum_login_for_proxy', 'EXECUTE ON dbo.sp_enum_proxy_for_subsystem',
						'SELECT ON dbo.sysproxies', 'SELECT ON dbo.sysproxylogin'
					)
				}
			)
		}
		'SCOM'
		{
			$serverPermissions = @('VIEW ANY DATABASE', 'VIEW ANY DEFINITION', 'VIEW SERVER STATE')
			$databaseScope = 'Eligible'
			$databaseGrants = @(
				[PSCustomObject]@{
					Database = 'master'
					Grants   = @(
						'EXECUTE ON sys.xp_readerrorlog', 'EXECUTE ON sys.xp_instance_regread',
						'SELECT ON sys.indexes', 'SELECT ON sys.tables', 'SELECT ON sys.dm_db_index_physical_stats'
					)
				}
				[PSCustomObject]@{
					Database = 'msdb'
					Grants   = @(
						'SELECT ON dbo.sysjobschedules', 'SELECT ON dbo.sysschedules', 'SELECT ON dbo.syscategories',
						'SELECT ON dbo.sysjobs_view', 'SELECT ON dbo.sysjobactivity', 'SELECT ON dbo.sysjobhistory',
						'SELECT ON dbo.syssessions', 'SELECT ON dbo.log_shipping_primary_databases',
						'SELECT ON dbo.log_shipping_secondary_databases', 'SELECT ON dbo.log_shipping_monitor_history_detail',
						'SELECT ON dbo.log_shipping_monitor_secondary', 'SELECT ON dbo.log_shipping_monitor_primary',
						'EXECUTE ON dbo.sp_help_job', 'EXECUTE ON dbo.agent_datetime', 'EXECUTE ON dbo.SQLAGENT_SUSER_SNAME'
					)
				}
			)
			# Die Datenbankrolle wird zusaetzlich Mitglied dieser festen msdb-Rolle.
			$msdbRoleMembership = @('SQLAgentReaderRole')
		}
	}

	[PSCustomObject]@{
		Product            = $Product
		RoleName           = $roleName
		ServerPermissions  = $serverPermissions
		DatabaseScope      = $databaseScope
		DatabaseGrants     = $databaseGrants
		MsdbRoleMembership = $msdbRoleMembership
		WmiNamespaces      = @('Root\CIMv2')
		WmiNamespaceRoot   = 'Root\Microsoft\SqlServer'
		WmiNamespaceLike   = 'ComputerManagement*'
		# Enable Account (0x1) + Remote Enable (0x20); Execute Methods (0x2) nur auf Wunsch
		WmiAccessMask      = [uint32]0x21
		WmiMethodExecute   = [uint32]0x2
		DcomGroup          = 'Distributed COM Users'
	}
}

function Get-sqmDiscoveryPolicyBlocker
{
	<# Prueft, ob Policy-Based Management CREATE LOGIN / ALTER SERVER ROLE / GRANT blockieren kann:
	   aktivierte Policies mit "On change: prevent" (execution_mode 1) und der Server-Trigger
	   syspolicy_server_trigger. Rein T-SQL (die dbatools-PBM-Befehle laufen unter PowerShell 7 nicht).
	   Liefert $null, wenn PBM auf der Instanz nicht lesbar ist. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	try
	{
		$p = @{ SqlInstance = $SqlInstance; Database = 'master'; As = 'PSObject'; EnableException = $true }
		if ($SqlCredential) { $p.SqlCredential = $SqlCredential }
		$policies = @(Invoke-DbaQuery @p -Query "SELECT name FROM msdb.dbo.syspolicy_policies WHERE is_enabled = 1 AND execution_mode = 1 ORDER BY name;")
		$trigger = @(Invoke-DbaQuery @p -Query "SELECT name, is_disabled FROM sys.server_triggers WHERE name = N'syspolicy_server_trigger';")
		$triggerActive = ($trigger.Count -gt 0 -and [int]$trigger[0].is_disabled -eq 0)
		[PSCustomObject]@{
			Policies      = @($policies | ForEach-Object { [string]$_.name })
			TriggerActive = $triggerActive
			Blocking      = ($policies.Count -gt 0 -and $triggerActive)
		}
	}
	catch
	{
		Write-Verbose "PBM-Zustand auf '$SqlInstance' nicht lesbar: $($_.Exception.Message)"
		return $null
	}
}

function Get-sqmDiscoveryHostName
{
	<# Rechnername aus einem Instanznamen (HOST, HOST\INST, HOST,1433, tcp:HOST). #>
	[CmdletBinding()]
	param ([Parameter(Mandatory = $true)][string]$SqlInstance)

	$name = $SqlInstance.Trim() -replace '^(tcp|np|lpc):', ''
	$name = ($name -split '[\\,]')[0]
	if ($name -in @('.', '(local)', 'localhost')) { return $env:COMPUTERNAME }
	return $name
}

function Resolve-sqmDiscoveryReplicaInstance
{
	<#
	Loest einen Knoten oder Listener einer AlwaysOn-Verfuegbarkeitsgruppe in ALLE Replikate auf.
	Die Katalogsichten sys.availability_replicas / sys.availability_group_listeners stehen auf
	jedem Replikat und ueber den Listener zur Verfuegung. Wird ein Listener angegeben, werden nur
	die Replikate seiner Gruppe zurueckgegeben, sonst alle Gruppen der Instanz.
	Ohne HADR, ohne Gruppe, mit -SingleNode oder wenn die Abfrage scheitert, kommt die angegebene
	Instanz unveraendert zurueck (der Aufrufer meldet einen Verbindungsfehler dann wie bisher).
	Der vom Benutzer angegebene Name bleibt erhalten (FQDN, Port), wenn er ein Replikat bezeichnet.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string[]]$SqlInstance,
		[Parameter(Mandatory = $false)][System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)][switch]$SingleNode
	)

	$result = [System.Collections.Generic.List[string]]::new()
	$query = @"
SET NOCOUNT ON;
IF ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS int), 0) = 1
SELECT ag.name AS AgName, ar.replica_server_name AS ReplicaServerName, l.dns_name AS ListenerName
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.availability_group_listeners l ON l.group_id = ag.group_id;
"@

	foreach ($inst in $SqlInstance)
	{
		if ([string]::IsNullOrWhiteSpace($inst)) { continue }
		$inst = $inst.Trim()
		$expanded = @($inst)

		if (-not $SingleNode)
		{
			try
			{
				$rows = @(Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -Database master -As PSObject -EnableException -Query $query |
						Where-Object { $_.PSObject.Properties['ReplicaServerName'] -and -not [string]::IsNullOrWhiteSpace([string]$_.ReplicaServerName) })
				if ($rows.Count -gt 0)
				{
					$givenHost = Get-sqmDiscoveryHostName -SqlInstance $inst
					$givenInst = ''
					$tail = ($inst -replace '^(tcp|np|lpc):', '') -split '\\', 2
					if ($tail.Count -gt 1) { $givenInst = ($tail[1] -split ',')[0] }

					# Listener angegeben: nur die Gruppe dieses Listeners
					$byListener = @($rows | Where-Object {
							$_.ListenerName -and ($givenHost -ieq [string]$_.ListenerName -or $givenHost -like ([string]$_.ListenerName + '.*'))
						})
					if ($byListener.Count -gt 0) { $rows = $byListener }

					$expanded = @()
					foreach ($name in @($rows | ForEach-Object { [string]$_.ReplicaServerName } | Select-Object -Unique))
					{
						$parts = $name -split '\\', 2
						$repHost = $parts[0]
						$repInst = if ($parts.Count -gt 1) { $parts[1] } else { '' }
						$isGiven = ($givenHost -ieq $repHost -or $givenHost -like "$repHost.*") -and ($givenInst -ieq $repInst)
						$expanded += $(if ($isGiven) { $inst } else { $name })
					}
					if ($expanded.Count -eq 0) { $expanded = @($inst) }
				}
			}
			catch
			{
				Write-Verbose "Replikate von '$inst' nicht lesbar, nur diese Instanz wird verwendet: $($_.Exception.Message)"
				$expanded = @($inst)
			}
		}

		foreach ($e in $expanded)
		{
			if (-not ($result | Where-Object { $_ -ieq $e })) { $result.Add($e) }
		}
	}

	return @($result)
}

function Get-sqmDiscoveryAccountSid
{
	[CmdletBinding()]
	param ([Parameter(Mandatory = $true)][string]$Account)

	$ntAccount = New-Object System.Security.Principal.NTAccount($Account)
	$sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
	$bin = New-Object byte[] $sid.BinaryLength
	$sid.GetBinaryForm($bin, 0)
	[PSCustomObject]@{ Sid = $sid; Binary = $bin }
}

function Resolve-sqmDiscoveryLoginName
{
	<# Bringt einen Kontonamen ohne Domaene (svc_x oder svc_x@corp.local) in die Form DOMAIN\Name, indem er
	   auf dem ausfuehrenden Rechner ueber die SID aufgeloest wird. Gibt $null zurueck, wenn das kein
	   Windows-Konto ist (dann nie raten). #>
	[CmdletBinding()]
	param ([Parameter(Mandatory = $true)][string]$Account)

	try
	{
		$sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier])
		return $sid.Translate([System.Security.Principal.NTAccount]).Value
	}
	catch { return $null }
}

function Find-sqmDiscoveryLogin
{
	<# Findet das Login zu einem Namen. Mit Backslash gilt der Name, wie er ist. Ohne Backslash (svc_x oder
	   svc_x@corp.local): zuerst genau dieser Name auf dem Server, sonst genau ein Login der Form
	   DOMAIN\svc_x, sonst die Aufloesung als Windows-Konto auf diesem Rechner.
	   Source: AsGiven, Exact, Server, Resolved, Ambiguous (mehrere DOMAIN\svc_x, es wird nicht geraten)
	   oder None. Install-sqmDiscoveryRole und Test-sqmDiscoveryAccess nutzen dieselbe Suche. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$SqlInstance,
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)][string]$Name
	)

	$given = $Name.Trim()
	if ($given -match '\\') { return [PSCustomObject]@{ Name = $given; Source = 'AsGiven'; Candidates = @() } }

	$lit = $given -replace "'", "''"
	$p = @{ SqlInstance = $SqlInstance; Database = 'master'; As = 'PSObject'; EnableException = $true }
	if ($SqlCredential) { $p.SqlCredential = $SqlCredential }
	$candidates = @(Invoke-DbaQuery @p -Query "SELECT name FROM sys.server_principals WHERE type IN ('U','G','S') AND (name = N'$lit' OR RIGHT(name, $($given.Length + 1)) = N'\$lit')" |
			Where-Object { $_ -and $_.name } | ForEach-Object { [string]$_.name })

	if ($candidates -contains $given) { return [PSCustomObject]@{ Name = $given; Source = 'Exact'; Candidates = $candidates } }
	if ($candidates.Count -eq 1) { return [PSCustomObject]@{ Name = $candidates[0]; Source = 'Server'; Candidates = $candidates } }
	if ($candidates.Count -gt 1) { return [PSCustomObject]@{ Name = $given; Source = 'Ambiguous'; Candidates = $candidates } }

	$resolved = Resolve-sqmDiscoveryLoginName -Account $given
	if ($resolved) { return [PSCustomObject]@{ Name = $resolved; Source = 'Resolved'; Candidates = @() } }
	return [PSCustomObject]@{ Name = $given; Source = 'None'; Candidates = @() }
}

function Open-sqmDiscoveryCimSession
{
	<# $null fuer den lokalen Rechner (kein DCOM/WinRM noetig), sonst eine CimSession. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$ComputerName,
		[System.Management.Automation.PSCredential]$Credential
	)

	if ($ComputerName -in @($env:COMPUTERNAME, 'localhost', '.')) { return $null }
	$opt = New-CimSessionOption -Protocol Dcom
	$p = @{ ComputerName = $ComputerName; SessionOption = $opt; ErrorAction = 'Stop' }
	if ($Credential) { $p.Credential = $Credential }
	New-CimSession @p
}

function Get-sqmDiscoveryWmiNamespaceList
{
	<# Root\CIMv2 plus alle Root\Microsoft\SqlServer\ComputerManagement*, die auf dem Rechner existieren. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]$Definition,
		[Microsoft.Management.Infrastructure.CimSession]$CimSession
	)

	$list = [System.Collections.Generic.List[string]]::new()
	foreach ($n in $Definition.WmiNamespaces) { $list.Add($n) }

	$p = @{ Namespace = $Definition.WmiNamespaceRoot; ClassName = '__NAMESPACE'; ErrorAction = 'Stop' }
	if ($CimSession) { $p.CimSession = $CimSession }
	try
	{
		foreach ($ns in @(Get-CimInstance @p | Where-Object { $_.Name -like $Definition.WmiNamespaceLike }))
		{
			$list.Add("$($Definition.WmiNamespaceRoot)\$($ns.Name)")
		}
	}
	catch
	{
		Write-Verbose "Namespace $($Definition.WmiNamespaceRoot) nicht lesbar (kein SQL WMI Provider?): $($_.Exception.Message)"
	}
	return $list.ToArray()
}

function Get-sqmDiscoveryWmiSecurity
{
	<# Liest den Security Descriptor eines WMI-Namespace. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$Namespace,
		[Microsoft.Management.Infrastructure.CimSession]$CimSession
	)

	$p = @{ Namespace = $Namespace; ClassName = '__SystemSecurity'; MethodName = 'GetSecurityDescriptor'; ErrorAction = 'Stop' }
	if ($CimSession) { $p.CimSession = $CimSession }
	$res = Invoke-CimMethod @p
	if ($res.ReturnValue -ne 0) { throw "GetSecurityDescriptor auf '$Namespace' lieferte ReturnValue $($res.ReturnValue)." }
	return $res.Descriptor
}

function Get-sqmDiscoveryWmiAccessMask
{
	<# Zugriffsmaske des (Allow-)Eintrags fuer eine SID im Namespace, $null wenn es keinen gibt. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$Namespace,
		[Parameter(Mandatory = $true)][string]$SidString,
		[Microsoft.Management.Infrastructure.CimSession]$CimSession
	)

	$sd = Get-sqmDiscoveryWmiSecurity -Namespace $Namespace -CimSession $CimSession
	foreach ($ace in @($sd.DACL))
	{
		if ($ace.AceType -eq 0 -and $ace.Trustee.SIDString -eq $SidString) { return [uint32]$ace.AccessMask }
	}
	return $null
}

function Write-sqmDiscoveryWmiAccessEntry
{
	<# Setzt (Apply) oder entfernt (Remove) den Allow-Eintrag der SID im Namespace. Andere Eintraege bleiben unveraendert. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$Namespace,
		[Parameter(Mandatory = $true)]$AccountSid,
		[Parameter(Mandatory = $true)][ValidateSet('Apply', 'Remove')][string]$Action,
		[Parameter(Mandatory = $true)][uint32]$AccessMask,
		[Microsoft.Management.Infrastructure.CimSession]$CimSession
	)

	$sd = Get-sqmDiscoveryWmiSecurity -Namespace $Namespace -CimSession $CimSession
	$keep = @(@($sd.DACL) | Where-Object { -not ($_.AceType -eq 0 -and $_.Trustee.SIDString -eq $AccountSid.Sid.Value) })

	if ($Action -eq 'Apply')
	{
		$trustee = New-CimInstance -ClientOnly -Namespace 'root/cimv2' -ClassName 'Win32_Trustee' -Property @{
			SID = [byte[]]$AccountSid.Binary
			SidLength = [uint32]$AccountSid.Binary.Length
		}
		# AceFlags 0x2 = CONTAINER_INHERIT: gilt fuer den Namespace und Unter-Namespaces
		$ace = New-CimInstance -ClientOnly -Namespace 'root/cimv2' -ClassName 'Win32_ACE' -Property @{
			AccessMask = [uint32]$AccessMask
			AceFlags   = [uint32]2
			AceType    = [uint32]0
			Trustee    = [Microsoft.Management.Infrastructure.CimInstance]$trustee
		}
		$keep += $ace
	}

	$sd.DACL = [Microsoft.Management.Infrastructure.CimInstance[]]$keep
	$p = @{ Namespace = $Namespace; ClassName = '__SystemSecurity'; MethodName = 'SetSecurityDescriptor'
		Arguments = @{ Descriptor = $sd }; ErrorAction = 'Stop' }
	if ($CimSession) { $p.CimSession = $CimSession }
	$res = Invoke-CimMethod @p
	if ($res.ReturnValue -ne 0) { throw "SetSecurityDescriptor auf '$Namespace' lieferte ReturnValue $($res.ReturnValue)." }
}

function Get-sqmDiscoveryDcomGroup
{
	[CmdletBinding()]
	param ([Parameter(Mandatory = $true)][string]$ComputerName, [Parameter(Mandatory = $true)][string]$GroupName)
	[ADSI]"WinNT://$ComputerName/$GroupName,group"
}

function Test-sqmDiscoveryDcomMember
{
	<# Ist die SID Mitglied der lokalen DCOM-Gruppe? Vergleich ueber die SID, nicht ueber den Namen. #>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$ComputerName,
		[Parameter(Mandatory = $true)][string]$GroupName,
		[Parameter(Mandatory = $true)][string]$SidString
	)

	$group = Get-sqmDiscoveryDcomGroup -ComputerName $ComputerName -GroupName $GroupName
	foreach ($m in @($group.Invoke('Members')))
	{
		$bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
		if ((New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value -eq $SidString) { return $true }
	}
	return $false
}

function Get-sqmDiscoveryWmiState
{
	<#
	.SYNOPSIS
	    Liest den WMI/DCOM-Stand eines Rechners fuer ein Konto (rein lesend).
	.DESCRIPTION
	    Liefert je Namespace die Zugriffsmaske, die DCOM-Gruppenmitgliedschaft und den Remote-Registry-Dienst.
	    Wird von Set-sqmDiscoveryWmiAccess (Check/Apply/Remove) und Test-sqmDiscoveryAccess (-CheckWmi) benutzt.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)][string]$ComputerName,
		[Parameter(Mandatory = $true)][string]$Account,
		[Parameter(Mandatory = $true)]$Definition,
		[switch]$AllowExecuteMethods,
		[System.Management.Automation.PSCredential]$Credential
	)

	$sid = Get-sqmDiscoveryAccountSid -Account $Account
	$mask = [uint32]$Definition.WmiAccessMask
	if ($AllowExecuteMethods) { $mask = $mask -bor [uint32]$Definition.WmiMethodExecute }

	$session = $null
	try
	{
		$session = Open-sqmDiscoveryCimSession -ComputerName $ComputerName -Credential $Credential

		$namespaces = foreach ($ns in (Get-sqmDiscoveryWmiNamespaceList -Definition $Definition -CimSession $session))
		{
			$current = Get-sqmDiscoveryWmiAccessMask -Namespace $ns -SidString $sid.Sid.Value -CimSession $session
			# "ok" heisst: mindestens die geforderten Bits sind gesetzt (mehr Rechte sind kein Fehler hier)
			[PSCustomObject]@{
				Namespace  = $ns
				AccessMask = $current
				Required   = $mask
				Ok         = ($null -ne $current -and (($current -band $mask) -eq $mask))
			}
		}

		$dcom = Test-sqmDiscoveryDcomMember -ComputerName $ComputerName -GroupName $Definition.DcomGroup -SidString $sid.Sid.Value

		$rrState = ''; $rrStart = ''
		try
		{
			$p = @{ ClassName = 'Win32_Service'; Filter = "Name='RemoteRegistry'"; ErrorAction = 'Stop' }
			if ($session) { $p.CimSession = $session }
			$rr = Get-CimInstance @p
			if ($rr) { $rrState = [string]$rr.State; $rrStart = [string]$rr.StartMode }
		}
		catch { Write-Verbose "Remote Registry auf '$ComputerName' nicht lesbar: $($_.Exception.Message)" }

		[PSCustomObject]@{
			ComputerName        = $ComputerName
			Namespaces          = @($namespaces)
			DcomMember          = $dcom
			RemoteRegistryState = $rrState
			RemoteRegistryStart = $rrStart
			Ok                  = ($dcom -and (@($namespaces | Where-Object { -not $_.Ok }).Count -eq 0) -and (@($namespaces).Count -gt 0))
		}
	}
	finally
	{
		if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
	}
}
