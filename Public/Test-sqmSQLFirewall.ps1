<#
.SYNOPSIS
    Tests whether the firewall and network allow a TCP connection to SQL Server.

.DESCRIPTION
    Attempts to establish a TCP connection to the specified SQL Server and port.
    By default, port 1433 (default instance) is used.

    For named instances, the SQL Browser service (UDP 1434) can additionally be
    queried to determine the dynamic TCP port of the instance.

    Returns one [PSCustomObject] per server/port combination with:
        Server, Port, Instance, TcpReachable, DynamicPort, Status, Message

.PARAMETER Server
    Hostname or IP address of the SQL Server. Pipeline-capable.

.PARAMETER Port
    TCP port to test. Default: 1433.
    Ignored when -Instance is specified and the SQL Browser provides the dynamic port.

.PARAMETER Instance
    Name of the named instance (without server prefix). When specified, the SQL Browser
    (UDP 1434) is first queried for the dynamic port of the instance, which is then
    tested via TCP.

.PARAMETER TimeoutSeconds
    Timeout for the TCP connection test in seconds. Default: 5.

.PARAMETER ContinueOnError
    Continue with the next server on error instead of aborting.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.OUTPUTS
    [PSCustomObject] with fields:
        Server       : Target server
        Port         : TCP port tested
        Instance     : Instance name (or $null for default instance)
        DynamicPort  : $true if port was determined via SQL Browser
        TcpReachable : $true if TCP connection was successful
        Status       : OK | Failed | Error
        Message      : Detail message

.EXAMPLE
    Test-sqmSQLFirewall -Server "SQL01"

    Tests the default instance on TCP port 1433.

.EXAMPLE
    Test-sqmSQLFirewall -Server "SQL01" -Port 54321

    Tests a custom port.

.EXAMPLE
    Test-sqmSQLFirewall -Server "SQL01" -Instance "SAGE"

    Determines the dynamic port of the "SAGE" instance via SQL Browser (UDP 1434)
    and then tests the TCP connection.

.EXAMPLE
    "SQL01","SQL02","SQL03" | Test-sqmSQLFirewall -Instance "PROD" -TimeoutSeconds 3

    Tests the "PROD" instance on three servers via pipeline.

.NOTES
    Prerequisites : PowerShell 3.0+, Test-NetConnection (from Windows 8 / 2012).
    SQL Browser   : UDP 1434 must be reachable on the target server when -Instance is used.
                    If not reachable, falls back to the port specified under -Port (default 1433).
