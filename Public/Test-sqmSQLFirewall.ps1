<#
.SYNOPSIS
    Testet ob Firewall und Netzwerk eine TCP-Verbindung zum SQL Server zulassen.

.DESCRIPTION
    Versucht eine TCP-Verbindung zum angegebenen SQL Server und Port aufzubauen.
    Standardmaessig wird Port 1433 (Default-Instanz) verwendet.

    Fuer benannte Instanzen kann zusaetzlich der SQL Browser-Dienst (UDP 1434)
    abgefragt werden, um den dynamischen TCP-Port der Instanz zu ermitteln.

    Gibt pro Server/Port-Kombination ein [PSCustomObject] zurueck mit:
        Server, Port, Instance, TcpReachable, DynamicPort, Status, Message

.PARAMETER Server
    Hostname oder IP-Adresse des SQL Servers. Pipeline-faehig.

.PARAMETER Port
    TCP-Port der getestet werden soll. Standard: 1433.
    Wird ignoriert wenn -Instance angegeben ist und der SQL Browser den
    dynamischen Port liefert.

.PARAMETER Instance
    Name der benannten Instanz (ohne Serverpraefix). Wenn angegeben wird zuerst
    der SQL Browser (UDP 1434) nach dem dynamischen Port der Instanz befragt
    und dieser dann per TCP getestet.

.PARAMETER TimeoutSeconds
    Timeout fuer den TCP-Verbindungstest in Sekunden. Standard: 5.

.PARAMETER ContinueOnError
    Bei Fehler auf einem Server fortfahren statt abzubrechen.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen (ueberschreibt ContinueOnError).

.OUTPUTS
    [PSCustomObject] mit den Feldern:
        Server       : Zielserver
        Port         : Getesteter TCP-Port
        Instance     : Instanzname (oder $null bei Default)
        DynamicPort  : $true wenn Port per SQL Browser ermittelt wurde
        TcpReachable : $true wenn TCP-Verbindung erfolgreich
        Status       : OK | Failed | Error
        Message      : Detailmeldung

.EXAMPLE
    Test-sqmSQLFirewall -Server "SQL01"

    Testet die Standardinstanz auf TCP-Port 1433.

.EXAMPLE
    Test-sqmSQLFirewall -Server "SQL01" -Port 54321

    Testet einen benutzerdefinierten Port.

.EXAMPLE
    Test-sqmSQLFirewall -Server "SQL01" -Instance "SAGE"

    Ermittelt den dynamischen Port der Instanz "SAGE" via SQL Browser (UDP 1434)
    und testet anschliessend die TCP-Verbindung.

.EXAMPLE
    "SQL01","SQL02","SQL03" | Test-sqmSQLFirewall -Instance "PROD" -TimeoutSeconds 3

    Testet die Instanz "PROD" auf drei Servern per Pipeline.

.NOTES
    Voraussetzungen : PowerShell 3.0+, Test-NetConnection (ab Windows 8 / 2012).
    SQL Browser     : UDP 1434 muss auf dem Zielserver erreichbar sein wenn
                      -Instance verwendet wird. Ist er nicht erreichbar, wird
                      auf den unter -Port angegebenen Wert (Standard 1433)
                      zurueckgefallen.
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
