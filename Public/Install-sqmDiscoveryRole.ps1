<#
.SYNOPSIS
    Creates the server role with read-only rights for an inventory/discovery account
    (ServiceNow Discovery) and optionally adds the service account to it.

.DESCRIPTION
    ServiceNow's "MSSql DB On Windows" pattern reads @@version, sys.configurations,
    sys.dm_exec_sessions, sys.dm_os_schedulers, SERVERPROPERTY and, for Always On,
    sys.dm_hadr_availability_group_states, sys.availability_groups,
    sys.availability_group_listeners and sys.availability_group_listener_ip_addresses.

    This function creates a user-defined server role (default SQL_ServiceNow_Discovery) and grants
    exactly what those queries need:

    - VIEW ANY DEFINITION      catalog views; without it sys.master_files and the AG catalog views
                               return ZERO rows instead of an error, the scan reports success with
                               empty sizes
    - VIEW ANY DATABASE        database list; granted explicitly so a hardening that revokes it from
                               public does not break the scan
    - VIEW SERVER STATE        DMVs (from SQL Server 2022 the finer VIEW SERVER PERFORMANCE STATE)

    Nothing else: no sysadmin, no db_owner, no db_datareader, no write access, no access to user data.

    The definition lives in one place (Get-sqmDiscoveryDefinition) and is also what
    Test-sqmDiscoveryAccess verifies, so setup and check cannot drift apart.

    The WMI/DCOM side (the part a SQL role cannot cover) is set by Set-sqmDiscoveryWmiAccess.

    Idempotent: running it again changes nothing that is already in place.

.PARAMETER SqlInstance
    One or more instances. Pipeline-capable. Default: current computer.

.PARAMETER LoginName
    The service account, e.g. "CORP\svc_servicenow". A missing Windows login is created, a missing
    SQL login is not (the function will not invent a password). Without this parameter only the
    role is created.

.PARAMETER RoleName
    Name of the server role. Default: SQL_ServiceNow_Discovery. One role per service account is
    recommended, not one shared role for several scanners.

.PARAMETER SqlCredential
    PSCredential for the DBA's own connection.

.PARAMETER ContinueOnError
    Continue with the next instance on error instead of throwing.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Install-sqmDiscoveryRole -SqlInstance SQL01 -LoginName "CORP\svc_servicenow" -WhatIf

    Shows what would be created and granted.

.EXAMPLE
    Get-Content .\sqlserver.txt | Install-sqmDiscoveryRole -LoginName "CORP\svc_servicenow"
    Test-sqmDiscoveryAccess -SqlInstance (Get-Content .\sqlserver.txt) -LoginName "CORP\svc_servicenow" `
        -ServerRole SQL_ServiceNow_Discovery -RequiredLevel Full

    Rolls the role out over a server list and verifies the result.

.NOTES
    Requires: dbatools, Invoke-sqmLogging. Needs sysadmin (or ALTER ANY SERVER ROLE plus the granted rights).
    Needs SQL Server 2012 or newer (user-defined server roles).
    Output: one object per instance (Status OK / Fehler / WhatIf).
#>
function Install-sqmDiscoveryRole
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false, Position = 1)]
		[string]$LoginName,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^[^\[\]\x00-\x1f]+$')]
		[string]$RoleName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$defaultRole = (Get-sqmDiscoveryDefinition).RoleName
		if ([string]::IsNullOrWhiteSpace($RoleName)) { $RoleName = $defaultRole }

		function _Q ([string]$Value) { return '[' + ($Value -replace '\]', ']]') + ']' }
		function _S ([string]$Value) { return $Value -replace "'", "''" }

		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			if ([string]::IsNullOrWhiteSpace($instance)) { continue }
			$instance = $instance.Trim()

			$row = [PSCustomObject]@{
				SqlInstance  = $instance
				RoleName     = $RoleName
				RoleCreated  = $false
				Granted      = @()
				LoginName    = $LoginName
				LoginCreated = $false
				MemberAdded  = $false
				Status       = 'Error'
				Message      = ''
			}

			try
			{
				$ver = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -As PSObject -EnableException `
					-Query "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion"
				$major = [int]$ver.MajorVersion
				if ($major -lt 11) { throw "SQL Server $major wird nicht unterstuetzt (benutzerdefinierte Serverrollen ab SQL Server 2012)." }

				$def = Get-sqmDiscoveryDefinition -MajorVersion $major

				if (-not $PSCmdlet.ShouldProcess($instance, "Rolle '$RoleName' mit $($def.ServerPermissions -join ', ') anlegen" + $(if ($LoginName) { " und '$LoginName' aufnehmen" } else { '' })))
				{
					$row.Status = 'WhatIf'
					$allResults.Add($row)
					continue
				}

				# Zustand lesen: was gibt es schon?
				$state = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -As PSObject -EnableException -Query @"
SELECT
  RoleExists  = CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(_S $RoleName)' AND type = 'R') THEN 1 ELSE 0 END,
  LoginExists = CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(_S $LoginName)' AND type IN ('U','G','S')) THEN 1 ELSE 0 END,
  IsMember    = CASE WHEN EXISTS (SELECT 1 FROM sys.server_role_members m
                                  JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
                                  JOIN sys.server_principals p ON p.principal_id = m.member_principal_id
                                  WHERE r.name = N'$(_S $RoleName)' AND p.name = N'$(_S $LoginName)') THEN 1 ELSE 0 END
"@

				if ($state.RoleExists -ne 1)
				{
					Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
						-Query "CREATE SERVER ROLE $(_Q $RoleName);"
					$row.RoleCreated = $true
				}

				# GRANT ist idempotent und stellt auch ein spaeter entzogenes Recht wieder her.
				foreach ($perm in $def.ServerPermissions)
				{
					Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
						-Query "GRANT $perm TO $(_Q $RoleName);"
				}
				$row.Granted = @($def.ServerPermissions)

				if ($LoginName)
				{
					if ($state.LoginExists -ne 1)
					{
						if ($LoginName -match '\\')
						{
							Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
								-Query "CREATE LOGIN $(_Q $LoginName) FROM WINDOWS;"
							$row.LoginCreated = $true
							$state.LoginExists = 1
						}
						else
						{
							throw "Login '$LoginName' existiert nicht und ist kein Windows-Konto (DOMAIN\Name). Ein SQL-Login wird nicht automatisch angelegt."
						}
					}
					if ($state.IsMember -ne 1 -or $row.LoginCreated)
					{
						Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
							-Query "IF NOT EXISTS (SELECT 1 FROM sys.server_role_members m JOIN sys.server_principals r ON r.principal_id = m.role_principal_id JOIN sys.server_principals p ON p.principal_id = m.member_principal_id WHERE r.name = N'$(_S $RoleName)' AND p.name = N'$(_S $LoginName)') ALTER SERVER ROLE $(_Q $RoleName) ADD MEMBER $(_Q $LoginName);"
						$row.MemberAdded = $true
					}
				}

				$row.Status  = 'OK'
				$row.Message = "Rolle '$RoleName' bereit (SQL Server $major)."
				Invoke-sqmLogging -Message "[$instance] $($row.Message) Neu: Rolle=$($row.RoleCreated), Login=$($row.LoginCreated), Mitglied=$($row.MemberAdded)." -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "[$instance] Einrichtung fehlgeschlagen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$row.Status  = 'Error'
				$row.Message = $_.Exception.Message

				if ($EnableException) { throw }
				if (-not $ContinueOnError) { $allResults.Add($row); throw $_ }
			}

			$allResults.Add($row)
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Instanz(en)." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
