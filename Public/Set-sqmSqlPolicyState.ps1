<#
.SYNOPSIS
    Aktiviert oder deaktiviert eine einzelne Policy-Based Management Policy
    auf einer SQL Server-Instanz.

.DESCRIPTION
    Verwendet dbatools (Get-DbaPbmPolicy) um zu pruefen, ob die angegebene
    Policy auf der Zielinstanz existiert, und schaltet anschliessend
    ausschliesslich diese Policy ueber ihr SMO-Objekt.

    Im Gegensatz zu aelteren Skripten wird nicht der globale PBM-Engine-Zustand
    veraendert, sondern nur die explizit benannte Policy.

.PARAMETER SqlInstance
    Ziel-SQL-Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    Optionales PSCredential fuer die Verbindung.

.PARAMETER Policy
    Name der zu schaltenden Policy. Standard: aus Modulkonfiguration (DefaultPolicy).

.PARAMETER State
    Zielzustand: 'Enable' oder 'Disable'.

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz mit naechster fortfahren.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (ueberschreibt ContinueOnError).

.PARAMETER Confirm
    Fordert Bestaetigung vor dem Schalten an.

.PARAMETER WhatIf
    Zeigt, was passieren wuerde, ohne aenderungen vorzunehmen.

.EXAMPLE
    Set-sqmSqlPolicyState -SqlInstance "SQL01" -Policy "xp_cmdshell must be disabled" -State Disable

.EXAMPLE
    "SQL01","SQL02" | Set-sqmSqlPolicyState -Policy "Password Policy" -State Enable

.OUTPUTS
    [PSCustomObject] mit SqlInstance, Policy, State, Status, Message.
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
					$policyObject.Policy.Enabled = $targetEnabled
					$policyObject.Policy.Alter()
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