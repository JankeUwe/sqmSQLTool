<#
.SYNOPSIS
    Obfuscates the SA account on a SQL Server instance by renaming it, disabling it, and setting a random password.

.DESCRIPTION
    Performs the following steps:
    1. Checks that at least one other active login with sysadmin rights exists (aborts otherwise).
    2. Identifies the SA account via its fixed SID 0x01 (rename-safe).
    3. Generates a secure random password (configurable length).
    4. Sets the new password.
    5. Renames the account (default: 'sqmsa').
    6. Disables the account.

    The generated password is returned in the output object — the caller is responsible for storing it securely.

.PARAMETER SqlInstance
    Target SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the SQL connection.

.PARAMETER NewName
    New name for the SA account. Default: 'sqmsa'.

.PARAMETER PasswordLength
    Length of the random password (12-128). Default: 18.

.PARAMETER ContinueOnError
    Continue with the next instance on error (otherwise aborts).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Prompts for confirmation before critical changes (default: off).

.PARAMETER WhatIf
    Shows what would happen without making any changes.

.EXAMPLE
    Invoke-sqmSaObfuscation -SqlInstance "SQL01"

.EXAMPLE
    Invoke-sqmSaObfuscation -SqlInstance "SQL01" -NewName "hidden_sa" -PasswordLength 24

.NOTES
    Prerequisites: dbatools, Invoke-sqmLogging
    The generated password is only returned in the output object — do not store it in files!
