#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the registered SPNs for SQL Server instances (default and named instances).

.DESCRIPTION
    Automatically determines all SQL Server services on the specified computer,
    identifies the service account per instance and derives the AD account for
    the SPN check.

    Supported service account types:
    - Domain account (DOMAIN\svc_sql)        -> used directly as SPN account
    - Computer-account-based accounts (SYSTEM,
      NETWORK SERVICE, NT SERVICE\*)         -> computer account (DOMAIN\HOSTNAME$)
      The computer account is determined cleanly via
      [System.DirectoryServices.ActiveDirectory.Domain].
    - LOCAL SERVICE                          -> no network identity, SPNs
      not possible -> finding with status 'NoNetwork'

    Per instance, the four expected MSSQLSvc SPNs are checked:
        MSSQLSvc/<Hostname>:<Port>
        MSSQLSvc/<FQDN>:<Port>
        MSSQLSvc/<Hostname>        (default instance only, port 1433)
        MSSQLSvc/<FQDN>            (default instance only, port 1433)

    For named instances (dynamic port via SQL Browser), additional instance-name SPNs are checked:
        MSSQLSvc/<Hostname>:<InstanceName>
        MSSQLSvc/<FQDN>:<InstanceName>

    Missing SPNs are prepared as ready-to-use setspn.exe commands
    that can be handed to the AD team.

    Output per instance:
        SpnReport_<Computer>_<Instance>_<Date>.txt   - Readable report including setspn commands
        SpnReport_<Computer>_<Instance>_<Date>.csv   - Machine-readable (one row per SPN)

.PARAMETER ComputerName
    Target computer. Default: local computer. Pipeline-capable.

.PARAMETER InstanceFilter
    Optional filter on instance names (wildcards allowed).
    Example: 'MSSQLSERVER' for default instance only, 'SQL*' for named instances.

.PARAMETER OutputPath
    Output directory for report and CSV.
    Default: module configuration (Get-sqmConfig -Key 'OutputPath').

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before creating files.

.PARAMETER WhatIf
    Shows which files would be created without writing them.

.EXAMPLE
    Get-sqmSpnReport

    Checks all SQL Server instances on the local computer.

.EXAMPLE
    Get-sqmSpnReport -ComputerName 'SQL01' -InstanceFilter 'MSSQLSERVER'

    Checks only the default instance on SQL01.

.EXAMPLE
    'SQL01','SQL02' | Get-sqmSpnReport -ContinueOnError

    Checks all instances on two servers; errors are skipped.

.EXAMPLE
    $result = Get-sqmSpnReport -ComputerName 'SQL01'
    $result.DetailRows | Where-Object Status -eq 'Missing' | Select-Object Spn, SetSpnCommand

    Returns only missing SPNs with the ready-to-use setspn command.

.NOTES
    Prerequisites:
    - Invoke-sqmLogging, Get-sqmConfig
    - setspn.exe in the system path (Windows default or RSAT)
    - Local administrator rights on the target computer for WMI queries
    - AD module (RSAT) is NOT required; domain resolution is performed via
      [System.DirectoryServices.ActiveDirectory.Domain]
