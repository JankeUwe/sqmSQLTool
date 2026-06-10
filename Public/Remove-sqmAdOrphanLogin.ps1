<#
.SYNOPSIS
    Removes Windows logins whose Active Directory account no longer exists (AD orphans).

.DESCRIPTION
    Safe, deliberate cleanup of "dead" AD logins on a SQL Server instance. This is the manual
    counterpart to the detection-only -AuditAdOrphans option of New-sqmAutoLoginSyncJob and is
    intentionally NOT meant for unattended or scheduled use: a missing AD account can be a
    transient domain controller or trust problem, and dropping a valid login would cause an outage.

    Safety model:
    1. The ActiveDirectory module is REQUIRED. If it is missing, -AdModuleAction controls behavior
       (default 'Abort'). Without AD lookups orphans cannot be verified, so nothing is deleted.
    2. Only Windows logins (WINDOWS_LOGIN / WINDOWS_GROUP) are considered.
    3. System logins and ALL sysadmin logins are excluded from removal, always.
    4. A login is treated as an orphan ONLY when Active Directory positively reports the account as
       missing. If the AD query fails, the login is skipped (never deleted).
    5. Logins that own a database are skipped (dropping them would fail or orphan the ownership).
    6. Before removal a rollback script (CREATE LOGIN FROM WINDOWS + server role memberships) is
       written per run, unless -SkipBackup is set.
    7. Every removal honors -WhatIf / -Confirm (ConfirmImpact = High), so nothing is dropped silently.

.PARAMETER SqlInstance
    Target SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the instance.

.PARAMETER ExcludeLogin
    Additional logins to exclude from removal (wildcards allowed). Combined with the always-on
    safety exclusions (system and sysadmin logins).

.PARAMETER AdModuleAction
    Behavior when the ActiveDirectory module is not present:
        'Abort'   (default) - stop with an error; nothing is verified or deleted.
        'Install'           - try Install-sqmAdModule, abort if it fails.
        'Skip'              - NOT allowed for a destructive operation; treated like 'Abort'.

.PARAMETER BackupPath
    Directory for the rollback script. Default: C:\System\WinSrvLog\MSSQL (created if missing).

.PARAMETER SkipBackup
    Skip writing the rollback script. Not recommended.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning error status.

.EXAMPLE
    Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -WhatIf
    Lists exactly which AD-orphaned logins would be removed, without changing anything.

.EXAMPLE
    Remove-sqmAdOrphanLogin -SqlInstance "SQL01"
    Removes confirmed AD-orphaned logins after a rollback backup, asking for confirmation per login.

.EXAMPLE
    Remove-sqmAdOrphanLogin -SqlInstance "SQL01" -ExcludeLogin 'DOMAIN\KeepThis*' -Confirm:$false
    Removes confirmed orphans (except the excluded pattern) without interactive confirmation.

.NOTES
    Requires: dbatools, Invoke-sqmLogging, ActiveDirectory module (RSAT), AD read rights.
    Needs: sysadmin on the instance.
    This function only verifies and removes. It does not run on a schedule by design.
