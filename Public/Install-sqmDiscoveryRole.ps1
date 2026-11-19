<#
.SYNOPSIS
    Creates the role with read-only rights for a scan/inventory account of ServiceNow, Qualys or SCOM
    and optionally adds the service account to it.

.DESCRIPTION
    One function for three products. -Product selects what is granted, the rights come from
    Get-sqmDiscoveryDefinition, which is also what Test-sqmDiscoveryAccess verifies, so setup and
    check cannot drift apart.

    ServiceNow (role SnowDisco)
        Server role with VIEW ANY DEFINITION, VIEW ANY DATABASE and VIEW SERVER [PERFORMANCE] STATE
        (the queries of the "MSSql DB On Windows" pattern; without VIEW ANY DEFINITION sys.master_files
        and the AG catalog views return ZERO rows instead of an error).

    Qualys (role Qualis_Scan)
        Restricted/read-only scan account of the Qualys document "MS SQL Server 2005-2019": server role
        with ALTER TRACE, VIEW SERVER STATE, VIEW ANY DEFINITION; in master a database role with SELECT
        on the nine catalog views of step 3b (including sys.trace_events and sys.traces) and EXECUTE on
        sys.xp_loginconfig; in msdb EXECUTE on sp_enum_login_for_proxy and sp_enum_proxy_for_subsystem
        and SELECT on sysproxies and sysproxylogin.

    SCOM (role SCOM_Scan)
        Low-privilege monitoring of the SQL Server management pack (Microsoft Learn, agent script):
        server role with VIEW ANY DATABASE, VIEW ANY DEFINITION, VIEW SERVER STATE; in master EXECUTE on
        xp_readerrorlog and xp_instance_regread and SELECT on sys.indexes, sys.tables and
        sys.dm_db_index_physical_stats; in msdb the job, schedule and log shipping tables, three
        procedures and membership of SQLAgentReaderRole; a user and a database role in every online,
        writable database (on an availability group only where the replica is primary).

    The role name is offered per product (SnowDisco, Qualis_Scan, SCOM_Scan) and can be replaced by any
    name with -RoleName. The same name is used for the server role and for the database roles. If
    -RoleName is one of the three offered names and -Product is not given, the product follows from the
    name; for a free name without -Product the ServiceNow rights apply.

    Policy-Based Management: an enabled policy with evaluation mode "On change: prevent" makes the
    built-in server trigger syspolicy_server_trigger roll back CREATE LOGIN, ALTER SERVER ROLE and
    GRANT. The function checks this first (policy names are reported in BlockingPolicies). If such a
    policy is active it disables only that trigger for the duration of the change and enables it again
    in a finally block, even if the change fails. The policies themselves are not touched. Use
    -SkipPolicyHandling to leave PBM alone.

    Nothing else is granted: no sysadmin, no db_owner, no db_datareader, no write access.
    The WMI/DCOM side (the part a SQL role cannot cover) is set by Set-sqmDiscoveryWmiAccess.

    Idempotent: running it again changes nothing that is already in place.

.PARAMETER SqlInstance
    One or more instances. Pipeline-capable. Default: current computer.

.PARAMETER LoginName
    The service account, e.g. "CORP\svc_servicenow". A missing Windows login is created, a missing
    SQL login is not (the function will not invent a password). A name without domain
    ("svc_servicenow" or "svc_servicenow@corp.local") is resolved as a Windows account on the
    computer running the function and created as DOMAIN\Name; if it does not resolve, the function
    stops and asks for DOMAIN\Name. Leading and trailing blanks are removed. Without this
    parameter only the roles and rights are created.

.PARAMETER Product
    ServiceNow, Qualys or SCOM. Default: derived from -RoleName, else ServiceNow.

.PARAMETER RoleName
    Name of the role. Offered: SnowDisco, Qualis_Scan, SCOM_Scan; any other name is accepted.
    Default: the name of the product. One role per service account is recommended.

.PARAMETER SqlCredential
    PSCredential for the DBA's own connection.

.PARAMETER SkipPolicyHandling
    Do not check or switch the Policy-Based Management trigger.

.PARAMETER ContinueOnError
    Continue with the next instance on error instead of throwing.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Install-sqmDiscoveryRole -SqlInstance SQL01 -Product Qualys -LoginName "CORP\QUALYS_SCAN" -WhatIf

    Shows what would be created and granted for the Qualys scan account.

.EXAMPLE
    Install-sqmDiscoveryRole -SqlInstance SQL01 -RoleName SCOM_Scan -LoginName "CORP\svc_scom_sql"

    The role name selects the SCOM rights.

.EXAMPLE
    Install-sqmDiscoveryRole -SqlInstance SQL01 -Product Qualys -RoleName Scan_Compliance -LoginName "CORP\QUALYS_SCAN"

    Qualys rights under a free role name.