#>
function Get-sqmSpnReport
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[Alias('Computer', 'Server')]
		[string[]]$ComputerName = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[string]$InstanceFilter = '*',

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Get-sqmConfig -Key 'OutputPath'),

		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		# setspn.exe verfuegbar?
		$setspnCmd = Get-Command -Name 'setspn.exe' -ErrorAction SilentlyContinue
		if (-not $setspnCmd)
		{
			$errMsg = "setspn.exe nicht gefunden. RSAT oder Windows-Tools pruefen."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
			throw $errMsg
		}
		Invoke-sqmLogging -Message "setspn.exe gefunden: $($setspnCmd.Source)" `
						  -FunctionName $functionName -Level 'INFO'

		Invoke-sqmLogging -Message "Starte $functionName | OutputPath: $OutputPath" `
						  -FunctionName $functionName -Level 'INFO'

		# ------------------------------------------------------------------
		# Hilfsfunktion: Dienstkonto ? SPN-Konto + Konto-Typ bestimmen
		#
		# Rueckgabe: [PSCustomObject] mit
		#   AccountType  : 'Domain' | 'Computer' | 'NoNetwork'
		#   SpnAccount   : Das Konto, unter dem die SPNs registriert sind
		#   Note         : Erklaerungstext fuer den Bericht
		# ------------------------------------------------------------------
		function _ResolveSpnAccount
		{
			param (
				[string]$ServiceAccount,
				[string]$HostName
			)

			# LOCAL SERVICE - keine Netzwerkidentitaet
			if ($ServiceAccount -match '(?i)(NT AUTHORITY\\LOCAL SERVICE|NT-AUTORIT[Aae]T\\LOKALER DIENST)')
			{
				return [PSCustomObject]@{
					AccountType = 'NoNetwork'
					SpnAccount  = $null
					Note        = "Konto '$ServiceAccount' hat keine Netzwerkidentitaet. Kerberos/SPNs nicht moeglich. " +
					              "Empfehlung: Dienstkonto auf Domaenenkonto, NETWORK SERVICE oder gMSA umstellen."
				}
			}

			# Eingebaute Konten die als Computerkonto im Netzwerk agieren:
			#   NT AUTHORITY\SYSTEM / NT-AUTORITaeT\SYSTEM
			#   NT AUTHORITY\NETWORK SERVICE / NT-AUTORITaeT\NETZWERKDIENST
			#   NT SERVICE\<VirtualAccount>   (z.B. NT SERVICE\MSSQLSERVER)
			#   LocalSystem (Legacy-Schreibweise)
			$isBuiltinComputerAccount = $ServiceAccount -match (
				'(?i)(' +
				    'LocalSystem'                       + '|' +
				    'NT AUTHORITY\\SYSTEM'              + '|' +
				    'NT-AUTORIT[Aae]T\\SYSTEM'           + '|' +
				    'NT AUTHORITY\\NETWORK SERVICE'     + '|' +
				    'NT-AUTORIT[Aae]T\\NETZWERKDIENST'  + '|' +
				    'NT SERVICE\\'                      +
				')'
			)

			if ($isBuiltinComputerAccount)
			{
				# Domaene sauber ueber .NET ermitteln - kein $env:USERDOMAIN
				# (der kann auf Mitgliedsservern den lokalen Computernamen liefern)
				$domainPrefix = $null
				try
				{
					$adDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
					# NetBIOS-Name aus dem Distinguished Name ableiten ist nicht direkt
					# moeglich; zuverlaessigster Weg: LDAP-Abfrage auf das Computerobjekt
					# oder den NetBIOS-Namen via WMI holen.
					$wmiDomain = Get-CimInstance -ClassName Win32_ComputerSystem `
					                              -ErrorAction Stop |
					             Select-Object -ExpandProperty Domain
					# Win32_ComputerSystem.Domain liefert den FQDN der Domaene.
					# NetBIOS-Name via Win32_NTDomain (zuverlaessiger als USERDOMAIN):
					$ntDomain = Get-CimInstance -ClassName Win32_NTDomain `
					                             -Filter "DnsForestName IS NOT NULL" `
					                             -ErrorAction SilentlyContinue |
					            Where-Object { $_.DnsForestName -and $_.DomainName } |
					            Select-Object -First 1 -ExpandProperty DomainName

					$domainPrefix = if ($ntDomain) { $ntDomain } else { $wmiDomain.Split('.')[0].ToUpper() }
				}
				catch
				{
					# Fallback: erster Teil des COMPUTERNAME-FQDN oder USERDOMAIN
					$domainPrefix = if ($env:USERDNSDOMAIN)
					                { $env:USERDNSDOMAIN.Split('.')[0].ToUpper() }
					                else
					                { $env:USERDOMAIN }
					Invoke-sqmLogging -Message "Domaenenermittlung via .NET fehlgeschlagen, Fallback: $domainPrefix. Fehler: $($_.Exception.Message)" `
					                  -FunctionName $functionName -Level 'WARNING'
				}

				$spnAccount = "${domainPrefix}\${HostName}$"
				return [PSCustomObject]@{
					AccountType = 'Computer'
					SpnAccount  = $spnAccount
					Note        = "Konto '$ServiceAccount' agiert als Computerkonto. SPNs werden unter '$spnAccount' geprueft."
				}
			}

			# Echtes Domaenenkonto (DOMAIN\user oder user@domain.local)
			return [PSCustomObject]@{
				AccountType = 'Domain'
				SpnAccount  = $ServiceAccount
				Note        = "Domaenenkonto '$ServiceAccount' wird direkt fuer SPN-Pruefung verwendet."
			}
		}

		# ------------------------------------------------------------------
		# Hilfsfunktion: Vorhandene MSSQLSvc-SPNs via setspn.exe einlesen
		# Rueckgabe: [string[]] der gefundenen SPNs, oder $null bei Fehler
		# ------------------------------------------------------------------
		function _GetExistingSpns
		{
			param ([string]$SpnAccount)

			try
			{
				$raw = & setspn.exe -L $SpnAccount 2>&1
				$text = $raw -join "`n"

				if ($text -match '(?i)(no such|Kein Objekt|cannot find|nicht gefunden|Object not found)')
				{
					return $null   # Konto nicht in AD gefunden
				}

				$spns = $raw |
				        Where-Object { $_ -match 'MSSQLSvc' } |
				        ForEach-Object { $_.Trim() }

				return @($spns)
			}
			catch
			{
				throw "setspn.exe Ausfuehrungsfehler: $($_.Exception.Message)"
			}
		}
	}

	process
	{
		foreach ($computer in $ComputerName)
		{
			Invoke-sqmLogging -Message "[$computer] Beginne SPN-Pruefung ..." `
							  -FunctionName $functionName -Level 'INFO'

			# ------------------------------------------------------------------
			# Hostname und FQDN des Zielcomputers ermitteln
			# ------------------------------------------------------------------
			$hostName = $computer.ToUpper().Split('.')[0]   # nur NetBIOS-Teil
			$fqdn     = $computer

			try
			{
				$fqdn = [System.Net.Dns]::GetHostEntry($hostName).HostName
			}
			catch
			{
				Invoke-sqmLogging -Message "[$computer] FQDN-Aufloesung fehlgeschlagen, verwende '$hostName'. Fehler: $($_.Exception.Message)" `
								  -FunctionName $functionName -Level 'WARNING'
				$fqdn = $hostName
			}

			Invoke-sqmLogging -Message "[$computer] Hostname: $hostName | FQDN: $fqdn" `
							  -FunctionName $functionName -Level 'INFO'

			# ------------------------------------------------------------------
			# Alle SQL Server-Dienste auf dem Computer via CIM ermitteln
			# Dienste: MSSQLSERVER (Standard) und MSSQL$<Instanzname> (benannt)
			# ------------------------------------------------------------------
			$sqlServices = $null
			try
			{
				$isLocal = ($hostName -eq $env:COMPUTERNAME)
				$cimParams = @{ ClassName = 'Win32_Service'; ErrorAction = 'Stop' }

				if (-not $isLocal)
				{
					$cimSession = New-CimSession -ComputerName $hostName -ErrorAction Stop
					$cimParams['CimSession'] = $cimSession
				}

				$sqlServices = Get-CimInstance @cimParams |
				               Where-Object {
				                   $_.Name -eq 'MSSQLSERVER' -or
				                   $_.Name -like 'MSSQL$*'
				               }
			}
			catch
			{
				$errMsg = "[$computer] SQL Server-Dienste konnten nicht abgefragt werden: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'

				$allResults.Add([PSCustomObject]@{
					ComputerName = $computer
					InstanceName = '(alle)'
					Status       = 'Error'
					Message      = $errMsg
					DetailRows   = $null
					TxtFile      = $null
					CsvFile      = $null
				})

				if ($EnableException) { throw $errMsg }
				if (-not $ContinueOnError) { throw $errMsg }
				continue
			}

			if (-not $sqlServices)
			{
				$warnMsg = "[$computer] Keine SQL Server-Dienste gefunden."
				Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level 'WARNING'

				$allResults.Add([PSCustomObject]@{
					ComputerName = $computer
					InstanceName = '(keine)'
					Status       = 'Warning'
					Message      = $warnMsg
					DetailRows   = $null
					TxtFile      = $null
					CsvFile      = $null
				})
				continue
			}

			# ------------------------------------------------------------------
			# Pro SQL Server-Dienst
			# ------------------------------------------------------------------
			foreach ($svc in $sqlServices)
			{
				# Instanzname ableiten:
				#   MSSQLSERVER         ? Standardinstanz
				#   MSSQL$INSTANZNAME   ? benannte Instanz
				$isDefaultInstance = ($svc.Name -eq 'MSSQLSERVER')
				$instanceName = if ($isDefaultInstance) { 'MSSQLSERVER' }
				               else { $svc.Name -replace '^MSSQL\$', '' }

				# InstanceFilter anwenden
				if ($instanceName -notlike $InstanceFilter)
				{
					Invoke-sqmLogging -Message "[$computer\$instanceName] uebersprungen (InstanceFilter: '$InstanceFilter')." `
									  -FunctionName $functionName -Level 'VERBOSE'
					continue
				}

				Invoke-sqmLogging -Message "[$computer\$instanceName] Verarbeite Dienst '$($svc.Name)' ..." `
								  -FunctionName $functionName -Level 'INFO'

				$detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()

				try
				{
					$serviceAccount = $svc.StartName
					Invoke-sqmLogging -Message "[$computer\$instanceName] Dienstkonto: $serviceAccount" `
									  -FunctionName $functionName -Level 'INFO'

					# --------------------------------------------------------
					# Konto-Typ und SPN-Konto aufloesen
					# --------------------------------------------------------
					$accountInfo = _ResolveSpnAccount -ServiceAccount $serviceAccount -HostName $hostName

					Invoke-sqmLogging -Message "[$computer\$instanceName] Konto-Typ: $($accountInfo.AccountType) | $($accountInfo.Note)" `
									  -FunctionName $functionName -Level 'INFO'

					# LOCAL SERVICE ? sofort als Befund ablegen, keine SPN-Pruefung
					if ($accountInfo.AccountType -eq 'NoNetwork')
					{
						$detailRows.Add([PSCustomObject]@{
							ComputerName   = $computer
							InstanceName   = $instanceName
							ServiceName    = $svc.Name
							ServiceAccount = $serviceAccount
							AccountType    = $accountInfo.AccountType
							SpnAccount     = $null
							Spn            = $null
							Status         = 'NoNetwork'
							SetSpnCommand  = $null
							Note           = $accountInfo.Note
						})

						Invoke-sqmLogging -Message "[$computer\$instanceName] WARNUNG: $($accountInfo.Note)" `
										  -FunctionName $functionName -Level 'WARNING'

						# Bericht schreiben und naechste Instanz
						_WriteReport -Computer $computer -Instance $instanceName `
						             -ServiceAccount $serviceAccount -AccountInfo $accountInfo `
						             -HostName $hostName -Fqdn $fqdn `
						             -DetailRows $detailRows -OutputPath $OutputPath `
						             -AllResults $allResults -Status 'Warning'
						continue
					}

					$spnAccount = $accountInfo.SpnAccount

					# --------------------------------------------------------
					# SQL Server-Port ermitteln
					# Standardinstanz: 1433 (oder konfiguriert)
					# Benannte Instanz: dynamisch aus Registry
					# --------------------------------------------------------
					$sqlPort = 1433
					try
					{
						# Registry-Pfad fuer TCP-Port:
						# HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\<InstanceReg>\MSSQLServer\SuperSocketNetLib\Tcp\IPAll
						$regBase = 'SOFTWARE\Microsoft\Microsoft SQL Server'

						# Instanz-Registry-Schluesselname ermitteln via SqlInstanceNames
						$regInstKeyPath = "HKLM:\$regBase\Instance Names\SQL"
						$regInstKey = $null

						if ($isLocal)
						{
							$regInstKey = Get-ItemProperty -Path $regInstKeyPath -ErrorAction SilentlyContinue
						}
						else
						{
							$regInstKey = Invoke-Command -ComputerName $hostName -ScriptBlock {
								param($p)
								Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
							} -ArgumentList $regInstKeyPath -ErrorAction SilentlyContinue
						}

						if ($regInstKey -and $regInstKey.$instanceName)
						{
							$instRegName = $regInstKey.$instanceName  # z.B. MSSQL16.INSTANZNAME
							$tcpPath = "HKLM:\$regBase\$instRegName\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"

							$tcpKey = $null
							if ($isLocal)
							{
								$tcpKey = Get-ItemProperty -Path $tcpPath -ErrorAction SilentlyContinue
							}
							else
							{
								$tcpKey = Invoke-Command -ComputerName $hostName -ScriptBlock {
									param($p)
									Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
								} -ArgumentList $tcpPath -ErrorAction SilentlyContinue
							}

							if ($tcpKey)
							{
								# TcpPort gesetzt ? statischer Port; leer ? dynamischer Port (TcpDynamicPorts)
								$staticPort  = $tcpKey.TcpPort
								$dynamicPort = $tcpKey.TcpDynamicPorts

								if ($staticPort -and $staticPort -ne '0' -and $staticPort -ne '')
								{
									$sqlPort = [int]$staticPort
									Invoke-sqmLogging -Message "[$computer\$instanceName] Statischer Port aus Registry: $sqlPort" `
													  -FunctionName $functionName -Level 'INFO'
								}
								elseif ($dynamicPort -and $dynamicPort -ne '0' -and $dynamicPort -ne '')
								{
									$sqlPort = [int]$dynamicPort
									Invoke-sqmLogging -Message "[$computer\$instanceName] Dynamischer Port aus Registry: $sqlPort" `
													  -FunctionName $functionName -Level 'INFO'
								}
							}
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$computer\$instanceName] Port-Ermittlung aus Registry fehlgeschlagen, verwende 1433. Fehler: $($_.Exception.Message)" `
										  -FunctionName $functionName -Level 'WARNING'
						$sqlPort = 1433
					}

					# --------------------------------------------------------
					# Erwartete SPNs definieren
					#
					# Standardinstanz (MSSQLSERVER):
					#   MSSQLSvc/<host>:1433      MSSQLSvc/<fqdn>:1433
					#   MSSQLSvc/<host>           MSSQLSvc/<fqdn>
					#
					# Benannte Instanz:
					#   MSSQLSvc/<host>:<port>    MSSQLSvc/<fqdn>:<port>
					#   MSSQLSvc/<host>:<instanz> MSSQLSvc/<fqdn>:<instanz>
					# --------------------------------------------------------
					$expectedSpns = if ($isDefaultInstance)
					{
						@(
							"MSSQLSvc/${hostName}:${sqlPort}",
							"MSSQLSvc/${fqdn}:${sqlPort}",
							"MSSQLSvc/$hostName",
							"MSSQLSvc/$fqdn"
						)
					}
					else
					{
						@(
							"MSSQLSvc/${hostName}:${sqlPort}",
							"MSSQLSvc/${fqdn}:${sqlPort}",
							"MSSQLSvc/${hostName}:${instanceName}",
							"MSSQLSvc/${fqdn}:${instanceName}"
						)
					}

					Invoke-sqmLogging -Message "[$computer\$instanceName] Erwartete SPNs: $($expectedSpns -join ' | ')" `
									  -FunctionName $functionName -Level 'INFO'

					# --------------------------------------------------------
					# Vorhandene SPNs via setspn.exe einlesen
					# --------------------------------------------------------
					$existingSpns = _GetExistingSpns -SpnAccount $spnAccount

					if ($null -eq $existingSpns)
					{
						throw "Konto '$spnAccount' wurde in AD nicht gefunden (setspn -L lieferte kein Objekt)."
					}

					Invoke-sqmLogging -Message "[$computer\$instanceName] Vorhandene MSSQLSvc-SPNs ($($existingSpns.Count)): $($existingSpns -join ' | ')" `
									  -FunctionName $functionName -Level 'INFO'

					# --------------------------------------------------------
					# Soll-/Ist-Vergleich ? Detailzeilen aufbauen
					# --------------------------------------------------------
					foreach ($expectedSpn in $expectedSpns)
					{
						$isPresent = $existingSpns | Where-Object { $_ -ieq $expectedSpn }
						$status    = if ($isPresent) { 'OK' } else { 'Missing' }
						$setSpnCmd = if (-not $isPresent)
						{
							"setspn -S $expectedSpn `"$spnAccount`""
						}
						else { $null }

						$detailRows.Add([PSCustomObject]@{
							ComputerName   = $computer
							InstanceName   = $instanceName
							ServiceName    = $svc.Name
							ServiceAccount = $serviceAccount
							AccountType    = $accountInfo.AccountType
							SpnAccount     = $spnAccount
							Spn            = $expectedSpn
							Status         = $status
							SetSpnCommand  = $setSpnCmd
							Note           = $accountInfo.Note
						})
					}

					# Zusaetzlich: bereits gesetzte SPNs die NICHT in der Erwartungsliste
					# stehen ? als 'Unexpected' melden (z.B. nach Portaenderung verwaiste SPNs)
					foreach ($existingSpn in $existingSpns)
					{
						$isExpected = $expectedSpns | Where-Object { $_ -ieq $existingSpn }
						if (-not $isExpected)
						{
							$detailRows.Add([PSCustomObject]@{
								ComputerName   = $computer
								InstanceName   = $instanceName
								ServiceName    = $svc.Name
								ServiceAccount = $serviceAccount
								AccountType    = $accountInfo.AccountType
								SpnAccount     = $spnAccount
								Spn            = $existingSpn
								Status         = 'Unexpected'
								SetSpnCommand  = $null
								Note           = "SPN vorhanden, aber nicht in Erwartungsliste (veraltet / Portaenderung?). Ggf. entfernen: setspn -D $existingSpn `"$spnAccount`""
							})
						}
					}

					$cntOk         = ($detailRows | Where-Object Status -eq 'OK').Count
					$cntMissing    = ($detailRows | Where-Object Status -eq 'Missing').Count
					$cntUnexpected = ($detailRows | Where-Object Status -eq 'Unexpected').Count

					Invoke-sqmLogging -Message "[$computer\$instanceName] OK: $cntOk | Fehlend: $cntMissing | Unerwartet: $cntUnexpected" `
									  -FunctionName $functionName -Level 'INFO'

					if ($cntMissing -gt 0)
					{
						Invoke-sqmLogging -Message "[$computer\$instanceName] $cntMissing SPN(s) fehlen - setspn-Kommandos im Bericht." `
										  -FunctionName $functionName -Level 'WARNING'
					}
					if ($cntUnexpected -gt 0)
					{
						Invoke-sqmLogging -Message "[$computer\$instanceName] $cntUnexpected unerwartete SPN(s) vorhanden." `
										  -FunctionName $functionName -Level 'WARNING'
					}

					# --------------------------------------------------------
					# Gesamtstatus der Instanz
					# --------------------------------------------------------
					$instanceStatus = if ($cntMissing -gt 0 -or $cntUnexpected -gt 0) { 'Warning' }
					                  else { 'OK' }

					# --------------------------------------------------------
					# Bericht schreiben
					# --------------------------------------------------------
					$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
					$datestamp = Get-Date -Format 'yyyy-MM-dd'
					$safeComp  = $computer   -replace '[\\/:*?"<>|]', '_'
					$safeInst  = $instanceName -replace '[\\/:*?"<>|]', '_'
					$txtFile   = Join-Path $OutputPath "SpnReport_${safeComp}_${safeInst}_${datestamp}.txt"
					$csvFile   = Join-Path $OutputPath "SpnReport_${safeComp}_${safeInst}_${datestamp}.csv"

					if ($PSCmdlet.ShouldProcess("$computer\$instanceName", "Erstelle SPN-Bericht in $OutputPath"))
					{
						if (-not (Test-Path $OutputPath))
						{
							New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
							Invoke-sqmLogging -Message "Verzeichnis '$OutputPath' wurde erstellt." `
											  -FunctionName $functionName -Level 'INFO'
						}

						$lines = [System.Collections.Generic.List[string]]::new()
						$sep   = '=' * 70
						$dash  = '-' * 70

						$lines.Add($sep)
						$lines.Add("# sqmSQLTool - SPN-Pruefbericht")
						$lines.Add("# Computer       : $computer")
						$lines.Add("# Hostname        : $hostName")
						$lines.Add("# FQDN            : $fqdn")
						$lines.Add("# Instanz         : $instanceName")
						$lines.Add("# Dienst          : $($svc.Name)")
						$lines.Add("# Dienstkonto     : $serviceAccount")
						$lines.Add("# Konto-Typ       : $($accountInfo.AccountType)")
						$lines.Add("# SPN-Konto (AD)  : $spnAccount")
						$lines.Add("# SQL-Port        : $sqlPort")
						$lines.Add("# Erstellt        : $timestamp")
						$lines.Add("# Status          : $instanceStatus")
						$lines.Add("# OK              : $cntOk")
						$lines.Add("# Fehlend         : $cntMissing")
						$lines.Add("# Unerwartet      : $cntUnexpected")
						$lines.Add($sep)

						# Hinweis bei Computerkonto
						if ($accountInfo.AccountType -eq 'Computer')
						{
							$lines.Add("")
							$lines.Add("# Hinweis: Dienstkonto '$serviceAccount' agiert als Computerkonto.")
							$lines.Add("# SPNs werden unter '$spnAccount' geprueft und registriert.")
						}

						# Ergebnis: OK-SPNs
						$okSpns = $detailRows | Where-Object Status -eq 'OK'
						$lines.Add("")
						$lines.Add($dash)
						$lines.Add("# VORHANDENE SPNs ($cntOk / 4 erwartet)")
						$lines.Add($dash)
						if ($okSpns)
						{
							foreach ($r in $okSpns)
							{
								$lines.Add("  ?  $($r.Spn)")
							}
						}
						else
						{
							$lines.Add("  (keine der erwarteten SPNs vorhanden)")
						}

						# Ergebnis: Fehlende SPNs + setspn-Kommandos
						$missingSpns = $detailRows | Where-Object Status -eq 'Missing'
						$lines.Add("")
						$lines.Add($dash)
						$lines.Add("# FEHLENDE SPNs ($cntMissing)  ? AKTION ERFORDERLICH")
						$lines.Add($dash)
						if ($missingSpns)
						{
							$lines.Add("")
							$lines.Add("  Bitte folgende Kommandos als Domain-Admin ausfuehren:")
							$lines.Add("  (Parameter -S prueft auf Duplikate, bevorzugt gegenueber -A)")
							$lines.Add("")
							foreach ($r in $missingSpns)
							{
								$lines.Add("  ?  $($r.Spn)")
								$lines.Add("     $($r.SetSpnCommand)")
								$lines.Add("")
							}
							$lines.Add("  Pruefung nach dem Setzen:")
							$lines.Add("  setspn -L `"$spnAccount`"")
							$lines.Add("")
							$lines.Add("  Berechtigung: Schreibrecht auf das Konto '$spnAccount' erforderlich.")
						}
						else
						{
							$lines.Add("  (keine fehlenden SPNs - kein Handlungsbedarf)")
						}

						# Unerwartete SPNs
						$unexpectedSpns = $detailRows | Where-Object Status -eq 'Unexpected'
						$lines.Add("")
						$lines.Add($dash)
						$lines.Add("# UNERWARTETE SPNs ($cntUnexpected)  ? PRueFEN (ggf. veraltet)")
						$lines.Add($dash)
						if ($unexpectedSpns)
						{
							foreach ($r in $unexpectedSpns)
							{
								$lines.Add("  ?  $($r.Spn)")
								$lines.Add("     $($r.Note)")
								$lines.Add("")
							}
						}
						else
						{
							$lines.Add("  (keine unerwarteten SPNs)")
						}

						$lines.Add("")
						$lines.Add($sep)
						$lines.Add("# Logdatei : $txtFile")
						$lines.Add("# CSV      : $csvFile")
						$lines.Add($sep)

						$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
						$detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

						Invoke-sqmLogging -Message "[$computer\$instanceName] Bericht erstellt: $txtFile" `
										  -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						Invoke-sqmLogging -Message "[$computer\$instanceName] WhatIf: Berichtsdateien wuerden erstellt werden." `
										  -FunctionName $functionName -Level 'VERBOSE'
						$txtFile = $null
						$csvFile = $null
					}

					$allResults.Add([PSCustomObject]@{
						ComputerName   = $computer
						InstanceName   = $instanceName
						ServiceName    = $svc.Name
						ServiceAccount = $serviceAccount
						AccountType    = $accountInfo.AccountType
						SpnAccount     = $spnAccount
						SqlPort        = $sqlPort
						CountOk        = $cntOk
						CountMissing   = $cntMissing
						CountUnexpected = $cntUnexpected
						Status         = $instanceStatus
						Message        = if ($instanceStatus -eq 'OK')
						                 { "Alle SPNs korrekt gesetzt." }
						                 else
						                 { "$cntMissing fehlende, $cntUnexpected unerwartete SPN(s). Bericht pruefen." }
						DetailRows     = $detailRows
						TxtFile        = $txtFile
						CsvFile        = $csvFile
					})
				}
				catch
				{
					$errMsg = "[$computer\$instanceName] Fehler: $($_.Exception.Message)"
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'

					$allResults.Add([PSCustomObject]@{
						ComputerName    = $computer
						InstanceName    = $instanceName
						ServiceName     = $svc.Name
						ServiceAccount  = $svc.StartName
						AccountType     = 'Error'
						SpnAccount      = $null
						SqlPort         = $null
						CountOk         = 0
						CountMissing    = 0
						CountUnexpected = 0
						Status          = 'Error'
						Message         = $errMsg
						DetailRows      = $detailRows
						TxtFile         = $null
						CsvFile         = $null
					})

					if ($EnableException) { throw }
					if (-not $ContinueOnError) { throw $_ }
				}
			} # foreach $svc
		} # foreach $computer
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Instanz(en) verarbeitet." `
						  -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
