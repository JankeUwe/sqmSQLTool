<#
.SYNOPSIS
    Gives a discovery service account (ServiceNow) read-only WMI/DCOM access on SQL Server hosts.

.DESCRIPTION
    The SQL role from Install-sqmDiscoveryRole covers what the scanner reads inside SQL Server.
    The rest of the scan (server, OS, SQL service, ports, instances) goes through WMI and
    needs rights on the Windows host, which a SQL role cannot provide.

    Per host this function handles:

    - Root\CIMv2 and every Root\Microsoft\SqlServer\ComputerManagement* namespace (found automatically):
      "Enable Account" and "Remote Enable" for the account, valid for the namespace and its sub-namespaces.
      "Execute Methods" is only added with -AllowExecuteMethods. Existing entries of other principals
      are left untouched.
    - Membership in the local group "Distributed COM Users" (remote DCOM access)
    - Remote Registry: only reported (state and start type), never changed. By default only
      Administrators and Backup Operators may reach the registry remotely.

    Modes:
      Check   (default) read-only, changes nothing
      Apply   sets the rights, idempotent
      Remove  takes the rights away again (rollback)

    Uses CIM cmdlets, so it runs under Windows PowerShell 5.1 and PowerShell 7. Needs local
    administrator rights on the target host.

.PARAMETER Account
    The service account, "DOMAIN\Name". The name must resolve on the machine running the function.

.PARAMETER ComputerName
    One or more hosts. Pipeline-capable. Default: current computer. For a cluster instance or an
    AG, give the node names, not the listener or the virtual network name.

.PARAMETER Mode
    Check (default), Apply or Remove.

.PARAMETER AllowExecuteMethods
    Additionally grants "Execute Methods". Not needed for read-only discovery.

.PARAMETER Credential
    Credential for remote hosts. Not used for the local computer.

.PARAMETER ContinueOnError
    Continue with the next host on error instead of throwing.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Set-sqmDiscoveryWmiAccess -Account "CORP\svc_servicenow" -ComputerName SQL01, SQL02

    Check only: shows per host and namespace what is missing.

.EXAMPLE
    Set-sqmDiscoveryWmiAccess -Account "CORP\svc_servicenow" -ComputerName SQL01 -Mode Apply -WhatIf
    Set-sqmDiscoveryWmiAccess -Account "CORP\svc_servicenow" -ComputerName SQL01 -Mode Apply

    Dry run first, then set.

.EXAMPLE
    Set-sqmDiscoveryWmiAccess -Account "CORP\svc_servicenow" -ComputerName SQL01 -Mode Remove

    Rollback.

.NOTES
    Requires: Invoke-sqmLogging. Run as local administrator of the target.
    Output: one object per host (Status OK / Fehler / WhatIf) with the namespace details.
    Related: Install-sqmDiscoveryRole (SQL side), Test-sqmDiscoveryAccess -CheckWmi (verification).
