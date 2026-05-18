<#
.SYNOPSIS
Changes the recovery mode of one or more user databases.

.DESCRIPTION
Sets the recovery mode (Simple, Full, BulkLogged) for all or selected user databases
on a SQL Server instance. System databases are automatically excluded.

If the SqlInstance parameter is not specified, the current computer name
($env:COMPUTERNAME) is used by default. This rule applies to all future versions.

.PARAMETER SqlInstance
The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.

.PARAMETER SqlCredential
Alternative credentials (PSCredential). If not specified, Windows authentication is used.

.PARAMETER Database
Name or array of user databases whose recovery mode should be changed.
Ignored when -All is set.

.PARAMETER All
When set, changes the recovery mode for all user databases.

.PARAMETER RecoveryMode
The desired recovery mode. Allowed values: Simple, Full, BulkLogged.

.PARAMETER EnableException
Switch to propagate exceptions immediately (by default errors are logged as warnings).

.PARAMETER Confirm
Prompts for confirmation before execution. Disabled by default.
Passed through to Set-DbaDbRecoveryModel.

.PARAMETER WhatIf
Shows what would happen without actually making the change.
Passed through to Set-DbaDbRecoveryModel.

.EXAMPLE
# Set all user databases to Full (without prompting)
Invoke-sqmSetDatabaseRecoveryMode -All -RecoveryMode Full

.EXAMPLE
# With confirmation prompt (passed to Set-DbaDbRecoveryModel)
Invoke-sqmSetDatabaseRecoveryMode -Database "SalesDB" -RecoveryMode Simple -Confirm

.NOTES
Requires the dbatools module and an existing Invoke-sqmLogging function.
System databases are ignored.
Default for SqlInstance: $env:COMPUTERNAME.
#>

function Invoke-sqmSetDatabaseRecoveryMode
{
	[CmdletBinding(DefaultParameterSetName = 'Specific', SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false, ParameterSetName = 'Specific')]
		[string[]]$Database,
		[Parameter(Mandatory = $false, ParameterSetName = 'All')]
		[switch]$All,
		[Parameter(Mandatory = $true)]
		[ValidateSet('Simple', 'Full', 'BulkLogged')]
		[string]$RecoveryMode,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}
		
		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		
		Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance. Ziel-RecoveryMode: $RecoveryMode" -FunctionName $functionName -Level "INFO"
		
		$results = @()
	}
	
	process
	{
		try
		{
			$dbParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				ExcludeSystem = $true
				ErrorAction   = 'Stop'
			}
			if ($EnableException) { $dbParams.EnableException = $true }
			
			if ($All)
			{
				Invoke-sqmLogging -Message "Parameter -All erkannt: aendere Recovery-Modus fuer ALLE Benutzerdatenbanken." -FunctionName $functionName -Level "INFO"
				$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
			}
			elseif ($Database)
			{
				Invoke-sqmLogging -Message "Filtere nach angegebenen Datenbanken: $($Database -join ', ')" -FunctionName $functionName -Level "DEBUG"
				$dbParams.Database = $Database
				$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
				$foundDbNames = $databases | Select-Object -ExpandProperty Name
				$missing = $Database | Where-Object { $_ -notin $foundDbNames }
				if ($missing)
				{
					$msg = "Folgende Datenbanken wurden nicht gefunden oder sind nicht zugaenglich: $($missing -join ', ')"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = $missing -join ','
						CurrentMode  = $null
						NewMode	     = $RecoveryMode
						Status	     = "NotFound"
						Message	     = $msg
					}
				}
			}
			else
			{
				$msg = "Weder -All noch -Database angegeben. Es werden keine Datenbanken geaendert."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				$results += [PSCustomObject]@{
					SqlInstance  = $SqlInstance
					DatabaseName = $null
					CurrentMode  = $null
					NewMode	     = $RecoveryMode
					Status	     = "NoSelection"
					Message	     = $msg
				}
				return $results
			}
			
			if (-not $databases)
			{
				$msg = "Keine Benutzerdatenbanken fuer die aenderung des Recovery-Modus gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
				$results += [PSCustomObject]@{
					SqlInstance  = $SqlInstance
					DatabaseName = $null
					CurrentMode  = $null
					NewMode	     = $RecoveryMode
					Status	     = "NoDatabasesFound"
					Message	     = $msg
				}
				return $results
			}
			
			foreach ($db in $databases)
			{
				$dbName = $db.Name
				$currentMode = $db.RecoveryModel
				
				if ($currentMode -eq $RecoveryMode)
				{
					$msg = "Datenbank '$dbName' hat bereits den Recovery-Modus '$RecoveryMode'. ueberspringe."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "VERBOSE"
					$results += [PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = $dbName
						CurrentMode  = $currentMode
						NewMode	     = $RecoveryMode
						Status	     = "AlreadySet"
						Message	     = $msg
					}
					continue
				}
				
				$actionMsg = "Setze Recovery-Modus fuer Datenbank '$dbName' von '$currentMode' auf '$RecoveryMode'"
				if ($PSCmdlet.ShouldProcess($dbName, $actionMsg))
				{
					try
					{
						Invoke-sqmLogging -Message $actionMsg -FunctionName $functionName -Level "INFO"
						
						# Dynamische Parameter fuer Set-DbaDbRecoveryModel
						$setParams = @{
							SqlInstance   = $SqlInstance
							SqlCredential = $SqlCredential
							Database	  = $dbName
							RecoveryModel = $RecoveryMode
							Confirm       = $false
							ErrorAction   = 'Stop'
						}

						Set-DbaDbRecoveryModel @setParams
						
						$successMsg = "Recovery-Modus fuer '$dbName' erfolgreich auf '$RecoveryMode' gesetzt."
						Invoke-sqmLogging -Message $successMsg -FunctionName $functionName -Level "INFO"
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							CurrentMode  = $currentMode
							NewMode	     = $RecoveryMode
							Status	     = "Success"
							Message	     = $successMsg
						}
					}
					catch
					{
						$errMsg = "Fehler beim Setzen des Recovery-Modus fuer '$dbName': $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							CurrentMode  = $currentMode
							NewMode	     = $RecoveryMode
							Status	     = "Failed"
							Message	     = $errMsg
						}
					}
				}
				else
				{
					$skipMsg = "WhatIf: aenderung an '$dbName' uebersprungen."
					Invoke-sqmLogging -Message $skipMsg -FunctionName $functionName -Level "VERBOSE"
					$results += [PSCustomObject]@{
						SqlInstance  = $SqlInstance
						DatabaseName = $dbName
						CurrentMode  = $currentMode
						NewMode	     = $RecoveryMode
						Status	     = "WhatIfSkipped"
						Message	     = $skipMsg
					}
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{
				SqlInstance  = $SqlInstance
				DatabaseName = $null
				CurrentMode  = $null
				NewMode	     = $RecoveryMode
				Status	     = "GlobalError"
				Message	     = $errMsg
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Objekte zurueckgegeben." -FunctionName $functionName -Level "INFO"
		return $results
	}
}