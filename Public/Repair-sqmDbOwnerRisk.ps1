<#
.SYNOPSIS
    Removes unexpected db_owner members and replaces them with db_datareader,
    db_datawriter, and a custom db_execute role granted EXECUTE on all stored procedures.

.DESCRIPTION
    Fixes what Get-sqmDbOwnerRisk finds. Per database:
      1. Re-detects current db_owner members (excluding 'dbo' and -ExcludeLogin), live -
         does not trust a possibly stale object passed in from the pipeline.
      2. If none are found, the database is skipped entirely - no role is created, no
         permissions are touched.
      3. Otherwise, once per database:
           - Creates the -ExecuteRoleName role (default 'db_execute') if it does not
             already exist yet: CREATE ROLE [db_execute] AUTHORIZATION [dbo].
           - Enumerates all user stored procedures (sys.procedures, is_ms_shipped = 0)
             and grants EXECUTE on each of them to that role. If the database has no
             stored procedures, this step is skipped.
      4. Per offending member:
           - ALTER ROLE db_owner DROP MEMBER
           - ALTER ROLE db_datareader ADD MEMBER
           - ALTER ROLE db_datawriter ADD MEMBER
           - ALTER ROLE <ExecuteRoleName> ADD MEMBER
         Each member is processed independently (wrapped in its own try/catch), so one
         failing login does not stop the others.

    Accepts Get-sqmDbOwnerRisk's pipeline output directly (binds SqlInstance and
    DatabaseName), or can be called standalone with -SqlInstance/-Database.

    Writes a CSV changelog per instance in -OutputPath and copies it to the module's
    central path (Copy-sqmToCentralPath), same as Set-sqmDatabaseOwner.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable (by property name). Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name(s) to repair. Wildcards allowed. Pipeline-capable (by property name,
    accepts 'DatabaseName' from Get-sqmDbOwnerRisk). Default: all user databases.

.PARAMETER ExcludeDatabase
    Databases to exclude. Wildcards allowed.

.PARAMETER ExcludeLogin
    Principal names to leave alone even if they are db_owner members (wildcards
    allowed), in addition to the always-excluded 'dbo'.

.PARAMETER ExecuteRoleName
    Name of the custom EXECUTE-only role to create/use. Default: 'db_execute'.

.PARAMETER IncludeSystemDatabases
    Also process master/model/msdb. Default: $false. tempdb is never processed.

.PARAMETER OutputPath
    Directory for the CSV changelog. Default: <module OutputPath>\DbOwnerRiskRepair.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -WhatIf

    Shows which db_owner members would be removed and what they would be granted instead,
    without changing anything.

.EXAMPLE
    Get-sqmDbOwnerRisk -SqlInstance 'SQL01' | Where-Object Status -eq 'Risk' | Repair-sqmDbOwnerRisk

.EXAMPLE
    Repair-sqmDbOwnerRisk -SqlInstance 'SQL01' -Database 'Prod*' -ExcludeLogin 'svc_deploy' -Confirm:$false

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    Needs: sysadmin or ALTER ANY ROLE + ALTER ANY USER on the target database(s).
    Background: https://www.powershelldba.de/blog/articles/db-owner-privilege-escalation-risks.html
    See also: Get-sqmDbOwnerRisk, Set-sqmDatabaseOwner
#>
function Repair-sqmDbOwnerRisk
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
		[Alias('DatabaseName')]
		[string[]]$Database = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDatabase = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeLogin = @(),

		[Parameter(Mandatory = $false)]
		[string]$ExecuteRoleName = 'db_execute',

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,

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
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		if (-not $OutputPath) { $OutputPath = Join-Path (Get-sqmDefaultOutputPath) 'DbOwnerRiskRepair' }

		$memberQuery = @"
