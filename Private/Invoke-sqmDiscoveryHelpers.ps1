# =============================================================================
# Invoke-sqmDiscoveryHelpers.ps1
# Gemeinsame Bausteine fuer Install-sqmDiscoveryRole, Set-sqmDiscoveryWmiAccess und
# Test-sqmDiscoveryAccess. Die Definition, was ein Discovery-Konto braucht, steht NUR hier,
# damit Einrichten und Pruefen nicht auseinanderlaufen koennen.
# =============================================================================

function Get-sqmDiscoveryDefinition
{
	<#
	.SYNOPSIS
	    Liefert die Rechte, die ein read-only Discovery-Konto (z. B. ServiceNow) braucht.
	.DESCRIPTION
	    Einzige Quelle der Wahrheit fuer Install-sqmDiscoveryRole (setzt sie),
	    Set-sqmDiscoveryWmiAccess (setzt die WMI-Seite) und Test-sqmDiscoveryAccess (prueft sie).
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[int]$MajorVersion = 0
	)

	# Ab SQL Server 2022 gibt es VIEW SERVER PERFORMANCE STATE als feineres Recht fuer die DMVs.
	$statePermission = if ($MajorVersion -ge 16) { 'VIEW SERVER PERFORMANCE STATE' } else { 'VIEW SERVER STATE' }

	[PSCustomObject]@{
		RoleName          = 'SQL_ServiceNow_Discovery'
		# ViewAnyDefinition: Katalogsichten (sys.master_files, sys.availability_groups, Listener).
		#                    Ohne das kommen 0 Zeilen zurueck, kein Fehler.
		# ViewAnyDatabase:   Standardmaessig ueber public; explizit, damit eine Haertung nicht greift.
		# State:             sys.dm_exec_sessions, sys.dm_os_schedulers, sys.dm_hadr_availability_group_states
		ServerPermissions = @('VIEW ANY DEFINITION', 'VIEW ANY DATABASE', $statePermission)
		WmiNamespaces     = @('Root\CIMv2')
		WmiNamespaceRoot  = 'Root\Microsoft\SqlServer'
		WmiNamespaceLike  = 'ComputerManagement*'
		# Enable Account (0x1) + Remote Enable (0x20); Execute Methods (0x2) nur auf Wunsch
		WmiAccessMask     = [uint32]0x21
		WmiMethodExecute  = [uint32]0x2
		DcomGroup         = 'Distributed COM Users'
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
