<#
.SYNOPSIS
    Reads the IBM TSM / Spectrum Protect client configuration (dsm.opt) and returns
    server, user and password settings.

.DESCRIPTION
    Locates the dsm.opt option file (locally or on a remote computer), parses it and
    returns the relevant TSM client settings as an object.

    Steps:
      1. Determine the dsm.opt path (auto-detected via _FindDsmOptPath, or -DsmOptPath).
      2. Read the file (UNC/remote-capable via _ReadRemoteFile).
      3. Parse all non-comment options into a hashtable.
      4. Extract TCPServeraddress, USERID and PASSWORD.

    The password is returned as a SecureString; the plain-text value is only included
    when -IncludePasswordPlain is set. On error a result object with Success = $false is
    returned (or an exception is thrown when -EnableException is set).

.PARAMETER ComputerName
    Target computer. Default: local computer name.

.PARAMETER DsmOptPath
    Optional explicit path to the dsm.opt file. If omitted, it is auto-detected.

.PARAMETER IncludePasswordPlain
    Also return the password in plain text (PasswordPlain). Off by default.

.PARAMETER Credential
    Optional PSCredential for accessing a remote dsm.opt file.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning a result object with Success = $false.

.EXAMPLE
    Get-sqmTsmConfiguration -ComputerName SQL01
    # Reads the TSM configuration from SQL01 (password as SecureString).

.EXAMPLE
    Get-sqmTsmConfiguration -DsmOptPath 'C:\Program Files\Tivoli\TSM\baclient\dsm.opt' -IncludePasswordPlain
    # Uses an explicit dsm.opt path and also returns the plain-text password.

.NOTES
    Requires the private helpers _FindDsmOptPath and _ReadRemoteFile.
#>
function Get-sqmTsmConfiguration
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$ComputerName = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[string]$DsmOptPath,
		[Parameter(Mandatory = $false)]
		[switch]$IncludePasswordPlain,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		# Logging-Aufruf (setzt voraus, dass Invoke-sqmLogging existiert)
		if (Get-Command "Invoke-sqmLogging" -ErrorAction SilentlyContinue)
		{
			Invoke-sqmLogging -Message "Starte $functionName auf $ComputerName" -FunctionName $functionName -Level "INFO"
		}
	}
	
	process
	{
		try
		{
			$isLocal = $ComputerName -in @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.')
			$optFile = $DsmOptPath
			
			# 1. Pfad zur dsm.opt ermitteln
			if (-not $optFile)
			{
				if (Get-Command "_FindDsmOptPath" -ErrorAction SilentlyContinue)
				{
					$optFile = _FindDsmOptPath -ComputerName $ComputerName -IsLocal $isLocal -Credential $Credential
				}
				else
				{
					throw "Hilfsfunktion _FindDsmOptPath nicht gefunden."
				}
			}
			
			if (-not $optFile)
			{
				$msg = "dsm.opt konnte nicht gefunden werden. Bitte -DsmOptPath angeben."
				if ($EnableException) { throw $msg }
				return [PSCustomObject]@{ Success = $false; ErrorMessage = $msg; FilePath = $null }
			}
			
			# 2. Datei lesen
			# Hinweis: _ReadRemoteFile muss UNC-Pfad Handling beherrschen
			$lines = _ReadRemoteFile -ComputerName $ComputerName -FilePath $optFile -Credential $Credential -ErrorAction Stop
			
			# 3. Optionen parsen
			$options = @{ }
			$rawNonCommentLines = [System.Collections.Generic.List[string]]::new()
			
			foreach ($line in $lines)
			{
				$trimmed = $line.Trim()
				if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('*')) { continue }
				
				$rawNonCommentLines.Add($trimmed)
				
				# Regex verbessert: Erlaubt Bindestriche in Keys und ist robuster bei Whitespaces
				if ($trimmed -match '^([A-Za-z0-9_-]+)\s+(.+)$')
				{
					$key = $Matches[1]
					$value = $Matches[2].Trim().Trim("'").Trim('"') # Robusteres Entfernen von Quotes
					$options[$key] = $value
				}
			}
			
			# 4. Spezielle Werte extrahieren (Case-Insensitive Hashtable Zugriff)
			$serverName = $options['TCPServeraddress']
			$userName = $options['USERID']
			$passwordPlain = $options['PASSWORD']
			$passwordSecure = $null
			
			if ($passwordPlain)
			{
				$passwordSecure = ConvertTo-SecureString -String $passwordPlain -AsPlainText -Force
			}
			
			# 5. Rueckgabeobjekt
			$result = [PSCustomObject]@{
				Success	      = $true
				ErrorMessage  = $null
				FilePath	  = $optFile
				ServerName    = $serverName
				UserName	  = $userName
				Password	  = $passwordSecure
				PasswordPlain = if ($IncludePasswordPlain) { $passwordPlain } else { $null }
				AllOptions    = $options
				RawContent    = $rawNonCommentLines.ToArray()
			}
			
			return $result
		}
		catch
		{
			$errMsg = "Fehler beim Lesen der dsm.opt: $($_.Exception.Message)"
			if ($EnableException) { throw }
			return [PSCustomObject]@{ Success = $false; ErrorMessage = $errMsg; FilePath = $null }
		}
	}
	
	end
	{
		# Optionales Abschluss-Logging
	}
}