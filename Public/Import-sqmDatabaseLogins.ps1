<#
.SYNOPSIS
Applies a login-password/SID export produced by Export-sqmDatabaseLogins against a destination
instance, then repairs any remaining orphaned database users.

.DESCRIPTION
Counterpart to Export-sqmDatabaseLogins. Reads the self-contained T-SQL script written by that
function - already placed at -InputPath by some external, separately controlled transport (file
share, scheduled copy job, ...; getting the file from the Production side to here is explicitly
NOT this function's responsibility, since the two sides may be in domains/networks that cannot
reach each other directly) - and executes it against -SqlInstance (the destination, e.g. Test).

Only -SqlInstance is ever contacted here; there is no connection back to the original source.

Process:
    1. Read -InputPath, parse the header (source instance/database/timestamp/login count, purely
       informational/audit) and split the file into its per-login blocks
       (each one is the self-contained, idempotent unit Export-sqmDatabaseLogins generated -
       see that function's help for exactly what each block does and how it protects sysadmin/
       'sa' logins).
    2. Temporarily disable the configured PBM policy on -SqlInstance (Set-sqmSqlPolicyState),
       exactly as long as step 3 runs - guaranteed re-enabled afterwards via a finally block, even
       on error.
    3. Execute every block individually (not as one combined script) so each of the potentially
       ~1500 logins gets its own result entry (Status Success / SkippedSysadmin /
       SkippedSidCollision / Failed) instead of one all-or-nothing outcome. A block's own PRINT
       output (emitted when it deliberately left a sysadmin/'sa' login alone, or found a SID
       already claimed by a differently-named login) is captured and reflected in that entry's
       Status - this is how the sysadmin-protection built into the file becomes visible/auditable
       here, not just a silent no-op.
    4. Run Repair-DbaDbOrphanUser against -Database on -SqlInstance, exactly as
       Invoke-sqmRestoreDatabase and Copy-sqmLogins already do after any login change.

.PARAMETER SqlInstance
Destination SQL Server instance (e.g. Test). Mandatory. Only this instance is ever contacted.

.PARAMETER SqlCredential
Credential for -SqlInstance.

.PARAMETER InputPath
Path to the .sql file produced by Export-sqmDatabaseLogins (already transported here by an
external process). Mandatory.

.PARAMETER Database
Database to run the final orphan-user repair against. Mandatory. Compared against the database
name recorded in the file's header - a mismatch only produces a warning, it does not block the run
(the caller may deliberately be applying the export under a different database name).

.PARAMETER DisablePolicy
Controls whether the configured default PBM policy on -SqlInstance is disabled before applying the
logins and re-enabled afterwards (via Set-sqmSqlPolicyState). Default: $true.

.PARAMETER ContinueOnError
Continue with the next login block if one fails, instead of aborting the whole run.

.PARAMETER EnableException
Throw exceptions immediately (overrides -ContinueOnError).

.PARAMETER Confirm
Request confirmation before applying the logins.

.PARAMETER WhatIf
Shows what would be applied without making changes.

.EXAMPLE
Import-sqmDatabaseLogins -SqlInstance 'TestSQL' -Database 'Frontarena' -InputPath 'D:\Handover\Frontarena_Logins.sql'

Applies the previously exported Frontarena logins to TestSQL and repairs orphaned users afterwards.