#>
function Set-sqmDiscoveryWmiAccess
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[ValidateNotNullOrEmpty()]
		[string]$Account,
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 1)]
		[string[]]$ComputerName = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[ValidateSet('Check', 'Apply', 'Remove')]
		[string]$Mode = 'Check',
		[Parameter(Mandatory = $false)]
		[switch]$AllowExecuteMethods,
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
		$def = Get-sqmDiscoveryDefinition
		$mask = [uint32]$def.WmiAccessMask
		if ($AllowExecuteMethods) { $mask = $mask -bor [uint32]$def.WmiMethodExecute }
		$sid = Get-sqmDiscoveryAccountSid -Account $Account
		$parts = $Account -split '\\', 2
		$adsiMember = if ($parts.Count -eq 2) { "WinNT://$($parts[0])/$($parts[1])" } else { "WinNT://$Account" }
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	}

	process
	{
		foreach ($computer in $ComputerName)
		{
			if ([string]::IsNullOrWhiteSpace($computer)) { continue }
			$computer = $computer.Trim()

			$row = [PSCustomObject]@{
				ComputerName        = $computer
				Account             = $Account
				Mode                = $Mode
				Namespaces          = @()
				DcomMember          = $null
				RemoteRegistryState = ''
				RemoteRegistryStart = ''
				Changed             = 0
				Ok                  = $false
				Status              = 'Error'
				Message             = ''
			}

			$session = $null
			try
			{
				$sessionParam = @{ ComputerName = $computer }
				if ($Credential) { $sessionParam.Credential = $Credential }
				$session = Open-sqmDiscoveryCimSession @sessionParam

				$changed = 0
				if ($Mode -ne 'Check')
				{
					foreach ($ns in (Get-sqmDiscoveryWmiNamespaceList -Definition $def -CimSession $session))
					{
						$cur = Get-sqmDiscoveryWmiAccessMask -Namespace $ns -SidString $sid.Sid.Value -CimSession $session
						$action = $null
						if ($Mode -eq 'Apply' -and ($null -eq $cur -or (($cur -band $mask) -ne $mask))) { $action = 'Apply' }
						if ($Mode -eq 'Remove' -and $null -ne $cur) { $action = 'Remove' }
						if ($action -and $PSCmdlet.ShouldProcess("$computer $ns", "$action WMI-Recht fuer $Account"))
						{
							Write-sqmDiscoveryWmiAccessEntry -Namespace $ns -AccountSid $sid -Action $action -AccessMask $mask -CimSession $session
							$changed++
						}
					}

					$isMember = Test-sqmDiscoveryDcomMember -ComputerName $computer -GroupName $def.DcomGroup -SidString $sid.Sid.Value
					if ($Mode -eq 'Apply' -and -not $isMember -and $PSCmdlet.ShouldProcess("$computer $($def.DcomGroup)", "Konto $Account hinzufuegen"))
					{
						(Get-sqmDiscoveryDcomGroup -ComputerName $computer -GroupName $def.DcomGroup).Add($adsiMember)
						$changed++
					}
					if ($Mode -eq 'Remove' -and $isMember -and $PSCmdlet.ShouldProcess("$computer $($def.DcomGroup)", "Konto $Account entfernen"))
					{
						(Get-sqmDiscoveryDcomGroup -ComputerName $computer -GroupName $def.DcomGroup).Remove($adsiMember)
						$changed++
					}
				}

				# Zustand (nach der Aenderung) immer frisch lesen, das ist das Ergebnis
				$state = Get-sqmDiscoveryWmiState -ComputerName $computer -Account $Account -Definition $def `
					-AllowExecuteMethods:$AllowExecuteMethods -Credential $Credential

				$row.Namespaces          = $state.Namespaces
				$row.DcomMember          = $state.DcomMember
				$row.RemoteRegistryState = $state.RemoteRegistryState
				$row.RemoteRegistryStart = $state.RemoteRegistryStart
				$row.Changed             = $changed

				if ($Mode -eq 'Remove')
				{
					$row.Ok = (-not $state.DcomMember) -and (@($state.Namespaces | Where-Object { $null -ne $_.AccessMask }).Count -eq 0)
				}
				else { $row.Ok = $state.Ok }

				$row.Status = if ($WhatIfPreference -and $Mode -ne 'Check') { 'WhatIf' }
							  elseif ($row.Ok) { 'OK' }
							  else { 'Fehler' }

				$missing = @($state.Namespaces | Where-Object { -not $_.Ok } | ForEach-Object { $_.Namespace })
				$row.Message = if ($Mode -eq 'Remove') { "Entfernt: $changed Aenderung(en)." }
							   elseif ($row.Ok) { "WMI/DCOM vollstaendig ($(@($state.Namespaces).Count) Namespace(s))." }
							   else
							   {
								   $bits = @()
								   if ($missing.Count -gt 0) { $bits += "WMI fehlt auf: $($missing -join ', ')" }
								   if (-not $state.DcomMember) { $bits += "nicht in '$($def.DcomGroup)'" }
								   $bits -join '; '
							   }
				if ($state.RemoteRegistryStart -eq 'Disabled' -or $state.RemoteRegistryState -ne 'Running')
				{
					$row.Message += " Hinweis: Remote Registry ist $($state.RemoteRegistryState) / $($state.RemoteRegistryStart); der Zugriff ist standardmaessig auf Administratoren und Backup Operators beschraenkt."
				}
				Invoke-sqmLogging -Message "[$computer] $Mode : $($row.Status). $($row.Message)" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "[$computer] $Mode fehlgeschlagen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$row.Status  = 'Error'
				$row.Message = $_.Exception.Message

				if ($EnableException) { throw }
				if (-not $ContinueOnError) { $allResults.Add($row); throw $_ }
			}
			finally
			{
				if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
			}

			$allResults.Add($row)
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Host(s), Modus $Mode." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
