<#
.SYNOPSIS
    Verifies that an inventory/discovery service account can actually read what it is
    supposed to read, across a list of SQL Server instances.

.DESCRIPTION
    Tools like ServiceNow Discovery, SCOM or an authenticated vulnerability scanner connect
    with a dedicated service account. When that account is missing on an instance, the
    collection fails silently from the DBA's point of view: the CMDB entry goes stale and,
    in the case of ServiceNow, a CI marked "absent" does not return to active on its own.
    The damage is therefore permanent until someone notices.

    This function is the recurring check for that. Per instance it reports:

    - Does the login exist at all, is it enabled, is CONNECT SQL denied
    - Is it a member of the expected server role (-ServerRole)
    - Which effective server permissions it really has, resolved through direct grants,
      every server role it is a member of (nested), and the public role, with DENY winning
    - Whether VIEW ANY DATABASE is still granted to public. That is the SQL Server default
      and the reason a bare login can already list all databases. If a hardening baseline
      revoked it, the account silently sees only master and tempdb
    - Whether the account is over-privileged (sysadmin), which is never required for discovery

    From that it derives a DiscoveryLevel, which is what the collecting tool can actually see:

        None            no usable login, nothing is collected
        ServerOnly      instance data only (that path needs no SQL login at all)
        Databases       database names, state, recovery model, collation, owner
        DatabaseDetails additionally sizes and file paths (needs VIEW ANY DEFINITION)
        Full            additionally port, CPU/RAM, cluster and AG topology (needs VIEW SERVER STATE)

    Results are saved as TXT and HTML report in -OutputPath and returned as objects.

.PARAMETER SqlInstance
    One or more SQL Server instances to check. Pipeline-capable, so a server list from a
    file or from Get-Content can be piped straight in. Default: current computer.

.PARAMETER LoginName
    The service account to verify, e.g. "CORP\SVC-SNOW-DISCO". A Windows login, a Windows
    group login or a SQL login.

    Note: if the account gets its access through an AD *group* login rather than its own
    login, this function reports it as missing. Resolving nested AD group membership is a
    separate job - use Test-sqmLoginGroupAccess for that, it needs a reachable domain
    controller.

.PARAMETER ServerRole
    Expected server role membership, e.g. "SQL_Inventory_RO_Basic". Without this parameter
    the role check is skipped and only permissions are evaluated.

.PARAMETER RequiredLevel
    The DiscoveryLevel the account is supposed to reach. Anything below it is reported as a
    finding. Default: Databases (server plus database listing), which is what a CMDB
    inventory normally needs.

.PARAMETER SqlCredential
    PSCredential for the SQL connection. This is the DBA's own connection, not the
    service account being checked.

.PARAMETER OutputPath
    Output directory for the TXT/HTML report. Default: 'DiscoveryAccess' subfolder under
    the configured default output path (see Get-sqmDefaultOutputPath).

.PARAMETER NoOpen
    Suppresses automatically opening the generated report.

.PARAMETER ContinueOnError
    Continue with the next instance on error instead of throwing.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Test-sqmDiscoveryAccess -SqlInstance SQL01 -LoginName "CORP\SVC-SNOW-DISCO"

    Checks one instance against the default requirement (server plus database listing).

.EXAMPLE
    Get-Content .\sqlserver.txt | Test-sqmDiscoveryAccess -LoginName "CORP\SVC-SNOW-DISCO" `
        -ServerRole "SQL_Inventory_RO_Basic" -NoOpen

    Sweeps a whole server list and reports every instance where the login or the role
    membership is missing.

.EXAMPLE
    Test-sqmDiscoveryAccess -SqlInstance SQL01, SQL02 -LoginName "CORP\SVC-SCOM" `
        -RequiredLevel Full

    Requires the account to also reach the DMVs (port, CPU/RAM, cluster and AG topology).

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Read-only. The function changes nothing on the instances it checks.
    Default output path: <Get-sqmDefaultOutputPath>\DiscoveryAccess
