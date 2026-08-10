<#
.SYNOPSIS
Synchronizes the SQL-authentication logins backing a database's users from a source to a
destination instance in one call, for the case where both are reachable from the same session.

.DESCRIPTION
Thin orchestration wrapper around Export-sqmDatabaseLogins and Import-sqmDatabaseLogins - no
login/password logic of its own. It exports -Source's logins for -Database to a throwaway temp
file, immediately imports that file against -Destination, and deletes the temp file again.

Use this only when one control host/session can reach BOTH -Source and -Destination directly. If
Production and Test sit in domains/networks that cannot see each other, this wrapper cannot help -
run Export-sqmDatabaseLogins on the source side, transport the resulting file across the boundary
by whatever separate means are available (not part of this module), then run
Import-sqmDatabaseLogins on the destination side. Both paths end up doing exactly the same thing;
this function only saves the manual two-step dance when connectivity allows it.

.PARAMETER Source
Source SQL Server instance (Production).

.PARAMETER Destination
Destination SQL Server instance (Test).

.PARAMETER Database
Database whose SQL-authentication users' logins should be synchronized.

.PARAMETER SqlCredential
Credential for both instances. For different credentials use -SourceCredential/-DestinationCredential.

.PARAMETER SourceCredential
Credential specifically for -Source (overrides -SqlCredential for the source side).

.PARAMETER DestinationCredential
Credential specifically for -Destination (overrides -SqlCredential for the destination side).

.PARAMETER Login
Passed through to Export-sqmDatabaseLogins - restricts the export to these login names (wildcards).

.PARAMETER ExcludeLogin
Passed through to Export-sqmDatabaseLogins - additional logins to exclude (wildcards).

.PARAMETER DisablePolicy
Passed through to Import-sqmDatabaseLogins. Default: $true.

.PARAMETER ContinueOnError
Passed through to Import-sqmDatabaseLogins.

.PARAMETER EnableException
Throw exceptions immediately instead of returning Failed result objects.

.PARAMETER Confirm
Request confirmation before applying the logins on -Destination.

.PARAMETER WhatIf
Shows what would happen without making changes.

.EXAMPLE
Sync-sqmDatabaseLogins -Source 'ProdSQL' -Destination 'TestSQL' -Database 'Frontarena'

Exports Frontarena's SQL-auth logins from ProdSQL and applies them to TestSQL in one call - only
works if this session can reach both instances.

.NOTES
Prerequisites : dbatools, Export-sqmDatabaseLogins, Import-sqmDatabaseLogins
#>
function Sync-sqmDatabaseLogins
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Source,
		[Parameter(Mandatory = $true, Position = 1)]
		[string]$Destination,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Login,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin,
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
		$srcCred = if ($SourceCredential) { $SourceCredential }
		elseif ($SqlCredential) { $SqlCredential }
		else { $null }
		$dstCred = if ($DestinationCredential) { $DestinationCredential }
		elseif ($SqlCredential) { $SqlCredential }
		else { $null }
	}

	process
	{
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		$safeDb = ($Database -replace '[\\/:*?"<>|]', '_')
		$tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) "sqmDatabaseLogins_${safeDb}_$(Get-Date -Format 'yyyyMMddHHmmss').sql"

		try
		{
			Invoke-sqmLogging -Message "Sync-sqmDatabaseLogins: Export von '$Source' nach Temp-Datei '$tmpFile'." `
							  -FunctionName $functionName -Level 'INFO'

			$exportParams = @{
				SqlInstance	    = $Source
				Database	    = $Database
				OutputPath	    = $tmpFile
				EnableException = $EnableException.IsPresent
			}
			if ($srcCred) { $exportParams['SqlCredential'] = $srcCred }
			if ($Login) { $exportParams['Login'] = $Login }
			if ($ExcludeLogin) { $exportParams['ExcludeLogin'] = $ExcludeLogin }

			$exportResult = Export-sqmDatabaseLogins @exportParams -Confirm:$false
			$results.Add($exportResult)

			if ($exportResult.Status -ne 'Success')
			{
				Invoke-sqmLogging -Message "Export nicht erfolgreich (Status: $($exportResult.Status)) - Import wird uebersprungen." `
								  -FunctionName $functionName -Level 'WARNING'
				return $results
			}

			$applyAction = "Login-Export von '$Source' auf '$Destination' anwenden ($($exportResult.LoginCount) Login(s))"
			if ($PSCmdlet.ShouldProcess($Destination, $applyAction))
			{
				$importParams = @{
					SqlInstance	    = $Destination
					InputPath	    = $tmpFile
					Database	    = $Database
					DisablePolicy   = $DisablePolicy
					ContinueOnError = $ContinueOnError.IsPresent
					EnableException = $EnableException.IsPresent
				}
				if ($dstCred) { $importParams['SqlCredential'] = $dstCred }

				$importResults = Import-sqmDatabaseLogins @importParams -Confirm:$false
				foreach ($r in $importResults) { $results.Add($r) }
			}
			else
			{
				Invoke-sqmLogging -Message "WhatIf - Import auf '$Destination' uebersprungen." -FunctionName $functionName -Level 'INFO'
			}

			return $results
		}
		catch
		{
			$errMsg = "Fehler in Sync-sqmDatabaseLogins: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $results
		}
		finally
		{
			if (Test-Path $tmpFile) { Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue }
		}
	}
}
