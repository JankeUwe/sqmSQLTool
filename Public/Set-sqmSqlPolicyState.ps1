<#
.SYNOPSIS
    Enables or disables a single Policy-Based Management policy on a SQL Server instance.

.DESCRIPTION
    Checks msdb.dbo.syspolicy_policies for the named policy and toggles only that policy
    via the msdb procedure sp_syspolicy_update_policy.

    Deliberately pure T-SQL instead of the dbatools PBM cmdlets (Get-DbaPbmPolicy): those
    require the SMO PolicyStore and abort under PowerShell 7 with "Get-DbaPbmStore: This
    command is not supported on Linux or macOS". That failed SILENTLY - the policy was never
    disabled, and callers relying on it (e.g. Invoke-sqmTempSysadminAction before a
    CREATE LOGIN, Invoke-sqmRestoreDatabase) ran on unprotected against the
    syspolicy_server_trigger. The T-SQL path behaves identically under Windows PowerShell 5.1
    and PowerShell 7.

    Note: disabling the last enabled "On Change: Prevent" policy makes SQL Server DROP the
    syspolicy_server_trigger entirely; re-enabling recreates it. That is PBM's own behaviour,
    not something this function does.

    Unlike older scripts, this does not change the global PBM engine state,
    but only the explicitly named policy.

.PARAMETER SqlInstance
    Target SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER Policy
    Name of the policy to toggle. Default: from module configuration (DefaultPolicy).

.PARAMETER State
    Target state: 'Enable' or 'Disable'.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Prompts for confirmation before toggling.

.PARAMETER WhatIf
    Shows what would happen without making any changes.

.EXAMPLE
    Set-sqmSqlPolicyState -SqlInstance "SQL01" -Policy "xp_cmdshell must be disabled" -State Disable

.EXAMPLE
    "SQL01","SQL02" | Set-sqmSqlPolicyState -Policy "Password Policy" -State Enable

.OUTPUTS
    [PSCustomObject] with SqlInstance, Policy, State, Status, Message.
#>
function Set-sqmSqlPolicyState
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$Policy,
		[Parameter(Mandatory = $true)]
		[ValidateSet('Enable', 'Disable')]
		[string]$State,
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

		# Policy-Name: explizit oder aus Konfiguration (3>$null unterdrueckt Warning wenn Key fehlt)
		if ([string]::IsNullOrWhiteSpace($Policy))
		{
			$Policy = Get-sqmConfig -Key 'DefaultPolicy' 3>$null
		}
		if ([string]::IsNullOrWhiteSpace($Policy))
		{
			$errMsg = "Kein Policy-Name angegeben und kein 'DefaultPolicy' in der Modulkonfiguration definiert."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$targetEnabled = ($State -eq 'Enable')
		$actionLabel = if ($targetEnabled) { 'aktiviert' }
		else { 'deaktiviert' }
		Invoke-sqmLogging -Message "Starte $functionName - Zielzustand: $State fuer Policy '$Policy'" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		foreach ($instance in $SqlInstance)
		{
			$connParams = @{ SqlInstance = $instance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
			
			try
			{
				Invoke-sqmLogging -Message "[$instance] Suche Policy '$Policy' ..." -FunctionName $functionName -Level "INFO"

				# Policy-Existenz per Katalogsicht statt Get-DbaPbmPolicy: die PBM-Cmdlets von
				# dbatools setzen SMO-PolicyStore voraus und brechen unter PowerShell 7 mit
				# "Get-DbaPbmStore: This command is not supported on Linux or macOS" ab (dbatools
				# blockiert die PBM-Befehle ausserhalb der Windows-PowerShell/.NET-Framework-
				# Umgebung). Ergebnis war ein STILLER Fehlschlag: Get-DbaPbmPolicy lieferte nichts,
				# diese Funktion meldete "Policy existiert nicht" und der Aufrufer lief ungeschuetzt
				# weiter - genau die Ursache dafuer, dass die Policy-Deaktivierung vor einem
				# CREATE LOGIN unter PS 7 wirkungslos blieb und die Anweisung am
				# syspolicy_server_trigger scheiterte. Die Katalogsicht und die msdb-Prozedur
				# sp_syspolicy_update_policy sind reines T-SQL und funktionieren unter JEDER
				# PowerShell-Version identisch.
				$policyLit = $Policy -replace "'", "''"
				$policyRow = Invoke-DbaQuery @connParams -Database msdb -EnableException -ErrorAction Stop `
					-Query "SELECT policy_id, is_enabled FROM msdb.dbo.syspolicy_policies WHERE name = N'$policyLit';"

				if (-not $policyRow)
				{
					$msg = "Policy '$Policy' existiert nicht auf '$instance'."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results.Add([PSCustomObject]@{
							SqlInstance = $instance
							Policy	    = $Policy
							State	    = $State
							Status	    = 'Skipped'
							Message	    = $msg
						})
					continue
				}

				$actionMsg = "Policy '$Policy' auf '$instance' $actionLabel"
				if ($PSCmdlet.ShouldProcess($instance, $actionMsg))
				{
					Invoke-sqmLogging -Message "[$instance] $actionMsg ..." -FunctionName $functionName -Level "INFO"

					$policyId = [int]$policyRow.policy_id
					$enabledInt = if ($targetEnabled) { 1 } else { 0 }
					Invoke-DbaQuery @connParams -Database msdb -EnableException -ErrorAction Stop `
						-Query "EXEC msdb.dbo.sp_syspolicy_update_policy @policy_id = $policyId, @is_enabled = $enabledInt;"

					# Nachpruefen statt auf "keine Exception = Erfolg" zu vertrauen.
					$verifyRow = Invoke-DbaQuery @connParams -Database msdb -EnableException -ErrorAction Stop `
						-Query "SELECT is_enabled FROM msdb.dbo.syspolicy_policies WHERE policy_id = $policyId;"
					if (-not $verifyRow -or [int]$verifyRow.is_enabled -ne $enabledInt)
					{
						throw "sp_syspolicy_update_policy lief ohne Fehler, aber 'is_enabled' der Policy '$Policy' auf '$instance' steht danach nicht auf $enabledInt."
					}

					$msg = "Policy '$Policy' auf '$instance' erfolgreich $actionLabel."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
					$results.Add([PSCustomObject]@{
							SqlInstance = $instance
							Policy	    = $Policy
							State	    = $State
							Status	    = 'Success'
							Message	    = $msg
						})
				}
				else
				{
					$msg = "WhatIf: $actionMsg uebersprungen."
					Invoke-sqmLogging -Message "[$instance] $msg" -FunctionName $functionName -Level "VERBOSE"
					$results.Add([PSCustomObject]@{
							SqlInstance = $instance
							Policy	    = $Policy
							State	    = $State
							Status	    = 'WhatIfSkipped'
							Message	    = $msg
						})
				}
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$results.Add([PSCustomObject]@{
						SqlInstance = $instance
						Policy	    = $Policy
						State	    = $State
						Status	    = 'Failed'
						Message	    = $errMsg
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw }
			}
		}
		return $results
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}