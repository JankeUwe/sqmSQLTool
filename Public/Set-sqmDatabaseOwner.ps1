<#
.SYNOPSIS
    Sets the owner of one or more databases to a uniform login.

.DESCRIPTION
    Checks and corrects the database owner on one or more SQL Server instances.
    Typical use case: after restores or migrations the owner is often a login that no
    longer exists or is incorrect. The function uniformly sets it to the sa account
    (regardless of the actual sa name, which may have been renamed via obfuscation) or
    any other login.

    Process per database:
      1. Read current owner
      2. Check whether a change is necessary (already correct -> skip)
      3. Check whether the target login exists on the instance
      4. Execute ALTER AUTHORIZATION ON DATABASE::<Name> TO <Login>
      5. Log result

    Returns a status object for each database:
      Status = OK / Skipped / Failed / NotFound

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name(s). Wildcards allowed (e.g. 'Prod*'). Default: all user databases.

.PARAMETER ExcludeDatabase
    Databases to exclude. Wildcards allowed.

.PARAMETER OwnerLogin
    Login to set as the new owner.
    Default: sa account (automatically determined via SID 0x01,
    regardless of whether it has been renamed).

.PARAMETER IncludeSystemDatabases
    Also include system databases (master, model, msdb). Default: $false.
    tempdb is always excluded.

.PARAMETER Force
    Also process databases that already have the correct owner (forces re-assignment).

.PARAMETER OutputPath
    Directory for the change log. Default: from module configuration.

.PARAMETER ContinueOnError
    Continue on error for one instance. Default: $false.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Set sa account on all user databases
    Set-sqmDatabaseOwner -SqlInstance "SQL01"

.EXAMPLE
    # Specific databases with a custom login
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -Database "Prod*" -OwnerLogin "svc_sqlowner"

.EXAMPLE
    # Pipeline across multiple instances
    'SQL01','SQL02' | Set-sqmDatabaseOwner

.EXAMPLE
    # WhatIf - only show what would be changed
    Set-sqmDatabaseOwner -SqlInstance "SQL01" -WhatIf

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    Needs: sysadmin or ALTER ANY DATABASE on the instance.
    The sa account is identified via SID 0x01 — works even after renaming.
    System databases: master/model/msdb can receive owner changes, tempdb never.
