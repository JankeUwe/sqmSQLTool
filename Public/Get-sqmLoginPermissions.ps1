<#
.SYNOPSIS
    Lists all logins with their server- and database-level permissions.

.DESCRIPTION
    Login-centric permission report. For each login the following is resolved:
    - Server roles (sys.server_role_members) and explicit server permissions
    - Per database: the mapped database user (via SID), its database roles
      and its explicit GRANT/DENY permissions

    Logins are mapped to database users by SID, not by name, because both may
    differ. Database users without a matching login are reported as orphaned
    (LoginName is empty, IsOrphaned = $true) when -IncludeOrphanedUsers is set.

    One flat row per permission, suitable for CSV/HTML export and filtering.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential.

.PARAMETER Login
    Filter: only these logins (wildcards allowed). Default: all.

.PARAMETER Database
    Filter: only these databases (wildcards allowed). Default: all accessible.

.PARAMETER ExcludeDatabase
    Databases to skip (wildcards allowed).

.PARAMETER ExcludeSystemDatabases
    Skip master, model, msdb and tempdb.

.PARAMETER ExcludeSystemLogins
    Hide NT SERVICE\*, NT AUTHORITY\* (incl. localized variants) and ##MS_*##.

.PARAMETER IncludeOrphanedUsers
    Also report database users that have no matching server login.

.PARAMETER ExcludeServerScope
    Skip the server-level roles and permissions, report database scope only.

.PARAMETER OutputPath
    If specified, CSV and HTML reports are written. Default: no export.

.PARAMETER ContinueOnError
    Continue on error for an instance.

.PARAMETER EnableException
    Throw exceptions immediately.

.PARAMETER NoOpen
    Do not open the HTML report after creation.

.EXAMPLE
    Get-sqmLoginPermissions -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmLoginPermissions -SqlInstance "SQL01" -Login "APP_*" -ExcludeSystemDatabases

.EXAMPLE
    Get-sqmLoginPermissions -SqlInstance "SQL01" -IncludeOrphanedUsers -OutputPath "C:\Reports"

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW ANY DEFINITION plus CONNECT on each database to be reported.
    Databases that are offline or inaccessible are skipped with a warning.
#>
function Get-sqmLoginPermissions
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$Login = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeSystemDatabases,

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeOrphanedUsers,

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeServerScope,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath,

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
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# NT AUTHORITY ist lokalisiert (z. B. 'NT-AUTORITAET\SYSTEM' auf deutschen Systemen).
		# Deshalb wird zusaetzlich zum englischen Namen auf das bekannte SID-Praefix geprueft.
		$sysLoginPatterns = @('NT SERVICE\*', 'NT AUTHORITY\*', 'NT-AUTORIT*\*', '##MS_*##')
		$sysDatabases     = @('master', 'model', 'msdb', 'tempdb')

		function _MatchesAny
		{
			param ([string]$Name,
				[string[]]$Patterns)
			if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
			foreach ($p in $Patterns)
			{
				if ($Name -like $p) { return $true }
			}
			return $false
		}

		function _SidToString
		{
			param ($Sid)
			if ($null -eq $Sid) { return '' }
			return [System.BitConverter]::ToString([byte[]]$Sid)
		}

		# Server-Ebene: Rollen und explizite Rechte
		$serverQuery = @"