.NOTES
    Requires: dbatools, Invoke-sqmLogging. Needs sysadmin.
    Needs SQL Server 2012 or newer (user-defined server roles).
    Output: one object per instance (Status OK / Warnung / Error / WhatIf).
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
		[ValidateSet('ServiceNow', 'Qualys', 'SCOM')]
		[string]$Product,
		[Parameter(Mandatory = $false)]
		[ArgumentCompleter({ param ($cmd, $param, $word) $null = $cmd, $param; 'SnowDisco', 'Qualis_Scan', 'SCOM_Scan' | Where-Object { $_ -like "$word*" } })]
		[ValidatePattern('^[^\[\]\x00-\x1f]+$')]
		[string]$RoleName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$SkipPolicyHandling,
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

		# Leerzeichen am Rand (Copy and Paste) wuerden sonst als Teil des Namens behandelt
		if ($LoginName) { $LoginName = $LoginName.Trim() }
		if ($RoleName) { $RoleName = $RoleName.Trim() }

		# Produkt: ausdruecklich, sonst aus dem Rollennamen (einer der drei angebotenen), sonst ServiceNow
		if (-not $Product)
		{
			$byName = Get-sqmDiscoveryProductList | Where-Object { $_.RoleName -eq $RoleName } | Select-Object -First 1
			$Product = if ($byName) { $byName.Product } else { 'ServiceNow' }
		}
		if ([string]::IsNullOrWhiteSpace($RoleName)) { $RoleName = (Get-sqmDiscoveryDefinition -Product $Product).RoleName }

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
				SqlInstance         = $instance
				Product             = $Product
				RoleName            = $RoleName
				RoleCreated         = $false
				Granted             = @()
				DatabasesConfigured = @()
				LoginName           = $LoginName
				LoginCreated        = $false
				MemberAdded         = $false
				BlockingPolicies    = @()
				PolicyTriggerDisabled = $false
				Warnings            = @()
				Status              = 'Error'
				Message             = ''
			}

			$triggerDisabled = $false
			try
			{
				$ver = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -As PSObject -EnableException `
					-Query "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion"
				$major = [int]$ver.MajorVersion
				if ($major -lt 11) { throw "SQL Server $major wird nicht unterstuetzt (benutzerdefinierte Serverrollen ab SQL Server 2012)." }

				$def = Get-sqmDiscoveryDefinition -MajorVersion $major -Product $Product

				if (-not $PSCmdlet.ShouldProcess($instance, "Rolle '$RoleName' ($Product) mit $($def.ServerPermissions -join ', ') anlegen" + $(if ($LoginName) { " und '$LoginName' aufnehmen" } else { '' })))
				{
					$row.Status = 'WhatIf'
					$allResults.Add($row)
					continue
				}

				# Policy-Based Management vorab pruefen: eine aktive "On change: prevent"-Policy laesst den
				# Server-Trigger syspolicy_server_trigger CREATE LOGIN / ALTER SERVER ROLE / GRANT zurueckrollen.
				if (-not $SkipPolicyHandling)
				{
					$pbm = Get-sqmDiscoveryPolicyBlocker -SqlInstance $instance -SqlCredential $SqlCredential
					if ($pbm -and $pbm.Policies.Count -gt 0) { $row.BlockingPolicies = @($pbm.Policies) }
					if ($pbm -and $pbm.Blocking)
					{
						Invoke-sqmLogging -Message "[$instance] Aktive PBM-Policies 'On change: prevent': $($pbm.Policies -join ', '). Server-Trigger syspolicy_server_trigger wird fuer die Einrichtung deaktiviert." -FunctionName $functionName -Level "WARNING"
						Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
							-Query "DISABLE TRIGGER [syspolicy_server_trigger] ON ALL SERVER;"
						$triggerDisabled = $true
						$row.PolicyTriggerDisabled = $true
					}
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
						$createName = $LoginName
						if ($createName -notmatch '\\')
						{
							# Name ohne Domaene (svc_x oder svc_x@corp.local): als Windows-Konto aufloesen
							$resolved = Resolve-sqmDiscoveryLoginName -Account $createName
							if ($resolved)
							{
								$createName = $resolved
								# der aufgeloeste Name kann schon als Login vorhanden sein
								$exists = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -As PSObject -EnableException `
									-Query "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(_S $createName)' AND type IN ('U','G')) THEN 1 ELSE 0 END AS LoginExists"
								if ($exists.LoginExists -eq 1) { $state.LoginExists = 1; $LoginName = $createName; $row.LoginName = $createName }
							}
						}

						if ($state.LoginExists -ne 1)
						{
							if ($createName -match '\\')
							{
								Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
									-Query "CREATE LOGIN $(_Q $createName) FROM WINDOWS;"
								$row.LoginCreated = $true
								$row.LoginName = $createName
								$LoginName = $createName
								$state.LoginExists = 1
							}
							else
							{
								throw "Login '$LoginName' existiert nicht auf dem Server und liess sich auf diesem Rechner nicht als Windows-Konto aufloesen. Konto als DOMAIN\Name angeben. Ein SQL-Login wird nicht automatisch angelegt."
							}
						}
					}
					if ($state.IsMember -ne 1 -or $row.LoginCreated)
					{
						Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
							-Query "IF NOT EXISTS (SELECT 1 FROM sys.server_role_members m JOIN sys.server_principals r ON r.principal_id = m.role_principal_id JOIN sys.server_principals p ON p.principal_id = m.member_principal_id WHERE r.name = N'$(_S $RoleName)' AND p.name = N'$(_S $LoginName)') ALTER SERVER ROLE $(_Q $RoleName) ADD MEMBER $(_Q $LoginName);"
						$row.MemberAdded = $true
					}
				}

				# Datenbankebene: Rolle, GRANTs, Benutzer und Mitgliedschaft je Datenbank
				$dbGrantMap = @{}
				foreach ($g in $def.DatabaseGrants) { $dbGrantMap[$g.Database] = @($g.Grants) }
				$targetDbs = [System.Collections.Generic.List[string]]::new()
				foreach ($g in $def.DatabaseGrants) { $targetDbs.Add($g.Database) }
				if ($def.DatabaseScope -eq 'Eligible')
				{
					$eligible = @(Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -As PSObject -EnableException -Query @"
SELECT DISTINCT db.name
FROM sys.databases db
LEFT JOIN sys.dm_hadr_availability_replica_states hadrstate ON db.replica_id = hadrstate.replica_id
WHERE db.database_id <> 2 AND db.user_access = 0 AND db.state = 0 AND db.is_read_only = 0
  AND (hadrstate.role = 1 OR hadrstate.role IS NULL)
"@)
					foreach ($e in $eligible) { if (-not $targetDbs.Contains([string]$e.name)) { $targetDbs.Add([string]$e.name) } }
				}

				$warnings = [System.Collections.Generic.List[string]]::new()
				foreach ($db in $targetDbs)
				{
					Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db -EnableException `
						-Query "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(_S $RoleName)' AND type = 'R') CREATE ROLE $(_Q $RoleName) AUTHORIZATION [dbo];"

					if ($dbGrantMap.ContainsKey($db))
					{
						foreach ($grant in $dbGrantMap[$db])
						{
							try
							{
								Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db -EnableException `
									-Query "GRANT $grant TO $(_Q $RoleName);"
							}
							catch
							{
								# ein fehlendes Objekt (aeltere Version) darf die uebrigen Rechte nicht verhindern
								$warnings.Add("[$db] GRANT $grant : $($_.Exception.Message)")
								Invoke-sqmLogging -Message "[$instance] GRANT $grant in $db fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							}
						}
					}

					if ($db -eq 'msdb')
					{
						foreach ($fixedRole in $def.MsdbRoleMembership)
						{
							Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database msdb -EnableException `
								-Query "ALTER ROLE $(_Q $fixedRole) ADD MEMBER $(_Q $RoleName);"
						}
					}

					if ($LoginName)
					{
						# Hat der Login schon einen Benutzer (evtl. unter anderem Namen), wird dieser verwendet
						$existingUser = @(Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db -As PSObject -EnableException `
								-Query "SELECT name FROM sys.database_principals WHERE sid = SUSER_SID(N'$(_S $LoginName)') AND type IN ('U','G','S');")
						$userName = $LoginName
						if ($existingUser.Count -gt 0) { $userName = [string]$existingUser[0].name }
						else
						{
							Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db -EnableException `
								-Query "CREATE USER $(_Q $userName) FOR LOGIN $(_Q $LoginName);"
						}
						Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db -EnableException `
							-Query "ALTER ROLE $(_Q $RoleName) ADD MEMBER $(_Q $userName);"
					}
				}
				$row.DatabasesConfigured = @($targetDbs)
				$row.Warnings = @($warnings)

				$row.Status = if ($warnings.Count -gt 0) { 'Warnung' } else { 'OK' }
				$row.Message = "Rolle '$RoleName' ($Product) bereit (SQL Server $major)." + $(if ($warnings.Count -gt 0) { " $($warnings.Count) Recht(e) konnten nicht vergeben werden, siehe Warnings." } else { '' })
				Invoke-sqmLogging -Message "[$instance] $($row.Message) Neu: Rolle=$($row.RoleCreated), Login=$($row.LoginCreated), Mitglied=$($row.MemberAdded), Datenbanken=$($targetDbs.Count)." -FunctionName $functionName -Level "INFO"
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
			finally
			{
				# Der PBM-Trigger wird in jedem Fall wieder eingeschaltet, auch nach einem Fehler.
				if ($triggerDisabled)
				{
					try
					{
						Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database master -EnableException `
							-Query "ENABLE TRIGGER [syspolicy_server_trigger] ON ALL SERVER;"
						Invoke-sqmLogging -Message "[$instance] syspolicy_server_trigger wieder aktiviert." -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						$restoreMsg = "[$instance] syspolicy_server_trigger konnte NICHT wieder aktiviert werden: $($_.Exception.Message). Von Hand: ENABLE TRIGGER [syspolicy_server_trigger] ON ALL SERVER;"
						Invoke-sqmLogging -Message $restoreMsg -FunctionName $functionName -Level "ERROR"
						Write-Warning $restoreMsg
					}
				}
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