#>
function Test-sqmDiscoveryAccess
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $true, Position = 1)]
		[ValidateNotNullOrEmpty()]
		[string]$LoginName,
		[Parameter(Mandatory = $false)]
		[string]$ServerRole,
		[Parameter(Mandatory = $false)]
		[ValidateSet('ServerOnly', 'Databases', 'DatabaseDetails', 'Full')]
		[string]$RequiredLevel = 'Databases',
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'DiscoveryAccess'),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
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

		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		# Rangfolge der Stufen, damit "erreicht" gegen "gefordert" vergleichbar wird.
		$levelRank = @{
			'None'			  = 0
			'ServerOnly'	  = 1
			'Databases'		  = 2
			'DatabaseDetails' = 3
			'Full'			  = 4
		}

		function _EscapeSql
		{
			param ([string]$Value)
			if ($null -eq $Value) { return '' }
			return $Value -replace "'", "''"
		}

		function _Enc
		{
			param ([string]$Value)
			if ($null -eq $Value) { return '' }
			return $Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
		}

		# Ein einziger Roundtrip pro Instanz. Die effektive Serverberechtigung wird aus
		# drei Quellen zusammengesetzt: direkte GRANTs, jede Serverrolle in der das Login
		# steckt (rekursiv, Rollen koennen verschachtelt sein) und public. DENY schlaegt
		# GRANT, deshalb wird DENY separat geprueft und nicht nur die Existenz eines GRANT.
		$sqlTemplate = @'
SET NOCOUNT ON;

DECLARE @login sysname = N'{0}';
DECLARE @role  sysname = NULLIF(N'{1}', N'');

DECLARE @pid int = (SELECT principal_id FROM sys.server_principals WHERE name = @login);

;WITH RolesOf AS
(
    SELECT rm.role_principal_id AS pid
    FROM   sys.server_role_members rm
    WHERE  rm.member_principal_id = @pid
    UNION ALL
    SELECT rm.role_principal_id
    FROM   sys.server_role_members rm
    JOIN   RolesOf r ON r.pid = rm.member_principal_id
),
AllP AS
(
    SELECT @pid AS pid WHERE @pid IS NOT NULL
    UNION
    SELECT pid FROM RolesOf
    UNION
    SELECT 2                                  -- public
),
Perm AS
(
    SELECT p.permission_name, p.state_desc
    FROM   sys.server_permissions p
    WHERE  p.class = 100
      AND  p.grantee_principal_id IN (SELECT pid FROM AllP)
)
SELECT
    MajorVersion        = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), 4) AS int),
    ProductVersion      = CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)),
    Edition             = CAST(SERVERPROPERTY('Edition') AS nvarchar(100)),
    LoginExists         = CASE WHEN @pid IS NULL THEN 0 ELSE 1 END,
    LoginType           = ISNULL((SELECT type_desc  FROM sys.server_principals WHERE principal_id = @pid), ''),
    IsDisabled          = ISNULL((SELECT CAST(is_disabled AS int) FROM sys.server_principals WHERE principal_id = @pid), 0),
    DenyConnectSql      = CASE WHEN EXISTS (SELECT 1 FROM Perm WHERE permission_name = 'CONNECT SQL' AND state_desc = 'DENY') THEN 1 ELSE 0 END,
    IsSysadmin          = ISNULL(CONVERT(int, IS_SRVROLEMEMBER('sysadmin', @login)), 0),
    RoleExists          = CASE WHEN @role IS NULL THEN -1
                               WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @role AND type = 'R') THEN 1
                               ELSE 0 END,
    InServerRole        = CASE WHEN @role IS NULL THEN -1
                               ELSE ISNULL(CONVERT(int, IS_SRVROLEMEMBER(@role, @login)), 0) END,
    PublicViewAnyDb     = CASE WHEN EXISTS (SELECT 1 FROM sys.server_permissions
                                            WHERE class = 100 AND grantee_principal_id = 2
                                              AND permission_name = 'VIEW ANY DATABASE'
                                              AND state_desc LIKE 'GRANT%') THEN 1 ELSE 0 END,
    ViewAnyDatabase     = CASE WHEN EXISTS (SELECT 1 FROM Perm WHERE permission_name = 'VIEW ANY DATABASE'   AND state_desc = 'DENY') THEN 0
                               WHEN EXISTS (SELECT 1 FROM Perm WHERE permission_name = 'VIEW ANY DATABASE'   AND state_desc LIKE 'GRANT%') THEN 1
                               ELSE 0 END,
    ViewAnyDefinition   = CASE WHEN EXISTS (SELECT 1 FROM Perm WHERE permission_name = 'VIEW ANY DEFINITION' AND state_desc = 'DENY') THEN 0
                               WHEN EXISTS (SELECT 1 FROM Perm WHERE permission_name = 'VIEW ANY DEFINITION' AND state_desc LIKE 'GRANT%') THEN 1
                               ELSE 0 END,
    ViewServerState     = CASE WHEN EXISTS (SELECT 1 FROM Perm WHERE permission_name IN ('VIEW SERVER STATE', 'VIEW SERVER PERFORMANCE STATE') AND state_desc = 'DENY') THEN 0
                               WHEN EXISTS (SELECT 1 FROM Perm WHERE permission_name IN ('VIEW SERVER STATE', 'VIEW SERVER PERFORMANCE STATE') AND state_desc LIKE 'GRANT%') THEN 1
                               ELSE 0 END,
    GrantedPermissions  = ISNULL(STUFF((SELECT DISTINCT ', ' + permission_name
                                        FROM Perm WHERE state_desc LIKE 'GRANT%'
                                        FOR XML PATH('')), 1, 2, ''), ''),
    ServerRoles         = ISNULL(STUFF((SELECT DISTINCT ', ' + sp.name
                                        FROM RolesOf r JOIN sys.server_principals sp ON sp.principal_id = r.pid
                                        FOR XML PATH('')), 1, 2, ''), '')
