<#
.SYNOPSIS
    Vergleicht Konfiguration, Logins und migrationsrelevante Objekte zwischen zwei SQL-Server-Instanzen.

.DESCRIPTION
    Vergleicht:
    - Instance-Einstellungen (sp_configure: MaxMemory, MinMemory, MaxDop, CTP, xp_cmdshell, CLR;
      Edition, ProductLevel, HostPlatform, IsClustered, IsHadrEnabled, BackupDirectory,
      DefaultFile/Log, ErrorLogPath, MasterDBPath, LoginMode)
    - Collation (Instance, immer ausgegeben - Mismatch ist Critical, da migrationsrelevant)
    - Logins (-CompareLogins): Vorhanden, SID, Standard-DB, Sprache, Deaktiviert-Status,
      Server-Rollenmitgliedschaft, Passwort-Hash (nur SQL-Logins)
    - Migrationsrelevante Objekte (-IncludeMigrationObjects): Linked Servers, Credentials,
      SQL-Agent-Jobs, Endpoints, Database-Mail-Profile
    - Datenbanken (-CompareDatabases): Name, Owner, RecoveryModel, Collation

    Jede Abweichung erhaelt einen Status (OK/Warning/Critical). Ausgabe als Rueckgabeobjekt
    sowie TXT- und HTML-Report (Report wird nach Erstellung automatisch geoeffnet, ausser -NoOpen).

.PARAMETER SourceInstance
    Quell-Instanz (Referenz). Mandatory.

.PARAMETER TargetInstance
    Ziel-Instanz (zu vergleichende Instanz). Mandatory.

.PARAMETER SqlCredential
    PSCredential fuer beide Instanzen (falls identisch).

.PARAMETER CompareDatabases
    Wenn gesetzt, werden Benutzerdatenbanken (Name, Owner, RecoveryModel, Collation) verglichen.

.PARAMETER CompareLogins
    Wenn gesetzt, werden Server-Logins verglichen (Vorhanden, SID, Standard-DB, Sprache,
    Deaktiviert-Status, Server-Rollen, Passwort-Hash).

.PARAMETER IncludeSystemLogins
    Nur mit -CompareLogins relevant. Wenn gesetzt, werden auch Systemlogins (sa, ##MS_*,
    NT SERVICE\*, NT AUTHORITY\*, BUILTIN\*) verglichen. Standard: ausgeblendet, da 'sa' und
    Systemkonten instanzspezifische Zufallswerte haben und keinen echten Drift darstellen.

.PARAMETER Login
    Nur mit -CompareLogins relevant. Nur diese Logins vergleichen (Wildcards erlaubt).

.PARAMETER ExcludeLogin
    Nur mit -CompareLogins relevant. Diese Logins ausschliessen (Wildcards erlaubt).

.PARAMETER IncludeMigrationObjects
    Wenn gesetzt, werden zusaetzlich migrationsrelevante Serverobjekte verglichen:
    Linked Servers, Credentials, SQL-Agent-Jobs, Endpoints, Database-Mail-Profile.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer TXT/HTML. Standard: aus Modulkonfiguration.

.PARAMETER NoOpen
    Unterdrueckt das automatische Oeffnen des Reports.

.PARAMETER NoReport
    Ueberspringt die Report-Erstellung (nur Rueckgabeobjekt, z.B. fuer Skript-Weiterverarbeitung).

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Compare-sqmServerConfiguration -SourceInstance "SQL01" -TargetInstance "SQL02" -CompareLogins -IncludeMigrationObjects

.NOTES
    Uses Connect-DbaInstance, Invoke-DbaQuery und SMO objects.