#>
function Test-sqmSQLFirewall
{
	[CmdletBinding(SupportsShouldProcess = $false)]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
		[string[]]$Server,

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 65535)]
		[int]$Port = 1433,

		[Parameter(Mandatory = $false)]
		[string]$Instance,

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 60)]
		[int]$TimeoutSeconds = 5,

		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		Invoke-sqmLogging -Message "Starte $functionName$(if ($Instance) { " | Instanz=$Instance" }) | Port=$Port | Timeout=${TimeoutSeconds}s" `
						  -FunctionName $functionName -Level 'INFO'

		# ?? Hilfsfunktion: TCP-Port testen ???????????????????????????????????
		function _TestTcpPort
		{
			param (
				[string]$ComputerName,
				[int]   $TcpPort,
				[int]   $Timeout
			)
			try
			{
				$tcpClient = New-Object System.Net.Sockets.TcpClient
				$asyncResult = $tcpClient.BeginConnect($ComputerName, $TcpPort, $null, $null)
				$waitHandle  = $asyncResult.AsyncWaitHandle
				$connected   = $waitHandle.WaitOne([TimeSpan]::FromSeconds($Timeout), $false)
				if ($connected -and $tcpClient.Connected)
				{
					$tcpClient.EndConnect($asyncResult)
					$tcpClient.Close()
					return $true
				}
				$tcpClient.Close()
				return $false
			}
			catch
			{
				return $false
			}
		}

		# ?? Hilfsfunktion: SQL Browser UDP 1434 abfragen ?????????????????????
		function _GetDynamicPort
		{
			param (
				[string]$ComputerName,
				[string]$InstanceName
			)
			try
			{
				$udpClient = New-Object System.Net.Sockets.UdpClient
				$udpClient.Client.ReceiveTimeout = 3000

				$udpClient.Connect($ComputerName, 1434)

				# CLNT_UCAST_INST-Paket: 0x04 + Instanzname + 0x00
				$instBytes = [System.Text.Encoding]::ASCII.GetBytes($InstanceName)
				$request   = [byte[]]@(0x04) + $instBytes + [byte[]]@(0x00)
				$udpClient.Send($request, $request.Length) | Out-Null

				$remoteEP  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
				$response  = $udpClient.Receive([ref]$remoteEP)
				$udpClient.Close()

				# Antwort-Payload: Bytes 3..n als ASCII (Header = 3 Bytes)
				if ($response.Length -le 3) { return $null }
				$responseString = [System.Text.Encoding]::ASCII.GetString($response, 3, $response.Length - 3)

				# Format: "...;tcp;1433;..." - extrahiere Port hinter "tcp;"
				if ($responseString -match 'tcp;(\d+)')
				{
					return [int]$Matches[1]
				}
				return $null
			}
			catch
			{
				return $null
			}
			finally
			{
				if ($udpClient) { try { $udpClient.Close() } catch { } }
			}
		}
	}

	process
	{
		foreach ($srv in $Server)
		{
			$effectivePort = $Port
			$dynamicPort   = $false

			try
			{
				Invoke-sqmLogging -Message "[$srv] Starte Firewall-Test ..." -FunctionName $functionName -Level 'INFO'

				# ?? SQL Browser abfragen wenn Instanzname angegeben ???????????
				if ($Instance)
				{
					Invoke-sqmLogging -Message "[$srv] Ermittle dynamischen Port fuer Instanz '$Instance' via UDP 1434 ..." `
									  -FunctionName $functionName -Level 'INFO'

					$browserPort = _GetDynamicPort -ComputerName $srv -InstanceName $Instance

					if ($browserPort)
					{
						$effectivePort = $browserPort
						$dynamicPort   = $true
						Invoke-sqmLogging -Message "[$srv] SQL Browser: Instanz '$Instance' ? TCP-Port $effectivePort" `
										  -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						Invoke-sqmLogging -Message "[$srv] SQL Browser nicht erreichbar oder Instanz '$Instance' nicht gefunden - verwende Port $effectivePort als Fallback." `
										  -FunctionName $functionName -Level 'WARNING'
						Write-Warning "[$srv] SQL Browser (UDP 1434) hat keinen Port fuer Instanz '$Instance' geliefert. Fallback auf Port $effectivePort."
					}
				}

				# ?? TCP-Test ?????????????????????????????????????????????????
				Invoke-sqmLogging -Message "[$srv] Teste TCP ${srv}:${effectivePort} (Timeout: ${TimeoutSeconds}s) ..." `
								  -FunctionName $functionName -Level 'INFO'

				$tcpReachable = _TestTcpPort -ComputerName $srv -TcpPort $effectivePort -Timeout $TimeoutSeconds

				# ?? Ergebnis aufbauen ?????????????????????????????????????????
				if ($tcpReachable)
				{
					$status  = 'OK'
					$message = "TCP-Port $effectivePort auf '$srv' ist erreichbar." +
						$(if ($dynamicPort) { " (Dynamischer Port via SQL Browser fuer Instanz '$Instance'.)" })
					Invoke-sqmLogging -Message "[$srv] $message" -FunctionName $functionName -Level 'INFO'
				}
				else
				{
					$status  = 'Failed'
					$message = "TCP-Port $effectivePort auf '$srv' ist NICHT erreichbar. " +
						"Moegliche Ursachen: SQL Server-Dienst gestoppt, Windows-Firewall-Regel fehlt, " +
						"Netzwerkgeraet blockiert Port $effectivePort." +
						$(if ($Instance -and -not $dynamicPort) { " SQL Browser (UDP 1434) war nicht erreichbar." })
					Invoke-sqmLogging -Message "[$srv] $message" -FunctionName $functionName -Level 'WARNING'
				}

				$allResults.Add([PSCustomObject]@{
					Server       = $srv
					Port         = $effectivePort
					Instance     = if ($Instance) { $Instance } else { $null }
					DynamicPort  = $dynamicPort
					TcpReachable = $tcpReachable
					Status       = $status
					Message      = $message
				})
			}
			catch
			{
				$errMsg = "Fehler beim Test auf '$srv': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'

				$allResults.Add([PSCustomObject]@{
					Server       = $srv
					Port         = $effectivePort
					Instance     = if ($Instance) { $Instance } else { $null }
					DynamicPort  = $false
					TcpReachable = $false
					Status       = 'Error'
					Message      = $errMsg
				})

				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Server getestet." `
						  -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
