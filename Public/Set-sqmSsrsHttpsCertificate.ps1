function Set-sqmSsrsHttpsCertificate
{
	<#
	.SYNOPSIS
		Binds a Windows certificate to SSRS or Power BI Report Server for HTTPS access.

	.DESCRIPTION
		Eliminates browser security warnings by binding a valid certificate to the SSRS
		or Power BI Report Server (PBIRS) HTTPS endpoint via the WMI configuration interface.

		The function performs the following steps:
		1. Discovers the SSRS/PBIRS WMI namespace dynamically under
		   root\Microsoft\SqlServer\ReportServer\{Instance}\v{Version}\Admin
		2. Validates the certificate in Cert:\LocalMachine\My by thumbprint
		3. Lists and removes existing HTTPS URL reservations for all web applications
		4. Removes existing SSL certificate bindings
		5. Reserves HTTPS URLs for all applicable web applications
		6. Creates the SSL certificate binding
		7. Optionally sets SecureConnectionLevel to require HTTPS
		8. Calls ApplyChanges() to finalize

		Supported application names (auto-detected by version):
		- ReportServerWebService  (always present)
		- ReportManager           (SSRS 2016 and earlier, v13-)
		- ReportServerWebApp      (SSRS 2017+ / PBIRS, v14+)

		Prerequisites: Local administrator rights on the target computer.
		For remote execution, WinRM must be available.
		The certificate must already be present in the LocalMachine\My store on the target.
		The SSRS service may need to be restarted after binding.

	.PARAMETER ComputerName
		Target computer name or IP address. Default: localhost ($env:COMPUTERNAME).

	.PARAMETER Thumbprint
		Mandatory. Certificate thumbprint (40 hex characters) from the LocalMachine\My store.
		Spaces are automatically removed from the thumbprint string.

	.PARAMETER Port
		HTTPS port to bind. Default: 443.

	.PARAMETER InstanceName
		SSRS WMI instance name (e.g. "RS_SSRS", "RS_PBIRS").
		Auto-detected when only one instance is found under the WMI namespace.
		Required when multiple instances exist on the same server.

	.PARAMETER IPAddress
		IP address for the SSL binding. Default: "0.0.0.0" (all interfaces).

	.PARAMETER RequireSSL
		When specified, sets SecureConnectionLevel = 1 (HTTPS required).
		Default: SecureConnectionLevel = 0 (HTTPS optional, HTTP still allowed).

	.PARAMETER Credential
		PSCredential for the WinRM session (remote operation only).

	.PARAMETER WhatIf
		Shows what would happen without making any changes.

	.PARAMETER Confirm
		Prompts for confirmation before applying changes.

	.EXAMPLE
		Set-sqmSsrsHttpsCertificate -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"

		Binds the specified certificate to SSRS on the local machine on port 443.
		The SSRS instance is auto-detected.

	.EXAMPLE
		Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER01" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Port 8443 -InstanceName "RS_PBIRS" -RequireSSL

		Binds the certificate to Power BI Report Server on REPSERVER01, port 8443,
		and requires HTTPS (SecureConnectionLevel = 1).

	.EXAMPLE
		$cred = Get-Credential
		Set-sqmSsrsHttpsCertificate -ComputerName "REPSERVER02" -Thumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" -Credential $cred -WhatIf

		Shows what changes would be made on REPSERVER02 without applying them.

	.NOTES
		Author      : sqmSQLTool
		Prerequisites: Admin rights on target, WinRM for remote, certificate in LocalMachine\My store.
		The SSRS Windows service may need a restart after the binding is applied.
		WMI namespace: root\Microsoft\SqlServer\ReportServer\{Instance}\v{Version}\Admin
	#>
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,

		[Parameter(Mandatory = $true)]
		[string]$Thumbprint,

		[Parameter(Mandatory = $false)]
		[int]$Port = 443,

		[Parameter(Mandatory = $false)]
		[string]$InstanceName,

		[Parameter(Mandatory = $false)]
		[string]$IPAddress = '0.0.0.0',

		[Parameter(Mandatory = $false)]
		[switch]$RequireSSL,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starting $functionName on '$ComputerName'" -FunctionName $functionName -Level "INFO"

		# Normalize thumbprint - remove spaces and convert to uppercase
		$Thumbprint = $Thumbprint -replace '\s', '' | ForEach-Object { $_.ToUpper() }

		$result = [PSCustomObject]@{
			ComputerName      = $ComputerName
			InstanceName      = $InstanceName
			Thumbprint        = $Thumbprint
			HttpsUrl          = $null
			Port              = $Port
			RequireSSL        = $RequireSSL.IsPresent
			PreviousBindings  = $null
			Result            = 'Unknown'
		}
	}

	process
	{
		$cimSession = $null
		try
		{
			# --- CIM session setup ---
			$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
			$cimBase = @{ ErrorAction = 'Stop' }

			if ($isLocal)
			{
				Invoke-sqmLogging -Message "Local execution - WinRM not required." -FunctionName $functionName -Level "INFO"
			}
			else
			{
				Invoke-sqmLogging -Message "Remote execution: connecting to '$ComputerName' via WsMan..." -FunctionName $functionName -Level "INFO"
				$sessionOpts = New-CimSessionOption -Protocol Wsman
				$cimParams = @{
					ComputerName  = $ComputerName
					SessionOption = $sessionOpts
					ErrorAction   = 'Stop'
				}
				if ($Credential) { $cimParams['Credential'] = $Credential }
				$cimSession = New-CimSession @cimParams
				$cimBase['CimSession'] = $cimSession
				Invoke-sqmLogging -Message "CIM session established to '$ComputerName'." -FunctionName $functionName -Level "INFO"
			}

			# --- Discover SSRS WMI namespace ---
			$rsBaseNamespace = 'root\Microsoft\SqlServer\ReportServer'

			$rsInstances = Get-CimInstance @cimBase -Namespace $rsBaseNamespace -ClassName '__NAMESPACE' -ErrorAction Stop
			if (-not $rsInstances)
			{
				throw "No SSRS/PBIRS instances found under WMI namespace '$rsBaseNamespace' on '$ComputerName'."
			}

			$instanceNames = @($rsInstances | Select-Object -ExpandProperty Name)

			if (-not $InstanceName)
			{
				if ($instanceNames.Count -gt 1)
				{
					$listStr = $instanceNames -join ', '
					throw "Multiple SSRS instances found: $listStr. Specify -InstanceName to select one."
				}
				$InstanceName = $instanceNames[0]
				$result.InstanceName = $InstanceName
				Invoke-sqmLogging -Message "Auto-detected SSRS instance: '$InstanceName'" -FunctionName $functionName -Level "INFO"
			}
			else
			{
				if ($instanceNames -notcontains $InstanceName)
				{
					$listStr = $instanceNames -join ', '
					throw "Instance '$InstanceName' not found. Available instances: $listStr"
				}
			}

			$instNamespace = "$rsBaseNamespace\$InstanceName"

			# Discover version namespace (e.g. v15)
			$versionNs = Get-CimInstance @cimBase -Namespace $instNamespace -ClassName '__NAMESPACE' -ErrorAction Stop |
				Where-Object { $_.Name -like 'v*' } |
				Sort-Object Name -Descending |
				Select-Object -First 1 -ExpandProperty Name

			if (-not $versionNs)
			{
				throw "No version namespace (v*) found under '$instNamespace' on '$ComputerName'."
			}

			$adminNamespace = "$instNamespace\$versionNs\Admin"
			Invoke-sqmLogging -Message "Using WMI namespace: $adminNamespace" -FunctionName $functionName -Level "INFO"

			# --- Get configuration instance ---
			$wmiConfig = Get-CimInstance @cimBase -Namespace $adminNamespace -ClassName 'MSReportServer_ConfigurationSetting' -ErrorAction Stop |
				Select-Object -First 1

			if (-not $wmiConfig)
			{
				throw "MSReportServer_ConfigurationSetting not found in namespace '$adminNamespace'."
			}

			$versionNumber = [int]($versionNs -replace 'v', '')
			Invoke-sqmLogging -Message "SSRS version: $versionNs (numeric: $versionNumber) | Instance: $($wmiConfig.InstanceName)" -FunctionName $functionName -Level "INFO"
			Write-Host "[$ComputerName] SSRS $versionNs | Instance: $($wmiConfig.InstanceName)" -ForegroundColor Cyan

			# Determine portal application name based on version
			$portalApp = if ($versionNumber -ge 14) { 'ReportServerWebApp' }
			else { 'ReportManager' }
			$webServiceApp = 'ReportServerWebService'
			$applications = @($webServiceApp, $portalApp)

			# --- Validate certificate ---
			Invoke-sqmLogging -Message "Validating certificate thumbprint '$Thumbprint' in LocalMachine\My on '$ComputerName'..." -FunctionName $functionName -Level "INFO"

			$certScript = {
				param($tp)
				$cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' |
					Where-Object { $_.Thumbprint.ToUpper() -eq $tp.ToUpper() } |
					Select-Object -First 1
				if (-not $cert) { return $null }
				[PSCustomObject]@{
					Subject    = $cert.Subject
					NotAfter   = $cert.NotAfter
					FriendlyName = $cert.FriendlyName
					Thumbprint = $cert.Thumbprint
				}
			}

			if ($isLocal)
			{
				$certInfo = & $certScript -tp $Thumbprint
			}
			else
			{
				$certInfo = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock $certScript -ArgumentList $Thumbprint -ErrorAction Stop
			}

			if (-not $certInfo)
			{
				throw "Certificate with thumbprint '$Thumbprint' not found in Cert:\LocalMachine\My on '$ComputerName'."
			}

			Invoke-sqmLogging -Message "Certificate found: '$($certInfo.Subject)' | Expires: $($certInfo.NotAfter)" -FunctionName $functionName -Level "INFO"
			Write-Host "  Certificate: $($certInfo.Subject) | Expires: $($certInfo.NotAfter)" -ForegroundColor Gray

			if ($certInfo.NotAfter -lt (Get-Date))
			{
				Invoke-sqmLogging -Message "WARNING: Certificate '$Thumbprint' expired on $($certInfo.NotAfter)!" -FunctionName $functionName -Level "WARNING"
				Write-Warning "Certificate expired on $($certInfo.NotAfter). Proceeding anyway."
			}

			# Helper: invoke WMI method and check HRESULT
			function _InvokeCimMethod
			{
				param(
					[string]$MethodName,
					[hashtable]$Arguments,
					[string]$Description
				)
				Invoke-sqmLogging -Message "WMI call: $MethodName - $Description" -FunctionName $functionName -Level "INFO"
				$r = Invoke-CimMethod @cimBase -Namespace $adminNamespace -ClassName 'MSReportServer_ConfigurationSetting' `
					-MethodName $MethodName -Arguments $Arguments -ErrorAction Stop
				if ($r.HRESULT -ne 0)
				{
					$hexCode = '0x' + $r.HRESULT.ToString('X8')
					throw "${MethodName} failed (HRESULT $hexCode): $($r.Error)"
				}
				return $r
			}

			# --- List existing SSL bindings ---
			Invoke-sqmLogging -Message "Listing current SSL certificate bindings..." -FunctionName $functionName -Level "INFO"
			$lcid = 1033
			try
			{
				$listResult = _InvokeCimMethod -MethodName 'ListSSLCertificateBindings' -Arguments @{ Lcid = $lcid } -Description "List current bindings"
				$result.PreviousBindings = $listResult
				if ($listResult.Application)
				{
					$bindingCount = @($listResult.Application).Count
					Invoke-sqmLogging -Message "Found $bindingCount existing SSL binding(s)." -FunctionName $functionName -Level "INFO"
					Write-Host "  Existing bindings: $bindingCount found." -ForegroundColor Gray
				}
				else
				{
					Invoke-sqmLogging -Message "No existing SSL bindings found." -FunctionName $functionName -Level "INFO"
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "Could not list SSL bindings (non-fatal): $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
			}

			if (-not $PSCmdlet.ShouldProcess($ComputerName, "Bind certificate '$Thumbprint' to SSRS HTTPS port $Port"))
			{
				$result.Result = 'WhatIf'
				return $result
			}

			# --- Remove existing HTTPS URL reservations ---
			Write-Host "  [1/5] Removing existing HTTPS URL reservations..." -ForegroundColor Gray
			foreach ($app in $applications)
			{
				$httpsUrl = "https://+:$Port"
				try
				{
					$null = _InvokeCimMethod -MethodName 'RemoveURL' -Arguments @{
						Application = $app
						UrlString   = $httpsUrl
						Lcid        = $lcid
					} -Description "RemoveURL $app $httpsUrl"
					Invoke-sqmLogging -Message "Removed HTTPS URL reservation for '$app': $httpsUrl" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					# Non-fatal: URL may not exist yet
					Invoke-sqmLogging -Message "RemoveURL for '$app' (non-fatal): $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}

			# --- Remove existing SSL certificate bindings ---
			Write-Host "  [2/5] Removing existing SSL certificate bindings..." -ForegroundColor Gray
			foreach ($app in $applications)
			{
				try
				{
					$null = _InvokeCimMethod -MethodName 'RemoveSSLCertificateBindings' -Arguments @{
						Application     = $app
						CertificateHash = $Thumbprint
						IPAddress       = $IPAddress
						Port            = $Port
						Lcid            = $lcid
					} -Description "RemoveSSLCertificateBindings $app"
					Invoke-sqmLogging -Message "Removed SSL binding for '$app' on $IPAddress`:$Port" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					# Non-fatal: binding may not exist yet
					Invoke-sqmLogging -Message "RemoveSSLCertificateBindings for '$app' (non-fatal): $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
				}
			}

			# --- Reserve HTTPS URLs ---
			Write-Host "  [3/5] Reserving HTTPS URLs..." -ForegroundColor Gray
			$httpsUrlReserve = "https://+:$Port"
			foreach ($app in $applications)
			{
				$null = _InvokeCimMethod -MethodName 'ReserveURL' -Arguments @{
					Application = $app
					UrlString   = $httpsUrlReserve
					Lcid        = $lcid
				} -Description "ReserveURL $app $httpsUrlReserve"
				Invoke-sqmLogging -Message "Reserved HTTPS URL for '$app': $httpsUrlReserve" -FunctionName $functionName -Level "INFO"
				Write-Host "    Reserved: $app -> $httpsUrlReserve" -ForegroundColor Gray
			}

			# --- Create SSL certificate binding ---
			Write-Host "  [4/5] Creating SSL certificate binding..." -ForegroundColor Gray
			foreach ($app in $applications)
			{
				$null = _InvokeCimMethod -MethodName 'CreateSSLCertificateBinding' -Arguments @{
					Application     = $app
					CertificateHash = $Thumbprint
					IPAddress       = $IPAddress
					Port            = $Port
					Lcid            = $lcid
				} -Description "CreateSSLCertificateBinding $app port $Port"
				Invoke-sqmLogging -Message "Created SSL certificate binding for '$app' on $IPAddress`:$Port with thumbprint '$Thumbprint'" -FunctionName $functionName -Level "INFO"
				Write-Host "    Bound: $app -> $IPAddress`:$Port" -ForegroundColor Gray
			}

			# --- Set SecureConnectionLevel ---
			Write-Host "  [5/5] Setting SecureConnectionLevel..." -ForegroundColor Gray
			$sslLevel = if ($RequireSSL) { 1 }
			else { 0 }
			$sslLevelDesc = if ($RequireSSL) { 'Required (1)' }
			else { 'Optional (0)' }
			$null = _InvokeCimMethod -MethodName 'SetSecureConnectionLevel' -Arguments @{
				Level = $sslLevel
			} -Description "SetSecureConnectionLevel $sslLevel"
			Invoke-sqmLogging -Message "SecureConnectionLevel set to $sslLevel ($sslLevelDesc)" -FunctionName $functionName -Level "INFO"

			# --- Apply changes ---
			Invoke-sqmLogging -Message "Calling ApplyChanges() to finalize configuration..." -FunctionName $functionName -Level "INFO"
			$null = _InvokeCimMethod -MethodName 'ApplyChanges' -Arguments @{} -Description "Finalize configuration"
			Invoke-sqmLogging -Message "ApplyChanges() completed successfully." -FunctionName $functionName -Level "INFO"

			# --- Build result ---
			$httpsUrlFinal = "https://$ComputerName`:$Port"
			$result.HttpsUrl = $httpsUrlFinal
			$result.Result = 'Success'

			Write-Host ""
			Write-Host "[$ComputerName] SSRS HTTPS certificate binding: Success" -ForegroundColor Green
			Write-Host "  HTTPS URL    : $httpsUrlFinal" -ForegroundColor Cyan
			Write-Host "  Thumbprint   : $Thumbprint" -ForegroundColor Cyan
			Write-Host "  Applications : $($applications -join ', ')" -ForegroundColor Gray
			Write-Host "  SSL Level    : $sslLevelDesc" -ForegroundColor Gray
			Write-Host "  Note: Restart the SSRS Windows service to activate the new binding." -ForegroundColor Yellow

			Invoke-sqmLogging -Message "HTTPS certificate binding completed. URL: $httpsUrlFinal | Thumbprint: $Thumbprint | RequireSSL: $($RequireSSL.IsPresent)" -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$errMsg = "Error in $functionName on '$ComputerName': $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			$result.Result = 'Failed'
			Write-Error $errMsg
		}
		finally
		{
			if ($cimSession)
			{
				Remove-CimSession $cimSession -ErrorAction SilentlyContinue
			}
		}

		return $result
	}

	end {}
}
