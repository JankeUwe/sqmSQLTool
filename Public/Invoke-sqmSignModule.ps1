<#
.SYNOPSIS
    Signs all PowerShell script files in a module directory using Set-AuthenticodeSignature.

.DESCRIPTION
    Signs .ps1, .psm1, and .psd1 files (configurable) under a module root directory recursively.
    Works with any code signing certificate: commercial OV cert, self-signed cert, or a
    SignPath-exported PFX file. Designed to be run before each GitHub release.

    Certificate resolution order:
      1. PFX file path  (-CertificatePath)
      2. Thumbprint      (-CertificateThumbprint) - searched in LocalMachine\My, then CurrentUser\My
      3. Auto-detect     - first valid, non-expired code signing cert in both stores

    Each file is checked for an existing signature before signing. Files with a valid
    signature are skipped unless -Force is specified. Files with an invalid or expired
    signature are always re-signed.

    On timestamp server failure the function automatically retries with a fallback TSA.

    Results are returned as a list of PSCustomObjects and copied to the clipboard.

.PARAMETER ModulePath
    Path to the module root directory. All matching files are signed recursively.
    If omitted, the parent of $PSScriptRoot is used (auto-detect for module-internal calls).

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate in Cert:\LocalMachine\My or Cert:\CurrentUser\My.
    If omitted and -CertificatePath is also omitted, the function auto-detects a valid
    code signing certificate from both stores.

.PARAMETER CertificatePath
    Path to a .pfx file. Takes precedence over -CertificateThumbprint.

.PARAMETER CertificatePassword
    SecureString password for the PFX file specified in -CertificatePath.

.PARAMETER TimestampServer
    URL of the timestamp authority (TSA). Default: http://timestamp.digicert.com.
    On failure the function retries with http://timestamp.sectigo.com as fallback.

.PARAMETER IncludeExtensions
    File extensions to sign. Default: @('.ps1', '.psm1', '.psd1').

.PARAMETER Force
    Re-signs files that already carry a valid signature. Without -Force those files
    are skipped.

.EXAMPLE
    # 1. Sign with a specific certificate from the store
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" `
        -CertificateThumbprint "AB12CD34EF56..."

.EXAMPLE
    # 2. Sign with a PFX file
    $pwd = ConvertTo-SecureString "secret" -AsPlainText -Force
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" `
        -CertificatePath "C:\Certs\CodeSign.pfx" -CertificatePassword $pwd

.EXAMPLE
    # 3. Auto-detect certificate (no parameters needed if cert is in store)
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule"

.EXAMPLE
    # 4. WhatIf dry run - show which files would be signed
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" -WhatIf

.EXAMPLE
    # 5. Force re-sign all files, even those already signed
    Invoke-sqmSignModule -ModulePath "C:\Dev\MyModule" -Force

.NOTES
    Requires: Invoke-sqmLogging
    Compatible with PowerShell 5.1 and later.
    Uses SHA-256 as the hash algorithm for the Authenticode signature.
    The code signing OID is 1.3.6.1.5.5.7.3.3.
