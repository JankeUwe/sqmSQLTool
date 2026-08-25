<#
.SYNOPSIS
    Entsperrt einen durch CHECK_POLICY gesperrten SQL-Server-Login, optional mit
    Passwort-Reset, ohne CHECK_POLICY/CHECK_EXPIRATION dauerhaft zu veraendern.

.DESCRIPTION
    Deckt beide Standardfaelle eines gesperrten SQL-Auth-Logins (is_locked = 1, weil
    CHECK_POLICY = ON die Windows-Kontosperrrichtlinie durchsetzt) ab:

    1. Aktuelles Passwort bekannt, soll aber NICHT geaendert werden, nur entsperren.
    2. Aktuelles Passwort unbekannt/verloren -> echter Passwort-Reset noetig.

    T-SQL kennt kein eigenstaendiges "ALTER LOGIN ... UNLOCK" - UNLOCK ist nur zusammen
    mit der PASSWORD-Klausel erlaubt. Ohne -NewPassword nutzt diese Funktion deshalb den
    bekannten Umweg ueber CHECK_POLICY: kurzzeitig OFF und sofort wieder ON setzen loescht
    den von Windows verwalteten Sperrzustand, OHNE das Passwort anzufassen - das
    funktioniert unabhaengig davon, ob der Aufrufer das aktuelle Passwort kennt. Wird
    CHECK_POLICY/CHECK_EXPIRATION dabei nicht explizit angegeben, laesst SQL Server beide
    Flags unveraendert; diese Funktion verifiziert das zusaetzlich per sys.sql_logins
    NACH der Aktion, statt sich auf "keine Exception = alles wie vorher" zu verlassen.

    Mit -NewPassword wird stattdessen ein echter Reset per
    ALTER LOGIN ... WITH PASSWORD = @newpwd UNLOCK[, MUST_CHANGE] ausgefuehrt - auch hier
    bleiben CHECK_POLICY/CHECK_EXPIRATION unangetastet, da sie nicht mit angegeben werden.
    Das neue Passwort wird als SqlParameter uebergeben (nie in den Query-String
    interpoliert) und nirgends geloggt.

    Ist der Login laut LOGINPROPERTY(...,'IsLocked') beim Start bereits entsperrt und wird
    kein -NewPassword angegeben, tut die Funktion nichts (Status 'AlreadyUnlocked') statt
    unnoetig CHECK_POLICY zu toggeln.

.PARAMETER SqlInstance
    Ziel-SQL-Server-Instanz(en). Pipeline-faehig. Default: aktueller Computername.

.PARAMETER SqlCredential
    Optionales PSCredential fuer die Verbindung.

.PARAMETER Login
    Name des zu entsperrenden SQL-Server-Authentifizierungs-Logins.

.PARAMETER NewPassword
    Neues Passwort als SecureString. Ohne Angabe wird NUR entsperrt (CHECK_POLICY-
    Umweg), das bestehende Passwort bleibt unveraendert - das deckt sowohl "Passwort
    bekannt, aber nicht aendern" als auch "Passwort unbekannt, Login soll trotzdem mit
    seinem alten Passwort weiterlaufen" ab. Mit Angabe wird das Passwort per
    ALTER LOGIN ... PASSWORD = ... UNLOCK zurueckgesetzt.

.PARAMETER MustChange
    Nur zusammen mit -NewPassword gueltig: erzwingt Passwort-Aenderung bei der naechsten
    interaktiven Anmeldung (MUST_CHANGE). Setzt CHECK_EXPIRATION = ON auf dem Login voraus
    (SQL-Server-eigene Einschraenkung) - ist das nicht der Fall, bricht die Funktion vorab
    mit einer klaren Fehlermeldung ab statt die rohe SQL-Fehlermeldung durchzureichen.

.PARAMETER ContinueOnError
    Bei mehreren Instanzen mit dem naechsten weitermachen statt bei einem Fehler
    abzubrechen.

.PARAMETER EnableException
    Wirft Exceptions sofort (hat Vorrang vor -ContinueOnError).

.PARAMETER Confirm
    Fragt vor dem Entsperren/Zuruecksetzen nach.

.PARAMETER WhatIf
    Zeigt nur, was passieren wuerde, ohne etwas zu aendern.