#>
function Compare-sqmServerConfiguration
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SourceInstance,
		[Parameter(Mandatory = $true)]
		[string]$TargetInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$CompareDatabases,
		[Parameter(Mandatory = $false)]
		[switch]$CompareLogins,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemLogins,
		[Parameter(Mandatory = $false)]
		[string[]]$Login = @(),
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin = @(),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeMigrationObjects,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmDefaultOutputPath),
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		# Reihenfolge der Kategorien im Report
		$categoryOrder = @('Instance', 'Collation', 'Login', 'LinkedServer', 'Credential', 'AgentJob', 'Endpoint', 'DatabaseMail', 'Database')
		$statusOrder = @{ Critical = 0; Warning = 1; OK = 2 }

		$sysLoginPatterns = @('sa', '##MS_*', 'NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*')

		function _IsSystemLogin
		{
			param ([string]$Name)
			foreach ($p in $sysLoginPatterns) { if ($Name -like $p) { return $true } }
			return $false
		}

		function _MatchesAny
		{
			param ([string]$Name, [string[]]$Patterns)
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}

		function _h { param($x) [string]$x -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

		function _AddResult
		{
			param ([string]$Category, [string]$Setting, $SourceValue, $TargetValue, [string]$Status)
			$results.Add([PSCustomObject]@{
					Category    = $Category
					Setting	    = $Setting
					SourceValue = $SourceValue
					TargetValue = $TargetValue
					Status      = $Status
				})
		}

		function Get-ServerProps($inst)
		{
			$srv = Connect-DbaInstance -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop
			$cfg = $srv.Configuration
			$props = @{
				Version           = $srv.VersionString
				Edition           = $srv.Edition
				ProductLevel      = $srv.ProductLevel
				HostPlatform      = $srv.HostPlatform
				Collation         = $srv.Collation
				LoginMode         = $srv.LoginMode
				IsClustered       = $srv.IsClustered
				IsHadrEnabled     = $srv.IsHadrEnabled
				MaxMemory         = $cfg.MaxServerMemory.ConfigValue
				MinMemory         = $cfg.MinServerMemory.ConfigValue
				MaxDop            = $cfg.MaxDegreeOfParallelism.ConfigValue
				CTP               = $cfg.CostThresholdForParallelism.ConfigValue
				XpCmdShell        = $cfg.XPCmdShell.ConfigValue
				ClrEnabled        = $cfg.IsSqlClrEnabled.ConfigValue
				BackupDirectory   = $srv.BackupDirectory
				DefaultFile       = $srv.DefaultFile
				DefaultLog        = $srv.DefaultLog
				ErrorLogPath      = $srv.ErrorLogPath
				MasterDBPath      = $srv.MasterDBPath
			}
			return $props
		}

		function Get-DatabaseSimple($inst)
		{
			$dbs = Get-DbaDatabase -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop
			$dbs | ForEach-Object {
				[PSCustomObject]@{
					Name           = $_.Name
					Owner          = $_.Owner
					RecoveryModel  = $_.RecoveryModel
					Collation      = $_.Collation
					IsSystemObject = $_.IsSystemObject
				}
			}
		}

		# Query fuer Login-Vergleich: SID/Passwort-Hash/Server-Rollen sind ueber dbatools-Objekte
		# nicht direkt vergleichbar, daher Rohabfrage (analog Compare-sqmAlwaysOnLogins).
		$loginQuery = @"
SELECT
    sp.name                                    AS LoginName,
    sp.type_desc                               AS LoginType,
    sp.default_database_name                   AS DefaultDatabase,
    sp.default_language_name                   AS DefaultLanguage,
    sp.is_disabled                              AS IsDisabled,
    CONVERT(varchar(85),  sp.sid, 1)            AS SidHex,
    CONVERT(varchar(256), sl.password_hash, 1)  AS PwdHash,
    STUFF((
        SELECT ', ' + rp.name
        FROM sys.server_role_members srm
        INNER JOIN sys.server_principals rp ON rp.principal_id = srm.role_principal_id
        WHERE srm.member_principal_id = sp.principal_id
        ORDER BY rp.name
        FOR XML PATH('')
    ), 1, 2, '')                                 AS ServerRoles
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT LIKE '##%##'
"@

		function Get-LoginMap($inst)
		{
			$rows = Invoke-DbaQuery -SqlInstance $inst -SqlCredential $SqlCredential -Query $loginQuery -ErrorAction Stop
			$map = @{}
			foreach ($r in $rows) { $map[$r.LoginName.ToLowerInvariant()] = $r }
			return $map
		}
	}

	process
	{
		try
		{
			# -------------------------------------------------------------------
			# 1. Instance-Einstellungen
			# -------------------------------------------------------------------
			$sourceProps = Get-ServerProps $SourceInstance
			$targetProps = Get-ServerProps $TargetInstance
			foreach ($key in $sourceProps.Keys)
			{
				if ($key -eq 'Collation') { continue }
				if ($sourceProps[$key] -ne $targetProps[$key])
				{
					_AddResult 'Instance' $key $sourceProps[$key] $targetProps[$key] 'Warning'
				}
			}

			# Collation immer ausgegeben (nicht nur bei Abweichung) - Mismatch ist Critical
			$collationStatus = if ($sourceProps['Collation'] -eq $targetProps['Collation']) { 'OK' } else { 'Critical' }
			_AddResult 'Collation' 'Collation (Instance)' $sourceProps['Collation'] $targetProps['Collation'] $collationStatus

			# -------------------------------------------------------------------
			# 2. Logins
			# -------------------------------------------------------------------
			if ($CompareLogins)
			{
				try
				{
					$saNames = @()
					foreach ($inst in @($SourceInstance, $TargetInstance))
					{
						$saName = Get-sqmSaLogin -SqlInstance $inst -SqlCredential $SqlCredential
						if ($saName) { $saNames += $saName }
					}

					$srcLogins = Get-LoginMap $SourceInstance
					$tgtLogins = Get-LoginMap $TargetInstance

					$allNames = @{}
					foreach ($k in $srcLogins.Keys) { $allNames[$k] = $srcLogins[$k].LoginName }
					foreach ($k in $tgtLogins.Keys) { if (-not $allNames.ContainsKey($k)) { $allNames[$k] = $tgtLogins[$k].LoginName } }

					foreach ($key in ($allNames.Keys | Sort-Object))
					{
						$display = $allNames[$key]

						if (-not $IncludeSystemLogins -and ((_IsSystemLogin $display) -or ($saNames -contains $display))) { continue }
						if ($Login.Count -gt 0 -and -not (_MatchesAny $display $Login)) { continue }
						if ($ExcludeLogin.Count -gt 0 -and (_MatchesAny $display $ExcludeLogin)) { continue }

						$s = $srcLogins[$key]
						$t = $tgtLogins[$key]

						if (-not $s) { _AddResult 'Login' "Login '$display'" '<fehlt>' 'vorhanden' 'Critical'; continue }
						if (-not $t) { _AddResult 'Login' "Login '$display'" 'vorhanden' '<fehlt>' 'Critical'; continue }

						if ([string]$s.SidHex -ne [string]$t.SidHex)
						{
							_AddResult 'Login' "$display - SID" $s.SidHex $t.SidHex 'Critical'
						}

						$isSqlLogin = ($s.LoginType -eq 'SQL_LOGIN' -or $t.LoginType -eq 'SQL_LOGIN')
						if ($isSqlLogin -and $s.PwdHash -and $t.PwdHash -and ([string]$s.PwdHash -ne [string]$t.PwdHash))
						{
							_AddResult 'Login' "$display - Passwort-Hash" 'abweichend' 'abweichend' 'Critical'
						}

						if ([string]$s.DefaultDatabase -ne [string]$t.DefaultDatabase)
						{
							_AddResult 'Login' "$display - Standard-DB" $s.DefaultDatabase $t.DefaultDatabase 'Warning'
						}
						if ([string]$s.DefaultLanguage -ne [string]$t.DefaultLanguage)
						{
							_AddResult 'Login' "$display - Sprache" $s.DefaultLanguage $t.DefaultLanguage 'Warning'
						}
						if ([bool]$s.IsDisabled -ne [bool]$t.IsDisabled)
						{
							_AddResult 'Login' "$display - Deaktiviert" ([bool]$s.IsDisabled) ([bool]$t.IsDisabled) 'Warning'
						}
						if ([string]$s.ServerRoles -ne [string]$t.ServerRoles)
						{
							_AddResult 'Login' "$display - Server-Rollen" $s.ServerRoles $t.ServerRoles 'Warning'
						}
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Fehler beim Login-Vergleich: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					if ($EnableException) { throw }
				}
			}

			# -------------------------------------------------------------------
			# 3. Migrationsrelevante Objekte
			# -------------------------------------------------------------------
			if ($IncludeMigrationObjects)
			{
				# Linked Servers
				try
				{
					$srcLS = @(Get-DbaLinkedServer -SqlInstance $SourceInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$tgtLS = @(Get-DbaLinkedServer -SqlInstance $TargetInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$allLsNames = ($srcLS.Name + $tgtLS.Name) | Where-Object { $_ } | Sort-Object -Unique
					foreach ($n in $allLsNames)
					{
						$s = $srcLS | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						$t = $tgtLS | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						if (-not $s) { _AddResult 'LinkedServer' "Linked Server '$n'" '<fehlt>' 'vorhanden' 'Critical'; continue }
						if (-not $t) { _AddResult 'LinkedServer' "Linked Server '$n'" 'vorhanden' '<fehlt>' 'Critical'; continue }
						if ($s.DataSource -ne $t.DataSource) { _AddResult 'LinkedServer' "$n - DataSource" $s.DataSource $t.DataSource 'Warning' }
						if ($s.Provider -ne $t.Provider) { _AddResult 'LinkedServer' "$n - Provider" $s.Provider $t.Provider 'Warning' }
					}
				}
				catch { Invoke-sqmLogging -Message "Fehler beim Linked-Server-Vergleich: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING" }

				# Credentials
				try
				{
					$srcCred = @(Get-DbaCredential -SqlInstance $SourceInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$tgtCred = @(Get-DbaCredential -SqlInstance $TargetInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$allCredNames = ($srcCred.Name + $tgtCred.Name) | Where-Object { $_ } | Sort-Object -Unique
					foreach ($n in $allCredNames)
					{
						$s = $srcCred | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						$t = $tgtCred | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						if (-not $s) { _AddResult 'Credential' "Credential '$n'" '<fehlt>' 'vorhanden' 'Warning'; continue }
						if (-not $t) { _AddResult 'Credential' "Credential '$n'" 'vorhanden' '<fehlt>' 'Warning'; continue }
						if ($s.Identity -ne $t.Identity) { _AddResult 'Credential' "$n - Identity" $s.Identity $t.Identity 'Warning' }
					}
				}
				catch { Invoke-sqmLogging -Message "Fehler beim Credential-Vergleich: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING" }

				# SQL-Agent-Jobs
				try
				{
					$srcJobs = @(Get-DbaAgentJob -SqlInstance $SourceInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$tgtJobs = @(Get-DbaAgentJob -SqlInstance $TargetInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$allJobNames = ($srcJobs.Name + $tgtJobs.Name) | Where-Object { $_ } | Sort-Object -Unique
					foreach ($n in $allJobNames)
					{
						$s = $srcJobs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						$t = $tgtJobs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						if (-not $s) { _AddResult 'AgentJob' "Job '$n'" '<fehlt>' 'vorhanden' 'Warning'; continue }
						if (-not $t) { _AddResult 'AgentJob' "Job '$n'" 'vorhanden' '<fehlt>' 'Warning'; continue }
						if ([bool]$s.Enabled -ne [bool]$t.Enabled) { _AddResult 'AgentJob' "$n - Aktiviert" ([bool]$s.Enabled) ([bool]$t.Enabled) 'Warning' }
						if ($s.OwnerLoginName -ne $t.OwnerLoginName) { _AddResult 'AgentJob' "$n - Owner" $s.OwnerLoginName $t.OwnerLoginName 'Warning' }
					}
				}
				catch { Invoke-sqmLogging -Message "Fehler beim Agent-Job-Vergleich: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING" }

				# Endpoints
				try
				{
					$srcEp = @(Get-DbaEndpoint -SqlInstance $SourceInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$tgtEp = @(Get-DbaEndpoint -SqlInstance $TargetInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$allEpNames = ($srcEp.Name + $tgtEp.Name) | Where-Object { $_ } | Sort-Object -Unique
					foreach ($n in $allEpNames)
					{
						$s = $srcEp | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						$t = $tgtEp | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						if (-not $s) { _AddResult 'Endpoint' "Endpoint '$n'" '<fehlt>' 'vorhanden' 'Warning'; continue }
						if (-not $t) { _AddResult 'Endpoint' "Endpoint '$n'" 'vorhanden' '<fehlt>' 'Warning'; continue }
						if ($s.Port -ne $t.Port) { _AddResult 'Endpoint' "$n - Port" $s.Port $t.Port 'Warning' }
						if ($s.EndpointState -ne $t.EndpointState) { _AddResult 'Endpoint' "$n - Status" $s.EndpointState $t.EndpointState 'Warning' }
					}
				}
				catch { Invoke-sqmLogging -Message "Fehler beim Endpoint-Vergleich: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING" }

				# Database Mail Profile
				try
				{
					$srcMail = @(Get-DbaDbMailProfile -SqlInstance $SourceInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$tgtMail = @(Get-DbaDbMailProfile -SqlInstance $TargetInstance -SqlCredential $SqlCredential -ErrorAction Stop)
					$allMailNames = ($srcMail.Name + $tgtMail.Name) | Where-Object { $_ } | Sort-Object -Unique
					foreach ($n in $allMailNames)
					{
						$s = $srcMail | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						$t = $tgtMail | Where-Object { $_.Name -eq $n } | Select-Object -First 1
						if (-not $s) { _AddResult 'DatabaseMail' "Mail-Profil '$n'" '<fehlt>' 'vorhanden' 'Warning'; continue }
						if (-not $t) { _AddResult 'DatabaseMail' "Mail-Profil '$n'" 'vorhanden' '<fehlt>' 'Warning'; continue }
						if ([bool]$s.IsDefault -ne [bool]$t.IsDefault) { _AddResult 'DatabaseMail' "$n - Standardprofil" ([bool]$s.IsDefault) ([bool]$t.IsDefault) 'Warning' }
					}
				}
				catch { Invoke-sqmLogging -Message "Fehler beim Database-Mail-Vergleich: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING" }
			}

			# -------------------------------------------------------------------
			# 4. Datenbanken
			# -------------------------------------------------------------------
			if ($CompareDatabases)
			{
				$sourceDbs = Get-DatabaseSimple $SourceInstance | Where-Object { -not $_.IsSystemObject }
				$targetDbs = Get-DatabaseSimple $TargetInstance | Where-Object { -not $_.IsSystemObject }
				$allDbNames = ($sourceDbs.Name + $targetDbs.Name) | Sort-Object -Unique
				foreach ($dbName in $allDbNames)
				{
					$s = $sourceDbs | Where-Object { $_.Name -eq $dbName }
					$t = $targetDbs | Where-Object { $_.Name -eq $dbName }
					if (-not $s) { _AddResult 'Database' "Database '$dbName'" '<fehlt>' $t.Owner 'Critical'; continue }
					if (-not $t) { _AddResult 'Database' "Database '$dbName'" $s.Owner '<fehlt>' 'Critical'; continue }
					if ($s.Owner -ne $t.Owner) { _AddResult 'Database' "$dbName Owner" $s.Owner $t.Owner 'Warning' }
					if ($s.RecoveryModel -ne $t.RecoveryModel) { _AddResult 'Database' "$dbName RecoveryModel" $s.RecoveryModel $t.RecoveryModel 'Warning' }
					if ($s.Collation -ne $t.Collation) { _AddResult 'Database' "$dbName Collation" $s.Collation $t.Collation 'Warning' }
				}
			}

			# -------------------------------------------------------------------
			# 5. Reports schreiben
			# -------------------------------------------------------------------
			$cntCrit = @($results | Where-Object Status -eq 'Critical').Count
			$cntWarn = @($results | Where-Object Status -eq 'Warning').Count
			$cntOk   = @($results | Where-Object Status -eq 'OK').Count

			Invoke-sqmLogging -Message "Vergleich abgeschlossen ($SourceInstance vs $TargetInstance). Critical: $cntCrit | Warning: $cntWarn | OK: $cntOk" -FunctionName $functionName -Level "INFO"

			if (-not $NoReport)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
				$datestamp = Get-Date -Format 'yyyy-MM-dd'
				$safeSrc   = $SourceInstance -replace '[\\/:*?"<>|]', '_'
				$safeTgt   = $TargetInstance -replace '[\\/:*?"<>|]', '_'
				$txtFile   = Join-Path $OutputPath "ServerConfigCompare_${safeSrc}_vs_${safeTgt}_${datestamp}.txt"
				$htmlFile  = Join-Path $OutputPath "ServerConfigCompare_${safeSrc}_vs_${safeTgt}_${datestamp}.html"

				$sorted = $results | Sort-Object `
					@{ Expression = { $categoryOrder.IndexOf($_.Category) } }, `
					@{ Expression = { $statusOrder[$_.Status] } }, `
					Setting

				# TXT
				$lines = [System.Collections.Generic.List[string]]::new()
				$lines.Add("# ================================================================")
				$lines.Add("# sqmSQLTool - Server-Konfigurationsvergleich")
				$lines.Add("# $(Get-sqmReportReference)")
				$lines.Add("# Source            : $SourceInstance")
				$lines.Add("# Target            : $TargetInstance")
				$lines.Add("# Erstellt          : $timestamp")
				$lines.Add("# Critical: $cntCrit | Warning: $cntWarn | OK: $cntOk")
				$lines.Add("# ================================================================")
				$lines.Add("")
				$lines.Add(("{0,-9} {1,-14} {2,-40} {3,-30} {4}" -f 'Status', 'Kategorie', 'Setting', 'Source', 'Target'))
				$lines.Add(('-' * 130))
				foreach ($e in $sorted)
				{
					$settingShort = if ($e.Setting.Length -gt 40) { $e.Setting.Substring(0, 37) + '...' } else { $e.Setting }
					$lines.Add(("{0,-9} {1,-14} {2,-40} {3,-30} {4}" -f $e.Status, $e.Category, $settingShort, $e.SourceValue, $e.TargetValue))
				}
				[System.IO.File]::WriteAllText($txtFile, ($lines -join "`n"), [System.Text.Encoding]::UTF8)

				# HTML
				$rowsHtml = ''
				foreach ($e in $sorted)
				{
					$cls = switch ($e.Status) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'ok' } }
					$rowsHtml += "<tr>" +
						"<td class='$cls'>$(_h $e.Status)</td>" +
						"<td>$(_h $e.Category)</td>" +
						"<td>$(_h $e.Setting)</td>" +
						"<td>$(_h $e.SourceValue)</td>" +
						"<td>$(_h $e.TargetValue)</td>" +
						"</tr>`n"
				}
				$bodyHtml = @"
<table>
<thead><tr><th>Status</th><th>Kategorie</th><th>Setting</th><th>Source ($(_h $SourceInstance))</th><th>Target ($(_h $TargetInstance))</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<p style="color:#94a8c0;font-size:12px;">Critical: $cntCrit &nbsp;|&nbsp; Warning: $cntWarn &nbsp;|&nbsp; OK: $cntOk</p>
"@
				$html = ConvertTo-sqmHtmlReport -Title "Server-Konfigurationsvergleich" -Subtitle "$SourceInstance vs $TargetInstance - Erstellt: $timestamp" -BodyHtml $bodyHtml
				[System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.Encoding]::UTF8)

				Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
				Invoke-sqmLogging -Message "Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"
			}

			return $results
		}
		catch
		{
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return $null
		}
	}
}