.NOTES
Prerequisites : dbatools, Invoke-sqmLogging, Set-sqmSqlPolicyState
Counterpart   : Export-sqmDatabaseLogins (produces the file consumed here).
Combined use  : Sync-sqmDatabaseLogins (when one control host can reach both instances directly).
#>
function Import-sqmDatabaseLogins
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string]$InputPath,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $false)]
		[bool]$DisablePolicy = $true,
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

		$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		function _AddResult([string]$Action, [string]$LoginName, [string]$Status, [string]$Message)
		{
			$results.Add([PSCustomObject]@{
					SqlInstance = $SqlInstance
					Action	    = $Action
					LoginName   = $LoginName
					Status	    = $Status
					Message	    = $Message
					Timestamp   = (Get-Date)
				})
		}

		# Policy-Handling: identisches eng-um-die-kritische-Aktion-Muster wie in Copy-sqmLogins -
		# deaktiviert unmittelbar vor der Login-Anwendung, im finally garantiert re-aktiviert.
		function _DisablePolicy
		{
			if (-not $DisablePolicy) { return $false }
			$_configuredPolicy = Get-sqmConfig -Key 'DefaultPolicy' 3>$null
			if ([string]::IsNullOrWhiteSpace($_configuredPolicy))
			{
				$skipMsg = "Policy-Handling uebersprungen: kein 'DefaultPolicy' in der Modulkonfiguration."
				Invoke-sqmLogging -Message $skipMsg -FunctionName $functionName -Level 'WARNING'
				_AddResult 'PolicyDisable' '(Server)' 'Skipped' $skipMsg
				return $false
			}
			try
			{
				Invoke-sqmLogging -Message "Deaktiviere Default-Policy auf '$SqlInstance'." -FunctionName $functionName -Level 'INFO'
				$policyResult = Set-sqmSqlPolicyState -SqlInstance $SqlInstance -SqlCredential $SqlCredential -State Disable `
													  -ContinueOnError:$ContinueOnError -EnableException:$EnableException
				$policyStatus = ($policyResult | Select-Object -ExpandProperty Status -First 1)
				if ($policyStatus -eq 'Success')
				{
					_AddResult 'PolicyDisable' '(Server)' 'Success' 'Policy deaktiviert.'
					return $true
				}
				_AddResult 'PolicyDisable' '(Server)' $policyStatus "Policy-Deaktivierung: $policyStatus"
				return $false
			}
			catch
			{
				$msg = "Fehler bei Policy-Deaktivierung: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				_AddResult 'PolicyDisable' '(Server)' 'Failed' $msg
				if ($EnableException) { throw }
				return $false
			}
		}

		function _EnablePolicy
		{
			try
			{
				Invoke-sqmLogging -Message "Reaktiviere Default-Policy auf '$SqlInstance'." -FunctionName $functionName -Level 'INFO'
				$reEnableResult = Set-sqmSqlPolicyState -SqlInstance $SqlInstance -SqlCredential $SqlCredential -State Enable `
														-ContinueOnError:$ContinueOnError -EnableException:$false
				$reEnableStatus = ($reEnableResult | Select-Object -ExpandProperty Status -First 1)
				_AddResult 'PolicyEnable' '(Server)' $reEnableStatus "Policy reaktiviert: $reEnableStatus"
			}
			catch
			{
				$msg = "KRITISCH: Policy-Reaktivierung fehlgeschlagen: $($_.Exception.Message)"
				Write-Warning $msg
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
				_AddResult 'PolicyEnable' '(Server)' 'Failed' $msg
			}
		}
	}

	process
	{
		try
		{
			# ---- 1. Datei lesen, Header parsen, in Login-Bloecke zerlegen ----
			$fullContent = [System.IO.File]::ReadAllText($InputPath)

			$headerSource = if ($fullContent -match '(?m)^-- Quelle\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
			$headerDatabase = if ($fullContent -match '(?m)^-- Datenbank\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
			$headerTimestamp = if ($fullContent -match '(?m)^-- Zeitstempel\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
			Invoke-sqmLogging -Message "Import aus '$InputPath' (Quelle laut Header: '$headerSource', Datenbank: '$headerDatabase', Zeitstempel: '$headerTimestamp')." `
							  -FunctionName $functionName -Level 'INFO'

			if ($headerDatabase -and $headerDatabase -ne $Database)
			{
				$warnMsg = "Datei wurde fuer Datenbank '$headerDatabase' exportiert, -Database ist aber '$Database'. Wird trotzdem angewendet."
				Write-Warning $warnMsg
				Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level 'WARNING'
				_AddResult 'HeaderCheck' '(Datei)' 'Warning' $warnMsg
			}

			$parts = [regex]::Split($fullContent, '(?m)^(?=-- ===LOGIN:)')
			$loginBlocks = [System.Collections.Generic.List[PSCustomObject]]::new()
			foreach ($part in $parts)
			{
				if ($part -match '^-- ===LOGIN:(.+?)===')
				{
					$loginBlocks.Add([PSCustomObject]@{ Name = $matches[1]; Sql = $part })
				}
			}

			if ($loginBlocks.Count -eq 0)
			{
				$msg = "Keine Login-Bloecke in '$InputPath' gefunden - nichts zu tun."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
				Write-Warning $msg
				_AddResult 'ParseFile' '(Datei)' 'Skipped' $msg
				return $results
			}
			Invoke-sqmLogging -Message "$($loginBlocks.Count) Login-Block/Bloecke in '$InputPath' gefunden." -FunctionName $functionName -Level 'INFO'

			# ---- 2+3. Policy deaktivieren, Bloecke einzeln anwenden, Policy garantiert reaktivieren ----
			$applyAction = "$($loginBlocks.Count) Login(s) aus '$InputPath' auf '$SqlInstance' anwenden"
			if ($PSCmdlet.ShouldProcess($SqlInstance, $applyAction))
			{
				$policyWasDisabled = $false
				try
				{
					$policyWasDisabled = _DisablePolicy

					foreach ($block in $loginBlocks)
					{
						try
						{
							$msgOutput = @(Invoke-DbaQuery @connParams -Database master -Query $block.Sql -MessagesToOutput -EnableException)
							$joinedMsg = ($msgOutput -join ' ').Trim()
							$status = if ($joinedMsg -match 'SICHERHEIT') { 'SkippedSysadmin' }
							elseif ($joinedMsg -match 'UEBERSPRUNGEN') { 'SkippedSidCollision' }
							else { 'Success' }
							_AddResult 'ApplyLogin' $block.Name $status $(if ($joinedMsg) { $joinedMsg } else { 'Login synchronisiert.' })
						}
						catch
						{
							$errMsg = "Fehler bei Login '$($block.Name)': $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
							_AddResult 'ApplyLogin' $block.Name 'Failed' $errMsg
							if (-not $ContinueOnError -and $EnableException) { throw }
						}
					}
				}
				finally
				{
					if ($policyWasDisabled) { _EnablePolicy }
				}
			}
			else
			{
				foreach ($block in $loginBlocks) { _AddResult 'ApplyLogin' $block.Name 'WhatIf' 'WhatIf: Login wuerde angewendet.' }
			}

			# ---- 4. Verwaiste User bereinigen ----
			$repairAction = "Verwaiste User in '$Database' auf '$SqlInstance' bereinigen"
			if ($PSCmdlet.ShouldProcess($Database, $repairAction))
			{
				try
				{
					$repairResult = Repair-DbaDbOrphanUser -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database `
														   -Confirm:$false -EnableException -ErrorAction Stop
					$repairedCount = if ($repairResult) { @($repairResult).Count } else { 0 }
					Invoke-sqmLogging -Message "Orphan-Repair auf '$Database': $repairedCount Eintraege bereinigt." -FunctionName $functionName -Level 'INFO'
					_AddResult 'RepairOrphanUsers' "($Database)" 'Success' "$repairedCount Eintraege bereinigt."
				}
				catch
				{
					$errMsg = "Fehler beim Orphan-Repair: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
					_AddResult 'RepairOrphanUsers' "($Database)" 'Failed' $errMsg
					if ($EnableException) { throw }
				}
			}
			else
			{
				_AddResult 'RepairOrphanUsers' "($Database)" 'WhatIf' 'WhatIf: Orphan-Repair wuerde ausgefuehrt.'
			}
		}
		catch
		{
			$errMsg = "Fehler in Import-sqmDatabaseLogins: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			_AddResult 'Import' '(alle)' 'Failed' $errMsg
			if ($EnableException) { throw }
		}
	}

	end
	{
		$successCount = @($results | Where-Object Status -eq 'Success').Count
		$failCount = @($results | Where-Object Status -eq 'Failed').Count
		$skipCount = @($results | Where-Object Status -in @('SkippedSysadmin', 'SkippedSidCollision')).Count
		$summaryMsg = "Import-sqmDatabaseLogins abgeschlossen - Erfolg: $successCount | Fehler: $failCount | Sicherheitsbedingt uebersprungen: $skipCount"
		Invoke-sqmLogging -Message $summaryMsg -FunctionName $functionName -Level 'INFO'
		Write-Host $summaryMsg -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' }
			else { 'Green' })
		return $results
	}
}