.EXAMPLE
    Unlock-sqmSqlLogin -SqlInstance "SQL01" -Login "app_user"
    # Nur entsperren, Passwort bleibt exakt wie es war (Fall 1 und 2 aus der Anfrage).

.EXAMPLE
    $newPw = Read-Host -AsSecureString 'Neues Passwort'
    Unlock-sqmSqlLogin -SqlInstance "SQL01" -Login "app_user" -NewPassword $newPw -MustChange
    # Echter Reset, weil das alte Passwort nicht mehr bekannt ist.

.EXAMPLE
    "SQL01","SQL02" | Unlock-sqmSqlLogin -Login "app_user" -Confirm:$false

.OUTPUTS
    [PSCustomObject] mit SqlInstance, Login, WasLocked, PasswordChanged, CheckPolicy,
    CheckExpiration, IsLockedNow, Status, Message.

.NOTES
    Requires: dbatools (Invoke-DbaQuery), Invoke-sqmLogging.
    CHECK_POLICY delegiert die Sperrlogik an die lokale/domainweite Windows-
    Kontosperrrichtlinie (NetValidatePasswordPolicy) - ist dort kein Schwellenwert
    konfiguriert, wird ein SQL-Login nie gesperrt und diese Funktion meldet
    'AlreadyUnlocked'.
