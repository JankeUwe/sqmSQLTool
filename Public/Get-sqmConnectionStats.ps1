<#
.SYNOPSIS
    Analyzes active SQL Server connections and connection statistics.

.DESCRIPTION
    Reads sys.dm_exec_sessions and sys.dm_exec_connections and groups
    by application, login, host or database. Shows connection load,
    active requests, CPU usage and oldest connections.

.PARAMETER SqlInstance
    SQL Server instance. Default: local computer name.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER GroupBy
    Grouping criterion: Application | Login | Host | Database.
    Default: Application.

.PARAMETER TopN
    Number of top groups. Default: 25.

.PARAMETER IncludeSystemConnections
    Include system connections (is_user_process = 0).

.PARAMETER OutputPath
    If specified, a CSV report is saved.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Get-sqmConnectionStats -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmConnectionStats -SqlInstance "SQL01" -GroupBy Login -TopN 10

.EXAMPLE
    Get-sqmConnectionStats -SqlInstance "SQL01" -GroupBy Database -IncludeSystemConnections

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Needs VIEW SERVER STATE.
#>
function Get-sqmConnectionStats
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Application', 'Login', 'Host', 'Database')]
		[string]$GroupBy = 'Application',
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 500)]
		[int]$TopN = 25,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemConnections,
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

		Invoke-sqmLogging -Message (_s 'ConnStats_Starting' $functionName, $SqlInstance, $GroupBy) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$sysFilter = if ($IncludeSystemConnections) { '' } else { 'AND s.is_user_process = 1' }

			$sessionSql = @"
SELECT
    s.session_id,
    s.login_name,
    ISNULL(s.program_name, '')              AS program_name,
    ISNULL(s.host_name, '')                 AS host_name,
    ISNULL(DB_NAME(s.database_id), '')      AS database_name,
    s.status,
    s.cpu_time,
    s.memory_usage * 8                      AS memory_kb,
    s.logical_reads,
    s.reads,
    s.writes,
    s.login_time,
    s.last_request_start_time,
    s.last_request_end_time,
    s.is_user_process,
    DATEDIFF(SECOND, s.login_time, GETDATE()) AS connection_age_sec,
    CASE WHEN r.session_id IS NOT NULL THEN 1 ELSE 0 END AS has_active_request,
    ISNULL(r.blocking_session_id, 0)        AS blocking_session_id,
    ISNULL(r.wait_type, '')                 AS wait_type,
    ISNULL(r.wait_time, 0)                  AS wait_time_ms,
    c.net_transport,
    c.auth_scheme,
    c.num_reads,
    c.num_writes,
    c.net_packet_size
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r
    ON s.session_id = r.session_id
LEFT JOIN sys.dm_exec_connections c
    ON s.session_id = c.session_id
WHERE 1=1
$sysFilter
"@
			$sessions = Invoke-DbaQuery @connParams -Database master -Query $sessionSql -ErrorAction Stop

			$maxConnSql = @"
SELECT
    value_in_use AS MaxConnections
FROM sys.configurations
WHERE name = 'max connections'
"@
			$maxConn      = Invoke-DbaQuery @connParams -Database master -Query $maxConnSql -ErrorAction Stop
			$maxConnValue = if ($maxConn -and $maxConn.MaxConnections -gt 0) { [long]$maxConn.MaxConnections } else { 32767 }

			$totalConn  = @($sessions).Count
			$activeReqs = @($sessions | Where-Object { $_.has_active_request -eq 1 }).Count
			$blocked    = @($sessions | Where-Object { $_.blocking_session_id -gt 0 }).Count
			$usagePct   = [math]::Round($totalConn * 100.0 / $maxConnValue, 1)

			$groupField = switch ($GroupBy)
			{
				'Application' { 'program_name' }
				'Login'       { 'login_name' }
				'Host'        { 'host_name' }
				'Database'    { 'database_name' }
			}

			$grouped = $sessions | Group-Object $groupField | ForEach-Object {
				$grpSessions = $_.Group
				$activeInGrp = @($grpSessions | Where-Object { $_.has_active_request -eq 1 }).Count
				$oldest  = ($grpSessions | Sort-Object login_time | Select-Object -First 1).login_time
				$ageMin  = if ($oldest) { [math]::Round((New-TimeSpan -Start $oldest -End (Get-Date)).TotalMinutes, 1) } else { 0 }
				[PSCustomObject]@{
					GroupValue          = $_.Name
					ConnectionCount     = $_.Count
					ActiveRequests      = $activeInGrp
					BlockedSessions     = @($grpSessions | Where-Object { $_.blocking_session_id -gt 0 }).Count
					TotalCpuMs          = ($grpSessions | Measure-Object cpu_time -Sum).Sum
					TotalLogicalReads   = ($grpSessions | Measure-Object logical_reads -Sum).Sum
					TotalMemoryKB       = ($grpSessions | Measure-Object memory_kb -Sum).Sum
					OldestConnectionMin = $ageMin
					WaitTypes           = (@($grpSessions | Where-Object { $_.wait_type -ne '' } | Select-Object -ExpandProperty wait_type -Unique) -join ', ')
				}
			} | Sort-Object ConnectionCount -Descending | Select-Object -First $TopN

			$activeDetails = $sessions | Where-Object { $_.has_active_request -eq 1 } | ForEach-Object {
				[PSCustomObject]@{
					SessionId    = $_.session_id
					Login        = $_.login_name
					Application  = $_.program_name
					Host         = $_.host_name
					Database     = $_.database_name
					WaitType     = $_.wait_type
					WaitMs       = $_.wait_time_ms
					BlockedBy    = $_.blocking_session_id
					CpuMs        = $_.cpu_time
					LogicalReads = $_.logical_reads
				}
			} | Sort-Object WaitMs -Descending

			$summary = [PSCustomObject]@{
				SqlInstance        = $SqlInstance
				TotalConnections   = $totalConn
				MaxConnections     = $maxConnValue
				ConnectionUsagePct = $usagePct
				ActiveRequests     = $activeReqs
				BlockedSessions    = $blocked
				UserConnections    = @($sessions | Where-Object { $_.is_user_process -eq 1 }).Count
				SystemConnections  = @($sessions | Where-Object { $_.is_user_process -eq 0 }).Count
			}

			Invoke-sqmLogging -Message (_s 'ConnStats_Summary' $functionName, $totalConn, $usagePct, $maxConnValue, $activeReqs, $blocked) -FunctionName $functionName -Level "INFO"

			if ($OutputPath)
			{
				if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
				$safeInst = $SqlInstance -replace '[\\/:<>|]', '_'
				$ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
				$csvFile  = Join-Path $OutputPath "ConnectionStats_${safeInst}_${ts}.csv"
				$grouped  | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
				Invoke-sqmLogging -Message (_s 'ConnStats_Saved' $csvFile) -FunctionName $functionName -Level "INFO"

				$htmlFile = Join-Path $OutputPath "ConnectionStats_${safeInst}_${ts}.html"
				$bodyHtml = ($grouped | ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "Connection Statistics - $SqlInstance" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}

			return [PSCustomObject]@{
				Summary        = $summary
				GroupedStats   = @($grouped)
				ActiveRequests = @($activeDetails)
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
