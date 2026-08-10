<#
.SYNOPSIS
Exports the SQL-authentication logins backing a database's users as a portable, self-contained
T-SQL script (password hash + SID), for later application on a different, possibly unreachable
instance via Import-sqmDatabaseLogins.

.DESCRIPTION
Some databases (e.g. an application like "Frontarena") are periodically copied from Production to
Test and restored there (Invoke-sqmRestoreDatabase). The restore brings the database's SQL-auth
users (with their Production SIDs) over correctly, but the matching server-level Logins - and in
particular their current password - normally live only on Production and change there from time
to time (password policy/expiry). Test never learns about those changes, so end users authenticate
against Test with a stale or altogether missing/mismatched password.

Production and Test are not guaranteed to be in the same domain/network - a live connection from
one control host to both instances at the same time (as Copy-sqmLogins/Copy-DbaLogin require) is
NOT a safe assumption. This function therefore only ever connects to -SqlInstance (the source) and
writes a plain .sql file to -OutputPath. Getting that file from the source side to wherever
Import-sqmDatabaseLogins will read it (-InputPath) is a separate, external transport (file share,
scheduled copy job, etc.) that is explicitly OUT OF SCOPE here - this function does not attempt any
network access to a destination.

The generated script contains one self-contained, idempotent block per login (no dependency on
execution order, safe to run more than once):
    - If a login with the same SID already exists: only the password (and CHECK_POLICY/
      CHECK_EXPIRATION) is refreshed via ALTER LOGIN - the login itself is left alone.
    - If a login with the same NAME but a different SID exists: it is dropped and recreated with
      the source's SID and password hash (this is what actually fixes orphaned database users -
      a same-named Test login created independently of Production almost always has a different
      SID).
    - If no login with that name exists at all: it is created outright.
    - Before ever dropping/recreating an existing login, the block re-checks (on whichever server
      it is executed against) whether that login is a member of the sysadmin role or is the
      well-known 'sa' account (SID 0x01) - if so, it is left completely untouched and only a PRINT
      notice is emitted. This is a second, independent safety net: sysadmin/system logins are
      already excluded from the export below and can never end up in the file in the first place,
      but the check is repeated in the executable script itself so that even a hand-edited or
      accidentally-misdirected file (e.g. run against the wrong instance) cannot touch one.

Logins are always excluded from the export, with no override:
    - 'sa' (identified by the well-known SID 0x01, independent of any rename)
    - every login that is currently a member of the sysadmin server role
    - '##MS_*', 'NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*'
Only SQL Server authentication logins (type 'S') that back an actual database user of -Database
are considered in the first place - Windows logins/groups are not part of this export.

.PARAMETER SqlInstance
Source SQL Server instance (Production). Mandatory. Only this instance is ever contacted.

.PARAMETER SqlCredential
Credential for -SqlInstance.

.PARAMETER Database
Name of the database whose SQL-authentication users' logins should be exported. Mandatory.

.PARAMETER OutputPath
Target path for the generated script. Either a full file path, or an existing/creatable directory
- in the latter case the file is named
"DatabaseLogins_<Database>_<SqlInstance>_<yyyyMMddHHmmss>.sql" inside it. Any path is accepted
(local disk, UNC share, ...) - how the file subsequently reaches the destination side is outside
this function's responsibility.

.PARAMETER Login
Restricts the export to these login names (wildcards allowed). Without this, every SQL-auth login
backing a user of -Database is exported (after the sysadmin/system exclusion above).

.PARAMETER ExcludeLogin
Additional logins to exclude (wildcards allowed), e.g. a shared service account that should keep
an independent Test-side password.

.PARAMETER EnableException
Throw exceptions immediately instead of returning a Failed result object.

.PARAMETER Confirm
Request confirmation before writing the output file.

.PARAMETER WhatIf
Shows what would be written without creating the file.

.EXAMPLE
Export-sqmDatabaseLogins -SqlInstance 'ProdSQL' -Database 'Frontarena' -OutputPath '\\Share\Handover\Frontarena_Logins.sql'

Exports every SQL-auth login backing a Frontarena user on ProdSQL to the given share. An external,
separately controlled process is then responsible for copying that file into the Test network.

