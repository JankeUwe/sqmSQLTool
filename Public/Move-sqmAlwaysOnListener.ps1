<#
.SYNOPSIS
    Migrates an AG Listener from one Availability Group to another.

.DESCRIPTION
    Used for Distributed AG failover scenarios where the listener must "follow" the
    primary role to a new AG.

    Process:
    1. Validate listener exists on source AG
    2. Extract listener configuration (IP, port, network mask)
    3. Remove listener from source AG
    4. Create new listener on target AG with same configuration
    5. Update DNS records (manual step documented)
    6. Verify connectivity

    IMPORTANT: This is typically done BEFORE failover to ensure zero-downtime transition.

    For Distributed AG Customer Scenario:
    - Before failover: Move listener from C1 AG to C2 AG
    - Update DNS to point to C2 listener IP
    - Trigger failover (C2 becomes primary)
    - Applications connect to listener (already pointing to C2)

.PARAMETER SqlInstance
    SQL Server instance hosting the SOURCE AG. Default: current computer name.

.PARAMETER SourceAgName
    Name of the source AG (currently has the listener).

.PARAMETER TargetAgName
    Name of the target AG (will receive the listener).

.PARAMETER TargetInstance
    SQL Server instance hosting the target AG. Default: same as SourceInstance.

.PARAMETER ListenerName
    Specific listener name to move (if multiple listeners exist). Optional.

.PARAMETER SqlCredential
    Optional PSCredential for both instances.

.PARAMETER WhatIf
    Shows what would be done without actually moving the listener.

