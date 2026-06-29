<#
.SYNOPSIS
    Compares important configuration settings between two SQL Server instances.

.DESCRIPTION
    Displays differences in the following areas: sp_configure, instance properties (Collation, Version, MaxMemory), database settings (optional). Output as a list with old/new values.

.PARAMETER SourceInstance
    Source instance (reference).

.PARAMETER TargetInstance
    Target instance (server to compare). Mandatory.

.PARAMETER SqlCredential
    PSCredential for both instances (if identical). For different credentials, separate parameters are required (simplified).

.PARAMETER CompareDatabases
    When set, databases (Name, Owner, RecoveryModel, Collation) are compared.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Compare-sqmServerConfiguration -SourceInstance "SQL01" -TargetInstance "SQL02"

.NOTES
    Uses Connect-DbaInstance and SMO objects.
#>
function Compare-sqmServerConfiguration
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SourceInstance,
		[Parameter(Mandatory = $true)]
		[string]$TargetInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$CompareDatabases,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		function Get-ServerProps($inst)
		{
			$srv = Connect-DbaInstance -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop
			$cfg = $srv.Configuration
			$props = @{
				Version = $srv.VersionString
				Edition = $srv.Edition
				Collation = $srv.Collation
				LoginMode = $srv.LoginMode
				MaxMemory = $cfg.MaxServerMemory.ConfigValue
				MinMemory = $cfg.MinServerMemory.ConfigValue
				MaxDop  = $cfg.MaxDegreeOfParallelism.ConfigValue
				CTP	    = $cfg.CostThresholdForParallelism.ConfigValue
				BackupDirectory = $srv.BackupDirectory
				DefaultFile = $srv.DefaultFile
				DefaultLog = $srv.DefaultLog
			}
			return $props
		}
		function Get-DatabaseSimple($inst)
		{
			$dbs = Get-DbaDatabase -SqlInstance $inst -SqlCredential $SqlCredential -ErrorAction Stop
			$dbs | ForEach-Object {
				[PSCustomObject]@{
					Name = $_.Name
					Owner = $_.Owner
					RecoveryModel = $_.RecoveryModel
					Collation = $_.Collation
				}
			}
		}
	}
	
	process
	{
		try
		{
			$sourceProps = Get-ServerProps $SourceInstance
			$targetProps = Get-ServerProps $TargetInstance
			foreach ($key in $sourceProps.Keys)
			{
				if ($key -eq 'Collation') { continue }
				if ($sourceProps[$key] -ne $targetProps[$key])
				{
					$results.Add([PSCustomObject]@{
							Setting	    = $key
							SourceValue = $sourceProps[$key]
							TargetValue = $targetProps[$key]
							Category    = "Instance"
						})
				}
			}

			# Collation always reported (not just on difference)
			$results.Add([PSCustomObject]@{
				Setting     = "Collation (Instance)"
				SourceValue = $sourceProps['Collation']
				TargetValue = $targetProps['Collation']
				Category    = "Collation"
			})

			if ($CompareDatabases)
			{
				$sourceDbs = Get-DatabaseSimple $SourceInstance | Where-Object { -not $_.IsSystemObject }
				$targetDbs = Get-DatabaseSimple $TargetInstance | Where-Object { -not $_.IsSystemObject }
				$allDbNames = ($sourceDbs.Name + $targetDbs.Name) | Sort-Object -Unique
				foreach ($dbName in $allDbNames)
				{
					$s = $sourceDbs | Where-Object { $_.Name -eq $dbName }
					$t = $targetDbs | Where-Object { $_.Name -eq $dbName }
					if (-not $s)
					{
						$results.Add([PSCustomObject]@{ Setting = "Database '$dbName'"; SourceValue = "<missing>"; TargetValue = $t.Owner; Category = "Database" })
						continue
					}
					if (-not $t)
					{
						$results.Add([PSCustomObject]@{ Setting = "Database '$dbName'"; SourceValue = $s.Owner; TargetValue = "<missing>"; Category = "Database" })
						continue
					}
					if ($s.Owner -ne $t.Owner)
					{
						$results.Add([PSCustomObject]@{ Setting = "$dbName Owner"; SourceValue = $s.Owner; TargetValue = $t.Owner; Category = "Database" })
					}
					if ($s.RecoveryModel -ne $t.RecoveryModel)
					{
						$results.Add([PSCustomObject]@{ Setting = "$dbName RecoveryModel"; SourceValue = $s.RecoveryModel; TargetValue = $t.RecoveryModel; Category = "Database" })
					}
					if ($s.Collation -ne $t.Collation)
					{
						$results.Add([PSCustomObject]@{ Setting = "$dbName Collation"; SourceValue = $s.Collation; TargetValue = $t.Collation; Category = "Database" })
					}
				}
			}
			return $results
		}
		catch
		{
			Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			return $null
		}
	}
}