.EXAMPLE
Export-sqmDatabaseLogins -SqlInstance 'ProdSQL' -Database 'Frontarena' -OutputPath 'C:\Temp' -ExcludeLogin 'SvcAccount_*'

Writes into an auto-named file inside C:\Temp, skipping any login starting with 'SvcAccount_'.

.NOTES
Prerequisites : dbatools, Invoke-sqmLogging
Counterpart   : Import-sqmDatabaseLogins (applies the generated file against the destination).
Combined use  : Sync-sqmDatabaseLogins (when one control host can reach both instances directly).
#>
function Export-sqmDatabaseLogins
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $true)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[string[]]$Login,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		# Escaping-Helfer fuer T-SQL-Literale/-Bezeichner
		function _SqlLit([string]$s) { $s -replace "'", "''" }
		function _SqlIdent([string]$s) { $s -replace '\]', ']]' }

		function _MatchesAnyPattern([string]$Name, [string[]]$Patterns)
		{
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}
	}

	process
	{
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		try
		{
			Invoke-sqmLogging -Message "Verbinde mit Quelle '$SqlInstance'." -FunctionName $functionName -Level 'INFO'
			$null = Connect-DbaInstance @connParams

			# ---- 1. SQL-Auth-User der Datenbank ermitteln ----
			$userQuery = @"
SELECT dp.name AS UserName
FROM sys.database_principals dp
WHERE dp.type = 'S'
  AND dp.sid IS NOT NULL
  AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
"@
			$dbUsers = @(Invoke-DbaQuery @connParams -Database $Database -Query $userQuery -EnableException | Select-Object -ExpandProperty UserName)

			if ($dbUsers.Count -eq 0)
			{
				$msg = "Keine SQL-Auth-User in Datenbank '$Database' auf '$SqlInstance' gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
				Write-Warning $msg
				return [PSCustomObject]@{
					SourceInstance = $SqlInstance; Database = $Database; OutputFile = $null
					LoginCount = 0; ExcludedSysadminCount = 0; Status = 'Skipped'; Message = $msg; Timestamp = Get-Date
				}
			}
			Invoke-sqmLogging -Message "$($dbUsers.Count) SQL-Auth-User in '$Database' gefunden." -FunctionName $functionName -Level 'INFO'

			# ---- 2. sysadmin/System-Logins IMMER ausschliessen (kein Override) ----
			$systemLoginPatterns = @('##MS_*', 'NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*')
			try
			{
				$saLoginName = (Invoke-DbaQuery @connParams -Query "SELECT SUSER_SNAME(0x01) AS n").n
				if (-not [string]::IsNullOrWhiteSpace($saLoginName)) { $systemLoginPatterns += $saLoginName }
			}
			catch
			{
				Invoke-sqmLogging -Message "'sa'-Erkennung ueber SID 0x01 fehlgeschlagen: $($_.Exception.Message)." `
								  -FunctionName $functionName -Level 'WARNING'
			}

			$sysAdminLogins = @()
			try
			{
				$query = "SELECT name FROM sys.server_principals WHERE (is_srvrolemember('sysadmin', name) = 1 OR sid = 0x01) AND name NOT LIKE '##%'"
				$sysAdminLogins = @((Invoke-DbaQuery @connParams -Query $query -EnableException).name)
			}
			catch
			{
				Invoke-sqmLogging -Message "Sysadmin-Logins konnten nicht ermittelt werden, verwende 'sa' als Fallback: $($_.Exception.Message)" `
								  -FunctionName $functionName -Level 'WARNING'
				$sysAdminLogins = @('sa')
			}

			$candidateNames = @($dbUsers | Where-Object {
					$_ -notin $sysAdminLogins -and -not (_MatchesAnyPattern $_ $systemLoginPatterns)
				})
			$excludedSysadminCount = $dbUsers.Count - $candidateNames.Count
			if ($excludedSysadminCount -gt 0)
			{
				Invoke-sqmLogging -Message "$excludedSysadminCount sysadmin-/System-Login(s) von der Kandidatenliste ausgeschlossen." `
								  -FunctionName $functionName -Level 'INFO'
			}

			# ---- 3. -Login / -ExcludeLogin Filter ----
			if ($Login)
			{
				$candidateNames = @($candidateNames | Where-Object { $n = $_; ($Login | Where-Object { $n -like $_ }).Count -gt 0 })
			}
			if ($ExcludeLogin)
			{
				$candidateNames = @($candidateNames | Where-Object { -not (_MatchesAnyPattern $_ $ExcludeLogin) })
			}

			if ($candidateNames.Count -eq 0)
			{
				$msg = "Keine Logins nach Filter-Anwendung uebrig (Datenbank '$Database' auf '$SqlInstance')."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
				Write-Warning $msg
				return [PSCustomObject]@{
					SourceInstance = $SqlInstance; Database = $Database; OutputFile = $null
					LoginCount = 0; ExcludedSysadminCount = $excludedSysadminCount; Status = 'Skipped'; Message = $msg; Timestamp = Get-Date
				}
			}

			# ---- 4. Login-Metadaten laden (SID, Kennwort-Hash, Policy-Flags) ----
			$inClause = ($candidateNames | ForEach-Object { "N'$(_SqlLit $_)'" }) -join ', '
			$metaQuery = @"
SELECT
    sp.name AS LoginName,
    CONVERT(varchar(300), sp.sid, 2) AS SidHex,
    CONVERT(varchar(300), sl.password_hash, 2) AS PasswordHashHex,
    sl.is_policy_checked AS IsPolicyChecked,
    sl.is_expiration_checked AS IsExpirationChecked,
    sl.default_database_name AS DefaultDatabaseName
FROM sys.server_principals sp
JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type = 'S' AND sp.name IN ($inClause)
"@
			$loginRows = @(Invoke-DbaQuery @connParams -Query $metaQuery -EnableException)

			$missingOnSource = @($candidateNames | Where-Object { $_ -notin $loginRows.LoginName })
			foreach ($m in $missingOnSource)
			{
				Invoke-sqmLogging -Message "Datenbank-User '$m' hat auf '$SqlInstance' kein passendes Server-Login mehr (verwaist) - wird uebersprungen." `
								  -FunctionName $functionName -Level 'WARNING'
			}

			# ---- 5. Pro Login einen eigenstaendigen, idempotenten Block bauen ----
			$blocks = [System.Collections.Generic.List[string]]::new()
			foreach ($row in $loginRows)
			{
				$nameLit = _SqlLit $row.LoginName
				$idLit = _SqlIdent $row.LoginName
				$sidHex = "0x$($row.SidHex)"
				$hashHex = "0x$($row.PasswordHashHex)"
				$checkPolicy = if ($row.IsPolicyChecked) { 'ON' } else { 'OFF' }
				$checkExpiration = if ($row.IsExpirationChecked) { 'ON' } else { 'OFF' }
				# DEFAULT_DATABASE nur uebernehmen, wenn es die gerade synchronisierte Datenbank oder eine
				# Systemdatenbank ist - jede andere Quell-Datenbank existiert auf dem Ziel womoeglich nicht,
				# und CREATE LOGIN schlaegt fehl, wenn DEFAULT_DATABASE nicht existiert.
				$rawDefaultDb = $row.DefaultDatabaseName
				$defaultDb = if ($rawDefaultDb -eq $Database -or $rawDefaultDb -in @('master', 'tempdb', 'model', 'msdb')) { $rawDefaultDb }
				else { 'master' }
				$defaultDbIdent = _SqlIdent $defaultDb

				$block = @"
-- ===LOGIN:$($row.LoginName)===
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE sid = $sidHex)
BEGIN
    IF EXISTS (SELECT 1 FROM sys.server_principals WHERE sid = $sidHex AND name = N'$nameLit')
        ALTER LOGIN [$idLit] WITH PASSWORD = $hashHex HASHED, CHECK_POLICY = $checkPolicy, CHECK_EXPIRATION = $checkExpiration;
    ELSE
        PRINT N'UEBERSPRUNGEN: SID $sidHex gehoert bereits zu einem anders benannten Login (Quelle: $nameLit).';
END
ELSE IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$nameLit')
BEGIN
    IF IS_SRVROLEMEMBER('sysadmin', N'$nameLit') = 1 OR (SELECT sid FROM sys.server_principals WHERE name = N'$nameLit') = 0x01
        PRINT N'SICHERHEIT: $nameLit ist sysadmin/sa auf diesem Server - NICHT angefasst.';
    ELSE
    BEGIN
        DROP LOGIN [$idLit];
        CREATE LOGIN [$idLit] WITH PASSWORD = $hashHex HASHED, SID = $sidHex, CHECK_POLICY = $checkPolicy, CHECK_EXPIRATION = $checkExpiration, DEFAULT_DATABASE = [$defaultDbIdent];
    END
END
ELSE
BEGIN
    CREATE LOGIN [$idLit] WITH PASSWORD = $hashHex HASHED, SID = $sidHex, CHECK_POLICY = $checkPolicy, CHECK_EXPIRATION = $checkExpiration, DEFAULT_DATABASE = [$defaultDbIdent];
END
"@
				$blocks.Add($block)
			}

			# ---- 6. Zielpfad aufloesen (Datei oder Verzeichnis) ----
			$isDirectory = (Test-Path -Path $OutputPath -PathType Container) -or ([string]::IsNullOrEmpty([System.IO.Path]::GetExtension($OutputPath)))
			if ($isDirectory)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeDb = ($Database -replace '[\\/:*?"<>|]', '_')
				$safeInst = ($SqlInstance -replace '[\\/:*?"<>|]', '_')
				$fileName = "DatabaseLogins_${safeDb}_${safeInst}_$(Get-Date -Format 'yyyyMMddHHmmss').sql"
				$finalOutputFile = Join-Path $OutputPath $fileName
			}
			else
			{
				$parentDir = Split-Path -Path $OutputPath -Parent
				if ($parentDir -and -not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
				$finalOutputFile = $OutputPath
			}

			# ---- 7. Header + Bloecke zusammenfuehren und schreiben ----
			$header = @"
-- =====================================================================
-- Export-sqmDatabaseLogins
-- Quelle        : $SqlInstance
-- Datenbank     : $Database
-- Zeitstempel   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
-- Login-Anzahl  : $($blocks.Count)
-- Sysadmin/System-Logins ausgeschlossen: $excludedSysadminCount
-- =====================================================================
-- Eigenstaendig ausfuehrbar (z. B. in SSMS) und idempotent - jeder Block ist ein
-- unabhaengiges Statement, kein GO zwischen den Bloecken erforderlich.
-- sysadmin-/sa-Logins werden NIE angefasst (Pruefung ist in jedem Block eingebaut).
-- =====================================================================

"@
			$fullContent = $header + ($blocks -join "`r`n`r`n")

			$writeAction = "$($blocks.Count) Login(s) aus '$Database' auf '$SqlInstance' nach '$finalOutputFile' exportieren"
			if ($PSCmdlet.ShouldProcess($finalOutputFile, $writeAction))
			{
				[System.IO.File]::WriteAllText($finalOutputFile, $fullContent, (New-Object System.Text.UTF8Encoding($false)))
				Invoke-sqmLogging -Message "Export geschrieben: $finalOutputFile ($($blocks.Count) Login(s))." -FunctionName $functionName -Level 'INFO'
				Write-Host "Export-sqmDatabaseLogins: $($blocks.Count) Login(s) nach '$finalOutputFile' geschrieben (sysadmin ausgeschlossen: $excludedSysadminCount)." -ForegroundColor Green

				return [PSCustomObject]@{
					SourceInstance		  = $SqlInstance
					Database			  = $Database
					OutputFile			  = $finalOutputFile
					LoginCount		      = $blocks.Count
					ExcludedSysadminCount = $excludedSysadminCount
					Status			      = 'Success'
					Message			      = "Export erfolgreich."
					Timestamp			  = Get-Date
				}
			}
			else
			{
				return [PSCustomObject]@{
					SourceInstance		  = $SqlInstance
					Database			  = $Database
					OutputFile			  = $finalOutputFile
					LoginCount		      = $blocks.Count
					ExcludedSysadminCount = $excludedSysadminCount
					Status			      = 'WhatIf'
					Message			      = "WhatIf - Datei wuerde geschrieben."
					Timestamp			  = Get-Date
				}
			}
		}
		catch
		{
			$errMsg = "Fehler in Export-sqmDatabaseLogins: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			Write-Error $errMsg
			return [PSCustomObject]@{
				SourceInstance = $SqlInstance; Database = $Database; OutputFile = $null
				LoginCount = 0; ExcludedSysadminCount = 0; Status = 'Failed'; Message = $errMsg; Timestamp = Get-Date
			}
		}
	}
}