SELECT
    sp.name COLLATE DATABASE_DEFAULT                        AS LoginName,
    sp.type_desc COLLATE DATABASE_DEFAULT                   AS LoginType,
    sp.is_disabled                                          AS IsDisabled,
    sp.sid                                                  AS Sid,
    CAST('Role' AS nvarchar(20)) COLLATE DATABASE_DEFAULT   AS PermissionType,
    r.name COLLATE DATABASE_DEFAULT                         AS Permission,
    CAST('MEMBER' AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS State,
    CAST('SERVER_ROLE' AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS Class,
    CAST(NULL AS nvarchar(128)) COLLATE DATABASE_DEFAULT    AS Securable
FROM sys.server_principals sp
JOIN sys.server_role_members srm ON srm.member_principal_id = sp.principal_id
JOIN sys.server_principals r     ON r.principal_id = srm.role_principal_id
WHERE sp.type IN ('S','U','G')

UNION ALL

SELECT
    sp.name COLLATE DATABASE_DEFAULT                        AS LoginName,
    sp.type_desc COLLATE DATABASE_DEFAULT                   AS LoginType,
    sp.is_disabled                                          AS IsDisabled,
    sp.sid                                                  AS Sid,
    CAST('Permission' AS nvarchar(20)) COLLATE DATABASE_DEFAULT AS PermissionType,
    perm.permission_name COLLATE DATABASE_DEFAULT           AS Permission,
    perm.state_desc COLLATE DATABASE_DEFAULT                AS State,
    perm.class_desc COLLATE DATABASE_DEFAULT                AS Class,
    CASE
        WHEN perm.class = 101 THEN (SELECT name COLLATE DATABASE_DEFAULT FROM sys.server_principals WHERE principal_id = perm.major_id)
        WHEN perm.class = 100 THEN CAST(@@SERVERNAME AS nvarchar(128)) COLLATE DATABASE_DEFAULT
    END                                                     AS Securable
FROM sys.server_permissions perm
JOIN sys.server_principals sp ON sp.principal_id = perm.grantee_principal_id
WHERE sp.type IN ('S','U','G')
"@

		# Alle Logins (auch ohne jedes Recht) fuer die SID-Zuordnung und Vollstaendigkeit
		$loginQuery = @"
SELECT
    name COLLATE DATABASE_DEFAULT       AS LoginName,
    type_desc COLLATE DATABASE_DEFAULT  AS LoginType,
    is_disabled                         AS IsDisabled,
    sid                                 AS Sid
FROM sys.server_principals
WHERE type IN ('S','U','G')
"@

		# Datenbank-Ebene: Rollen und explizite Rechte je DB-User
		$dbQuery = @"
SELECT
    dp.name COLLATE DATABASE_DEFAULT                        AS UserName,
    dp.type_desc COLLATE DATABASE_DEFAULT                   AS UserType,
    dp.sid                                                  AS Sid,
    CAST('Role' AS nvarchar(20)) COLLATE DATABASE_DEFAULT   AS PermissionType,
    r.name COLLATE DATABASE_DEFAULT                         AS Permission,
    CAST('MEMBER' AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS State,
    CAST('DATABASE_ROLE' AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS Class,
    CAST(NULL AS nvarchar(128)) COLLATE DATABASE_DEFAULT    AS SecurableSchema,
    CAST(NULL AS nvarchar(128)) COLLATE DATABASE_DEFAULT    AS Securable
FROM sys.database_principals dp
JOIN sys.database_role_members drm ON drm.member_principal_id = dp.principal_id
JOIN sys.database_principals r     ON r.principal_id = drm.role_principal_id
WHERE dp.type IN ('S','U','G')

UNION ALL

SELECT
    dp.name COLLATE DATABASE_DEFAULT                        AS UserName,
    dp.type_desc COLLATE DATABASE_DEFAULT                   AS UserType,
    dp.sid                                                  AS Sid,
    CAST('Permission' AS nvarchar(20)) COLLATE DATABASE_DEFAULT AS PermissionType,
    perm.permission_name COLLATE DATABASE_DEFAULT           AS Permission,
    perm.state_desc COLLATE DATABASE_DEFAULT                AS State,
    perm.class_desc COLLATE DATABASE_DEFAULT                AS Class,
    CASE WHEN perm.class = 1 THEN OBJECT_SCHEMA_NAME(perm.major_id) END COLLATE DATABASE_DEFAULT AS SecurableSchema,
    CASE
        WHEN perm.class = 0 THEN DB_NAME()
        WHEN perm.class = 1 THEN OBJECT_NAME(perm.major_id)
        WHEN perm.class = 3 THEN SCHEMA_NAME(perm.major_id)
        WHEN perm.class = 4 THEN USER_NAME(perm.major_id)
    END COLLATE DATABASE_DEFAULT                            AS Securable
FROM sys.database_permissions perm
JOIN sys.database_principals dp ON dp.principal_id = perm.grantee_principal_id
WHERE dp.type IN ('S','U','G')
"@

		Invoke-sqmLogging -Message "Starte $functionName" -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			try
			{
				$connParams = @{ SqlInstance = $instance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				# --- Logins einlesen und nach SID indizieren -------------------
				$loginRows = Invoke-DbaQuery @connParams -Database master -Query $loginQuery -EnableException:$EnableException

				$loginBySid = @{ }
				$loginFiltered = [System.Collections.Generic.List[PSCustomObject]]::new()
				foreach ($row in $loginRows)
				{
					if ($ExcludeSystemLogins -and (_MatchesAny $row.LoginName $sysLoginPatterns)) { continue }
					if ($Login.Count -gt 0 -and -not (_MatchesAny $row.LoginName $Login)) { continue }

					$key = _SidToString $row.Sid
					$loginBySid[$key] = $row
					$loginFiltered.Add($row)
				}

				if ($loginFiltered.Count -eq 0)
				{
					Invoke-sqmLogging -Message "[$instance] Keine Logins nach Filterung." -FunctionName $functionName -Level 'WARNING'
					continue
				}

				$instanceRows = [System.Collections.Generic.List[PSCustomObject]]::new()

				# --- Server-Ebene ---------------------------------------------
				if (-not $ExcludeServerScope)
				{
					$srvRows = Invoke-DbaQuery @connParams -Database master -Query $serverQuery -EnableException:$EnableException
					foreach ($row in $srvRows)
					{
						$key = _SidToString $row.Sid
						if (-not $loginBySid.ContainsKey($key)) { continue }

						$instanceRows.Add([PSCustomObject]@{
							SqlInstance     = $instance
							LoginName       = $row.LoginName
							LoginType       = $row.LoginType
							IsDisabled      = [bool]$row.IsDisabled
							Scope           = 'Server'
							DatabaseName    = ''
							UserName        = ''
							IsOrphaned      = $false
							PermissionType  = $row.PermissionType
							Permission      = $row.Permission
							State           = $row.State
							Class           = $row.Class
							SecurableSchema = ''
							Securable       = if ($null -eq $row.Securable -or $row.Securable -is [DBNull]) { '' } else { $row.Securable }
						})
					}
				}

				# --- Datenbank-Ebene ------------------------------------------
				$dbParams = @{ } + $connParams
				$dbs = Get-DbaDatabase @dbParams -ErrorAction Stop | Where-Object { $_.IsAccessible }

				foreach ($dbObj in $dbs)
				{
					$dbName = $dbObj.Name

					if ($ExcludeSystemDatabases -and $dbName -in $sysDatabases) { continue }
					if ($Database.Count -gt 0 -and -not (_MatchesAny $dbName $Database)) { continue }
					if ($ExcludeDatabase.Count -gt 0 -and (_MatchesAny $dbName $ExcludeDatabase)) { continue }

					try
					{
						$dbRows = Invoke-DbaQuery @connParams -Database $dbName -Query $dbQuery -EnableException -ErrorAction Stop
					}
					catch
					{
						Invoke-sqmLogging -Message "[$instance] Datenbank '$dbName' uebersprungen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
						continue
					}

					foreach ($row in $dbRows)
					{
						$key      = _SidToString $row.Sid
						$hasLogin = $loginBySid.ContainsKey($key)

						# DB-User ohne Login = verwaist
						if (-not $hasLogin)
						{
							if (-not $IncludeOrphanedUsers) { continue }
							# Bei aktivem Login-Filter keine Waisen zeigen - sie gehoeren zu keinem Login
							if ($Login.Count -gt 0) { continue }
						}

						$lg = if ($hasLogin) { $loginBySid[$key] } else { $null }

						$instanceRows.Add([PSCustomObject]@{
							SqlInstance     = $instance
							LoginName       = if ($lg) { $lg.LoginName } else { '' }
							LoginType       = if ($lg) { $lg.LoginType } else { $row.UserType }
							IsDisabled      = if ($lg) { [bool]$lg.IsDisabled } else { $false }
							Scope           = 'Database'
							DatabaseName    = $dbName
							UserName        = $row.UserName
							IsOrphaned      = (-not $hasLogin)
							PermissionType  = $row.PermissionType
							Permission      = $row.Permission
							State           = $row.State
							Class           = $row.Class
							SecurableSchema = if ($null -eq $row.SecurableSchema -or $row.SecurableSchema -is [DBNull]) { '' } else { $row.SecurableSchema }
							Securable       = if ($null -eq $row.Securable -or $row.Securable -is [DBNull]) { '' } else { $row.Securable }
						})
					}
				}

				foreach ($r in $instanceRows) { $allResults.Add($r) }

				$loginCount = @($instanceRows | Where-Object { $_.LoginName } | Select-Object -ExpandProperty LoginName -Unique).Count
				$orphCount  = @($instanceRows | Where-Object { $_.IsOrphaned }).Count
				Invoke-sqmLogging -Message "[$instance] $($instanceRows.Count) Berechtigungszeile(n) fuer $loginCount Login(s), $orphCount verwaiste User-Zeile(n)." -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				$errMsg = "[$instance] Fehler: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		if ($OutputPath -and $allResults.Count -gt 0)
		{
			try
			{
				if (-not (Test-Path $OutputPath))
				{
					New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
				}
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$csvFile = Join-Path $OutputPath "LoginPermissions_$datestamp.csv"
				$allResults | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
				Invoke-sqmLogging -Message "CSV geschrieben: $csvFile" -FunctionName $functionName -Level 'INFO'

				$htmlFile = Join-Path $OutputPath "LoginPermissions_$datestamp.html"
				$bodyHtml = ($allResults |
					Select-Object SqlInstance, LoginName, LoginType, Scope, DatabaseName, UserName, IsOrphaned, PermissionType, Permission, State, Class, Securable |
					ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "Login Permissions" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen

				Copy-sqmToCentralPath -Path $csvFile, $htmlFile
			}
			catch
			{
				Invoke-sqmLogging -Message "Export fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Zeile(n) gesamt." -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