#>
function Unlock-sqmSqlLogin
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$Login,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$NewPassword,
		[Parameter(Mandatory = $false)]
		[switch]$MustChange,
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
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$passwordReset = $PSBoundParameters.ContainsKey('NewPassword')
		if ($MustChange -and -not $passwordReset)
		{
			$errMsg = "-MustChange setzt -NewPassword voraus."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$loginBracket = '[' + ($Login -replace '\]', ']]') + ']'
		$loginLit = $Login -replace "'", "''"

		$stateQuery = @"
SELECT
    is_disabled            AS IsDisabled,
    is_policy_checked      AS IsPolicyChecked,
    is_expiration_checked  AS IsExpirationChecked,
    LOGINPROPERTY(name, 'IsLocked')         AS IsLocked,
    LOGINPROPERTY(name, 'IsExpired')        AS IsExpired,
    LOGINPROPERTY(name, 'BadPasswordCount') AS BadPasswordCount,
    LOGINPROPERTY(name, 'LockoutTime')      AS LockoutTime
FROM sys.sql_logins
WHERE name = N'$loginLit';
"@

		$verifyQuery = @"
SELECT
    is_policy_checked      AS IsPolicyChecked,
    is_expiration_checked  AS IsExpirationChecked,
    LOGINPROPERTY(name, 'IsLocked') AS IsLocked
FROM sys.sql_logins
WHERE name = N'$loginLit';
"@

		Invoke-sqmLogging -Message "Starte $functionName fuer Login '$Login' (NewPassword angegeben: $passwordReset)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			$plainNewPassword = $null

			try
			{
				Invoke-sqmLogging -Message "[$instance] Pruefe Zustand von Login '$Login' ..." -FunctionName $functionName -Level "INFO"
				$stateRow = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop -Query $stateQuery

				if (-not $stateRow)
				{
					$msg = "Login '$Login' existiert nicht auf '$instance' (oder ist kein SQL-Auth-Login)."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results.Add([PSCustomObject]@{
							SqlInstance     = $instance
							Login		    = $Login
							WasLocked	    = $null
							PasswordChanged = $false
							CheckPolicy     = $null
							CheckExpiration = $null
							IsLockedNow     = $null
							Status		    = 'NotFound'
							Message		    = $msg
						})
					continue
				}

				$wasLocked = [bool][int]$stateRow.IsLocked
				$originalCheckPolicy = [bool][int]$stateRow.IsPolicyChecked
				$originalCheckExpiration = [bool][int]$stateRow.IsExpirationChecked

				if ($MustChange -and -not $originalCheckExpiration)
				{
					throw "-MustChange erfordert CHECK_EXPIRATION = ON auf '$Login'@'$instance' (aktuell OFF)."
				}

				if (-not $wasLocked -and -not $passwordReset)
				{
					$msg = "Login '$Login' auf '$instance' ist laut LOGINPROPERTY nicht gesperrt - keine Aktion noetig."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
					$results.Add([PSCustomObject]@{
							SqlInstance     = $instance
							Login		    = $Login
							WasLocked	    = $false
							PasswordChanged = $false
							CheckPolicy     = $originalCheckPolicy
							CheckExpiration = $originalCheckExpiration
							IsLockedNow     = $false
							Status		    = 'AlreadyUnlocked'
							Message		    = $msg
						})
					continue
				}

				$actionLabel = if ($passwordReset) { "Passwort zuruecksetzen und entsperren" }
				else { "entsperren (Passwort bleibt unveraendert)" }

				if ($PSCmdlet.ShouldProcess("Login '$Login' auf '$instance'", $actionLabel))
				{
					Invoke-sqmLogging -Message "[$instance] $actionLabel fuer Login '$Login' ..." -FunctionName $functionName -Level "INFO"

					if ($passwordReset)
					{
						$pwCred = New-Object System.Management.Automation.PSCredential('placeholder', $NewPassword)
						$plainNewPassword = $pwCred.GetNetworkCredential().Password
						$mustChangeClause = if ($MustChange) { ', MUST_CHANGE' } else { '' }
						$actionQuery = "ALTER LOGIN $loginBracket WITH PASSWORD = @newpwd UNLOCK$mustChangeClause;"
						Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop `
							-Query $actionQuery -SqlParameter @{ newpwd = $plainNewPassword }
					}
					else
					{
						$actionQuery = "ALTER LOGIN $loginBracket WITH CHECK_POLICY = OFF; ALTER LOGIN $loginBracket WITH CHECK_POLICY = ON;"
						Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop -Query $actionQuery
					}

					# Nachpruefen statt auf "keine Exception = Erfolg" zu vertrauen.
					$verifyRow = Invoke-DbaQuery @connParams -Database master -EnableException -ErrorAction Stop -Query $verifyQuery
					if (-not $verifyRow)
					{
						throw "Login '$Login' auf '$instance' ist nach der Aktion ueber sys.sql_logins nicht mehr auffindbar."
					}

					$isLockedNow = [bool][int]$verifyRow.IsLocked
					$checkPolicyNow = [bool][int]$verifyRow.IsPolicyChecked
					$checkExpirationNow = [bool][int]$verifyRow.IsExpirationChecked

					if ($isLockedNow)
					{
						throw "Aktion lief ohne Fehler, aber Login '$Login' auf '$instance' ist laut LOGINPROPERTY weiterhin gesperrt."
					}
					if ($checkPolicyNow -ne $originalCheckPolicy -or $checkExpirationNow -ne $originalCheckExpiration)
					{
						throw "CHECK_POLICY/CHECK_EXPIRATION von '$Login' auf '$instance' hat sich unerwartet veraendert (vorher POLICY=$originalCheckPolicy/EXPIRATION=$originalCheckExpiration, jetzt POLICY=$checkPolicyNow/EXPIRATION=$checkExpirationNow)."
					}

					$msg = "Login '$Login' auf '$instance' erfolgreich $actionLabel."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
					$results.Add([PSCustomObject]@{
							SqlInstance     = $instance
							Login		    = $Login
							WasLocked	    = $wasLocked
							PasswordChanged = $passwordReset
							CheckPolicy     = $checkPolicyNow
							CheckExpiration = $checkExpirationNow
							IsLockedNow     = $isLockedNow
							Status		    = 'Success'
							Message		    = $msg
						})
				}
				else
				{
					$msg = "WhatIf: $actionLabel fuer Login '$Login' auf '$instance' uebersprungen."
					Invoke-sqmLogging -Message "[$instance] $msg" -FunctionName $functionName -Level "VERBOSE"
					$results.Add([PSCustomObject]@{
							SqlInstance     = $instance
							Login		    = $Login
							WasLocked	    = $wasLocked
							PasswordChanged = $false
							CheckPolicy     = $originalCheckPolicy
							CheckExpiration = $originalCheckExpiration
							IsLockedNow     = $wasLocked
							Status		    = 'WhatIfSkipped'
							Message		    = $msg
						})
				}
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$results.Add([PSCustomObject]@{
						SqlInstance     = $instance
						Login		    = $Login
						WasLocked	    = $null
						PasswordChanged = $false
						CheckPolicy     = $null
						CheckExpiration = $null
						IsLockedNow     = $null
						Status		    = 'Failed'
						Message		    = $errMsg
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw }
			}
			finally
			{
				$plainNewPassword = $null
			}
		}
		return $results
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}
