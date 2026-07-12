<#
.SYNOPSIS
    Creates a health report for SQL Server Service Broker configuration and status.

.DESCRIPTION
    Retrieves Service Broker information from a SQL Server instance:
    - Service Broker status (enabled/disabled per database)
    - Endpoints on port 4022 (SSBEndpoint)
    - Queue status and message counts
    - Undeliverable messages in transmission queue
    - Service pairs and their contracts
    - Replica status (if AlwaysOn AG is configured)

    Results are saved as a TXT report in the specified directory.
    The function automatically detects single-instance or AlwaysOn configurations.

.PARAMETER SqlInstance
    SQL Server instance. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential for the connection.

.PARAMETER OutputPath
    Output directory for report files. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER ContinueOnError
    Continue on error (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.EXAMPLE
    Get-sqmServiceBrokerHealth

.EXAMPLE
    Get-sqmServiceBrokerHealth -SqlInstance "SQL01" -OutputPath "D:\Reports"

.NOTES
    Author:       sqmSQLTool
    Prerequisites: dbatools
    Default output path: C:\System\WinSrvLog\MSSQL
#>
function Get-sqmServiceBrokerHealth
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starte $functionName mit OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			# Verbindung herstellen
			$server = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop

			# Ausgabeverzeichnis erstellen falls nicht vorhanden
			if (-not (Test-Path $OutputPath))
			{
				$null = New-Item -ItemType Directory -Path $OutputPath -Force
				Invoke-sqmLogging -Message "Verzeichnis erstellt: $OutputPath" -FunctionName $functionName -Level "INFO"
			}

			# Report-Metadaten
			$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
			$cleanServerName = $server.Name -replace '\\', '-'
			$reportFile = Join-Path $OutputPath ("ServiceBrokerHealth_" + $cleanServerName + "_" + $timestamp + ".txt")
			$htmlFile = Join-Path $OutputPath ("ServiceBrokerHealth_" + $cleanServerName + "_" + $timestamp + ".html")
			$reportContent = [System.Collections.Generic.List[string]]::new()
			$htmlSections = [System.Collections.Generic.List[string]]::new()

			# Header
			$reportContent.Add("=" * 80) | Out-Null
			$reportContent.Add("SQL Server Service Broker Health Report") | Out-Null
			$reportContent.Add("=" * 80) | Out-Null
			$reportContent.Add("Server:      $($server.Name)") | Out-Null
			$reportContent.Add("Generated:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
			$reportContent.Add("") | Out-Null

			# 1. AlwaysOn Auto-Detect
			$agQuery = "SELECT COUNT(*) as AGCount FROM sys.availability_groups"
			$agResult = $server.Query($agQuery)
			$isAlwaysOn = $agResult.AGCount -gt 0
			$reportContent.Add("Configuration: $(if ($isAlwaysOn) { 'AlwaysOn Availability Group' } else { 'Single System' })") | Out-Null
			$reportContent.Add("") | Out-Null
			$htmlSections.Add("<p>Configuration: $(if ($isAlwaysOn) { 'AlwaysOn Availability Group' } else { 'Single System' })</p>") | Out-Null

			# 2. Broker Endpoints
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Broker Endpoints") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$epQuery = @"
SELECT
    name,
    state_desc,
    protocol_desc,
    type_desc
FROM sys.endpoints
WHERE type = 3
ORDER BY name
"@

			$endpoints = $server.Query($epQuery)
			if ($endpoints)
			{
				foreach ($ep in $endpoints)
				{
					$reportContent.Add("  Endpoint:    $($ep.name)") | Out-Null
					$reportContent.Add("  State:       $($ep.state_desc)") | Out-Null
					$reportContent.Add("  Protocol:    $($ep.protocol_desc)") | Out-Null
					$reportContent.Add("  Type:        $($ep.type_desc)") | Out-Null
					$reportContent.Add("") | Out-Null
				}
				$epRowsHtml = foreach ($ep in $endpoints)
				{
					$sevClass = if ($ep.state_desc -eq 'STARTED') { 'ok' } else { 'warn' }
					"<tr><td>$([System.Net.WebUtility]::HtmlEncode($ep.name))</td><td class='$sevClass'>$($ep.state_desc)</td><td>$($ep.protocol_desc)</td><td>$($ep.type_desc)</td></tr>"
				}
				$htmlSections.Add("<h3>Service Broker Endpoints</h3><table><tr><th>Endpoint</th><th>State</th><th>Protocol</th><th>Type</th></tr>$($epRowsHtml -join '')</table>") | Out-Null
			}
			else
			{
				$reportContent.Add("  No Service Broker endpoints found") | Out-Null
				$reportContent.Add("") | Out-Null
				$htmlSections.Add("<h3>Service Broker Endpoints</h3><p>No Service Broker endpoints found</p>") | Out-Null
			}

			# 3. Broker Status per Database
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Broker Status per Database") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$brokerQuery = @"
SELECT
    name,
    is_broker_enabled,
    state_desc
FROM sys.databases
WHERE state_desc = 'ONLINE'
ORDER BY name
"@

			$brokerDbs = $server.Query($brokerQuery)
			$enabledCount = ($brokerDbs | Where-Object { $_.is_broker_enabled -eq 1 }).Count
			$disabledCount = ($brokerDbs | Where-Object { $_.is_broker_enabled -eq 0 }).Count

			$reportContent.Add("  Enabled:  $enabledCount") | Out-Null
			$reportContent.Add("  Disabled: $disabledCount") | Out-Null
			$reportContent.Add("") | Out-Null

			foreach ($db in $brokerDbs)
			{
				$status = if ($db.is_broker_enabled) { "ENABLED" } else { "DISABLED" }
				$reportContent.Add("  $($db.name): $status") | Out-Null
			}
			$reportContent.Add("") | Out-Null
			$dbRowsHtml = foreach ($db in $brokerDbs)
			{
				$sevClass = if ($db.is_broker_enabled) { 'ok' } else { 'warn' }
				$status = if ($db.is_broker_enabled) { "ENABLED" } else { "DISABLED" }
				"<tr><td>$([System.Net.WebUtility]::HtmlEncode($db.name))</td><td class='$sevClass'>$status</td></tr>"
			}
			$htmlSections.Add("<h3>Service Broker Status per Database</h3><p>Enabled: $enabledCount | Disabled: $disabledCount</p><table><tr><th>Database</th><th>Status</th></tr>$($dbRowsHtml -join '')</table>") | Out-Null

			# 4. Service Queues
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Queues") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$queueQuery = @"
SELECT
    name,
    is_activation_enabled,
    is_enqueue_enabled,
    is_receive_enabled,
    is_retention_enabled
FROM sys.service_queues
ORDER BY name
"@

			$queueRowsHtml = [System.Collections.Generic.List[string]]::new()
			foreach ($db in $brokerDbs | Where-Object { $_.is_broker_enabled -eq 1 })
			{
				$queues = $server.Query($queueQuery, $db.name)
				if ($queues)
				{
					$reportContent.Add("  Database: $($db.name)") | Out-Null
					foreach ($q in $queues)
					{
						$reportContent.Add("    Queue:       $($q.name)") | Out-Null
						$reportContent.Add("    Enqueue:     $(if ($q.is_enqueue_enabled) { 'ON' } else { 'OFF' })") | Out-Null
						$reportContent.Add("    Receive:     $(if ($q.is_receive_enabled) { 'ON' } else { 'OFF' })") | Out-Null
						$reportContent.Add("    Activation:  $(if ($q.is_activation_enabled) { 'ON' } else { 'OFF' })") | Out-Null
						$reportContent.Add("") | Out-Null

						$queueRowsHtml.Add("<tr><td>$([System.Net.WebUtility]::HtmlEncode($db.name))</td><td>$([System.Net.WebUtility]::HtmlEncode($q.name))</td><td>$(if ($q.is_enqueue_enabled) { 'ON' } else { 'OFF' })</td><td>$(if ($q.is_receive_enabled) { 'ON' } else { 'OFF' })</td><td>$(if ($q.is_activation_enabled) { 'ON' } else { 'OFF' })</td></tr>") | Out-Null
					}
				}
			}
			$htmlSections.Add("<h3>Service Queues</h3><table><tr><th>Database</th><th>Queue</th><th>Enqueue</th><th>Receive</th><th>Activation</th></tr>$($queueRowsHtml -join '')</table>") | Out-Null

			# 5. Undeliverable Messages
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Undeliverable Messages (Transmission Queue)") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$undeliverableQuery = @"
SELECT COUNT(*) as UndeliverableCount FROM sys.transmission_queue
"@

			$undelivRowsHtml = [System.Collections.Generic.List[string]]::new()
			foreach ($db in $brokerDbs | Where-Object { $_.is_broker_enabled -eq 1 })
			{
				$undeliverable = $server.Query($undeliverableQuery, $db.name)
				$count = $undeliverable[0].UndeliverableCount
				$reportContent.Add("  Database: $($db.name)") | Out-Null
				if ($count -gt 0)
				{
					$reportContent.Add("  Undeliverable: $count messages") | Out-Null
				}
				else
				{
					$reportContent.Add("  Undeliverable: 0 messages") | Out-Null
				}
				$reportContent.Add("") | Out-Null

				$sevClass = if ($count -gt 0) { 'crit' } else { 'ok' }
				$undelivRowsHtml.Add("<tr><td>$([System.Net.WebUtility]::HtmlEncode($db.name))</td><td class='$sevClass'>$count</td></tr>") | Out-Null
			}
			$htmlSections.Add("<h3>Undeliverable Messages (Transmission Queue)</h3><table><tr><th>Database</th><th>Undeliverable</th></tr>$($undelivRowsHtml -join '')</table>") | Out-Null

			# 6. Service Pairs and Contracts
			$reportContent.Add("-" * 80) | Out-Null
			$reportContent.Add("Service Pairs and Contracts") | Out-Null
			$reportContent.Add("-" * 80) | Out-Null

			$serviceQuery = @"
SELECT
    s.name as ServiceName,
    sc.name as ContractName
FROM sys.services s
LEFT JOIN sys.service_contract_usages scu ON s.service_id = scu.service_id
LEFT JOIN sys.service_contracts sc ON scu.service_contract_id = sc.service_contract_id
ORDER BY s.name
"@

			$svcRowsHtml = [System.Collections.Generic.List[string]]::new()
			foreach ($db in $brokerDbs | Where-Object { $_.is_broker_enabled -eq 1 })
			{
				$services = $server.Query($serviceQuery, $db.name)
				if ($services)
				{
					$reportContent.Add("  Database: $($db.name)") | Out-Null
					foreach ($svc in $services)
					{
						$contract = if ($svc.ContractName) { $svc.ContractName } else { "N/A" }
						$reportContent.Add("    Service:  $($svc.ServiceName)") | Out-Null
						$reportContent.Add("    Contract: $contract") | Out-Null
						$reportContent.Add("") | Out-Null

						$svcRowsHtml.Add("<tr><td>$([System.Net.WebUtility]::HtmlEncode($db.name))</td><td>$([System.Net.WebUtility]::HtmlEncode($svc.ServiceName))</td><td>$([System.Net.WebUtility]::HtmlEncode($contract))</td></tr>") | Out-Null
					}
				}
			}
			$htmlSections.Add("<h3>Service Pairs and Contracts</h3><table><tr><th>Database</th><th>Service</th><th>Contract</th></tr>$($svcRowsHtml -join '')</table>") | Out-Null

			# 7. AlwaysOn Replica Status (falls AG vorhanden)
			if ($isAlwaysOn)
			{
				$reportContent.Add("-" * 80) | Out-Null
				$reportContent.Add("AlwaysOn Replica Status") | Out-Null
				$reportContent.Add("-" * 80) | Out-Null

				$replicaQuery = @"
SELECT
    ag.name as AGName,
    ar.replica_server_name,
    ar.availability_mode_desc,
    ars.role_desc,
    ars.operational_state_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
ORDER BY ag.name, ar.replica_server_name
"@

				$replicas = $server.Query($replicaQuery)
				if ($replicas)
				{
					$replicaRowsHtml = foreach ($r in $replicas)
					{
						$sevClass = if ($r.operational_state_desc -eq 'ONLINE' -or [string]::IsNullOrEmpty($r.operational_state_desc)) { 'ok' } else { 'warn' }
						"<tr><td>$([System.Net.WebUtility]::HtmlEncode($r.AGName))</td><td>$([System.Net.WebUtility]::HtmlEncode($r.replica_server_name))</td><td>$($r.role_desc)</td><td class='$sevClass'>$($r.operational_state_desc)</td></tr>"
					}
					foreach ($r in $replicas)
					{
						$reportContent.Add("  AG:       $($r.AGName)") | Out-Null
						$reportContent.Add("  Replica:  $($r.replica_server_name)") | Out-Null
						$reportContent.Add("  Role:     $($r.role_desc)") | Out-Null
						$reportContent.Add("  State:    $($r.operational_state_desc)") | Out-Null
						$reportContent.Add("") | Out-Null
					}
					$htmlSections.Add("<h3>AlwaysOn Replica Status</h3><table><tr><th>AG</th><th>Replica</th><th>Role</th><th>State</th></tr>$($replicaRowsHtml -join '')</table>") | Out-Null
				}
			}

			# Footer
			$reportContent.Add("=" * 80) | Out-Null
			$reportContent.Add("End of Report") | Out-Null

			# Report schreiben
			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "Report erstellt: $reportFile" -FunctionName $functionName -Level "INFO"

			# HTML-Bericht schreiben
			$html = ConvertTo-sqmHtmlReport -Title "Service Broker Health - $($server.Name)" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml ($htmlSections -join '')
			$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "HTML-Bericht erstellt: $htmlFile" -FunctionName $functionName -Level "INFO"

			# Return
			$result = [PSCustomObject]@{
				ComputerName = $server.Name
				ReportPath   = $reportFile
				HtmlPath     = $htmlFile
				Timestamp    = $timestamp
				IsAlwaysOn   = $isAlwaysOn
			}

			Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $reportFile -NoOpen:$NoOpen

			return $result
		}
		catch
		{
			$errMsg = "Fehler in $functionName`:`n$_"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException)
			{
				throw
			}
			elseif (-not $ContinueOnError)
			{
				throw
			}
		}
	}
}