'@
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			if ([string]::IsNullOrWhiteSpace($instance)) { continue }
			$instance = $instance.Trim()

			$row = [PSCustomObject]@{
				SqlInstance		   = $instance
				Reachable		   = $false
				ProductVersion	   = ''
				Edition			   = ''
				LoginName		   = $LoginName
				LoginExists		   = $false
				LoginType		   = ''
				IsDisabled		   = $false
				DenyConnectSql	   = $false
				IsSysadmin		   = $false
				ServerRole		   = $ServerRole
				RoleExists		   = $null
				InServerRole	   = $null
				ServerRoles		   = ''
				PublicViewAnyDb    = $null
				ViewAnyDatabase    = $false
				ViewAnyDefinition  = $false
				ViewServerState    = $false
				GrantedPermissions = ''
				DiscoveryLevel	   = 'None'
				RequiredLevel	   = $RequiredLevel
				MeetsRequirement   = $false
				Status			   = 'Error'
				Findings		   = @()
			}

			try
			{
				if (-not $PSCmdlet.ShouldProcess($instance, "Discovery-Zugriff fuer '$LoginName' pruefen"))
				{
					$row.Status = 'WhatIf'
					$allResults.Add($row)
					continue
				}

				$query = [string]::Format($sqlTemplate, (_EscapeSql $LoginName), (_EscapeSql $ServerRole))

				$data = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential `
									    -Database master -Query $query -As PSObject -EnableException

				if (-not $data)
				{
					throw "Instanz '$instance' lieferte kein Ergebnis."
				}

				$findings = [System.Collections.Generic.List[string]]::new()

				$row.Reachable		   = $true
				$row.ProductVersion    = [string]$data.ProductVersion
				$row.Edition		   = [string]$data.Edition
				$row.LoginExists	   = ($data.LoginExists -eq 1)
				$row.LoginType		   = [string]$data.LoginType
				$row.IsDisabled		   = ($data.IsDisabled -eq 1)
				$row.DenyConnectSql    = ($data.DenyConnectSql -eq 1)
				$row.IsSysadmin		   = ($data.IsSysadmin -eq 1)
				$row.ServerRoles	   = [string]$data.ServerRoles
				$row.PublicViewAnyDb   = ($data.PublicViewAnyDb -eq 1)
				$row.ViewAnyDatabase   = ($data.ViewAnyDatabase -eq 1)
				$row.ViewAnyDefinition = ($data.ViewAnyDefinition -eq 1)
				$row.ViewServerState   = ($data.ViewServerState -eq 1)
				$row.GrantedPermissions = [string]$data.GrantedPermissions

				if ($data.RoleExists -ge 0)
				{
					$row.RoleExists   = ($data.RoleExists -eq 1)
					$row.InServerRole = ($data.InServerRole -eq 1)
				}

				# --- Stufe bestimmen -------------------------------------------------------
				# Die Serverdaten holt eine agentenlose Discovery ueber Registry und WMI,
				# dafuer ist auf SQL-Ebene ueberhaupt kein Login noetig. Erst ab der
				# Datenbankliste zaehlt, was hier geprueft wird.
				$level = 'ServerOnly'
				if (-not $row.LoginExists -or $row.IsDisabled -or $row.DenyConnectSql)
				{
					$level = 'ServerOnly'
				}
				elseif ($row.ViewAnyDatabase)
				{
					$level = 'Databases'
					if ($row.ViewAnyDefinition) { $level = 'DatabaseDetails' }
					if ($row.ViewAnyDefinition -and $row.ViewServerState) { $level = 'Full' }
				}
				$row.DiscoveryLevel	  = $level
				$row.MeetsRequirement = ($levelRank[$level] -ge $levelRank[$RequiredLevel])

				# --- Befunde ---------------------------------------------------------------
				if (-not $row.LoginExists)
				{
					$findings.Add("Login '$LoginName' existiert nicht. Datenbanken werden nicht erfasst; ein bereits inaktiv gesetztes CI kehrt nicht von selbst zurueck.")
				}
				else
				{
					if ($row.IsDisabled)     { $findings.Add("Login ist deaktiviert.") }
					if ($row.DenyConnectSql) { $findings.Add("CONNECT SQL ist fuer dieses Login explizit mit DENY gesperrt.") }

					if ($row.IsSysadmin)
					{
						$findings.Add("Login ist Mitglied von sysadmin. Fuer Discovery nicht erforderlich, Rechte sollten reduziert werden.")
					}

					if ($null -ne $row.RoleExists)
					{
						if (-not $row.RoleExists)       { $findings.Add("Serverrolle '$ServerRole' existiert auf dieser Instanz nicht.") }
						elseif (-not $row.InServerRole) { $findings.Add("Login ist nicht Mitglied der Serverrolle '$ServerRole'.") }
					}

					# Der Haertungsfall: ohne VIEW ANY DATABASE meldet SQL Server keinen
					# Fehler, das Konto sieht nur noch master und tempdb.
					if (-not $row.ViewAnyDatabase)
					{
						if ($row.PublicViewAnyDb)
						{
							$findings.Add("VIEW ANY DATABASE fehlt trotz GRANT an public. Das deutet auf ein explizites DENY fuer dieses Login hin.")
						}
						else
						{
							$findings.Add("VIEW ANY DATABASE ist public entzogen und dem Login nicht einzeln erteilt. Das Konto sieht nur master und tempdb, ohne jede Fehlermeldung.")
						}
					}

					if ($levelRank[$RequiredLevel] -ge $levelRank['DatabaseDetails'] -and -not $row.ViewAnyDefinition)
					{
						$findings.Add("VIEW ANY DEFINITION fehlt. Datenbankgroessen und Dateipfade bleiben leer, sys.master_files liefert null Zeilen ohne Fehlermeldung.")
					}

					if ($levelRank[$RequiredLevel] -ge $levelRank['Full'] -and -not $row.ViewServerState)
					{
						$verHint = if ($data.MajorVersion -ge 16) { " (ab SQL 2022 meldet der Server 'VIEW SERVER PERFORMANCE STATE')" } else { '' }
						$findings.Add("VIEW SERVER STATE fehlt$verHint. Port, CPU/RAM sowie Cluster- und AG-Topologie werden nicht erfasst.")
					}
				}

				$row.Findings = $findings.ToArray()

				$row.Status = if (-not $row.MeetsRequirement) { 'Fehler' }
							  elseif ($findings.Count -gt 0)  { 'Warnung' }
							  else						      { 'OK' }

				Invoke-sqmLogging -Message "[$instance] Stufe '$level' (gefordert '$RequiredLevel'), Status $($row.Status), $($findings.Count) Befund(e)." -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "[$instance] Pruefung fehlgeschlagen: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$row.Status   = 'Error'
				$row.Findings = @($_.Exception.Message)

				if ($EnableException) { throw }
				if (-not $ContinueOnError) { $allResults.Add($row); throw $_ }
			}

			$allResults.Add($row)
		}
	}

	end
	{
		if ($allResults.Count -eq 0)
		{
			Invoke-sqmLogging -Message "$functionName ohne Ergebnis beendet." -FunctionName $functionName -Level "WARNING"
			return $allResults
		}

		try
		{
			if (-not (Test-Path $OutputPath))
			{
				New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
			}

			$datestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
			$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
			$safeLogin = $LoginName -replace '[\\/:*?"<>|]', '_'
			$txtFile   = Join-Path $OutputPath "DiscoveryAccess_${safeLogin}_${datestamp}.txt"
			$htmlFile  = Join-Path $OutputPath "DiscoveryAccess_${safeLogin}_${datestamp}.html"

			$countErr  = @($allResults | Where-Object { $_.Status -eq 'Error' }).Count
			$countWarn = @($allResults | Where-Object { $_.Status -eq 'Warnung' }).Count
			$countOk   = @($allResults | Where-Object { $_.Status -eq 'OK' }).Count

			# --- TXT ---------------------------------------------------------------------
			$txt = [System.Collections.Generic.List[string]]::new()
			$txt.Add("Discovery-Zugriffspruefung")
			$txt.Add("Konto            : $LoginName")
			if ($ServerRole) { $txt.Add("Erwartete Rolle  : $ServerRole") }
			$txt.Add("Geforderte Stufe : $RequiredLevel")
			$txt.Add("Erstellt         : $timestamp")
			$txt.Add("Instanzen        : $($allResults.Count)   OK: $countOk   Warnung: $countWarn   Fehler: $countErr")
			$txt.Add("")
			$txt.Add((Get-sqmReportReference))
			$txt.Add(('-' * 100))

			foreach ($r in $allResults)
			{
				$txt.Add("")
				$txt.Add("$($r.SqlInstance)   [$($r.Status)]   Stufe: $($r.DiscoveryLevel)")
				if ($r.Reachable)
				{
					$roleTxt = if ($null -eq $r.InServerRole) { 'nicht geprueft' }
							   elseif ($r.InServerRole)       { 'ja' }
							   else                           { 'NEIN' }
					$txt.Add("    Version: $($r.ProductVersion)  $($r.Edition)")
					$txt.Add("    Login vorhanden: $(if ($r.LoginExists) { "ja ($($r.LoginType))" } else { 'NEIN' })   deaktiviert: $(if ($r.IsDisabled) { 'ja' } else { 'nein' })   sysadmin: $(if ($r.IsSysadmin) { 'JA' } else { 'nein' })")
					$txt.Add("    Rollenmitglied '$ServerRole': $roleTxt")
					$txt.Add("    VIEW ANY DATABASE: $(if ($r.ViewAnyDatabase) { 'ja' } else { 'NEIN' })   VIEW ANY DEFINITION: $(if ($r.ViewAnyDefinition) { 'ja' } else { 'nein' })   VIEW SERVER STATE: $(if ($r.ViewServerState) { 'ja' } else { 'nein' })")
					if ($r.ServerRoles)        { $txt.Add("    Serverrollen: $($r.ServerRoles)") }
					if ($r.GrantedPermissions) { $txt.Add("    Effektive GRANTs: $($r.GrantedPermissions)") }
				}
				foreach ($f in $r.Findings) { $txt.Add("    - $f") }
			}

			$txt | Out-File -FilePath $txtFile -Encoding UTF8 -Force

			# --- HTML --------------------------------------------------------------------
			$rowsHtml = ''
			foreach ($r in $allResults)
			{
				$cls = switch ($r.Status) { 'OK' { 'ok' } 'Warnung' { 'warn' } default { 'crit' } }
				$roleCell = if ($null -eq $r.InServerRole) { '-' }
							elseif ($r.InServerRole)       { "<span class='ok'>ja</span>" }
							else                           { "<span class='crit'>nein</span>" }
				$loginCell = if (-not $r.Reachable)   { "<span class='crit'>nicht erreichbar</span>" }
							 elseif ($r.LoginExists)  { "<span class='ok'>ja</span>" }
							 else                     { "<span class='crit'>nein</span>" }
				$yn = {
					param ($v)
					if ($v) { "<span class='ok'>ja</span>" } else { "<span class='warn'>nein</span>" }
				}
				$findingsHtml = if ($r.Findings.Count -gt 0)
				{
					'<ul style="margin:4px 0 0 16px;padding:0;">' + (($r.Findings | ForEach-Object { '<li>' + (_Enc $_) + '</li>' }) -join '') + '</ul>'
				}
				else { '<span class="ok">keine</span>' }

				$rowsHtml += "<tr><td>$(_Enc $r.SqlInstance)</td><td class='$cls'>$($r.Status)</td><td>$(_Enc $r.DiscoveryLevel)</td><td>$loginCell</td><td>$roleCell</td><td>$(& $yn $r.ViewAnyDatabase)</td><td>$(& $yn $r.ViewAnyDefinition)</td><td>$(& $yn $r.ViewServerState)</td><td>$(if ($r.IsSysadmin) { "<span class='crit'>JA</span>" } else { 'nein' })</td><td>$findingsHtml</td></tr>`n"
			}

			$bodyHtml = @"
