<#
.SYNOPSIS
    Installs a certificate file into the Windows certificate store - locally or on
    multiple remote computers.

.DESCRIPTION
    Reads a certificate file (.cer, .crt, or .pfx) and installs it into the
    specified Windows certificate store (LocalMachine) on one or more computers.

    Use cases:
      - Distribute a CA root certificate to the Trusted Root store on all nodes
      - Distribute a SQL Server self-signed certificate to admin workstations
      - Distribute AlwaysOn partner certificates (CER without private key) to replica machines

    Process:
      1. Read the certificate file and determine format (PFX vs CER/CRT) by extension
         and by attempting to parse the file
      2. For PFX files: load with X509KeyStorageFlags MachineKeySet + PersistKeySet
         and an optional password
      3. For CER/CRT files: load without password
      4. Open the target store (LocalMachine\<StoreName>) with ReadWrite access
      5. Check whether a certificate with the same thumbprint is already present -
         skip and log WARNING if so
      6. Add the certificate and close the store
      7. For remote computers: serialize the certificate as a byte array and pass it
         via Invoke-Command so the import runs on the target without needing file share access

    Returns one PSCustomObject per target computer with:
      ComputerName, StoreName, Thumbprint, Subject, Expiry, Action
    Action values: Installed / AlreadyPresent / Failed

.PARAMETER CertFile
    Full path to the certificate file (.cer, .crt, or .pfx).
    The file must exist and be readable.

.PARAMETER StoreName
    Target Windows certificate store under LocalMachine.
    Valid values: Root, My, TrustedPeople, CA
    Default: Root

.PARAMETER ComputerName
    One or more target computer names. Default: localhost only (the local machine).
    For remote targets PowerShell Remoting (WinRM) must be enabled and accessible.

.PARAMETER CertPassword
    Password for PFX files as SecureString. Ignored for CER/CRT files.

.EXAMPLE
    # Install a CA root certificate to the Trusted Root store on all AlwaysOn replica nodes
    $nodes = 'SQL-AG-01', 'SQL-AG-02', 'SQL-AG-03'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\CompanyRootCA.cer' `
        -StoreName Root -ComputerName $nodes

.EXAMPLE
    # Distribute a SQL Server self-signed certificate to an admin workstation
    Install-sqmCertificateToStore -CertFile 'C:\Certs\SQL-PROD-01.cer' `
        -StoreName TrustedPeople -ComputerName 'ADMINWS-01'

.EXAMPLE
    # Distribute an AlwaysOn partner certificate (CER without private key) to replica machines
    $replicas = 'SQL-AG-02', 'SQL-AG-03'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\SQL-AG-01_AG_CERT.cer' `
        -StoreName My -ComputerName $replicas

