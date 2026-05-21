<#
.SYNOPSIS
    Binds a Windows certificate from the Machine store to SQL Server as the TLS certificate.

.DESCRIPTION
    Replaces the default self-signed auto-generated SQL Server TLS certificate with a
    proper certificate from the LocalMachine\My store. This eliminates SSL/TLS connection
    warnings in client applications and satisfies security/compliance requirements.

    Process:
      1. Resolve the SQL Server instance registry key name from the Instance Names registry
      2. Validate the certificate: find by thumbprint, check expiry, verify private key
      3. Determine SQL Server service name (MSSQLSERVER or MSSQL$INSTANCENAME)
      4. Get SQL Server service account from WMI
      5. Grant READ permission on the certificate private key to the service account
         (supports both CSP keys in MachineKeys and CNG keys in Crypto\Keys)
      6. Write the thumbprint to the SuperSocketNetLib registry key
      7. Optionally enable Force Encryption in the same registry key
      8. Optionally restart the SQL Server service to apply the change

    Returns a PSCustomObject summarising the result. A service restart is always required
    for the new certificate to take effect - either via -Restart or manually.

.PARAMETER SqlInstance
    SQL Server instance name. For a default instance use the computer name or leave
    at default ($env:COMPUTERNAME). For a named instance use COMPUTERNAME\INSTANCENAME.

.PARAMETER Thumbprint
    Certificate thumbprint (hex string). Spaces are stripped automatically.
    Must match a certificate in Cert:\LocalMachine\My.

.PARAMETER ForceEncryption
    If specified, sets ForceEncryption = 1 in the SuperSocketNetLib registry key,
    requiring all connections to use TLS encryption.

.PARAMETER Restart
    If specified, restarts the SQL Server service automatically after the registry
    change. Without this switch the service must be restarted manually.

.PARAMETER WhatIf
    Shows what would be changed without making any modifications.

.PARAMETER Confirm
    Prompts for confirmation before making changes.

.EXAMPLE
    Set-sqmSqlTlsCertificate -SqlInstance "SQL01" -Thumbprint "A1B2C3D4E5F6..."

    Binds the specified certificate to the default instance on SQL01.
    Service restart must be performed manually.

.EXAMPLE
    Set-sqmSqlTlsCertificate -SqlInstance "SQL01\INST1" -Thumbprint "A1B2C3D4E5F6..." -ForceEncryption -Restart

    Binds the certificate to the named instance INST1, enables Force Encryption,
    and restarts the SQL Server service automatically.

.EXAMPLE
    Set-sqmSqlTlsCertificate -Thumbprint "A1 B2 C3 D4 E5 F6" -WhatIf

    Shows what would be done for the local default instance without making changes.
    Thumbprint spaces are stripped automatically.

.NOTES
    Author  : sqmSQLTool
    Requires: Administrator rights on the target machine.
              The certificate must already be installed in Cert:\LocalMachine\My.
              Run on the SQL Server host (not remotely).
    Version : 1.0