#>
function Remove-sqmAdOrphanLogin
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Abort', 'Install', 'Skip')]
		[string]$AdModuleAction = 'Abort',

		[Parameter(Mandatory = $false)]
		[string]$BackupPath = 'C:\System\WinSrvLog\MSSQL',

		[Parameter(Mandatory = $false)]
		[switch]$SkipBackup,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'

		# Hilfsfunktion: Name gegen Muster pruefen
		function _MatchesAny
		{
			param ([string]$Name,
				[string[]]$Patterns)
			if (-not $Patterns) { return $false }
			foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
			return $false
		}

		# ActiveDirectory-Modul sicherstellen. Ohne AD KEINE Loeschung.
		$adAvailable = [bool](Get-Command -Name Get-ADObject -ErrorAction SilentlyContinue)
		if (-not $adAvailable)
		{
			$adAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
			if ($adAvailable) { Import-Module ActiveDirectory -ErrorAction SilentlyContinue }
		}
		if (-not $adAvailable -and $AdModuleAction -eq 'Install')
		{
			Invoke-sqmLogging -Message "ActiveDirectory-Modul nicht gefunden - starte Install-sqmAdModule." -FunctionName $functionName -Level 'INFO'
			$adAvailable = Install-sqmAdModule -ContinueOnError -SkipIfPresent $false
		}
		if (-not $adAvailable)
		{
			$msg = "ActiveDirectory-Modul nicht verfuegbar - AD-Orphans koennen nicht verifiziert werden. Es wird NICHTS geloescht. (AdModuleAction='$AdModuleAction')"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
			throw $msg
		}
	}

	process
	{
		try
		{
			# Immer ausgeschlossen: System-Logins
			$systemPatterns = @('##MS_*', '##*', 'NT SERVICE\*', 'NT AUTHORITY\*', 'BUILTIN\*')

			# Immer ausgeschlossen: alle sysadmin-Logins (inkl. umbenanntes 'sa')
			$sysAdminLogins = @()
			try
			{
				$saQuery = "SELECT name FROM sys.server_principals WHERE is_srvrolemember('sysadmin', name) = 1 AND name NOT LIKE '##%'"
				$sysAdminLogins = @((Invoke-DbaQuery @connParams -Query $saQuery).name)
			}
			catch
			{
				# Kann sysadmin-Liste nicht ermittelt werden: aus Sicherheit abbrechen.
				throw "Sysadmin-Logins konnten nicht ermittelt werden - Abbruch aus Sicherheitsgruenden: $($_.Exception.Message)"
			}

			# Windows-Logins laden
			$winLogins = @(Get-DbaLogin @connParams | Where-Object { $_.LoginType -in @('WindowsUser', 'WindowsGroup') })
			if ($winLogins.Count -eq 0)
			{
				Invoke-sqmLogging -Message "Keine Windows-Logins auf $SqlInstance gefunden." -FunctionName $functionName -Level 'INFO'
				return
			}

			# Backup-Datei vorbereiten (erst schreiben wenn ein Orphan tatsaechlich entfernt wird)
			$backupFile = $null
			if (-not $SkipBackup)
			{
				if (-not (Test-Path $BackupPath))
				{
					New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
				}
				$safeInst = $SqlInstance -replace '[\\/:*?"<>|]', '_'
				$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
				$backupFile = Join-Path $BackupPath "AdOrphanLoginBackup_${safeInst}_${ts}.sql"
			}

			foreach ($login in $winLogins)
			{
				$name = $login.Name

				# Safety-Ausschluesse
				if (_MatchesAny $name $systemPatterns) { continue }
				if ($sysAdminLogins -contains $name)
				{
					$results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; Login = $name; Status = 'Skipped'; Reason = 'sysadmin - nie entfernen'; BackupFile = $null; Timestamp = Get-Date })
					continue
				}
				if ($ExcludeLogin -and (_MatchesAny $name $ExcludeLogin))
				{
					$results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; Login = $name; Status = 'Skipped'; Reason = 'ExcludeLogin'; BackupFile = $null; Timestamp = Get-Date })
					continue
				}

				# AD-Pruefung: nur bei POSITIVEM "nicht vorhanden" als Orphan behandeln
				$samName = $name -replace '^.*\\', ''
				$isOrphan = $false
				try
				{
					$adObj = Get-ADObject -Filter { SamAccountName -eq $samName } -ErrorAction Stop | Select-Object -First 1
					if (-not $adObj) { $isOrphan = $true }
				}
				catch
				{
					# AD-Abfrage fehlgeschlagen -> NICHT loeschen
					$results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; Login = $name; Status = 'Skipped'; Reason = "AD-Abfrage fehlgeschlagen: $($_.Exception.Message)"; BackupFile = $null; Timestamp = Get-Date })
					continue
				}

				if (-not $isOrphan) { continue }

				# DB-Owner-Schutz: Logins die eine Datenbank besitzen nicht entfernen
				$ownedDbs = @()
				try
				{
					$ownerQuery = "SELECT name FROM sys.databases WHERE SUSER_SNAME(owner_sid) = @login"
					$ownedDbs = @((Invoke-DbaQuery @connParams -Query $ownerQuery -SqlParameter @{ login = $name }).name)
				}
				catch { }
				if ($ownedDbs.Count -gt 0)
				{
					$results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; Login = $name; Status = 'Skipped'; Reason = "Besitzt Datenbank(en): $($ownedDbs -join ', ') - Owner zuerst aendern"; BackupFile = $null; Timestamp = Get-Date })
					Invoke-sqmLogging -Message "[$name] AD-Orphan, aber DB-Owner ($($ownedDbs -join ', ')) - uebersprungen." -FunctionName $functionName -Level 'WARNING'
					continue
				}

				# Rollback-Skript schreiben (vor dem Drop)
				$thisBackup = $null
				if (-not $SkipBackup -and $PSCmdlet.ShouldProcess($name, "Rollback-Skript schreiben"))
				{
					try
					{
						$roleQuery = @"
SELECT r.name AS RoleName
FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
WHERE m.name = @login
"@
						$roles = @((Invoke-DbaQuery @connParams -Query $roleQuery -SqlParameter @{ login = $name }).RoleName)
						$nameEsc = $name -replace '\]', ']]'

						$lines = [System.Collections.Generic.List[string]]::new()
						$lines.Add("-- Rollback fuer AD-Orphan-Login: $name")
						$lines.Add("-- Instanz: $SqlInstance | Entfernt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
						$lines.Add("-- Hinweis: CREATE ... FROM WINDOWS funktioniert nur, wenn das AD-Konto wieder existiert.")
						$lines.Add("CREATE LOGIN [$nameEsc] FROM WINDOWS;")
						foreach ($r in $roles)
						{
							$rEsc = $r -replace '\]', ']]'
							$lines.Add("ALTER SERVER ROLE [$rEsc] ADD MEMBER [$nameEsc];")
						}
						$lines.Add("")
						$lines | Out-File -FilePath $backupFile -Append -Encoding UTF8
						$thisBackup = $backupFile
						Invoke-sqmLogging -Message "[$name] Rollback-Skript gesichert: $backupFile" -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						Invoke-sqmLogging -Message "[$name] WARNUNG: Rollback-Skript konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
					}
				}

				# Entfernen (ShouldProcess, ConfirmImpact High)
				if ($PSCmdlet.ShouldProcess($name, "AD-verwaistes Login entfernen (DROP LOGIN)"))
				{
					try
					{
						Remove-DbaLogin -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Login $name -Confirm:$false -EnableException | Out-Null
						$results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; Login = $name; Status = 'Removed'; Reason = 'AD-Konto nicht vorhanden'; BackupFile = $thisBackup; Timestamp = Get-Date })
						Invoke-sqmLogging -Message "[$name] AD-verwaistes Login entfernt." -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						$results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; Login = $name; Status = 'Failed'; Reason = $_.Exception.Message; BackupFile = $thisBackup; Timestamp = Get-Date })
						Invoke-sqmLogging -Message "[$name] Fehler beim Entfernen: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
						if ($EnableException) { throw }
					}
				}
				else
				{
					$results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; Login = $name; Status = 'WhatIf'; Reason = 'AD-Konto nicht vorhanden (wuerde entfernt)'; BackupFile = $thisBackup; Timestamp = Get-Date })
				}
			}
		}
		catch
		{
			Invoke-sqmLogging -Message "Fehler in ${functionName}: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
		}
	}

	end
	{
		$removed = @($results | Where-Object Status -eq 'Removed').Count
		$skipped = @($results | Where-Object Status -eq 'Skipped').Count
		$whatif  = @($results | Where-Object Status -eq 'WhatIf').Count
		$failed  = @($results | Where-Object Status -eq 'Failed').Count
		Invoke-sqmLogging -Message "$functionName abgeschlossen. Removed: $removed | WhatIf: $whatif | Skipped: $skipped | Failed: $failed" -FunctionName $functionName -Level 'INFO'
		return $results
	}
}