#>
function Invoke-sqmSaObfuscation
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$NewName = 'sqmsa',
		[Parameter(Mandatory = $false)]
		[ValidateRange(12, 128)]
		[int]$PasswordLength = 18,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		Invoke-sqmLogging -Message "Starte $functionName" -FunctionName $functionName -Level "INFO"
		
		# Kryptografisch sicherer Passwortgenerator
		function _GeneratePassword
		{
			param ([int]$Length)
			$upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ' # ohne I,O
			$lower = 'abcdefghjkmnpqrstuvwxyz' # ohne i,l,o
			$digits = '23456789' # ohne 0,1
			$special = '!@#$%^&*()-_=+[]{}|;:,.<>?'
			$allChars = $upper + $lower + $digits + $special
			$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
			$pwChars = [System.Collections.Generic.List[char]]::new()
			# Mindestens ein Zeichen jeder Klasse
			foreach ($pool in @($upper, $lower, $digits, $special))
			{
				$buf = [byte[]]::new(1)
				do { $rng.GetBytes($buf) }
				while ($buf[0] -ge (256 - (256 % $pool.Length)))
				$pwChars.Add($pool[$buf[0] % $pool.Length])
			}
			# Restliche Zeichen
			for ($i = $pwChars.Count; $i -lt $Length; $i++)
			{
				$buf = [byte[]]::new(1)
				do { $rng.GetBytes($buf) }
				while ($buf[0] -ge (256 - (256 % $allChars.Length)))
				$pwChars.Add($allChars[$buf[0] % $allChars.Length])
			}
			# Fisher-Yates-Shuffle
			$arr = $pwChars.ToArray()
			for ($i = $arr.Length - 1; $i -gt 0; $i--)
			{
				$buf = [byte[]]::new(4)
				$rng.GetBytes($buf)
				$j = [System.BitConverter]::ToUInt32($buf, 0) % ($i + 1)
				$tmp = $arr[$i]; $arr[$i] = $arr[$j]; $arr[$j] = $tmp
			}
			$rng.Dispose()
			return -join $arr
		}
	}
	
	process
	{
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			$originalName = $null
			$sysadminAccts = @()
			$renamed = $false
			$disabled = $false
			$passwordSet = $false
			$generatedPw = $null
			$activeOthers = 0
			
			try
			{
				# ---- 1. Sicherheitspruefung: Andere aktive sysadmin-Konten vorhanden? ----
				$sysadminQuery = @"
SELECT
    sp.name                          AS LoginName,
    sp.type_desc                     AS LoginType,
    sp.is_disabled                   AS IsDisabled,
    CASE WHEN sp.sid = 0x01 THEN 1 ELSE 0 END AS IsSa
FROM sys.server_principals       sp
JOIN sys.server_role_members     rm ON rm.member_principal_id = sp.principal_id
JOIN sys.server_principals       sr ON sr.principal_id        = rm.role_principal_id
WHERE sr.name = 'sysadmin'
  AND sp.type IN ('S','U','G','R')
  AND sp.principal_id > 1
ORDER BY sp.name;
"@
				$sysadminLogins = Invoke-DbaQuery @connParams -Query $sysadminQuery -EnableException:$EnableException
				$otherSysadmins = @($sysadminLogins | Where-Object { $_.IsSa -eq 0 })
				$activeOthers = @($otherSysadmins | Where-Object { $_.IsDisabled -eq $false }).Count
				$sysadminAccts = $otherSysadmins | Select-Object -ExpandProperty LoginName
				
				if ($activeOthers -eq 0)
				{
					$abortMsg = "ABBRUCH: Kein weiteres aktives sysadmin-Login auf '$instance' gefunden. Fuege zuerst ein zusaetzliches sysadmin-Konto hinzu."
					Invoke-sqmLogging -Message $abortMsg -FunctionName $functionName -Level "ERROR"
					$allResults.Add([PSCustomObject]@{
							SqlInstance	      = $instance
							OriginalLoginName = '(unbekannt)'
							NewLoginName	  = $NewName
							GeneratedPassword = $null
							PasswordLength    = $PasswordLength
							SysadminCheck	  = 0
							SysadminAccounts  = @()
							Renamed		      = $false
							Disabled		  = $false
							PasswordSet	      = $false
							Status		      = 'AbortedNoSysadmin'
							Message		      = $abortMsg
						})
					if (-not $ContinueOnError -and -not $EnableException) { throw $abortMsg }
					continue
				}
				Invoke-sqmLogging -Message "[$instance] Sicherheitspruefung bestanden: $activeOthers aktive sysadmin-Konten." -FunctionName $functionName -Level "INFO"
				
				# ---- 2. SA-Login via SID 0x01 ermitteln ----
				$saQuery = "SELECT name FROM sys.server_principals WHERE sid = 0x01"
				$saRow = Invoke-DbaQuery @connParams -Query $saQuery -EnableException:$EnableException
				if (-not $saRow) { throw "SA-Konto (SID 0x01) nicht gefunden." }
				$originalName = $saRow.name
				Invoke-sqmLogging -Message "[$instance] SA-Konto gefunden: '$originalName'" -FunctionName $functionName -Level "INFO"
				
				# ---- 3. Zufaelliges Kennwort generieren ----
				$generatedPw = _GeneratePassword -Length $PasswordLength
				Invoke-sqmLogging -Message "[$instance] Kennwort generiert ($PasswordLength Zeichen)." -FunctionName $functionName -Level "VERBOSE"
				
				# ---- 4. Kennwort setzen ----
				if ($PSCmdlet.ShouldProcess($instance, "Setze Kennwort fuer Login '$originalName'"))
				{
					$pwEscaped = $generatedPw -replace "'", "''"
					$pwQuery = "ALTER LOGIN [$originalName] WITH PASSWORD = '$pwEscaped';"
					Invoke-DbaQuery @connParams -Query $pwQuery -EnableException:$EnableException
					$passwordSet = $true
					Invoke-sqmLogging -Message "[$instance] Kennwort gesetzt." -FunctionName $functionName -Level "INFO"
				}
				
				# ---- 5. Umbenennung (falls noetig) ----
				if ($originalName -ne $NewName)
				{
					if ($PSCmdlet.ShouldProcess($instance, "Benenne Login '$originalName' um in '$NewName'"))
					{
						$renameQuery = "ALTER LOGIN [$originalName] WITH NAME = [$NewName];"
						Invoke-DbaQuery @connParams -Query $renameQuery -EnableException:$EnableException
						$renamed = $true
						Invoke-sqmLogging -Message "[$instance] Login umbenannt: '$originalName' ? '$NewName'" -FunctionName $functionName -Level "INFO"
					}
				}
				else
				{
					Invoke-sqmLogging -Message "[$instance] Login heisst bereits '$NewName' - Umbenennung uebersprungen." -FunctionName $functionName -Level "VERBOSE"
					$renamed = $true
				}
				
				# ---- 6. Deaktivieren ----
				$effectiveName = if ($renamed) { $NewName }
				else { $originalName }
				if ($PSCmdlet.ShouldProcess($instance, "Deaktiviere Login '$effectiveName'"))
				{
					$disableQuery = "ALTER LOGIN [$effectiveName] DISABLE;"
					Invoke-DbaQuery @connParams -Query $disableQuery -EnableException:$EnableException
					$disabled = $true
					Invoke-sqmLogging -Message "[$instance] Login '$effectiveName' deaktiviert." -FunctionName $functionName -Level "INFO"
				}
				
				$successMsg = "SA-Verschleierung erfolgreich: '$originalName' ? '$effectiveName', deaktiviert, Kennwort gesetzt ($PasswordLength Zeichen)."
				Invoke-sqmLogging -Message $successMsg -FunctionName $functionName -Level "INFO"
				
				$allResults.Add([PSCustomObject]@{
						SqlInstance	      = $instance
						OriginalLoginName = $originalName
						NewLoginName	  = $effectiveName
						GeneratedPassword = $generatedPw
						PasswordLength    = $PasswordLength
						SysadminCheck	  = $activeOthers
						SysadminAccounts  = $sysadminAccts
						Renamed		      = $renamed
						Disabled		  = $disabled
						PasswordSet	      = $passwordSet
						Status		      = 'Success'
						Message		      = $successMsg
					})
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						SqlInstance	      = $instance
						OriginalLoginName = if ($originalName) { $originalName } else { '(unbekannt)' }
						NewLoginName	  = $NewName
						GeneratedPassword = $generatedPw
						PasswordLength    = $PasswordLength
						SysadminCheck	  = $activeOthers
						SysadminAccounts  = $sysadminAccts
						Renamed		      = $renamed
						Disabled		  = $disabled
						PasswordSet	      = $passwordSet
						Status		      = 'Failed'
						Message		      = $errMsg
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw }
			}
		}
		return $allResults
	}
}