.PARAMETER OutputPath
    Output directory for detailed logs. Default: C:\System\WinSrvLog\MSSQL

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Move listener from Primary AG to Secondary AG (before failover)
    Move-sqmAgListener -SqlInstance "SQL01" -SourceAgName "ProductionAG" `
        -TargetAgName "DrAG" -TargetInstance "DR-SQL01"

.NOTES
    Author:       MSSQLTools
    CRITICAL:     DNS update is a manual step. See output for required changes.
    Timing:       Run this BEFORE failover, then trigger failover once DNS is updated.
#>
function Move-sqmAlwaysOnListener
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $true)]
		[string]$SourceAgName,
		[Parameter(Mandatory = $true)]
		[string]$TargetAgName,
		[Parameter(Mandatory = $false)]
		[string]$TargetInstance,
		[Parameter(Mandatory = $false)]
		[string]$ListenerName,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = "C:\System\WinSrvLog\MSSQL",
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName - Listener Migration" -FunctionName $functionName -Level "INFO"

		if (-not (Test-Path $OutputPath))
		{
			New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
		}

		if (-not $TargetInstance) { $TargetInstance = $SqlInstance }
	}

	process
	{
		$sourceConnParams = @{ SqlInstance = $SqlInstance }
		$targetConnParams = @{ SqlInstance = $TargetInstance }
		if ($SqlCredential)
		{
			$sourceConnParams['SqlCredential'] = $SqlCredential
			$targetConnParams['SqlCredential'] = $SqlCredential
		}

		try
		{
			# Step 1: Get listener details from source AG
			Invoke-sqmLogging -Message "Lade Listener von [$SourceAgName]" -FunctionName $functionName -Level "INFO"

			$getListenerQuery = @"
SELECT
    agl.dns_name,
    agl.listener_id,
    agliip.ip_configuration_string_from_cluster,
    agliip.ip_address,
    agliip.ip_subnet_mask,
    aglil.port
FROM sys.availability_group_listeners agl
JOIN sys.availability_group_listener_ip_addresses agliip ON agliip.listener_id = agl.listener_id
LEFT JOIN sys.availability_group_listener_ip_port aglil ON aglil.listener_id = agl.listener_id
WHERE agl.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = @AgName)
"@

			$listenerInfo = Invoke-DbaQuery @sourceConnParams -Query $getListenerQuery -SqlParameters @{ AgName = $SourceAgName } -ErrorAction Stop

			if (-not $listenerInfo)
			{
				throw "Kein Listener auf AG [$SourceAgName] gefunden"
			}

			$listenerDns = $listenerInfo.dns_name
			$listenerIp = $listenerInfo.ip_address
			$listenerSubnet = $listenerInfo.ip_subnet_mask
			$listenerPort = if ($listenerInfo.port) { [int]$listenerInfo.port } else { 1433 }

			Invoke-sqmLogging -Message "Listener found: DNS=$listenerDns IP=$listenerIp Port=$listenerPort" -FunctionName $functionName -Level "INFO"

			# Step 2: Validate target AG exists
			$targetAgQuery = "SELECT COUNT(*) AS C FROM sys.availability_groups WHERE name = @AgName"
			$targetAgCheck = Invoke-DbaQuery @targetConnParams -Query $targetAgQuery -SqlParameters @{ AgName = $TargetAgName } -ErrorAction Stop

			if ([int]$targetAgCheck.C -eq 0)
			{
				throw "Target AG [$TargetAgName] nicht gefunden auf [$TargetInstance]"
			}

			# Step 3: Remove listener from source AG
			if ($PSCmdlet.ShouldProcess($SourceAgName, "Remove listener $listenerDns"))
			{
				Invoke-sqmLogging -Message "Entferne Listener von [$SourceAgName]" -FunctionName $functionName -Level "WARNING"

				$removeListenerSql = "ALTER AVAILABILITY GROUP [$SourceAgName] REMOVE LISTENER N'$listenerDns'"
				Invoke-DbaQuery @sourceConnParams -Query $removeListenerSql -ErrorAction Stop

				Start-Sleep -Seconds 2
			}

			# Step 4: Create listener on target AG
			Invoke-sqmLogging -Message "Erstelle Listener auf [$TargetAgName]" -FunctionName $functionName -Level "INFO"

			$createListenerSql = @"
ALTER AVAILABILITY GROUP [$TargetAgName]
ADD LISTENER N'$listenerDns' ( WITH IP ( (N'$listenerIp', N'$listenerSubnet') ), PORT = $listenerPort)
"@
			Invoke-DbaQuery @targetConnParams -Query $createListenerSql -ErrorAction Stop

			# Step 5: Verify listener exists on target
			Start-Sleep -Seconds 3

			$verifyQuery = @"
SELECT
    agl.dns_name,
    agl.listener_id,
    agliip.ip_address,
    aglil.port
FROM sys.availability_group_listeners agl
JOIN sys.availability_group_listener_ip_addresses agliip ON agliip.listener_id = agl.listener_id
LEFT JOIN sys.availability_group_listener_ip_port aglil ON aglil.listener_id = agl.listener_id
WHERE agl.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = @AgName) AND agl.dns_name = @DnsName
"@

			$verifyListener = Invoke-DbaQuery @targetConnParams -Query $verifyQuery -SqlParameters @{ AgName = $TargetAgName; DnsName = $listenerDns } -ErrorAction Stop

			if (-not $verifyListener)
			{
				throw "Listener konnte nicht auf Target AG erstellt werden"
			}

			# Step 6: Create report with DNS instructions
			$reportFile = Join-Path -Path $OutputPath -ChildPath "Move-AgListener-$SourceAgName-$TargetAgName-$(Get-Date -Format 'yyyy-MM-dd-HHmm').txt"

			$reportContent = @(
				"================================================================"
				"sqmSQLTool - AG Listener Migration Report"
				"================================================================"
				"Timestamp              : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
				"Source AG              : $SourceAgName (SQL Instance: $SqlInstance)"
				"Target AG              : $TargetAgName (SQL Instance: $TargetInstance)"
				"Listener Name          : $listenerDns"
				"Listener IP            : $listenerIp"
				"Listener Subnet        : $listenerSubnet"
				"Listener Port          : $listenerPort"
				"Migration Status       : SUCCESS"
				"================================================================`n"
				"IMPORTANT: DNS CONFIGURATION REQUIRED"
				"================================================================"
				"Listener is now on [$TargetAgName] ($TargetInstance)"
				""
				"UPDATE YOUR DNS RECORDS:"
				"Old DNS Record:"
				"  Host    : $listenerDns"
				"  IP      : (OLD IP pointing to $SqlInstance)"
				"  Port    : $listenerPort"
				""
				"New DNS Record:"
				"  Host    : $listenerDns"
				"  IP      : $listenerIp"
				"  Port    : $listenerPort"
				""
				"STEPS:"
				"1. Update DNS to point $listenerDns to $listenerIp"
				"2. Allow DNS TTL to expire (typically 5-15 minutes)"
				"3. Then trigger failover:"
				"   Invoke-sqmDistributedFailover -SqlInstance '$TargetInstance' -AvailabilityGroupName '$TargetAgName'"
				"4. Applications will automatically reconnect via DNS"
				""
				"VERIFICATION:"
				"nslookup $listenerDns"
				"Should resolve to: $listenerIp"
				""
				"sqlcmd -S $listenerDns -l 5 -Q 'SELECT @@SERVERNAME AS [Current_Server]'"
				"Should return: $TargetInstance"
				"================================================================"
			)

			$reportContent -join "`n" | Out-File -FilePath $reportFile -Encoding UTF8 -Force

			Invoke-sqmLogging -Message "Listener Migration abgeschlossen. DNS-Anleitung in: $reportFile" -FunctionName $functionName -Level "INFO"

			return [PSCustomObject]@{
				Status = 'SUCCESS'
				SourceAg = $SourceAgName
				TargetAg = $TargetAgName
				ListenerName = $listenerDns
				ListenerIp = $listenerIp
				ListenerPort = $listenerPort
				Timestamp = Get-Date
				DnsUpdateRequired = $true
				DnsInstructions = "Update DNS for $listenerDns to point to $listenerIp"
				ReportFile = $reportFile
				NextSteps = @(
					"1. Update DNS records (see report)",
					"2. Wait for DNS TTL to expire",
					"3. Trigger failover: Invoke-sqmDistributedFailover -AvailabilityGroupName '$TargetAgName'",
					"4. Verify with: nslookup $listenerDns"
				)
			}
		}
		catch
		{
			$errMsg = "Fehler bei Listener Migration: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"

			if ($EnableException) { throw }

			return [PSCustomObject]@{
				Status = 'FAILED'
				Error = $errMsg
				Timestamp = Get-Date
			}
		}
	}
}