#>
function Invoke-sqmSignModule
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$ModulePath,

		[Parameter(Mandatory = $false)]
		[string]$CertificateThumbprint,

		[Parameter(Mandatory = $false)]
		[string]$CertificatePath,

		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$CertificatePassword,

		[Parameter(Mandatory = $false)]
		[string]$TimestampServer = 'http://timestamp.digicert.com',

		[Parameter(Mandatory = $false)]
		[string[]]$IncludeExtensions = @('.ps1', '.psm1', '.psd1'),

		[Parameter(Mandatory = $false)]
		[switch]$Force
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$fallbackTsa  = 'http://timestamp.sectigo.com'
		$codeSignOid  = '1.3.6.1.5.5.7.3.3'
		$results      = [System.Collections.Generic.List[PSCustomObject]]::new()

		Invoke-sqmLogging -Message "Starting $functionName" -FunctionName $functionName -Level "INFO"

		# ------------------------------------------------------------------
		# Resolve ModulePath
		# ------------------------------------------------------------------
		if (-not $ModulePath)
		{
			$ModulePath = Split-Path -Parent $PSScriptRoot
			Invoke-sqmLogging -Message "ModulePath auto-detected: $ModulePath" -FunctionName $functionName -Level "INFO"
		}

		if (-not (Test-Path -LiteralPath $ModulePath -PathType Container))
		{
			$msg = "ModulePath not found or is not a directory: $ModulePath"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		# ------------------------------------------------------------------
		# Resolve certificate
		# ------------------------------------------------------------------
		$cert = $null

		if ($CertificatePath)
		{
			# Load from PFX file
			if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf))
			{
				$msg = "CertificatePath not found: $CertificatePath"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}

			try
			{
				if ($CertificatePassword)
				{
					$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
						$CertificatePath, $CertificatePassword)
				}
				else
				{
					$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
						$CertificatePath)
				}
				Invoke-sqmLogging -Message "Certificate loaded from PFX: $CertificatePath" -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$msg = "Failed to load PFX certificate from '$CertificatePath': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}
		}
		elseif ($CertificateThumbprint)
		{
			# Search by thumbprint in both stores
			$thumbprintClean = $CertificateThumbprint -replace '\s', ''
			$cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
				Where-Object { $_.Thumbprint -ieq $thumbprintClean } |
				Select-Object -First 1

			if (-not $cert)
			{
				$cert = Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
					Where-Object { $_.Thumbprint -ieq $thumbprintClean } |
					Select-Object -First 1
			}

			if (-not $cert)
			{
				$msg = "Certificate with thumbprint '$CertificateThumbprint' not found in LocalMachine\My or CurrentUser\My."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}

			Invoke-sqmLogging -Message "Certificate found by thumbprint in store." -FunctionName $functionName -Level "INFO"
		}
		else
		{
			# Auto-detect: first valid, non-expired code signing cert
			$now = Get-Date
			$allCerts = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue) +
				@(Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue)

			$cert = $allCerts | Where-Object {
				$_.NotAfter -gt $now -and
				$_.HasPrivateKey -and
				($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq $codeSignOid })
			} | Select-Object -First 1

			if (-not $cert)
			{
				$msg = "No valid code signing certificate found in LocalMachine\My or CurrentUser\My. Provide -CertificateThumbprint or -CertificatePath."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}

			Invoke-sqmLogging -Message "Code signing certificate auto-detected: $($cert.Subject)" -FunctionName $functionName -Level "INFO"
		}

		# ------------------------------------------------------------------
		# Validate certificate
		# ------------------------------------------------------------------
		$hasCodeSignEku = $cert.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq $codeSignOid }
		if (-not $hasCodeSignEku)
		{
			$msg = "Certificate '$($cert.Subject)' does not have the Code Signing EKU (OID $codeSignOid)."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		if ($cert.NotAfter -lt (Get-Date))
		{
			$msg = "Certificate '$($cert.Subject)' expired on $($cert.NotAfter.ToString('yyyy-MM-dd'))."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		if (-not $cert.HasPrivateKey)
		{
			$msg = "Certificate '$($cert.Subject)' does not have a private key - cannot sign."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		Invoke-sqmLogging -Message "Certificate validated - Subject: $($cert.Subject) | Thumbprint: $($cert.Thumbprint) | Expiry: $($cert.NotAfter.ToString('yyyy-MM-dd'))" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		# Collect files
		$files = Get-ChildItem -LiteralPath $ModulePath -Recurse -File -ErrorAction Stop |
			Where-Object { $IncludeExtensions -contains $_.Extension.ToLower() }

		if (-not $files)
		{
			Invoke-sqmLogging -Message "No files matching extensions ($($IncludeExtensions -join ', ')) found under $ModulePath." -FunctionName $functionName -Level "WARNING"
			return
		}

		Invoke-sqmLogging -Message "Found $($files.Count) file(s) to process under $ModulePath." -FunctionName $functionName -Level "INFO"

		foreach ($file in $files)
		{
			$filePath     = $file.FullName
			$fileName     = $file.Name
			$prevStatus   = 'Unknown'
			$errorMessage = $null
			$usedTsa      = $TimestampServer
			$fileStatus   = 'Unknown'

			# Check existing signature
			try
			{
				$sigInfo   = Get-AuthenticodeSignature -LiteralPath $filePath -ErrorAction Stop
				$prevStatus = $sigInfo.Status.ToString()
			}
			catch
			{
				$prevStatus = 'CheckFailed'
			}

			# Skip if already valid and -Force not set
			if ($prevStatus -eq 'Valid' -and -not $Force)
			{
				Invoke-sqmLogging -Message "Skipping '$fileName' - already has a valid signature. Use -Force to re-sign." -FunctionName $functionName -Level "INFO"
				$results.Add([PSCustomObject]@{
					FilePath        = $filePath
					FileName        = $fileName
					Status          = 'Skipped'
					PreviousStatus  = $prevStatus
					Thumbprint      = $cert.Thumbprint
					CertSubject     = $cert.Subject
					TimestampServer = $null
					ErrorMessage    = $null
				})
				continue
			}

			# WhatIf
			if (-not $PSCmdlet.ShouldProcess($filePath, "Sign with certificate '$($cert.Subject)'"))
			{
				$results.Add([PSCustomObject]@{
					FilePath        = $filePath
					FileName        = $fileName
					Status          = 'WhatIf'
					PreviousStatus  = $prevStatus
					Thumbprint      = $cert.Thumbprint
					CertSubject     = $cert.Subject
					TimestampServer = $TimestampServer
					ErrorMessage    = $null
				})
				continue
			}

			# Sign - try primary TSA, then fallback
			$signed = $false
			foreach ($tsa in @($TimestampServer, $fallbackTsa))
			{
				try
				{
					$signResult = Set-AuthenticodeSignature `
						-FilePath $filePath `
						-Certificate $cert `
						-TimestampServer $tsa `
						-HashAlgorithm SHA256 `
						-ErrorAction Stop

					if ($signResult.Status -eq 'Valid')
					{
						$fileStatus = 'Signed'
						$usedTsa    = $tsa
						$signed     = $true
						Invoke-sqmLogging -Message "Signed '$fileName' using TSA: $tsa" -FunctionName $functionName -Level "INFO"
						break
					}
					else
					{
						$errorMessage = "Set-AuthenticodeSignature returned status '$($signResult.Status)' using TSA: $tsa"
						Invoke-sqmLogging -Message "$fileName - $errorMessage" -FunctionName $functionName -Level "WARNING"
					}
				}
				catch
				{
					$errorMessage = "TSA '$tsa' failed: $($_.Exception.Message)"
					Invoke-sqmLogging -Message "$fileName - $errorMessage" -FunctionName $functionName -Level "WARNING"
				}
			}

			if (-not $signed)
			{
				$fileStatus = 'Failed'
				Invoke-sqmLogging -Message "FAILED to sign '$fileName'. Last error: $errorMessage" -FunctionName $functionName -Level "ERROR"
			}

			$results.Add([PSCustomObject]@{
				FilePath        = $filePath
				FileName        = $fileName
				Status          = $fileStatus
				PreviousStatus  = $prevStatus
				Thumbprint      = $cert.Thumbprint
				CertSubject     = $cert.Subject
				TimestampServer = $usedTsa
				ErrorMessage    = $errorMessage
			})
		}
	}

	end
	{
		$signedCount  = @($results | Where-Object { $_.Status -eq 'Signed' }).Count
		$skippedCount = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count
		$failedCount  = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
		$whatIfCount  = @($results | Where-Object { $_.Status -eq 'WhatIf' }).Count

		$summaryMsg = "$functionName complete - Signed: $signedCount | Skipped: $skippedCount | Failed: $failedCount | WhatIf: $whatIfCount"
		Invoke-sqmLogging -Message $summaryMsg -FunctionName $functionName -Level "INFO"
		Write-Verbose $summaryMsg

		if ($failedCount -gt 0)
		{
			Write-Warning "${functionName}: $failedCount file(s) could not be signed. Check ErrorMessage in results."
		}

		# Copy summary to clipboard
		if ($results.Count -gt 0)
		{
			try
			{
				$clipText = $results |
					Select-Object FileName, Status, PreviousStatus, TimestampServer, ErrorMessage |
					Format-Table -AutoSize |
					Out-String
				Set-Clipboard -Value $clipText.Trim()
				Invoke-sqmLogging -Message "Results ($($results.Count) file(s)) copied to clipboard." -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				Invoke-sqmLogging -Message "Could not write to clipboard: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
			}
		}

		return $results
	}
}
