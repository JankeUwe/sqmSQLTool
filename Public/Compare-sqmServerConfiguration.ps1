<#
.SYNOPSIS
    Vergleicht wichtige Konfigurationseinstellungen zweier SQL Server-Instanzen.

.DESCRIPTION
    Zeigt Unterschiede in folgenden Bereichen an: sp_configure, Instanz-Eigenschaften (Collation, Version, MaxMemory), Datenbank-Einstellungen (optional). Ausgabe als Liste mit Alt/Neu-Werten.

.PARAMETER SourceInstance
    Quell-Instanz (Referenz).

.PARAMETER TargetInstance
    Ziel-Instanz (zu vergleichender Server). Wenn nicht angegeben, wird gleiche wie Source verwendet? Nein, Pflicht.

.PARAMETER SqlCredential
    PSCredential fuer beide Instanzen (falls identisch). Fuer unterschiedliche Credentials sind separate Parameter noetig (vereinfacht).

.PARAMETER CompareDatabases
    Wenn gesetzt, werden Datenbanken (Name, Owner, RecoveryModel, Collation) verglichen.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Compare-sqmServerConfiguration -SourceInstance "SQL01" -TargetInstance "SQL02"

.NOTES
    Verwendet Connect-DbaInstance und SMO-Objekte.
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