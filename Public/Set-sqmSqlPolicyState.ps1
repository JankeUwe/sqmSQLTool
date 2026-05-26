<#
.SYNOPSIS
    Enables or disables a single Policy-Based Management policy on a SQL Server instance.

.DESCRIPTION
    Uses dbatools (Get-DbaPbmPolicy) to check whether the specified policy exists on
    the target instance, and then toggles only that policy via its SMO object.

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
				
				$policyObject = Get-DbaPbmPolicy @connParams -Policy $Policy -EnableException:$EnableException -ErrorAction Stop
				if (-not $policyObject)
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

					# SMO-Policy-Objekt ermitteln: dbatools gibt je nach Version entweder
					# einen Wrapper mit .Policy-Sub-Property zurueck, oder das SMO-Objekt direkt.
					$smoPolicy = $null
					$policySubObj = $policyObject.PSObject.Properties['Policy']
					if ($policySubObj -and $null -ne $policySubObj.Value)
					{
						$candidate = $policySubObj.Value
						if ($candidate | Get-Member -Name 'Enabled' -MemberType Property -ErrorAction SilentlyContinue)
						{
							$smoPolicy = $candidate
						}
					}
					# Fallback: dbatools gibt SMO-Objekt direkt zurueck (dbatools 2.x)
					if ($null -eq $smoPolicy)
					{
						if ($policyObject | Get-Member -Name 'Enabled' -MemberType Property -ErrorAction SilentlyContinue)
						{
							$smoPolicy = $policyObject
						}
					}
					if ($null -eq $smoPolicy)
					{
						throw "Policy-Objekt hat keine setzbare 'Enabled'-Eigenschaft. " +
						      "dbatools-Version pruefen. Verfuegbare Eigenschaften: " +
						      (($policyObject | Get-Member -MemberType Property | Select-Object -ExpandProperty Name) -join ', ')
					}

					$smoPolicy.Enabled = $targetEnabled
					$smoPolicy.Alter()
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