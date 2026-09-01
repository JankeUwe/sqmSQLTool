<#
.SYNOPSIS
    Diagnoses why a user cannot log in when logins are provisioned as AD groups.

.DESCRIPTION
    In environments where SQL Server logins are created only as AD groups (not per-user),
    a user who can't connect is missing one of two things:
    1. None of the AD groups the user belongs to is provisioned as a SQL Server login
       at all (or the login exists but is disabled / explicitly denied CONNECT SQL), or
    2. A usable login exists for one of the user's groups, but that login has no matching
       database user in the target database (no CREATE USER ... FOR LOGIN was ever run there).

    This function answers both questions in one pass:
    - Resolves all AD groups the user belongs to, direct and nested (via Get-sqmADMemberGroups).
    - Checks -SqlInstance's sys.server_principals for a Windows-group login matching each of
      those AD groups, and whether that login is enabled / not denied CONNECT SQL.
    - For every login found this way, checks each accessible database's sys.database_principals
      (matched by SID, not by name - names can differ) for a mapped database user and its role
      memberships.

    Results are additionally saved as TXT and HTML report in -OutputPath. The function still
    returns the flat array of per-user result objects (each with a nested per-group Detail[]).

.PARAMETER Identity
    The AD user having trouble logging in. SamAccountName, UPN, or DistinguishedName.
    Pipeline-capable.

.PARAMETER SqlInstance
    SQL Server instance to check logins/database access on. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the SQL connection.

.PARAMETER Domain
    Optional: AD domain. Auto-detected if not specified (see Get-sqmADMemberGroups).

.PARAMETER Depth
    Maximum AD group nesting depth to resolve (default: 2, passed through to Get-sqmADMemberGroups).

.PARAMETER Database
    Restrict the database-level check to these databases (wildcards allowed).
    Default: all accessible databases on the instance.

.PARAMETER ExcludeDatabase
    Databases to skip during the database-level check (wildcards allowed).

.PARAMETER ExcludeSystemDatabases
    Skip master, model, msdb and tempdb during the database-level check.

.PARAMETER OutputPath
    Output directory for the TXT/HTML report files. Default: 'LoginGroupAccess' subfolder
    under the configured default output path (see Get-sqmDefaultOutputPath).

.PARAMETER NoOpen
    Suppresses automatically opening the generated report (HTML has priority over TXT).

.PARAMETER ContinueOnError
    Continue with the next identity on error instead of throwing.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Test-sqmLoginGroupAccess -Identity "john.doe" -SqlInstance "SQL01"

.EXAMPLE
    Test-sqmLoginGroupAccess -Identity "john.doe" -SqlInstance "SQL01" -Database "AdventureWorks"

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmADMemberGroups
    Requires a reachable Domain Controller (see Get-sqmADMemberGroups) - not usable in a
    workgroup-only lab.
    Default output path: <Get-sqmDefaultOutputPath>\LoginGroupAccess
