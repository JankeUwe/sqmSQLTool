<#
.SYNOPSIS
    Checks and corrects NTFS permissions for SSAS directories (Data, Log, Temp, Backup).

.DESCRIPTION
    Determines the directory paths for an SSAS instance from the registry,
    checks whether the SSAS service account has FullControl access to these directories,
    and sets any missing permissions as needed.

    The function is idempotent — on repeated calls only missing permissions are added.

.PARAMETER InstanceName
    Name of the SSAS instance. Default: 'MSSQLSERVER' (default instance).
    For named instances e.g. 'SSAS2019'.

.PARAMETER ServiceAccount
    Optional: Name of the service account (e.g. 'NT SERVICE\MSSQLServerOLAPService').
    If not specified, the account is automatically determined from the Windows service.

.PARAMETER WhatIf
    Shows which changes would be made without executing them.

.PARAMETER Confirm
    Prompts for confirmation before each change.

.PARAMETER EnableException
    Throws an exception immediately on errors (otherwise the error is logged).

.PARAMETER ContinueOnError
    Continues checking the next directories even on errors.

.EXAMPLE
    Test-sqmSsasDirectoryPermissions

    Checks the directories of the default SSAS instance and corrects missing permissions.

.EXAMPLE
    Test-sqmSsasDirectoryPermissions -InstanceName "SSAS2019" -WhatIf

    Shows which permissions would be set for the named instance.

.NOTES
    Requires local administrator rights on the SSAS server.
    The function uses the registry under HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSAS*.
#>
function Test-sqmSsasDirectoryPermissions
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$InstanceName = 'MSSQLSERVER',
		[Parameter(Mandatory = $false)]
		[string]$ServiceAccount,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		
		Invoke-sqmLogging -Message "Starte $functionName fuer SSAS-Instanz '$InstanceName'" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			# 1. Registry-Pfad fuer SSAS-Instanz finden
			$basePath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
			$instances = Get-ChildItem -Path $basePath -ErrorAction Stop | Where-Object { $_.PSChildName -like 'MSAS*' }
			if (-not $instances)
			{
				throw "Keine SSAS-Instanzen in der Registry gefunden."
			}
			
			$found = $null
			foreach ($inst in $instances)
			{
				$regPath = Join-Path $inst.PSPath "Setup"
				if (Test-Path $regPath)
				{
					$instId = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).InstanceName
					if ($instId -eq $InstanceName)
					{
						$found = $regPath
						break
					}
				}
			}
			if (-not $found)
			{
				throw "SSAS-Instanz '$InstanceName' nicht in der Registry gefunden."
			}
			$setupProps = Get-ItemProperty -Path $found -ErrorAction Stop
			$directories = @{
				DataDir = $setupProps.DataDir
				LogDir  = $setupProps.LogDir
				TempDir = $setupProps.TempDir
				BackupDir = $setupProps.BackupDir
			}
			
			# 2. Dienstkonto ermitteln
			if (-not $ServiceAccount)
			{
				$serviceName = if ($InstanceName -eq 'MSSQLSERVER')
				{
					'MSSQLServerOLAPService'
				}
				else
				{
					"MSOLAP`$$InstanceName"
				}
				$svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
				if (-not $svc)
				{
					throw "SSAS-Dienst '$serviceName' nicht gefunden."
				}
				$ServiceAccount = $svc.StartName
				Invoke-sqmLogging -Message "Dienstkonto automatisch ermittelt: $ServiceAccount" -FunctionName $functionName -Level "INFO"
			}
			
			# 3. Berechtigungen pruefen/korrigieren
			foreach ($dirName in @('DataDir', 'LogDir', 'TempDir', 'BackupDir'))
			{
				$dirPath = $directories[$dirName]
				if (-not $dirPath)
				{
					$msg = "Registry-Eintrag fuer $dirName ist leer oder nicht vorhanden."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results.Add([PSCustomObject]@{
							InstanceName = $InstanceName
							Directory    = $dirName
							Path		 = $null
							Status	     = 'NotFound'
							Message	     = $msg
						})
					continue
				}
				if (-not (Test-Path $dirPath))
				{
					$msg = "Verzeichnis '$dirPath' existiert nicht."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
					$results.Add([PSCustomObject]@{
							InstanceName = $InstanceName
							Directory    = $dirName
							Path		 = $dirPath
							Status	     = 'Missing'
							Message	     = $msg
						})
					if (-not $ContinueOnError) { throw $msg }
					continue
				}
				
				# ACL auslesen
				$acl = Get-Acl -Path $dirPath -ErrorAction Stop
				$identity = $ServiceAccount
				$accessRules = $acl.Access | Where-Object {
					$_.IdentityReference -eq $identity -and
					$_.FileSystemRights -eq 'FullControl' -and
					$_.IsInherited -eq $false
				}
				$hasFullControl = ($accessRules.Count -gt 0)
				
				if ($hasFullControl)
				{
					$msg = "OK: Vollzugriff fuer $identity bereits vorhanden."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "VERBOSE"
					$results.Add([PSCustomObject]@{
							InstanceName = $InstanceName
							Directory    = $dirName
							Path		 = $dirPath
							Status	     = 'OK'
							Message	     = $msg
						})
				}
				else
				{
					$msg = "Fehlender Vollzugriff fuer $identity auf '$dirPath'."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					if ($PSCmdlet.ShouldProcess($dirPath, "Vollzugriff fuer $identity hinzufuegen"))
					{
						try
						{
							$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
								$identity, 'FullControl',
								'ContainerInherit, ObjectInherit',
								'None', 'Allow'
							)
							$acl.SetAccessRule($rule)
							Set-Acl -Path $dirPath -AclObject $acl -ErrorAction Stop
							$successMsg = "Vollzugriff fuer $identity auf '$dirPath' wurde hinzugefuegt."
							Invoke-sqmLogging -Message $successMsg -FunctionName $functionName -Level "INFO"
							$results.Add([PSCustomObject]@{
									InstanceName = $InstanceName
									Directory    = $dirName
									Path		 = $dirPath
									Status	     = 'Fixed'
									Message	     = $successMsg
								})
						}
						catch
						{
							$errMsg = "Fehler beim Setzen der Berechtigung auf '$dirPath': $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results.Add([PSCustomObject]@{
									InstanceName = $InstanceName
									Directory    = $dirName
									Path		 = $dirPath
									Status	     = 'Failed'
									Message	     = $errMsg
								})
							if (-not $ContinueOnError) { throw $errMsg }
						}
					}
					else
					{
						$skipMsg = "WhatIf: Berechtigung wuerde hinzugefuegt."
						$results.Add([PSCustomObject]@{
								InstanceName = $InstanceName
								Directory    = $dirName
								Path		 = $dirPath
								Status	     = 'WhatIf'
								Message	     = $skipMsg
							})
					}
				}
			}
		}
		catch
		{
			$errMsg = "Schwerer Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results.Add([PSCustomObject]@{
					InstanceName = $InstanceName
					Directory    = 'Global'
					Path		 = $null
					Status	     = 'Error'
					Message	     = $errMsg
				})
		}
		return $results
	}
}