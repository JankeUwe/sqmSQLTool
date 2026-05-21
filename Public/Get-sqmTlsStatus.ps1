<#
.SYNOPSIS
    Audits TLS/SSL configuration and certificate status for all SQL Server instances on one or more computers.

.DESCRIPTION
    Get-sqmTlsStatus connects to each target computer (locally or via Invoke-Command for remotes),
    reads the SQL Server instance list from the registry, and for each instance checks:

    - The TLS certificate thumbprint bound in SuperSocketNetLib (empty = auto-generated self-signed)
    - Whether ForceEncryption is enabled (0 = Warning, 1 = required)
    - Certificate details from the local machine certificate store (Cert:\LocalMachine\My):
        Expiry date, days remaining, Subject/CN, SAN entries, chain trust validation, private key presence
    - TLS protocol version state at the OS/SCHANNEL level:
        TLS 1.0, TLS 1.1, TLS 1.2, TLS 1.3 -- each reported as Enabled, Disabled, or NotConfigured

    Status is calculated per instance:
    - Critical : cert expired, cert not found in store, or cert chain not trusted
    - Warning  : cert expires within 60 days, ForceEncryption = 0, or TLS 1.0 / TLS 1.1 enabled
    - OK       : cert trusted, not expiring soon, ForceEncryption = 1, TLS 1.0 and TLS 1.1 disabled

    Results are written to a CSV and a TXT summary report in OutputPath, and returned as PSCustomObjects.

.PARAMETER ComputerName
    One or more computer names to audit. Default: current computer ($env:COMPUTERNAME).

.PARAMETER Credential
    Optional PSCredential used for Invoke-Command when auditing remote computers.

.PARAMETER OutputPath
    Directory where the CSV and TXT report files are saved.
    Default: $env:ProgramData\sqmSQLTool\Logs

.PARAMETER WarnDaysBeforeExpiry
    Number of days before certificate expiry that triggers a Warning status.
    Default: 60

.EXAMPLE
    Get-sqmTlsStatus

    Audits all SQL Server instances on the local computer and saves results to the default log folder.

.EXAMPLE
    Get-sqmTlsStatus -ComputerName "SQL01", "SQL02" -OutputPath "D:\Reports"

    Audits SQL01 and SQL02, saves reports to D:\Reports.

.EXAMPLE
    $cred = Get-Credential
    Get-sqmTlsStatus -ComputerName "SQL01" -Credential $cred | Where-Object Status -ne "OK"

    Audits SQL01 with explicit credentials and filters for non-OK results.

.NOTES
    Author:        sqmSQLTool
    Prerequisites: None (pure PowerShell, Registry, CertStore). PowerShell 5.1 compatible.
    Remote access: Uses Invoke-Command (WinRM) for remote computers.
    Default output path: $env:ProgramData\sqmSQLTool\Logs