SELECT dp.name AS MemberName
FROM sys.database_role_members rm
JOIN sys.database_principals dp ON dp.principal_id = rm.member_principal_id
JOIN sys.database_principals rp ON rp.principal_id = rm.role_principal_id
WHERE rp.name = N'db_owner'
ORDER BY dp.name
"@

		Invoke-sqmLogging -Message ("Starte " + $functionName) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			Invoke-sqmLogging -Message ("[$instance] Verarbeite Instanz") -FunctionName $functionName -Level "INFO"

			try
			{
				$connParams = @{ SqlInstance = $instance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				$dbList = Get-DbaDatabase @connParams -ErrorAction Stop | Where-Object { $_.Name -ne 'tempdb' }
				if (-not $IncludeSystemDatabases) { $dbList = $dbList | Where-Object { -not $_.IsSystemObject } }

				if ($Database.Count -gt 0)
				{
					$dbList = $dbList | Where-Object {
						$dbName = $_.Name
						$match = $false
						foreach ($pattern in $Database) { if ($dbName -like $pattern) { $match = $true } }
						$match
					}
				}
				if ($ExcludeDatabase.Count -gt 0)
				{
					$dbList = $dbList | Where-Object {
						$dbName = $_.Name
						$exclude = $false
						foreach ($pattern in $ExcludeDatabase) { if ($dbName -like $pattern) { $exclude = $true } }
						-not $exclude
					}
				}

				$dbList = @($dbList)
				if ($dbList.Count -eq 0)
				{
					Invoke-sqmLogging -Message ("[$instance] Keine Datenbanken nach Filterung gefunden.") -FunctionName $functionName -Level "WARNING"
					continue
				}

				$execEsc     = $ExecuteRoleName -replace "'", "''"
				$execBracket = $ExecuteRoleName -replace '\]', '\]\]'

				$instanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()

				foreach ($db in $dbList)
				{
					$dbName = $db.Name

					$rows = Invoke-DbaQuery @connParams -Database $dbName -Query $memberQuery -ErrorAction Stop
					$members = @($rows | Where-Object {
						$n = $_.MemberName
						if ($n -eq 'dbo') { return $false }
						$excluded = $false
						foreach ($pattern in $ExcludeLogin) { if ($n -like $pattern) { $excluded = $true } }
						-not $excluded
					} | Select-Object -ExpandProperty MemberName)

					if ($members.Count -eq 0)
					{
						Invoke-sqmLogging -Message ("[$instance] $dbName : keine unerwarteten db_owner-Mitglieder - uebersprungen.") -FunctionName $functionName -Level "INFO"
						continue
					}

					$action = "$($members.Count) db_owner-Mitglied(er) entfernen ($($members -join ', ')), " +
						"db_datareader/db_datawriter/$ExecuteRoleName zuweisen"

					if ($PSCmdlet.ShouldProcess("[$instance] $dbName", $action))
					{
						$procCount = 0

						try
						{
							$roleExists = Invoke-DbaQuery @connParams -Database $dbName `
								-Query "SELECT 1 AS Found FROM sys.database_principals WHERE name = N'$execEsc' AND type = 'R'" -ErrorAction Stop
							if (-not $roleExists)
							{
								Invoke-DbaQuery @connParams -Database $dbName -Query "CREATE ROLE [$execBracket] AUTHORIZATION [dbo];" -ErrorAction Stop
								Invoke-sqmLogging -Message ("[$instance] $dbName : Rolle [$ExecuteRoleName] angelegt.") -FunctionName $functionName -Level "INFO"
							}

							$procs = Invoke-DbaQuery @connParams -Database $dbName -Query @"
SELECT s.name AS SchemaName, p.name AS ProcName
FROM sys.procedures p
JOIN sys.schemas s ON s.schema_id = p.schema_id
WHERE p.is_ms_shipped = 0
"@ -ErrorAction Stop

							$procs = @($procs)
							$procCount = $procs.Count

							if ($procCount -gt 0)
							{
								$grantStatements = foreach ($p in $procs)
								{
									$schemaBr = $p.SchemaName -replace '\]', '\]\]'
									$procBr   = $p.ProcName   -replace '\]', '\]\]'
									"GRANT EXECUTE ON OBJECT::[$schemaBr].[$procBr] TO [$execBracket];"
								}
								Invoke-DbaQuery @connParams -Database $dbName -Query ($grantStatements -join "`r`n") -ErrorAction Stop
								Invoke-sqmLogging -Message ("[$instance] $dbName : EXECUTE auf $procCount Prozedur(en) an [$ExecuteRoleName] vergeben.") -FunctionName $functionName -Level "INFO"
							}
							else
							{
								Invoke-sqmLogging -Message ("[$instance] $dbName : keine Prozeduren vorhanden - EXECUTE-Grant uebersprungen.") -FunctionName $functionName -Level "INFO"
							}
						}
						catch
						{
							Invoke-sqmLogging -Message ("[$instance] $dbName : Rolle/Grant-Vorbereitung fehlgeschlagen: " + $_.Exception.Message) -FunctionName $functionName -Level "WARNING"
						}

						foreach ($member in $members)
						{
							$rowResult = [PSCustomObject]@{
								SqlInstance       = $instance
								DatabaseName      = $dbName
								LoginName         = $member
								ExecuteRoleName   = $ExecuteRoleName
								ProceduresGranted = $procCount
								Status            = 'Unknown'
								Message           = ''
							}

							try
							{
								$memberBr = $member -replace '\]', '\]\]'
								$memberSql = @"
ALTER ROLE db_owner DROP MEMBER [$memberBr];
ALTER ROLE db_datareader ADD MEMBER [$memberBr];
ALTER ROLE db_datawriter ADD MEMBER [$memberBr];
ALTER ROLE [$execBracket] ADD MEMBER [$memberBr];
"@
								Invoke-DbaQuery @connParams -Database $dbName -Query $memberSql -ErrorAction Stop

								$rowResult.Status = 'OK'
								$rowResult.Message = "db_owner entfernt; db_datareader/db_datawriter/$ExecuteRoleName zugewiesen ($procCount Prozedur(en))."
								Invoke-sqmLogging -Message ("[$instance] $dbName : $member -> " + $rowResult.Message) -FunctionName $functionName -Level "INFO"
							}
							catch
							{
								$rowResult.Status = 'Failed'
								$rowResult.Message = $_.Exception.Message
								Invoke-sqmLogging -Message ("[$instance] $dbName : $member -> Fehler: " + $_.Exception.Message) -FunctionName $functionName -Level "ERROR"
							}

							$instanceResults.Add($rowResult)
						}
					}
					else
					{
						foreach ($member in $members)
						{
							$instanceResults.Add([PSCustomObject]@{
								SqlInstance       = $instance
								DatabaseName      = $dbName
								LoginName         = $member
								ExecuteRoleName   = $ExecuteRoleName
								ProceduresGranted = $null
								Status            = 'WhatIf'
								Message           = "WhatIf: $action"
							})
						}
					}
				}

				# -------------------------------------------------------------------
				# Protokoll schreiben
				# -------------------------------------------------------------------
				$changed = $instanceResults | Where-Object { $_.Status -eq 'OK' }
				if ($changed -and $PSCmdlet.ShouldProcess($instance, "Protokoll schreiben"))
				{
					if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

					$safeInst = $instance -replace '\\', '_'
					$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
					$csvFile = Join-Path $OutputPath ("DbOwnerRiskRepair_" + $safeInst + "_" + $stamp + ".csv")

					$instanceResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
					Copy-sqmToCentralPath -Path @($csvFile)
					Invoke-sqmLogging -Message ("[$instance] Protokoll: $csvFile") -FunctionName $functionName -Level "INFO"
				}

				$okCount     = @($instanceResults | Where-Object { $_.Status -eq 'OK' }).Count
				$failedCount = @($instanceResults | Where-Object { $_.Status -eq 'Failed' }).Count
				$summary = "[$instance] Repariert: $okCount, Fehler: $failedCount"
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
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen. " + $allResults.Count + " Login(s) verarbeitet.") -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