#>
function Set-sqmDatabaseOwner
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Database = @(),
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),
		[Parameter(Mandatory = $false)]
		[string]$OwnerLogin,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}
		
		if (-not $OutputPath) { $OutputPath = Get-sqmDefaultOutputPath }
		
		Invoke-sqmLogging -Message ("Starte " + $functionName) -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			Invoke-sqmLogging -Message ("[$instance] Verarbeite Instanz") -FunctionName $functionName -Level "INFO"
			
			try
			{
				$connParams = @{
					SqlInstance   = $instance
					SqlCredential = $SqlCredential
				}
				
				# -------------------------------------------------------------------
				# 1. Ziel-Login ermitteln
				#    Standard: sa-Account via SID 0x01 (funktioniert nach Umbenennung)
				# -------------------------------------------------------------------
				$targetLogin = $OwnerLogin
				if (-not $targetLogin)
				{
					$saQuery = "SELECT name FROM sys.server_principals WHERE sid = 0x01 AND type = 'S'"
					$saResult = Invoke-DbaQuery @connParams -Database 'master' -Query $saQuery -ErrorAction Stop
					if ($saResult)
					{
						$targetLogin = $saResult.name
					}
					else
					{
						throw "Sa-Account (SID 0x01) konnte nicht ermittelt werden."
					}
				}
				
				# Pruefen ob Ziel-Login existiert
				$loginCheckQuery = "SELECT name FROM sys.server_principals WHERE name = N'$($targetLogin -replace "'", "''")' AND type IN ('S','U','G')"
				$loginExists = Invoke-DbaQuery @connParams -Database 'master' -Query $loginCheckQuery -ErrorAction Stop
				if (-not $loginExists)
				{
					throw "Ziel-Login '$targetLogin' existiert nicht auf '$instance'."
				}
				
				Invoke-sqmLogging -Message ("[$instance] Ziel-Owner: $targetLogin") -FunctionName $functionName -Level "INFO"
				
				# -------------------------------------------------------------------
				# 2. Datenbanken ermitteln
				# -------------------------------------------------------------------
				$dbGetParams = @{
					SqlInstance   = $instance
					SqlCredential = $SqlCredential
				}
				
				$allDbs = Get-DbaDatabase @dbGetParams
				
				# tempdb immer ausschliessen
				$filtered = $allDbs | Where-Object { $_.Name -ne 'tempdb' }
				
				# Systemdatenbanken
				if (-not $IncludeSystemDatabases)
				{
					$filtered = $filtered | Where-Object { -not $_.IsSystemObject }
				}
				
				# Namenfilter
				if ($Database.Count -gt 0)
				{
					$filtered = $filtered | Where-Object {
						$dbName = $_.Name
						$match = $false
						foreach ($pattern in $Database) { if ($dbName -like $pattern) { $match = $true } }
						$match
					}
				}
				
				# Ausschluesse
				if ($ExcludeDatabase.Count -gt 0)
				{
					$filtered = $filtered | Where-Object {
						$dbName = $_.Name
						$exclude = $false
						foreach ($pattern in $ExcludeDatabase) { if ($dbName -like $pattern) { $exclude = $true } }
						-not $exclude
					}
				}
				
				$dbList = @($filtered)
				if ($dbList.Count -eq 0)
				{
					Invoke-sqmLogging -Message ("[$instance] Keine Datenbanken nach Filterung gefunden.") -FunctionName $functionName -Level "WARNING"
					continue
				}
				
				Invoke-sqmLogging -Message ("[$instance] $($dbList.Count) Datenbank(en) zu pruefen.") -FunctionName $functionName -Level "INFO"
				
				# -------------------------------------------------------------------
				# 3. Pro Datenbank Owner pruefen und setzen
				# -------------------------------------------------------------------
				$instanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
				$changedCount = 0
				$skippedCount = 0
				$failedCount = 0
				
				foreach ($db in $dbList)
				{
					$dbName = $db.Name
					$currentOwner = $db.Owner
					
					$rowResult = [PSCustomObject]@{
						SqlInstance  = $instance
						DatabaseName = $dbName
						OldOwner	 = $currentOwner
						NewOwner	 = $targetLogin
						Status	     = 'Unknown'
						Message	     = ''
					}
					
					# Bereits korrekt?
					if ($currentOwner -eq $targetLogin -and -not $Force)
					{
						$rowResult.Status = 'Skipped'
						$rowResult.Message = "Owner bereits '$targetLogin' - keine aenderung."
						$skippedCount++
						$instanceResults.Add($rowResult)
						continue
					}
					
					$action = "Owner von '$dbName' von '$currentOwner' auf '$targetLogin' setzen"
					if ($PSCmdlet.ShouldProcess("[$instance] $dbName", $action))
					{
						try
						{
							$alterSql = "ALTER AUTHORIZATION ON DATABASE::[$($dbName -replace '\]', '\]\]')] TO [$($targetLogin -replace '\]', '\]\]')]"
							Invoke-DbaQuery @connParams -Database 'master' -Query $alterSql -ErrorAction Stop
							
							$rowResult.Status = 'OK'
							$rowResult.Message = "Owner erfolgreich auf '$targetLogin' gesetzt."
							$changedCount++
							Invoke-sqmLogging -Message ("[" + $instance + "] " + $dbName + ": Owner " + $currentOwner + " -> " + $targetLogin) -FunctionName $functionName -Level "INFO"
						}
						catch
						{
							$rowResult.Status = 'Failed'
							$rowResult.Message = $_.Exception.Message
							$failedCount++
							Invoke-sqmLogging -Message ("[" + $instance + "] " + $dbName + ": Fehler beim Owner-Setzen: " + $_.Exception.Message) -FunctionName $functionName -Level "ERROR"
						}
					}
					else
					{
						$rowResult.Status = 'WhatIf'
						$rowResult.Message = "WhatIf: Keine aenderung durchgefuehrt."
					}
					
					$instanceResults.Add($rowResult)
				}
				
				# -------------------------------------------------------------------
				# 4. Protokoll schreiben
				# -------------------------------------------------------------------
				$changed = $instanceResults | Where-Object { $_.Status -eq 'OK' }
				if ($changed -and $PSCmdlet.ShouldProcess($instance, "Protokoll schreiben"))
				{
					if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
					
					$safeInst = $instance -replace '\\', '_'
					$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
					$csvFile = Join-Path $OutputPath ("OwnerChange_" + $safeInst + "_" + $stamp + ".csv")
					
					$instanceResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
					Copy-sqmToCentralPath -Path @($csvFile)
					Invoke-sqmLogging -Message ("[$instance] Protokoll: $csvFile") -FunctionName $functionName -Level "INFO"
				}
				
				$summary = "[$instance] Geaendert: $changedCount, uebersprungen: $skippedCount, Fehler: $failedCount"
				Invoke-sqmLogging -Message $summary -FunctionName $functionName -Level "INFO"
				Write-Verbose $summary
				
				foreach ($r in $instanceResults) { $allResults.Add($r) }
			}
			catch
			{
				$errMsg = "Fehler auf '$instance': " + $_.Exception.Message
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { Write-Error $errMsg; return }
				Write-Warning $errMsg
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen. " + $allResults.Count + " Datenbank(en) verarbeitet.") -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}