#>
function Get-sqmTlsStatus
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$ComputerName = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = '$env:ProgramData\sqmSQLTool\Logs',

		[Parameter(Mandatory = $false)]
		[int]$WarnDaysBeforeExpiry = 60
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		# Resolve literal $env:... in OutputPath at runtime
		if ($OutputPath -like '*$env:*')
		{
			$OutputPath = $OutputPath -replace '\$env:ProgramData', $env:ProgramData
		}

		if (-not (Test-Path -Path $OutputPath))
		{
			New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
		}

		Invoke-sqmLogging -Message "Starting $functionName - ComputerName: $($ComputerName -join ', ') - OutputPath: $OutputPath" -FunctionName $functionName -Level "INFO"

		# Script block executed on each target (local or remote via Invoke-Command)
		$remoteCollectBlock = {
			param([string]$TargetComputer)

			$collected = [System.Collections.Generic.List[hashtable]]::new()

			# --- Read SQL Server instances from registry ---
			$instanceRegPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
			$instanceNames = @()
			try
			{
				$regKey = Get-Item -Path $instanceRegPath -ErrorAction Stop
				$instanceNames = $regKey.GetValueNames()
			}
			catch
			{
				# No SQL Server installed or registry not accessible
				return $collected
			}

			# --- Read SCHANNEL TLS protocol state (computer-wide) ---
			$tlsProtocols = @('TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3')
			$tlsState = @{}
			foreach ($proto in $tlsProtocols)
			{
				$clientPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\Client"
				$serverPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\Server"

				# Server subkey is authoritative for SQL Server; fall back to Client if absent
				$enabled = $null
				$disabledByDefault = $null

				foreach ($subPath in @($serverPath, $clientPath))
				{
					if (Test-Path -Path $subPath)
					{
						try
						{
							$subKey = Get-Item -Path $subPath -ErrorAction Stop
							$eVal = $subKey.GetValue('Enabled', $null)
							$dVal = $subKey.GetValue('DisabledByDefault', $null)
							if ($null -ne $eVal)
							{
								$enabled = [int]$eVal
								$disabledByDefault = if ($null -ne $dVal) { [int]$dVal } else { $null }
								break
							}
						}
						catch { }
					}
				}

				if ($null -eq $enabled)
				{
					$tlsState[$proto] = 'NotConfigured'
				}
				elseif ($enabled -eq 1)
				{
					$tlsState[$proto] = 'Enabled'
				}
				else
				{
					$tlsState[$proto] = 'Disabled'
				}
			}

			# --- Per-instance data ---
			foreach ($instName in $instanceNames)
			{
				# Resolve key name (e.g. MSSQL15.MSSQLSERVER)
				try
				{
					$keyName = (Get-ItemProperty -Path $instanceRegPath -Name $instName -ErrorAction Stop).$instName
				}
				catch
				{
					continue
				}

				$superSockPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$keyName\MSSQLServer\SuperSocketNetLib"

				$thumbprint = ''
				$forceEncryption = 0

				if (Test-Path -Path $superSockPath)
				{
					try
					{
						$ssnKey = Get-Item -Path $superSockPath -ErrorAction Stop
						$rawThumb = $ssnKey.GetValue('Certificate', '')
						$thumbprint = if ($rawThumb) { $rawThumb.ToString().ToUpper() } else { '' }
						$feVal = $ssnKey.GetValue('ForceEncryption', 0)
						$forceEncryption = [int]$feVal
					}
					catch { }
				}

				$entry = @{
					ComputerName     = $TargetComputer
					InstanceName     = $instName
					KeyName          = $keyName
					ForceEncryption  = $forceEncryption
					CertThumbprint   = $thumbprint
					TLS10            = $tlsState['TLS 1.0']
					TLS11            = $tlsState['TLS 1.1']
					TLS12            = $tlsState['TLS 1.2']
					TLS13            = $tlsState['TLS 1.3']
				}
				$collected.Add($entry)
			}

			return $collected
		}
	}

	process
	{
		foreach ($computer in $ComputerName)
		{
			Invoke-sqmLogging -Message "[$computer] Starting TLS audit ..." -FunctionName $functionName -Level "INFO"

			# --- Collect registry data (local or remote) ---
			$rawData = $null
			$isLocal = ($computer -eq $env:COMPUTERNAME) -or ($computer -eq 'localhost') -or ($computer -eq '.')

			try
			{
				if ($isLocal)
				{
					$rawData = & $remoteCollectBlock -TargetComputer $computer
				}
				else
				{
					$invokeParams = @{
						ComputerName = $computer
						ScriptBlock  = $remoteCollectBlock
						ArgumentList = $computer
						ErrorAction  = 'Stop'
					}
					if ($Credential) { $invokeParams['Credential'] = $Credential }
					$rawData = Invoke-Command @invokeParams
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "[$computer] Failed to collect registry data: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
					ComputerName   = $computer
					InstanceName   = 'N/A'
					ForceEncryption = $null
					CertThumbprint = ''
					CertSubject    = ''
					CertExpiry     = $null
					CertDaysLeft   = $null
					CertTrusted    = $null
					CertInStore    = $null
					TLS10          = 'Unknown'
					TLS11          = 'Unknown'
					TLS12          = 'Unknown'
					TLS13          = 'Unknown'
					Status         = 'Critical'
					StatusDetail   = "Registry collection failed - $($_.Exception.Message)"
				})
				continue
			}

			if (-not $rawData -or $rawData.Count -eq 0)
			{
				Invoke-sqmLogging -Message "[$computer] No SQL Server instances found in registry." -FunctionName $functionName -Level "WARNING"
				continue
			}

			# --- Validate certificates locally (cert store on THIS machine or remote) ---
			foreach ($entry in $rawData)
			{
				$certSubject    = ''
				$certExpiry     = $null
				$certDaysLeft   = $null
				$certTrusted    = $null
				$certInStore    = $false
				$sanEntries     = ''
				$hasPrivateKey  = $null
				$statusList     = [System.Collections.Generic.List[string]]::new()

				$thumb = $entry['CertThumbprint']

				if ($thumb -ne '')
				{
					# Look up cert in LocalMachine\My on the target computer
					# For remote: run cert lookup via Invoke-Command
					$certLookupBlock = {
						param([string]$Thumbprint)
						$result = @{
							Found        = $false
							Subject      = ''
							Expiry       = $null
							SAN          = ''
							HasPrivKey   = $false
							ChainValid   = $false
							ChainStatus  = ''
						}
						$cert = Get-Item -Path "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction SilentlyContinue
						if ($cert)
						{
							$result['Found']      = $true
							$result['Subject']    = $cert.Subject
							$result['Expiry']     = $cert.NotAfter
							$result['HasPrivKey'] = $cert.HasPrivateKey

							# SAN
							$sanExt = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }
							if ($sanExt)
							{
								$result['SAN'] = $sanExt.Format($false)
							}

							# Chain validation
							$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
							$chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
							$chainBuilt = $chain.Build($cert)
							$result['ChainValid'] = $chainBuilt
							if (-not $chainBuilt)
							{
								$statusTexts = @($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() })
								$result['ChainStatus'] = $statusTexts -join '; '
							}
						}
						return $result
					}

					try
					{
						if ($isLocal)
						{
							$certInfo = & $certLookupBlock -Thumbprint $thumb
						}
						else
						{
							$certInvokeParams = @{
								ComputerName = $computer
								ScriptBlock  = $certLookupBlock
								ArgumentList = $thumb
								ErrorAction  = 'Stop'
							}
							if ($Credential) { $certInvokeParams['Credential'] = $Credential }
							$certInfo = Invoke-Command @certInvokeParams
						}

						if ($certInfo['Found'])
						{
							$certInStore    = $true
							$certSubject    = $certInfo['Subject']
							$certExpiry     = $certInfo['Expiry']
							$certDaysLeft   = [int](($certExpiry - (Get-Date)).TotalDays)
							$certTrusted    = $certInfo['ChainValid']
							$hasPrivateKey  = $certInfo['HasPrivKey']
							$sanEntries     = $certInfo['SAN']
						}
						else
						{
							$certInStore = $false
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$computer][$($entry['InstanceName'])] Certificate lookup failed: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
				}

				# --- Determine status ---
				$overallStatus = 'OK'

				# Critical conditions
				if ($thumb -ne '' -and -not $certInStore)
				{
					$statusList.Add('Cert not found in LocalMachine\My')
					$overallStatus = 'Critical'
				}
				if ($certTrusted -eq $false)
				{
					$statusList.Add('Cert chain not trusted')
					$overallStatus = 'Critical'
				}
				if ($null -ne $certDaysLeft -and $certDaysLeft -lt 0)
				{
					$statusList.Add("Cert expired $([Math]::Abs($certDaysLeft)) days ago")
					$overallStatus = 'Critical'
				}

				# Warning conditions (only downgrade to Warning if not already Critical)
				if ($overallStatus -ne 'Critical')
				{
					if ($null -ne $certDaysLeft -and $certDaysLeft -ge 0 -and $certDaysLeft -lt $WarnDaysBeforeExpiry)
					{
						$statusList.Add("Cert expires in $certDaysLeft days")
						$overallStatus = 'Warning'
					}
					if ($entry['ForceEncryption'] -eq 0)
					{
						$statusList.Add('ForceEncryption = 0')
						$overallStatus = 'Warning'
					}
					if ($entry['TLS10'] -eq 'Enabled')
					{
						$statusList.Add('TLS 1.0 enabled')
						$overallStatus = 'Warning'
					}
					if ($entry['TLS11'] -eq 'Enabled')
					{
						$statusList.Add('TLS 1.1 enabled')
						$overallStatus = 'Warning'
					}
					if ($thumb -eq '')
					{
						$statusList.Add('No cert bound - auto-generated self-signed cert in use')
						if ($overallStatus -eq 'OK') { $overallStatus = 'Warning' }
					}
				}

				if ($statusList.Count -eq 0) { $statusList.Add('All checks passed') }

				$resultObj = [PSCustomObject]@{
					ComputerName    = $entry['ComputerName']
					InstanceName    = $entry['InstanceName']
					ForceEncryption = $entry['ForceEncryption']
					CertThumbprint  = $thumb
					CertSubject     = $certSubject
					CertExpiry      = $certExpiry
					CertDaysLeft    = $certDaysLeft
					CertTrusted     = $certTrusted
					CertInStore     = $certInStore
					SANEntries      = $sanEntries
					HasPrivateKey   = $hasPrivateKey
					TLS10           = $entry['TLS10']
					TLS11           = $entry['TLS11']
					TLS12           = $entry['TLS12']
					TLS13           = $entry['TLS13']
					Status          = $overallStatus
					StatusDetail    = $statusList -join ' | '
				}

				$allResults.Add($resultObj)

				Invoke-sqmLogging -Message "[$computer][$($entry['InstanceName'])] Status: $overallStatus - $($resultObj.StatusDetail)" -FunctionName $functionName -Level $(if ($overallStatus -eq 'OK') { 'INFO' } elseif ($overallStatus -eq 'Warning') { 'WARNING' } else { 'ERROR' })
			}
		}
	}

	end
	{
		if ($allResults.Count -eq 0)
		{
			Invoke-sqmLogging -Message "$functionName completed - no instances found." -FunctionName $functionName -Level "WARNING"
			return
		}

		$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
		$csvPath   = Join-Path -Path $OutputPath -ChildPath "TlsStatus_$timestamp.csv"
		$txtPath   = Join-Path -Path $OutputPath -ChildPath "TlsStatus_$timestamp.txt"

		# --- CSV export ---
		try
		{
			$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
			Invoke-sqmLogging -Message "CSV saved: $csvPath" -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			Invoke-sqmLogging -Message "Failed to write CSV: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
		}

		# --- TXT report ---
		try
		{
			$lines = [System.Collections.Generic.List[string]]::new()
			$lines.Add("TLS / SSL Status Report")
			$lines.Add("Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
			$lines.Add("Computers : $($ComputerName -join ', ')")
			$lines.Add(('-' * 80))
			$lines.Add('')

			$criticalCount = ($allResults | Where-Object { $_.Status -eq 'Critical' }).Count
			$warningCount  = ($allResults | Where-Object { $_.Status -eq 'Warning'  }).Count
			$okCount       = ($allResults | Where-Object { $_.Status -eq 'OK'       }).Count

			$lines.Add("Summary  :  OK=$okCount  Warning=$warningCount  Critical=$criticalCount")
			$lines.Add('')

			foreach ($r in $allResults)
			{
				$lines.Add("[[$($r.Status)]] $($r.ComputerName) \ $($r.InstanceName)")
				$lines.Add("  ForceEncryption : $($r.ForceEncryption)")
				$lines.Add("  CertThumbprint  : $(if ($r.CertThumbprint) { $r.CertThumbprint } else { '(none - self-signed)' })")
				$lines.Add("  CertSubject     : $($r.CertSubject)")
				$lines.Add("  CertExpiry      : $(if ($r.CertExpiry) { $r.CertExpiry.ToString('yyyy-MM-dd') + ' (' + $r.CertDaysLeft + ' days)' } else { 'N/A' })")
				$lines.Add("  CertTrusted     : $($r.CertTrusted)")
				$lines.Add("  CertInStore     : $($r.CertInStore)")
				$lines.Add("  HasPrivateKey   : $($r.HasPrivateKey)")
				$lines.Add("  SAN Entries     : $($r.SANEntries)")
				$lines.Add("  TLS 1.0         : $($r.TLS10)")
				$lines.Add("  TLS 1.1         : $($r.TLS11)")
				$lines.Add("  TLS 1.2         : $($r.TLS12)")
				$lines.Add("  TLS 1.3         : $($r.TLS13)")
				$lines.Add("  Detail          : $($r.StatusDetail)")
				$lines.Add('')
			}

			$lines | Out-File -FilePath $txtPath -Encoding UTF8
			Invoke-sqmLogging -Message "TXT report saved: $txtPath" -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			Invoke-sqmLogging -Message "Failed to write TXT report: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
		}

		Invoke-sqmLogging -Message "$functionName completed. Total instances audited: $($allResults.Count). Critical=$criticalCount Warning=$warningCount OK=$okCount" -FunctionName $functionName -Level "INFO"

		return $allResults
	}
}