.EXAMPLE
    # Install a PFX certificate with password into the Personal store on the local machine
    $pwd = Read-Host -AsSecureString 'PFX password'
    Install-sqmCertificateToStore -CertFile 'C:\Certs\sql-ssl.pfx' `
        -StoreName My -CertPassword $pwd

.NOTES
    Author      : sqmSQLTool
    Prerequisites:
      - Administrator rights on each target computer
      - PowerShell Remoting (WinRM) enabled for remote targets
      - The certificate file must be accessible from the machine running this function;
        for remote targets the certificate bytes are transferred in-memory via Invoke-Command
        (no file share required on the target)
#>
function Install-sqmCertificateToStore
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string]$CertFile,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Root', 'My', 'TrustedPeople', 'CA')]
		[string]$StoreName = 'Root',

		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName = @('localhost'),

		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$CertPassword
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		Invoke-sqmLogging -Message "Starting $functionName - CertFile='$CertFile', StoreName=$StoreName, Targets=$($ComputerName -join ', ')" -FunctionName $functionName -Level "INFO"

		# ------------------------------------------------------------------
		# Determine certificate format by extension; fall back to try-parse
		# ------------------------------------------------------------------
		$certExt = [System.IO.Path]::GetExtension($CertFile).ToLower()
		$isPfx = $certExt -in @('.pfx', '.p12')

		if (-not $isPfx -and $certExt -notin @('.cer', '.crt'))
		{
			# Unknown extension - try to determine by attempting PFX parse
			try
			{
				$testBytes = [System.IO.File]::ReadAllBytes($CertFile)
				$testCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
					$testBytes, $CertPassword,
					[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
				)
				$isPfx = $true
				$testCert = $null
			}
			catch
			{
				$isPfx = $false
			}
		}

		# ------------------------------------------------------------------
		# Read certificate bytes and probe metadata from the local machine
		# ------------------------------------------------------------------
		$certBytes = [System.IO.File]::ReadAllBytes($CertFile)

		try
		{
			if ($isPfx)
			{
				$probeCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
					$certBytes, $CertPassword,
					([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
						[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)
				)
			}
			else
			{
				$probeCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
					$certBytes, $null,
					[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
				)
			}

			$certThumbprint = $probeCert.Thumbprint
			$certSubject    = $probeCert.Subject
			$certExpiry     = $probeCert.NotAfter
			$probeCert      = $null

			Invoke-sqmLogging -Message "Certificate parsed - Subject='$certSubject', Thumbprint=$certThumbprint, Expiry=$($certExpiry.ToString('yyyy-MM-dd'))" -FunctionName $functionName -Level "INFO"

			if ($certExpiry -lt (Get-Date))
			{
				Write-Warning "Certificate '$certSubject' has already expired ($($certExpiry.ToString('yyyy-MM-dd')))."
				Invoke-sqmLogging -Message "Certificate is expired: $certExpiry" -FunctionName $functionName -Level "WARNING"
			}
			elseif ($certExpiry -lt (Get-Date).AddDays(30))
			{
				Write-Warning "Certificate '$certSubject' expires in less than 30 days ($($certExpiry.ToString('yyyy-MM-dd')))."
				Invoke-sqmLogging -Message "Certificate expires within 30 days: $certExpiry" -FunctionName $functionName -Level "WARNING"
			}
		}
		catch
		{
			$errMsg = "Cannot read certificate file '$CertFile': $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Convert SecureString password to plain text for transport inside script block
		# (the plain text string is only constructed inside Invoke-Command scope)
		$plainPassword = $null
		if ($CertPassword)
		{
			$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertPassword)
			$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
			[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
		}

		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
	}

	process
	{
		# Script block that runs on each target (local or remote)
		$installScriptBlock = {
			param(
				[byte[]]$CertBytesArg,
				[string]$StoreNameArg,
				[string]$PlainPasswordArg,
				[bool]$IsPfxArg,
				[string]$ExpectedThumbprint
			)

			$result = [PSCustomObject]@{
				ComputerName = $env:COMPUTERNAME
				StoreName    = $StoreNameArg
				Thumbprint   = $ExpectedThumbprint
				Subject      = $null
				Expiry       = $null
				Action       = 'Failed'
				ErrorMessage = $null
			}

			try
			{
				# Load the certificate object
				if ($IsPfxArg)
				{
					$secPwd = $null
					if ($PlainPasswordArg)
					{
						$secPwd = ConvertTo-SecureString -String $PlainPasswordArg -AsPlainText -Force
					}
					$x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
						$CertBytesArg, $secPwd,
						([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
							[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)
					)
					$secPwd = $null
				}
				else
				{
					$x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
						$CertBytesArg, $null,
						[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
					)
				}

				$result.Subject = $x509.Subject
				$result.Expiry  = $x509.NotAfter
				$result.Thumbprint = $x509.Thumbprint

				# Open the target store
				$storeLocation = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
				$store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
					$StoreNameArg, $storeLocation
				)
				$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

				# Check whether the certificate is already present (by thumbprint)
				$existing = $store.Certificates | Where-Object { $_.Thumbprint -eq $x509.Thumbprint }

				if ($existing)
				{
					$store.Close()
					$result.Action = 'AlreadyPresent'
				}
				else
				{
					$store.Add($x509)
					$store.Close()
					$result.Action = 'Installed'
				}

				$x509 = $null
			}
			catch
			{
				$result.Action       = 'Failed'
				$result.ErrorMessage = $_.Exception.Message
			}

			return $result
		}

		foreach ($computer in $ComputerName)
		{
			$isLocal = ($computer -eq 'localhost') -or
				($computer -eq '.') -or
				($computer -ieq $env:COMPUTERNAME)

			if (-not $PSCmdlet.ShouldProcess($computer, "Install certificate (Thumbprint: $certThumbprint) into LocalMachine\$StoreName"))
			{
				$skipped = [PSCustomObject]@{
					ComputerName = $computer
					StoreName    = $StoreName
					Thumbprint   = $certThumbprint
					Subject      = $certSubject
					Expiry       = $certExpiry
					Action       = 'Skipped'
					ErrorMessage = $null
				}
				$results.Add($skipped)
				continue
			}

			Invoke-sqmLogging -Message "Processing target: $computer (isLocal=$isLocal)" -FunctionName $functionName -Level "INFO"

			try
			{
				if ($isLocal)
				{
					$res = & $installScriptBlock `
						-CertBytesArg $certBytes `
						-StoreNameArg $StoreName `
						-PlainPasswordArg $plainPassword `
						-IsPfxArg $isPfx `
						-ExpectedThumbprint $certThumbprint
				}
				else
				{
					$res = Invoke-Command -ComputerName $computer -ScriptBlock $installScriptBlock -ArgumentList `
						$certBytes, $StoreName, $plainPassword, $isPfx, $certThumbprint -ErrorAction Stop
				}

				# Ensure ComputerName reflects the intended target (remote sb sets $env:COMPUTERNAME)
				$res.ComputerName = $computer

				if ($res.Action -eq 'Installed')
				{
					Invoke-sqmLogging -Message "Certificate installed successfully on $computer - Store=LocalMachine\$StoreName, Thumbprint=$($res.Thumbprint)" -FunctionName $functionName -Level "INFO"
					Write-Host "[$computer] Certificate installed into LocalMachine\$StoreName." -ForegroundColor Green
				}
				elseif ($res.Action -eq 'AlreadyPresent')
				{
					Invoke-sqmLogging -Message "Certificate already present on $computer - Store=LocalMachine\$StoreName, Thumbprint=$($res.Thumbprint) - skipped." -FunctionName $functionName -Level "WARNING"
					Write-Warning "[$computer] Certificate with thumbprint $($res.Thumbprint) is already present in LocalMachine\$StoreName. Skipped."
				}
				else
				{
					Invoke-sqmLogging -Message "Certificate installation FAILED on $computer - $($res.ErrorMessage)" -FunctionName $functionName -Level "ERROR"
					Write-Error "[$computer] Installation failed: $($res.ErrorMessage)"
				}

				$results.Add($res)
			}
			catch
			{
				$errMsg = $_.Exception.Message
				Invoke-sqmLogging -Message "Failed to reach $computer or execute install: $errMsg" -FunctionName $functionName -Level "ERROR"
				Write-Error "[$computer] $errMsg"

				$failResult = [PSCustomObject]@{
					ComputerName = $computer
					StoreName    = $StoreName
					Thumbprint   = $certThumbprint
					Subject      = $certSubject
					Expiry       = $certExpiry
					Action       = 'Failed'
					ErrorMessage = $errMsg
				}
				$results.Add($failResult)
			}
		}
	}

	end
	{
		# Clear plain-text password from memory
		$plainPassword = $null

		$installed = ($results | Where-Object { $_.Action -eq 'Installed' }).Count
		$already   = ($results | Where-Object { $_.Action -eq 'AlreadyPresent' }).Count
		$failed    = ($results | Where-Object { $_.Action -eq 'Failed' }).Count

		Invoke-sqmLogging -Message "$functionName completed - Installed=$installed, AlreadyPresent=$already, Failed=$failed" -FunctionName $functionName -Level "INFO"

		return $results
	}
}
