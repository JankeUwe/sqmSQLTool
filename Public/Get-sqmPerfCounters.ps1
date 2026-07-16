<#
.SYNOPSIS
    Reads SQL Server performance counters from sys.dm_os_performance_counters.

.DESCRIPTION
    Returns the most important SQL Server performance counters:
    Buffer Cache Hit Ratio, Page Life Expectancy, Batch Requests/sec,
    compilations, lock waits, memory, connections, scans and more.
    Automatically interprets values and flags notable ones.

.PARAMETER SqlInstance
    SQL Server instance. Default: local computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Category
    Filter on category fragments, e.g. @('Buffer','Memory','Locks').
    Default: all key counters.

.PARAMETER TopN
    Maximum number of results. Default: 50.

.PARAMETER OutputPath
    If specified, a CSV report is saved.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmPerfCounters -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmPerfCounters -SqlInstance "SQL01" -Category "Buffer","Memory"

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE.
#>
function Get-sqmPerfCounters
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Category,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 500)]
		[int]$TopN = 50,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = _s 'Error_dbatoolsNotFound'
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message (_s 'PerfCounters_Starting' $functionName, $SqlInstance) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$counterSql = @"
SELECT TOP ($TopN)
    RTRIM(object_name)   AS ObjectName,
    RTRIM(counter_name)  AS CounterName,
    RTRIM(instance_name) AS InstanceName,
    cntr_value           AS Value,
    cntr_type            AS CntrType
FROM sys.dm_os_performance_counters
WHERE (
    (counter_name LIKE '%Buffer cache hit ratio%'       AND cntr_type = 537003264)
 OR (counter_name LIKE '%Page life expectancy%'         AND instance_name = '')
 OR (counter_name LIKE '%Batch Requests/sec%')
 OR (counter_name LIKE '%SQL Compilations/sec%')
 OR (counter_name LIKE '%SQL Re-Compilations/sec%')
 OR (counter_name LIKE '%Lock Waits/sec%'               AND instance_name = '_Total')
 OR (counter_name LIKE '%Number of Deadlocks/sec%'      AND instance_name = '_Total')
 OR (counter_name LIKE '%User Connections%')
 OR (counter_name LIKE '%Total Server Memory%')
 OR (counter_name LIKE '%Target Server Memory%')
 OR (counter_name LIKE '%Stolen Server Memory%')
 OR (counter_name LIKE '%Full Scans/sec%')
 OR (counter_name LIKE '%Index Searches/sec%')
 OR (counter_name LIKE '%Lazy Writes/sec%')
 OR (counter_name LIKE '%Checkpoint Pages/sec%')
 OR (counter_name LIKE '%Memory Grants Pending%')
 OR (counter_name LIKE '%Processes Blocked%')
 OR (counter_name LIKE '%Active Temp Tables%')
 OR (counter_name LIKE '%Temp Tables Creation Rate%')
 OR (counter_name LIKE '%Free list stalls/sec%')
 OR (counter_name LIKE '%Plan Cache%'                   AND instance_name = '_Total')
 OR (counter_name LIKE '%Cache Hit Ratio%'              AND object_name LIKE '%Plan Cache%')
)
ORDER BY object_name, counter_name
"@
			$rows = Invoke-DbaQuery @connParams -Database master -Query $counterSql -ErrorAction Stop

			$ple     = ($rows | Where-Object { $_.CounterName -like '*Page life expectancy*' -and $_.InstanceName -eq '' } | Select-Object -First 1).Value
			$userConn = ($rows | Where-Object { $_.CounterName -like '*User Connections*' } | Select-Object -First 1).Value

			$bhrRow  = $rows | Where-Object { $_.CounterName -like '*Buffer cache hit ratio*' -and $_.CntrType -eq 537003264 } | Select-Object -First 1
			$bhrBase = $rows | Where-Object { $_.CounterName -like '*Buffer cache hit ratio base*' } | Select-Object -First 1
			$bhr = if ($bhrRow -and $bhrBase -and [long]$bhrBase.Value -gt 0) {
				[math]::Round([long]$bhrRow.Value * 100.0 / [long]$bhrBase.Value, 1)
			} else { $null }

			if ($Category -and $Category.Count -gt 0)
			{
				$filtered = $rows | Where-Object {
					$on  = $_.ObjectName
					$match = $false
					foreach ($c in $Category) { if ($on -like "*$c*") { $match = $true; break } }
					$match
				}
			}
			else { $filtered = $rows }

			$results = $filtered | ForEach-Object {
				$val    = [long]$_.Value
				$interp = ''

				if ($_.CounterName -like '*Page life expectancy*' -and $_.InstanceName -eq '')
				{
					if ($val -lt 300)    { $interp = _s 'PerfInterp_PLE_Critical' }
					elseif ($val -lt 600){ $interp = _s 'PerfInterp_PLE_Warning' }
				}
				elseif ($_.CounterName -like '*Memory Grants Pending*' -and $val -gt 0)
				{
					$interp = _s 'PerfInterp_MemGrants'
				}
				elseif ($_.CounterName -like '*Processes Blocked*' -and $val -gt 0)
				{
					$interp = if ($val -gt 5) { _s 'PerfInterp_Blocking_Critical' } else { _s 'PerfInterp_Blocking_Warning' }
				}
				elseif ($_.CounterName -like '*Number of Deadlocks*' -and $val -gt 0)
				{
					$interp = _s 'PerfInterp_Deadlocks'
				}
				elseif ($_.CounterName -like '*Lazy Writes/sec*' -and $val -gt 20)
				{
					$interp = _s 'PerfInterp_LazyWrites'
				}
				elseif ($_.CounterName -like '*SQL Re-Compilations*' -and $val -gt 100)
				{
					$interp = _s 'PerfInterp_ReCompilations'
				}

				[PSCustomObject]@{
					Category       = ($_.ObjectName -replace '^.*?:', '' -replace 'SQLServer:', '').Trim()
					CounterName    = $_.CounterName
					InstanceName   = $_.InstanceName
					Value          = $val
					CntrType       = $_.CntrType
					Interpretation = $interp
				}
			}

			$summary = [PSCustomObject]@{
				SqlInstance            = $SqlInstance
				BufferCacheHitRatioPct = $bhr
				PageLifeExpectancy     = $ple
				UserConnections        = $userConn
				CountersRead           = $results.Count
				Warnings               = @($results | Where-Object { $_.Interpretation -ne '' }).Count
			}

			Invoke-sqmLogging -Message (_s 'PerfCounters_Completed' $functionName, $results.Count, $summary.Warnings) -FunctionName $functionName -Level "INFO"

			if ($OutputPath)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'
				$ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
				$csvFile  = Join-Path $OutputPath "PerfCounters_${safeInst}_${ts}.csv"
				$results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message (_s 'PerfCounters_Saved' $csvFile) -FunctionName $functionName -Level "INFO"

				$htmlFile = Join-Path $OutputPath "PerfCounters_${safeInst}_${ts}.html"
				$bodyHtml = ($results | ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "Performance Counters - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}

			return [PSCustomObject]@{
				Summary  = $summary
				Counters = @($results)
			}
		}
		catch
		{
			$errMsg = _s 'Error_Generic' $functionName, $_.Exception.Message
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
	}
}
