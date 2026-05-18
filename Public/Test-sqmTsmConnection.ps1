function Test-sqmTsmConnection
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$DsmadmcPath,
		[Parameter(Mandatory = $false)]
		[string]$UserName,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$Password,
		[Parameter(Mandatory = $false)]
		[string]$ServerName,
		[Parameter(Mandatory = $false)]
		[string]$DsmOptPath,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		Invoke-sqmLogging -Message "Starte $functionName auf $ComputerName" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		$result = [PSCustomObject]@{
			Success	    = $false
			Message	    = $null
			DsmadmcPath = $null
			ServerName  = $null
			UserName    = $null
			Output	    = $null
			ErrorOutput = $null
		}
		
		try
		{
			# ---- 1. dsmadmc.exe Pfad ermitteln ----
			$dsmadmc = if ($DsmadmcPath) { $DsmadmcPath }
			else { _FindDsmadmcPath -ComputerName $ComputerName -Credential $Credential }
			if (-not $dsmadmc)
			{
				$msg = "dsmadmc nicht gefunden. Bitte TSM-Client installieren oder -DsmadmcPath angeben."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			$result.DsmadmcPath = $dsmadmc
			Invoke-sqmLogging -Message "Verwende dsmadmc: $dsmadmc" -FunctionName $functionName -Level "VERBOSE"
			
			# ---- 2. TSM-Konfiguration aus dsm.opt lesen (falls nicht alle Parameter angegeben) ----
			$effUserName = $UserName
			$effPassword = $Password
			$effServerName = $ServerName
			
			if (-not $effUserName -or -not $effPassword -or -not $effServerName)
			{
				$cfg = Get-sqmTsmConfiguration -ComputerName $ComputerName -DsmOptPath $DsmOptPath -Credential $Credential -IncludePasswordPlain -ErrorAction Stop
				if (-not $cfg.Success)
				{
					throw "TSM-Konfiguration konnte nicht gelesen werden: $($cfg.ErrorMessage)"
				}
				if (-not $effServerName) { $effServerName = $cfg.ServerName }
				if (-not $effUserName) { $effUserName = $cfg.UserName }
				if (-not $effPassword -and $cfg.Password) { $effPassword = $cfg.Password }
			}
			
			if (-not $effUserName)
			{
				$msg = "Kein TSM-Benutzername angegeben und kein USERID in dsm.opt gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			if (-not $effPassword)
			{
				$msg = "Kein TSM-Kennwort angegeben und kein PASSWORD in dsm.opt gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			if (-not $effServerName)
			{
				$msg = "Kein TSM-Server angegeben und kein TCPServeraddress in dsm.opt gefunden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw $msg }
				$result.Message = $msg
				return $result
			}
			$result.UserName = $effUserName
			$result.ServerName = $effServerName
			Invoke-sqmLogging -Message "TSM-Server: $effServerName, Benutzer: $effUserName" -FunctionName $functionName -Level "INFO"
			
			# ---- 3. Kennwort aus SecureString extrahieren ----
			$plainPwd = _SecureToPlain $effPassword
			
			# ---- 4. dsmadmc-Befehl aufbauen ----
			$cmdArgs = "-id=$effUserName -password=$plainPwd -se=$effServerName -dataonly=yes show version"
			Invoke-sqmLogging -Message "Fuehre dsmadmc aus: $dsmadmc $cmdArgs" -FunctionName $functionName -Level "VERBOSE"
			
			# ---- 5. Befehl ausfuehren ----
			$output = $null
			$errorOut = $null
			$exitCode = 0
			$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
			
			if ($PSCmdlet.ShouldProcess("TSM-Verbindung zu $effServerName mit Benutzer $effUserName", "Pruefen"))
			{
				if ($isLocal)
				{
					$psi = New-Object System.Diagnostics.ProcessStartInfo
					$psi.FileName = $dsmadmc
					$psi.Arguments = $cmdArgs
					$psi.UseShellExecute = $false
					$psi.RedirectStandardOutput = $true
					$psi.RedirectStandardError = $true
					$psi.CreateNoWindow = $true
					$p = [System.Diagnostics.Process]::Start($psi)
					$output = $p.StandardOutput.ReadToEnd()
					$errorOut = $p.StandardError.ReadToEnd()
					$p.WaitForExit()
					$exitCode = $p.ExitCode
				}
				else
				{
					$scriptBlock = {
						param ($exe,
							$args)
						$psi = New-Object System.Diagnostics.ProcessStartInfo
						$psi.FileName = $exe
						$psi.Arguments = $args
						$psi.UseShellExecute = $false
						$psi.RedirectStandardOutput = $true
						$psi.RedirectStandardError = $true
						$psi.CreateNoWindow = $true
						$p = [System.Diagnostics.Process]::Start($psi)
						$out = $p.StandardOutput.ReadToEnd()
						$err = $p.StandardError.ReadToEnd()
						$p.WaitForExit()
						return @{ ExitCode = $p.ExitCode; Output = $out; Error = $err }
					}
					$session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
					$remoteResult = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $dsmadmc, $cmdArgs -ErrorAction Stop
					$exitCode = $remoteResult.ExitCode
					$output = $remoteResult.Output
					$errorOut = $remoteResult.Error
					Remove-PSSession $session
				}
				
				$result.Output = $output
				$result.ErrorOutput = $errorOut
				
				if ($exitCode -eq 0 -and $output -match 'IBM Spectrum Protect')
				{
					$result.Success = $true
					$result.Message = "Verbindung zu TSM-Server '$effServerName' mit Benutzer '$effUserName' erfolgreich."
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
				}
				else
				{
					$result.Success = $false
					$result.Message = "Fehler bei TSM-Verbindung (Exitcode $exitCode). Ausgabe: $output $errorOut".Trim()
					Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "ERROR"
				}
			}
			else
			{
				$result.Success = $false
				$result.Message = "WhatIf: Verbindungstest wuerde ausgefuehrt."
				Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "VERBOSE"
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$result.Message = $errMsg
		}
		return $result
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}

# ---- Hilfsfunktionen (lokal) ----
function _FindDsmadmcPath
{
	param ([string]$ComputerName,
		[System.Management.Automation.PSCredential]$Credential)
	
	$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
	$candidates = [System.Collections.Generic.List[string]]::new()
	
	if ($isLocal)
	{
		try
		{
			$regPath = 'HKLM:\SOFTWARE\IBM\ADSM\CurrentVersion'
			$installPath = (Get-ItemProperty $regPath -Name 'InstallPath' -ErrorAction SilentlyContinue).InstallPath
			# KORREKTUR: Doppelte Klammern fuer den Methodenaufruf
			if ($installPath) { $candidates.Add((Join-Path $installPath 'dsmadmc.exe')) }
		}
		catch { }
		
		if ($env:DSM_DIR) { $candidates.Add((Join-Path $env:DSM_DIR 'dsmadmc.exe')) }
		
		$candidates.Add('C:\Program Files\Tivoli\TSM\baclient\dsmadmc.exe')
		$candidates.Add('C:\Program Files\IBM\TSM\baclient\dsmadmc.exe')
		$candidates.Add('C:\Program Files\IBM\SpectrumProtect\baclient\dsmadmc.exe')
	}
	else
	{
		# Remote-Logik... (hier ebenfalls Klammern pruefen falls Join-Path genutzt wird)
	}
	
	foreach ($c in $candidates)
	{
		if (Test-Path $c) { return $c }
	}
	return $null
}