<p>Konto: <strong>$(_Enc $LoginName)</strong>$(if ($ServerRole) { " | Erwartete Rolle: <strong>$(_Enc $ServerRole)</strong>" }) | Geforderte Stufe: <strong>$(_Enc $RequiredLevel)</strong></p>
<p>Instanzen: <strong>$($allResults.Count)</strong> &nbsp;|&nbsp; <span class="ok">OK: $countOk</span> &nbsp;|&nbsp; <span class="warn">Warnung: $countWarn</span> &nbsp;|&nbsp; <span class="crit">Fehler: $countErr</span></p>
<table>
<tr><th>Instanz</th><th>Status</th><th>Stufe</th><th>Login</th><th>in Rolle</th><th>VIEW ANY DATABASE</th><th>VIEW ANY DEFINITION</th><th>VIEW SERVER STATE</th><th>sysadmin</th><th>Befunde</th></tr>
$rowsHtml
</table>
"@

			$html = ConvertTo-sqmHtmlReport -Title "Discovery-Zugriffspruefung - $LoginName" `
											-Subtitle "Erstellt: $timestamp | $($allResults.Count) Instanz(en)" `
											-BodyHtml $bodyHtml
			$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

			Invoke-sqmLogging -Message "Bericht gespeichert: $htmlFile" -FunctionName $functionName -Level "INFO"
			Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
		}
		catch
		{
			Invoke-sqmLogging -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Instanz(en) geprueft." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