#>
function Set-sqmSqlTlsCertificate
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $true, Position = 1)]
		[string]$Thumbprint,

		[Parameter(Mandatory = $false)]
		[switch]$ForceEncryption,

		[Parameter(Mandatory = $false)]
		[switch]$Restart
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		Invoke-sqmLogging -Message ("Starting " + $functionName + " for instance: " + $SqlInstance) -FunctionName $functionName -Level "INFO"

		# Normalize thumbprint: strip spaces, lowercase
		$Thumbprint = ($Thumbprint -replace '\s', '').ToLower()
		Invoke-sqmLogging -Message ("Normalized thumbprint: " + $Thumbprint) -FunctionName $functionName -Level "INFO"

		# Parse instance name: separate computer and instance parts
		if ($SqlInstance -match '^([^\\]+)\\(.+)$')
		{
			$computerName  = $Matches[1]
			$instancePart  = $Matches[2].ToUpper()
		}
		else
		{
			$computerName  = $SqlInstance
			$instancePart  = 'MSSQLSERVER'   # default instance sentinel
		}

		# Verify we are running on the target host
		if ($computerName -ne $env:COMPUTERNAME -and $computerName -ne '.' -and $computerName -ne 'localhost')
		{
			$warnMsg = "SqlInstance computer name '$computerName' differs from local computer '$($env:COMPUTERNAME)'. " +
				"This function modifies the local registry and file system - ensure you are running on the correct host."
			Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
			Write-Warning $warnMsg
		}
	}

	process
	{
		# ------------------------------------------------------------------
		# 1. Resolve SQL Server registry key name
		# ------------------------------------------------------------------
		Invoke-sqmLogging -Message "Step 1: Resolving SQL Server registry key name" -FunctionName $functionName -Level "INFO"

		$instanceNamesPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
		if (-not (Test-Path $instanceNamesPath))
		{
			$errMsg = "Registry path not found: $instanceNamesPath - Is SQL Server installed?"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$instanceNamesKey  = Get-ItemProperty -Path $instanceNamesPath -ErrorAction Stop
		$registryKeyName   = $null

		if ($instancePart -eq 'MSSQLSERVER')
		{
			# Default instance uses the value 'MSSQLSERVER'
			if ($instanceNamesKey.PSObject.Properties.Name -contains 'MSSQLSERVER')
			{
				$registryKeyName = $instanceNamesKey.MSSQLSERVER
			}
		}
		else
		{
			if ($instanceNamesKey.PSObject.Properties.Name -contains $instancePart)
			{
				$registryKeyName = $instanceNamesKey.$instancePart
			}
		}

		if (-not $registryKeyName)
		{
			$errMsg = "SQL Server instance '$instancePart' not found in registry at $instanceNamesPath"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message ("Registry key name resolved: " + $registryKeyName) -FunctionName $functionName -Level "INFO"

		# ------------------------------------------------------------------
		# 2. Validate certificate
		# ------------------------------------------------------------------
		Invoke-sqmLogging -Message "Step 2: Validating certificate in LocalMachine\My" -FunctionName $functionName -Level "INFO"

		$cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' |
			Where-Object { $_.Thumbprint.ToLower() -eq $Thumbprint } |
			Select-Object -First 1

		if (-not $cert)
		{
			$errMsg = "Certificate with thumbprint '$Thumbprint' not found in Cert:\LocalMachine\My"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Check expiry
		if ($cert.NotAfter -lt (Get-Date))
		{
			$errMsg = "Certificate '$($cert.Subject)' (thumbprint: $Thumbprint) is EXPIRED (NotAfter: $($cert.NotAfter))"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}
		if ($cert.NotAfter -lt (Get-Date).AddDays(30))
		{
			$warnMsg = "Certificate '$($cert.Subject)' expires in less than 30 days: $($cert.NotAfter)"
			Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
			Write-Warning $warnMsg
		}

		# Check private key presence
		if (-not $cert.HasPrivateKey)
		{
			$errMsg = "Certificate '$($cert.Subject)' has no private key accessible in LocalMachine\My"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message ("Certificate validated: Subject='" + $cert.Subject + "', NotAfter=" + $cert.NotAfter) -FunctionName $functionName -Level "INFO"

		# ------------------------------------------------------------------
		# 3. Determine SQL Server service name
		# ------------------------------------------------------------------
		Invoke-sqmLogging -Message "Step 3: Determining SQL Server service name" -FunctionName $functionName -Level "INFO"

		if ($instancePart -eq 'MSSQLSERVER')
		{
			$serviceName = 'MSSQLSERVER'
		}
		else
		{
			$serviceName = 'MSSQL$' + $instancePart
		}

		Invoke-sqmLogging -Message ("SQL Server service name: " + $serviceName) -FunctionName $functionName -Level "INFO"

		# ------------------------------------------------------------------
		# 4. Get SQL Server service account
		# ------------------------------------------------------------------
		Invoke-sqmLogging -Message "Step 4: Retrieving SQL Server service account" -FunctionName $functionName -Level "INFO"

		$svcObject = Get-CimInstance -ClassName Win32_Service -Filter ("Name = '" + $serviceName + "'") -ErrorAction Stop

		if (-not $svcObject)
		{
			$errMsg = "SQL Server service '$serviceName' not found via Win32_Service"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$serviceAccount = $svcObject.StartName
		Invoke-sqmLogging -Message ("Service account: " + $serviceAccount) -FunctionName $functionName -Level "INFO"

		# ------------------------------------------------------------------
		# 5. Grant READ on private key to service account
		# ------------------------------------------------------------------
		Invoke-sqmLogging -Message "Step 5: Granting private key read permission to service account" -FunctionName $functionName -Level "INFO"

		$privateKeyGranted = $false
		$keyFilePath       = $null

		# Determine key type: CSP vs CNG
		$isCng = $false
		try
		{
			# RSACng / ECDsaCng indicate CNG
			$pkType = $cert.PrivateKey.GetType().Name
			if ($pkType -match 'Cng')
			{
				$isCng = $true
			}
		}
		catch
		{
			# PrivateKey property may throw if CNG - try alternate detection
			$isCng = $true
		}

		if ($isCng)
		{
			# CNG key: stored in ProgramData\Microsoft\Crypto\Keys\
			try
			{
				$cngKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
				if ($null -eq $cngKey)
				{
					$cngKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($cert)
				}
				if ($cngKey -and $cngKey.Key -and $cngKey.Key.UniqueName)
				{
					$keyFileName = $cngKey.Key.UniqueName
					$keyFilePath = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$keyFileName"
				}
			}
			catch
			{
				Invoke-sqmLogging -Message ("CNG key detection via extension method failed: " + $_.Exception.Message + " - trying fallback") -FunctionName $functionName -Level "WARNING"
			}

			# Fallback: search CNG keys folder
			if (-not $keyFilePath -or -not (Test-Path $keyFilePath))
			{
				$cngFolder = Join-Path $env:ProgramData "Microsoft\Crypto\Keys"
				$thumbUpper = $Thumbprint.ToUpper()
				# Try to find by certificate unique key container via certutil pattern
				# As a safe fallback just try to list and find the most recent key
				Invoke-sqmLogging -Message "CNG key file path could not be determined automatically. Manual permission grant may be required." -FunctionName $functionName -Level "WARNING"
				$keyFilePath = $null
			}
		}
		else
		{
			# CSP key: stored in ProgramData\Microsoft\Crypto\RSA\MachineKeys\
			try
			{
				$keyContainerName = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
				if ($keyContainerName)
				{
					$keyFilePath = Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$keyContainerName"
				}
			}
			catch
			{
				Invoke-sqmLogging -Message ("CSP key container name retrieval failed: " + $_.Exception.Message) -FunctionName $functionName -Level "WARNING"
			}
		}

		if ($keyFilePath -and (Test-Path $keyFilePath))
		{
			$grantAction = "Grant READ on private key file '$keyFilePath' to '$serviceAccount'"
			if ($PSCmdlet.ShouldProcess($keyFilePath, $grantAction))
			{
				try
				{
					# Use icacls to grant read access
					$icaclsArgs = @("`"$keyFilePath`"", '/grant', "`"${serviceAccount}:(R)`"")
					$icaclsResult = & icacls @icaclsArgs 2>&1
					if ($LASTEXITCODE -eq 0)
					{
						$privateKeyGranted = $true
						Invoke-sqmLogging -Message ("Private key permission granted to '$serviceAccount' on '$keyFilePath'") -FunctionName $functionName -Level "INFO"
					}
					else
					{
						$warnMsg = "icacls returned exit code $LASTEXITCODE for '$keyFilePath': $icaclsResult"
						Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
						Write-Warning $warnMsg

						# Fallback: use .NET ACL API
						$acl = Get-Acl -Path $keyFilePath
						$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
							$serviceAccount,
							[System.Security.AccessControl.FileSystemRights]::Read,
							[System.Security.AccessControl.AccessControlType]::Allow
						)
						$acl.AddAccessRule($accessRule)
						Set-Acl -Path $keyFilePath -AclObject $acl -ErrorAction Stop
						$privateKeyGranted = $true
						Invoke-sqmLogging -Message ("Private key permission granted via ACL API to '$serviceAccount' on '$keyFilePath'") -FunctionName $functionName -Level "INFO"
					}
				}
				catch
				{
					$warnMsg = "Failed to grant private key permission to '$serviceAccount': " + $_.Exception.Message
					Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
					Write-Warning $warnMsg
				}
			}
		}
		else
		{
			$warnMsg = "Private key file not found or path could not be determined. " +
				"Manual permission grant required: grant READ on the private key file to '$serviceAccount'."
			Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
			Write-Warning $warnMsg
		}

		# ------------------------------------------------------------------
		# 6. Read old thumbprint, write new thumbprint to registry
		# ------------------------------------------------------------------
		Invoke-sqmLogging -Message "Step 6: Writing certificate thumbprint to registry" -FunctionName $functionName -Level "INFO"

		$superSocketPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$registryKeyName\MSSQLServer\SuperSocketNetLib"

		if (-not (Test-Path $superSocketPath))
		{
			$errMsg = "Registry path not found: $superSocketPath"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$superSocketProps = Get-ItemProperty -Path $superSocketPath -ErrorAction Stop
		$oldThumbprint    = $superSocketProps.Certificate

		$writeAction = "Set Certificate thumbprint in registry '$superSocketPath'"
		if ($PSCmdlet.ShouldProcess($superSocketPath, $writeAction))
		{
			Set-ItemProperty -Path $superSocketPath -Name 'Certificate' -Value $Thumbprint -Type String -ErrorAction Stop
			Invoke-sqmLogging -Message ("Certificate thumbprint written to registry. Old: '$oldThumbprint', New: '$Thumbprint'") -FunctionName $functionName -Level "INFO"
		}

		# ------------------------------------------------------------------
		# 7. Optionally set Force Encryption
		# ------------------------------------------------------------------
		$forceEncryptionSet = $false
		if ($ForceEncryption)
		{
			Invoke-sqmLogging -Message "Step 7: Enabling Force Encryption in registry" -FunctionName $functionName -Level "INFO"
			$feAction = "Set ForceEncryption = 1 in registry '$superSocketPath'"
			if ($PSCmdlet.ShouldProcess($superSocketPath, $feAction))
			{
				Set-ItemProperty -Path $superSocketPath -Name 'ForceEncryption' -Value 1 -Type DWord -ErrorAction Stop
				$forceEncryptionSet = $true
				Invoke-sqmLogging -Message "ForceEncryption set to 1" -FunctionName $functionName -Level "INFO"
			}
		}
		else
		{
			Invoke-sqmLogging -Message "Step 7: Skipping Force Encryption (switch not specified)" -FunctionName $functionName -Level "INFO"
		}

		# ------------------------------------------------------------------
		# 8. Optionally restart SQL Server service
		# ------------------------------------------------------------------
		$restartDone = $false
		if ($Restart)
		{
			Invoke-sqmLogging -Message ("Step 8: Restarting SQL Server service '" + $serviceName + "'") -FunctionName $functionName -Level "INFO"
			$restartAction = "Restart SQL Server service '$serviceName'"
			if ($PSCmdlet.ShouldProcess($serviceName, $restartAction))
			{
				try
				{
					Restart-Service -Name $serviceName -Force -ErrorAction Stop
					$restartDone = $true
					Invoke-sqmLogging -Message ("Service '" + $serviceName + "' restarted successfully") -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = "Failed to restart service '$serviceName': " + $_.Exception.Message
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					Write-Warning $errMsg
				}
			}
		}
		else
		{
			Invoke-sqmLogging -Message "Step 8: Service restart skipped (-Restart not specified). Restart '$serviceName' manually to apply the new certificate." -FunctionName $functionName -Level "INFO"
			Write-Host ("ACTION REQUIRED: Restart the SQL Server service '$serviceName' to apply the new TLS certificate.") -ForegroundColor Yellow
		}

		# ------------------------------------------------------------------
		# 9. Build result object
		# ------------------------------------------------------------------
		$result = [PSCustomObject]@{
			InstanceName       = $SqlInstance
			OldThumbprint      = $oldThumbprint
			NewThumbprint      = $Thumbprint
			ForceEncryption    = $forceEncryptionSet
			PrivateKeyGranted  = $privateKeyGranted
			ServiceAccount     = $serviceAccount
			RestartRequired    = (-not $restartDone)
			RestartDone        = $restartDone
		}

		Invoke-sqmLogging -Message ("Completed. RestartDone=" + $restartDone + ", PrivateKeyGranted=" + $privateKeyGranted + ", ForceEncryption=" + $forceEncryptionSet) -FunctionName $functionName -Level "INFO"

		return $result
	}

	end
	{
		Invoke-sqmLogging -Message ($functionName + " finished") -FunctionName $functionName -Level "INFO"
	}
}
