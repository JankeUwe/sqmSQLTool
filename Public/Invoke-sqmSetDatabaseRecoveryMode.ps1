<#
.SYNOPSIS
aendert den Recovery-Modus einer oder mehrerer Benutzerdatenbanken.

.DESCRIPTION
Die Funktion setzt den Recovery-Modus (Simple, Full, BulkLogged) fuer alle oder
ausgewaehlte Benutzerdatenbanken einer SQL Server-Instanz. Systemdatenbanken werden
automatisch ausgeschlossen.

Wenn kein SqlInstance-Parameter angegeben wird, wird standardmaessig der aktuelle
Computername ($env:COMPUTERNAME) verwendet. Diese Regel gilt fuer alle zukuenftigen
Versionen.

.PARAMETER SqlInstance
Die Ziel-SQL Server-Instanz (z.B. "localhost", "SQL01\INSTANCE").
Wenn nicht angegeben, wird der aktuelle Computername verwendet.

.PARAMETER SqlCredential
Alternative Anmeldeinformationen (PSCredential). Wenn nicht angegeben, wird
Windows-Authentifizierung verwendet.

.PARAMETER Database
Name oder Array von Benutzerdatenbanken, deren Recovery-Modus geaendert werden soll.
Wird ignoriert, wenn -All gesetzt ist.

.PARAMETER All
Wenn gesetzt, wird der Recovery-Modus fuer alle Benutzerdatenbanken geaendert.

.PARAMETER RecoveryMode
Der gewuenschte Recovery-Modus. Erlaubte Werte: Simple, Full, BulkLogged.

.PARAMETER EnableException
Schalter, um Ausnahmen durchzulassen (standardmaessig werden Fehler als Warnung
protokolliert).

.PARAMETER Confirm
Fordert vor der Ausfuehrung eine Bestaetigung an. Standardmaessig deaktiviert.
Wird an Set-DbaDbRecoveryModel weitergereicht.

.PARAMETER WhatIf
Zeigt, was passieren wuerde, ohne die aenderung tatsaechlich auszufuehren.
Wird an Set-DbaDbRecoveryModel weitergereicht.

.EXAMPLE
# Alle Benutzerdatenbanken auf Full setzen (ohne Nachfrage)
Invoke-sqmSetDatabaseRecoveryMode -All -RecoveryMode Full

.EXAMPLE
# Mit Nachfrage (Confirm an Set-DbaDbRecoveryModel)
Invoke-sqmSetDatabaseRecoveryMode -Database "SalesDB" -RecoveryMode Simple -Confirm

.NOTES
Erfordert dbatools-Modul und eine vorhandene Funktion Invoke-sqmLogging.
Systemdatenbanken werden ignoriert.
Default fuer SqlInstance: $env:COMPUTERNAME.
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