#>
function Test-sqmLoginGroupAccess
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
		[ValidateNotNullOrEmpty()]
		[string[]]$Identity,
		[Parameter(Mandatory = $false, Position = 1)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$Domain,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 10)]
		[int]$Depth = 2,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[switch]$ExcludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'LoginGroupAccess'),
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
		if (-not (Get-Command -Name Get-sqmADMemberGroups -ErrorAction SilentlyContinue))
		{
			$errMsg = "Get-sqmADMemberGroups nicht gefunden - wird fuer die AD-Gruppenaufloesung benoetigt."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		$sysDatabases = @('master', 'model', 'msdb', 'tempdb')

		function _MatchesAny
		{
			param ([string]$Name, [string[]]$Patterns)
			if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}

		function _SidToString
		{
			param ($Sid)
			if ($null -eq $Sid -or $Sid -is [DBNull]) { return '' }
			return [System.BitConverter]::ToString([byte[]]$Sid)
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		foreach ($id in $Identity)
		{
			$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
			$datestamp = Get-Date -Format 'yyyy-MM-dd'

			try
			{
				# --- Schritt 1: AD-Gruppen des Benutzers ermitteln (direkt + verschachtelt) ---
				$adParams = @{
					Identity  = $id
					Depth	  = $Depth
					OutputPath = (Join-Path $OutputPath 'ADMemberGroups')
					NoOpen	  = $true
				}
				if ($Domain) { $adParams['Domain'] = $Domain }
				$adInfo = Get-sqmADMemberGroups @adParams -Confirm:$false | Select-Object -First 1

				if (-not $adInfo -or $adInfo.Status -eq 'Error')
				{
					$msg = if ($adInfo) { $adInfo.Message } else { "AD-Gruppenmitgliedschaft konnte nicht ermittelt werden." }
					Invoke-sqmLogging -Message "[$id] $msg" -FunctionName $functionName -Level "ERROR"
					$allResults.Add([PSCustomObject]@{
							Identity    = $id
							DisplayName = $null
							SqlInstance = $SqlInstance
							Diagnosis   = 'Error'
							Status	    = 'Error'
							Message	    = $msg
							Detail	    = @()
							TxtFile	    = $null
							CsvFile	    = $null
							HtmlFile    = $null
						})
					if ($EnableException) { throw $msg }
					if (-not $ContinueOnError) { throw $msg }
					continue
				}

				$cleanIdentity = $adInfo.Identity
				$targetDomain = $adInfo.Domain
				$adGroups = @($adInfo.Groups)

				# --- Schritt 2: Server-Logins (Windows-Gruppen) auf der Zielinstanz lesen -----
				$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				$loginQuery = @"
SELECT
    sp.name           AS LoginName,
    sp.is_disabled    AS IsDisabled,
    sp.sid            AS Sid,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.server_permissions perm
        WHERE perm.grantee_principal_id = sp.principal_id
          AND perm.permission_name = 'CONNECT SQL'
          AND perm.state = 'D'
    ) THEN 1 ELSE 0 END AS DenyConnectSql
FROM sys.server_principals sp
WHERE sp.type = 'G'
"@
				$serverLogins = Invoke-DbaQuery @connParams -Database 'master' -Query $loginQuery -EnableException

				# --- Schritt 3: jede AD-Gruppe gegen die Server-Logins matchen ----------------
				$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()
				$matchedLogins = [System.Collections.Generic.List[PSCustomObject]]::new()

				foreach ($grp in $adGroups)
				{
					$matches = @($serverLogins | Where-Object { ($_.LoginName -replace '^[^\\]*\\', '') -eq $grp.SamAccountName })

					if ($matches.Count -eq 0)
					{
						$detailRows.Add([PSCustomObject]@{
								GroupSamAccountName = $grp.SamAccountName
								GroupDisplayName    = $grp.DisplayName
								GroupDepth	        = $grp.Depth
								HasServerLogin      = $false
								LoginName	        = $null
								LoginEnabled        = $null
								DenyConnectSql      = $null
								DatabaseAccess      = @()
								DatabaseAccessSummary = ''
								Assessment	        = "Keine SQL-Server-Login-Gruppe fuer '$($grp.SamAccountName)' vorhanden - diese AD-Gruppe ist nicht als Login angelegt."
							})
						continue
					}

					foreach ($m in $matches)
					{
						$enabled = -not [bool]$m.IsDisabled
						$deny = [bool]$m.DenyConnectSql
						$assessment = if (-not $enabled) { "Login '$($m.LoginName)' ist DEAKTIVIERT." }
						elseif ($deny) { "Login '$($m.LoginName)' hat DENY CONNECT SQL." }
						else { "Login '$($m.LoginName)' ist aktiv und zugelassen." }

						$row = [PSCustomObject]@{
							GroupSamAccountName = $grp.SamAccountName
							GroupDisplayName    = $grp.DisplayName
							GroupDepth	        = $grp.Depth
							HasServerLogin      = $true
							LoginName	        = $m.LoginName
							LoginEnabled        = $enabled
							DenyConnectSql      = $deny
							DatabaseAccess      = @()
							DatabaseAccessSummary = ''
							Assessment	        = $assessment
							Sid		            = $m.Sid
						}
						$detailRows.Add($row)
						if ($enabled -and -not $deny) { $matchedLogins.Add($row) }
					}
				}

				# --- Schritt 4: Datenbank-Zugriff fuer jedes nutzbare Login pruefen -----------
				if ($matchedLogins.Count -gt 0)
				{
					$sidToRow = @{ }
					foreach ($r in $matchedLogins) { $sidToRow[(_SidToString $r.Sid)] = $r }

					$dbQuery = @"
SELECT
    dp.name AS DbUserName,
    dp.sid  AS Sid,
    STUFF((
        SELECT ', ' + r.name
        FROM sys.database_role_members rm
        JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
        WHERE rm.member_principal_id = dp.principal_id
        FOR XML PATH('')
    ), 1, 2, '') AS Roles
FROM sys.database_principals dp
WHERE dp.type IN ('G','U') AND dp.sid IS NOT NULL
"@
					$dbs = Get-DbaDatabase @connParams | Where-Object { $_.IsAccessible }
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
							Invoke-sqmLogging -Message "[$SqlInstance] Datenbank '$dbName' uebersprungen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
							continue
						}

						foreach ($dbRow in $dbRows)
						{
							$key = _SidToString $dbRow.Sid
							if (-not $sidToRow.ContainsKey($key)) { continue }
							$targetRow = $sidToRow[$key]
							$targetRow.DatabaseAccess += [PSCustomObject]@{
								DatabaseName = $dbName
								DbUserName   = $dbRow.DbUserName
								Roles	     = $dbRow.Roles
							}
						}
					}

					foreach ($r in $matchedLogins)
					{
						$r.DatabaseAccessSummary = if ($r.DatabaseAccess.Count -gt 0)
						{
							($r.DatabaseAccess | ForEach-Object { "$($_.DatabaseName)$(if ($_.Roles) { " ($($_.Roles))" })" }) -join '; '
						}
						else { '(keine Datenbank)' }
					}
				}

				# --- Schritt 5: Gesamtdiagnose ableiten ----------------------------------------
				$hasAnyGroup = $adGroups.Count -gt 0
				$hasLoginGroup = @($detailRows | Where-Object HasServerLogin).Count -gt 0
				$hasUsableLogin = $matchedLogins.Count -gt 0
				$hasDbAccess = @($matchedLogins | Where-Object { $_.DatabaseAccess.Count -gt 0 }).Count -gt 0
				$checkedSpecificDb = $Database.Count -gt 0

				$diagnosis = if (-not $hasAnyGroup) { 'NoGroups' }
				elseif (-not $hasLoginGroup) { 'NoLoginGroup' }
				elseif (-not $hasUsableLogin) { 'LoginBlocked' }
				elseif ($checkedSpecificDb -and -not $hasDbAccess) { 'NoDatabaseAccess' }
				elseif (-not $checkedSpecificDb -and -not $hasDbAccess) { 'NoDatabaseAccessAnywhere' }
				else { 'OK' }

				$status = if ($diagnosis -eq 'OK') { 'OK' } else { 'Warning' }
				$message = switch ($diagnosis)
				{
					'NoGroups' { "'$cleanIdentity' ist Mitglied in keiner (relevanten) AD-Gruppe - Get-sqmADMemberGroups liefert keine Treffer." }
					'NoLoginGroup' { "Keine der $($adGroups.Count) AD-Gruppe(n) von '$cleanIdentity' ist auf '$SqlInstance' als SQL-Server-Login angelegt." }
					'LoginBlocked' { "Login-Gruppe(n) vorhanden, aber alle sind deaktiviert oder haben DENY CONNECT SQL." }
					'NoDatabaseAccess' { "Login-Gruppe ist auf '$SqlInstance' zugelassen, aber in keiner der geprueften Datenbank(en) ($($Database -join ', ')) als DB-User angelegt." }
					'NoDatabaseAccessAnywhere' { "Login-Gruppe ist auf '$SqlInstance' zugelassen, hat aber in KEINER geprueften Datenbank einen DB-User." }
					default { "Login-Gruppe ist zugelassen und hat Datenbankzugriff." }
				}

				# --- Schritt 6: Reports schreiben ----------------------------------------------
				$txtFile = $null
				$csvFile = $null
				$htmlFile = $null

				if ($PSCmdlet.ShouldProcess($cleanIdentity, "Erstelle Login-Gruppen-Zugriffsbericht in $OutputPath"))
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
					}

					$safeIdentity = $cleanIdentity -replace '[\\/:*?"<>|]', '_'
					$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
					$txtFile = Join-Path $OutputPath "LoginGroupAccess_${safeIdentity}_${safeInst}_${datestamp}.txt"
					$csvFile = Join-Path $OutputPath "LoginGroupAccess_${safeIdentity}_${safeInst}_${datestamp}.csv"
					$htmlFile = Join-Path $OutputPath "LoginGroupAccess_${safeIdentity}_${safeInst}_${datestamp}.html"

					$reference = Get-sqmReportReference
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - Login Group Access Diagnosis")
					$lines.Add("# $reference")
					$lines.Add("# Benutzer   : $cleanIdentity ($($adInfo.DisplayName))")
					$lines.Add("# Domain     : $targetDomain")
					$lines.Add("# Instanz    : $SqlInstance")
					$lines.Add("# Erstellt   : $timestamp")
					$lines.Add("# Diagnose   : $diagnosis - $message")
					$lines.Add("# ================================================================")
					$lines.Add("")
					$lines.Add(("{0,-8} {1,-25} {2,-30} {3,-10} {4,-8} {5,-8} {6}" -f 'Tiefe', 'AD-Gruppe', 'Login', 'Aktiviert', 'Deny', 'DB', 'Datenbankzugriff'))
					$lines.Add(("-" * 140))
					foreach ($e in ($detailRows | Sort-Object GroupDepth, GroupSamAccountName))
					{
						$lines.Add(("{0,-8} {1,-25} {2,-30} {3,-10} {4,-8} {5,-8} {6}" -f `
								$e.GroupDepth, $e.GroupSamAccountName, $(if ($e.LoginName) { $e.LoginName } else { '-' }), `
								(if ($null -eq $e.LoginEnabled) { '-' } elseif ($e.LoginEnabled) { 'Ja' } else { 'Nein' }), `
								(if ($null -eq $e.DenyConnectSql) { '-' } elseif ($e.DenyConnectSql) { 'Ja' } else { 'Nein' }), `
								(if ($e.HasServerLogin) { 'Ja' } else { 'Nein' }), `
								$(if ($e.DatabaseAccessSummary) { $e.DatabaseAccessSummary } else { $e.Assessment })))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$detailRows | Select-Object GroupSamAccountName, GroupDisplayName, GroupDepth, HasServerLogin, LoginName, LoginEnabled, DenyConnectSql, DatabaseAccessSummary, Assessment |
					Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# HTML-Bericht
					$rowsHtml = ''
					foreach ($e in ($detailRows | Sort-Object GroupDepth, GroupSamAccountName))
					{
						$cls = if (-not $e.HasServerLogin -or $e.LoginEnabled -eq $false -or $e.DenyConnectSql -eq $true) { 'crit' }
						elseif (-not $e.DatabaseAccessSummary -or $e.DatabaseAccessSummary -eq '(keine Datenbank)') { 'warn' }
						else { 'ok' }
						$grpEnc = [string]$e.GroupSamAccountName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
						$loginEnc = [string]$e.LoginName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
						$dbEnc = [string]$(if ($e.DatabaseAccessSummary) { $e.DatabaseAccessSummary } else { $e.Assessment }) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
						$rowsHtml += "<tr><td>$($e.GroupDepth)</td><td>$grpEnc</td><td class='$cls'>$(if ($e.HasServerLogin) { $loginEnc } else { '(kein Login)' })</td><td>$(if ($null -eq $e.LoginEnabled) { '-' } elseif ($e.LoginEnabled) { 'Ja' } else { 'Nein' })</td><td>$(if ($null -eq $e.DenyConnectSql) { '-' } elseif ($e.DenyConnectSql) { 'Ja' } else { 'Nein' })</td><td class='$cls'>$dbEnc</td></tr>`n"
					}
					$diagEnc = [string]$message -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
					$diagCls = if ($status -eq 'OK') { 'ok' } else { 'warn' }
					$bodyHtml = @"
<p>Benutzer: <strong>$([System.Net.WebUtility]::HtmlEncode($cleanIdentity))</strong> ($([System.Net.WebUtility]::HtmlEncode($adInfo.DisplayName))) | Domain: $([System.Net.WebUtility]::HtmlEncode($targetDomain)) | Instanz: $([System.Net.WebUtility]::HtmlEncode($SqlInstance))</p>
<p class='$diagCls'><strong>Diagnose ($diagnosis):</strong> $diagEnc</p>
<table>
<thead><tr><th>Tiefe</th><th>AD-Gruppe</th><th>Login</th><th>Aktiviert</th><th>Deny Connect</th><th>Datenbankzugriff</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
"@
					$html = ConvertTo-sqmHtmlReport -Title "Login Group Access - $cleanIdentity" -Subtitle "Erstellt: $timestamp | Instanz: $SqlInstance" -BodyHtml $bodyHtml
					$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

					Invoke-sqmLogging -Message "[$cleanIdentity] Bericht: $htmlFile" -FunctionName $functionName -Level "INFO"
				}

				$allResults.Add([PSCustomObject]@{
						Identity    = $cleanIdentity
						DisplayName = $adInfo.DisplayName
						SqlInstance = $SqlInstance
						Domain	    = $targetDomain
						GroupsChecked = $adGroups.Count
						Diagnosis   = $diagnosis
						Status	    = $status
						Message	    = $message
						Detail	    = $detailRows
						TxtFile	    = $txtFile
						CsvFile	    = $csvFile
						HtmlFile    = $htmlFile
					})

				Invoke-sqmLogging -Message "[$cleanIdentity] Diagnose: $diagnosis" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$errMsg = "Fehler bei '$id': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						Identity    = $id
						DisplayName = $null
						SqlInstance = $SqlInstance
						Domain	    = $Domain
						GroupsChecked = 0
						Diagnosis   = 'Error'
						Status	    = 'Error'
						Message	    = $errMsg
						Detail	    = @()
						TxtFile	    = $null
						CsvFile	    = $null
						HtmlFile    = $null
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Benutzer verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
