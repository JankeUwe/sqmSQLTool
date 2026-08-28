<#
.SYNOPSIS
    Drops tables, views, procedures, and functions from the master database that are not on
    the configured whitelist of expected maintenance tooling.

.DESCRIPTION
    Fixes what Get-sqmMasterDbCustomObjects finds. Per instance:
      1. Re-detects custom objects in master live (sys.objects, is_ms_shipped = 0), excluding
         the configured MasterDbObjectWhitelist and anything matched by -ExcludeObject - does
         not trust a possibly stale object passed in from the pipeline.
      2. If -ObjectName is given, only those names (wildcards allowed) are considered; otherwise
         every non-whitelisted object found is a candidate.
      3. If nothing is left to remove, the instance is skipped entirely.
      4. Each remaining object is dropped with the statement matching its type
         (DROP TABLE / DROP VIEW / DROP PROCEDURE / DROP FUNCTION), each wrapped in its own
         try/catch so one failing object does not stop the rest.

    Accepts Get-sqmMasterDbCustomObjects's pipeline output directly (binds SqlInstance and
    ObjectName), or can be called standalone with -SqlInstance/-ObjectName.

    Writes a CSV changelog per instance in -OutputPath and copies it to the module's central
    path (Copy-sqmToCentralPath), same as Repair-sqmDbOwnerRisk / Set-sqmDatabaseOwner.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable (by property name). Default: current computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER ObjectName
    Object name(s) to remove. Wildcards allowed. Pipeline-capable (by property name, accepts
    'ObjectName' from Get-sqmMasterDbCustomObjects). Default: every non-whitelisted object found.

.PARAMETER ExcludeObject
    Additional object names to leave alone even though they are not on the configured
    whitelist (wildcards allowed). Use for a one-off tool you know is legitimate without
    changing the persisted configuration.

.PARAMETER OutputPath
    Directory for the CSV changelog. Default: <module OutputPath>\MasterDbCustomObjectsRemoval.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Remove-sqmMasterDbCustomObjects -SqlInstance 'SQL01' -WhatIf

    Shows which objects would be dropped, without changing anything.

.EXAMPLE
    Get-sqmMasterDbCustomObjects -SqlInstance 'SQL01' | Where-Object Status -eq 'Custom' | Remove-sqmMasterDbCustomObjects

.EXAMPLE
    Remove-sqmMasterDbCustomObjects -SqlInstance 'SQL01' -ObjectName 'usp_Test*' -Confirm:$false

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    Needs: sysadmin or ALTER ANY SCHEMA + CONTROL on the affected objects in master.
    The whitelist that protects objects from removal is configured once, module-wide, via
    Set-sqmConfig -MasterDbObjectWhitelist (see Get-sqmConfig -Key 'MasterDbObjectWhitelist'
    for the current value). There is no per-call override to bypass it - edit the whitelist
    first if an object should be exempt.
    See also: Get-sqmMasterDbCustomObjects, Set-sqmConfig
#>
function Remove-sqmMasterDbCustomObjects
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
		[string[]]$ObjectName = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeObject = @(),

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

		if (-not $OutputPath) { $OutputPath = Join-Path (Get-sqmDefaultOutputPath) 'MasterDbCustomObjectsRemoval' }

		$whitelist = @(Get-sqmConfig -Key 'MasterDbObjectWhitelist')

		$objectQuery = @"
SELECT
    s.name       AS SchemaName,
    o.name       AS ObjectName,
    o.type       AS ObjectTypeCode,
    o.type_desc  AS ObjectTypeDesc
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U','V','P','PC','FN','IF','TF','FS','FT')
  AND o.is_ms_shipped = 0
ORDER BY o.type_desc, s.name, o.name
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

				$rows = Invoke-DbaQuery @connParams -Database 'master' -Query $objectQuery -ErrorAction Stop

				$excludePatterns = @($whitelist) + @($ExcludeObject)
				$candidates = @($rows | Where-Object {
					$n = $_.ObjectName
					$excluded = $false
					foreach ($pattern in $excludePatterns) { if ($n -like $pattern) { $excluded = $true } }
					-not $excluded
				})

				if ($ObjectName.Count -gt 0)
				{
					$candidates = @($candidates | Where-Object {
						$n = $_.ObjectName
						$match = $false
						foreach ($pattern in $ObjectName) { if ($n -like $pattern) { $match = $true } }
						$match
					})
				}

				if ($candidates.Count -eq 0)
				{
					Invoke-sqmLogging -Message ("[$instance] Keine zu entfernenden Objekte in master - uebersprungen.") -FunctionName $functionName -Level "INFO"
					continue
				}

				$instanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()

				foreach ($obj in $candidates)
				{
					$schemaBr = $obj.SchemaName -replace '\]', '\]\]'
					$nameBr   = $obj.ObjectName -replace '\]', '\]\]'
					$typeCode = $obj.ObjectTypeCode.Trim()

					$dropStatement = switch ($typeCode)
					{
						'U'       { "DROP TABLE [$schemaBr].[$nameBr];" }
						'V'       { "DROP VIEW [$schemaBr].[$nameBr];" }
						{ $_ -in @('P', 'PC') } { "DROP PROCEDURE [$schemaBr].[$nameBr];" }
						default   { "DROP FUNCTION [$schemaBr].[$nameBr];" }
					}

					$rowResult = [PSCustomObject]@{
						SqlInstance = $instance
						SchemaName  = $obj.SchemaName
						ObjectName  = $obj.ObjectName
						ObjectType  = $obj.ObjectTypeDesc
						Status      = 'Unknown'
						Message     = ''
					}

					$action = "$typeCode-Objekt entfernen: $($obj.SchemaName).$($obj.ObjectName) ($dropStatement)"
					if ($PSCmdlet.ShouldProcess("[$instance] master", $action))
					{
						try
						{
							Invoke-DbaQuery @connParams -Database 'master' -Query $dropStatement -ErrorAction Stop

							$rowResult.Status = 'OK'
							$rowResult.Message = "Entfernt ($($obj.ObjectTypeDesc))."
							Invoke-sqmLogging -Message ("[$instance] master : $($obj.SchemaName).$($obj.ObjectName) entfernt ($($obj.ObjectTypeDesc)).") -FunctionName $functionName -Level "INFO"
						}
						catch
						{
							$rowResult.Status = 'Failed'
							$rowResult.Message = $_.Exception.Message
							Invoke-sqmLogging -Message ("[$instance] master : $($obj.SchemaName).$($obj.ObjectName) -> Fehler: " + $_.Exception.Message) -FunctionName $functionName -Level "ERROR"
						}
					}
					else
					{
						$rowResult.Status = 'WhatIf'
						$rowResult.Message = "WhatIf: $action"
					}

					$instanceResults.Add($rowResult)
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
					$csvFile = Join-Path $OutputPath ("MasterDbCustomObjectsRemoval_" + $safeInst + "_" + $stamp + ".csv")

					$instanceResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
					Copy-sqmToCentralPath -Path @($csvFile)
					Invoke-sqmLogging -Message ("[$instance] Protokoll: $csvFile") -FunctionName $functionName -Level "INFO"
				}

				$okCount     = @($instanceResults | Where-Object { $_.Status -eq 'OK' }).Count
				$failedCount = @($instanceResults | Where-Object { $_.Status -eq 'Failed' }).Count
				$summary = "[$instance] Entfernt: $okCount, Fehler: $failedCount"
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
		Invoke-sqmLogging -Message ($functionName + " abgeschlossen. " + $allResults.Count + " Objekt(e) verarbeitet.") -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}
